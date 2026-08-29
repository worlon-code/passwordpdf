import 'dart:io';
import 'package:docx_creator/docx_creator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../features/settings/services/settings_service.dart';

class WordToPdfService {
  /// Converts a .docx file to a .pdf file entirely offline using pure Dart.
  /// Returns the absolute path of the generated PDF file.
  Future<String> convertDocxToPdf(String docxPath) async {
    final doc = await DocxReader.load(docxPath);
    final dir = await _resolveWritableExportDir();
    final base = p.basenameWithoutExtension(docxPath);
    final pdfPath = _uniquePath(p.join(dir, '$base.pdf'));

    await PdfExporter().exportToFile(doc, pdfPath);
    return pdfPath;
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
