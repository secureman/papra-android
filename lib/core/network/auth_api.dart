import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'interceptors.dart';
import 'models.dart';
import 'session_auth_interceptor.dart';
import 'session_cookie_store.dart';

/// The pre-auth client. Everything here authenticates with the Better Auth
/// session cookie: sign-in, listing organizations, minting the per-org device
/// API key, and session validation.
class AuthApi {
  AuthApi({
    required this.baseUrl,
    required SessionCookieStore cookieStore,
    required this.onSessionExpired,
    Map<String, String> customHeaders = const {},
  }) : _cookieStore = cookieStore {
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 60),
      ),
    );
    _dio.interceptors.add(SessionAuthInterceptor(
      baseUrl: baseUrl,
      cookieStore: cookieStore,
      onSessionExpired: onSessionExpired,
    ));
    _dio.interceptors.add(CustomHeadersInterceptor(customHeaders));
  }

  final String baseUrl;
  final SessionCookieStore _cookieStore;
  final void Function() onSessionExpired;

  late final Dio _dio;

  /// Normalizes [DioException]s to [PapraApiException].
  Future<T> _run<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw mapDioError(e, messageFor401: 'Invalid email or password');
    }
  }

  /// Signs in with email/password against Better Auth and returns the session
  /// cookie (captured into [_cookieStore] by the interceptor).
  Future<String> signInWithEmail({
    required String email,
    required String password,
    required bool rememberMe,
  }) {
    return _run(() async {
      await _dio.post(
      '/api/auth/sign-in/email',
      data: SignInRequest(email: email, password: password, rememberMe: rememberMe).toJson(),
      options: Options(extra: {'_skipAuthRefresh': true}),
    );
    final cookie = _cookieStore.cookie;
    if (cookie == null || cookie.isEmpty) {
      throw const PapraApiException(
        statusCode: 500,
        message: 'The server did not return a session. Check the server URL.',
      );
    }
    return cookie;
    });
  }

  Future<List<PapraOrganization>> listOrganizations() {
    return _run(() async {
      final resp = await _dio.get('/api/organizations');
      return OrganizationsResponse.fromJson(asMap(resp.data)).organizations;
    });
  }

  /// Mints a device API key. Requires the session cookie.
  ///
  /// The fork (like upstream papra) only exposes `POST /api/api-keys` and
  /// creates keys that cover all of the user's organizations — there is no
  /// org-scoped endpoint. The fork returns the token at the top level:
  /// `{ apiKey, token }`.
  Future<String> createDeviceApiKey({
    required String name,
    required List<String> permissions,
  }) {
    return _run(() async {
      final resp = await _dio.post(
        '/api/api-keys',
        data: DeviceApiKeyRequest(name: name, permissions: permissions).toJson(),
      );
      final token = DeviceApiKeyResponse.fromJson(asMap(resp.data)).token;
      if (token.isEmpty) {
        throw const PapraApiException(
          statusCode: 500,
          message: 'The server did not return a device API key.',
        );
      }
      return token;
    });
  }

  /// True if the current session is still valid. Never triggers renewal.
  Future<bool> validateSession() async {
    try {
      final resp = await _dio.get(
        '/api/auth/get-session',
        options: Options(extra: {'_skipAuthRefresh': true}),
      );
      if (resp.statusCode != 200) return false;
      final session = asMap(resp.data)['session'];
      return session != null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return false;
      rethrow;
    }
  }
}
