import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import 'open_document.dart';

/// Progress snapshot for a batch download.
class BatchDownloadProgress {
  const BatchDownloadProgress({
    required this.completed,
    required this.total,
    required this.currentName,
  });

  final int completed;
  final int total;

  /// Name of the file currently being downloaded.
  final String currentName;
}

class BatchDownloadResult {
  const BatchDownloadResult({
    required this.completed,
    required this.failed,
    this.cancelled = false,
  });

  final int completed;

  /// Names of the documents that failed to download.
  final List<String> failed;

  final bool cancelled;
}

/// Downloads every document in [documents] into [destinationDir] with a small
/// worker pool (3 concurrent downloads). Files that already exist in the
/// destination are skipped. [onProgress] fires whenever a file starts or
/// finishes; [shouldCancel] is polled between files — in-flight downloads
/// finish, but no new ones start after it returns true.
Future<BatchDownloadResult> batchDownloadDocuments({
  required ApiClient client,
  required List<PapraDocument> documents,
  required String destinationDir,
  void Function(BatchDownloadProgress)? onProgress,
  bool Function()? shouldCancel,
}) async {
  const concurrency = 3;
  var completed = 0;
  final failed = <String>[];
  var cancelled = false;
  var nextIndex = 0;

  void emit(PapraDocument document) {
    onProgress?.call(BatchDownloadProgress(
      completed: completed,
      total: documents.length,
      currentName: document.name,
    ));
  }

  Future<void> worker() async {
    while (true) {
      if (shouldCancel?.call() ?? false) {
        cancelled = true;
        return;
      }
      final index = nextIndex++;
      if (index >= documents.length) return;
      final document = documents[index];
      emit(document);
      final ok = await _downloadOne(client, document, destinationDir);
      if (ok) {
        completed++;
      } else {
        failed.add(document.name);
      }
      emit(document);
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  return BatchDownloadResult(
    completed: completed,
    failed: failed,
    cancelled: cancelled,
  );
}

Future<bool> _downloadOne(ApiClient client, PapraDocument document, String dir) async {
  final fileName = safeFileName(document.name);
  final baseTarget = '$dir/$fileName';
  // Already saved from a previous run — skip instead of re-downloading.
  if (await File(baseTarget).exists()) return true;
  final target = await _uniquePath(dir, fileName);
  final partPath = '$target.part';
  try {
    await client.downloadDocument(documentId: document.id, savePath: partPath);
    var finalTarget = target;
    // Two same-named documents downloading concurrently could both target the
    // same path; if the name got taken while we were downloading, pick a
    // numbered variant instead of overwriting.
    if (await File(finalTarget).exists()) {
      finalTarget = await _uniquePath(dir, fileName);
    }
    await File(partPath).rename(finalTarget);
    return true;
  } catch (_) {
    await deleteFileIfExists(partPath);
    return false;
  }
}

/// Appends " (1)", " (2)"… before the extension until the path is free, so
/// concurrent downloads never clobber each other.
Future<String> _uniquePath(String dir, String fileName) async {
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  final ext = dot > 0 ? fileName.substring(dot) : '';
  var candidate = '$dir/$fileName';
  var counter = 1;
  while (await File(candidate).exists()) {
    candidate = '$dir/$base ($counter)$ext';
    counter++;
  }
  return candidate;
}

/// Paginates every document in the organization (server max page size is 100)
/// and returns those carrying [tagId]. The fork's search doesn't index tag
/// names, so filtering happens client-side.
Future<List<PapraDocument>> documentsWithTag(ApiClient client, String tagId) async {
  const pageSize = 100;
  final docs = <PapraDocument>[];
  var pageIndex = 0;
  while (true) {
    final resp = await client.listDocuments(pageIndex: pageIndex, pageSize: pageSize);
    docs.addAll(resp.documents.where((d) => d.tags.any((t) => t.id == tagId)));
    final collectedAll = resp.documents.isEmpty || docs.length >= resp.documentsCount;
    if (collectedAll) break;
    pageIndex++;
  }
  return docs;
}

/// Recursively collects every document under [folderId] (or the org root when
/// null), following subfolders breadth-first. Documents are deduplicated by
/// id.
Future<List<PapraDocument>> documentsInFolder(ApiClient client, {String? folderId}) async {
  final docs = <String, PapraDocument>{};
  final queue = <String?>[folderId];
  while (queue.isNotEmpty) {
    final id = queue.removeLast();
    final contents = await client.getFolderContents(folderId: id);
    for (final document in contents.documents) {
      docs.putIfAbsent(document.id, () => document);
    }
    queue.addAll(contents.folders.map((f) => f.id));
  }
  return docs.values.toList();
}

/// Mutable progress holder for a batch download dialog, driven by
/// [batchDownloadDocuments]' [onProgress].
class BatchDownloadController extends ChangeNotifier {
  BatchDownloadController({required this.total});

  final int total;
  int _completed = 0;
  String _currentName = '';
  bool _cancelled = false;

  int get completed => _completed;
  String get currentName => _currentName;
  bool get cancelled => _cancelled;
  double get fraction => total == 0 ? 0 : _completed / total;

  void cancel() => _cancelled = true;

  void update(BatchDownloadProgress progress) {
    _completed = progress.completed;
    _currentName = progress.currentName;
    notifyListeners();
  }
}

/// Runs the full "download a selection of documents to the device" flow:
/// SAF destination picker → enumerate documents → progress dialog → download.
///
/// Returns a user-facing summary message (empty for a no-op), or null when
/// the user cancelled the destination picker.
Future<String?> downloadSelectionToDevice({
  required BuildContext context,
  required ApiClient client,
  required String title,
  required Future<List<PapraDocument>> Function() enumerate,
}) async {
  final dir = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose where to save',
  );
  if (dir == null || dir.isEmpty) return null;
  if (!context.mounted) return null;

  final List<PapraDocument> documents;
  try {
    documents = await enumerate();
  } on PapraApiException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not load the documents to download.';
  }
  if (!context.mounted) return null;
  if (documents.isEmpty) return 'No documents to download.';

  final controller = showBatchDownloadDialog(
    context,
    title: title,
    total: documents.length,
  );
  if (!context.mounted) return null;

  final result = await batchDownloadDocuments(
    client: client,
    documents: documents,
    destinationDir: dir,
    onProgress: controller.update,
    shouldCancel: () => controller.cancelled,
  );

  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
  }
  if (result.cancelled) {
    return 'Download cancelled — ${result.completed} of ${documents.length} saved.';
  }
  if (result.failed.isNotEmpty) {
    return 'Downloaded ${result.completed} of ${documents.length}. '
        'Failed: ${result.failed.join(', ')}';
  }
  return 'Downloaded ${result.completed} of ${documents.length} to the selected folder.';
}

/// Shows the modal batch-download progress dialog and returns its controller
/// immediately. The caller drives it with [BatchDownloadController.update]
/// and closes the dialog with `Navigator.of(context, rootNavigator: true).pop()`.
/// The dialog's Cancel button sets `controller.cancelled`.
BatchDownloadController showBatchDownloadDialog(
  BuildContext context, {
  required String title,
  required int total,
}) {
  final controller = BatchDownloadController(total: total);
  unawaited(
    showDialog<BatchDownloadController>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _BatchDownloadDialog(controller: controller, title: title),
    ),
  );
  return controller;
}

class _BatchDownloadDialog extends StatefulWidget {
  const _BatchDownloadDialog({required this.controller, required this.title});

  final BatchDownloadController controller;
  final String title;

  @override
  State<_BatchDownloadDialog> createState() => _BatchDownloadDialogState();
}

class _BatchDownloadDialogState extends State<_BatchDownloadDialog> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return AlertDialog(
          title: Text(widget.title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${controller.completed} of ${controller.total} downloaded',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: controller.fraction),
              const SizedBox(height: 8),
              Text(
                controller.currentName.isEmpty
                    ? 'Preparing…'
                    : controller.currentName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: controller.cancel,
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }
}
