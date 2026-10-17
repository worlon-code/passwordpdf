import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:passwordpdf_manager/services/excel_edit_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String testFilePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('excel_test_');
    testFilePath = '/sample.xlsx';

    // Create a minimal valid .xlsx with excel_plus
    final excel = Excel.createExcel();
    final sheet = excel['Sheet1'];
    sheet.updateCell(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      TextCellValue('Initial Value'),
    );
    final bytes = excel.save();
    await File(testFilePath).writeAsBytes(bytes!);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ExcelEditService', () {
    test('saveCopyWithEdits preserves original and writes verified copy', () async {
      final service = ExcelEditService();
      final dirty = {
        'Sheet1!0,c0': 'Modified Value',
      };

      final result = await service.saveCopyWithEdits(testFilePath, dirty);

      expect(result.verified, isTrue);
      expect(File(result.savedPath).existsSync(), isTrue);

      // Verify original file is unchanged (invariant 2)
      final originalExcel = Excel.decodeBytes(await File(testFilePath).readAsBytes());
      expect(
        originalExcel['Sheet1'].cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).value?.toString(),
        equals('Initial Value'),
      );

      // Verify edited copy contains new value
      final copyExcel = Excel.decodeBytes(await File(result.savedPath).readAsBytes());
      expect(
        copyExcel['Sheet1'].cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).value?.toString(),
        equals('Modified Value'),
      );

      // Clean up copy
      if (File(result.savedPath).existsSync()) {
        await File(result.savedPath).delete();
      }
    });

    test('loadRichWorkbook loads legacy .xls file (HTML table format)', () async {
      final service = ExcelEditService();
      final legacyPath = '${tempDir.path}/legacy_table.xls';
      await File(legacyPath).writeAsString('<table><tr><td>Col1</td><td>Col2</td></tr><tr><td>Val1</td><td>123</td></tr></table>');

      final wb = await service.loadRichWorkbook(legacyPath);
      expect(wb.sheets.isNotEmpty, isTrue);
      final sheet = wb.sheets.first;
      expect(sheet.getCell(0, 0)?.rawValue, equals('Col1'));
      expect(sheet.getCell(0, 1)?.rawValue, equals('Col2'));
      expect(sheet.getCell(1, 0)?.rawValue, equals('Val1'));
      expect(sheet.getCell(1, 1)?.rawValue, equals('123'));
    });

    test('loadRichWorkbook loads binary OLE2 .xls file (file_example_XLS_50.xls)', () async {
      final service = ExcelEditService();
      final wb = await service.loadRichWorkbook('test_files/file_example_XLS_50.xls');
      expect(wb.sheets.isNotEmpty, isTrue);
      final sheet = wb.sheets.first;
      // Header
      expect(sheet.getCell(0, 1)?.rawValue, equals('First Name'));
      expect(sheet.getCell(0, 2)?.rawValue, equals('Last Name'));
      expect(sheet.getCell(0, 4)?.rawValue, equals('Country'));
      // Row 1
      expect(sheet.getCell(1, 1)?.rawValue, equals('Dulce'));
      expect(sheet.getCell(1, 2)?.rawValue, equals('Abril'));
      expect(sheet.getCell(1, 4)?.rawValue, equals('United States'));
      // No replacement characters
      for (final cell in sheet.cells.values) {
        expect(cell.rawValue.contains('\uFFFD'), isFalse);
      }
    });
  });
}
