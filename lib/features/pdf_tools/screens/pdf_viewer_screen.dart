import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import '../../recent_documents/services/recent_service.dart';

/// PDF Viewer screen for viewing PDF documents
class PdfViewerScreen extends StatefulWidget {
  final String filePath;
  final String password;

  const PdfViewerScreen({
    super.key,
    required this.filePath,
    this.password = '',
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final RecentService _recentService = RecentService();
  final PdfViewerController _pdfViewerController = PdfViewerController();

  @override
  void initState() {
    super.initState();
    _addToRecent();
  }

  Future<void> _addToRecent() async {
    await _recentService.addRecentDocument(widget.filePath);
  }

  Future<void> _sharePdf() async {
    try {
      await Share.shareXFiles(
        [XFile(widget.filePath)],
        text: 'Sharing PDF document',
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sharing: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.filePath.split(Platform.pathSeparator).last;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          fileName,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _sharePdf,
            tooltip: 'Share',
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              _pdfViewerController.clearSelection();
            },
            tooltip: 'Search',
          ),
        ],
      ),
      body: SfPdfViewer.file(
        File(widget.filePath),
        controller: _pdfViewerController,
        password: widget.password.isNotEmpty ? widget.password : null,
        onDocumentLoadFailed: (details) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to load PDF: ${details.error}'),
              backgroundColor: Colors.red,
            ),
          );
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  void dispose() {
    _pdfViewerController.dispose();
    super.dispose();
  }
}
