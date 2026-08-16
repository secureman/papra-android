import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted storage for secrets: per-org device API keys and the session
/// cookie backup used by "remember me".
class SecureStore {
  SecureStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _apiKeyPrefix = 'api_key:';
  static const _sessionCookieKey = 'session_cookie';

  Future<void> saveApiKey({required String orgId, required String token}) =>
      _storage.write(key: '$_apiKeyPrefix$orgId', value: token);

  Future<String?> readApiKey(String orgId) => _storage.read(key: '$_apiKeyPrefix$orgId');

  Future<Map<String, String>> readAllApiKeys() async {
    final all = await _storage.readAll();
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(_apiKeyPrefix)) entry.key.substring(_apiKeyPrefix.length): entry.value,
    };
  }

  Future<void> deleteApiKey(String orgId) => _storage.delete(key: '$_apiKeyPrefix$orgId');

  Future<void> saveSessionCookie(String cookie) => _storage.write(key: _sessionCookieKey, value: cookie);

  Future<String?> readSessionCookie() => _storage.read(key: _sessionCookieKey);

  Future<void> deleteSessionCookie() => _storage.delete(key: _sessionCookieKey);

  Future<void> clearAuth() => _storage.deleteAll();
}
