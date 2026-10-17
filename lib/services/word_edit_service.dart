import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:docx_creator/docx_creator.dart';
import 'package:excel2003/src/ole2/ole2_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import '../features/settings/services/settings_service.dart';
import '../models/word_document_model.dart';

class WordSaveResult {
  final String savedPath;
  final bool verified;
  final List<String> notes;
  WordSaveResult(this.savedPath, this.verified, this.notes);
}

class WordEditService {
  /// Save a copy with updated paragraph texts (legacy backward compatibility).
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

  /// Load a rich OpenXML Word document with full styles, geometry, tables, and images
  Future<WordDocumentModel> loadRichDocument(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      // Legacy .doc (Word 97-2003 OLE2, RTF, HTML, or plain text)
      return _loadLegacyDoc(bytes, sourcePath);
    }

    // 1. Parse Relationships (for images)
    final relMap = <String, String>{};
    final relFile = archive.findFile('word/_rels/document.xml.rels');
    if (relFile != null) {
      try {
        final relDoc = XmlDocument.parse(utf8.decode(relFile.content as List<int>, allowMalformed: true));
        for (final rel in relDoc.findAllElements('Relationship')) {
          final id = rel.getAttribute('Id');
          final target = rel.getAttribute('Target');
          if (id != null && target != null) {
            relMap[id] = target;
          }
        }
      } catch (_) {}
    }

    // 2. Parse document.xml
    final docFile = archive.findFile('word/document.xml');
    if (docFile == null) {
      return _loadLegacyDoc(bytes, sourcePath);
    }

    final xmlStr = utf8.decode(docFile.content as List<int>, allowMalformed: true);
    final xmlDoc = XmlDocument.parse(xmlStr);

    WordPageSetup pageSetup = const WordPageSetup();
    final blocks = <WordBlock>[];
    int blockSeq = 0;

    final body = xmlDoc.findAllElements('w:body').firstOrNull;
    if (body == null) {
      return WordDocumentModel();
    }

    // Parse page geometry
    final sectPr = body.findElements('w:sectPr').lastOrNull;
    if (sectPr != null) {
      final pgSz = sectPr.findElements('w:pgSz').firstOrNull;
      final pgMar = sectPr.findElements('w:pgMar').firstOrNull;

      double wPt = 595.3;
      double hPt = 841.9;
      if (pgSz != null) {
        final wTwips = double.tryParse(pgSz.getAttribute('w:w') ?? '');
        final hTwips = double.tryParse(pgSz.getAttribute('w:h') ?? '');
        if (wTwips != null) wPt = wTwips / 20.0;
        if (hTwips != null) hPt = hTwips / 20.0;
      }

      double topPt = 72.0;
      double bottomPt = 72.0;
      double leftPt = 72.0;
      double rightPt = 72.0;
      if (pgMar != null) {
        final t = double.tryParse(pgMar.getAttribute('w:top') ?? '');
        final b = double.tryParse(pgMar.getAttribute('w:bottom') ?? '');
        final l = double.tryParse(pgMar.getAttribute('w:left') ?? '');
        final r = double.tryParse(pgMar.getAttribute('w:right') ?? '');
        if (t != null) topPt = t / 20.0;
        if (b != null) bottomPt = b / 20.0;
        if (l != null) leftPt = l / 20.0;
        if (r != null) rightPt = r / 20.0;
      }

      pageSetup = WordPageSetup(
        pageWidthPt: wPt,
        pageHeightPt: hPt,
        marginTopPt: topPt,
        marginBottomPt: bottomPt,
        marginLeftPt: leftPt,
        marginRightPt: rightPt,
      );
    }

    for (final child in body.children.whereType<XmlElement>()) {
      if (child.name.local == 'p') {
        final pBlock = _parseParagraph(child, 'p_${blockSeq++}', archive, relMap);
        if (pBlock != null) blocks.add(pBlock);
      } else if (child.name.local == 'tbl') {
        final tblBlock = _parseTable(child, 'tbl_${blockSeq++}', archive, relMap);
        if (tblBlock != null) blocks.add(tblBlock);
      }
    }

    return WordDocumentModel(blocks: blocks, pageSetup: pageSetup);
  }

  WordBlock? _parseParagraph(
    XmlElement pElem,
    String id,
    Archive archive,
    Map<String, String> relMap,
  ) {
    // Check for page break
    final brPage = pElem.findAllElements('w:br').where((b) => b.getAttribute('w:type') == 'page');
    if (brPage.isNotEmpty && pElem.findAllElements('w:t').isEmpty) {
      return WordPageBreakBlock(id: id);
    }

    // Check drawing/image
    final blip = pElem.findAllElements('a:blip').firstOrNull;
    if (blip != null) {
      final embedId = blip.getAttribute('r:embed');
      if (embedId != null && relMap.containsKey(embedId)) {
        var target = relMap[embedId]!;
        if (target.startsWith('media/')) target = 'word/$target';
        else if (!target.startsWith('word/')) target = 'word/$target';

        final imgFile = archive.findFile(target);
        if (imgFile != null) {
          final bytes = Uint8List.fromList(imgFile.content as List<int>);
          return WordImageBlock(
            id: id,
            imageBytes: bytes,
            relId: embedId,
            width: 320,
            height: 240,
          );
        }
      }
    }

    int headingLevel = 0;
    String alignment = 'left';
    String listType = 'none';
    int listLevel = 0;
    double indentLeft = 0.0;
    double lineSpacing = 1.15;

    final pPr = pElem.findElements('w:pPr').firstOrNull;
    if (pPr != null) {
      final pStyle = pPr.findElements('w:pStyle').firstOrNull?.getAttribute('w:val')?.toLowerCase() ?? '';
      if (pStyle.contains('heading1') || pStyle.contains('heading 1')) headingLevel = 1;
      else if (pStyle.contains('heading2') || pStyle.contains('heading 2')) headingLevel = 2;
      else if (pStyle.contains('heading3') || pStyle.contains('heading 3')) headingLevel = 3;
      else if (pStyle.contains('heading4') || pStyle.contains('heading 4')) headingLevel = 4;
      else if (pStyle.contains('heading5') || pStyle.contains('heading 5')) headingLevel = 5;
      else if (pStyle.contains('heading6') || pStyle.contains('heading 6')) headingLevel = 6;
      else if (pStyle.contains('title')) headingLevel = 7;
      else if (pStyle.contains('subtitle')) headingLevel = 8;

      final jc = pPr.findElements('w:jc').firstOrNull?.getAttribute('w:val');
      if (jc != null) {
        if (jc == 'center') alignment = 'center';
        else if (jc == 'right') alignment = 'right';
        else if (jc == 'both') alignment = 'justify';
      }

      final numPr = pPr.findElements('w:numPr').firstOrNull;
      if (numPr != null) {
        listType = 'bullet';
        final ilvl = numPr.findElements('w:ilvl').firstOrNull?.getAttribute('w:val');
        if (ilvl != null) listLevel = int.tryParse(ilvl) ?? 0;
      }

      final ind = pPr.findElements('w:ind').firstOrNull?.getAttribute('w:left');
      if (ind != null) {
        final twips = double.tryParse(ind);
        if (twips != null) indentLeft = twips / 20.0;
      }

      final spacing = pPr.findElements('w:spacing').firstOrNull?.getAttribute('w:line');
      if (spacing != null) {
        final val = double.tryParse(spacing);
        if (val != null) lineSpacing = val / 240.0;
      }
    }

    final runs = <WordTextRun>[];
    for (final rElem in pElem.findElements('w:r')) {
      final tElem = rElem.findElements('w:t').firstOrNull;
      final text = tElem?.innerText ?? '';
      if (text.isEmpty) continue;

      bool bold = false;
      bool italic = false;
      bool underline = false;
      bool strikethrough = false;
      String fontFamily = 'Calibri';
      double fontSizePt = 11.0;
      String? textColorHex;
      String? highlightColorHex;

      final rPr = rElem.findElements('w:rPr').firstOrNull;
      if (rPr != null) {
        bold = rPr.findElements('w:b').isNotEmpty;
        italic = rPr.findElements('w:i').isNotEmpty;
        underline = rPr.findElements('w:u').isNotEmpty;
        strikethrough = rPr.findElements('w:strike').isNotEmpty;

        final font = rPr.findElements('w:rFonts').firstOrNull?.getAttribute('w:ascii');
        if (font != null && font.isNotEmpty) fontFamily = font;

        final sz = rPr.findElements('w:sz').firstOrNull?.getAttribute('w:val');
        if (sz != null) {
          final halfPts = double.tryParse(sz);
          if (halfPts != null) fontSizePt = halfPts / 2.0;
        }

        final color = rPr.findElements('w:color').firstOrNull?.getAttribute('w:val');
        if (color != null && color != 'auto') textColorHex = '#$color';

        final highlight = rPr.findElements('w:highlight').firstOrNull?.getAttribute('w:val');
        if (highlight != null) highlightColorHex = highlight;
      }

      runs.add(WordTextRun(
        text: text,
        bold: bold,
        italic: italic,
        underline: underline,
        strikethrough: strikethrough,
        fontFamily: fontFamily,
        fontSizePt: fontSizePt,
        textColorHex: textColorHex,
        highlightColorHex: highlightColorHex,
      ));
    }

    return WordParagraphBlock(
      id: id,
      runs: runs,
      headingLevel: headingLevel,
      alignment: alignment,
      listType: listType,
      listLevel: listLevel,
      indentLeft: indentLeft,
      lineSpacing: lineSpacing,
    );
  }

  WordTableBlock? _parseTable(
    XmlElement tblElem,
    String id,
    Archive archive,
    Map<String, String> relMap,
  ) {
    final rows = <WordTableRow>[];
    int rIdx = 0;
    for (final trElem in tblElem.findElements('w:tr')) {
      final cells = <WordTableCell>[];
      int cIdx = 0;
      for (final tcElem in trElem.findElements('w:tc')) {
        final cellPars = <WordParagraphBlock>[];
        for (final pChild in tcElem.findElements('w:p')) {
          final pBlock = _parseParagraph(pChild, 'tc_${rIdx}_${cIdx++}', archive, relMap);
          if (pBlock is WordParagraphBlock) cellPars.add(pBlock);
        }

        String? bgColor;
        final shd = tcElem.findAllElements('w:shd').firstOrNull?.getAttribute('w:fill');
        if (shd != null && shd != 'auto') bgColor = '#$shd';

        int colSpan = 1;
        final gridSpan = tcElem.findAllElements('w:gridSpan').firstOrNull?.getAttribute('w:val');
        if (gridSpan != null) colSpan = int.tryParse(gridSpan) ?? 1;

        cells.add(WordTableCell(
          paragraphs: cellPars,
          backgroundColorHex: bgColor,
          colSpan: colSpan,
        ));
      }
      rows.add(WordTableRow(cells: cells));
      rIdx++;
    }

    return WordTableBlock(id: id, rows: rows);
  }

  /// Save a rich OpenXML Word document non-destructively, preserving media and untouched XML files
  Future<WordSaveResult> saveRichDocument({
    required String sourcePath,
    required WordDocumentModel document,
    bool overwriteOriginal = false,
  }) async {
    final bytes = await File(sourcePath).readAsBytes();
    Archive? sourceArchive;
    try {
      sourceArchive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {}

    // Build replacement word/document.xml
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="UTF-8" standalone="yes"');
    xmlBuilder.element('w:document', namespaces: {
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main': 'w',
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships': 'r',
      'http://schemas.openxmlformats.org/drawingml/2006/main': 'a',
      'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing': 'wp',
    }, nest: () {
      xmlBuilder.element('w:body', nest: () {
        for (final block in document.blocks) {
          if (block is WordParagraphBlock) {
            _serializeParagraph(xmlBuilder, block);
          } else if (block is WordTableBlock) {
            _serializeTable(xmlBuilder, block);
          } else if (block is WordPageBreakBlock) {
            xmlBuilder.element('w:p', nest: () {
              xmlBuilder.element('w:r', nest: () {
                xmlBuilder.element('w:br', attributes: {'w:type': 'page'});
              });
            });
          }
        }

        // Section properties with page dimensions and margins
        xmlBuilder.element('w:sectPr', nest: () {
          xmlBuilder.element('w:pgSz', attributes: {
            'w:w': (document.pageSetup.pageWidthPt * 20).round().toString(),
            'w:h': (document.pageSetup.pageHeightPt * 20).round().toString(),
          });
          xmlBuilder.element('w:pgMar', attributes: {
            'w:top': (document.pageSetup.marginTopPt * 20).round().toString(),
            'w:bottom': (document.pageSetup.marginBottomPt * 20).round().toString(),
            'w:left': (document.pageSetup.marginLeftPt * 20).round().toString(),
            'w:right': (document.pageSetup.marginRightPt * 20).round().toString(),
          });
        });
      });
    });

    final newDocXml = xmlBuilder.buildDocument().toXmlString(pretty: true);
    final newDocBytes = Uint8List.fromList(utf8.encode(newDocXml));

    // Create new ZIP archive preserving all other untouched files
    final newArchive = Archive();
    if (sourceArchive != null) {
      for (final file in sourceArchive.files) {
        if (file.name == 'word/document.xml') {
          newArchive.addFile(ArchiveFile('word/document.xml', newDocBytes.length, newDocBytes));
        } else {
          newArchive.addFile(file);
        }
      }
    } else {
      const contentTypesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n  <Default Extension="xml" ContentType="application/xml"/>\n  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\n</Types>';
      const relsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\n</Relationships>';
      const docRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>';
      
      final ctBytes = Uint8List.fromList(utf8.encode(contentTypesXml));
      final relsBytes = Uint8List.fromList(utf8.encode(relsXml));
      final docRelsBytes = Uint8List.fromList(utf8.encode(docRelsXml));

      newArchive.addFile(ArchiveFile('[Content_Types].xml', ctBytes.length, ctBytes));
      newArchive.addFile(ArchiveFile('_rels/.rels', relsBytes.length, relsBytes));
      newArchive.addFile(ArchiveFile('word/_rels/document.xml.rels', docRelsBytes.length, docRelsBytes));
      newArchive.addFile(ArchiveFile('word/document.xml', newDocBytes.length, newDocBytes));
    }

    final encodedZip = ZipEncoder().encode(newArchive);

    String targetPath;
    if (overwriteOriginal) {
      targetPath = sourcePath;
    } else {
      final dir = await _resolveWritableExportDir();
      final base = p.basenameWithoutExtension(sourcePath);
      targetPath = _uniquePath(p.join(dir, '$base (edited).docx'));
    }

    await File(targetPath).writeAsBytes(encodedZip, flush: true);
    return WordSaveResult(targetPath, true, const []);
  }

  void _serializeParagraph(XmlBuilder builder, WordParagraphBlock block) {
    builder.element('w:p', nest: () {
      builder.element('w:pPr', nest: () {
        if (block.headingLevel > 0 && block.headingLevel <= 6) {
          builder.element('w:pStyle', attributes: {'w:val': 'Heading${block.headingLevel}'});
        } else if (block.headingLevel == 7) {
          builder.element('w:pStyle', attributes: {'w:val': 'Title'});
        } else if (block.headingLevel == 8) {
          builder.element('w:pStyle', attributes: {'w:val': 'Subtitle'});
        }

        if (block.alignment == 'center') {
          builder.element('w:jc', attributes: {'w:val': 'center'});
        } else if (block.alignment == 'right') {
          builder.element('w:jc', attributes: {'w:val': 'right'});
        } else if (block.alignment == 'justify') {
          builder.element('w:jc', attributes: {'w:val': 'both'});
        }

        if (block.indentLeft > 0) {
          builder.element('w:ind', attributes: {'w:left': (block.indentLeft * 20).round().toString()});
        }
      });

      for (final run in block.runs) {
        builder.element('w:r', nest: () {
          builder.element('w:rPr', nest: () {
            if (run.bold) builder.element('w:b');
            if (run.italic) builder.element('w:i');
            if (run.underline) builder.element('w:u', attributes: {'w:val': 'single'});
            if (run.strikethrough) builder.element('w:strike');
            builder.element('w:rFonts', attributes: {'w:ascii': run.fontFamily, 'w:hAnsi': run.fontFamily});
            builder.element('w:sz', attributes: {'w:val': (run.fontSizePt * 2).round().toString()});
            if (run.textColorHex != null) {
              final hex = run.textColorHex!.replaceAll('#', '');
              builder.element('w:color', attributes: {'w:val': hex});
            }
          });
          builder.element('w:t', attributes: {'xml:space': 'preserve'}, nest: run.text);
        });
      }
    });
  }

  void _serializeTable(XmlBuilder builder, WordTableBlock block) {
    builder.element('w:tbl', nest: () {
      for (final row in block.rows) {
        builder.element('w:tr', nest: () {
          for (final cell in row.cells) {
            builder.element('w:tc', nest: () {
              if (cell.colSpan > 1) {
                builder.element('w:tcPr', nest: () {
                  builder.element('w:gridSpan', attributes: {'w:val': cell.colSpan.toString()});
                });
              }
              for (final p in cell.paragraphs) {
                _serializeParagraph(builder, p);
              }
              if (cell.paragraphs.isEmpty) {
                builder.element('w:p');
              }
            });
          }
        });
      }
    });
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

  WordDocumentModel _loadLegacyDoc(List<int> bytes, String sourcePath) {
    final blocks = <WordBlock>[];
    final text = _extractTextFromLegacyDoc(bytes);
    final lines = text.split(RegExp(r'\r\n|\r|\n'));
    int seq = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      blocks.add(WordParagraphBlock(
        id: 'p_${seq++}',
        runs: [WordTextRun(text: trimmed)],
      ));
    }

    if (blocks.isEmpty) {
      blocks.add(WordParagraphBlock(
        id: 'p_0',
        runs: [WordTextRun(text: 'Empty document')],
      ));
    }

    return WordDocumentModel(blocks: blocks);
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

  String _extractTextFromLegacyDoc(List<int> bytes) {
    if (bytes.isEmpty) return '';

    // 1. Check for RTF
    if (bytes.length >= 5 && bytes[0] == 0x7B && bytes[1] == 0x5C && bytes[2] == 0x72 && bytes[3] == 0x74 && bytes[4] == 0x66) {
      return _extractTextFromRtf(utf8.decode(bytes, allowMalformed: true));
    }

    // 2. Check for HTML / XML
    final sample = utf8.decode(bytes.sublist(0, bytes.length > 512 ? 512 : bytes.length), allowMalformed: true).toLowerCase();
    if (sample.contains('<html') || sample.contains('<!doctype') || sample.contains('<table') || sample.contains('<?xml')) {
      return _extractTextFromHtml(utf8.decode(bytes, allowMalformed: true));
    }

    // 3. Genuine OLE2 Compound Document (.doc Word 97-2003)
    if (_isOle2(bytes)) {
      final docText = _extractFromOle2Doc(bytes);
      if (docText.trim().isNotEmpty) {
        return docText;
      }
    }

    // 4. Try extracting UTF-16LE text sequences
    final utf16Lines = _extractUtf16Text(bytes);
    if (utf16Lines.length > 1 || (utf16Lines.isNotEmpty && utf16Lines.join(' ').length > 20)) {
      return utf16Lines.join('\n');
    }

    // 5. Try extracting 8-bit ASCII / CP1252 readable text
    final asciiLines = _extractAsciiText(bytes);
    if (asciiLines.isNotEmpty) {
      return asciiLines.join('\n');
    }

    // 6. Non-binary plain text fallback
    if (!_isBinary(bytes)) {
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } catch (_) {}
    }

    return '';
  }

  String _extractFromOle2Doc(List<int> bytes) {
    try {
      final ole2 = Ole2Reader();
      ole2.openBytes(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

      final wordDocEntry = ole2.findEntry('WordDocument');
      if (wordDocEntry == null) return '';

      final wordDoc = ole2.readEntry(wordDocEntry);
      if (wordDoc.length < 0x01AA) {
        return _extractAsciiText(wordDoc).join('\n');
      }

      // Read table stream flag
      final flags = wordDoc[0x0A] | (wordDoc[0x0B] << 8);
      final is1Table = (flags & 0x0200) != 0;
      final tableName = is1Table ? '1Table' : '0Table';

      // Read fcClx and lcbClx
      final fcClx = wordDoc[0x01A2] | (wordDoc[0x01A3] << 8) | (wordDoc[0x01A4] << 16) | (wordDoc[0x01A5] << 24);
      final lcbClx = wordDoc[0x01A6] | (wordDoc[0x01A7] << 8) | (wordDoc[0x01A8] << 16) | (wordDoc[0x01A9] << 24);

      final tableEntry = ole2.findEntry(tableName);
      if (tableEntry != null && fcClx > 0 && lcbClx > 0) {
        final tableStream = ole2.readEntry(tableEntry);
        if (fcClx + lcbClx <= tableStream.length) {
          final clxData = Uint8List.sublistView(tableStream, fcClx, fcClx + lcbClx);
          int pos = 0;
          while (pos < clxData.length) {
            final clxt = clxData[pos++];
            if (clxt == 0x01) {
              if (pos + 2 > clxData.length) break;
              final cb = clxData[pos] | (clxData[pos + 1] << 8);
              pos += 2 + cb;
            } else if (clxt == 0x02) {
              if (pos + 4 > clxData.length) break;
              final lcb = clxData[pos] | (clxData[pos + 1] << 8) | (clxData[pos + 2] << 16) | (clxData[pos + 3] << 24);
              pos += 4;
              if (pos + lcb > clxData.length) break;

              final n = (lcb - 4) ~/ 12;
              if (n > 0) {
                final cpList = <int>[];
                for (int i = 0; i <= n; i++) {
                  final cpOffset = pos + i * 4;
                  cpList.add(clxData[cpOffset] | (clxData[cpOffset + 1] << 8) | (clxData[cpOffset + 2] << 16) | (clxData[cpOffset + 3] << 24));
                }

                final pcdStart = pos + (n + 1) * 4;
                final textBuf = StringBuffer();
                for (int i = 0; i < n; i++) {
                  final pcdOffset = pcdStart + i * 8;
                  final fc = clxData[pcdOffset + 2] | (clxData[pcdOffset + 3] << 8) | (clxData[pcdOffset + 4] << 16) | (clxData[pcdOffset + 5] << 24);
                  final isCompressed = (fc & 0x40000000) != 0;
                  final realOffset = isCompressed ? ((fc & ~0x40000000) ~/ 2) : (fc & ~0x40000000);
                  final charCount = cpList[i + 1] - cpList[i];
                  if (charCount <= 0) continue;

                  if (isCompressed) {
                    if (realOffset + charCount <= wordDoc.length) {
                      for (int k = 0; k < charCount; k++) {
                        textBuf.writeCharCode(wordDoc[realOffset + k]);
                      }
                    }
                  } else {
                    if (realOffset + charCount * 2 <= wordDoc.length) {
                      for (int k = 0; k < charCount; k++) {
                        final ch = wordDoc[realOffset + k * 2] | (wordDoc[realOffset + k * 2 + 1] << 8);
                        textBuf.writeCharCode(ch);
                      }
                    }
                  }
                }

                final text = _cleanWordText(textBuf.toString());
                if (text.trim().isNotEmpty) {
                  return text;
                }
              }
              break;
            } else {
              break;
            }
          }
        }
      }

      // Fallback: contiguous text starting at fcMin
      final fcMin = wordDoc[0x18] | (wordDoc[0x19] << 8) | (wordDoc[0x1A] << 16) | (wordDoc[0x1B] << 24);
      final ccpText = (wordDoc.length >= 0x50) ? (wordDoc[0x4C] | (wordDoc[0x4D] << 8) | (wordDoc[0x4E] << 16) | (wordDoc[0x4F] << 24)) : 0;
      if (fcMin > 0 && fcMin < wordDoc.length) {
        final textSlice = Uint8List.sublistView(wordDoc, fcMin, (ccpText > 0 && fcMin + ccpText * 2 <= wordDoc.length) ? fcMin + ccpText * 2 : wordDoc.length);
        final utf16 = _extractUtf16Text(textSlice);
        if (utf16.isNotEmpty) return utf16.join('\n');
        final ascii = _extractAsciiText(textSlice);
        if (ascii.isNotEmpty) return ascii.join('\n');
      }

      final streamUtf16 = _extractUtf16Text(wordDoc);
      if (streamUtf16.isNotEmpty) return streamUtf16.join('\n');
      final streamAscii = _extractAsciiText(wordDoc);
      if (streamAscii.isNotEmpty) return streamAscii.join('\n');
    } catch (e, st) {
      debugPrint('[WordEditService] Ole2 doc extraction error: $e\n$st');
    }
    return '';
  }

  String _cleanWordText(String text) {
    final sb = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code == 0x0D || code == 0x0A) {
        sb.write('\n');
      } else if (code == 0x09 || code == 0x07) {
        sb.write(' ');
      } else if (code == 0x0B) {
        sb.write('\n');
      } else if (code == 0x0C) {
        sb.write('\n\n');
      } else if (code >= 0x20 && code != 0x7F && code != 0xFFFD) {
        sb.writeCharCode(code);
      }
    }
    return sb.toString();
  }

  List<String> _extractUtf16Text(List<int> bytes) {
    final result = <String>[];
    final buffer = StringBuffer();
    for (int i = 0; i < bytes.length - 1; i += 2) {
      final b0 = bytes[i];
      final b1 = bytes[i + 1];
      if (b1 == 0 && (b0 >= 0x20 && b0 <= 0x7E || b0 == 0x0A || b0 == 0x09)) {
        buffer.writeCharCode(b0);
      } else if (b1 == 0 && b0 == 0x0D) {
        if (buffer.length > 1) {
          result.add(buffer.toString());
          buffer.clear();
        }
      } else {
        if (buffer.length > 3) {
          result.add(buffer.toString());
        }
        buffer.clear();
      }
    }
    if (buffer.length > 3) result.add(buffer.toString());

    return result
        .map((s) => s.trim())
        .where((s) => s.length > 2 && !_isBinaryNoise(s))
        .toList();
  }

  List<String> _extractAsciiText(List<int> bytes) {
    final result = <String>[];
    final buffer = StringBuffer();
    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if ((b >= 0x20 && b <= 0x7E) || b == 0x09) {
        buffer.writeCharCode(b);
      } else if (b == 0x0A || b == 0x0D) {
        if (buffer.length > 2) {
          result.add(buffer.toString());
          buffer.clear();
        }
      } else {
        if (buffer.length > 3) {
          result.add(buffer.toString());
        }
        buffer.clear();
      }
    }
    if (buffer.length > 3) result.add(buffer.toString());
    return result
        .map((s) => s.trim())
        .where((s) => s.length > 2 && !_isBinaryNoise(s))
        .toList();
  }

  bool _isBinaryNoise(String s) {
    const noiseNames = [
      'worddocument', 'summaryinformation', 'documentsummaryinformation',
      'root entry', 'compobj', 'table', 'data', 'objectpool', 'current user',
      '1table', '0table', 'props', 'props9', 'msworddoc'
    ];
    return noiseNames.contains(s.toLowerCase());
  }

  String _extractTextFromRtf(String rtf) {
    var clean = rtf.replaceAll(RegExp(r'\\(par|line)\b'), '\n');
    clean = clean.replaceAll(RegExp(r'\{\\\*(?:[^{}]*|\{[^{}]*\})*\}'), '');
    clean = clean.replaceAll(RegExp(r'\{\\(?:fonttbl|colortbl|stylesheet|info)[^{}]*\}'), '');
    clean = clean.replaceAll(RegExp(r"\\'[0-9a-fA-F]{2}"), ' ');
    clean = clean.replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), '');
    clean = clean.replaceAll('{', '').replaceAll('}', '');
    return clean;
  }

  String _extractTextFromHtml(String html) {
    return html
        .replaceAll(RegExp(r'<(p|h[1-6]|tr|div|li)[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
  }
}
