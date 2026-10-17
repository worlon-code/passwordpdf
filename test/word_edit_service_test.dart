import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docx_creator/docx_creator.dart';
import 'package:passwordpdf_manager/services/word_edit_service.dart';
import 'package:passwordpdf_manager/models/word_document_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String testFilePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('word_edit_test_');
    testFilePath = '${tempDir.path}/sample.docx';

    final doc = docx()
        .p('First initial paragraph')
        .p('Second initial paragraph')
        .build();
    await DocxExporter().exportToFile(doc, testFilePath);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('WordEditService', () {
    test('saveCopyWithEdits preserves original and writes verified copy', () async {
      final service = WordEditService();
      final edits = {
        0: 'Edited first paragraph',
      };

      final result = await service.saveCopyWithEdits(testFilePath, edits);

      expect(result.verified, isTrue);
      expect(File(result.savedPath).existsSync(), isTrue);

      // Verify original file is unchanged (invariant 2)
      final origDoc = await DocxReader.load(testFilePath);
      final origP0 = origDoc.elements.whereType<DocxParagraph>().first;
      final origText = origP0.children.whereType<DocxText>().map((t) => t.content).join();
      expect(origText, equals('First initial paragraph'));

      // Verify edited copy contains new text
      final copyDoc = await DocxReader.load(result.savedPath);
      final copyP0 = copyDoc.elements.whereType<DocxParagraph>().first;
      final copyText = copyP0.children.whereType<DocxText>().map((t) => t.content).join();
      expect(copyText, equals('Edited first paragraph'));

      // Clean up copy
      if (File(result.savedPath).existsSync()) {
        await File(result.savedPath).delete();
      }
    });

    test('loadRichDocument loads legacy .doc file', () async {
      final service = WordEditService();
      final legacyPath = '${tempDir.path}/legacy_sample.doc';
      await File(legacyPath).writeAsString('Line 1 of legacy doc\nLine 2 of legacy doc');

      final doc = await service.loadRichDocument(legacyPath);
      expect(doc.blocks.isNotEmpty, isTrue);
      expect(doc.blocks.first.plainText, contains('Line 1 of legacy doc'));
    });

    test('WordTextRun supports linkUrl and copyWith preserves it', () {
      final run = WordTextRun(
        text: 'Google',
        linkUrl: 'https://google.com',
      );
      expect(run.linkUrl, equals('https://google.com'));

      final copy = run.copyWith(text: 'Alphabet');
      expect(copy.text, equals('Alphabet'));
      expect(copy.linkUrl, equals('https://google.com'));

      final overridden = run.copyWith(linkUrl: 'https://flutter.dev');
      expect(overridden.linkUrl, equals('https://flutter.dev'));
    });
  });
}
