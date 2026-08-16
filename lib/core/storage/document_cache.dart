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
///
/// A single shared instance is used app-wide; expose it via
/// [documentCacheProvider].
class DocumentCache {
  // Public so tests can subclass it with an in-memory stub; the app itself
  // always uses [instance].
  DocumentCache();

  static final DocumentCache instance = DocumentCache();

  Directory? _filesDir;
  Directory? _jsonDir;
  File? _offlineIndexFile;
  Set<String> _pinnedIds = {};
  Future<void>? _initFuture;

  /// Maximum number of JSON snapshots kept (oldest evicted by mtime).
  static const int _maxJsonEntries = 50;

  Future<void> init() {
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    final base = await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/papra');
    _filesDir = Directory('${root.path}/files');
    _jsonDir = Directory('${root.path}/json');
    await _filesDir!.create(recursive: true);
    await _jsonDir!.create(recursive: true);
    _offlineIndexFile = File('${root.path}/offline_index.json');
    await _loadPinnedIndex();
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
    final dir = _filesDir!;
    final candidates = dir.listSync().whereType<File>().where((f) {
      final name = f.uri.pathSegments.last;
      return name == documentId || name.startsWith('$documentId.');
    });
    for (final file in candidates) {
      if (await file.exists()) return file.path;
    }
    return null;
  }

  /// Atomically moves a freshly downloaded `.part` file into the cache.
  Future<void> finalizeDownload(String partPath, String finalPath) async {
    await init();
    final part = File(partPath);
    if (await part.exists()) {
      await part.rename(finalPath);
    }
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
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (files.length <= _maxJsonEntries) return;
    for (final file in files.skip(_maxJsonEntries)) {
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
