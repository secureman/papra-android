import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/network/models.dart';
import '../../core/storage/document_cache.dart';
import '../auth/auth_controller.dart';
import 'open_document.dart';

/// Files above this size are never downloaded just for a thumbnail.
const int maxThumbnailBytes = 3 * 1024 * 1024;

/// Target pixel width of persisted thumbnail PNGs (2× a typical 120px tile).
const int _thumbnailMaxDimension = 240;

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

/// Bounds how many thumbnail downloads run at once. A freshly logged-in list
/// can contain dozens of thumbnailable documents; without a limiter they'd
/// all start downloading simultaneously and slow down everything.
class _DownloadLimiter {
  static const int _maxConcurrent = 4;
  static int _active = 0;
  static final List<Completer<void>> _waiters = [];

  static Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= _maxConcurrent) {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
  }
}

/// A rounded thumbnail for image/PDF documents. Falls back to a placeholder
/// icon while downloading or for anything not thumbnailable.
///
/// Thumbnails are cached **on disk** (PNG in the document cache, or the
/// original file when already cached), so document lists paint instantly on
/// every launch instead of re-downloading originals to temp.
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
  /// docId → local path, shared across every thumbnail widget.
  static final Map<String, String> _cachedPaths = {};

  /// docIds currently being rendered to a persisted PNG, so concurrent
  /// thumbnails for the same document don't render twice.
  static final Set<String> _generating = {};

  /// pdfrx is initialized lazily, the first time a PDF thumbnail needs the
  /// document API — keeping it off the app's startup path.
  static Future<void>? _pdfrxInitFuture;

  String? _path;
  bool _isPersistedPng = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final cached = _cachedPaths[widget.document.id];
    if (cached != null) {
      _path = cached;
      _isPersistedPng = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final cache = ref.read(documentCacheProvider);
    final client = ref.read(apiClientProvider);

    // 1. Pre-rendered thumbnail PNG — the fast path for repeat visits.
    final thumb = await cache.thumbnailPath(widget.document.id);
    if (thumb != null && mounted) {
      _remember(thumb, isPng: true);
      return;
    }

    // 2. Original file already in the persistent cache (previously opened).
    final cached = await cache.cachedFilePath(widget.document.id);
    if (cached != null) {
      if (mounted) _remember(cached, isPng: false);
      unawaited(_generateThumbnail(cached));
      return;
    }

    if (client == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }

    // 3. Download once (concurrency-limited), straight into the persistent
    // cache so "previously viewed" documents stay available offline.
    final result = await _DownloadLimiter.run(
      () => downloadDocumentToCache(client: client, document: widget.document),
    );
    if (!mounted) return;
    final path = result.path;
    if (result.error != null || path == null) {
      setState(() => _failed = true);
      return;
    }
    _remember(path, isPng: false);
    unawaited(_generateThumbnail(path));
  }

  void _remember(String path, {required bool isPng}) {
    _cachedPaths[widget.document.id] = path;
    setState(() {
      _path = path;
      _isPersistedPng = isPng;
    });
  }

  /// Renders a small PNG of the document (PDF page 1, or a downscaled image)
  /// and persists it next to the cache so the next visit needs no download.
  Future<void> _generateThumbnail(String originalPath) async {
    final docId = widget.document.id;
    if (_generating.contains(docId)) return;
    _generating.add(docId);
    try {
      final bytes = isPdfDocument(widget.document)
          ? await _renderPdfThumbnail(originalPath)
          : await _downscaleImage(originalPath);
      if (bytes == null || bytes.isEmpty) return;
      await ref.read(documentCacheProvider).writeThumbnail(docId, bytes);
      final thumb = await ref.read(documentCacheProvider).thumbnailPath(docId);
      if (thumb != null && mounted) {
        _cachedPaths[docId] = thumb;
        setState(() {
          _path = thumb;
          _isPersistedPng = true;
        });
      }
    } catch (_) {
      // Best effort — the original still displays fine.
    } finally {
      _generating.remove(docId);
    }
  }

  Future<Uint8List?> _renderPdfThumbnail(String path) async {
    _pdfrxInitFuture ??= pdfrxFlutterInitialize();
    await _pdfrxInitFuture;
    final document = await PdfDocument.openFile(path);
    try {
      if (document.pages.isEmpty) return null;
      final page = document.pages.first;
      final aspect = page.height == 0 ? 1.0 : page.width / page.height;
      final targetWidth = _thumbnailMaxDimension;
      final targetHeight = (targetWidth / aspect).round();
      final image = await page.render(width: targetWidth, height: targetHeight);
      try {
        if (image == null) return null;
        final uiImage = await _decodeBgra(
          pixels: image.pixels,
          width: image.width,
          height: image.height,
        );
        try {
          final data = await uiImage.toByteData(format: ui.ImageByteFormat.png);
          return data?.buffer.asUint8List();
        } finally {
          uiImage.dispose();
        }
      } finally {
        image?.dispose();
      }
    } finally {
      await document.dispose();
    }
  }

  /// dart:ui's [ui.decodeImageFromPixels] delivers its result through a
  /// callback; wrap it in a Future for ergonomics.
  Future<ui.Image> _decodeBgra({
    required Uint8List pixels,
    required int width,
    required int height,
  }) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.bgra8888,
      completer.complete,
    );
    return completer.future;
  }

  Future<Uint8List?> _downscaleImage(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _thumbnailMaxDimension,
      targetHeight: _thumbnailMaxDimension,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
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
    } else if (_isPersistedPng) {
      child = Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        errorBuilder: (context, error, stackTrace) => _placeholder(scheme, size),
      );
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