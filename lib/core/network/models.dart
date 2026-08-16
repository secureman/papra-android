import 'dart:convert';

/// Coerces a Dio response body into a JSON object, handling both already-parsed
/// maps and raw JSON strings.
Map<String, dynamic> asMap(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is String) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Fall through.
    }
  }
  return const {};
}

List<Map<String, dynamic>> asList(Object? data, String key) {
  final map = asMap(data);
  final raw = map[key];
  if (raw is List) {
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }
  return const [];
}

String _str(Map<String, dynamic> m, String k) => (m[k] as String?) ?? '';
bool _bool(Map<String, dynamic> m, String k, [bool d = false]) => (m[k] as bool?) ?? d;
int _int(Map<String, dynamic> m, String k, [int d = 0]) => (m[k] as num?)?.toInt() ?? d;
String? _optStr(Map<String, dynamic> m, String k) => m[k] as String?;
int? _optInt(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt();

Map<String, dynamic> _objMap(Map<String, dynamic> m, String k) =>
    (m[k] as Map?)?.map((key, value) => MapEntry(key.toString(), value)) ?? const {};

List<String> _strList(Map<String, dynamic> m, String k) =>
    (m[k] as List?)?.map((e) => e.toString()).toList() ?? const [];

// ── Auth ────────────────────────────────────────────────────────────────────

class SignInRequest {
  const SignInRequest({required this.email, required this.password, required this.rememberMe});

  final String email;
  final String password;
  final bool rememberMe;

  Map<String, dynamic> toJson() => {
        'email': email,
        'password': password,
        'rememberMe': rememberMe,
      };
}

class PapraOrganization {
  const PapraOrganization({required this.id, required this.name});

  factory PapraOrganization.fromJson(Map<String, dynamic> json) =>
      PapraOrganization(id: _str(json, 'id'), name: _str(json, 'name'));

  final String id;
  final String name;
}

class OrganizationsResponse {
  const OrganizationsResponse({required this.organizations});

  factory OrganizationsResponse.fromJson(Map<String, dynamic> json) =>
      OrganizationsResponse(
        organizations: asList(json, 'organizations')
            .map(PapraOrganization.fromJson)
            .toList(),
      );

  final List<PapraOrganization> organizations;
}

class DeviceApiKeyRequest {
  const DeviceApiKeyRequest({required this.name, required this.permissions});

  final String name;
  final List<String> permissions;

  Map<String, dynamic> toJson() => {'name': name, 'permissions': permissions};
}

/// Response of the device-key minting endpoint.
///
/// The fork returns the token at the top level: `{apiKey: {...}, token: "..."}`.
/// The nested `{apiKey: {token: "..."}}` shape is kept as a fallback.
class DeviceApiKeyResponse {
  const DeviceApiKeyResponse({required this.token});

  factory DeviceApiKeyResponse.fromJson(Map<String, dynamic> json) {
    final topLevelToken = _optStr(json, 'token');
    if (topLevelToken != null && topLevelToken.isNotEmpty) {
      return DeviceApiKeyResponse(token: topLevelToken);
    }
    final apiKey = json['apiKey'];
    final nestedToken = apiKey is Map<String, dynamic> ? _str(apiKey, 'token') : '';
    return DeviceApiKeyResponse(token: nestedToken);
  }

  final String token;
}

// ── Documents ───────────────────────────────────────────────────────────────

class PapraTag {
  const PapraTag({required this.id, required this.name, this.color = '', this.description});

  factory PapraTag.fromJson(Map<String, dynamic> json) => PapraTag(
        id: _str(json, 'id'),
        name: _str(json, 'name'),
        color: _str(json, 'color'),
        description: _optStr(json, 'description'),
      );

  final String id;
  final String name;
  final String color;
  final String? description;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        if (description != null) 'description': description,
      };
}

/// A single custom-property value embedded in an enriched document.
///
/// The fork returns these as an array of `{key, name, type, displayOrder,
/// value}` entries (see `buildCustomPropertiesArray`), not as a map.
class PapraCustomPropertyValue {
  const PapraCustomPropertyValue({
    required this.key,
    required this.name,
    required this.type,
    this.displayOrder = 0,
    this.value,
  });

  factory PapraCustomPropertyValue.fromJson(Map<String, dynamic> json) =>
      PapraCustomPropertyValue(
        key: _str(json, 'key'),
        name: _str(json, 'name'),
        type: _str(json, 'type'),
        displayOrder: _int(json, 'displayOrder'),
        value: json['value'],
      );

  final String key;
  final String name;
  final String type;
  final int displayOrder;

  /// Per-type value: String for text, num for number, bool for boolean,
  /// `{optionId, name}` for select, etc. Null when unset.
  final dynamic value;

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'type': type,
        'displayOrder': displayOrder,
        'value': value,
      };
}

class PapraDocument {
  const PapraDocument({
    required this.id,
    required this.name,
    required this.createdAt,
    this.size = 0,
    this.mimeType = '',
    this.tags = const [],
    this.customProperties = const [],
    this.folderId,
    this.content = '',
    this.notes,
    this.documentDate,
    this.isDeleted = false,
    this.deletedAt,
    this.updatedAt,
  });

  factory PapraDocument.fromJson(Map<String, dynamic> json) => PapraDocument(
        id: _str(json, 'id'),
        name: _str(json, 'name'),
        createdAt: _str(json, 'createdAt'),
        size: _int(json, 'originalSize'),
        mimeType: _str(json, 'mimeType'),
        tags: asList(json, 'tags').map(PapraTag.fromJson).toList(),
        customProperties: asList(json, 'customProperties')
            .map(PapraCustomPropertyValue.fromJson)
            .toList(),
        folderId: _optStr(json, 'folderId'),
        content: _str(json, 'content'),
        notes: _optStr(json, 'notes'),
        documentDate: _optStr(json, 'documentDate'),
        isDeleted: _bool(json, 'isDeleted'),
        deletedAt: _optStr(json, 'deletedAt'),
        updatedAt: _optStr(json, 'updatedAt'),
      );

  final String id;
  final String name;
  final String createdAt;

  /// Byte size of the original file (fork field: `originalSize`).
  final int size;
  final String mimeType;
  final List<PapraTag> tags;
  final List<PapraCustomPropertyValue> customProperties;
  final String? folderId;

  /// Extracted text/content of the document.
  final String content;
  final String? notes;
  final String? documentDate;
  final bool isDeleted;
  final String? deletedAt;
  final String? updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'originalSize': size,
        'mimeType': mimeType,
        'tags': tags.map((t) => t.toJson()).toList(),
        'customProperties': customProperties.map((p) => p.toJson()).toList(),
        if (folderId != null) 'folderId': folderId,
        'content': content,
        if (notes != null) 'notes': notes,
        if (documentDate != null) 'documentDate': documentDate,
        'isDeleted': isDeleted,
        if (deletedAt != null) 'deletedAt': deletedAt,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };
}

class DocumentsResponse {
  const DocumentsResponse({required this.documents, this.documentsCount = 0});

  factory DocumentsResponse.fromJson(Map<String, dynamic> json) => DocumentsResponse(
        documents: asList(json, 'documents').map(PapraDocument.fromJson).toList(),
        documentsCount: _int(json, 'documentsCount'),
      );

  final List<PapraDocument> documents;
  final int documentsCount;
}

// ── Tags ────────────────────────────────────────────────────────────────────

class TagsResponse {
  const TagsResponse({required this.tags});

  factory TagsResponse.fromJson(Map<String, dynamic> json) =>
      TagsResponse(tags: asList(json, 'tags').map(PapraTag.fromJson).toList());

  final List<PapraTag> tags;
}

// ── Folders ─────────────────────────────────────────────────────────────────

class PapraFolder {
  const PapraFolder({
    required this.id,
    required this.name,
    this.parentId,
    this.createdAt,
    this.documentsCount = 0,
  });

  factory PapraFolder.fromJson(Map<String, dynamic> json) => PapraFolder(
        id: _str(json, 'id'),
        name: _str(json, 'name'),
        parentId: _optStr(json, 'parentId'),
        createdAt: _optStr(json, 'createdAt'),
        documentsCount: _int(json, 'documentsCount'),
      );

  final String id;
  final String name;
  final String? parentId;
  final String? createdAt;

  /// Direct (non-deleted) document count, returned by the org folders list.
  final int documentsCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (parentId != null) 'parentId': parentId,
        if (createdAt != null) 'createdAt': createdAt,
        'documentsCount': documentsCount,
      };
}

class FoldersResponse {
  const FoldersResponse({required this.folders});

  factory FoldersResponse.fromJson(Map<String, dynamic> json) =>
      FoldersResponse(folders: asList(json, 'folders').map(PapraFolder.fromJson).toList());

  final List<PapraFolder> folders;
}

class FolderContentsResponse {
  const FolderContentsResponse({required this.folders, required this.documents});

  factory FolderContentsResponse.fromJson(Map<String, dynamic> json) =>
      FolderContentsResponse(
        folders: asList(json, 'folders').map(PapraFolder.fromJson).toList(),
        documents: asList(json, 'documents').map(PapraDocument.fromJson).toList(),
      );

  final List<PapraFolder> folders;
  final List<PapraDocument> documents;
}

// ── Sharing ─────────────────────────────────────────────────────────────────

class PapraShareLink {
  const PapraShareLink({
    required this.id,
    required this.documentId,
    required this.url,
    this.token = '',
    this.isPasswordProtected = false,
    this.isEnabled = true,
    this.expiresAt,
    this.lastAccessedAt,
    this.createdAt,
    this.documentName,
    this.isDocumentDeleted = false,
  });

  factory PapraShareLink.fromJson(Map<String, dynamic> json) => PapraShareLink(
        id: _str(json, 'id'),
        documentId: _str(json, 'documentId'),
        url: _str(json, 'url'),
        token: _str(json, 'token'),
        isPasswordProtected: _bool(json, 'isPasswordProtected'),
        isEnabled: _bool(json, 'isEnabled', true),
        expiresAt: _optStr(json, 'expiresAt'),
        lastAccessedAt: _optStr(json, 'lastAccessedAt'),
        createdAt: _optStr(json, 'createdAt'),
        // The fork's org-scoped list joins the document name + trashed state
        // so the UI can display them without a second round-trip.
        documentName: _optStr(json, 'documentName'),
        isDocumentDeleted: _bool(json, 'isDocumentDeleted'),
      );

  final String id;
  final String documentId;
  final String url;

  /// Share token, used to build the public share URL (`<base>/share/<token>`).
  final String token;
  final bool isPasswordProtected;
  final bool isEnabled;
  final String? expiresAt;
  final String? lastAccessedAt;
  final String? createdAt;
  final String? documentName;
  final bool isDocumentDeleted;
}

class ShareLinksResponse {
  const ShareLinksResponse({required this.shareLinks});

  factory ShareLinksResponse.fromJson(Map<String, dynamic> json) =>
      ShareLinksResponse(shareLinks: asList(json, 'shareLinks').map(PapraShareLink.fromJson).toList());

  final List<PapraShareLink> shareLinks;
}

// ── Custom properties ───────────────────────────────────────────────────────

/// A custom-property definition (fork key in list responses: `propertyDefinitions`).
class PapraCustomProperty {
  const PapraCustomProperty({
    required this.id,
    required this.name,
    required this.key,
    required this.type,
    this.description,
    this.displayOrder = 0,
  });

  factory PapraCustomProperty.fromJson(Map<String, dynamic> json) => PapraCustomProperty(
        id: _str(json, 'id'),
        name: _str(json, 'name'),
        key: _str(json, 'key'),
        type: _str(json, 'type'),
        description: _optStr(json, 'description'),
        displayOrder: _int(json, 'displayOrder'),
      );

  final String id;
  final String name;
  final String key;

  /// "text" | "number" | "date" | "boolean" | "select" | "multi_select" |
  /// "user_relation" | "document_relation"
  final String type;
  final String? description;
  final int displayOrder;
}

// ── Intake emails ───────────────────────────────────────────────────────────

class PapraIntakeEmail {
  const PapraIntakeEmail({
    required this.id,
    required this.emailAddress,
    this.enabled = true,
    this.createdAt,
    this.allowedOrigins = const [],
  });

  factory PapraIntakeEmail.fromJson(Map<String, dynamic> json) => PapraIntakeEmail(
        id: _str(json, 'id'),
        emailAddress: _str(json, 'emailAddress'),
        enabled: _bool(json, 'isEnabled', true),
        createdAt: _optStr(json, 'createdAt'),
        allowedOrigins: _strList(json, 'allowedOrigins'),
      );

  final String id;

  /// Inbox address the organization receives documents at (fork field: `emailAddress`).
  final String emailAddress;
  final bool enabled;
  final String? createdAt;
  final List<String> allowedOrigins;
}

// ── Tagging rules ───────────────────────────────────────────────────────────

class PapraTaggingCondition {
  const PapraTaggingCondition({
    required this.field,
    required this.operator,
    required this.value,
    this.isCaseSensitive = false,
  });

  factory PapraTaggingCondition.fromJson(Map<String, dynamic> json) => PapraTaggingCondition(
        field: _str(json, 'field'),
        operator: _str(json, 'operator'),
        value: _str(json, 'value'),
        isCaseSensitive: _bool(json, 'isCaseSensitive'),
      );

  /// "name" | "content"
  final String field;

  /// "equal" | "not_equal" | "contains" | "not_contains" |
  /// "starts_with" | "ends_with"
  final String operator;
  final String value;
  final bool isCaseSensitive;

  /// Only field/operator/value are sent — the fork's condition schema is
  /// strict and rejects extra keys.
  Map<String, dynamic> toJson() => {'field': field, 'operator': operator, 'value': value};
}

// ── Backups ─────────────────────────────────────────────────────────────────

/// A supported backup destination driver (`google_drive` | `webdav` | `ftp` | `local`).
class PapraBackupDriver {
  const PapraBackupDriver({required this.name, required this.isConfigured});

  factory PapraBackupDriver.fromJson(Map<String, dynamic> json) => PapraBackupDriver(
        name: _str(json, 'name'),
        isConfigured: _bool(json, 'isConfigured'),
      );

  final String name;
  final bool isConfigured;
}

/// Response of `GET /api/backups/drivers` (global, not org-scoped).
class BackupsStatusResponse {
  const BackupsStatusResponse({required this.isConfigured, required this.drivers});

  factory BackupsStatusResponse.fromJson(Map<String, dynamic> json) => BackupsStatusResponse(
        isConfigured: _bool(json, 'isConfigured'),
        drivers: asList(json, 'drivers').map(PapraBackupDriver.fromJson).toList(),
      );

  /// Whether the server has `BACKUPS_KEK` set (the whole feature is disabled otherwise).
  final bool isConfigured;
  final List<PapraBackupDriver> drivers;
}

class PapraBackupSchedule {
  const PapraBackupSchedule({
    this.isEnabled = false,
    this.days = const [],
    this.hour,
    this.minute,
  });

  factory PapraBackupSchedule.fromJson(Map<String, dynamic> json) => PapraBackupSchedule(
        isEnabled: _bool(json, 'isEnabled'),
        days: (json['days'] as List?)?.map((e) => (e as num).toInt()).toList() ?? const [],
        hour: _optInt(json, 'hour'),
        minute: _optInt(json, 'minute'),
      );

  final bool isEnabled;

  /// Weekday ints, 0 (Sunday) to 6 (Saturday); empty = every day.
  final List<int> days;
  final int? hour;
  final int? minute;

  Map<String, dynamic> toJson() =>
      {'isEnabled': isEnabled, 'days': days, 'hour': hour, 'minute': minute};
}

/// A configured backup destination. Secrets are never sent to the client —
/// only the non-secret `settings` and `accountLabel` are returned.
class PapraBackupDestination {
  const PapraBackupDestination({
    required this.id,
    required this.driver,
    required this.displayName,
    this.settings = const {},
    this.accountLabel,
    this.isEnabled = true,
    this.schedule = const PapraBackupSchedule(),
    this.lastRunAt,
    this.nextScheduledAt,
    this.createdAt = '',
  });

  factory PapraBackupDestination.fromJson(Map<String, dynamic> json) =>
      PapraBackupDestination(
        id: _str(json, 'id'),
        driver: _str(json, 'driver'),
        displayName: _str(json, 'displayName'),
        settings: _objMap(json, 'settings'),
        accountLabel: _optStr(json, 'accountLabel'),
        isEnabled: _bool(json, 'isEnabled', true),
        schedule: json['schedule'] is Map<String, dynamic>
            ? PapraBackupSchedule.fromJson(json['schedule'] as Map<String, dynamic>)
            : const PapraBackupSchedule(),
        lastRunAt: _optStr(json, 'lastRunAt'),
        nextScheduledAt: _optStr(json, 'nextScheduledAt'),
        createdAt: _str(json, 'createdAt'),
      );

  final String id;
  final String driver;
  final String displayName;
  final Map<String, dynamic> settings;
  final String? accountLabel;
  final bool isEnabled;
  final PapraBackupSchedule schedule;
  final String? lastRunAt;
  final String? nextScheduledAt;
  final String createdAt;
}

class PapraBackupRun {
  const PapraBackupRun({
    required this.id,
    this.trigger = '',
    this.status = '',
    this.remoteFileId,
    this.remoteFileName,
    this.documentsCount,
    this.totalSizeBytes,
    this.errorMessage,
    this.completedAt,
    this.createdAt = '',
  });

  factory PapraBackupRun.fromJson(Map<String, dynamic> json) => PapraBackupRun(
        id: _str(json, 'id'),
        trigger: _str(json, 'trigger'),
        status: _str(json, 'status'),
        remoteFileId: _optStr(json, 'remoteFileId'),
        remoteFileName: _optStr(json, 'remoteFileName'),
        documentsCount: _optInt(json, 'documentsCount'),
        totalSizeBytes: _optInt(json, 'totalSizeBytes'),
        errorMessage: _optStr(json, 'errorMessage'),
        completedAt: _optStr(json, 'completedAt'),
        createdAt: _str(json, 'createdAt'),
      );

  final String id;

  /// "manual" | "scheduled"
  final String trigger;

  /// "pending" | "uploading" | "succeeded" | "failed"
  final String status;
  final String? remoteFileId;
  final String? remoteFileName;
  final int? documentsCount;
  final int? totalSizeBytes;
  final String? errorMessage;
  final String? completedAt;
  final String createdAt;
}

/// A background restore job, polled for progress (fork: `backups/restore-jobs/*`).
class PapraBackupRestoreJob {
  const PapraBackupRestoreJob({
    required this.id,
    this.source = '',
    this.status = '',
    this.destinationId,
    this.runId,
    this.totalDocumentsCount,
    this.processedDocumentsCount = 0,
    this.downloadedBytes,
    this.totalBytes,
    this.restoredDocumentsCount,
    this.untrashedDocumentsCount,
    this.skippedDuplicatesCount,
    this.errorMessage,
    this.startedAt,
    this.completedAt,
    this.createdAt = '',
  });

  factory PapraBackupRestoreJob.fromJson(Map<String, dynamic> json) => PapraBackupRestoreJob(
        id: _str(json, 'id'),
        source: _str(json, 'source'),
        status: _str(json, 'status'),
        destinationId: _optStr(json, 'destinationId'),
        runId: _optStr(json, 'runId'),
        totalDocumentsCount: _optInt(json, 'totalDocumentsCount'),
        processedDocumentsCount: _int(json, 'processedDocumentsCount'),
        downloadedBytes: _optInt(json, 'downloadedBytes'),
        totalBytes: _optInt(json, 'totalBytes'),
        restoredDocumentsCount: _optInt(json, 'restoredDocumentsCount'),
        untrashedDocumentsCount: _optInt(json, 'untrashedDocumentsCount'),
        skippedDuplicatesCount: _optInt(json, 'skippedDuplicatesCount'),
        errorMessage: _optStr(json, 'errorMessage'),
        startedAt: _optStr(json, 'startedAt'),
        completedAt: _optStr(json, 'completedAt'),
        createdAt: _str(json, 'createdAt'),
      );

  final String id;

  /// "run" | "remote_file" | "uploaded_file"
  final String source;

  /// "pending" | "downloading" | "restoring" | "succeeded" | "failed"
  final String status;
  final String? destinationId;
  final String? runId;
  final int? totalDocumentsCount;
  final int processedDocumentsCount;
  final int? downloadedBytes;
  final int? totalBytes;
  final int? restoredDocumentsCount;
  final int? untrashedDocumentsCount;
  final int? skippedDuplicatesCount;
  final String? errorMessage;
  final String? startedAt;
  final String? completedAt;
  final String createdAt;
}

/// A backup file as reported by the destination driver
/// (fork: `{remoteFileId, name, size?, modifiedAt?}`).
class PapraBackupRemoteFile {
  const PapraBackupRemoteFile({
    required this.remoteFileId,
    required this.name,
    this.size,
    this.modifiedAt,
  });

  factory PapraBackupRemoteFile.fromJson(Map<String, dynamic> json) => PapraBackupRemoteFile(
        remoteFileId: _str(json, 'remoteFileId'),
        name: _str(json, 'name'),
        size: _optInt(json, 'size'),
        modifiedAt: _optStr(json, 'modifiedAt'),
      );

  final String remoteFileId;
  final String name;
  final int? size;
  final String? modifiedAt;
}

/// Result of verifying a backup run's integrity (document hash checks).
class PapraBackupVerifyResult {
  const PapraBackupVerifyResult({
    required this.valid,
    this.totalDocuments = 0,
    this.validDocuments = 0,
    this.invalidDocuments = 0,
    this.errors = const [],
  });

  factory PapraBackupVerifyResult.fromJson(Map<String, dynamic> json) => PapraBackupVerifyResult(
        valid: _bool(json, 'valid'),
        totalDocuments: _int(json, 'totalDocuments'),
        validDocuments: _int(json, 'validDocuments'),
        invalidDocuments: _int(json, 'invalidDocuments'),
        errors: _strList(json, 'errors'),
      );

  final bool valid;
  final int totalDocuments;
  final int validDocuments;
  final int invalidDocuments;
  final List<String> errors;
}

class PapraTaggingRule {
  const PapraTaggingRule({
    required this.id,
    required this.name,
    this.description,
    this.enabled = true,
    this.conditionMatchMode = 'all',
    this.conditions = const [],
    this.tagIds = const [],
  });

  factory PapraTaggingRule.fromJson(Map<String, dynamic> json) {
    // The fork aggregates rules with `actions: [{tagId, tag, ...}]`; some
    // clients may also return a flat `tagIds` array.
    final actions = asList(json, 'actions');
    final tagIds = actions.isNotEmpty
        ? actions.map((a) => _str(a, 'tagId')).where((id) => id.isNotEmpty).toList()
        : _strList(json, 'tagIds');
    return PapraTaggingRule(
      id: _str(json, 'id'),
      name: _str(json, 'name'),
      description: _optStr(json, 'description'),
      enabled: _bool(json, 'enabled', true),
      conditionMatchMode: _str(json, 'conditionMatchMode'),
      conditions: asList(json, 'conditions').map(PapraTaggingCondition.fromJson).toList(),
      tagIds: tagIds,
    );
  }

  final String id;
  final String name;
  final String? description;
  final bool enabled;

  /// "all" | "any"
  final String conditionMatchMode;
  final List<PapraTaggingCondition> conditions;
  final List<String> tagIds;
}
