import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/network/models.dart';
import '../auth/auth_controller.dart';
import 'open_document.dart';

/// Files above this size are never downloaded just for a thumbnail.
const int maxThumbnailBytes = 3 * 1024 * 1024;

const Set<String> _imageExtensions = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif',
};

/// Whether [document] can show a thumbnail without wrecking the user's data
/// plan: it must be a PDF or an image, and reasonably small.
bool isThumbnailable(PapraDocument document) {
  if (document.size <= 0 || document.size > maxThumbnailBytes) return false;
  final name = document.name.toLowerCase();
  if (isPdfDocument(document)) return true;
  if (_imageExtensions.any(name.endsWith)) return true;
  return document.mimeType.toLowerCase().startsWith('image/');
}

/// A rounded thumbnail for image/PDF documents. Falls back to a placeholder
/// icon while downloading or for anything not thumbnailable. Downloads are
/// cached per document id so each file is fetched only once per session.
class DocumentThumbnail extends ConsumerStatefulWidget {
  const DocumentThumbnail({
    super.key,
    required this.document,
    this.size = 44,
    this.rounded = true,
  });

  final PapraDocument document;
  final double size;
  final bool rounded;

  @override
  ConsumerState<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends ConsumerState<DocumentThumbnail> {
  /// docId → temp path, shared across every thumbnail widget.
  static final Map<String, String> _cachedPaths = {};

  String? _path;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final cached = _cachedPaths[widget.document.id];
    if (cached != null) {
      _path = cached;
    } else {
      _download();
    }
  }

  Future<void> _download() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final result = await downloadDocumentToTemp(client: client, document: widget.document);
    if (!mounted) return;
    if (result.path != null) {
      _cachedPaths[widget.document.id] = result.path!;
      setState(() => _path = result.path);
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    final radius = widget.rounded ? size * 0.3 : 0.0;

    Widget child;
    final path = _path;
    if (path == null || _failed) {
      child = _placeholder(scheme, size);
    } else if (isPdfDocument(widget.document)) {
      child = PdfDocumentViewBuilder.file(
        path,
        autoDispose: true,
        loadingBuilder: (context) => _placeholder(scheme, size),
        errorBuilder: (context, error, stackTrace) => _placeholder(scheme, size),
        builder: (context, document) {
          if (document == null) return _placeholder(scheme, size);
          return SizedBox(
            width: size,
            height: size,
            child: PdfPageView(
              document: document,
              pageNumber: 1,
              alignment: Alignment.center,
              maximumDpi: size <= 64 ? 72 : 120,
              decoration: const BoxDecoration(),
            ),
          );
        },
      );
    } else {
      child = Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        errorBuilder: (context, error, stackTrace) => _placeholder(scheme, size),
      );
    }

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }

  Widget _placeholder(ColorScheme scheme, double size) {
    return Center(
      child: Icon(
        isPdfDocument(widget.document)
            ? Icons.picture_as_pdf_outlined
            : Icons.description_outlined,
        size: size * 0.5,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}
