import 'dart:ui';
import 'package:syncfusion_flutter_pdf/pdf.dart';

extension PdfDocumentImportExtension on PdfDocument {
  /// Import a range of pages from [sourceDocument] into this document.
  void importPageRange(PdfDocument sourceDocument, int startIndex, int endIndex) {
    for (int i = startIndex; i <= endIndex; i++) {
      if (i >= 0 && i < sourceDocument.pages.count) {
        final srcPage = sourceDocument.pages[i];
        final template = srcPage.createTemplate();
        // Create section with matching page size
        final section = sections!.add();
        section.pageSettings.size = srcPage.size;
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();
        page.graphics.drawPdfTemplate(template, const Offset(0, 0));
      }
    }
  }
}
