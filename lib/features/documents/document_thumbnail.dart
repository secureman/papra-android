import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/network/api_client.dart';
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

/// A locally resolved thumbnail: the path to display, and whether it is the
/// pre-rendered PNG (fast `Image.file`) or the original file.
typedef ThumbnailResult = ({String path, bool isPng});

/// docId → resolved thumbnail, shared across every thumbnail widget and the
/// eager list preloader, so resolving once (even off-screen) paints all tiles
/// instantly.
final Map<String, ThumbnailResult> _cachedThumbnails = {};

/// docIds currently being rendered to a persisted PNG. Stores the in-flight
/// future so concurrent preloaders and widgets share a single render instead
/// of rendering the same document twice.
final Map<String, Future<void>> _generatingFutures = {};

/// pdfrx is initialized lazily, the first time a PDF thumbnail needs the
/// document API — keeping it off the app's startup path.
Future<void>? _pdfrxInitFuture;

/// Clears the shared preload state; tests call it between runs.
@visibleForTesting
void resetThumbnailCache() {
  _cachedThumbnails.clear();
  _generatingFutures.clear();
}

/// Resolves the best local file for [document]'s thumbnail:
///
///  1. pre-rendered thumbnail PNG — the fast path for repeat visits;
///  2. original file already in the persistent cache (previously opened);
///  3. otherwise a one-time, concurrency-limited download straight into the
///     persistent cache.
///
/// The result is remembered in [_cachedThumbnails] so every widget (and any
/// later preload pass) reuses it without I/O. Returns null when nothing could
/// be resolved (e.g. offline with nothing cached).
Future<ThumbnailResult?> resolveThumbnail({
  required PapraDocument document,
  required DocumentCache cache,
  required ApiClient? client,
}) async {
  final docId = document.id;
  final existing = _cachedThumbnails[docId];
  if (existing != null) return existing;

  final thumb = await cache.thumbnailPath(docId);
  if (thumb != null) {
    final result = (path: thumb, isPng: true);
    _cachedThumbnails[docId] = result;
    return result;
  }

  final cached = await cache.cachedFilePath(docId);
  if (cached != null) {
    final result = (path: cached, isPng: false);
    _cachedThumbnails[docId] = result;
    return result;
  }

  if (client == null) return null;

  final download = await _DownloadLimiter.run(
    () => downloadDocumentToCache(client: client, document: document, cache: cache),
  );
  if (download.error != null || download.path == null) return null;
  final result = (path: download.path!, isPng: false);
  _cachedThumbnails[docId] = result;
  return result;
}

/// Renders a small PNG of [originalPath] (PDF page 1, or a downscaled image)
/// and persists it next to the cache so the next visit needs no download.
/// Concurrent callers for the same document share the in-flight render.
Future<void> generateThumbnail({
  required PapraDocument document,
  required DocumentCache cache,
  required String originalPath,
}) {
  final docId = document.id;
  final inFlight = _generatingFutures[docId];
  if (inFlight != null) return inFlight;
  final future = _doGenerateThumbnail(
    document: document,
    cache: cache,
    originalPath: originalPath,
  );
  _generatingFutures[docId] = future;
  return future.whenComplete(() => _generatingFutures.remove(docId));
}

Future<void> _doGenerateThumbnail({
  required PapraDocument document,
  required DocumentCache cache,
  required String originalPath,
}) async {
  final docId = document.id;
  try {
    final bytes = isPdfDocument(document)
        ? await renderPdfThumbnail(originalPath)
        : await downscaleImagePng(originalPath);
    if (bytes == null || bytes.isEmpty) return;
    await cache.writeThumbnail(docId, bytes);
    final thumb = await cache.thumbnailPath(docId);
    if (thumb != null) {
      _cachedThumbnails[docId] = (path: thumb, isPng: true);
    }
  } catch (_) {
    // Best effort — the original still displays fine.
  }
}

/// Eagerly resolves thumbnails for [documents] so they are already painted
/// (or downloading) by the time the user scrolls to them. Lazy list slivers
/// only build the tiles in the viewport, so without this, thumbnail work
/// would only start once each item scrolls into view.
Future<void> preloadThumbnails({
  required List<PapraDocument> documents,
  required DocumentCache cache,
  required ApiClient? client,
}) async {
  await Future.wait([
    for (final document in documents)
      if (isThumbnailable(document))
        _preloadOne(document: document, cache: cache, client: client),
  ]);
}

Future<void> _preloadOne({
  required PapraDocument document,
  required DocumentCache cache,
  required ApiClient? client,
}) async {
  final result = await resolveThumbnail(
    document: document,
    cache: cache,
    client: client,
  );
  if (result != null && !result.isPng) {
    unawaited(generateThumbnail(
      document: document,
      cache: cache,
      originalPath: result.path,
    ));
  }
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

/// Renders page 1 of a PDF at thumbnail resolution. Public so the offline
/// backup browser can reuse it for snapshot-local files.
Future<Uint8List?> renderPdfThumbnail(String path) async {
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

/// Downscales an image file to a small square PNG. Public so the offline
/// backup browser can reuse it for snapshot-local files.
Future<Uint8List?> downscaleImagePng(String path) async {
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
  String? _path;
  bool _isPersistedPng = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final cached = _cachedThumbnails[widget.document.id];
    if (cached != null) {
      _path = cached.path;
      _isPersistedPng = cached.isPng;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final cache = ref.read(documentCacheProvider);
    final client = ref.read(apiClientProvider);

    final result = await resolveThumbnail(
      document: widget.document,
      cache: cache,
      client: client,
    );
    if (!mounted) return;
    if (result == null) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _path = result.path;
      _isPersistedPng = result.isPng;
    });
    if (!result.isPng) {
      unawaited(_upgradeToPng(cache, result.path));
    }
  }

  /// After the persisted PNG is rendered (by this widget or a preloader),
  /// swap the original file for the smaller pre-rendered image.
  Future<void> _upgradeToPng(DocumentCache cache, String originalPath) async {
    await generateThumbnail(
      document: widget.document,
      cache: cache,
      originalPath: originalPath,
    );
    if (!mounted) return;
    final upgraded = _cachedThumbnails[widget.document.id];
    if (upgraded != null && upgraded.isPng && upgraded.path != _path) {
      setState(() {
        _path = upgraded.path;
        _isPersistedPng = true;
      });
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