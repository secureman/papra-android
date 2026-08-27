import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../core/storage/document_cache.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';
import '../documents/document_thumbnail.dart';

/// Trash screen: documents soft-deleted from the organization.
///
/// Mirrors the fork's `GET /documents/deleted` paged listing and offers the
/// three recovery actions: restore, permanently delete a single document,
/// and empty the trash.
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  static const _pageSize = 50;

  bool _loading = true;
  String? _error;
  List<PapraDocument> _documents = const [];
  int _count = 0;
  int _pageIndex = 0;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _emptyTrashRunning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoader = true}) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'You are not signed in.';
      });
      return;
    }
    if (showLoader) setState(() => _loading = true);
    try {
      final resp = await client.listDeletedDocuments(pageIndex: 0, pageSize: _pageSize);
      if (!mounted) return;
      setState(() {
        _documents = resp.documents;
        _count = resp.documentsCount;
        _pageIndex = 0;
        _hasMore = _documents.length < resp.documentsCount;
        _loading = false;
        _error = null;
      });
      _preloadThumbnails(resp.documents);
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    setState(() => _loadingMore = true);
    try {
      final next = _pageIndex + 1;
      final resp = await client.listDeletedDocuments(pageIndex: next, pageSize: _pageSize);
      if (!mounted) return;
      setState(() {
        _documents = [..._documents, ...resp.documents];
        _count = resp.documentsCount;
        _pageIndex = next;
        _hasMore = _documents.length < resp.documentsCount;
        _loadingMore = false;
      });
      _preloadThumbnails(resp.documents);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// Starts thumbnail resolution for the whole list so tiles paint instantly
  /// instead of only loading the thumbnails of items scrolled into view.
  void _preloadThumbnails(List<PapraDocument> documents) {
    unawaited(preloadThumbnails(
      documents: documents,
      cache: ref.read(documentCacheProvider),
      client: ref.read(apiClientProvider),
    ));
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _restoreDocument(PapraDocument document) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.restoreDocument(document.id);
      _showSnack('Restored “${document.name}”.');
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _permanentlyDelete(PapraDocument document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text('“${document.name}” will be permanently deleted. '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.permanentlyDeleteDocument(document.id);
      _showSnack('Deleted “${document.name}”.');
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _emptyTrash() async {
    if (_emptyTrashRunning || _documents.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empty trash?'),
        content: Text('All $_count trashed documents will be permanently '
            'deleted. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Empty trash'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    setState(() => _emptyTrashRunning = true);
    try {
      await client.emptyTrash();
      _showSnack('Trash emptied.');
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    } finally {
      if (mounted) setState(() => _emptyTrashRunning = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Reload whenever the authenticated client changes (org switch, re-login).
    ref.listen(apiClientProvider, (previous, next) {
      if (previous != next) _load();
    });

    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          if (_documents.isNotEmpty)
            IconButton(
              tooltip: 'Empty trash',
              onPressed: _emptyTrashRunning ? null : _emptyTrash,
              icon: _emptyTrashRunning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: _loading
          ? const LoadingState(label: 'Loading trash…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: () => _load())
              : RefreshIndicator(
                  onRefresh: () => _load(showLoader: false),
                  child: _buildList(scheme),
                ),
    );
  }

  Widget _buildList(ColorScheme scheme) {
    if (_documents.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 160),
          EmptyState(
            icon: Icons.delete_outline,
            title: 'Trash is empty',
            message: 'Documents you move to the trash will appear here. '
                'You can restore them or delete them forever.',
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
                child: Text('Load more (${_count - _documents.length} more)'),
              ),
      ),
    );
  }

  Widget _buildDocumentTile(PapraDocument document, ColorScheme scheme) {
    return ListTile(
      leading: isThumbnailable(document)
          ? DocumentThumbnail(document: document, size: 44)
          : CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.description_outlined, color: scheme.onPrimaryContainer),
            ),
      title: Text(document.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          formatBytes(document.size),
          'Deleted ${formatDate(document.deletedAt ?? document.createdAt)}',
        ].join(' · '),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          switch (action) {
            case 'restore':
              _restoreDocument(document);
            case 'delete':
              _permanentlyDelete(document);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'restore', child: Text('Restore')),
          PopupMenuItem(value: 'delete', child: Text('Delete forever')),
        ],
      ),
    );
  }
}
