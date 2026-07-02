import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:passwordpdf_manager/services/pdf_tools_service.dart';

void main() {
  test('PdfToolsService in-place split preserves form fields and bookmarks', () async {
    // 1. Create a 2-page PDF document
    final document = PdfDocument();
    
    // Add 2 pages
    final page1 = document.pages.add();
    document.pages.add();
    
    // Add one AcroForm field (PdfTextBoxField)
    final textTextBox = PdfTextBoxField(page1, 'textBoxField', const Rect.fromLTWH(0, 0, 100, 20));
    document.form.fields.add(textTextBox);
    
    // Add one bookmark
    document.bookmarks.add('Bookmark X');
    
    // Save to bytes
    final List<int> bytes = await document.save();
    document.dispose();
    
    // Write to a temporary file
    final tempDir = Directory.systemTemp.createTempSync();
    final tempFile = File('${tempDir.path}/form_bookmark.pdf');
    await tempFile.writeAsBytes(bytes);
    
    // 2. Perform splitPdf (in-place operation)
    final service = PdfToolsService();
    final splitPath = await service.splitPdf(
      filePath: tempFile.path,
      password: '',
      pageIndices: [0], // Keep only first page
    );
    
    // Load result and assert
    final resultBytes = await File(splitPath).readAsBytes();
    final resultDoc = PdfDocument(inputBytes: resultBytes);
    
    expect(resultDoc.form.fields.count, greaterThan(0));
    expect(resultDoc.bookmarks.count, greaterThan(0));
    
    resultDoc.dispose();
    
    // Clean up files
    tempDir.deleteSync(recursive: true);
  });
}
