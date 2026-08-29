import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../../../services/pdf_password_service.dart';
import '../screens/pdf_viewer_screen.dart';
import '../screens/excel_viewer_screen.dart';
import '../screens/word_viewer_screen.dart';

enum OfficeOpenTarget { pdfInApp, wordInApp, excelInApp, externalHandoff }

/// Max size we render in-app; larger => external app (invariant 7).
const int kMaxInAppOfficeBytes = 25 * 1024 * 1024;

OfficeOpenTarget routeForPath(String path, {int? sizeBytes}) {
  if (sizeBytes != null && sizeBytes > kMaxInAppOfficeBytes) {
    return OfficeOpenTarget.externalHandoff;
  }
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'pdf':
      return OfficeOpenTarget.pdfInApp;
    case 'docx':
      return OfficeOpenTarget.wordInApp;
    case 'xlsx':
      return OfficeOpenTarget.excelInApp;
    case 'doc': // legacy binary — no OSS Dart reader (invariant 5)
    case 'xls':
    default:
      return OfficeOpenTarget.externalHandoff;
  }
}

/// Open a document via the right in-app screen, or hand off to an external app.
Future<void> openDocument(BuildContext context, String filePath) async {
  final fileName = filePath.split(Platform.pathSeparator).last;
  int? size;
  try {
    size = await File(filePath).length();
  } catch (_) {}

  switch (routeForPath(filePath, sizeBytes: size)) {
    case OfficeOpenTarget.pdfInApp:
      final stored = await PdfPasswordService().getPasswordForDocument(filePath);
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(
            filePath: filePath, fileName: fileName, password: stored),
      ));
      break;
    case OfficeOpenTarget.excelInApp:
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ExcelViewerScreen(filePath: filePath, fileName: fileName),
      ));
      break;
    case OfficeOpenTarget.wordInApp:
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WordViewerScreen(filePath: filePath, fileName: fileName),
      ));
      break;
    case OfficeOpenTarget.externalHandoff:
      if (context.mounted) {
        if (size != null && size > kMaxInAppOfficeBytes) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('File exceeds 25MB limit. Opening with external app…'),
              duration: Duration(seconds: 2),
            ),
          );
        } else {
          final ext = filePath.toLowerCase().split('.').last;
          if (ext == 'doc' || ext == 'xls') {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                content: Text('Legacy .$ext format. Opening with external app…'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
      await OpenFilex.open(filePath);
      break;
  }
}
