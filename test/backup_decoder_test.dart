import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/features/offline/backup_decoder.dart';

// Builds fixtures in the exact byte layout of the fork's backup files
// (mirroring backups.encryption.service.ts + backups.packager.service.ts),
// then verifies the app-side decoder against them end to end.

const _ivLength = 12;
final _aesGcm = AesGcm.with256bits();

// Legacy layout: tag FIRST (IV | tag | ciphertext) — matches the shared crypto
// encrypt() on the server. Used for wrapping the DEK, and by older backups for
// the payload too.
Future<Uint8List> _encryptLegacyLayout(Uint8List plaintext, Uint8List key) async {
  final iv = Uint8List.fromList(List.generate(_ivLength, (i) => i + 1));
  final box = await _aesGcm.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: iv,
  );
  return Uint8List.fromList([...iv, ...box.mac.bytes, ...box.cipherText]);
}

// Wrapped key: tag FIRST — matches wrapWithKek() on the server.
Future<Uint8List> _encryptWrappedKey(Uint8List plaintext, Uint8List key) =>
    _encryptLegacyLayout(plaintext, key);

// Encrypted payload (current): tag LAST (IV | ciphertext | tag) — matches the
// streaming producer on the server (see backups.encryption.service.ts).
Future<Uint8List> _encryptPayload(Uint8List plaintext, Uint8List key) async {
  final iv = Uint8List.fromList(List.generate(_ivLength, (i) => i + 1));
  final box = await _aesGcm.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: iv,
  );
  return Uint8List.fromList([...iv, ...box.cipherText, ...box.mac.bytes]);
}

Uint8List _buildTar(Map<String, List<int>> entries) {
  final blocks = <int>[];
  for (final entry in entries.entries) {
    final header = Uint8List(512);
    final name = entry.key.codeUnits;
    header.setRange(0, name.length, name);
    // mode "0000644\0" at offset 100
    header.setRange(100, 107, '0000644'.codeUnits);
    // size octal at offset 124
    final sizeStr = entry.value.length.toRadixString(8).padLeft(11, '0');
    header.setRange(124, 135, sizeStr.codeUnits);
    header[156] = '0'.codeUnitAt(0);
    header.setRange(257, 262, 'ustar'.codeUnits);
    header.setRange(263, 265, '00'.codeUnits);
    // checksum: spaces placeholder, sum, then octal
    header.setRange(148, 156, List.filled(8, 0x20));
    var sum = 0;
    for (final b in header) {
      sum += b;
    }
    final checksumStr = '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ';
    header.setRange(148, 155, checksumStr.codeUnits);

    blocks.addAll(header);
    blocks.addAll(entry.value);
    final padding = (512 - entry.value.length % 512) % 512;
    blocks.addAll(List.filled(padding, 0));
  }
  blocks.addAll(List.filled(1024, 0));
  return Uint8List.fromList(blocks);
}

Future<Uint8List> buildBackupFile({
  required String hexKek,
  Map<String, List<int>>? extraEntries,
  // Set true to emit the payload in the OLD [iv][tag][ciphertext] layout so a
  // legacy backup can be exercised against the dual-format reader.
  bool legacyPayloadLayout = false,
}) async {
  final dek = Uint8List.fromList(List.generate(32, (i) => i * 3));

  final manifest = jsonEncode({
    'schemaVersion': 2,
    'organizationId': 'org-123',
    'createdAt': '2026-08-25T10:00:00.000Z',
    'documents': [
      {
        'id': 'doc-abc',
        'name': 'Contract',
        'originalName': 'contract.pdf',
        'mimeType': 'application/pdf',
        'originalSize': 5,
        'createdAt': '2026-01-01T00:00:00.000Z',
        'folderPath': ['Legal', '2026'],
        'tags': [
          {'name': 'important', 'color': '#e53935'},
        ],
      },
    ],
  });

  final tarEntries = <String, List<int>>{
    'manifest.json': utf8.encode(manifest),
    'files/doc-abc-contract.pdf': [1, 2, 3, 4, 5],
    ...?extraEntries,
  };
  final tarGz = GZipCodec().encode(_buildTar(tarEntries));

  final encryptedPayload = legacyPayloadLayout
    ? await _encryptLegacyLayout(Uint8List.fromList(tarGz), dek)
    : await _encryptPayload(Uint8List.fromList(tarGz), dek);
  final wrappedKeyBytes = await _encryptWrappedKey(dek, _hexToBytes(hexKek));
  final wrappedKeyB64 = base64Encode(wrappedKeyBytes);
  final wrappedKeyUtf8 = utf8.encode(wrappedKeyB64);

  final prefix = ByteData(4)..setUint32(0, wrappedKeyUtf8.length, Endian.big);
  return Uint8List.fromList([
    ...prefix.buffer.asUint8List(),
    ...wrappedKeyUtf8,
    ...encryptedPayload,
  ]);
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  const kek = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4'; // 64 hex chars

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('offline_import_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('decodes a valid encrypted backup into manifest and files', () async {
    final bytes = await buildBackupFile(
      hexKek: kek,
      extraEntries: {
        'files/doc-empty.txt': [], // skipped: zero-size entries ignored
      },
    );
    final source = File('${tempDir.path}/backup.papra-backup');
    await source.writeAsBytes(bytes);
    final target = '${tempDir.path}/snapshot';

    final stages = <String>[];
    final manifest = await extractBackupToDirectory(
      sourcePath: source.path,
      hexKek: kek,
      targetDir: target,
      onStage: stages.add,
    );

    expect(manifest['organizationId'], 'org-123');
    expect((manifest['documents'] as List).length, 1);
    expect(stages, isNotEmpty);

    final extracted = File('$target/files/doc-abc-contract.pdf');
    expect(await extracted.exists(), isTrue);
    expect(await extracted.readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('rejects a wrong KEK with a user-facing message', () async {
    final bytes = await buildBackupFile(hexKek: kek);
    final source = File('${tempDir.path}/backup.papra-backup');
    await source.writeAsBytes(bytes);

    await expectLater(
      extractBackupToDirectory(
        sourcePath: source.path,
        hexKek: '${kek.substring(0, 62)}ff',
        targetDir: '${tempDir.path}/out-wrong-key',
      ),
      throwsA(isA<BackupDecodingException>().having(
        (e) => e.message,
        'message',
        contains('Decryption failed'),
      )),
    );
  });

  test('rejects a file that is not a Papra backup', () async {
    final source = File('${tempDir.path}/random.bin');
    await source.writeAsBytes([9, 9, 9, 9, 0, 255, 0, 0]);

    await expectLater(
      extractBackupToDirectory(
        sourcePath: source.path,
        hexKek: kek,
        targetDir: '${tempDir.path}/out-garbage',
      ),
      throwsA(isA<BackupDecodingException>()),
    );
  });

  test('handles multi-block tar entries spanning several 512-byte blocks', () async {
    final bigContent = List.generate(1500, (i) => i % 256);
    final bytes = await buildBackupFile(
      hexKek: kek,
      extraEntries: {'files/doc-big-binary.bin': bigContent},
    );
    final source = File('${tempDir.path}/backup.papra-backup');
    await source.writeAsBytes(bytes);

    final manifest = await extractBackupToDirectory(
      sourcePath: source.path,
      hexKek: kek,
      targetDir: '${tempDir.path}/snapshot-big',
    );

    expect((manifest['documents'] as List).length, 1);
    final big = await File('${tempDir.path}/snapshot-big/files/doc-big-binary.bin')
        .readAsBytes();
    expect(big, bigContent);
  });

  test('decodes backups with the legacy [iv][tag][ciphertext] payload layout',
      () async {
    // Older backups (before the streaming change) put the GCM tag after the IV
    // and before the ciphertext. The dual-format reader must still open them.
    final bytes = await buildBackupFile(
      hexKek: kek,
      legacyPayloadLayout: true,
      extraEntries: {'files/doc-legacy.txt': utf8.encode('old style payload')},
    );
    final source = File('${tempDir.path}/legacy.papra-backup');
    await source.writeAsBytes(bytes);

    final manifest = await extractBackupToDirectory(
      sourcePath: source.path,
      hexKek: kek,
      targetDir: '${tempDir.path}/snapshot-legacy',
    );

    expect((manifest['documents'] as List).length, 1);
    final legacy = await File('${tempDir.path}/snapshot-legacy/files/doc-legacy.txt')
        .readAsString();
    expect(legacy, 'old style payload');
  });
}
