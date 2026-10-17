import 'package:flutter_test/flutter_test.dart';
import 'package:passwordpdf_manager/models/excel_workbook_model.dart';
import 'package:passwordpdf_manager/services/excel_formula_engine.dart';

void main() {
  group('ExcelFormulaEngine', () {
    late ExcelFormulaEngine engine;
    late ExcelSheetModel sheet;
    late ExcelWorkbookModel workbook;

    setUp(() {
      engine = ExcelFormulaEngine();
      sheet = ExcelSheetModel(name: 'Sheet1');
      workbook = ExcelWorkbookModel(sheets: [sheet]);
    });

    test('Arithmetic and Operator Precedence', () {
      expect(engine.evaluate(formula: '=1+2*3', sheet: sheet), equals(7.0));
      expect(engine.evaluate(formula: '=(10 - 4) / 2', sheet: sheet), equals(3.0));
      expect(engine.evaluate(formula: '=2^3', sheet: sheet), equals(8.0));
      expect(engine.evaluate(formula: '=50%', sheet: sheet), equals(0.5));
      expect(engine.evaluate(formula: '=-5 + 10', sheet: sheet), equals(5.0));
    });

    test('String Concatenation & Text Functions', () {
      expect(engine.evaluate(formula: '="Hello " & "World"', sheet: sheet), equals('Hello World'));
      expect(engine.evaluate(formula: '=UPPER("flutter")', sheet: sheet), equals('FLUTTER'));
      expect(engine.evaluate(formula: '=LOWER("EXCEL")', sheet: sheet), equals('excel'));
      expect(engine.evaluate(formula: '=TRIM("   spaced   ")', sheet: sheet), equals('spaced'));
      expect(engine.evaluate(formula: '=LEN("Antigravity")', sheet: sheet), equals(11.0));
      expect(engine.evaluate(formula: '=LEFT("PasswordPDF", 8)', sheet: sheet), equals('Password'));
      expect(engine.evaluate(formula: '=RIGHT("PasswordPDF", 3)', sheet: sheet), equals('PDF'));
      expect(engine.evaluate(formula: '=MID("abcdefgh", 3, 4)', sheet: sheet), equals('cdef'));
      expect(engine.evaluate(formula: '=CONCAT("A", "B", "C")', sheet: sheet), equals('ABC'));
    });

    test('Math and Statistical Functions', () {
      expect(engine.evaluate(formula: '=SUM(1, 2, 3, 4, 5)', sheet: sheet), equals(15.0));
      expect(engine.evaluate(formula: '=AVERAGE(10, 20, 30)', sheet: sheet), equals(20.0));
      expect(engine.evaluate(formula: '=PRODUCT(2, 3, 4)', sheet: sheet), equals(24.0));
      expect(engine.evaluate(formula: '=MIN(10, 5, 20, 2)', sheet: sheet), equals(2.0));
      expect(engine.evaluate(formula: '=MAX(10, 5, 20, 2)', sheet: sheet), equals(20.0));
      expect(engine.evaluate(formula: '=MEDIAN(1, 5, 2, 8, 7)', sheet: sheet), equals(5.0));
      expect(engine.evaluate(formula: '=ABS(-99)', sheet: sheet), equals(99.0));
      expect(engine.evaluate(formula: '=SQRT(144)', sheet: sheet), equals(12.0));
      expect(engine.evaluate(formula: '=ROUND(3.14159, 2)', sheet: sheet), equals(3.14));
      expect(engine.evaluate(formula: '=ROUNDUP(3.141, 2)', sheet: sheet), equals(3.15));
      expect(engine.evaluate(formula: '=ROUNDDOWN(3.149, 2)', sheet: sheet), equals(3.14));
    });

    test('Logical and Conditional Functions', () {
      expect(engine.evaluate(formula: '=IF(10 > 5, "yes", "no")', sheet: sheet), equals('yes'));
      expect(engine.evaluate(formula: '=IF(2 > 5, "yes", "no")', sheet: sheet), equals('no'));
      expect(engine.evaluate(formula: '=AND(TRUE, TRUE, TRUE)', sheet: sheet), isTrue);
      expect(engine.evaluate(formula: '=AND(TRUE, FALSE)', sheet: sheet), isFalse);
      expect(engine.evaluate(formula: '=OR(FALSE, TRUE)', sheet: sheet), isTrue);
      expect(engine.evaluate(formula: '=OR(FALSE, FALSE)', sheet: sheet), isFalse);
      expect(engine.evaluate(formula: '=NOT(TRUE)', sheet: sheet), isFalse);
      expect(engine.evaluate(formula: '=IFERROR(1/0, "caught")', sheet: sheet), equals('caught'));
    });

    test('Cell & Range References', () {
      sheet.setCell(0, 0, ExcelCellData(rawValue: '1,000')); // A1 with comma
      sheet.setCell(1, 0, ExcelCellData(rawValue: '20'));    // A2
      sheet.setCell(2, 0, ExcelCellData(rawValue: '30'));    // A3
      sheet.setCell(0, 1, ExcelCellData(rawValue: '5'));     // B1

      expect(engine.evaluate(formula: '=A1 + B1', sheet: sheet, workbook: workbook), equals(1005.0));
      expect(engine.evaluate(formula: '=SUM(A1:A3)', sheet: sheet, workbook: workbook), equals(1050.0));
      expect(engine.evaluate(formula: '=sum(a1:a3)', sheet: sheet, workbook: workbook), equals(1050.0));
      expect(engine.evaluate(formula: '=SUM(A1 : A3)', sheet: sheet, workbook: workbook), equals(1050.0));
      expect(engine.evaluate(formula: '=AVERAGE(A1:A3)', sheet: sheet, workbook: workbook), equals(350.0));

      // Test recalculateSheet
      sheet.setCell(3, 0, ExcelCellData(rawValue: '=SUM(A1:A3)', formula: '=SUM(A1:A3)')); // A4
      engine.recalculateSheet(sheet, workbook);
      expect(sheet.getCell(3, 0)?.evaluatedValue, equals('1050'));
    });

    test('VLOOKUP Table Search', () {
      sheet.setCell(0, 0, ExcelCellData(rawValue: 'apple'));
      sheet.setCell(0, 1, ExcelCellData(rawValue: '1.50', evaluatedValue: '1.50'));
      sheet.setCell(1, 0, ExcelCellData(rawValue: 'banana'));
      sheet.setCell(1, 1, ExcelCellData(rawValue: '0.75', evaluatedValue: '0.75'));
      sheet.setCell(2, 0, ExcelCellData(rawValue: 'cherry'));
      sheet.setCell(2, 1, ExcelCellData(rawValue: '3.00', evaluatedValue: '3.00'));

      final res = engine.evaluate(
        formula: '=VLOOKUP("banana", A1:B3, 2, FALSE)',
        sheet: sheet,
        workbook: workbook,
      );
      expect(res, equals('0.75'));
    });

    test('Error Handling: Division by Zero & Cycle Detection', () {
      expect(engine.evaluate(formula: '=10 / 0', sheet: sheet), equals('#DIV/0!'));

      // Circular reference: A1 = B1 + 1, B1 = A1 + 1
      sheet.setCell(0, 0, ExcelCellData(rawValue: '=B1 + 1', formula: '=B1 + 1')); // A1
      sheet.setCell(0, 1, ExcelCellData(rawValue: '=A1 + 1', formula: '=A1 + 1')); // B1

      final cycleRes = engine.evaluate(formula: '=A1', sheet: sheet, workbook: workbook);
      expect(cycleRes, equals('#CYCLE!'));
    });
  });
}
