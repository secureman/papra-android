import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Decodes Papra `.papra-backup` archives entirely on-device.
///
/// The archive layout matches the fork's server-side packager
/// (`backups.packager.service.ts` + `backups.encryption.service.ts`):
///
///   envelope  = [4-byte big-endian wrappedKeyLength][wrappedKey utf8][encrypted payload]
///   wrappedKey= base64(IV(12) | GCM tag(16) | AES-256-GCM(DEK))   — DEK wrapped with BACKUPS_KEK
///   payload   = IV(12) | AES-256-GCM(tar.gz) | GCM tag(16)        — tag last (streamed layout)
///              OR the legacy IV(12) | GCM tag(16) | AES-256-GCM(tar.gz) for older backups
///   tar.gz    = `manifest.json` + `files/<documentId>-<originalName>` entries
///
/// All heavy work runs inside a background isolate so the UI stays responsive;
/// progress is reported through a [SendPort] as `('stage', message)` frames.
class BackupDecodingException implements Exception {
  const BackupDecodingException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef ImportProgress = void Function(String stage);

/// Imports [sourcePath] into [targetDir] (which is created; must be empty or
/// nonexistent). Returns the parsed manifest map. Throws
/// [BackupDecodingException] with a user-facing message on any failure.
Future<Map<String, dynamic>> extractBackupToDirectory({
  required String sourcePath,
  required String hexKek,
  required String targetDir,
  ImportProgress? onStage,
}) async {
  final port = ReceivePort();
  final result = Completer<Map<String, dynamic>>();
  Isolate? isolate;

  void fail(String message) {
    if (!result.isCompleted) {
      result.completeError(BackupDecodingException(message));
    }
  }

  late final StreamSubscription<dynamic> subscription;
  subscription = port.listen(
    (message) {
      if (message is Map) {
        // Success frame: {'manifest': …} sent by [_importIsolateEntry].
        subscription.cancel();
        if (!result.isCompleted) {
          final inner = message['manifest'];
          if (inner is Map) {
            result.complete(Map<String, dynamic>.from(inner));
          } else {
            fail('The backup could not be read.');
          }
        }
        return;
      }
      if (message is List && message.length >= 2) {
        switch (message[0]) {
          case 'stage':
            onStage?.call(message[1] as String);
          case 'error':
            subscription.cancel();
            fail(message[1] as String);
        }
      }
    },
    onError: (Object error) => fail('Something went wrong while reading the backup.'),
    onDone: () => fail('The backup could not be read.'),
    cancelOnError: true,
  );

  try {
    isolate = await Isolate.spawn(
      _importIsolateEntry,
      _ImportArgs(
        sourcePath: sourcePath,
        hexKek: hexKek,
        targetDir: targetDir,
        port: port.sendPort,
      ),
      errorsAreFatal: true,
    );
    // Generous ceiling so a wedged isolate can never leave the import dialog
    // spinning forever; real imports finish far below this.
    return await result.future.timeout(const Duration(minutes: 10));
  } on TimeoutException {
    throw const BackupDecodingException('Reading the backup took too long.');
  } on BackupDecodingException {
    rethrow;
  } catch (_) {
    throw const BackupDecodingException('Something went wrong while reading the backup.');
  } finally {
    port.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

class _ImportArgs {
  const _ImportArgs({
    required this.sourcePath,
    required this.hexKek,
    required this.targetDir,
    required this.port,
  });

  final String sourcePath;
  final String hexKek;
  final String targetDir;
  final SendPort port;
}

Future<void> _importIsolateEntry(_ImportArgs args) async {
  try {
    args.port.send(const ['stage', 'Reading file…']);
    final bytes = await File(args.sourcePath).readAsBytes();
    if (bytes.length < 4) {
      throw const BackupDecodingException('This file is not a Papra backup.');
    }

    final (wrappedKey, encryptedPayload) = _parseEnvelope(bytes);

    args.port.send(const ['stage', 'Decrypting…']);
    Uint8List tarGzBytes;
    try {
      final dek = await _unwrapDek(wrappedKey: wrappedKey, hexKek: args.hexKek);
      tarGzBytes = await _decryptPayload(encryptedPayload, dek);
    } catch (_) {
      throw const BackupDecodingException(
        'Decryption failed. Check that this is the server key (BACKUPS_KEK) '
        'and that the backup file is complete.',
      );
    }

    args.port.send(const ['stage', 'Extracting files…']);
    final targetDir = Directory(args.targetDir);
    await targetDir.create(recursive: true);
    final manifest = _extractTar(tarGzBytes, targetDir);
    if (manifest == null) {
      throw const BackupDecodingException('This archive is missing its manifest and cannot be opened.');
    }

    args.port.send({'manifest': manifest});
  } on BackupDecodingException catch (e) {
    args.port.send(['error', e.message]);
  } catch (_) {
    args.port.send(const ['error', 'Something went wrong while reading the backup.']);
  }
}

(String, Uint8List) _parseEnvelope(Uint8List bytes) {
  final byteData = ByteData.sublistView(bytes);
  final keyLength = byteData.getUint32(0, Endian.big);
  if (keyLength == 0 || keyLength > bytes.length - 4) {
    throw const BackupDecodingException('This file is not a Papra backup.');
  }
  try {
    return (
      utf8.decode(bytes.sublist(4, 4 + keyLength)),
      Uint8List.sublistView(bytes, 4 + keyLength),
    );
  } catch (_) {
    throw const BackupDecodingException('This file is not a Papra backup.');
  }
}

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.isEmpty || clean.length.isOdd) {
    throw const BackupDecodingException('The server key must be a hex string.');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

const int _ivLength = 12;
const int _tagLength = 16;

final AesGcm _aesGcm = AesGcm.with256bits();

/// Reverses `wrapWithKek`: base64 → IV | tag | ciphertext, decrypted with the
/// server-wide KEK to recover the per-backup data key.
Future<Uint8List> _unwrapDek({required String wrappedKey, required String hexKek}) async {
  final box = _splitEncrypted(Uint8List.fromList(base64Decode(wrappedKey)));
  final clear = await _aesGcm.decrypt(
    SecretBox(box.$3, nonce: box.$1, mac: Mac(box.$2)),
    secretKey: SecretKey(_hexToBytes(hexKek)),
  );
  return Uint8List.fromList(clear);
}

/// Reverses `encryptPayload` on the server. Two layouts have existed:
///   - legacy : [iv][tag][ciphertext]     (old in-RAM builder via shared encrypt())
///   - current: [iv][ciphertext][tag]      (the streaming producer)
/// GCM tag verification picks whichever one a file actually uses, so we try the
/// current layout first and fall back to the legacy one.
Future<Uint8List> _decryptPayload(Uint8List encrypted, Uint8List key) async {
  if (encrypted.length < _ivLength + _tagLength) {
    throw const BackupDecodingException('The backup payload is truncated.');
  }

  Object? firstFailure;
  try {
    // Current: tag is last.
    final clear = await _aesGcm.decrypt(
      SecretBox(
        Uint8List.sublistView(encrypted, _ivLength, encrypted.length - _tagLength),
        nonce: Uint8List.sublistView(encrypted, 0, _ivLength),
        mac: Mac(Uint8List.sublistView(encrypted, encrypted.length - _tagLength)),
      ),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  } catch (error) {
    firstFailure = error;
  }

  // Legacy: [iv][tag][ciphertext] — try the wrapped-key splitter layout.
  try {
    final box = _splitEncrypted(encrypted);
    final clear = await _aesGcm.decrypt(
      SecretBox(box.$3, nonce: box.$1, mac: Mac(box.$2)),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  } catch (_) {
    // Neither layout authenticated (bad key / corrupt file) — rethrow the
    // first failure so the isolate reports a clean "Decryption failed".
    throw firstFailure;
  }
}

typedef _SplitEncrypted = (Uint8List, Uint8List, Uint8List);

_SplitEncrypted _splitEncrypted(Uint8List data) {
  if (data.length < _ivLength + _tagLength) {
    throw const BackupDecodingException('The backup payload is truncated.');
  }
  return (
    Uint8List.sublistView(data, 0, _ivLength),
    Uint8List.sublistView(data, _ivLength, _ivLength + _tagLength),
    Uint8List.sublistView(data, _ivLength + _tagLength),
  );
}

const int _blockSize = 512;

/// Minimal ustar reader mirroring the server packager: flat regular-file
/// entries, name + optional prefix fields, two zero blocks at the end.
/// Writes every `files/…` entry into [targetDir]/files and returns the parsed
/// `manifest.json` object, or null when the archive has no manifest.
Map<String, dynamic>? _extractTar(Uint8List tarGz, Directory targetDir) {
  late final List<int> tarBytes;
  try {
    tarBytes = GZipCodec().decode(tarGz);
  } catch (_) {
    throw const BackupDecodingException('The backup archive is corrupted.');
  }

  final filesDir = Directory('${targetDir.path}/files');
  filesDir.createSync(recursive: true);
  final tar = tarBytes is Uint8List ? tarBytes : Uint8List.fromList(tarBytes);
  final byteData = ByteData.sublistView(tar);

  Map<String, dynamic>? manifest;
  var offset = 0;
  var extractedCount = 0;

  while (offset + _blockSize <= tar.length) {
    var allZero = true;
    for (var i = 0; i < _blockSize; i++) {
      if (tar[offset + i] != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) break;

    final nameField = _tarString(tar, offset, 100);
    final prefixField = _tarString(tar, offset + 345, 155);
    final entryName = prefixField.isEmpty ? nameField : '$prefixField/$nameField';
    final size = _tarOctal(byteData, offset + 124, 12);

    offset += _blockSize;
    if (offset + size > tar.length) break;
    final content = Uint8List.sublistView(tar, offset, offset + size);
    offset += ((size + _blockSize - 1) ~/ _blockSize) * _blockSize;

    if (entryName == 'manifest.json') {
      try {
        final decoded = jsonDecode(utf8.decode(content));
        if (decoded is Map<String, dynamic>) manifest = decoded;
      } catch (_) {
        throw const BackupDecodingException('The backup manifest is corrupted.');
      }
      continue;
    }

    if (!entryName.startsWith('files/') || content.isEmpty) continue;

    // Entry names are sanitized server-side ([\w.-]); still guard against
    // traversal before writing to disk.
    final relativeName = entryName.substring('files/'.length).replaceAll('\\', '_');
    if (relativeName.isEmpty || relativeName.contains('..')) continue;

    final outFile = File('${filesDir.path}/$relativeName');
    outFile.writeAsBytesSync(content, flush: true);
    extractedCount++;
  }

  if (extractedCount == 0 && manifest == null) {
    throw const BackupDecodingException('No documents were found in this backup.');
  }
  return manifest;
}

String _tarString(Uint8List tar, int offset, int length) {
  var end = offset;
  final limit = offset + length;
  while (end < limit && tar[end] != 0) {
    end++;
  }
  return utf8.decode(tar.sublist(offset, end), allowMalformed: true).trim();
}

int _tarOctal(ByteData data, int offset, int length) {
  var value = 0;
  for (var i = 0; i < length; i++) {
    final byte = data.getUint8(offset + i);
    if (byte == 0 || byte == 0x20) break;
    if (byte < 0x30 || byte > 0x37) break;
    value = value * 8 + (byte - 0x30);
  }
  return value;
}
