import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../core/storage/document_cache.dart';

/// Sanitizes a file name for use as a local path component.
String safeFileName(String name) {
  final safe = name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
  return safe.isEmpty ? 'document.bin' : safe;
}

/// Opens (or downloads) the original file into the persistent document cache,
/// so it works offline and is only ever fetched once. Serves straight from
/// cache when already present. Returns the local path, or a user-facing error
/// message.
Future<({String? path, String? error})> downloadDocumentToCache({
  required ApiClient client,
  required PapraDocument document,
  DocumentCache? cache,
  void Function(double fraction)? onProgress,
}) async {
  try {
    final resolved = cache ?? DocumentCache.instance;
    final cached = await resolved.cachedFilePath(document.id);
    if (cached != null) return (path: cached, error: null);

    final target = await resolved.downloadPathFor(document.id, document.name);
    final partPath = '$target.part';
    await client.downloadDocument(
      documentId: document.id,
      savePath: partPath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    await resolved.finalizeDownload(partPath, target);
    return (path: target, error: null);
  } on PapraApiException catch (e) {
    return (path: null, error: e.message);
  } catch (_) {
    return (path: null, error: 'Could not download the file.');
  }
}

bool isPdfDocument(PapraDocument document) {
  final name = document.name.toLowerCase();
  return name.endsWith('.pdf') || document.mimeType.toLowerCase() == 'application/pdf';
}

/// Result of a "download to device" operation.
class DeviceDownloadResult {
  const DeviceDownloadResult({this.path, this.error, this.cancelled = false});

  /// Local path of the saved file, or null when it failed or was cancelled.
  final String? path;

  /// User-facing error message, or null on success/cancel.
  final String? error;

  /// True when the user dismissed the destination picker.
  final bool cancelled;
}

/// Downloads [document]'s original file to a user-chosen destination via the
/// system folder picker (Android SAF). Streams straight to the picked
/// directory when the path is writable; otherwise falls back to the native
/// save-file dialog (which buffers the bytes in memory). Returns the saved
/// path, an error message, or a cancelled flag.
Future<DeviceDownloadResult> downloadDocumentToDevice({
  required ApiClient client,
  required PapraDocument document,
  void Function(double fraction)? onProgress,
}) async {
  final fileName = safeFileName(document.name);

  try {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose where to save “${document.name}”',
    );
    if (dir == null || dir.isEmpty) return const DeviceDownloadResult(cancelled: true);

    final target = '$dir/$fileName';
    final partPath = '$target.part';
    try {
      await client.downloadDocument(
        documentId: document.id,
        savePath: partPath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );
      await File(partPath).rename(target);
      return DeviceDownloadResult(path: target);
    } on PapraApiException catch (e) {
      // dio wraps save-path write failures in a DioException whose `error`
      // is the underlying FileSystemException.
      final cause = e.cause;
      final underlying = cause is DioException ? cause.error : cause;
      if (underlying is IOException) {
        // The picked path isn't writable from Dart (scoped storage) — fall
        // back to the native save dialog which writes via the content
        // resolver.
        await deleteFileIfExists(partPath);
        return _downloadViaSaveDialog(
          client: client,
          document: document,
          fileName: fileName,
        );
      }
      return DeviceDownloadResult(error: e.message);
    }
  } on PapraApiException catch (e) {
    return DeviceDownloadResult(error: e.message);
  } catch (_) {
    return const DeviceDownloadResult(error: 'Could not download the file.');
  }
}

/// Fallback used when raw-path writes fail: download to a temp file, then
/// hand the bytes to the native save-file dialog.
Future<DeviceDownloadResult> _downloadViaSaveDialog({
  required ApiClient client,
  required PapraDocument document,
  required String fileName,
}) async {
  final temp = await getTemporaryDirectory();
  final tempPath = '${temp.path}/${document.id}_$fileName';
  try {
    await client.downloadDocument(documentId: document.id, savePath: tempPath);
    final bytes = await File(tempPath).readAsBytes();
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save “${document.name}”',
      fileName: fileName,
      bytes: bytes,
      type: FileType.any,
    );
    if (uri == null) return const DeviceDownloadResult(cancelled: true);
    return DeviceDownloadResult(path: uri.toString());
  } on PapraApiException catch (e) {
    return DeviceDownloadResult(error: e.message);
  } catch (_) {
    return const DeviceDownloadResult(error: 'Could not save the file.');
  } finally {
    await deleteFileIfExists(tempPath);
  }
}

/// Deletes a file if it exists. Never throws (best effort).
Future<void> deleteFileIfExists(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort.
  }
}

/// Opens a downloaded file with the system's default app for its type.
/// Returns a user-facing error message on failure, or null on success.
Future<String?> openWithSystemViewer(String filePath) async {
  final result = await OpenFilex.open(filePath);
  if (result.type == ResultType.done) return null;
  return result.message.isEmpty ? 'No app could open this file.' : result.message;
}
