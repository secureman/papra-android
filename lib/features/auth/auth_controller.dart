import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/auth_api.dart';
import '../../core/network/models.dart';
import '../../core/providers.dart';
import '../../core/storage/settings_store.dart';
import 'auth_state.dart';

final authStateProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

/// The authenticated [ApiClient], or null while not authenticated.
/// Re-created whenever the auth state changes (org switch, re-login).
final apiClientProvider = Provider<ApiClient?>((ref) {
  final auth = ref.watch(authStateProvider);
  if (auth is! AuthAuthenticated) return null;
  return ApiClient(
    baseUrl: auth.baseUrl,
    organizationId: auth.organizationId,
    apiKey: auth.apiKey,
    cookieStore: ref.watch(sessionCookieStoreProvider),
    onAuthFailure: () => ref.read(authStateProvider.notifier).handleAuthFailure(),
  );
});

class AuthController extends Notifier<AuthState> {
  AppSettings? _settings;

  Future<AppSettings> _loadSettings() async {
    _settings ??= await ref.read(settingsStoreProvider).load();
    return _settings!;
  }

  Map<String, String> get _customHeaders {
    final s = _settings ?? const AppSettings();
    return {'Origin': s.originHeader ?? '', 'Referer': s.refererHeader ?? ''};
  }

  AuthApi _authApi(String baseUrl) => AuthApi(
        baseUrl: baseUrl,
        cookieStore: ref.read(sessionCookieStoreProvider),
        onSessionExpired: handleAuthFailure,
        customHeaders: _customHeaders,
      );

  @override
  AuthState build() {
    _restore();
    return const AuthUnknown();
  }

  // ── Restore (app launch) ──────────────────────────────────────────────────

  Future<void> _restore() async {
    try {
      final settings = await _loadSettings();
      final cookieStore = ref.read(sessionCookieStoreProvider);
      cookieStore.persist = settings.rememberMe;

      if (settings.serverUrl.isEmpty || !settings.rememberMe) {
        state = const AuthUnauthenticated();
        return;
      }

      await cookieStore.restore();
      if (cookieStore.cookie == null || cookieStore.cookie!.isEmpty) {
        state = const AuthUnauthenticated();
        return;
      }

      final api = _authApi(settings.serverUrl);
      final keys = await ref.read(secureStoreProvider).readAllApiKeys();
      final lastOrgId = settings.lastOrgId;

      if (lastOrgId != null && keys.containsKey(lastOrgId)) {
        // Optimistic restore; validate in the background so a dead session is
        // caught without blocking startup.
        state = AuthAuthenticated(
          baseUrl: settings.serverUrl,
          apiKey: keys[lastOrgId]!,
          organizationId: lastOrgId,
          organizationName: settings.lastOrgName ?? '',
          userEmail: settings.userEmail ?? '',
        );
        _validateInBackground(api);
        return;
      }

      // No usable key for the last org — re-list orgs and pick.
      final orgs = await api.listOrganizations();
      if (orgs.isEmpty) {
        state = const AuthUnauthenticated();
        return;
      }
      if (orgs.length == 1) {
        await _mintAndAuthenticate(api, orgs.first, settings);
      } else {
        state = AuthNeedsOrgSelection(
          baseUrl: settings.serverUrl,
          userEmail: settings.userEmail ?? '',
          organizations: orgs,
        );
      }
    } catch (_) {
      state = const AuthUnauthenticated();
    }
  }

  Future<void> _validateInBackground(AuthApi api) async {
    try {
      final valid = await api.validateSession();
      if (!valid) handleAuthFailure();
    } catch (_) {
      // Offline or server unreachable — keep the optimistic session.
    }
  }

  // ── Sign-in ───────────────────────────────────────────────────────────────

  Future<void> signIn({
    required String serverUrl,
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    final baseUrl = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty || email.trim().isEmpty || password.isEmpty) {
      throw const PapraApiException(message: 'Fill in the server URL, email and password.');
    }

    final cookieStore = ref.read(sessionCookieStoreProvider);
    cookieStore.persist = rememberMe;
    await cookieStore.clear();

    final settings = await _loadSettings();
    final api = _authApi(baseUrl);
    await api.signInWithEmail(email: email.trim(), password: password, rememberMe: rememberMe);

    final orgs = await api.listOrganizations();
    if (orgs.isEmpty) {
      throw const PapraApiException(message: 'No organizations found for this account.');
    }

    await ref.read(settingsStoreProvider).save(
          serverUrl: baseUrl,
          rememberMe: rememberMe,
          userEmail: email.trim(),
        );

    if (orgs.length == 1) {
      await _mintAndAuthenticate(api, orgs.first, settings);
    } else {
      state = AuthNeedsOrgSelection(
        baseUrl: baseUrl,
        userEmail: email.trim(),
        organizations: orgs,
      );
    }
  }

  // ── Org selection ─────────────────────────────────────────────────────────

  Future<void> selectOrganization(PapraOrganization org) async {
    final current = state;
    if (current is! AuthNeedsOrgSelection) return;
    final settings = await _loadSettings();
    final api = _authApi(current.baseUrl);
    await _mintAndAuthenticate(api, org, settings);
  }

  /// Switches orgs while authenticated, reusing an already-minted key if one
  /// exists for that org (fixes the old client's single-key-for-all-orgs bug).
  Future<void> switchOrganization(PapraOrganization org) async {
    final current = state;
    if (current is! AuthAuthenticated) return;
    if (org.id == current.organizationId) return;

    final api = _authApi(current.baseUrl);
    var token = await ref.read(secureStoreProvider).readApiKey(org.id);
    if (token == null) {
      // The fork's `/api/api-keys` endpoint mints a key valid for all of the
      // user's organizations, so a single mint covers every org. We still
      // store it per-org so each org keeps a stable key.
      token = await api.createDeviceApiKey(
        name: AppConfig.deviceKeyName,
        permissions: AppConfig.deviceKeyPermissions,
      );
      await ref.read(secureStoreProvider).saveApiKey(orgId: org.id, token: token);
    }
    await ref.read(settingsStoreProvider).save(lastOrgId: org.id, lastOrgName: org.name);
    state = AuthAuthenticated(
      baseUrl: current.baseUrl,
      apiKey: token,
      organizationId: org.id,
      organizationName: org.name,
      userEmail: current.userEmail,
    );
  }

  Future<List<PapraOrganization>> listOrganizations() async {
    final current = state;
    if (current is! AuthAuthenticated) return const [];
    final api = _authApi(current.baseUrl);
    return api.listOrganizations();
  }

  Future<void> _mintAndAuthenticate(
    AuthApi api,
    PapraOrganization org,
    AppSettings settings,
  ) async {
    final token = await api.createDeviceApiKey(
      name: AppConfig.deviceKeyName,
      permissions: AppConfig.deviceKeyPermissions,
    );
    await ref.read(secureStoreProvider).saveApiKey(orgId: org.id, token: token);
    await ref.read(settingsStoreProvider).save(lastOrgId: org.id, lastOrgName: org.name);
    state = AuthAuthenticated(
      baseUrl: api.baseUrl,
      apiKey: token,
      organizationId: org.id,
      organizationName: org.name,
      userEmail: settings.userEmail ?? '',
    );
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  Future<void> logout() async {
    await ref.read(secureStoreProvider).clearAuth();
    await ref.read(sessionCookieStoreProvider).clear();
    await ref.read(settingsStoreProvider).clearAuth();
    _settings = null;
    state = const AuthUnauthenticated();
  }

  /// Called by the network layer when the session or key is definitively dead.
  void handleAuthFailure() {
    if (state is AuthAuthenticated || state is AuthNeedsOrgSelection) {
      // Defer so we don't mutate state from inside a Dio interceptor stack.
      Future.microtask(logout);
    }
  }
}
