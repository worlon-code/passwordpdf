import 'dart:io';
import 'package:archive/archive.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../features/settings/services/settings_service.dart';

class ExcelSaveResult {
  final String savedPath;    // the NEW copy
  final bool verified;       // re-open round-trip matched
  final List<String> notes;  // anything we detected as dropped
  ExcelSaveResult(this.savedPath, this.verified, this.notes);
}

class ExcelEditService {
  /// Apply dirty cells to [sourcePath] and write a COPY (never overwrite).
  /// [dirty] key = sheetName!rowIdx,colField(cN).
  Future<ExcelSaveResult> saveCopyWithEdits(
      String sourcePath, Map<String, String> dirty) async {
    final bytes = await File(sourcePath).readAsBytes();
    final excel = Excel.decodeBytes(bytes);

    // Detect potential dropped features (invariant 4)
    final notes = <String>[];
    try {
      final zip = ZipDecoder().decodeBytes(bytes);
      for (final file in zip.files) {
        if (file.name.contains('xl/charts/') && !notes.contains('Charts may not be preserved in edited copy.')) {
          notes.add('Charts may not be preserved in edited copy.');
        }
        if (file.name.contains('xl/drawings/') && !notes.contains('Images/drawings may not be preserved in edited copy.')) {
          notes.add('Images/drawings may not be preserved in edited copy.');
        }
        if (file.name.contains('vbaProject.bin') && !notes.contains('VBA Macros are not preserved in edited copy.')) {
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
}
