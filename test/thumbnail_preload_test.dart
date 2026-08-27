import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/document_cache.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/documents/document_thumbnail.dart';

/// In-memory [DocumentCache] stub so thumbnail resolution never touches disk
/// (the real cache does file I/O, which hangs in the fake-async widget-test
/// zone and writes outside the test sandbox).
class _FakeCache extends DocumentCache {
  /// documentId → persisted PNG path.
  final Map<String, String> persistedPngs = {};

  /// documentId → path of the cached original file.
  final Map<String, String> cachedFiles = {};

  final List<String> writtenThumbnails = [];
  int downloadsFinalized = 0;

  @override
  Future<void> init() async {}

  @override
  Future<String?> thumbnailPath(String documentId) async => persistedPngs[documentId];

  @override
  Future<void> writeThumbnail(String documentId, List<int> pngBytes) async {
    writtenThumbnails.add(documentId);
    persistedPngs[documentId] = '/thumbs/$documentId.png';
  }

  @override
  Future<String?> cachedFilePath(String documentId) async => cachedFiles[documentId];

  @override
  Future<String> downloadPathFor(String documentId, String fileName) async =>
      '/files/$documentId.bin';

  @override
  Future<void> finalizeDownload(String partPath, String finalPath) async {
    downloadsFinalized++;
    final name = finalPath.split('/').last;
    final id = name.substring(0, name.lastIndexOf('.'));
    cachedFiles[id] = finalPath;
  }
}

/// In-memory [ApiClient] stub: `downloadDocument` records the call instead of
/// hitting the network.
class _FakeClient extends ApiClient {
  _FakeClient()
      : super(
          baseUrl: 'https://example.com',
          organizationId: 'org-1',
          apiKey: 'key',
          cookieStore: SessionCookieStore(SecureStore()),
          onAuthFailure: () {},
        );

  int downloadCalls = 0;

  @override
  Future<void> downloadDocument({
    required String documentId,
    required String savePath,
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    downloadCalls++;
  }
}

PapraDocument _pdfDoc(String id) => PapraDocument(
      id: id,
      name: 'doc.pdf',
      createdAt: '2026-01-01T00:00:00Z',
      size: 2048,
      mimeType: 'application/pdf',
    );

PapraDocument _imageDoc(String id) => PapraDocument(
      id: id,
      name: 'photo.png',
      createdAt: '2026-01-01T00:00:00Z',
      size: 2048,
      mimeType: 'image/png',
    );

PapraDocument _plainDoc(String id) => PapraDocument(
      id: id,
      name: 'notes.docx',
      createdAt: '2026-01-01T00:00:00Z',
      size: 2048,
      mimeType: 'application/octet-stream',
    );

void main() {
  setUp(resetThumbnailCache);

  group('resolveThumbnail', () {
    test('returns the persisted PNG without touching the network', () async {
      final cache = _FakeCache()..persistedPngs['d-1'] = '/thumbs/d-1.png';
      final client = _FakeClient();

      final result =
          await resolveThumbnail(document: _pdfDoc('d-1'), cache: cache, client: client);

      expect(result, isNotNull);
      expect(result!.path, '/thumbs/d-1.png');
      expect(result.isPng, isTrue);
      expect(client.downloadCalls, 0);
    });

    test('returns the cached original without downloading', () async {
      final cache = _FakeCache()..cachedFiles['d-1'] = '/files/d-1.pdf';
      final client = _FakeClient();

      final result =
          await resolveThumbnail(document: _pdfDoc('d-1'), cache: cache, client: client);

      expect(result, isNotNull);
      expect(result!.path, '/files/d-1.pdf');
      expect(result.isPng, isFalse);
      expect(client.downloadCalls, 0);
    });

    test('downloads a missing original once and remembers the result', () async {
      final cache = _FakeCache();
      final client = _FakeClient();

      final first =
          await resolveThumbnail(document: _imageDoc('d-1'), cache: cache, client: client);

      expect(first, isNotNull);
      expect(first!.isPng, isFalse);
      expect(client.downloadCalls, 1);
      expect(cache.cachedFiles['d-1'], isNotNull);

      final second =
          await resolveThumbnail(document: _imageDoc('d-1'), cache: cache, client: client);

      expect(client.downloadCalls, 1, reason: 'repeat calls must reuse the shared result');
      expect(second!.path, first.path);
    });

    test('returns null when offline and nothing is cached', () async {
      final result =
          await resolveThumbnail(document: _imageDoc('d-1'), cache: _FakeCache(), client: null);

      expect(result, isNull);
    });
  });

  group('preloadThumbnails', () {
    test('skips documents that are not thumbnailable', () async {
      final cache = _FakeCache();
      final client = _FakeClient();

      await preloadThumbnails(
        documents: [_plainDoc('d-1'), _plainDoc('d-2')],
        cache: cache,
        client: client,
      );

      expect(client.downloadCalls, 0);
      expect(cache.downloadsFinalized, 0);
      expect(cache.writtenThumbnails, isEmpty);
    });

    test('downloads each thumbnailable document exactly once across repeated calls', () async {
      final cache = _FakeCache();
      final client = _FakeClient();
      final documents = [_pdfDoc('d-1'), _imageDoc('d-2')];

      await preloadThumbnails(documents: documents, cache: cache, client: client);
      await preloadThumbnails(documents: documents, cache: cache, client: client);

      expect(client.downloadCalls, 2, reason: 'one download per document, not per call');
      expect(cache.cachedFiles.keys, containsAll(['d-1', 'd-2']));
    });
  });

  group('DocumentThumbnail with preloaded thumbnails', () {
    Widget wrap(Widget child, {required _FakeClient client, required _FakeCache cache}) {
      return ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          documentCacheProvider.overrideWithValue(cache),
        ],
        child: MaterialApp(home: Scaffold(body: Center(child: child))),
      );
    }

    testWidgets('renders the thumbnail on the very first frame after preloading',
        (tester) async {
      final cache = _FakeCache()..persistedPngs['d-1'] = '/thumbs/d-1.png';
      final client = _FakeClient();
      await preloadThumbnails(documents: [_imageDoc('d-1')], cache: cache, client: client);

      await tester.pumpWidget(
        wrap(
          DocumentThumbnail(document: _imageDoc('d-1'), size: 44),
          client: client,
          cache: cache,
        ),
      );

      expect(find.byType(Image), findsOneWidget,
          reason: 'the tile must paint the thumbnail without another async load');
      expect(client.downloadCalls, 0);
    });

    testWidgets('without preloading, the tile shows a placeholder until it loads itself',
        (tester) async {
      final cache = _FakeCache();
      final client = _FakeClient();

      await tester.pumpWidget(
        wrap(
          DocumentThumbnail(document: _imageDoc('d-1'), size: 44),
          client: client,
          cache: cache,
        ),
      );

      expect(find.byType(Image), findsNothing,
          reason: 'first frame is the placeholder while the tile loads its own thumbnail');

      await tester.pump();
      expect(client.downloadCalls, 1, reason: 'the tile itself had to trigger the download');

      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    });
  });
}