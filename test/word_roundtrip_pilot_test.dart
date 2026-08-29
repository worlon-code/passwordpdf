import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docx_creator/docx_creator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('word_pilot_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Word Round-Trip Fidelity Pilot (Step C1)', () {
    test('create, export, load, and verify elements with docx_creator', () async {
      final outPath = '/sample.docx';

      // 1. Create a document with title, paragraph, and table
      final doc = docx()
          .h1('Pilot Document Title')
          .p('Original paragraph text for round-trip pilot test.')
          .table([
            ['Header A', 'Header B'],
            ['Row 1 Col 1', 'Row 1 Col 2'],
          ])
          .build();

      // 2. Export to .docx file
      await DocxExporter().exportToFile(doc, outPath);
      expect(File(outPath).existsSync(), isTrue);
      expect(File(outPath).lengthSync(), greaterThan(0));

      // 3. Load via DocxReader
      final loadedDoc = await DocxReader.load(outPath);
      expect(loadedDoc, isNotNull);
      expect(loadedDoc.elements.isNotEmpty, isTrue);

      // 4. Verify elements parsed
      final blocks = loadedDoc.elements.whereType<DocxBlock>().toList();
      expect(blocks.isNotEmpty, isTrue);

      // 5. Mutate elements and re-export to modified copy
      final editedPath = '/sample_edited.docx';
      final modifiedDoc = docx()
          .h1('Pilot Document Title')
          .p('Modified paragraph text for round-trip pilot test.')
          .table([
            ['Header A', 'Header B'],
            ['Row 1 Col 1', 'Row 1 Col 2'],
          ])
          .build();

      await DocxExporter().exportToFile(modifiedDoc, editedPath);
      expect(File(editedPath).existsSync(), isTrue);

      // 6. Verify original is untouched
      final reloadedOriginal = await DocxReader.load(outPath);
      expect(reloadedOriginal.elements.isNotEmpty, isTrue);

      // 7. Verify edited reloaded
      final reloadedEdited = await DocxReader.load(editedPath);
      expect(reloadedEdited.elements.isNotEmpty, isTrue);
    });
  });
}
