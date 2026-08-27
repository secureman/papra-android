import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../documents/document_thumbnail.dart';
import '../offline_models.dart';

/// Thumbnail for a document inside an imported backup snapshot.
///
/// Mirrors the online [DocumentThumbnail] but resolves files from the
/// snapshot's `files/` directory and persists rendered PNGs in the
/// snapshot-local `thumbs/` directory (no downloads, fully offline). PNG
/// rendering is lazy — the first scroll over a list pays it once.
class OfflineDocumentThumbnail extends StatefulWidget {
  const OfflineDocumentThumbnail({
    super.key,
    required this.document,
    required this.filePath,
    required this.thumbsDir,
    this.size = 44,
  });

  final OfflineDocument document;

  /// Resolved path of the document's original file inside the snapshot.
  final String filePath;
  final String thumbsDir;
  final double size;

  @override
  State<OfflineDocumentThumbnail> createState() => _OfflineDocumentThumbnailState();
}

class _OfflineDocumentThumbnailState extends State<OfflineDocumentThumbnail> {
  static final Map<String, String> _pngCache = {};

  bool get _isPdf => widget.document.isPdf;

  @override
  void initState() {
    super.initState();
    _maybeRenderPng();
  }

  Future<void> _maybeRenderPng() async {
    final docId = widget.document.id;
    final cached = _pngCache[docId];
    if (cached != null && await File(cached).exists()) return;
    try {
      final bytes = _isPdf
          ? await renderPdfThumbnail(widget.filePath)
          : await downscaleImagePng(widget.filePath);
      if (bytes == null || bytes.isEmpty) return;
      final file = File('${widget.thumbsDir}/${_safeId(docId)}.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      _pngCache[docId] = file.path;
      if (mounted) setState(() {});
    } catch (_) {
      // Best effort — the placeholder icon shows instead.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    final png = _pngCache[widget.document.id];

    Widget child;
    if (png != null && File(png).existsSync()) {
      child = Image.file(
        File(png),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        errorBuilder: (context, error, stackTrace) => _placeholder(scheme),
      );
    } else if (_isPdf) {
      child = _placeholder(scheme);
    } else {
      child = Image.file(
        File(widget.filePath),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        errorBuilder: (context, error, stackTrace) => _placeholder(scheme),
      );
    }

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: child,
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Center(
      child: Icon(
        _isPdf ? Icons.picture_as_pdf_outlined : Icons.description_outlined,
        size: widget.size * 0.5,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}

String _safeId(String id) => id.replaceAll(RegExp(r'[^\w.-]'), '_');

/// Whether an offline tile should attempt a thumbnail at all — same budget
/// as the online list so huge files never block scrolling.
bool offlineThumbnailable(OfflineDocument document) =>
    document.size > 0 &&
    document.size <= maxThumbnailBytes &&
    (document.isPdf ||
        const {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'}
            .any((ext) => document.originalName.toLowerCase().endsWith(ext)) ||
        document.mimeType.toLowerCase().startsWith('image/'));
