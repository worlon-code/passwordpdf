import 'package:flutter/material.dart';
import 'word_viewer_screen.dart';

/// Word editor screen that opens the unified Google Docs / Windows Word workspace in edit mode.
class WordEditorScreen extends StatelessWidget {
  final String filePath;
  final String fileName;

  const WordEditorScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    return WordViewerScreen(
      filePath: filePath,
      fileName: fileName,
      initialEditMode: true,
    );
  }
}
