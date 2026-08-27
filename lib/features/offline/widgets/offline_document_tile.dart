import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/utils/format.dart';
import '../../../shared/widgets/tag_chip.dart';
import '../offline_models.dart';
import '../widgets/offline_document_thumbnail.dart';

/// One document row inside the offline browser. Shared by the Documents,
/// Tags and Folders views so every entry point looks identical.
class OfflineDocumentTile extends StatelessWidget {
  const OfflineDocumentTile({
    super.key,
    required this.document,
    required this.filePath,
    required this.thumbsDir,
  });

  final OfflineDocument document;
  final String filePath;
  final String thumbsDir;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: offlineThumbnailable(document)
          ? OfflineDocumentThumbnail(
              document: document,
              filePath: filePath,
              thumbsDir: thumbsDir,
              size: 44,
            )
          : CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.description_outlined, color: scheme.onPrimaryContainer),
            ),
      title: Text(document.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatBytes(document.size)} · ${formatDate(document.createdAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (document.folderPath.isNotEmpty)
            Text(
              document.folderPath.join(' / '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          if (document.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [for (final tag in document.tags.take(4)) TagChip(tag: tag.asPapraTag())],
              ),
            ),
        ],
      ),
      trailing: document.isPdf
          ? Icon(Icons.picture_as_pdf_outlined, size: 18, color: scheme.primary)
          : null,
      onTap: () => context.push('/offline/document/${document.id}'),
    );
  }
}
