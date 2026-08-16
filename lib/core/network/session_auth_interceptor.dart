import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'session_cookie_store.dart';

/// Attaches the session cookie to every request, captures renewed cookies from
/// responses, and transparently refreshes an expired session before surfacing
/// the failure.
///
/// A session is considered expired only when renewal fails; at that point
/// [onSessionExpired] fires (the app signs the user out) and a
/// [PapraApiException] with [PapraApiException.isSessionExpired] is thrown.
class SessionAuthInterceptor extends QueuedInterceptor {
  SessionAuthInterceptor({
    required this.baseUrl,
    required this.cookieStore,
    required this.onSessionExpired,
  });

  final String baseUrl;
  final SessionCookieStore cookieStore;
  final void Function() onSessionExpired;

  Dio? _refreshDio;
  Future<bool>? _inflightRefresh;

  /// A bare Dio (no interceptors) used for renewal + retry requests.
  Dio get _dio => _refreshDio ??= Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final cookie = cookieStore.cookie;
    if (cookie != null && cookie.isNotEmpty) {
      options.headers['Cookie'] = cookie;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _captureCookies(response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final requestOptions = err.requestOptions;
    final isAuthFailure = err.response?.statusCode == 401;
    if (isAuthFailure &&
        requestOptions.extra['_authRetried'] != true &&
        requestOptions.extra['_skipAuthRefresh'] != true) {
      _handleUnauthorized(err, handler);
    } else {
      handler.next(err);
    }
  }

  Future<void> _handleUnauthorized(DioException err, ErrorInterceptorHandler handler) async {
    final cookie = cookieStore.cookie;
    if (cookie == null || cookie.isEmpty) {
      _expire(handler, err);
      return;
    }

    final renewed = await _refreshOnce();
    if (!renewed) {
      _expire(handler, err);
      return;
    }

    // Session renewed — replay the original request once.
    final options = err.requestOptions;
    options.extra['_authRetried'] = true;
    try {
      final response = await _dio.fetch<dynamic>(options);
      _captureCookies(response);
      handler.resolve(response);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        _expire(handler, e);
      } else {
        handler.next(e);
      }
    }
  }

  Future<bool> _refreshOnce() {
    final inflight = _inflightRefresh;
    if (inflight != null) return inflight;
    final future = _tryRefreshSession();
    _inflightRefresh = future;
    return future.whenComplete(() => _inflightRefresh = null);
  }

  /// Best-effort session renewal.
  ///
  /// 1. `GET /api/auth/get-session` — standard Better Auth endpoint; validating
  ///    a session slides its expiry forward (sliding window).
  /// 2. `POST /api/auth/refresh` — attempted if the fork exposes it.
  ///
  /// ⚠️ VERIFY against the fork's Better Auth config: if the fork does not slide
  /// sessions and has no refresh endpoint, expired sessions will force a re-login.
  Future<bool> _tryRefreshSession() async {
    final cookie = cookieStore.cookie;
    if (cookie == null || cookie.isEmpty) return false;
    final headers = {'Cookie': cookie};

    try {
      final resp = await _dio.get<dynamic>('$baseUrl/api/auth/get-session', options: Options(headers: headers));
      if (resp.statusCode == 200) {
        _captureCookies(resp);
        return true;
      }
    } catch (_) {
      // Fall through to the refresh attempt.
    }

    try {
      final resp = await _dio.post<dynamic>('$baseUrl/api/auth/refresh', options: Options(headers: headers));
      if (resp.statusCode == 200 || resp.statusCode == 204) {
        _captureCookies(resp);
        return true;
      }
    } catch (_) {
      // Fall through.
    }
    return false;
  }

  void _captureCookies(Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      cookieStore.setFromHeaders(setCookie);
    }
  }

  void _expire(ErrorInterceptorHandler handler, DioException err) {
    onSessionExpired();
    handler.reject(DioException(
      requestOptions: err.requestOptions,
      type: DioExceptionType.unknown,
      error: PapraApiException(
        statusCode: 401,
        message: 'Your session has expired. Please sign in again.',
        isSessionExpired: true,
      ),
    ));
  }
}
