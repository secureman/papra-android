import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../core/storage/document_cache.dart';

/// Downloads the original file (fork: `GET /documents/:id/file`) to a temp
/// path — used for throwaway data like thumbnails. Returns the local path on
/// success, or a user-facing error message.
/// [onProgress] receives the download fraction (0.0–1.0) when the server
/// reports a content length.
Future<({String? path, String? error})> downloadDocumentToTemp({
  required ApiClient client,
  required PapraDocument document,
  void Function(double fraction)? onProgress,
}) async {
  try {
    final dir = await getTemporaryDirectory();
    final safeName = document.name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    final fileName = safeName.isEmpty ? '${document.id}.bin' : safeName;
    final path = '${dir.path}/$fileName';

    await client.downloadDocument(
      documentId: document.id,
      savePath: path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    return (path: path, error: null);
  } on PapraApiException catch (e) {
    return (path: null, error: e.message);
  } catch (_) {
    return (path: null, error: 'Could not download the file.');
  }
}

/// Opens (or downloads) the original file into the persistent document cache,
/// so it works offline and is only ever fetched once. Serves straight from
/// cache when already present. Returns the local path, or a user-facing error
/// message.
Future<({String? path, String? error})> downloadDocumentToCache({
  required ApiClient client,
  required PapraDocument document,
  void Function(double fraction)? onProgress,
}) async {
  try {
    final cache = DocumentCache.instance;
    final cached = await cache.cachedFilePath(document.id);
    if (cached != null) return (path: cached, error: null);

    final target = await cache.downloadPathFor(document.id, document.name);
    final partPath = '$target.part';
    await client.downloadDocument(
      documentId: document.id,
      savePath: partPath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    await cache.finalizeDownload(partPath, target);
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

/// Opens a downloaded file with the system's default app for its type.
/// Returns a user-facing error message on failure, or null on success.
Future<String?> openWithSystemViewer(String filePath) async {
  final result = await OpenFilex.open(filePath);
  if (result.type == ResultType.done) return null;
  return result.message.isEmpty ? 'No app could open this file.' : result.message;
}
