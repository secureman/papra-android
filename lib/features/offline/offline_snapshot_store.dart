import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'backup_decoder.dart';
import 'offline_models.dart';

/// On-device store for the single imported backup snapshot.
///
/// Layout under `<appDocs>/papra/offline/`:
///   snapshot/meta.json      — import metadata
///   snapshot/manifest.json  — raw manifest from the archive
///   snapshot/files/…        — extracted original documents
///
/// One snapshot is active at a time: an import extracts into a temporary
/// directory and atomically replaces `snapshot/` only after everything
/// decoded successfully, so a failed import never destroys the previous data.
class OfflineSnapshotStore {
  OfflineSnapshotStore();

  static const _rootDirName = 'offline';
  static const _snapshotDirName = 'snapshot';

  Future<Directory> _root() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}/papra/$_rootDirName');
  }

  Future<Directory?> _snapshotDir() async {
    final dir = Directory('${(await _root()).path}/$_snapshotDirName');
    if (!await dir.exists()) return null;
    return dir;
  }

  Future<File?> _metaFile() async {
    final dir = await _snapshotDir();
    if (dir == null) return null;
    return File('${dir.path}/meta.json');
  }

  Future<File?> _manifestFile() async {
    final dir = await _snapshotDir();
    if (dir == null) return null;
    return File('${dir.path}/manifest.json');
  }

  /// Metadata of the active snapshot, or null when none was imported yet.
  Future<Map<String, dynamic>?> readMeta() async {
    final file = await _metaFile();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<OfflineManifest?> readManifest() async {
    final file = await _manifestFile();
    if (file == null || !await file.exists()) return null;
    return OfflineManifest.tryParse(await file.readAsString());
  }

  /// Resolves the extracted original file for [documentId] by scanning the
  /// snapshot's files directory for the server's `<id>-<name>` entry naming.
  Future<String?> filePathForDocument(String documentId) async {
    final dir = await _snapshotDir();
    if (dir == null) return null;
    final filesDir = Directory('${dir.path}/files');
    if (!await filesDir.exists()) return null;
    await for (final entity in filesDir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('$documentId-')) return entity.path;
    }
    return null;
  }

  Directory? thumbsDirectorySync(Directory snapshotDir) =>
      Directory('${snapshotDir.path}/thumbs');

  /// The active snapshot directory, when present (used by widgets that need
  /// to place derived artifacts such as thumbnail PNGs inside it).
  Future<String?> snapshotPath() async => (await _snapshotDir())?.path;

  /// Deletes the whole offline area: snapshot plus any leftovers. Used by the
  /// "Delete backup" action and failed-import cleanup.
  Future<void> deleteSnapshot() async {
    final dir = await _snapshotDir();
    if (dir != null) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // Best effort.
      }
    }
  }

  /// Extracts [sourcePath] with [hexKek] and installs it as the new active
  /// snapshot, replacing any previously imported one. Throws a
  /// [BackupDecodingException] (user-facing message) on failure; the existing
  /// snapshot is untouched in that case.
  Future<Map<String, dynamic>> importFromFile({
    required String sourcePath,
    required String hexKek,
    ImportProgress? onStage,
  }) async {
    final root = await _root();
    await root.create(recursive: true);
    final incoming = Directory('${root.path}/incoming-${DateTime.now().millisecondsSinceEpoch}');
    try {
      final manifest = await extractBackupToDirectory(
        sourcePath: sourcePath,
        hexKek: hexKek,
        targetDir: incoming.path,
        onStage: onStage,
      );
      final docs = manifest['documents'];
      final meta = <String, dynamic>{
        'fileName': sourcePath.split('/').last,
        'importedAt': DateTime.now().toIso8601String(),
        'organizationId': manifest['organizationId'] ?? '',
        'documentCount': docs is List ? docs.length : 0,
        'schemaVersion': manifest['schemaVersion'] ?? 0,
      };
      await File('${incoming.path}/meta.json').writeAsString(jsonEncode(meta));
      await File('${incoming.path}/manifest.json')
          .writeAsString(jsonEncode(manifest), flush: true);

      // Swap: remove the old snapshot, promote the fresh extraction.
      await deleteSnapshot();
      final finalDir = Directory('${root.path}/$_snapshotDirName');
      try {
        await incoming.rename(finalDir.path);
      } on FileSystemException {
        // Cross-device or transient rename failure — fall back to a copy.
        await _copyDirectory(incoming, finalDir);
        try {
          await incoming.delete(recursive: true);
        } catch (_) {}
      }
      return meta;
    } finally {
      if (await incoming.exists()) {
        try {
          await incoming.delete(recursive: true);
        } catch (_) {
          // Best effort.
        }
      }
    }
  }

  Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true)) {
      final relative = entity.path.substring(from.path.length).replaceAll('\\', '/');
      final targetPath = '${to.path}$relative';
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
      }
    }
  }
}
