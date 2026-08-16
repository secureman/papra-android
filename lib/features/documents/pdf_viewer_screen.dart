import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// In-app PDF viewer. Renders the already-downloaded file at [filePath] with
/// pinch-zoom, scrolling and text selection via pdfrx (PDFium).
class PdfViewerScreen extends StatelessWidget {
  const PdfViewerScreen({super.key, required this.filePath, required this.fileName});

  final String filePath;
  final String fileName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: PdfViewer.file(
        filePath,
        params: PdfViewerParams(
          underflowAnchor: PdfPageAnchor.topCenter,
          backgroundColor: scheme.surfaceContainerLowest,
        ),
      ),
    );
  }
}
