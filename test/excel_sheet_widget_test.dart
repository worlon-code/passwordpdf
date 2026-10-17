import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passwordpdf_manager/models/excel_workbook_model.dart';
import 'package:passwordpdf_manager/features/documents/widgets/excel_grid_canvas.dart';

void main() {
  testWidgets('ExcelGridCanvas mounts, switches sheets, and responds to controller without key collision', (WidgetTester tester) async {
    final sheet1 = ExcelSheetModel(name: 'Sheet1');
    final sheet2 = ExcelSheetModel(name: 'Sheet2');
    sheet1.setCell(0, 0, ExcelCellData(rawValue: 'Hello Sheet 1'));
    sheet2.setCell(0, 0, ExcelCellData(rawValue: 'Hello Sheet 2'));

    final controller = ExcelGridController();
    ExcelSheetModel activeSheet = sheet1;
    int activeSheetIndex = 0;
    double zoomScale = 1.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        activeSheet = sheet2;
                        activeSheetIndex = 1;
                      });
                    },
                    child: const Text('Switch to Sheet 2'),
                  ),
                  Expanded(
                    child: ExcelGridCanvas(
                      key: ValueKey('sheet_${activeSheetIndex}_${activeSheet.name}'),
                      controller: controller,
                      sheet: activeSheet,
                      zoomScale: zoomScale,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Hello Sheet 1'), findsOneWidget);

    // Switch sheets
    await tester.tap(find.text('Switch to Sheet 2'));
    await tester.pumpAndSettle();

    expect(find.text('Hello Sheet 2'), findsOneWidget);

    // Navigate to cell via controller
    controller.navigateToCell('B2');
    await tester.pumpAndSettle();

    // Update active cell formula/value via controller
    controller.updateActiveCellFormulaOrValue('UpdatedValue');
    await tester.pumpAndSettle();

    // Verify cell was updated
    expect(activeSheet.getCell(1, 1)?.rawValue, 'UpdatedValue');
  });
}
