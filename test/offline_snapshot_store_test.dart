import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/features/offline/backup_decoder.dart';
import 'package:papra_android/features/offline/offline_snapshot_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'backup_decoder_test.dart' show buildBackupFile;

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kek = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';

  late Directory tempDir;
  late OfflineSnapshotStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('offline-store-test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
    store = OfflineSnapshotStore();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeFixture(String name, {String kekHex = kek}) async {
    final bytes = await buildBackupFile(hexKek: kekHex);
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  test('imports a snapshot and exposes meta, manifest and file paths', () async {
    final fixture = await writeFixture('good.papra-backup');

    final meta = await store.importFromFile(sourcePath: fixture.path, hexKek: kek);

    expect(meta['documentCount'], 1);
    expect(meta['organizationId'], 'org-123');

    final readBack = await store.readMeta();
    expect(readBack?['fileName'], 'good.papra-backup');

    final manifest = await store.readManifest();
    expect(manifest?.documents.single.id, 'doc-abc');
    expect(manifest?.documents.single.folderPath, ['Legal', '2026']);

    final filePath = await store.filePathForDocument('doc-abc');
    expect(filePath, isNotNull);
    expect(File(filePath!).existsSync(), isTrue);
    expect(await store.snapshotPath(), isNotNull);
  });

  test('a failed import leaves the previous snapshot untouched', () async {
    final good = await writeFixture('good.papra-backup');
    await store.importFromFile(sourcePath: good.path, hexKek: kek);
    final originalPath = await store.snapshotPath();

    // Wrong KEK → import fails.
    final bad = await writeFixture('bad.papra-backup', kekHex: '${kek.substring(0, 62)}00');
    await expectLater(
      store.importFromFile(sourcePath: bad.path, hexKek: '${kek.substring(0, 62)}ff'),
      throwsA(isA<BackupDecodingException>()),
    );

    expect(await store.snapshotPath(), originalPath);
    expect((await store.readMeta())?['fileName'], 'good.papra-backup');
    expect(await store.filePathForDocument('doc-abc'), isNotNull);
  });

  test('re-import replaces the active snapshot', () async {
    final first = await writeFixture('first.papra-backup');
    await store.importFromFile(sourcePath: first.path, hexKek: kek);

    // Build a second distinct backup (different manifest content).
    final bytes = await buildBackupFile(hexKek: kek);
    final second = File('${tempDir.path}/second.papra-backup');
    await second.writeAsBytes(bytes);

    final meta = await store.importFromFile(sourcePath: second.path, hexKek: kek);
    expect(meta['fileName'], 'second.papra-backup');

    // No leftover incoming-* directories.
    final offlineRoot = Directory('${tempDir.path}/papra/offline');
    final leftovers =
        await offlineRoot.list().where((e) => e.path.contains('incoming')).toList();
    expect(leftovers, isEmpty);
    expect(await store.readManifest(), isNotNull);
  });

  test('deleteSnapshot removes everything', () async {
    final fixture = await writeFixture('gone.papra-backup');
    await store.importFromFile(sourcePath: fixture.path, hexKek: kek);
    expect(await store.readMeta(), isNotNull);

    await store.deleteSnapshot();

    expect(await store.readMeta(), isNull);
    expect(await store.readManifest(), isNull);
    expect(await store.snapshotPath(), isNull);
  });

  test('meta json is valid json with expected shape', () async {
    final fixture = await writeFixture('shape.papra-backup');
    final meta = await store.importFromFile(sourcePath: fixture.path, hexKek: kek);
    // Sanity: the map returned matches what is persisted.
    final stored = jsonDecode(
      await File('${(await store.snapshotPath())!}/meta.json').readAsString(),
    ) as Map<String, dynamic>;
    expect(stored['documentCount'], meta['documentCount']);
    expect(stored['importedAt'], isNotEmpty);
  });
}
