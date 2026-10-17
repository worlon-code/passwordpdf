import 'package:flutter_test/flutter_test.dart';
import 'package:passwordpdf_manager/features/documents/services/office_open_router.dart';

void main() {
  group('OfficeOpenRouter routeForPath', () {
    test('routes .pdf to pdfInApp', () {
      expect(routeForPath('/path/to/sample.pdf'), equals(OfficeOpenTarget.pdfInApp));
      expect(routeForPath('SAMPLE.PDF'), equals(OfficeOpenTarget.pdfInApp));
    });

    test('routes .docx to wordInApp', () {
      expect(routeForPath('/path/to/sample.docx'), equals(OfficeOpenTarget.wordInApp));
      expect(routeForPath('REPORT.DOCX'), equals(OfficeOpenTarget.wordInApp));
    });

    test('routes .xlsx to excelInApp', () {
      expect(routeForPath('/path/to/sample.xlsx'), equals(OfficeOpenTarget.excelInApp));
      expect(routeForPath('SHEET.XLSX'), equals(OfficeOpenTarget.excelInApp));
    });

    test('routes legacy .doc and .xls to externalHandoff', () {
      expect(routeForPath('/path/to/old.doc'), equals(OfficeOpenTarget.externalHandoff));
      expect(routeForPath('/path/to/old.xls'), equals(OfficeOpenTarget.externalHandoff));
    });

    test('routes unknown extensions to externalHandoff', () {
      expect(routeForPath('/path/to/image.png'), equals(OfficeOpenTarget.externalHandoff));
      expect(routeForPath('/path/to/archive.zip'), equals(OfficeOpenTarget.externalHandoff));
    });

    test('routes oversized files (>25MB) to externalHandoff', () {
      const largeSize = 26 * 1024 * 1024;
      expect(routeForPath('large.docx', sizeBytes: largeSize), equals(OfficeOpenTarget.externalHandoff));
      expect(routeForPath('large.xlsx', sizeBytes: largeSize), equals(OfficeOpenTarget.externalHandoff));
      expect(routeForPath('normal.docx', sizeBytes: 1024), equals(OfficeOpenTarget.wordInApp));
    });
  });
}
