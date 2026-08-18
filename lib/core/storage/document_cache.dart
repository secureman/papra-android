import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent on-device cache (Google-Drive-style offline):
///
///  * **File blobs** — original files land in `<appDocs>/papra/files` so
///    previously opened documents open instantly and work offline.
///  * **Pinned index** — the explicit "available offline" set, persisted in
///    `<appDocs>/papra/offline_index.json`.
///  * **JSON snapshots** — list/search responses cached per key in
///    `<appDocs>/papra/json`, so browsing paints from cache first.
///  * **Thumbnails** — small pre-rendered PNGs in `<appDocs>/papra/thumbs`
///    so document lists paint instantly without re-downloading originals.
///
/// All lookups are backed by an in-memory index built with async directory
/// listing — no synchronous I/O on the UI thread. A single shared instance is
/// used app-wide; expose it via [documentCacheProvider].
class DocumentCache {
  // Public so tests can subclass it with an in-memory stub; the app itself
  // always uses [instance].
  DocumentCache();

  static final DocumentCache instance = DocumentCache();

  Directory? _filesDir;
  Directory? _jsonDir;
  Directory? _thumbsDir;
  File? _offlineIndexFile;
  Set<String> _pinnedIds = {};

  /// documentId → cached file path, kept in sync with [Directory.list].
  /// Lookups are O(1) instead of a blocking `listSync` per document.
  final Map<String, String> _fileIndex = {};
  Future<void>? _initFuture;

  /// Maximum number of JSON snapshots kept (oldest evicted by mtime).
  static const int _maxJsonEntries = 50;

  /// Thumbnail PNGs are tiny (~10–50 KB), so they are simply kept; the JSON
  /// eviction already bounds the metadata cache.
  static const int _maxThumbnailEntries = 500;

  Future<void> init() {
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    final base = await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/papra');
    _filesDir = Directory('${root.path}/files');
    _jsonDir = Directory('${root.path}/json');
    _thumbsDir = Directory('${root.path}/thumbs');
    await _filesDir!.create(recursive: true);
    await _jsonDir!.create(recursive: true);
    await _thumbsDir!.create(recursive: true);
    _offlineIndexFile = File('${root.path}/offline_index.json');
    await _indexFiles();
    await _loadPinnedIndex();
  }

  /// Builds the in-memory file index from disk (async, non-blocking).
  Future<void> _indexFiles() async {
    final dir = _filesDir;
    if (dir == null) return;
    _fileIndex.clear();
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      final id = dot > 0 ? name.substring(0, dot) : name;
      if (id.isNotEmpty) _fileIndex[id] = entity.path;
    }
  }

  Future<void> _loadPinnedIndex() async {
    final file = _offlineIndexFile;
    if (file == null || !await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        _pinnedIds = data.keys.cast<String>().toSet();
      }
    } catch (_) {
      _pinnedIds = {};
    }
  }

  Future<void> _persistPinnedIndex() async {
    final file = _offlineIndexFile;
    if (file == null) return;
    final payload = {for (final id in _pinnedIds) id: ''};
    await file.writeAsString(jsonEncode(payload));
  }

  // ── File blobs ────────────────────────────────────────────────────────────

  String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot > 0 && dot < fileName.length - 1 && fileName.length - dot <= 10) {
      return fileName.substring(dot).toLowerCase();
    }
    return '.bin';
  }

  /// The path a file should be downloaded to so it becomes cached.
  Future<String> downloadPathFor(String documentId, String fileName) async {
    await init();
    return '${_filesDir!.path}/$documentId${_extensionOf(fileName)}';
  }

  /// Path of the cached file for [documentId], or null when not cached.
  Future<String?> cachedFilePath(String documentId) async {
    await init();
    final path = _fileIndex[documentId];
    if (path == null) return null;
    if (await File(path).exists()) return path;
    // Stale index entry (file deleted out-of-band) — drop and re-scan.
    _fileIndex.remove(documentId);
    await _indexFiles();
    return _fileIndex[documentId];
  }

  /// Atomically moves a freshly downloaded `.part` file into the cache.
  Future<void> finalizeDownload(String partPath, String finalPath) async {
    await init();
    final part = File(partPath);
    if (await part.exists()) {
      await part.rename(finalPath);
    }
    final name = finalPath.split('/').last;
    final dot = name.lastIndexOf('.');
    final id = dot > 0 ? name.substring(0, dot) : name;
    if (id.isNotEmpty) _fileIndex[id] = finalPath;
  }

  /// Deletes a cached file (used when unpinning, to actually free space).
  Future<void> deleteCachedFile(String documentId) async {
    final path = await cachedFilePath(documentId);
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {
        // Best effort.
      }
      _fileIndex.remove(documentId);
    }
  }

  // ── Pinned ("available offline") ──────────────────────────────────────────

  Future<Set<String>> getPinnedIds() async {
    await init();
    return {..._pinnedIds};
  }

  Future<void> setPinned(String documentId, {required bool pinned}) async {
    await init();
    if (pinned) {
      _pinnedIds.add(documentId);
    } else {
      _pinnedIds.remove(documentId);
    }
    await _persistPinnedIndex();
  }

  // ── JSON snapshots ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> readJson(String key) async {
    await init();
    final file = File('${_jsonDir!.path}/${_safeKey(key)}.json');
    if (!await file.exists()) return null;
    try {
      final data = jsonDecode(await file.readAsString());
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(String key, Map<String, dynamic> data) async {
    await init();
    final file = File('${_jsonDir!.path}/${_safeKey(key)}.json');
    // Keys nest under directories (e.g. `docs/search/<org>/<query>/...`), so
    // the parent must be created or the write fails with "no such directory"
    // and the offline cache silently never gets written.
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(data));
    await _evictOldJsonIfNeeded(_jsonDir!);
  }

  /// Path-fixes a cache key: keeps intentional directory nesting while
  /// preventing empty segments (double slashes) and directory traversal.
  static String _safeKey(String key) => key
      .split('/')
      .map((segment) => segment.isEmpty || segment == '.' || segment == '..' ? '_' : segment)
      .join('/');

  Future<void> _evictOldJsonIfNeeded(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (files.length <= _maxJsonEntries) return;
    for (final file in files.skip(_maxJsonEntries)) {
      try {
        await file.delete();
      } catch (_) {
        // Best effort.
      }
    }
  }

  // ── Thumbnails ────────────────────────────────────────────────────────────

  /// Path of the persisted thumbnail PNG for [documentId], or null when the
  /// thumbnail has not been generated yet.
  Future<String?> thumbnailPath(String documentId) async {
    await init();
    final file = File('${_thumbsDir!.path}/$documentId.png');
    if (await file.exists()) return file.path;
    return null;
  }

  /// Persists a pre-rendered thumbnail PNG for [documentId].
  Future<void> writeThumbnail(String documentId, List<int> pngBytes) async {
    await init();
    final file = File('${_thumbsDir!.path}/$documentId.png');
    await file.writeAsBytes(pngBytes, flush: true);
    await _evictOldThumbnailsIfNeeded();
  }

  Future<void> _evictOldThumbnailsIfNeeded() async {
    final dir = _thumbsDir;
    if (dir == null) return;
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) files.add(entity);
    }
    if (files.length <= _maxThumbnailEntries) return;
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final file in files.skip(_maxThumbnailEntries)) {
      try {
        await file.delete();
      } catch (_) {
        // Best effort.
      }
    }
  }
}

final documentCacheProvider = Provider<DocumentCache>((ref) => DocumentCache.instance);

/// Reactive view of which documents are pinned "available offline".
final offlineDocumentsProvider =
    NotifierProvider<OfflineDocumentsController, Set<String>>(OfflineDocumentsController.new);

class OfflineDocumentsController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    _load();
    return const {};
  }

  Future<void> _load() async {
    final cache = ref.read(documentCacheProvider);
    state = await cache.getPinnedIds();
  }

  Future<void> setPinned(String documentId, {required bool pinned}) async {
    final cache = ref.read(documentCacheProvider);
    await cache.setPinned(documentId, pinned: pinned);
    state = await cache.getPinnedIds();
  }
}
