import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../core/storage/document_cache.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/widgets/tag_chip.dart';
import '../auth/auth_controller.dart';
import '../documents/batch_download.dart';
import '../documents/document_thumbnail.dart';
import '../documents/open_document.dart';

Color _hexTagColor(String hex) {
  final value = hex.replaceFirst('#', '');
  if (value.length == 6) {
    return Color(int.parse('FF$value', radix: 16));
  }
  return Colors.blueGrey;
}

/// All documents carrying a single tag, plus the usual per-document actions
/// and a "download everything" shortcut.
///
/// The server's search doesn't index tag names, so the list is built by
/// paginating every document and filtering client-side by tag id.
class TagDocumentsScreen extends ConsumerStatefulWidget {
  const TagDocumentsScreen({super.key, required this.tagId, this.initialTag});

  final String tagId;

  /// Best-effort tag from the list screen, used for the title while the
  /// authoritative tag is loaded.
  final PapraTag? initialTag;

  @override
  ConsumerState<TagDocumentsScreen> createState() => _TagDocumentsScreenState();
}

class _TagDocumentsScreenState extends ConsumerState<TagDocumentsScreen> {
  PapraTag? _tag;
  bool _loading = true;
  String? _error;
  List<PapraDocument> _documents = const [];
  Set<String> _offlinePinned = const {};

  @override
  void initState() {
    super.initState();
    _tag = widget.initialTag;
    _load();
  }

  Future<void> _load({bool showLoader = true}) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = 'You are not signed in.';
      });
      return;
    }
    if (showLoader) setState(() => _loading = true);
    try {
      final tag = _tag ??= await _fetchTag(client);
      final documents = await documentsWithTag(client, widget.tagId);
      if (!mounted) return;
      setState(() {
        _tag = tag;
        _documents = documents;
        _loading = false;
        _error = null;
      });
      unawaited(preloadThumbnails(
        documents: documents,
        cache: ref.read(documentCacheProvider),
        client: ref.read(apiClientProvider),
      ));
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

  Future<PapraTag?> _fetchTag(ApiClient client) async {
    final tags = await client.listTags();
    for (final tag in tags) {
      if (tag.id == widget.tagId) return tag;
    }
    return null;
  }

  // ── Document actions ──────────────────────────────────────────────────────

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
      });
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

  /// Downloads every document carrying this tag to a user-chosen folder.
  Future<void> _downloadAll() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final message = await downloadSelectionToDevice(
      context: context,
      client: client,
      title: 'Downloading tagged documents…',
      enumerate: () => documentsWithTag(client, widget.tagId),
    );
    if (message != null && message.isNotEmpty && mounted) _showSnack(message);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _offlinePinned = ref.watch(offlineDocumentsProvider);
    final tag = _tag;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tag != null) ...[
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _hexTagColor(tag.color),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Flexible(child: Text(tag?.name ?? 'Documents', overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Download all documents',
            onPressed: _documents.isEmpty ? null : _downloadAll,
            icon: const Icon(Icons.download_for_offline_outlined),
          ),
        ],
      ),
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const LoadingState(label: 'Loading documents…');
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: () => _load());
    }
    if (_documents.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 160),
          EmptyState(
            icon: Icons.sell_outlined,
            title: 'No documents yet',
            message: 'Documents tagged “${_tag?.name ?? ''}” will show up here.',
          ),
          const SizedBox(height: 88),
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
              '${_documents.length} document${_documents.length == 1 ? '' : 's'}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          for (final document in _documents) _buildDocumentTile(document, scheme),
          const SizedBox(height: 88),
        ],
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