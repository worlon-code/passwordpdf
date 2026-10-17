import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart';

import '../../../services/word_to_pdf_service.dart';
import '../services/office_open_router.dart';
import 'word_editor_screen.dart';

class WordViewerScreen extends StatelessWidget {
  final String filePath;
  final String fileName;
  const WordViewerScreen({super.key, required this.filePath, required this.fileName});

  Future<void> _exportToPdf(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Exporting to PDF…')));
    try {
      final pdfPath = await WordToPdfService().convertDocxToPdf(filePath);
      final pdfName = pdfPath.split(Platform.pathSeparator).last;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Exported to PDF: $pdfName'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () {
              if (context.mounted) {
                openDocument(context, pdfPath);
              }
            },
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Export to PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: () => _exportToPdf(context),
          ),
          IconButton(
            tooltip: 'Edit Document',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => WordEditorScreen(
                    filePath: filePath,
                    fileName: fileName,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Open with another app',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => OpenFilex.open(filePath), // invariant 8
          ),
        ],
      ),
      body: _DocxBody(filePath: filePath),
    );
  }
}

class _DocxBody extends StatelessWidget {
  final String filePath;
  const _DocxBody({required this.filePath});
  @override
  Widget build(BuildContext context) {
    try {
      return DocxView.file(
        File(filePath),
        config: const DocxViewConfig(enableZoom: true, enableSelection: true),
      );
    } catch (e) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => OpenFilex.open(filePath),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open with another app'),
        ),
      );
    }
  }
}
