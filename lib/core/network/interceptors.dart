import 'dart:convert';

import 'package:dio/dio.dart';

import 'api_exception.dart';

/// Applies optional custom headers (e.g. Origin/Referer for servers with
/// strict CORS/origin middleware) to every request. Empty values are skipped.
class CustomHeadersInterceptor extends Interceptor {
  CustomHeadersInterceptor(this.headers);

  final Map<String, String> headers;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    headers.forEach((key, value) {
      if (value.isNotEmpty) options.headers[key] = value;
    });
    handler.next(options);
  }
}

/// Converts a raw [DioException] into a [PapraApiException] so feature code
/// only ever handles one error type. Exceptions already carrying a
/// [PapraApiException] (e.g. from the session interceptor) pass through.
PapraApiException mapDioError(DioException e, {required String messageFor401}) {
  final alreadyTyped = e.error;
  if (alreadyTyped is PapraApiException) return alreadyTyped;

  final status = e.response?.statusCode;

  if (e.type == DioExceptionType.connectionError ||
      e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.receiveTimeout) {
    return PapraApiException(
      isNetwork: true,
      message: 'Could not reach the server. Check your connection and the server URL.',
      cause: e,
    );
  }

  if (status == 401 || status == 403) {
    return PapraApiException(statusCode: status, message: messageFor401, cause: e);
  }

  final message = _extractMessage(e.response?.data);
  return PapraApiException(
    statusCode: status,
    message: message ?? 'HTTP ${status ?? 'unknown error'}',
    cause: e,
  );
}

String? _extractMessage(Object? data) {
  if (data is Map) {
    final raw = data['message'] ?? data['error'];
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is Map && raw['message'] is String) return raw['message'] as String;
    return null;
  }
  if (data is String && data.isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) return _extractMessage(decoded);
    } catch (_) {
      // Not JSON — a plain-text body.
    }
    return data.length > 200 ? data.substring(0, 200) : data;
  }
  return null;
}
