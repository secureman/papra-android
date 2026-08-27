import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'offline_models.dart';
import 'offline_snapshot_store.dart';

final offlineSnapshotStoreProvider =
    Provider<OfflineSnapshotStore>((ref) => OfflineSnapshotStore());

/// The server's BACKUPS_KEK, remembered (securely) between imports. Null when
/// the user has not provided one yet or chose to forget it.
final offlineKekProvider =
    NotifierProvider<OfflineKekController, String?>(OfflineKekController.new);

class OfflineKekController extends Notifier<String?> {
  @override
  String? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    state = await ref.read(secureStoreProvider).readBackupKek();
  }

  Future<void> save(String kek) async {
    await ref.read(secureStoreProvider).saveBackupKek(kek);
    state = kek;
  }

  Future<void> forget() async {
    await ref.read(secureStoreProvider).deleteBackupKek();
    state = null;
  }
}

/// Everything the offline browser needs: import metadata plus the parsed
/// manifest, or null when no snapshot has been imported.
class OfflineSnapshotData {
  const OfflineSnapshotData({required this.meta, required this.manifest});

  final Map<String, dynamic> meta;
  final OfflineManifest manifest;

  String get fileName => (meta['fileName'] as String?) ?? '';
  String get importedAt => (meta['importedAt'] as String?) ?? '';
  int get documentCount =>
      (meta['documentCount'] as num?)?.toInt() ?? manifest.documents.length;
}

final offlineSnapshotProvider = AsyncNotifierProvider<OfflineSnapshotController, OfflineSnapshotData?>(
  OfflineSnapshotController.new,
);

class OfflineSnapshotController extends AsyncNotifier<OfflineSnapshotData?> {
  @override
  Future<OfflineSnapshotData?> build() => _load();

  Future<OfflineSnapshotData?> _load() async {
    final store = ref.read(offlineSnapshotStoreProvider);
    final meta = await store.readMeta();
    final manifest = await store.readManifest();
    if (meta == null || manifest == null) return null;
    return OfflineSnapshotData(meta: meta, manifest: manifest);
  }

  Future<void> reload() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// Imports and installs a new snapshot; the previous one survives failures.
  Future<void> importBackup({
    required String sourcePath,
    required String hexKek,
    void Function(String stage)? onStage,
  }) async {
    await ref.read(offlineSnapshotStoreProvider).importFromFile(
          sourcePath: sourcePath,
          hexKek: hexKek,
          onStage: onStage,
        );
    await reload();
  }

  Future<void> deleteSnapshot() async {
    await ref.read(offlineSnapshotStoreProvider).deleteSnapshot();
    await reload();
  }
}

// ── Derived views ───────────────────────────────────────────────────────────

/// Unique tags across every document in the snapshot with usage counts,
/// sorted by name — the read-only equivalent of the online Tags tab.
Map<String, ({OfflineTagRef tag, int count})> aggregateTags(List<OfflineDocument> documents) {
  final byName = <String, ({OfflineTagRef tag, int count})>{};
  for (final doc in documents) {
    for (final tag in doc.tags) {
      if (tag.name.isEmpty) continue;
      final key = tag.name.toLowerCase();
      final existing = byName[key];
      byName[key] = (tag: existing?.tag ?? tag, count: (existing?.count ?? 0) + 1);
    }
  }
  final entries = byName.values.toList()
    ..sort((a, b) => a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase()));
  return {for (final e in entries) e.tag.name.toLowerCase(): e};
}

class OfflineFolderNode {
  OfflineFolderNode(this.name);

  final String name;
  final Map<String, OfflineFolderNode> children = {};
  int directCount = 0;

  int get totalCount {
    var total = directCount;
    for (final child in children.values) {
      total += child.totalCount;
    }
    return total;
  }

  /// Collects this node's subtree folder-path prefixes (used to filter
  /// documents when a folder is opened).
  Set<String> subtreePrefixes() {
    final prefix = <String>{};
    void visit(List<String> path, OfflineFolderNode node) {
      if (path.isNotEmpty) prefix.add(path.join('/'));
      for (final child in node.children.values) {
        visit([...path, child.name], child);
      }
    }

    visit(const [], this);
    return prefix;
  }
}

/// Builds the folder tree from document `folderPath`s. The returned root's
/// children are top-level folders; documents at the root increment
/// [rootDirectDocuments].
({OfflineFolderNode root, int rootDirectDocuments}) buildFolderTree(List<OfflineDocument> documents) {
  final root = OfflineFolderNode('');
  var rootDirect = 0;
  for (final doc in documents) {
    if (doc.folderPath.isEmpty) {
      rootDirect++;
      continue;
    }
    var node = root;
    for (final segment in doc.folderPath) {
      node = node.children.putIfAbsent(segment, () => OfflineFolderNode(segment));
    }
    node.directCount++;
  }
  return (root: root, rootDirectDocuments: rootDirect);
}
