import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../core/storage/document_cache.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/widgets/tag_chip.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_state.dart';
import 'batch_download.dart';
import 'document_thumbnail.dart';
import 'open_document.dart';

/// Documents list screen.
///
/// Mirrors the fork's two browsing modes:
///  * **Search** — when the search box has text, results come from
///    `listDocuments` (org-wide `GET /documents`, with sort + pagination).
///  * **Browse** — when it's empty, [getFolderContents] shows the current
///    folder's subfolders + documents (Google-Drive style), navigated with
///    tappable breadcrumbs.
class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key, this.initialFolderId, this.initialFolderName});

  /// When set, the screen starts browsing inside this folder instead of the
  /// organization root (used when opening a folder from the Folders tab).
  final String? initialFolderId;
  final String? initialFolderName;

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _FolderCrumb {
  const _FolderCrumb({required this.id, required this.name});

  final String id;
  final String name;
}

enum _SortOption { newest, oldest, nameAsc, nameDesc }

Color _hexTagColor(String hex) {
  final value = hex.replaceFirst('#', '');
  if (value.length == 6) {
    return Color(int.parse('FF$value', radix: 16));
  }
  return Colors.blueGrey;
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  static const _pageSize = 50;

  Set<String> _offlinePinned = const {};

  final _searchController = TextEditingController();
  Timer? _debounce;
  String _searchQuery = '';

  final List<_FolderCrumb> _crumbs = [];
  String _sortField = 'createdAt';
  String _sortOrder = 'desc';

  bool _loading = true;
  String? _error;
  List<PapraFolder> _subfolders = const [];
  List<PapraDocument> _documents = const [];
  int _documentsCount = 0;
  int _pageIndex = 0;
  bool _hasMore = false;
  bool _loadingMore = false;

  String? get _currentFolderId =>
      _crumbs.isEmpty ? null : _crumbs.last.id;

  bool get _isSearching => _searchQuery.trim().isNotEmpty;

  String? get _organizationId {
    final auth = ref.read(authStateProvider);
    return auth is AuthAuthenticated ? auth.organizationId : null;
  }

  @override
  void initState() {
    super.initState();
    // Deep-link from the Folders tab: seed the breadcrumb so the first load
    // browses inside the requested folder.
    final initialId = widget.initialFolderId;
    if (initialId != null && initialId.isNotEmpty) {
      _crumbs.add(_FolderCrumb(
        id: initialId,
        name: widget.initialFolderName ?? 'Folder',
      ));
    }
    // Kick off the initial load. A plain ref.listen in build only fires on
    // provider *changes*, so without this the screen would sit on
    // "Loading documents…" forever after login.
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ── Loading ───────────────────────────────────────────────────────────────

  /// Cache key for the current view (browse folder or search query).
  String get _cacheKey {
    final org = _organizationId ?? 'org';
    if (_isSearching) {
      return 'docs/search/$org/${_searchQuery.trim()}/$_sortField/$_sortOrder';
    }
    return 'docs/browse/$org/${_currentFolderId ?? 'root'}';
  }

  /// [showLoader] hides the current list while reloading; pull-to-refresh
  /// passes false so the stale list stays visible under the spinner.
  ///
  /// Offline-first: paints from the cached JSON snapshot instantly, then
  /// refreshes from the network. When the network fails, the cached data
  /// stays on screen (with a notice) instead of an error.
  Future<void> _load({bool showLoader = true}) async {
    final cache = ref.read(documentCacheProvider);
    final client = ref.read(apiClientProvider);

    // Paint from cache first — instant and works offline.
    final cached = await cache.readJson(_cacheKey);
    if (cached != null && mounted) {
      _applyResponse(cached);
    } else if (client != null && showLoader) {
      setState(() => _loading = true);
    }

    if (client == null) {
      if (!mounted) return;
      if (cached == null) {
        setState(() {
          _loading = false;
          _error = 'You are not signed in.';
        });
      }
      return;
    }

    try {
      final Map<String, dynamic> data;
      if (_isSearching) {
        final resp = await client.listDocuments(
          search: _searchQuery.trim(),
          pageIndex: 0,
          pageSize: _pageSize,
          sortField: _sortField,
          sortOrder: _sortOrder,
        );
        data = {
          'documents': resp.documents.map((d) => d.toJson()).toList(),
          'documentsCount': resp.documentsCount,
        };
      } else {
        final contents = await client.getFolderContents(folderId: _currentFolderId);
        data = {
          'folders': contents.folders.map((f) => f.toJson()).toList(),
          'documents': contents.documents.map((d) => d.toJson()).toList(),
        };
      }
      if (!mounted) return;
      _applyResponse(data);
      unawaited(cache.writeJson(_cacheKey, data));
    } on PapraApiException catch (e) {
      if (!mounted) return;
      if (cached != null) {
        _showSnack('Offline — showing cached data.');
      } else {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (!mounted) return;
      if (cached != null) {
        _showSnack('Offline — showing cached data.');
      } else {
        setState(() {
          _loading = false;
          _error = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  /// Applies a cached or fresh response map to the screen state.
  void _applyResponse(Map<String, dynamic> data) {
    final rawFolders = data['folders'];
    final rawDocuments = data['documents'];
    setState(() {
      _subfolders = rawFolders is List
          ? rawFolders
              .whereType<Map>()
              .map((e) => PapraFolder.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [];
      _documents = rawDocuments is List
          ? rawDocuments
              .whereType<Map>()
              .map((e) => PapraDocument.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [];
      _documentsCount = (data['documentsCount'] as num?)?.toInt() ?? _documents.length;
      _pageIndex = 0;
      _hasMore = _isSearching && _documents.length < _documentsCount;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || !_isSearching) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    setState(() => _loadingMore = true);
    try {
      final next = _pageIndex + 1;
      final resp = await client.listDocuments(
        search: _searchQuery.trim(),
        pageIndex: next,
        pageSize: _pageSize,
        sortField: _sortField,
        sortOrder: _sortOrder,
      );
      setState(() {
        _documents = [..._documents, ...resp.documents];
        _documentsCount = resp.documentsCount;
        _pageIndex = next;
        _hasMore = _documents.length < resp.documentsCount;
        _loadingMore = false;
      });
    } catch (_) {
      setState(() => _loadingMore = false);
    }
  }

  void _reloadAll() {
    _debounce?.cancel();
    _searchController.clear();
    _searchQuery = '';
    _crumbs.clear();
    _documents = const [];
    _subfolders = const [];
    _pageIndex = 0;
    _hasMore = false;
    _load();
  }

  // ── Search ────────────────────────────────────────────────────────────────

  void _onSearchChanged(String value) {
    setState(() {}); // refresh the clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final query = value.trim();
      if (query == _searchQuery) return;
      setState(() {
        _searchQuery = query;
        _crumbs.clear();
      });
      _load();
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _crumbs.clear();
    });
    _load();
  }

  void _applySort(_SortOption option) {
    final (field, order) = switch (option) {
      _SortOption.newest => ('createdAt', 'desc'),
      _SortOption.oldest => ('createdAt', 'asc'),
      _SortOption.nameAsc => ('name', 'asc'),
      _SortOption.nameDesc => ('name', 'desc'),
    };
    if (field == _sortField && order == _sortOrder) return;
    setState(() {
      _sortField = field;
      _sortOrder = order;
    });
    _load();
  }

  // ── Folder navigation ─────────────────────────────────────────────────────

  void _enterFolder(PapraFolder folder) {
    setState(() {
      _crumbs.add(_FolderCrumb(id: folder.id, name: folder.name));
      _searchController.clear();
      _searchQuery = '';
    });
    _load();
  }

  /// [-1] jumps to the root; otherwise truncates the breadcrumb at [index].
  void _goToCrumb(int index) {
    setState(() {
      if (index < 0) {
        _crumbs.clear();
      } else {
        _crumbs.removeRange(index + 1, _crumbs.length);
      }
    });
    _load();
  }

  // ── Document actions ──────────────────────────────────────────────────────

  Future<void> _renameDocument(PapraDocument document) async {
    final controller = TextEditingController(text: document.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename document'),
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
    if (newName == null || newName.isEmpty || newName == document.name) return;
    try {
      await ref.read(apiClientProvider)?.renameDocument(document.id, newName);
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _trashDocument(PapraDocument document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to trash?'),
        content: Text('“${document.name}” will be moved to the trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(apiClientProvider)?.trashDocument(document.id);
      setState(() {
        _documents = _documents.where((d) => d.id != document.id).toList();
        _documentsCount = _documentsCount > 0 ? _documentsCount - 1 : 0;
      });
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Move / tag ────────────────────────────────────────────────────────────

  /// Re-parents a document into another folder (or the root).
  Future<void> _moveDocument(PapraDocument document) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final List<PapraFolder> folders;
    try {
      folders = await client.listFolders();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
      return;
    } catch (_) {
      _showSnack('Could not load folders.');
      return;
    }
    if (!mounted) return;

    final options = [...folders]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    String? selected = document.folderId ?? '';

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Move “${document.name}”'),
          content: DropdownButtonFormField<String>(
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Destination folder'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Root (no folder)')),
              for (final folder in options)
                DropdownMenuItem(
                  value: folder.id,
                  child: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
    try {
      await client.moveDocumentToFolder(document.id, choice.isEmpty ? null : choice);
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  /// Adds/removes tags on a document via a checkbox dialog.
  Future<void> _tagDocument(PapraDocument document) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final List<PapraTag> tags;
    try {
      tags = await client.listTags();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
      return;
    } catch (_) {
      _showSnack('Could not load tags.');
      return;
    }
    if (tags.isEmpty) {
      _showSnack('No tags yet — create one in the Tags tab first.');
      return;
    }
    if (!mounted) return;

    final current = document.tags.map((t) => t.id).toSet();
    final selected = <String>{...current};

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Tags'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final tag in tags)
                  CheckboxListTile(
                    value: selected.contains(tag.id),
                    title: Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: _hexTagColor(tag.color),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(tag.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                    controlAffinity: ListTileControlAffinity.trailing,
                    onChanged: (checked) => setDialogState(() {
                      if (checked == true) {
                        selected.add(tag.id);
                      } else {
                        selected.remove(tag.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    final toAdd = selected.difference(current);
    final toRemove = current.difference(selected);
    try {
      for (final tagId in toAdd) {
        await client.addTagToDocument(document.id, tagId);
      }
      for (final tagId in toRemove) {
        await client.removeTagFromDocument(document.id, tagId);
      }
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  // ── Upload ────────────────────────────────────────────────────────────────

  Future<void> _uploadDocument() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final file = await FilePicker.pickFile(
      type: FileType.any,
      dialogTitle: 'Select a document to upload',
    );
    if (file == null) return;
    if (!mounted) return;
    final path = file.path;
    if (path == null) {
      _showSnack('Could not access the selected file.');
      return;
    }
    final fileName = file.name;
    final folderId = _currentFolderId;

    final progress = ValueNotifier<double>(0);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, child) => AlertDialog(
            title: const Text('Uploading…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: value == 0 ? null : value),
                const SizedBox(height: 8),
                Text(
                  '${(value * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await client.uploadDocument(
        filePath: path,
        fileName: fileName,
        folderId: folderId,
        onProgress: (sent, total) =>
            progress.value = total > 0 ? sent / total : 0,
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showSnack('Uploaded “$fileName”.');
        _load(showLoader: false);
      }
    } on PapraApiException catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (e.isDuplicate) {
        _showSnack('“$fileName” already exists on the server.');
      } else {
        _showSnack(e.message);
      }
    } catch (_) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _showSnack('Could not upload the file.');
    }
  }

  /// Downloads the original file (into the persistent cache): PDFs open in
  /// the in-app viewer, everything else is handed to the system viewer.
  Future<void> _openOriginal(PapraDocument document) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final result = await downloadDocumentToCache(client: client, document: document);
    if (result.error != null) {
      _showSnack(result.error!);
      return;
    }
    final path = result.path;
    if (path == null || !mounted) return;
    if (isPdfDocument(document)) {
      await context.push(
        '/document-viewer',
        extra: (filePath: path, fileName: document.name),
      );
    } else {
      final error = await openWithSystemViewer(path);
      if (error != null && mounted) _showSnack(error);
    }
  }

  /// Exports the original file to a user-chosen folder on the device (SAF),
  /// with a live progress dialog.
  Future<void> _downloadDocument(PapraDocument document) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final progress = ValueNotifier<double>(0);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, child) => AlertDialog(
            title: const Text('Downloading…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(document.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: value == 0 ? null : value),
                const SizedBox(height: 8),
                Text(
                  value == 0 ? 'Choosing destination…' : '${(value * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final result = await downloadDocumentToDevice(
      client: client,
      document: document,
      onProgress: (fraction) => progress.value = fraction,
    );
    if (!mounted) {
      progress.dispose();
      return;
    }
    Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    if (result.cancelled) return;
    if (result.error != null) {
      _showSnack(result.error!);
      return;
    }
    _showSnack('Saved “${document.name}”.');
  }

  /// Downloads every document in the current folder (recursively) to a
  /// user-chosen destination.
  Future<void> _downloadCurrentFolder() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final folderId = _currentFolderId;
    final message = await downloadSelectionToDevice(
      context: context,
      client: client,
      title: 'Downloading folder…',
      enumerate: () => documentsInFolder(client, folderId: folderId),
    );
    if (message != null && message.isNotEmpty && mounted) _showSnack(message);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Reload whenever the authenticated client changes (org switch, re-login).
    ref.listen(apiClientProvider, (previous, next) {
      if (previous != next) _reloadAll();
    });

    final scheme = Theme.of(context).colorScheme;
    _offlinePinned = ref.watch(offlineDocumentsProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploadDocument,
        icon: const Icon(Icons.upload_file_outlined),
        label: const Text('Upload'),
      ),
      body: Column(
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
                if (_isSearching) ...[
                  const SizedBox(width: 8),
                  PopupMenuButton<_SortOption>(
                    icon: const Icon(Icons.sort),
                    tooltip: 'Sort results',
                    onSelected: _applySort,
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: _SortOption.newest, child: Text('Newest first')),
                      const PopupMenuItem(value: _SortOption.oldest, child: Text('Oldest first')),
                      const PopupMenuItem(value: _SortOption.nameAsc, child: Text('Name (A–Z)')),
                      const PopupMenuItem(value: _SortOption.nameDesc, child: Text('Name (Z–A)')),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const LoadingState(label: 'Loading documents…');
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: () => _load());
    }
    return RefreshIndicator(
      onRefresh: () => _load(showLoader: false),
      child: _isSearching ? _buildSearchResults(scheme) : _buildBrowseView(scheme),
    );
  }

  Widget _buildBrowseView(ColorScheme scheme) {
    if (_subfolders.isEmpty && _documents.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 160),
          EmptyState(
            icon: _crumbs.isEmpty ? Icons.description_outlined : Icons.folder_open,
            title: _crumbs.isEmpty ? 'No documents yet' : 'This folder is empty',
            message: _crumbs.isEmpty
                ? 'Uploaded documents will show up here.'
                : 'Move documents into this folder to organize them.',
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (_crumbs.isNotEmpty) _buildBreadcrumbRow(scheme),
        if (_subfolders.isNotEmpty) ..._buildFolderSection(scheme),
        if (_documents.isNotEmpty) ..._buildDocumentSection(scheme),
      ],
    );
  }

  /// Breadcrumb navigation plus a button to download the whole folder.
  Widget _buildBreadcrumbRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(child: _buildBreadcrumb()),
          IconButton(
            tooltip: 'Download folder contents',
            onPressed: _downloadCurrentFolder,
            icon: const Icon(Icons.download_for_offline_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          _crumbChip('All documents', () => _goToCrumb(-1)),
          for (var i = 0; i < _crumbs.length; i++) ...[
            const Icon(Icons.chevron_right, size: 18),
            _crumbChip(_crumbs[i].name, () => _goToCrumb(i)),
          ],
        ],
      ),
    );
  }

  Widget _crumbChip(String label, VoidCallback onTap) {
    return ActionChip(
      avatar: const Icon(Icons.folder_outlined, size: 16),
      label: Text(label),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }

  List<Widget> _buildFolderSection(ColorScheme scheme) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text('Folders', style: Theme.of(context).textTheme.titleSmall),
      ),
      SizedBox(
        height: 108,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          itemCount: _subfolders.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) => _buildFolderCard(_subfolders[index], scheme),
        ),
      ),
    ];
  }

  Widget _buildFolderCard(PapraFolder folder, ColorScheme scheme) {
    return SizedBox(
      width: 150,
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _enterFolder(folder),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(Icons.folder, color: scheme.primary, size: 28),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      '${folder.documentsCount} document${folder.documentsCount == 1 ? '' : 's'}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDocumentSection(ColorScheme scheme) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          'Documents${_isSearching ? '' : ' (${_documents.length})'}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      for (final document in _documents) _buildDocumentTile(document, scheme),
    ];
  }

  Widget _buildSearchResults(ColorScheme scheme) {
    if (_documents.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 160),
          EmptyState(
            icon: Icons.search_off,
            title: 'No results',
            message: 'No documents match “${_searchQuery.trim()}”.',
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _documents.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _documents.length) return _buildLoadMore();
        return _buildDocumentTile(_documents[index], scheme);
      },
    );
  }

  Widget _buildLoadMore() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : TextButton(
                onPressed: _loadMore,
                child: Text('Load more (${_documentsCount - _documents.length} more)'),
              ),
      ),
    );
  }

  Widget _buildDocumentTile(PapraDocument document, ColorScheme scheme) {
    final isOfflineAvailable = _offlinePinned.contains(document.id);
    return ListTile(
      leading: isThumbnailable(document)
          ? DocumentThumbnail(document: document, size: 44)
          : CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.description_outlined, color: scheme.onPrimaryContainer),
            ),
      title: Text(document.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatBytes(document.size)} · ${formatDate(document.createdAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (document.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [for (final tag in document.tags.take(4)) TagChip(tag: tag)],
              ),
            ),
        ],
      ),
      onTap: () async {
        final result = await context.push<String>('/document/${document.id}');
        if (result == 'renamed' || result == 'trashed') {
          _load(showLoader: false);
        }
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isOfflineAvailable)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.offline_pin, size: 18, color: scheme.primary),
            ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'open':
                  _openOriginal(document);
                case 'download':
                  _downloadDocument(document);
                case 'move':
                  _moveDocument(document);
                case 'tag':
                  _tagDocument(document);
                case 'rename':
                  _renameDocument(document);
                case 'trash':
                  _trashDocument(document);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'open', child: Text('Open original')),
              PopupMenuItem(value: 'download', child: Text('Download to device')),
              PopupMenuItem(value: 'move', child: Text('Move to folder')),
              PopupMenuItem(value: 'tag', child: Text('Tags')),
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'trash', child: Text('Move to trash')),
            ],
          ),
        ],
      ),
    );
  }
}

