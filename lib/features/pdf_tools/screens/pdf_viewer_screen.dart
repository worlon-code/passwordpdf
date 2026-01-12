// TEMPORARY STUB: Original file used syncfusion_flutter_pdfviewer which conflicts with pdfrx v2
// TODO: Migrate to use pdfrx or remove this feature
import 'package:flutter/material.dart';

/// Stub PDF Viewer screen - original implementation used Syncfusion pdfviewer
/// which is incompatible with the current pdfrx v2 migration
class PdfViewerScreen extends StatelessWidget {
  final String filePath;
  final String password;

  const PdfViewerScreen({
    super.key,
    required this.filePath,
    this.password = '',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Viewer (Unavailable)'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning_amber, size: 64, color: Colors.orange),
            const SizedBox(height: 16),
            const Text(
              'This PDF viewer is temporarily unavailable.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'File: $filePath',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
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
}
