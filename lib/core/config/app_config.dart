/// App-wide constants.
class AppConfig {
  const AppConfig._();

  static const String appName = 'Papra';
  static const String deviceKeyName = 'Papra Android app';

  /// Scopes requested when minting the device API key.
  ///
  /// Restricted to the exact permission strings the fork's server accepts
  /// (`API_KEY_PERMISSIONS` in `apps/papra-server/src/modules/api-keys`).
  /// The fork does not define `api-keys:*`, `intake-emails:*` or
  /// `tagging-rules:*` scopes, so requesting them makes the key-minting call
  /// fail validation. Intake emails and tagging rules are session-authenticated
  /// endpoints anyway, so they don't need key scopes.
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
    'folders:create',
    'folders:read',
    'folders:update',
    'folders:delete',
  ];
}
