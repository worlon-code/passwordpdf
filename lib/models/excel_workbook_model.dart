import 'package:flutter/material.dart';

/// Number formatting categories
enum ExcelNumberFormat {
  general,
  number,
  currency,
  percent,
  date,
}

/// Border definitions for an individual cell
class ExcelCellBorder {
  final bool top;
  final bool bottom;
  final bool left;
  final bool right;
  final String? colorHex;

  const ExcelCellBorder({
    this.top = false,
    this.bottom = false,
    this.left = false,
    this.right = false,
    this.colorHex,
  });

  bool get hasAny => top || bottom || left || right;

  ExcelCellBorder copyWith({
    bool? top,
    bool? bottom,
    bool? left,
    bool? right,
    String? colorHex,
  }) {
    return ExcelCellBorder(
      top: top ?? this.top,
      bottom: bottom ?? this.bottom,
      left: left ?? this.left,
      right: right ?? this.right,
      colorHex: colorHex ?? this.colorHex,
    );
  }
}

/// Visual formatting and styling for an Excel cell
class ExcelCellStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final double fontSize;
  final String? textColorHex;
  final String? fillColorHex;
  final TextAlign horizontalAlign;
  final bool wrapText;
  final ExcelNumberFormat numberFormat;
  final int decimalPlaces;
  final ExcelCellBorder borders;

  const ExcelCellStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontSize = 11.0,
    this.textColorHex,
    this.fillColorHex,
    this.horizontalAlign = TextAlign.left,
    this.wrapText = false,
    this.numberFormat = ExcelNumberFormat.general,
    this.decimalPlaces = 2,
    this.borders = const ExcelCellBorder(),
  });

  ExcelCellStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    double? fontSize,
    String? textColorHex,
    String? fillColorHex,
    TextAlign? horizontalAlign,
    bool? wrapText,
    ExcelNumberFormat? numberFormat,
    int? decimalPlaces,
    ExcelCellBorder? borders,
  }) {
    return ExcelCellStyle(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      fontSize: fontSize ?? this.fontSize,
      textColorHex: textColorHex ?? this.textColorHex,
      fillColorHex: fillColorHex ?? this.fillColorHex,
      horizontalAlign: horizontalAlign ?? this.horizontalAlign,
      wrapText: wrapText ?? this.wrapText,
      numberFormat: numberFormat ?? this.numberFormat,
      decimalPlaces: decimalPlaces ?? this.decimalPlaces,
      borders: borders ?? this.borders,
    );
  }
}

/// Represents a single cell with value, formula, and styling
class ExcelCellData {
  String rawValue;
  String? formula;
  String evaluatedValue;
  ExcelCellStyle style;

  ExcelCellData({
    required this.rawValue,
    this.formula,
    String? evaluatedValue,
    ExcelCellStyle? style,
  })  : evaluatedValue = evaluatedValue ?? rawValue,
        style = style ?? const ExcelCellStyle();

  bool get hasFormula => formula != null && formula!.startsWith('=');

  /// Formatted display value based on style
  String get displayValue {
    final val = evaluatedValue;
    if (val.isEmpty) return '';
    final numVal = double.tryParse(val.replaceAll(RegExp(r'[$,₹%]'), '').trim());
    if (numVal == null) return val;

    switch (style.numberFormat) {
      case ExcelNumberFormat.currency:
        return '\$${numVal.toStringAsFixed(style.decimalPlaces)}';
      case ExcelNumberFormat.percent:
        return '${(numVal * 100).toStringAsFixed(style.decimalPlaces)}%';
      case ExcelNumberFormat.number:
        final parts = numVal.toStringAsFixed(style.decimalPlaces).split('.');
        final intPart = parts[0].replaceAllMapped(
            RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},');
        return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
      case ExcelNumberFormat.general:
      case ExcelNumberFormat.date:
        return val;
    }
  }

  ExcelCellData copyWith({
    String? rawValue,
    String? formula,
    String? evaluatedValue,
    ExcelCellStyle? style,
  }) {
    return ExcelCellData(
      rawValue: rawValue ?? this.rawValue,
      formula: formula ?? this.formula,
      evaluatedValue: evaluatedValue ?? this.evaluatedValue,
      style: style ?? this.style,
    );
  }
}

/// Represents a 2D rectangular cell range (0-indexed)
class ExcelCellRange {
  final int startRow;
  final int startCol;
  final int endRow;
  final int endCol;

  const ExcelCellRange({
    required this.startRow,
    required this.startCol,
    required this.endRow,
    required this.endCol,
  });

  int get minRow => startRow < endRow ? startRow : endRow;
  int get maxRow => startRow > endRow ? startRow : endRow;
  int get minCol => startCol < endCol ? startCol : endCol;
  int get maxCol => startCol > endCol ? startCol : endCol;

  int get rowCount => maxRow - minRow + 1;
  int get colCount => maxCol - minCol + 1;
  int get cellCount => rowCount * colCount;

  bool contains(int row, int col) {
    return row >= minRow && row <= maxRow && col >= minCol && col <= maxCol;
  }

  String toA1String() {
    final start = rowColToCellCoordinate(minRow, minCol);
    if (rowCount == 1 && colCount == 1) return start;
    final end = rowColToCellCoordinate(maxRow, maxCol);
    return '$start:$end';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExcelCellRange &&
          runtimeType == other.runtimeType &&
          minRow == other.minRow &&
          maxRow == other.maxRow &&
          minCol == other.minCol &&
          maxCol == other.maxCol;

  @override
  int get hashCode => Object.hash(minRow, maxRow, minCol, maxCol);
}

/// Represents an individual worksheet
class ExcelSheetModel {
  String name;
  final Map<String, ExcelCellData> cells;
  final Map<int, double> columnWidths;
  final Map<int, double> rowHeights;
  final List<ExcelCellRange> mergedRanges;
  int frozenRows;
  int frozenColumns;
  int _maxRow = 0;
  int _maxCol = 0;

  ExcelSheetModel({
    required this.name,
    Map<String, ExcelCellData>? cells,
    Map<int, double>? columnWidths,
    Map<int, double>? rowHeights,
    List<ExcelCellRange>? mergedRanges,
    this.frozenRows = 0,
    this.frozenColumns = 0,
  })  : cells = cells ?? {},
        columnWidths = columnWidths ?? {},
        rowHeights = rowHeights ?? {},
        mergedRanges = mergedRanges ?? [] {
    _calculateDimensions();
  }

  void _calculateDimensions() {
    int mr = 0;
    int mc = 0;
    for (final key in cells.keys) {
      final rc = keyToRowCol(key);
      if (rc != null) {
        if (rc.$1 > mr) mr = rc.$1;
        if (rc.$2 > mc) mc = rc.$2;
      }
    }
    _maxRow = mr;
    _maxCol = mc;
  }

  /// Get cell at (row, col)
  ExcelCellData? getCell(int row, int col) {
    return cells[rowColToKey(row, col)];
  }

  /// Get or create cell at (row, col)
  ExcelCellData getOrCreateCell(int row, int col) {
    final key = rowColToKey(row, col);
    var cell = cells[key];
    if (cell == null) {
      cell = ExcelCellData(rawValue: '');
      cells[key] = cell;
      if (row > _maxRow) _maxRow = row;
      if (col > _maxCol) _maxCol = col;
    }
    return cell;
  }

  /// Set cell at (row, col)
  void setCell(int row, int col, ExcelCellData cell) {
    cells[rowColToKey(row, col)] = cell;
    if (row > _maxRow) _maxRow = row;
    if (col > _maxCol) _maxCol = col;
  }

  /// Max row index present (0-indexed) - O(1)
  int get maxRow => _maxRow;

  /// Max column index present (0-indexed) - O(1)
  int get maxCol => _maxCol;

  double getColumnWidth(int col) => columnWidths[col] ?? 84.0;
  double getRowHeight(int row) => rowHeights[row] ?? 28.0;

  ExcelCellRange? getMergedRangeForCell(int row, int col) {
    if (mergedRanges.isEmpty) return null;
    for (final r in mergedRanges) {
      if (r.contains(row, col)) return r;
    }
    return null;
  }
}

/// Top-level model for a workbook containing multiple sheets
class ExcelWorkbookModel {
  final List<ExcelSheetModel> sheets;
  int activeSheetIndex;

  ExcelWorkbookModel({
    List<ExcelSheetModel>? sheets,
    this.activeSheetIndex = 0,
  }) : sheets = sheets ?? [ExcelSheetModel(name: 'Sheet1')];

  ExcelSheetModel get activeSheet {
    if (sheets.isEmpty) {
      sheets.add(ExcelSheetModel(name: 'Sheet1'));
    }
    if (activeSheetIndex < 0 || activeSheetIndex >= sheets.length) {
      activeSheetIndex = 0;
    }
    return sheets[activeSheetIndex];
  }

  ExcelSheetModel? getSheetByName(String name) {
    for (final s in sheets) {
      if (s.name.toLowerCase() == name.toLowerCase()) return s;
    }
    return null;
  }
}

// -----------------------------------------------------------------------------
// Coordinate Helpers: A1 <-> (row, col)
// -----------------------------------------------------------------------------

String rowColToKey(int row, int col) => '$row:$col';

(int, int)? keyToRowCol(String key) {
  final parts = key.split(':');
  if (parts.length != 2) return null;
  final r = int.tryParse(parts[0]);
  final c = int.tryParse(parts[1]);
  if (r == null || c == null) return null;
  return (r, c);
}

String colIndexToLetters(int col) {
  String result = '';
  int c = col;
  while (c >= 0) {
    result = String.fromCharCode((c % 26) + 65) + result;
    c = (c ~/ 26) - 1;
  }
  return result;
}

int lettersToColIndex(String letters) {
  int result = 0;
  final clean = letters.toUpperCase().trim();
  for (int i = 0; i < clean.length; i++) {
    result = result * 26 + (clean.codeUnitAt(i) - 64);
  }
  return result - 1;
}

String rowColToCellCoordinate(int row, int col) {
  return '${colIndexToLetters(col)}${row + 1}';
}

(int, int)? cellCoordinateToRowCol(String coord) {
  final match = RegExp(r'^\$?([A-Za-z]+)\$?(\d+)$').firstMatch(coord.trim());
  if (match == null) return null;
  final colLetters = match.group(1)!;
  final rowNumber = int.tryParse(match.group(2)!);
  if (rowNumber == null || rowNumber < 1) return null;
  return (rowNumber - 1, lettersToColIndex(colLetters));
}
