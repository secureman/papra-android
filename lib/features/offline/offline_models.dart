import 'dart:convert';

import '../../core/network/models.dart';

/// Typed view of the `manifest.json` embedded in every backup archive.
///
/// The server stores tags by name/color and folders as root-to-leaf name
/// paths (ids don't survive a restore to a fresh install), so this model
/// mirrors exactly that shape rather than the live API's id-based one.

class OfflineTagRef {
  const OfflineTagRef({required this.name, this.color = '', this.description});

  factory OfflineTagRef.fromJson(Map<String, dynamic> json) => OfflineTagRef(
        name: _str(json, 'name'),
        color: _str(json, 'color'),
        description: _optStr(json, 'description'),
      );

  final String name;
  final String color;
  final String? description;

  /// Adapter so shared widgets (chips, thumbnails, PDF checks) can consume
  /// offline tags through the same type as online ones.
  PapraTag asPapraTag() => PapraTag(id: 'offline:$name', name: name, color: color, description: description);
}

class OfflineDocument {
  const OfflineDocument({
    required this.id,
    required this.name,
    required this.createdAt,
    this.originalName = '',
    this.mimeType = '',
    this.size = 0,
    this.sha256 = '',
    this.updatedAt,
    this.documentDate,
    this.notes,
    this.folderId,
    this.folderPath = const [],
    this.tags = const [],
  });

  factory OfflineDocument.fromJson(Map<String, dynamic> json) => OfflineDocument(
        id: _str(json, 'id'),
        name: _str(json, 'name'),
        originalName: _str(json, 'originalName'),
        mimeType: _str(json, 'mimeType'),
        size: _int(json, 'originalSize'),
        sha256: _str(json, 'originalSha256Hash'),
        createdAt: _str(json, 'createdAt'),
        updatedAt: _optStr(json, 'updatedAt'),
        documentDate: _optStr(json, 'documentDate'),
        notes: _optStr(json, 'notes'),
        folderId: _optStr(json, 'folderId'),
        folderPath:
            (json['folderPath'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        tags: (json['tags'] as List?)
                ?.whereType<Map>()
                .map((e) => OfflineTagRef.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            const [],
      );

  final String id;
  final String name;

  /// The original file's name inside the archive (`files/<id>-<original>`).
  final String originalName;
  final String mimeType;
  final int size;
  final String sha256;
  final String createdAt;
  final String? updatedAt;
  final String? documentDate;
  final String? notes;
  final String? folderId;

  /// Root-to-leaf folder names; empty when the document sits at the root.
  final List<String> folderPath;
  final List<OfflineTagRef> tags;

  bool get isPdf =>
      name.toLowerCase().endsWith('.pdf') ||
      originalName.toLowerCase().endsWith('.pdf') ||
      mimeType.toLowerCase() == 'application/pdf';

  /// Adapter reusing the online thumbnail/PDF-viewer helpers.
  PapraDocument asPapraDocument() => PapraDocument(
        id: id,
        name: originalName.isNotEmpty ? originalName : name,
        createdAt: createdAt,
        size: size,
        mimeType: mimeType,
        tags: [for (final t in tags) t.asPapraTag()],
        folderId: folderId,
        notes: notes,
        documentDate: documentDate,
      );
}

class OfflineManifest {
  const OfflineManifest({
    required this.organizationId,
    required this.createdAt,
    required this.documents,
    this.schemaVersion = 0,
  });

  factory OfflineManifest.fromJson(Map<String, dynamic> json) => OfflineManifest(
        schemaVersion: _int(json, 'schemaVersion'),
        organizationId: _str(json, 'organizationId'),
        createdAt: _str(json, 'createdAt'),
        documents: (json['documents'] as List?)
                ?.whereType<Map>()
                .map((e) => OfflineDocument.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'organizationId': organizationId,
        'createdAt': createdAt,
        'documents': [
          for (final d in documents)
            {
              'id': d.id,
              'name': d.name,
              'originalName': d.originalName,
              'mimeType': d.mimeType,
              'originalSize': d.size,
              if (d.sha256.isNotEmpty) 'originalSha256Hash': d.sha256,
              'createdAt': d.createdAt,
              if (d.updatedAt != null) 'updatedAt': d.updatedAt,
              if (d.documentDate != null) 'documentDate': d.documentDate,
              if (d.notes != null) 'notes': d.notes,
              if (d.folderId != null) 'folderId': d.folderId,
              if (d.folderPath.isNotEmpty) 'folderPath': d.folderPath,
              'tags': [
                for (final t in d.tags)
                  {
                    'name': t.name,
                    'color': t.color,
                    if (t.description != null) 'description': t.description,
                  },
              ],
            },
        ],
      };

  static OfflineManifest? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return OfflineManifest.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  final int schemaVersion;
  final String organizationId;
  final String createdAt;
  final List<OfflineDocument> documents;
}

String _str(Map<String, dynamic> m, String k) => (m[k] as String?) ?? '';
String? _optStr(Map<String, dynamic> m, String k) => m[k] as String?;
int _int(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;
