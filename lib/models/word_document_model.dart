import 'dart:typed_data';

/// Represents page geometry parsed from `<w:pgSz>` and `<w:pgMar>`
class WordPageSetup {
  final double pageWidthPt;
  final double pageHeightPt;
  final double marginTopPt;
  final double marginBottomPt;
  final double marginLeftPt;
  final double marginRightPt;
  final double headerPt;
  final double footerPt;

  const WordPageSetup({
    this.pageWidthPt = 595.3, // A4 default: 595.3 x 841.9 pt (8.27 x 11.69 in)
    this.pageHeightPt = 841.9,
    this.marginTopPt = 72.0, // 1 inch default margins
    this.marginBottomPt = 72.0,
    this.marginLeftPt = 72.0,
    this.marginRightPt = 72.0,
    this.headerPt = 36.0,
    this.footerPt = 36.0,
  });

  /// Usable content width in points
  double get contentWidthPt => pageWidthPt - marginLeftPt - marginRightPt;

  /// Usable content height in points
  double get contentHeightPt => pageHeightPt - marginTopPt - marginBottomPt;

  WordPageSetup copyWith({
    double? pageWidthPt,
    double? pageHeightPt,
    double? marginTopPt,
    double? marginBottomPt,
    double? marginLeftPt,
    double? marginRightPt,
    double? headerPt,
    double? footerPt,
  }) {
    return WordPageSetup(
      pageWidthPt: pageWidthPt ?? this.pageWidthPt,
      pageHeightPt: pageHeightPt ?? this.pageHeightPt,
      marginTopPt: marginTopPt ?? this.marginTopPt,
      marginBottomPt: marginBottomPt ?? this.marginBottomPt,
      marginLeftPt: marginLeftPt ?? this.marginLeftPt,
      marginRightPt: marginRightPt ?? this.marginRightPt,
      headerPt: headerPt ?? this.headerPt,
      footerPt: footerPt ?? this.footerPt,
    );
  }
}

/// Represents an inline run of formatted text `<w:r>`
class WordTextRun {
  String text;
  bool bold;
  bool italic;
  bool underline;
  bool strikethrough;
  String fontFamily;
  double fontSizePt;
  String? textColorHex;
  String? highlightColorHex;
  String? linkUrl;

  WordTextRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.fontFamily = 'Calibri',
    this.fontSizePt = 11.0,
    this.textColorHex,
    this.highlightColorHex,
    this.linkUrl,
  });

  WordTextRun copyWith({
    String? text,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    String? fontFamily,
    double? fontSizePt,
    String? textColorHex,
    String? highlightColorHex,
    String? linkUrl,
  }) {
    return WordTextRun(
      text: text ?? this.text,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strikethrough: strikethrough ?? this.strikethrough,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSizePt: fontSizePt ?? this.fontSizePt,
      textColorHex: textColorHex ?? this.textColorHex,
      highlightColorHex: highlightColorHex ?? this.highlightColorHex,
      linkUrl: linkUrl ?? this.linkUrl,
    );
  }
}

/// Abstract base class for all top-level document blocks
abstract class WordBlock {
  final String id;
  const WordBlock({required this.id});

  String get plainText => '';
}

/// Represents a paragraph `<w:p>`
class WordParagraphBlock extends WordBlock {
  final List<WordTextRun> runs;
  int headingLevel; // 0 = Normal, 1..6 = Heading 1..6, 7 = Title, 8 = Subtitle
  String alignment; // 'left', 'center', 'right', 'justify'
  String listType; // 'none', 'bullet', 'numbered'
  int listLevel;
  double indentLeft;
  double lineSpacing; // 1.0, 1.15, 1.5, 2.0

  WordParagraphBlock({
    required super.id,
    List<WordTextRun>? runs,
    this.headingLevel = 0,
    this.alignment = 'left',
    this.listType = 'none',
    this.listLevel = 0,
    this.indentLeft = 0.0,
    this.lineSpacing = 1.15,
  }) : runs = runs ?? [];

  String get plainText => runs.map((r) => r.text).join();

  WordParagraphBlock copyWith({
    String? id,
    List<WordTextRun>? runs,
    int? headingLevel,
    String? alignment,
    String? listType,
    int? listLevel,
    double? indentLeft,
    double? lineSpacing,
  }) {
    return WordParagraphBlock(
      id: id ?? this.id,
      runs: runs ?? this.runs.map((r) => r.copyWith()).toList(),
      headingLevel: headingLevel ?? this.headingLevel,
      alignment: alignment ?? this.alignment,
      listType: listType ?? this.listType,
      listLevel: listLevel ?? this.listLevel,
      indentLeft: indentLeft ?? this.indentLeft,
      lineSpacing: lineSpacing ?? this.lineSpacing,
    );
  }
}

/// Represents a cell inside a table row `<w:tc>`
class WordTableCell {
  final List<WordParagraphBlock> paragraphs;
  String? backgroundColorHex;
  int colSpan;
  int rowSpan;
  double? width;

  WordTableCell({
    List<WordParagraphBlock>? paragraphs,
    this.backgroundColorHex,
    this.colSpan = 1,
    this.rowSpan = 1,
    this.width,
  }) : paragraphs = paragraphs ?? [];

  String get plainText => paragraphs.map((p) => p.plainText).join('\n');

  WordTableCell copyWith({
    List<WordParagraphBlock>? paragraphs,
    String? backgroundColorHex,
    int? colSpan,
    int? rowSpan,
    double? width,
  }) {
    return WordTableCell(
      paragraphs: paragraphs ?? this.paragraphs.map((p) => p.copyWith()).toList(),
      backgroundColorHex: backgroundColorHex ?? this.backgroundColorHex,
      colSpan: colSpan ?? this.colSpan,
      rowSpan: rowSpan ?? this.rowSpan,
      width: width ?? this.width,
    );
  }
}

/// Represents a row inside a table `<w:tr>`
class WordTableRow {
  final List<WordTableCell> cells;

  WordTableRow({List<WordTableCell>? cells}) : cells = cells ?? [];

  WordTableRow copyWith({List<WordTableCell>? cells}) {
    return WordTableRow(
      cells: cells ?? this.cells.map((c) => c.copyWith()).toList(),
    );
  }
}

/// Represents a table block `<w:tbl>`
class WordTableBlock extends WordBlock {
  final List<WordTableRow> rows;
  List<double>? columnWidths;
  String? borderColorHex;
  double borderWidth;

  WordTableBlock({
    required super.id,
    List<WordTableRow>? rows,
    this.columnWidths,
    this.borderColorHex = '#D3D3D3',
    this.borderWidth = 1.0,
  }) : rows = rows ?? [];

  WordTableBlock copyWith({
    String? id,
    List<WordTableRow>? rows,
    List<double>? columnWidths,
    String? borderColorHex,
    double? borderWidth,
  }) {
    return WordTableBlock(
      id: id ?? this.id,
      rows: rows ?? this.rows.map((r) => r.copyWith()).toList(),
      columnWidths: columnWidths ?? this.columnWidths,
      borderColorHex: borderColorHex ?? this.borderColorHex,
      borderWidth: borderWidth ?? this.borderWidth,
    );
  }
}

/// Represents an embedded image `<w:drawing>`
class WordImageBlock extends WordBlock {
  final Uint8List imageBytes;
  final double? width;
  final double? height;
  final String? relId;
  final String? altText;

  WordImageBlock({
    required super.id,
    required this.imageBytes,
    this.width,
    this.height,
    this.relId,
    this.altText,
  });
}

/// Represents a page break `<w:br w:type="page"/>`
class WordPageBreakBlock extends WordBlock {
  const WordPageBreakBlock({required super.id});
}

/// Represents an entry in the document outline / table of contents
class WordHeadingEntry {
  final String blockId;
  final String title;
  final int level;

  const WordHeadingEntry({
    required this.blockId,
    required this.title,
    required this.level,
  });
}

/// Top-level model for a Microsoft Word document (.docx)
class WordDocumentModel {
  final List<WordBlock> blocks;
  WordPageSetup pageSetup;

  WordDocumentModel({
    List<WordBlock>? blocks,
    WordPageSetup? pageSetup,
  })  : blocks = blocks ?? [],
        pageSetup = pageSetup ?? const WordPageSetup();

  /// Headings for document outline navigation
  List<WordHeadingEntry> get headings {
    final list = <WordHeadingEntry>[];
    for (final b in blocks) {
      if (b is WordParagraphBlock && b.headingLevel > 0) {
        final text = b.plainText.trim();
        if (text.isNotEmpty) {
          list.add(WordHeadingEntry(
            blockId: b.id,
            title: text,
            level: b.headingLevel,
          ));
        }
      }
    }
    return list;
  }

  /// Full plain text across all blocks
  String get plainText {
    final buf = StringBuffer();
    for (final b in blocks) {
      if (b is WordParagraphBlock) {
        buf.writeln(b.plainText);
      } else if (b is WordTableBlock) {
        for (final row in b.rows) {
          buf.writeln(row.cells.map((c) => c.plainText).join('\t'));
        }
      }
    }
    return buf.toString();
  }

  /// Total word count
  int get wordCount {
    final text = plainText.trim();
    if (text.isEmpty) return 0;
    return RegExp(r'\S+').allMatches(text).length;
  }

  /// Total character count
  int get characterCount {
    return plainText.replaceAll(RegExp(r'\r?\n'), '').length;
  }
}
