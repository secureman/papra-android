import 'dart:async';

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
import 'document_thumbnail.dart';
import 'open_document.dart';

/// Full document view: extracted-content preview, tags, custom properties and
/// metadata. Fetches the enriched document (which includes `content`, unlike
/// the list projection). Pops with `'renamed'` / `'trashed'` so the list can
/// refresh.
class DocumentDetailScreen extends ConsumerStatefulWidget {
  const DocumentDetailScreen({super.key, required this.documentId, this.initial});

  final String documentId;

  /// Best-effort data from the list, shown while the detail loads.
  final PapraDocument? initial;

  @override
  ConsumerState<DocumentDetailScreen> createState() => _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends ConsumerState<DocumentDetailScreen> {
  PapraDocument? _document;
  bool _loading = true;
  String? _error;
  bool _downloading = false;
  double _downloadProgress = 0;
  bool _offlineBusy = false;

  /// True when the detail was rendered from cached data because the network
  /// is unavailable (offline). Shows an offline notice instead of an error so
  /// pinned files can still be opened from the on-device cache.
  bool _isOfflineSnapshot = false;

  Set<String> get _pinned => ref.watch(offlineDocumentsProvider);

  @override
  void initState() {
    super.initState();
    _document = widget.initial;
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = 'You are not signed in.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final document = await client.getDocument(widget.documentId);
      if (!mounted) return;
      final cacheKey = _detailCacheKey;
      if (cacheKey != null) {
        // Remember the enriched detail so the same document can be opened
        // offline (Google-Drive style) even outside the list snapshot.
        unawaited(ref.read(documentCacheProvider).writeJson(cacheKey, document.toJson()));
      }
      setState(() {
        _document = document;
        _isOfflineSnapshot = false;
        _loading = false;
      });
    } on PapraApiException catch (e) {
      if (!mounted) return;
      await _fallBackToCached(e.message);
    } catch (_) {
      if (!mounted) return;
      await _fallBackToCached('Something went wrong. Please try again.');
    }
  }

  /// Cache key for the enriched document detail, scoped per organization so
  /// data never leaks across orgs.
  String? get _detailCacheKey {
    final auth = ref.read(authStateProvider);
    if (auth is! AuthAuthenticated) return null;
    return 'docs/detail/${auth.organizationId}/${widget.documentId}';
  }

  /// When the network is unavailable, fall back to the snapshot passed from
  /// the list (cached JSON), then to the cached detail, so documents that are
  /// "available offline" can still be opened. Only shows an error when no
  /// cached data exists at all.
  Future<void> _fallBackToCached(String message) async {
    if (!mounted) return;

    final fallback = widget.initial;
    if (fallback != null) {
      setState(() {
        _document = fallback;
        _isOfflineSnapshot = true;
        _loading = false;
      });
      return;
    }

    final cacheKey = _detailCacheKey;
    if (cacheKey != null) {
      final cached = await ref.read(documentCacheProvider).readJson(cacheKey);
      if (cached != null && mounted) {
        setState(() {
          _document = PapraDocument.fromJson(cached);
          _isOfflineSnapshot = true;
          _loading = false;
        });
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _rename() async {
    final document = _document;
    if (document == null) return;
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
      if (!mounted) return;
      Navigator.of(context).pop('renamed');
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _trash() async {
    final document = _document;
    if (document == null) return;
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
      if (!mounted) return;
      Navigator.of(context).pop('trashed');
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Downloads the original file into the persistent cache: PDFs open in the
  /// in-app viewer, everything else is handed to the system viewer. Files
  /// opened this way stay available offline.
  Future<void> _viewOriginal() async {
    final client = ref.read(apiClientProvider);
    final document = _document;
    if (client == null || document == null || _downloading) return;

    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    final result = await downloadDocumentToCache(
      client: client,
      document: document,
      onProgress: (fraction) {
        if (mounted) setState(() => _downloadProgress = fraction);
      },
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _downloadProgress = 0;
    });
    if (result.error != null) {
      _showSnack(result.error!);
      return;
    }
    final path = result.path;
    if (path == null) return;

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

  /// Pins/unpins the original file for offline use (Google-Drive style).
  Future<void> _toggleOffline(bool enable) async {
    final client = ref.read(apiClientProvider);
    final document = _document;
    if (client == null || document == null || _offlineBusy) return;

    setState(() => _offlineBusy = true);
    try {
      if (enable) {
        final result = await downloadDocumentToCache(client: client, document: document);
        if (result.error != null) {
          _showSnack(result.error!);
          return;
        }
        await ref.read(offlineDocumentsProvider.notifier).setPinned(document.id, pinned: true);
      } else {
        await DocumentCache.instance.deleteCachedFile(document.id);
        await ref.read(offlineDocumentsProvider.notifier).setPinned(document.id, pinned: false);
      }
    } finally {
      if (mounted) setState(() => _offlineBusy = false);
    }
  }

  /// Exports the original file to a user-chosen folder on the device (SAF).
  Future<void> _downloadToDevice() async {
    final client = ref.read(apiClientProvider);
    final document = _document;
    if (client == null || document == null || _downloading) return;

    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    final result = await downloadDocumentToDevice(
      client: client,
      document: document,
      onProgress: (fraction) {
        if (mounted) setState(() => _downloadProgress = fraction);
      },
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _downloadProgress = 0;
    });
    if (result.cancelled) return;
    if (result.error != null) {
      _showSnack(result.error!);
      return;
    }
    _showSnack('Saved “${document.name}”.');
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          document?.name ?? 'Document',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Rename',
            onPressed: document == null ? null : _rename,
            icon: const Icon(Icons.drive_file_rename_outline),
          ),
          IconButton(
            tooltip: 'Move to trash',
            onPressed: document == null ? null : _trash,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingState(label: 'Loading document…');
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    final document = _document;
    if (document == null) {
      return const ErrorState(message: 'Document not found.');
    }

    final scheme = Theme.of(context).colorScheme;
    final listView = ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (isThumbnailable(document))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: DocumentThumbnail(
                document: document,
                size: 180,
                rounded: true,
              ),
            ),
          ),
        _buildMetadataCard(document, scheme),
        if (document.tags.isNotEmpty) ...[
          _sectionHeader('Tags'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final tag in document.tags) TagChip(tag: tag)],
          ),
        ],
        if (document.customProperties.isNotEmpty) ...[
          _sectionHeader('Custom properties'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < document.customProperties.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _buildPropertyTile(document.customProperties[i]),
                ],
              ],
            ),
          ),
        ],
        if (document.notes != null && document.notes!.isNotEmpty) ...[
          _sectionHeader('Notes'),
          Text(document.notes!, style: Theme.of(context).textTheme.bodyMedium),
        ],
        _sectionHeader('Content preview'),
        Card(
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: document.content.isEmpty
                ? Text(
                    'No extracted text available for this document.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic),
                  )
                : SelectableText(
                    document.content,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
          ),
        ),
      ],
    );

    if (!_isOfflineSnapshot) return listView;
    return Column(
      children: [
        _buildOfflineBanner(scheme),
        Expanded(child: listView),
      ],
    );
  }

  /// Shown when the detail was rendered from cached data: makes it clear the
  /// user is offline while keeping the saved file reachable.
  Widget _buildOfflineBanner(ColorScheme scheme) {
    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.offline_pin_outlined, size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "You're offline — showing the saved copy. The original file is still available.",
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _buildMetadataCard(PapraDocument document, ColorScheme scheme) {
    final isOfflineAvailable = _pinned.contains(document.id);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            _buildMetadataRow(scheme, Icons.description_outlined, 'Type', document.mimeType),
            _buildMetadataRow(scheme, Icons.data_usage, 'Size', formatBytes(document.size)),
            _buildMetadataRow(
              scheme,
              Icons.calendar_today_outlined,
              'Added',
              formatDate(document.createdAt),
            ),
            if (document.documentDate != null && document.documentDate!.isNotEmpty)
              _buildMetadataRow(
                scheme,
                Icons.event_outlined,
                'Date',
                formatDate(document.documentDate!),
              ),
            const SizedBox(height: 8),
            if (_downloading)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: _downloadProgress),
                  const SizedBox(height: 6),
                  Text(
                    'Downloading… ${(_downloadProgress * 100).toStringAsFixed(0)}%',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _viewOriginal,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('View original file'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Download to device',
                    onPressed: _downloadToDevice,
                    icon: const Icon(Icons.download),
                  ),
                ],
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Available offline'),
              subtitle: const Text('Keep a copy of the file on this device'),
              value: isOfflineAvailable,
              onChanged: (_downloading || _offlineBusy) ? null : _toggleOffline,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataRow(ColorScheme scheme, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(value.isEmpty ? '—' : value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _buildPropertyTile(PapraCustomPropertyValue property) {
    final scheme = Theme.of(context).colorScheme;
    final value = _formatPropertyValue(property.value);
    final isSet = property.value != null;
    return ListTile(
      dense: true,
      title: Text(
        property.name.isEmpty ? property.key : property.name,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      subtitle: Text(
        value,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: isSet ? null : scheme.onSurfaceVariant, fontStyle: isSet ? null : FontStyle.italic),
      ),
    );
  }
}

/// Formats a custom-property value for display. Values are per-type: strings,
/// numbers, booleans, `{optionId, name}` objects for select, lists for
/// multi-select, etc.
String _formatPropertyValue(dynamic value) {
  if (value == null) return 'Not set';
  if (value is String) return value.isEmpty ? 'Not set' : value;
  if (value is num || value is bool) return value.toString();
  if (value is Map) {
    final name = value['name'];
    if (name != null && name.toString().isNotEmpty) return name.toString();
    return value.toString();
  }
  if (value is List) {
    final parts = value.map(_formatPropertyValue).where((p) => p != 'Not set').toList();
    return parts.isEmpty ? 'Not set' : parts.join(', ');
  }
  return value.toString();
}
