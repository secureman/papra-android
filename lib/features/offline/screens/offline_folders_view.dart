import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/async_states.dart';
import '../offline_models.dart';
import '../offline_providers.dart';
import 'offline_documents_view.dart';

/// Folders tab of the offline browser: an accordion tree reconstructed from
/// each document's `folderPath`. Tapping a folder expands it in place,
/// revealing its subfolders and its own documents; counts are recursive.
class OfflineFoldersView extends ConsumerStatefulWidget {
  const OfflineFoldersView({super.key, required this.documents});

  final List<OfflineDocument> documents;

  @override
  ConsumerState<OfflineFoldersView> createState() => _OfflineFoldersViewState();
}

class _OfflineFoldersViewState extends ConsumerState<OfflineFoldersView> {
  final Set<String> _expanded = {};
  Directory? _snapshotDir;

  @override
  void initState() {
    super.initState();
    _resolveSnapshotDir();
  }

  Future<void> _resolveSnapshotDir() async {
    final path = await ref.read(offlineSnapshotStoreProvider).snapshotPath();
    if (!mounted || path == null) return;
    setState(() => _snapshotDir = Directory(path));
  }

  void _toggle(String key) {
    setState(() {
      if (!_expanded.remove(key)) _expanded.add(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (:root, :rootDirectDocuments) = buildFolderTree(widget.documents);

    if (root.children.isEmpty && rootDirectDocuments == 0) {
      return const EmptyState(
        icon: Icons.folder_outlined,
        title: 'No folders',
        message: 'The imported backup has no documents yet.',
      );
    }

    const rootKey = '';
    final rows = <Widget>[
      ListTile(
        leading: Icon(
          _expanded.contains(rootKey) ? Icons.folder_open : Icons.folder,
          color: scheme.primary,
        ),
        title: const Text('Root (no folder)'),
        subtitle:
            Text('$rootDirectDocuments document${rootDirectDocuments == 1 ? '' : 's'}'),
        trailing: AnimatedRotation(
          turns: _expanded.contains(rootKey) ? 0.25 : 0,
          duration: const Duration(milliseconds: 150),
          child: const Icon(Icons.expand_more),
        ),
        onTap: () => _toggle(rootKey),
      ),
      if (_expanded.contains(rootKey))
        for (final doc in _docsIn(const [])) _docRow(doc, depth: 1),
      for (final child in root.children.values)
        ..._buildFolderRows(child, const [], scheme, rootKey: rootKey),
    ];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: rows,
    );
  }

  /// Documents whose folderPath is exactly [path] — i.e. directly inside it.
  List<OfflineDocument> _docsIn(List<String> path) {
    final joined = path.join('/');
    return widget.documents.where((d) => d.folderPath.join('/') == joined).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Widget _docRow(OfflineDocument doc, {required double depth}) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 20),
      child: OfflineResolvedDocumentTile(document: doc, snapshotDir: _snapshotDir),
    );
  }

  List<Widget> _buildFolderRows(
    OfflineFolderNode node,
    List<String> path,
    ColorScheme scheme, {
    String? rootKey,
  }) {
    final currentPath = [...path, node.name];
    final key = currentPath.join('/');
    final isExpanded = _expanded.contains(key);

    return [
      ListTile(
        contentPadding: EdgeInsets.only(left: 16.0 + path.length * 20, right: 16),
        leading: Icon(
          isExpanded ? Icons.folder_open : Icons.folder,
          color: scheme.primary,
        ),
        title: Text(node.name),
        subtitle: Text('${node.totalCount} document${node.totalCount == 1 ? '' : 's'}'),
        trailing: AnimatedRotation(
          turns: isExpanded ? 0.25 : 0,
          duration: const Duration(milliseconds: 150),
          child: const Icon(Icons.expand_more),
        ),
        onTap: () => _toggle(key),
      ),
      if (isExpanded) ...[
        for (final doc in _docsIn(currentPath)) _docRow(doc, depth: path.length + 1.0),
        if (node.children.isEmpty && _docsIn(currentPath).isEmpty)
          Padding(
            padding: EdgeInsets.only(left: 16.0 + (path.length + 1) * 20, top: 8, bottom: 8),
            child: Text(
              'Empty folder',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else
          for (final child in node.children.values)
            ..._buildFolderRows(child, currentPath, scheme),
      ],
    ];
  }
}
