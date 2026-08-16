import '../storage/secure_store.dart';

/// Holds the Better Auth session cookie used by the session-authenticated
/// client (tagging rules + intake emails).
///
/// The cookie lives in memory for the whole session. When [persist] is true
/// ("remember me"), it is also mirrored to [SecureStore] so the app can
/// restore the session on the next launch.
class SessionCookieStore {
  SessionCookieStore(this._secure);

  final SecureStore _secure;

  String? _cookie;

  /// Whether the cookie is mirrored to secure storage. Set from the
  /// "remember me" preference.
  bool persist = false;

  String? get cookie => _cookie;

  /// Merges `Set-Cookie` response headers (name=value pairs only).
  void setFromHeaders(List<String> setCookieHeaders) {
    final parts = <String>[];
    for (final header in setCookieHeaders) {
      final nameValue = header.split(';').first.trim();
      if (nameValue.isNotEmpty && nameValue.contains('=')) parts.add(nameValue);
    }
    if (parts.isEmpty) return;
    _cookie = parts.join('; ');
    if (persist) _secure.saveSessionCookie(_cookie!);
  }

  void set(String cookie) {
    _cookie = cookie;
    if (persist) _secure.saveSessionCookie(cookie);
  }

  Future<void> restore() async {
    _cookie ??= await _secure.readSessionCookie();
  }

  Future<void> clear() async {
    _cookie = null;
    await _secure.deleteSessionCookie();
  }
}
