import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docx_creator/docx_creator.dart';
import 'package:passwordpdf_manager/services/word_to_pdf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String docxPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('word_to_pdf_test_');
    docxPath = '/test_doc.docx';

    final doc = docx()
        .h1('Document for PDF Conversion')
        .p('Testing offline pure-Dart Word to PDF export.')
        .build();
    await DocxExporter().exportToFile(doc, docxPath);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('WordToPdfService', () {
    test('converts docx to valid pdf file', () async {
      final service = WordToPdfService();
      final pdfPath = await service.convertDocxToPdf(docxPath);

      expect(File(pdfPath).existsSync(), isTrue);
      expect(File(pdfPath).lengthSync(), greaterThan(0));
      expect(pdfPath.endsWith('.pdf'), isTrue);

      // Verify PDF header bytes (%PDF-)
      final bytes = await File(pdfPath).readAsBytes();
      final header = String.fromCharCodes(bytes.sublist(0, 5));
      expect(header, equals('%PDF-'));

      // Clean up
      if (File(pdfPath).existsSync()) {
        await File(pdfPath).delete();
      }
    });
  });
}
