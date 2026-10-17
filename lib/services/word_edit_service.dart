import 'dart:io';
import 'package:docx_creator/docx_creator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../features/settings/services/settings_service.dart';

class WordSaveResult {
  final String savedPath;
  final bool verified;
  final List<String> notes;
  WordSaveResult(this.savedPath, this.verified, this.notes);
}

class WordEditService {
  /// Save a copy with updated paragraph texts.
  /// [editedParagraphs] maps paragraph index (0-indexed) to new string content.
  Future<WordSaveResult> saveCopyWithEdits(
    String sourcePath,
    Map<int, String> editedParagraphs,
  ) async {
    final doc = await DocxReader.load(sourcePath);
    final builder = docx();

    int pIndex = 0;
    for (final element in doc.elements) {
      if (element is DocxParagraph) {
        if (editedParagraphs.containsKey(pIndex)) {
          builder.p(editedParagraphs[pIndex]!);
        } else {
          final text = element.children
              .whereType<DocxText>()
              .map((t) => t.content)
              .join();
          if (element.styleId?.toLowerCase().contains('heading 1') == true) {
            builder.h1(text);
          } else if (element.styleId?.toLowerCase().contains('heading 2') == true) {
            builder.h2(text);
          } else {
            builder.p(text);
          }
        }
        pIndex++;
      } else if (element is DocxTable) {
        final rows = <List<String>>[];
        for (final row in element.rows) {
          final cells = <String>[];
          for (final cell in row.cells) {
            final cellText = cell.children
                .whereType<DocxParagraph>()
                .map((p) => p.children.whereType<DocxText>().map((t) => t.content).join())
                .join(' ');
            cells.add(cellText);
          }
          rows.add(cells);
        }
        if (rows.isNotEmpty) {
          builder.table(rows);
        }
      }
    }

    final builtDoc = builder.build();

    final dir = await _resolveWritableExportDir();
    final base = p.basenameWithoutExtension(sourcePath);
    final copyPath = _uniquePath(p.join(dir, '$base (edited).docx'));

    await DocxExporter().exportToFile(builtDoc, copyPath);

    // Invariant 3: verify the copy round-trips
    final verified = await _verify(copyPath, editedParagraphs);
    return WordSaveResult(copyPath, verified, const []);
  }

  Future<bool> _verify(String copyPath, Map<int, String> editedParagraphs) async {
    try {
      final doc = await DocxReader.load(copyPath);
      int pIndex = 0;
      for (final element in doc.elements) {
        if (element is DocxParagraph) {
          if (editedParagraphs.containsKey(pIndex)) {
            final text = element.children
                .whereType<DocxText>()
                .map((t) => t.content)
                .join();
            if (text != editedParagraphs[pIndex]) return false;
          }
          pIndex++;
        }
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
