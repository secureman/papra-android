import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';

/// Folders tab: a management tree of the whole organization.
///
/// Uses [ApiClient.listFolders] — the fork returns every folder flat with
/// `parentId` and direct `documentsCount`, exactly so the client can build a
/// full tree without N round trips. Supports create, rename, move and delete
/// (with the fork's `force` cascade semantics for non-empty folders).
class FoldersScreen extends ConsumerStatefulWidget {
  const FoldersScreen({super.key});

  @override
  ConsumerState<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends ConsumerState<FoldersScreen> {
  bool _loading = true;
  String? _error;
  List<PapraFolder> _folders = const [];
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoader = true}) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = null;
        _folders = const [];
      });
      return;
    }
    if (showLoader) setState(() => _loading = true);
    try {
      final folders = await client.listFolders();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _loading = false;
        _error = null;
      });
    } on PapraApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  // ── Tree helpers ──────────────────────────────────────────────────────────

  /// Folders indexed by parent id ('' for root), each list sorted by name.
  Map<String, List<PapraFolder>> get _byParent {
    final map = <String, List<PapraFolder>>{};
    for (final folder in _folders) {
      map.putIfAbsent(folder.parentId ?? '', () => []).add(folder);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return map;
  }

  /// Documents directly inside [folder] plus all of its descendants.
  int _totalCount(PapraFolder folder) {
    var total = folder.documentsCount;
    for (final child in _byParent[folder.id] ?? const <PapraFolder>[]) {
      total += _totalCount(child);
    }
    return total;
  }

  int get _totalDocuments {
    var total = 0;
    for (final folder in _byParent[''] ?? const <PapraFolder>[]) {
      total += _totalCount(folder);
    }
    return total;
  }

  Set<String> _descendantsOf(String folderId) {
    final result = <String>{};
    void visit(String id) {
      for (final child in _byParent[id] ?? const <PapraFolder>[]) {
        if (result.add(child.id)) visit(child.id);
      }
    }

    visit(folderId);
    return result;
  }

  void _toggle(String folderId) {
    setState(() {
      if (!_expanded.remove(folderId)) _expanded.add(folderId);
    });
  }

  // ── Folder actions ────────────────────────────────────────────────────────

  Future<void> _createFolder({String? parentId}) async {
    final nameController = TextEditingController();
    var selectedParent = parentId ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New folder'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selectedParent,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Parent folder'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Root (no parent)')),
                  for (final folder in _sortedFolders)
                    DropdownMenuItem(
                      value: folder.id,
                      child: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) => setDialogState(() => selectedParent = value ?? ''),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(nameController.text.trim()),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.createFolder(name: name, parentId: selectedParent.isEmpty ? null : selectedParent);
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _renameFolder(PapraFolder folder) async {
    final controller = TextEditingController(text: folder.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == folder.name) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.updateFolder(folder.id, name: newName);
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  /// Re-parents [folder]; excludes the folder itself and its descendants to
  /// avoid the fork's circular-reference error.
  Future<void> _moveFolder(PapraFolder folder) async {
    final excluded = _descendantsOf(folder.id)..add(folder.id);
    final options = _folders.where((f) => !excluded.contains(f.id)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    String? selected = folder.parentId ?? '';
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Move “${folder.name}”'),
          content: DropdownButtonFormField<String>(
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Parent folder'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Root (no parent)')),
              for (final option in options)
                DropdownMenuItem(
                  value: option.id,
                  child: Text(option.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setDialogState(() => selected = value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selected),
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.updateFolder(folder.id, parentId: choice.isEmpty ? null : choice);
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _deleteFolder(PapraFolder folder) async {
    final hasContents =
        (_byParent[folder.id] ?? const <PapraFolder>[]).isNotEmpty || folder.documentsCount > 0;

    final bool? confirmed;
    if (hasContents) {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete folder?'),
          content: Text(
            '“${folder.name}” contains subfolders or documents. Force-delete will delete '
            'all subfolders; documents inside will be moved to the root of the organization.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Force delete'),
            ),
          ],
        ),
      );
    } else {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete folder?'),
          content: Text('“${folder.name}” will be deleted.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
    }

    if (confirmed != true) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.deleteFolder(folder.id, force: hasContents);
      _expanded.remove(folder.id);
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  /// Opens the folder's contents in the Documents browser.
  void _openFolder(PapraFolder folder) {
    context.push('/documents/folder/${folder.id}', extra: folder.name);
  }

  List<PapraFolder> get _sortedFolders {
    final list = [..._folders]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createFolder(),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('New folder'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const LoadingState(label: 'Loading folders…');
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: () => _load());
    }
    if (_folders.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 160),
          EmptyState(
            icon: Icons.folder_open,
            title: 'No folders yet',
            message: 'Create folders to organize your documents.',
            actionLabel: 'Create folder',
            onAction: () => _createFolder(),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(showLoader: false),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '${_folders.length} folder${_folders.length == 1 ? '' : 's'} · '
              '$_totalDocuments document${_totalDocuments == 1 ? '' : 's'}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          ..._buildRows(_byParent[''] ?? const [], 0),
          const SizedBox(height: 88),
        ],
      ),
    );
  }

  List<Widget> _buildRows(List<PapraFolder> folders, int depth) {
    final rows = <Widget>[];
    for (final folder in folders) {
      final hasChildren = (_byParent[folder.id] ?? const <PapraFolder>[]).isNotEmpty;
      final isExpanded = _expanded.contains(folder.id);
      rows.add(_buildFolderRow(folder, depth, hasChildren, isExpanded));
      if (hasChildren && isExpanded) {
        rows.addAll(_buildRows(_byParent[folder.id] ?? const [], depth + 1));
      }
    }
    return rows;
  }

  Widget _buildFolderRow(
    PapraFolder folder,
    int depth,
    bool hasChildren,
    bool isExpanded,
  ) {
    final count = _totalCount(folder);

    return Padding(
      padding: EdgeInsets.only(left: (depth * 20.0).clamp(0, 80)),
      child: ListTile(
        dense: true,
        leading: hasChildren
            ? IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                tooltip: isExpanded ? 'Collapse' : 'Expand',
                onPressed: () => _toggle(folder.id),
                icon: AnimatedRotation(
                  turns: isExpanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.chevron_right),
                ),
              )
            : const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.folder_outlined, size: 20),
              ),
        title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('$count document${count == 1 ? '' : 's'}'),
        onTap: () => _openFolder(folder),
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            switch (action) {
              case 'create':
                _createFolder(parentId: folder.id);
              case 'rename':
                _renameFolder(folder);
              case 'move':
                _moveFolder(folder);
              case 'delete':
                _deleteFolder(folder);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'create', child: Text('New subfolder')),
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'move', child: Text('Move to…')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }
}
