import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart';

class WordViewerScreen extends StatelessWidget {
  final String filePath;
  final String fileName;
  const WordViewerScreen({super.key, required this.filePath, required this.fileName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, overflow: TextOverflow.ellipsis),
        actions: [
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
