/// A typed error thrown by the API layer.
///
/// Carries enough structure for screens to special-case the important cases:
/// duplicate uploads (409), invalid origin (server-side CORS config), and
/// expired sessions.
class PapraApiException implements Exception {
  const PapraApiException({
    this.statusCode,
    this.message = '',
    this.isNetwork = false,
    this.isSessionExpired = false,
    this.cause,
  });

  final int? statusCode;
  final String message;
  final bool isNetwork;
  final bool isSessionExpired;
  final Object? cause;

  /// Server returned 409 — the uploaded document already exists.
  bool get isDuplicate => statusCode == 409;

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  bool get isNotFound => statusCode == 404;

  /// The server's CORS/origin middleware rejected the request because the
  /// Origin/Referer headers don't match what it expects.
  bool get isInvalidOrigin =>
      message.toLowerCase().contains('invalid application origin') ||
      message.toLowerCase().contains('origin');

  @override
  String toString() =>
      message.isEmpty ? 'HTTP ${statusCode ?? 'unknown error'}' : message;
}
