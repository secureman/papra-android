import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'interceptors.dart';
import 'models.dart';
import 'session_auth_interceptor.dart';
import 'session_cookie_store.dart';

/// Typed client for the Papra REST API.
///
/// Mirrors the fork's dual-auth middleware:
///  * [dio] — API-key (Bearer) auth for documents, folders, tags, sharing,
///    custom properties. The fork rejects most endpoints without a key.
///  * [sessionDio] — session-cookie auth for tagging rules and intake emails,
///    which the fork's middleware only accepts with session auth.
///
/// Paths, query params, bodies and response keys were aligned against the
/// fork's routes in `apps/papra-server/src/modules` (all `*.routes.ts`).
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.organizationId,
    required this.apiKey,
    required this.cookieStore,
    required this.onAuthFailure,
    Map<String, String> customHeaders = const {},
  }) {
    dio = _buildKeyDio(customHeaders);
    sessionDio = _buildSessionDio(customHeaders);
  }

  final String baseUrl;
  final String organizationId;
  final String apiKey;
  final SessionCookieStore cookieStore;

  /// Called when auth is definitively invalid (expired session or dead key),
  /// so the auth controller can sign the user out.
  final void Function() onAuthFailure;

  late final Dio dio;
  late final Dio sessionDio;

  String _orgPath(String path) => '/api/organizations/$organizationId$path';

  Dio _buildKeyDio(Map<String, String> customHeaders) {
    final d = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 120),
        sendTimeout: const Duration(seconds: 120),
      ),
    );
    d.interceptors.add(CustomHeadersInterceptor(customHeaders));
    d.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['Authorization'] = 'Bearer $apiKey';
      handler.next(options);
    }));
    return d;
  }

  Dio _buildSessionDio(Map<String, String> customHeaders) {
    final d = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 120),
        sendTimeout: const Duration(seconds: 120),
      ),
    );
    d.interceptors.add(CustomHeadersInterceptor(customHeaders));
    d.interceptors.add(SessionAuthInterceptor(
      baseUrl: baseUrl,
      cookieStore: cookieStore,
      onSessionExpired: onAuthFailure,
    ));
    return d;
  }

  /// Runs a request and normalizes failures to [PapraApiException].
  ///
  /// For key-authenticated calls ([notifyAuthFailure] == true) a dead key
  /// (401) means the whole session is stale, so it is surfaced to the auth
  /// layer. Session endpoints handle their own expiry via the interceptor.
  Future<T> _run<T>(Future<T> Function() fn, {bool notifyAuthFailure = true}) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw _normalize(e, notifyAuthFailure: notifyAuthFailure);
    } on PapraApiException catch (e) {
      throw _normalize(e, notifyAuthFailure: notifyAuthFailure);
    }
  }

  PapraApiException _normalize(Object error, {required bool notifyAuthFailure}) {
    final mapped = error is DioException
        ? mapDioError(error, messageFor401: 'Invalid API key. Please sign in again.')
        : error as PapraApiException;
    if (notifyAuthFailure && mapped.isUnauthorized && !mapped.isSessionExpired) {
      onAuthFailure();
    }
    return mapped;
  }

  // ── Documents ─────────────────────────────────────────────────────────────

  /// Lists/searchable documents. The fork's query schema is strict and only
  /// accepts `searchQuery`, `sortField`, `sortOrder`, `pageIndex`, `pageSize`
  /// — there is no `folderId`/`trashed` filter here (use [getFolderContents]
  /// to browse a folder, [listDeletedDocuments] for the trash).
  Future<DocumentsResponse> listDocuments({
    String search = '',
    int pageIndex = 0,
    int pageSize = 100,
    String sortField = 'createdAt',
    String sortOrder = 'desc',
  }) {
    return _run(() async {
      final resp = await dio.get(
        _orgPath('/documents'),
        queryParameters: {
          if (search.isNotEmpty) 'searchQuery': search,
          'pageIndex': pageIndex,
          'pageSize': pageSize,
          'sortField': sortField,
          'sortOrder': sortOrder,
        },
      );
      return DocumentsResponse.fromJson(asMap(resp.data));
    });
  }

  /// Documents currently in the trash (fork: `GET /documents/deleted`).
  Future<DocumentsResponse> listDeletedDocuments({
    int pageIndex = 0,
    int pageSize = 100,
  }) {
    return _run(() async {
      final resp = await dio.get(
        _orgPath('/documents/deleted'),
        queryParameters: {'pageIndex': pageIndex, 'pageSize': pageSize},
      );
      return DocumentsResponse.fromJson(asMap(resp.data));
    });
  }

  /// Uploads a single file. The fork expects `folderId` as a *query* param and
  /// the file under the `file` form field. Returns the created document id.
  Future<String> uploadDocument({
    required String filePath,
    required String fileName,
    String? folderId,
    void Function(int sent, int total)? onProgress,
  }) {
    return _run(() async {
      final form = FormData();
      form.files.add(
        MapEntry('file', await MultipartFile.fromFile(filePath, filename: fileName)),
      );
      final resp = await dio.post(
        _orgPath('/documents'),
        queryParameters: {
          if (folderId != null && folderId.isNotEmpty) 'folderId': folderId,
        },
        data: form,
        onSendProgress: onProgress,
      );
      final data = asMap(resp.data);
      final doc = data['document'];
      if (doc is Map<String, dynamic>) return doc['id']?.toString() ?? '';
      return '';
    });
  }

  Future<void> downloadDocument({
    required String documentId,
    required String savePath,
    void Function(int received, int total)? onReceiveProgress,
  }) {
    return _run(() => dio.download(
          _orgPath('/documents/$documentId/file'),
          savePath,
          onReceiveProgress: onReceiveProgress,
        ));
  }

  /// Fetches one document, enriched with tags and custom properties. The
  /// extracted text is available on [PapraDocument.content].
  Future<PapraDocument> getDocument(String documentId) {
    return _run(() async {
      final resp = await dio.get(_orgPath('/documents/$documentId'));
      return PapraDocument.fromJson(asMap(asMap(resp.data)['document'] as Map<String, dynamic>? ?? const {}));
    });
  }

  /// Moves a document to the trash. The fork's `DELETE /documents/:id` trashes
  /// the document (soft delete); it is not a hard delete.
  Future<void> trashDocument(String documentId) {
    return _run(() => dio.delete(_orgPath('/documents/$documentId')));
  }

  /// Restores a document that is already in the trash.
  ///
  /// The fork's restore route uses bare `requireAuthentication()` (no API-key
  /// permissions), which the middleware only satisfies with a session cookie —
  /// same as the tagging rules/intake emails/backups routes. So it goes
  /// through [sessionDio] and never triggers an "invalid API key" sign-out.
  Future<void> restoreDocument(String documentId) {
    return _run(
      () => sessionDio.post(_orgPath('/documents/$documentId/restore')),
      notifyAuthFailure: false,
    );
  }

  /// Permanently deletes a document that is already in the trash (session
  /// auth, same as [restoreDocument]).
  Future<void> permanentlyDeleteDocument(String documentId) {
    return _run(
      () => sessionDio.delete(_orgPath('/documents/trash/$documentId')),
      notifyAuthFailure: false,
    );
  }

  /// Permanently deletes every document in the trash (session auth, same as
  /// [restoreDocument]).
  Future<void> emptyTrash() {
    return _run(
      () => sessionDio.delete(_orgPath('/documents/trash')),
      notifyAuthFailure: false,
    );
  }

  Future<void> renameDocument(String documentId, String newName) {
    return _run(() => dio.patch(_orgPath('/documents/$documentId'), data: {'name': newName}));
  }

  /// Moves a document into [folderId], or to the organization root when null
  /// (the fork's update schema accepts a nullable `folderId`).
  Future<void> moveDocumentToFolder(String documentId, String? folderId) {
    return _run(() => dio.patch(
          _orgPath('/documents/$documentId'),
          data: {'folderId': folderId},
        ));
  }

  // ── Tags ──────────────────────────────────────────────────────────────────

  Future<List<PapraTag>> listTags() {
    return _run(() async {
      final resp = await dio.get(_orgPath('/tags'));
      return TagsResponse.fromJson(asMap(resp.data)).tags;
    });
  }

  Future<void> createTag({required String name, required String color, String? description}) {
    return _run(() => dio.post(
          _orgPath('/tags'),
          data: {'name': name, 'color': color, 'description': ?description},
        ));
  }

  Future<void> updateTag(String tagId, {String? name, String? color, String? description}) {
    return _run(() => dio.put(
          _orgPath('/tags/$tagId'),
          data: {'name': ?name, 'color': ?color, 'description': ?description},
        ));
  }

  Future<void> deleteTag(String tagId) {
    return _run(() => dio.delete(_orgPath('/tags/$tagId')));
  }

  Future<void> addTagToDocument(String documentId, String tagId) {
    return _run(() => dio.post(
          _orgPath('/documents/$documentId/tags'),
          data: {'tagId': tagId},
        ));
  }

  Future<void> removeTagFromDocument(String documentId, String tagId) {
    return _run(() => dio.delete(_orgPath('/documents/$documentId/tags/$tagId')));
  }

  // ── Sharing ───────────────────────────────────────────────────────────────

  Future<List<PapraShareLink>> listShareLinksForDocument(String documentId) {
    return _run(() async {
      final resp = await dio.get(_orgPath('/documents/$documentId/share-links'));
      return ShareLinksResponse.fromJson(asMap(resp.data)).shareLinks;
    });
  }

  /// Lists every share link in the organization.
  Future<List<PapraShareLink>> listOrganizationShareLinks() {
    return _run(() async {
      final resp = await dio.get(_orgPath('/share-links'));
      return ShareLinksResponse.fromJson(asMap(resp.data)).shareLinks;
    });
  }

  /// [expiresAt] must be an ISO-8601 timestamp string.
  Future<void> createShareLink(
    String documentId, {
    String? expiresAt,
    String? password,
  }) {
    return _run(() => dio.post(
          _orgPath('/documents/$documentId/share-links'),
          data: {'expiresAt': ?expiresAt, 'password': ?password},
        ));
  }

  /// Updates a share link. The fork's schema accepts explicit `null` for
  /// [expiresAt]/[password] (which clears them), while omitted keys leave the
  /// field untouched — so clearing is opt-in via the flags.
  Future<void> updateShareLink(
    String shareLinkId, {
    String? expiresAt,
    String? password,
    bool? isEnabled,
    bool clearExpiresAt = false,
    bool clearPassword = false,
  }) {
    return _run(() => dio.patch(
          _orgPath('/share-links/$shareLinkId'),
          data: {
            if (clearExpiresAt) 'expiresAt': null else 'expiresAt': ?expiresAt,
            if (clearPassword) 'password': null else 'password': ?password,
            'isEnabled': ?isEnabled,
          },
        ));
  }

  Future<void> deleteShareLink(String shareLinkId) {
    return _run(() => dio.delete(_orgPath('/share-links/$shareLinkId')));
  }

  // ── Custom properties ─────────────────────────────────────────────────────

  Future<List<PapraCustomProperty>> listCustomProperties() {
    return _run(() async {
      final resp = await dio.get(_orgPath('/custom-properties'));
      return asList(resp.data, 'propertyDefinitions')
          .map(PapraCustomProperty.fromJson)
          .toList();
    });
  }

  /// Creates a property definition. For `select`/`multi_select` types, pass
  /// the option names via [options] — the fork requires them at creation.
  Future<void> createCustomProperty({
    required String name,
    required String type,
    String? description,
    List<String> options = const [],
  }) {
    return _run(() => dio.post(
          _orgPath('/custom-properties'),
          data: {
            'name': name,
            'type': type,
            'description': ?description,
            if (options.isNotEmpty)
              'options': options.map((o) => {'name': o}).toList(),
          },
        ));
  }

  Future<void> deleteCustomProperty(String propertyId) {
    return _run(() => dio.delete(_orgPath('/custom-properties/$propertyId')));
  }

  /// Sets a document's value for a property definition. The value shape
  /// depends on the property type (e.g. string for text, option id for select).
  Future<void> setDocumentCustomProperty(
    String documentId, {
    required String propertyId,
    required Object value,
  }) {
    return _run(() => dio.put(
          _orgPath('/documents/$documentId/custom-properties/$propertyId'),
          data: {'value': value},
        ));
  }

  Future<void> deleteDocumentCustomProperty(String documentId, String propertyId) {
    return _run(
      () => dio.delete(_orgPath('/documents/$documentId/custom-properties/$propertyId')),
    );
  }

  /// Aggregated custom-property values for a document (fork key: `customProperties`).
  Future<List<PapraCustomPropertyValue>> getDocumentCustomProperties(String documentId) {
    return _run(() async {
      final resp = await dio.get(_orgPath('/documents/$documentId/custom-properties'));
      return asList(resp.data, 'customProperties')
          .map(PapraCustomPropertyValue.fromJson)
          .toList();
    });
  }

  // ── Intake emails (session auth) ──────────────────────────────────────────

  Future<List<PapraIntakeEmail>> listIntakeEmails() {
    return _run(() async {
      final resp = await sessionDio.get(_orgPath('/intake-emails'));
      return asList(resp.data, 'intakeEmails').map(PapraIntakeEmail.fromJson).toList();
    }, notifyAuthFailure: false);
  }

  /// The fork's create route takes no body — the address is generated
  /// server-side.
  Future<void> createIntakeEmail() {
    return _run(
      () => sessionDio.post(_orgPath('/intake-emails')),
      notifyAuthFailure: false,
    );
  }

  Future<void> updateIntakeEmail(
    String intakeEmailId, {
    bool? isEnabled,
    List<String>? allowedOrigins,
  }) {
    return _run(
      () => sessionDio.put(
        _orgPath('/intake-emails/$intakeEmailId'),
        data: {'isEnabled': ?isEnabled, 'allowedOrigins': ?allowedOrigins},
      ),
      notifyAuthFailure: false,
    );
  }

  Future<void> deleteIntakeEmail(String intakeEmailId) {
    return _run(
      () => sessionDio.delete(_orgPath('/intake-emails/$intakeEmailId')),
      notifyAuthFailure: false,
    );
  }

  // ── Tagging rules (session auth) ──────────────────────────────────────────

  Future<List<PapraTaggingRule>> listTaggingRules() {
    return _run(() async {
      final resp = await sessionDio.get(_orgPath('/tagging-rules'));
      return asList(resp.data, 'taggingRules').map(PapraTaggingRule.fromJson).toList();
    }, notifyAuthFailure: false);
  }

  /// [conditionMatchMode] is `all` or `any`; [tagIds] must be non-empty.
  Future<void> createTaggingRule({
    required String name,
    String? description,
    required bool enabled,
    String conditionMatchMode = 'all',
    required List<PapraTaggingCondition> conditions,
    required List<String> tagIds,
  }) {
    return _run(
      () => sessionDio.post(
        _orgPath('/tagging-rules'),
        data: {
          'name': name,
          'description': ?description,
          'enabled': enabled,
          'conditionMatchMode': conditionMatchMode,
          'conditions': conditions.map((c) => c.toJson()).toList(),
          'tagIds': tagIds,
        },
      ),
      notifyAuthFailure: false,
    );
  }

  Future<void> updateTaggingRule(
    String ruleId, {
    String? name,
    String? description,
    bool? enabled,
    String? conditionMatchMode,
    List<PapraTaggingCondition>? conditions,
    List<String>? tagIds,
  }) {
    return _run(
      () => sessionDio.put(
        _orgPath('/tagging-rules/$ruleId'),
        data: {
          'name': ?name,
          'description': ?description,
          'enabled': ?enabled,
          'conditionMatchMode': ?conditionMatchMode,
          'conditions': conditions?.map((c) => c.toJson()).toList(),
          'tagIds': tagIds,
        },
      ),
      notifyAuthFailure: false,
    );
  }

  Future<void> deleteTaggingRule(String ruleId) {
    return _run(
      () => sessionDio.delete(_orgPath('/tagging-rules/$ruleId')),
      notifyAuthFailure: false,
    );
  }

  /// Enqueues applying the rule to existing documents. Returns the background
  /// task id (fork: `POST /tagging-rules/:id/apply`, 202 with `{taskId}`).
  Future<String> applyTaggingRuleToExisting(String ruleId) {
    return _run(
      () async {
        final resp = await sessionDio.post(_orgPath('/tagging-rules/$ruleId/apply'));
        return asMap(resp.data)['taskId']?.toString() ?? '';
      },
      notifyAuthFailure: false,
    );
  }
}
