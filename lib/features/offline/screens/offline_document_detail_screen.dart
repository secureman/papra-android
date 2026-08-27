import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/utils/format.dart';
import '../../../shared/widgets/async_states.dart';
import '../../../shared/widgets/tag_chip.dart';
import '../../documents/open_document.dart';
import '../offline_models.dart';
import '../offline_providers.dart';
import '../widgets/offline_document_thumbnail.dart';

/// Read-only detail view for a document inside the imported backup:
/// metadata, tags, notes, and opening/exporting the extracted original file.
class OfflineDocumentDetailScreen extends ConsumerStatefulWidget {
  const OfflineDocumentDetailScreen({super.key, required this.documentId});

  final String documentId;

  @override
  ConsumerState<OfflineDocumentDetailScreen> createState() =>
      _OfflineDocumentDetailScreenState();
}

class _OfflineDocumentDetailScreenState
    extends ConsumerState<OfflineDocumentDetailScreen> {
  OfflineDocument? _document;
  String? _filePath;
  bool _loading = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snapshot = ref.read(offlineSnapshotProvider).value;
    if (snapshot == null) {
      setState(() => _loading = false);
      return;
    }
    final doc = snapshot.manifest.documents
        .where((d) => d.id == widget.documentId)
        .firstOrNull;
    if (doc == null) {
      setState(() => _loading = false);
      return;
    }
    final path = await ref
        .read(offlineSnapshotStoreProvider)
        .filePathForDocument(doc.id);
    if (!mounted) return;
    setState(() {
      _document = doc;
      _filePath = path;
      _loading = false;
    });
  }

  /// PDFs open in the in-app viewer; everything else goes to a system app.
  Future<void> _openOriginal() async {
    final path = _filePath;
    final doc = _document;
    if (path == null || doc == null || !await File(path).exists()) {
      _showSnack('The file is missing from the imported backup.');
      return;
    }
    if (!mounted) return;
    if (isPdfDocument(doc.asPapraDocument())) {
      await context.push(
        '/document-viewer',
        extra: (filePath: path, fileName: doc.originalName.isNotEmpty ? doc.originalName : doc.name),
      );
    } else {
      final error = await openWithSystemViewer(path);
      if (error != null && mounted) _showSnack(error);
    }
  }

  /// Copies the original file out to a user-chosen location via SAF.
  Future<void> _exportToDevice() async {
    final path = _filePath;
    final doc = _document;
    if (path == null || doc == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final bytes = await File(path).readAsBytes();
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Save “${doc.name}”',
        fileName: safeFileName(doc.originalName.isNotEmpty ? doc.originalName : doc.name),
        bytes: bytes,
        type: FileType.any,
      );
      if (uri != null && mounted) _showSnack('Saved “${doc.name}”.');
    } catch (_) {
      if (mounted) _showSnack('Could not save the file.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Scaffold(body: LoadingState(label: 'Loading document…'));
    }
    final doc = _document;
    if (doc == null) {
      return const Scaffold(body: ErrorState(message: 'Document not found in this backup.'));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          doc.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (offlineThumbnailable(doc) && _filePath != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: OfflineDocumentThumbnail(
                  document: doc,
                  filePath: _filePath!,
                  thumbsDir: _thumbsDir(),
                  size: 180,
                ),
              ),
            ),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  _row(scheme, Icons.description_outlined, 'Type', doc.mimeType),
                  _row(scheme, Icons.data_usage, 'Size', formatBytes(doc.size)),
                  _row(scheme, Icons.calendar_today_outlined, 'Added', formatDate(doc.createdAt)),
                  if (doc.documentDate != null && doc.documentDate!.isNotEmpty)
                    _row(scheme, Icons.event_outlined, 'Date', formatDate(doc.documentDate!)),
                  if (doc.folderPath.isNotEmpty)
                    _row(scheme, Icons.folder_outlined, 'Folder', doc.folderPath.join(' / ')),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _openOriginal,
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open file'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Save to device',
                        onPressed: _exporting ? null : _exportToDevice,
                        icon: _exporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (doc.tags.isNotEmpty) ...[
            _sectionHeader('Tags'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final tag in doc.tags) TagChip(tag: tag.asPapraTag())],
            ),
          ],
          if (doc.notes != null && doc.notes!.isNotEmpty) ...[
            _sectionHeader('Notes'),
            Text(doc.notes!, style: Theme.of(context).textTheme.bodyMedium),
          ],
          _sectionHeader('About this copy'),
          Card(
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This is a read-only copy from the offline backup '
                    '(imported ${formatDate(ref.read(offlineSnapshotProvider).value?.importedAt ?? '')}).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                  if (doc.sha256.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      'SHA-256: ${doc.sha256}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _thumbsDir() {
    // The thumbs dir sits inside the snapshot directory; derive it from any
    // resolved file path (…/snapshot/files/<name>) for consistency.
    final path = _filePath;
    if (path != null) {
      final filesIndex = path.lastIndexOf('/files/');
      if (filesIndex > 0) return '${path.substring(0, filesIndex)}/thumbs';
    }
    return '';
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _row(ColorScheme scheme, IconData icon, String label, String value) {
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
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value.isEmpty ? '—' : value)),
        ],
      ),
    );
  }
}
