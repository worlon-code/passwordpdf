import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'dart:io';

/// PDF Viewer Screen - displays PDF files with zoom and scroll
class PdfViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  final String? password;
  final VoidCallback? onPasswordRequired;
  final VoidCallback? onSuccess;

  const PdfViewerScreen({
    super.key,
    required this.filePath,
    required this.fileName,
    this.password,
    this.onPasswordRequired,
    this.onSuccess,
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final GlobalKey<SfPdfViewerState> _pdfViewerKey = GlobalKey();
  bool _hasCalledSuccess = false;
  bool _hasCalledPasswordRequired = false;

  @override
  Widget build(BuildContext context) {
    // Check if file exists
    final file = File(widget.filePath);
    if (!file.existsSync()) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Error'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.red,
              ),
              const SizedBox(height: 16),
              const Text(
                'File not found',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                widget.fileName,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SfPdfViewer.file(
        file,
        key: _pdfViewerKey,
        password: widget.password ?? '',
        canShowScrollHead: true,
        canShowScrollStatus: true,
        canShowPaginationDialog: true,
        enableDoubleTapZooming: true,
        canShowPasswordDialog: false, // Disable Syncfusion's password dialog
        onDocumentLoaded: (details) {
          // PDF loaded successfully
          if (!_hasCalledSuccess && widget.onSuccess != null) {
            _hasCalledSuccess = true;
            widget.onSuccess!();
          }
        },
        onDocumentLoadFailed: (details) {
          // Check if password error
          final desc = details.description.toLowerCase();
          final err = details.error.toLowerCase();
          if (desc.contains('password') || err.contains('password') ||
              desc.contains('encrypted') || err.contains('encrypted')) {
            // Password required - trigger callback
            if (!_hasCalledPasswordRequired && widget.onPasswordRequired != null) {
              _hasCalledPasswordRequired = true;
              widget.onPasswordRequired!();
            } else if (widget.onPasswordRequired == null) {
              // No callback set - just go back
              Navigator.pop(context);
            }
          }
        },
      ),
    );
  }
}
