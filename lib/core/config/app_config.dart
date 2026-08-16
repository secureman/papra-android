/// App-wide constants.
class AppConfig {
  const AppConfig._();

  static const String appName = 'Papra';
  static const String deviceKeyName = 'Papra Android app';

  /// Scopes requested when minting the device API key.
  ///
  /// Matches the exact permission strings the official papra server accepts
  /// (`API_KEY_PERMISSIONS` in `apps/papra-server/src/modules/api-keys`).
  /// `folders:*` is fork-only and the official server rejects it, which made
  /// key minting fail with "invalid request body" at login.
  static const List<String> deviceKeyPermissions = [
    'organizations:read',
    'documents:create',
    'documents:read',
    'documents:update',
    'documents:delete',
    'tags:create',
    'tags:read',
    'tags:update',
    'tags:delete',
    'custom-properties:create',
    'custom-properties:read',
    'custom-properties:update',
    'custom-properties:delete',
  ];
}
