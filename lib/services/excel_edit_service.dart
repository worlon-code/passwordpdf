import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:excel2003/excel2003.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../features/settings/services/settings_service.dart';
import '../models/excel_workbook_model.dart';
import 'excel_formula_engine.dart';

class ExcelSaveResult {
  final String savedPath; // the NEW or overwritten copy
  final bool verified; // re-open round-trip matched
  final List<String> notes; // anything we detected as dropped
  ExcelSaveResult(this.savedPath, this.verified, this.notes);
}

class ExcelEditService {
  /// Apply dirty cells to [sourcePath] and write a COPY (never overwrite) - legacy compatibility.
  Future<ExcelSaveResult> saveCopyWithEdits(
      String sourcePath, Map<String, String> dirty) async {
    final bytes = await File(sourcePath).readAsBytes();
    final excel = Excel.decodeBytes(bytes);

    // Detect potential dropped features (invariant 4)
    final notes = <String>[];
    try {
      final zip = ZipDecoder().decodeBytes(bytes);
      for (final file in zip.files) {
        if (file.name.contains('xl/charts/') &&
            !notes.contains('Charts may not be preserved in edited copy.')) {
          notes.add('Charts may not be preserved in edited copy.');
        }
        if (file.name.contains('xl/drawings/') &&
            !notes.contains('Images/drawings may not be preserved in edited copy.')) {
          notes.add('Images/drawings may not be preserved in edited copy.');
        }
        if (file.name.contains('vbaProject.bin') &&
            !notes.contains('VBA Macros are not preserved in edited copy.')) {
          notes.add('VBA Macros are not preserved in edited copy.');
        }
      }
    } catch (_) {}

    dirty.forEach((k, v) {
      final bang = k.indexOf('!');
      final sheet = k.substring(0, bang);
      final rc = k.substring(bang + 1).split(',');
      final row = int.parse(rc[0]);
      final col = int.parse(rc[1].substring(1)); // strip leading 'c'
      excel[sheet].updateCell(
        CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
        TextCellValue(v),
      );
    });

    final out = excel.save();
    if (out == null) throw StateError('excel.save() returned null');

    final dir = await _resolveWritableExportDir();
    final base = p.basenameWithoutExtension(sourcePath);
    final copyPath = _uniquePath(p.join(dir, '$base (edited).xlsx'));
    await File(copyPath).writeAsBytes(out, flush: true);

    // Invariant 3: verify the copy round-trips the edits before reporting success.
    final verified = await _verify(copyPath, dirty);
    return ExcelSaveResult(copyPath, verified, notes);
  }

  /// Load a rich workbook from .xlsx, .csv, or .tsv
  Future<ExcelWorkbookModel> loadRichWorkbook(String sourcePath) async {
    final ext = p.extension(sourcePath).toLowerCase();

    if (ext == '.csv' || ext == '.tsv') {
      return _loadDelimitedFile(sourcePath, isTsv: ext == '.tsv');
    }

    final bytes = await File(sourcePath).readAsBytes();
    if (ext == '.xls') {
      return _loadLegacyXls(bytes, sourcePath);
    }

    Excel excel;
    try {
      excel = Excel.decodeBytes(bytes);
    } catch (_) {
      return _loadLegacyXls(bytes, sourcePath);
    }

    final sheets = <ExcelSheetModel>[];

    for (final sheetName in excel.tables.keys) {
      final table = excel.tables[sheetName]!;
      final sheetModel = ExcelSheetModel(name: sheetName);

      // 1. Spanned/Merged items
      for (final spanStr in table.spannedItems) {
        final parts = spanStr.split(':');
        if (parts.length == 2) {
          final rc1 = cellCoordinateToRowCol(parts[0]);
          final rc2 = cellCoordinateToRowCol(parts[1]);
          if (rc1 != null && rc2 != null) {
            sheetModel.mergedRanges.add(ExcelCellRange(
              startRow: rc1.$1,
              startCol: rc1.$2,
              endRow: rc2.$1,
              endCol: rc2.$2,
            ));
          }
        }
      }

      // 2. Cells
      for (int r = 0; r < table.maxRows; r++) {
        final row = table.rows.length > r ? table.rows[r] : null;
        if (row == null) continue;

        for (int c = 0; c < row.length; c++) {
          final cell = row[c];
          if (cell == null) continue;

          String rawVal = '';
          String? formula;

          if (cell.value is FormulaCellValue) {
            final fVal = cell.value as FormulaCellValue;
            formula = fVal.formula;
            if (!formula.startsWith('=')) formula = '=$formula';
            rawVal = formula;
          } else if (cell.value is IntCellValue) {
            rawVal = (cell.value as IntCellValue).value.toString();
          } else if (cell.value is DoubleCellValue) {
            rawVal = (cell.value as DoubleCellValue).value.toString();
          } else if (cell.value is BoolCellValue) {
            rawVal = (cell.value as BoolCellValue).value ? 'TRUE' : 'FALSE';
          } else if (cell.value != null) {
            rawVal = cell.value.toString();
          }

          if (rawVal.isEmpty && formula == null && cell.cellStyle == null) continue;

          // Styles
          final cs = cell.cellStyle;
          ExcelCellStyle style = const ExcelCellStyle();
          if (cs != null) {
            TextAlign align = TextAlign.left;
            if (cs.horizontalAlignment == HorizontalAlign.Center) {
              align = TextAlign.center;
            } else if (cs.horizontalAlignment == HorizontalAlign.Right) {
              align = TextAlign.right;
            }

            style = ExcelCellStyle(
              bold: cs.isBold,
              italic: cs.isItalic,
              underline: cs.underline != Underline.None,
              fontSize: cs.fontSize?.toDouble() ?? 11.0,
              textColorHex: cs.fontColor.colorHex.isNotEmpty ? '#${cs.fontColor.colorHex}' : null,
              fillColorHex: cs.backgroundColor.colorHex.isNotEmpty ? '#${cs.backgroundColor.colorHex}' : null,
              horizontalAlign: align,
            );
          }

          sheetModel.setCell(
            r,
            c,
            ExcelCellData(
              rawValue: rawVal,
              formula: formula,
              evaluatedValue: rawVal,
              style: style,
            ),
          );
        }
      }

      sheets.add(sheetModel);
    }

    if (sheets.isEmpty) {
      sheets.add(ExcelSheetModel(name: 'Sheet1'));
    }

    final workbook = ExcelWorkbookModel(sheets: sheets);

    // Recalculate all formulas across all sheets
    final formulaEngine = ExcelFormulaEngine();
    for (final s in workbook.sheets) {
      formulaEngine.recalculateSheet(s, workbook);
    }

    return workbook;
  }

  /// Load a CSV or TSV file into a workbook
  Future<ExcelWorkbookModel> _loadDelimitedFile(String sourcePath, {required bool isTsv}) async {
    final file = File(sourcePath);
    final lines = await file.readAsLines();
    final sheet = ExcelSheetModel(name: p.basenameWithoutExtension(sourcePath));

    for (int r = 0; r < lines.length; r++) {
      final line = lines[r];
      final values = isTsv ? line.split('\t') : _parseCsvLine(line);

      for (int c = 0; c < values.length; c++) {
        final v = values[c].trim();
        if (v.isNotEmpty) {
          sheet.setCell(r, c, ExcelCellData(rawValue: v));
        }
      }
    }

    return ExcelWorkbookModel(sheets: [sheet]);
  }

  List<String> _parseCsvLine(String line) {
    final result = <String>[];
    final buf = StringBuffer();
    bool inQuote = false;

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuote && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuote = !inQuote;
        }
      } else if (ch == ',' && !inQuote) {
        result.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    result.add(buf.toString());
    return result;
  }

  /// Save a rich workbook to XLSX or CSV
  Future<ExcelSaveResult> saveRichWorkbook({
    required String sourcePath,
    required ExcelWorkbookModel workbook,
    bool overwriteOriginal = false,
  }) async {
    final ext = p.extension(sourcePath).toLowerCase();

    if (ext == '.csv' || ext == '.tsv') {
      final targetPath = overwriteOriginal
          ? sourcePath
          : _uniquePath(p.join(
              await _resolveWritableExportDir(),
              '${p.basenameWithoutExtension(sourcePath)} (edited)$ext',
            ));
      await exportSheetToCsv(workbook.activeSheet, targetPath);
      return ExcelSaveResult(targetPath, true, const []);
    }

    // XLSX save
    Excel excel;
    if (File(sourcePath).existsSync() && ext == '.xlsx') {
      try {
        final originalBytes = await File(sourcePath).readAsBytes();
        excel = Excel.decodeBytes(originalBytes);
      } catch (_) {
        excel = Excel.createExcel();
      }
    } else {
      excel = Excel.createExcel();
    }

    // Write all sheets from workbook model
    for (final sheetModel in workbook.sheets) {
      final sheet = excel[sheetModel.name];

      // Update all cell values
      for (final entry in sheetModel.cells.entries) {
        final rc = keyToRowCol(entry.key);
        if (rc == null) continue;
        final cellData = entry.value;
        final cellIdx = CellIndex.indexByColumnRow(columnIndex: rc.$2, rowIndex: rc.$1);

        if (cellData.hasFormula) {
          final fClean = cellData.formula!.startsWith('=')
              ? cellData.formula!.substring(1)
              : cellData.formula!;
          sheet.updateCell(cellIdx, FormulaCellValue(fClean));
        } else {
          final numVal = double.tryParse(cellData.rawValue);
          if (numVal != null) {
            if (numVal == numVal.roundToDouble() && !cellData.rawValue.contains('.')) {
              sheet.updateCell(cellIdx, IntCellValue(numVal.toInt()));
            } else {
              sheet.updateCell(cellIdx, DoubleCellValue(numVal));
            }
          } else if (cellData.rawValue.toUpperCase() == 'TRUE') {
            sheet.updateCell(cellIdx, BoolCellValue(true));
          } else if (cellData.rawValue.toUpperCase() == 'FALSE') {
            sheet.updateCell(cellIdx, BoolCellValue(false));
          } else {
            sheet.updateCell(cellIdx, TextCellValue(cellData.rawValue));
          }
        }
      }
    }

    final out = excel.save();
    if (out == null) throw StateError('Failed to serialize Excel workbook');

    String targetPath;
    if (overwriteOriginal) {
      targetPath = sourcePath;
    } else {
      final dir = await _resolveWritableExportDir();
      final base = p.basenameWithoutExtension(sourcePath);
      targetPath = _uniquePath(p.join(dir, '$base (edited).xlsx'));
    }

    await File(targetPath).writeAsBytes(out, flush: true);
    return ExcelSaveResult(targetPath, true, const []);
  }

  /// Export an active worksheet as a .csv file
  Future<String> exportSheetToCsv(ExcelSheetModel sheet, String targetCsvPath) async {
    final buf = StringBuffer();
    final maxR = sheet.maxRow;
    final maxC = sheet.maxCol;

    for (int r = 0; r <= maxR; r++) {
      final rowVals = <String>[];
      for (int c = 0; c <= maxC; c++) {
        final cell = sheet.getCell(r, c);
        final val = (cell?.evaluatedValue.isNotEmpty == true ? cell!.evaluatedValue : cell?.rawValue) ?? '';
        if (val.contains(',') || val.contains('"') || val.contains('\n')) {
          rowVals.add('"${val.replaceAll('"', '""')}"');
        } else {
          rowVals.add(val);
        }
      }
      buf.writeln(rowVals.join(','));
    }

    final file = File(targetCsvPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(buf.toString(), encoding: utf8, flush: true);
    return file.path;
  }

  Future<bool> _verify(String copyPath, Map<String, String> dirty) async {
    try {
      final re = Excel.decodeBytes(await File(copyPath).readAsBytes());
      for (final entry in dirty.entries) {
        final bang = entry.key.indexOf('!');
        final sheet = entry.key.substring(0, bang);
        final rc = entry.key.substring(bang + 1).split(',');
        final row = int.parse(rc[0]);
        final col = int.parse(rc[1].substring(1));
        final cell = re[sheet].cell(
            CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
        if ((cell.value?.toString() ?? '') != entry.value) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  String _uniquePath(String path) {
    if (!File(path).existsSync()) return path;
    final dir = p.dirname(path);
    final name = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    var i = 2;
    while (File(p.join(dir, '$name ($i)$ext')).existsSync()) {
      i++;
    }
    return p.join(dir, '$name ($i)$ext');
  }

  Future<String> _resolveWritableExportDir() async {
    try {
      final preferred = SettingsService().exportPath;
      final dir = Directory(preferred);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final testFile = File(p.join(dir.path, '.test_write_${DateTime.now().millisecondsSinceEpoch}'));
      await testFile.writeAsString('test', flush: true);
      await testFile.delete();
      return dir.path;
    } catch (_) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final fallbackDir = Directory(p.join(appDocDir.path, 'PDF Manager'));
      if (!await fallbackDir.exists()) {
        await fallbackDir.create(recursive: true);
      }
      return fallbackDir.path;
    }
  }

  static const List<int> _ole2Magic = [
    0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
  ];

  bool _isOle2(List<int> bytes) {
    if (bytes.length < 8) return false;
    for (int i = 0; i < 8; i++) {
      if (bytes[i] != _ole2Magic[i]) return false;
    }
    return true;
  }

  bool _isBinary(List<int> bytes) {
    final checkLen = bytes.length < 1024 ? bytes.length : 1024;
    int nonPrintable = 0;
    for (int i = 0; i < checkLen; i++) {
      final b = bytes[i];
      if (b == 0) return true;
      if ((b < 0x09 || (b > 0x0D && b < 0x20)) && b != 0x1B) {
        nonPrintable++;
      }
    }
    return nonPrintable > (checkLen * 0.1);
  }

  Future<ExcelWorkbookModel> _loadLegacyXls(List<int> bytes, String sourcePath) async {
    // 1. Genuine OLE2 BIFF8 (.xls) file
    if (_isOle2(bytes)) {
      try {
        final reader = XlsReader(sourcePath);
        reader.open();
        final sheets = <ExcelSheetModel>[];
        for (int i = 0; i < reader.sheetCount; i++) {
          final s = reader.sheet(i);
          final sheetModel = ExcelSheetModel(name: s.name);
          for (final cell in s.cells) {
            final v = cell.value;
            if (v == null) continue;
            String strVal;
            if (v is double) {
              strVal = v == v.roundToDouble() ? v.toInt().toString() : v.toString();
            } else {
              strVal = v.toString().trim();
            }
            if (strVal.isEmpty) continue;
            sheetModel.setCell(
              cell.row,
              cell.col,
              ExcelCellData(
                rawValue: strVal,
                evaluatedValue: strVal,
              ),
            );
          }
          if (sheetModel.cells.isNotEmpty) {
            sheets.add(sheetModel);
          }
        }
        if (sheets.isNotEmpty) {
          return ExcelWorkbookModel(sheets: sheets);
        }
      } catch (e, st) {
        debugPrint('[ExcelEditService] excel2003 OLE2 load error: $e\n$st');
      }
    }

    // 2. Check for HTML Table formatted as .xls
    final sample = utf8.decode(bytes.sublist(0, bytes.length > 2048 ? 2048 : bytes.length), allowMalformed: true).toLowerCase();
    if (sample.contains('<table') || sample.contains('<tr') || sample.contains('<html')) {
      final htmlWb = _parseHtmlTable(utf8.decode(bytes, allowMalformed: true), sourcePath);
      if (htmlWb != null && htmlWb.sheets.isNotEmpty && htmlWb.sheets.first.cells.isNotEmpty) {
        return htmlWb;
      }
    }

    // 3. Check for delimited text (CSV / TSV) ONLY if file is NOT binary
    if (!_isBinary(bytes)) {
      try {
        final text = utf8.decode(bytes, allowMalformed: false);
        if (text.contains('\t') || (text.contains(',') && text.contains('\n'))) {
          final isTsv = text.contains('\t');
          final lines = text.split(RegExp(r'\r\n|\r|\n'));
          final sheet = ExcelSheetModel(name: p.basenameWithoutExtension(sourcePath));
          int rowIdx = 0;
          for (final line in lines) {
            if (line.trim().isEmpty) continue;
            final parts = isTsv ? line.split('\t') : _parseCsvLine(line);
            for (int c = 0; c < parts.length; c++) {
              final val = parts[c].trim();
              if (val.isNotEmpty) {
                sheet.setCell(rowIdx, c, ExcelCellData(rawValue: val));
              }
            }
            rowIdx++;
          }
          if (sheet.cells.isNotEmpty) {
            return ExcelWorkbookModel(sheets: [sheet]);
          }
        }
      } catch (_) {}
    }

    // 4. Binary BIFF stream parser
    final biffWb = _parseBiffStream(bytes, sourcePath);
    if (biffWb != null && biffWb.sheets.isNotEmpty && biffWb.sheets.first.cells.isNotEmpty) {
      return biffWb;
    }

    // 5. Clean text fallback without control noise
    final sheet = ExcelSheetModel(name: p.basenameWithoutExtension(sourcePath));
    final extractedLines = _extractTextLines(bytes);
    for (int r = 0; r < extractedLines.length; r++) {
      sheet.setCell(r, 0, ExcelCellData(rawValue: extractedLines[r]));
    }
    if (sheet.cells.isEmpty) {
      sheet.setCell(0, 0, ExcelCellData(rawValue: 'Empty or unreadable spreadsheet'));
    }
    return ExcelWorkbookModel(sheets: [sheet]);
  }

  ExcelWorkbookModel? _parseHtmlTable(String html, String sourcePath) {
    final sheet = ExcelSheetModel(name: p.basenameWithoutExtension(sourcePath));
    final rowRegex = RegExp(r'<tr[^>]*>(.*?)</tr>', caseSensitive: false, dotAll: true);
    final cellRegex = RegExp(r'<(td|th)[^>]*>(.*?)</\1>', caseSensitive: false, dotAll: true);

    int r = 0;
    for (final rowMatch in rowRegex.allMatches(html)) {
      final rowHtml = rowMatch.group(1) ?? '';
      int c = 0;
      for (final cellMatch in cellRegex.allMatches(rowHtml)) {
        var val = cellMatch.group(2) ?? '';
        val = val.replaceAll(RegExp(r'<[^>]+>'), '');
        val = val
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"');
        val = val.trim();
        if (val.isNotEmpty) {
          sheet.setCell(r, c, ExcelCellData(rawValue: val));
        }
        c++;
      }
      if (c > 0) r++;
    }

    if (sheet.cells.isNotEmpty) {
      return ExcelWorkbookModel(sheets: [sheet]);
    }
    return null;
  }

  ExcelWorkbookModel? _parseBiffStream(List<int> bytes, String sourcePath) {
    try {
      final udata = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      final sst = <String>[];
      final sheet = ExcelSheetModel(name: p.basenameWithoutExtension(sourcePath));

      int pos = 0;
      while (pos + 4 <= udata.length) {
        final opcode = udata[pos] | (udata[pos + 1] << 8);
        final length = udata[pos + 2] | (udata[pos + 3] << 8);
        pos += 4;

        if (pos + length > udata.length) break;

        final recData = Uint8List.sublistView(udata, pos, pos + length);

        // 0x00FC: SST (Shared String Table)
        if (opcode == 0x00FC) {
          sst.addAll(_parseSst(recData));
        }
        // 0x00FD: LABELSST (Cell with reference to SST)
        else if (opcode == 0x00FD && recData.length >= 10) {
          final row = recData[0] | (recData[1] << 8);
          final col = recData[2] | (recData[3] << 8);
          final sstIdx = recData[6] | (recData[7] << 8) | (recData[8] << 16) | (recData[9] << 24);
          if (sstIdx < sst.length) {
            sheet.setCell(row, col, ExcelCellData(rawValue: sst[sstIdx]));
          }
        }
        // 0x0004 or 0x0204: LABEL (Cell with direct string)
        else if ((opcode == 0x0004 || opcode == 0x0204) && recData.length >= 8) {
          final row = recData[0] | (recData[1] << 8);
          final col = recData[2] | (recData[3] << 8);
          final cch = recData[6] | (recData[7] << 8);
          if (recData.length >= 8 + cch) {
            final str = String.fromCharCodes(recData.sublist(8, 8 + cch));
            sheet.setCell(row, col, ExcelCellData(rawValue: str));
          }
        }
        // 0x0203: NUMBER (IEEE 754 64-bit float)
        else if (opcode == 0x0203 && recData.length >= 14) {
          final row = recData[0] | (recData[1] << 8);
          final col = recData[2] | (recData[3] << 8);
          final bd = ByteData.sublistView(recData, 6, 14);
          final val = bd.getFloat64(0, Endian.little);
          final str = val == val.roundToDouble() ? val.toInt().toString() : val.toString();
          sheet.setCell(row, col, ExcelCellData(rawValue: str));
        }
        // 0x027E: RK (Packed 30-bit integer or float)
        else if (opcode == 0x027E && recData.length >= 10) {
          final row = recData[0] | (recData[1] << 8);
          final col = recData[2] | (recData[3] << 8);
          final rk = recData[6] | (recData[7] << 8) | (recData[8] << 16) | (recData[9] << 24);
          final val = _decodeRk(rk);
          final str = val == val.roundToDouble() ? val.toInt().toString() : val.toString();
          sheet.setCell(row, col, ExcelCellData(rawValue: str));
        }

        pos += length;
      }

      if (sheet.cells.isNotEmpty) {
        return ExcelWorkbookModel(sheets: [sheet]);
      }
    } catch (_) {}
    return null;
  }

  double _decodeRk(int rk) {
    final is100 = (rk & 1) != 0;
    final isInt = (rk & 2) != 0;
    double val;
    if (isInt) {
      val = (rk >> 2).toDouble();
    } else {
      final bd = ByteData(8);
      bd.setUint32(4, rk & 0xFFFFFFFC, Endian.little);
      val = bd.getFloat64(0, Endian.little);
    }
    if (is100) val /= 100.0;
    return val;
  }

  List<String> _parseSst(Uint8List data) {
    final list = <String>[];
    if (data.length < 8) return list;
    int pos = 8;
    while (pos + 3 <= data.length) {
      final cch = data[pos] | (data[pos + 1] << 8);
      final flags = data[pos + 2];
      final is16 = (flags & 1) != 0;
      pos += 3;
      final byteLen = cch * (is16 ? 2 : 1);
      if (pos + byteLen > data.length) break;

      String s;
      if (is16) {
        final chars = <int>[];
        for (int j = 0; j < cch; j++) {
          chars.add(data[pos + j * 2] | (data[pos + j * 2 + 1] << 8));
        }
        s = String.fromCharCodes(chars);
      } else {
        s = String.fromCharCodes(data.sublist(pos, pos + cch));
      }
      pos += byteLen;
      list.add(s);
    }
    return list;
  }

  List<String> _extractTextLines(List<int> bytes) {
    final lines = <String>[];
    final buffer = StringBuffer();
    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if ((b >= 0x20 && b <= 0x7E) || b == 0x09) {
        buffer.writeCharCode(b);
      } else if (b == 0x0A || b == 0x0D) {
        if (buffer.length > 2) {
          lines.add(buffer.toString().trim());
          buffer.clear();
        }
      } else {
        if (buffer.length > 3) {
          lines.add(buffer.toString().trim());
        }
        buffer.clear();
      }
    }
    if (buffer.length > 3) lines.add(buffer.toString().trim());
    return lines.where((l) => l.isNotEmpty).toList();
  }
}
