import 'package:shared_preferences/shared_preferences.dart';

/// Theme preference persisted in settings.
enum AppThemeMode { system, light, dark }

/// User preferences persisted with shared_preferences (non-secret).
class AppSettings {
  const AppSettings({
    this.serverUrl = '',
    this.themeMode = AppThemeMode.system,
    // "Stay signed in" is on by default so sessions persist across launches.
    this.rememberMe = true,
    this.lastOrgId,
    this.lastOrgName,
    this.userEmail,
    this.originHeader,
    this.refererHeader,
  });

  final String serverUrl;
  final AppThemeMode themeMode;
  final bool rememberMe;
  final String? lastOrgId;
  final String? lastOrgName;
  final String? userEmail;

  /// Optional custom request headers (e.g. Origin/Referer) for servers whose
  /// CORS/origin middleware rejects requests without a matching origin.
  final String? originHeader;
  final String? refererHeader;
}

class SettingsStore {
  static const _kServerUrl = 'server_url';
  static const _kThemeMode = 'theme_mode';
  static const _kRememberMe = 'remember_me';
  static const _kLastOrgId = 'last_org_id';
  static const _kLastOrgName = 'last_org_name';
  static const _kUserEmail = 'user_email';
  static const _kOriginHeader = 'origin_header';
  static const _kRefererHeader = 'referer_header';

  Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      serverUrl: p.getString(_kServerUrl) ?? '',
      themeMode: _themeFromName(p.getString(_kThemeMode)),
      rememberMe: p.getBool(_kRememberMe) ?? true,
      lastOrgId: p.getString(_kLastOrgId),
      lastOrgName: p.getString(_kLastOrgName),
      userEmail: p.getString(_kUserEmail),
      originHeader: p.getString(_kOriginHeader),
      refererHeader: p.getString(_kRefererHeader),
    );
  }

  Future<void> save({
    String? serverUrl,
    AppThemeMode? themeMode,
    bool? rememberMe,
    String? lastOrgId,
    String? lastOrgName,
    String? userEmail,
    String? originHeader,
    String? refererHeader,
  }) async {
    final p = await SharedPreferences.getInstance();
    if (serverUrl != null) await p.setString(_kServerUrl, serverUrl);
    if (themeMode != null) await p.setString(_kThemeMode, themeMode.name);
    if (rememberMe != null) await p.setBool(_kRememberMe, rememberMe);
    if (lastOrgId != null) await p.setString(_kLastOrgId, lastOrgId);
    if (lastOrgName != null) await p.setString(_kLastOrgName, lastOrgName);
    if (userEmail != null) await p.setString(_kUserEmail, userEmail);
    if (originHeader != null) await p.setString(_kOriginHeader, originHeader);
    if (refererHeader != null) await p.setString(_kRefererHeader, refererHeader);
  }

  /// Clears everything auth-related (used on logout). Keeps server URL + theme.
  Future<void> clearAuth() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kLastOrgId);
    await p.remove(_kLastOrgName);
    await p.remove(_kUserEmail);
    await p.remove(_kRememberMe);
  }

  static AppThemeMode _themeFromName(String? name) =>
      AppThemeMode.values.asNameMap()[name] ?? AppThemeMode.system;
}
