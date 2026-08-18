import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/storage/document_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Points path_provider's application-documents directory at a fresh temp dir
/// so the real [DocumentCache] can be exercised on disk.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;

  @override
  Future<String?> getTemporaryPath() async => '${root.path}/tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('papra-cache-test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // A fresh instance per test: the app uses the singleton, but a fresh
  // instance avoids carrying state/dirs across tests while still exercising
  // the real on-disk implementation.
  DocumentCache newCache() => DocumentCache();

  test('writes and reads back a JSON snapshot with a nested key', () async {
    final cache = newCache();
    const key = 'docs/search/org_abc//createdAt/desc';
    const data = {'documents': <Object>[], 'documentsCount': 0};

    await cache.writeJson(key, data);

    // The nested parent directories must have been created.
    final saved = await cache.readJson(key);
    expect(saved, data);
    expect(saved?['documentsCount'], 0);
  });

  test('returns null for a missing key', () async {
    final cache = newCache();
    expect(await cache.readJson('docs/detail/org_abc/doc_xyz'), isNull);
  });

  test('pinned index round-trips through setPinned/getPinnedIds', () async {
    final cache = newCache();
    expect(await cache.getPinnedIds(), isEmpty);

    await cache.setPinned('doc_1', pinned: true);
    await cache.setPinned('doc_2', pinned: true);
    expect(await cache.getPinnedIds(), {'doc_1', 'doc_2'});

    await cache.setPinned('doc_1', pinned: false);
    expect(await cache.getPinnedIds(), {'doc_2'});
  });

  test('finalizeDownload makes the file visible to cachedFilePath', () async {
    final cache = newCache();
    final target = await cache.downloadPathFor('doc_abc', 'invoice.pdf');
    expect(target, endsWith('.pdf'));

    // A leftover .part file is not a valid cache entry.
    await File('$target.part').writeAsBytes([1, 2, 3]);
    expect(await cache.cachedFilePath('doc_abc'), isNull);

    await cache.finalizeDownload('$target.part', target);
    expect(await cache.cachedFilePath('doc_abc'), target);
  });

  test('deleteCachedFile frees the file and clears the index', () async {
    final cache = newCache();
    final target = await cache.downloadPathFor('doc_abc', 'invoice.pdf');
    await File(target).writeAsBytes([1, 2, 3]);
    await cache.finalizeDownload(target, target);

    expect(await cache.cachedFilePath('doc_abc'), target);
    await cache.deleteCachedFile('doc_abc');
    expect(await cache.cachedFilePath('doc_abc'), isNull);
  });

  test('thumbnail PNGs round-trip through writeThumbnail/thumbnailPath', () async {
    final cache = newCache();
    expect(await cache.thumbnailPath('doc_abc'), isNull);

    await cache.writeThumbnail('doc_abc', [137, 80, 78, 71]);
    final path = await cache.thumbnailPath('doc_abc');
    expect(path, isNotNull);
    expect(path, endsWith('doc_abc.png'));
    expect(File(path!).readAsBytesSync(), [137, 80, 78, 71]);
  });
}
