import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/async_states.dart';
import '../offline_models.dart';
import '../offline_providers.dart';
import '../widgets/offline_document_tile.dart';

enum _SortOption { newest, oldest, nameAsc, nameDesc }

/// Documents tab of the offline browser.
///
/// Mirrors the online Documents screen read-only: a search box filtering by
/// name/notes/tags/folder, sort options, and Google-Drive-style folder
/// navigation built from each document's `folderPath` in the manifest.
class OfflineDocumentsView extends ConsumerStatefulWidget {
  const OfflineDocumentsView({super.key, required this.documents});

  final List<OfflineDocument> documents;

  @override
  ConsumerState<OfflineDocumentsView> createState() => _OfflineDocumentsViewState();
}

class _OfflineDocumentsViewState extends ConsumerState<OfflineDocumentsView> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  _SortOption _sort = _SortOption.newest;

  /// Current breadcrumb stack of folder names; empty = root.
  final List<String> _crumbs = [];

  /// Snapshot directory containing `files/` and `thumbs/`, resolved once.
  Directory? _snapshotDir;

  @override
  void initState() {
    super.initState();
    _resolveSnapshotDir();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _resolveSnapshotDir() async {
    final store = ref.read(offlineSnapshotStoreProvider);
    final path = await store.snapshotPath();
    if (!mounted || path == null) return;
    setState(() => _snapshotDir = Directory(path));
  }

  bool get _isSearching => _query.trim().isNotEmpty;

  List<OfflineDocument> get _sortedFiltered {
    var docs = widget.documents;
    if (_isSearching) {
      final needle = _query.trim().toLowerCase();
      docs = docs.where((d) {
        if (d.name.toLowerCase().contains(needle)) return true;
        if (d.originalName.toLowerCase().contains(needle)) return true;
        if (d.notes?.toLowerCase().contains(needle) ?? false) return true;
        for (final tag in d.tags) {
          if (tag.name.toLowerCase().contains(needle)) return true;
        }
        return d.folderPath.join('/').toLowerCase().contains(needle);
      }).toList();
    } else {
      // Mirror the online browser: only the current folder's own documents
      // (empty crumbs = organization root). Exact path matches are documents
      // directly inside this folder; deeper ones live in subfolders.
      final prefix = _crumbs.join('/');
      docs = prefix.isEmpty
          ? docs.where((d) => d.folderPath.isEmpty).toList()
          : docs
              .where((d) {
                final joined = d.folderPath.join('/');
                return joined == prefix || joined.startsWith('$prefix/');
              })
              .toList();
    }
    switch (_sort) {
      case _SortOption.newest:
        docs = [...docs]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _SortOption.oldest:
        docs = [...docs]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _SortOption.nameAsc:
        docs = [...docs]
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _SortOption.nameDesc:
        docs = [...docs]
          ..sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
    }
    return docs;
  }

  /// Next-level subfolder names at the current breadcrumb depth.
  Set<String> get _subfolders {
    if (_isSearching) return const {};
    final depth = _crumbs.length;
    final names = <String>{};
    for (final doc in widget.documents) {
      if (!_crumbsMatchesPrefix(doc.folderPath)) continue;
      if (doc.folderPath.length > depth) names.add(doc.folderPath[depth]);
    }
    return names;
  }

  bool _crumbsMatchesPrefix(List<String> folderPath) {
    for (var i = 0; i < _crumbs.length; i++) {
      if (i >= folderPath.length || folderPath[i] != _crumbs[i]) return false;
    }
    return true;
  }

  void _onSearchChanged(String value) {
    setState(() {}); // refresh the clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        _crumbs.clear();
      });
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    setState(() {
      _query = '';
      _crumbs.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search documents',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            tooltip: 'Clear search',
                            onPressed: _clearSearch,
                          ),
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<_SortOption>(
                icon: const Icon(Icons.sort),
                tooltip: 'Sort',
                onSelected: (option) => setState(() => _sort = option),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: _SortOption.newest, child: Text('Newest first')),
                  const PopupMenuItem(value: _SortOption.oldest, child: Text('Oldest first')),
                  const PopupMenuItem(value: _SortOption.nameAsc, child: Text('Name (A–Z)')),
                  const PopupMenuItem(value: _SortOption.nameDesc, child: Text('Name (Z–A)')),
                ],
              ),
            ],
          ),
        ),
        Expanded(child: _buildList(scheme)),
      ],
    );
  }

  Widget _buildList(ColorScheme scheme) {
    final docs = _sortedFiltered;
    final folders = _subfolders.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (folders.isEmpty && docs.isEmpty) {
      return EmptyState(
        icon: _isSearching ? Icons.search_off : Icons.description_outlined,
        title: _isSearching ? 'No results' : 'No documents here',
        message: _isSearching
            ? 'No offline documents match “${_query.trim()}”.'
            : _crumbs.isEmpty
                ? 'The imported backup has no documents.'
                : 'This folder has no documents.',
      );
    }

    final itemCount = (_crumbs.isNotEmpty ? 1 : 0) + folders.length + docs.length;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        var cursor = 0;
        if (_crumbs.isNotEmpty) {
          if (index == 0) return _buildBreadcrumb(scheme);
          cursor++;
        }
        final folderIndex = index - cursor;
        if (folderIndex < folders.length) {
          return ListTile(
            leading: Icon(Icons.folder, color: scheme.primary),
            title: Text(folders[folderIndex]),
            subtitle: Text(_docCountInFolder(folders[folderIndex])),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _crumbs.add(folders[folderIndex])),
          );
        }
        final doc = docs[folderIndex - folders.length];
        return OfflineResolvedDocumentTile(document: doc, snapshotDir: _snapshotDir);
      },
    );
  }

  String _docCountInFolder(String name) {
    final path = ([..._crumbs, name]).join('/');
    var count = 0;
    for (final doc in widget.documents) {
      final joined = doc.folderPath.join('/');
      if (joined == path || joined.startsWith('$path/')) count++;
    }
    return '$count document${count == 1 ? '' : 's'}';
  }

  Widget _buildBreadcrumb(ColorScheme scheme) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          ActionChip(
            avatar: Icon(Icons.folder_outlined, size: 16, color: scheme.primary),
            label: const Text('All documents'),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _crumbs.clear()),
          ),
          for (var i = 0; i < _crumbs.length; i++) ...[
            const Icon(Icons.chevron_right, size: 18),
            ActionChip(
              label: Text(_crumbs[i]),
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _crumbs.removeRange(i + 1, _crumbs.length)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Resolves a document's extracted file path from the snapshot's `files/`
/// directory once, then renders the shared tile with thumbnail support.
class OfflineResolvedDocumentTile extends StatefulWidget {
  const OfflineResolvedDocumentTile({super.key, required this.document, required this.snapshotDir});

  final OfflineDocument document;
  final Directory? snapshotDir;

  @override
  State<OfflineResolvedDocumentTile> createState() => _OfflineResolvedDocumentTileState();
}

class _OfflineResolvedDocumentTileState extends State<OfflineResolvedDocumentTile> {
  String? _path;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final dir = widget.snapshotDir;
    if (dir == null) return;
    final filesDir = Directory('${dir.path}/files');
    if (!await filesDir.exists()) return;
    await for (final entity in filesDir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('${widget.document.id}-')) {
        if (mounted) setState(() => _path = entity.path);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumbsDir = widget.snapshotDir == null ? '' : '${widget.snapshotDir!.path}/thumbs';
    return OfflineDocumentTile(
      document: widget.document,
      filePath: _path ?? '',
      thumbsDir: thumbsDir,
    );
  }
}
