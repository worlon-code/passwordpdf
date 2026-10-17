import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../models/word_document_model.dart';
import 'word_ribbon_toolbar.dart';

/// Custom TextEditingController that renders rich formatted text runs, hyperlinks, and search highlights
class RichParagraphEditingController extends TextEditingController {
  final WordParagraphBlock block;
  String? searchQuery;
  final void Function(String url)? onLinkTap;
  final List<TapGestureRecognizer> _recognizers = [];
  bool isEditing = false;

  static final RegExp _linkRegex = RegExp(
    r'(https?:\/\/[^\s<>"' + "'" + r']+|www\.[^\s<>"' + "'" + r']+|[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)',
    caseSensitive: false,
  );

  RichParagraphEditingController({
    required this.block,
    this.searchQuery,
    this.onLinkTap,
  }) : super(text: block.plainText);

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  static String normalizeUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('.') || url.endsWith(',') || url.endsWith(';') || url.endsWith(')') || url.endsWith('>')) {
      url = url.substring(0, url.length - 1).trim();
    }
    if (url.contains('@') && !url.startsWith('mailto:') && !url.startsWith('http://') && !url.startsWith('https://')) {
      return 'mailto:$url';
    }
    if (url.startsWith('www.')) {
      return 'https://$url';
    }
    if (!url.startsWith('http://') && !url.startsWith('https://') && !url.startsWith('mailto:') && !url.startsWith('tel:')) {
      return 'https://$url';
    }
    return url;
  }

  Widget _buildLinkWidget({
    required String text,
    required String targetUrl,
    required TextStyle linkStyle,
    String? searchQuery,
  }) {
    final cleanTarget = normalizeUrl(targetUrl);
    InlineSpan contentSpan;
    if (searchQuery != null && searchQuery.isNotEmpty && text.toLowerCase().contains(searchQuery.toLowerCase())) {
      final spans = <InlineSpan>[];
      final query = searchQuery.toLowerCase();
      final lower = text.toLowerCase();
      int start = 0;
      int matchIdx;
      while ((matchIdx = lower.indexOf(query, start)) != -1) {
        if (matchIdx > start) {
          spans.add(TextSpan(text: text.substring(start, matchIdx), style: linkStyle));
        }
        spans.add(TextSpan(
          text: text.substring(matchIdx, matchIdx + query.length),
          style: linkStyle.copyWith(backgroundColor: Colors.yellowAccent, color: Colors.black),
        ));
        start = matchIdx + query.length;
      }
      if (start < text.length) {
        spans.add(TextSpan(text: text.substring(start), style: linkStyle));
      }
      contentSpan = TextSpan(children: spans);
    } else {
      contentSpan = TextSpan(text: text, style: linkStyle);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onLinkTap?.call(cleanTarget),
        child: Text.rich(contentSpan),
      ),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    if (block.runs.isEmpty) {
      return TextSpan(text: text, style: style);
    }

    final spans = <InlineSpan>[];
    for (final run in block.runs) {
      final runStyle = _buildRunStyle(run, style);

      if (run.linkUrl != null && run.linkUrl!.isNotEmpty) {
        final linkStyle = runStyle.copyWith(
          color: const Color(0xFF0563C1),
          decoration: TextDecoration.underline,
        );

        if (!isEditing) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _buildLinkWidget(
              text: run.text,
              targetUrl: run.linkUrl!,
              linkStyle: linkStyle,
              searchQuery: searchQuery,
            ),
          ));
        } else {
          _addHighlightedOrPlainSpan(
            spans: spans,
            text: run.text,
            baseStyle: linkStyle,
            searchQuery: searchQuery,
          );
        }
      } else {
        final matches = _linkRegex.allMatches(run.text).toList();
        if (matches.isEmpty) {
          _addHighlightedOrPlainSpan(
            spans: spans,
            text: run.text,
            baseStyle: runStyle,
            searchQuery: searchQuery,
          );
        } else {
          int lastIndex = 0;
          for (final m in matches) {
            if (m.start > lastIndex) {
              _addHighlightedOrPlainSpan(
                spans: spans,
                text: run.text.substring(lastIndex, m.start),
                baseStyle: runStyle,
                searchQuery: searchQuery,
              );
            }
            final matchText = m.group(0)!;
            final linkStyle = runStyle.copyWith(
              color: const Color(0xFF0563C1),
              decoration: TextDecoration.underline,
            );

            if (!isEditing) {
              spans.add(WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: _buildLinkWidget(
                  text: matchText,
                  targetUrl: matchText,
                  linkStyle: linkStyle,
                  searchQuery: searchQuery,
                ),
              ));
            } else {
              _addHighlightedOrPlainSpan(
                spans: spans,
                text: matchText,
                baseStyle: linkStyle,
                searchQuery: searchQuery,
              );
            }
            lastIndex = m.end;
          }
          if (lastIndex < run.text.length) {
            _addHighlightedOrPlainSpan(
              spans: spans,
              text: run.text.substring(lastIndex),
              baseStyle: runStyle,
              searchQuery: searchQuery,
            );
          }
        }
      }
    }

    return TextSpan(children: spans, style: style);
  }

  void _addHighlightedOrPlainSpan({
    required List<InlineSpan> spans,
    required String text,
    required TextStyle baseStyle,
    String? searchQuery,
    GestureRecognizer? recognizer,
  }) {
    if (searchQuery != null && searchQuery.isNotEmpty && text.toLowerCase().contains(searchQuery.toLowerCase())) {
      final query = searchQuery.toLowerCase();
      final lower = text.toLowerCase();
      int start = 0;
      int matchIdx;
      while ((matchIdx = lower.indexOf(query, start)) != -1) {
        if (matchIdx > start) {
          spans.add(TextSpan(
            text: text.substring(start, matchIdx),
            style: baseStyle,
            recognizer: recognizer,
          ));
        }
        spans.add(TextSpan(
          text: text.substring(matchIdx, matchIdx + query.length),
          style: baseStyle.copyWith(
            backgroundColor: Colors.yellowAccent,
            color: Colors.black,
          ),
          recognizer: recognizer,
        ));
        start = matchIdx + query.length;
      }
      if (start < text.length) {
        spans.add(TextSpan(
          text: text.substring(start),
          style: baseStyle,
          recognizer: recognizer,
        ));
      }
    } else {
      spans.add(TextSpan(text: text, style: baseStyle, recognizer: recognizer));
    }
  }

  TextStyle _buildRunStyle(WordTextRun run, TextStyle? baseStyle) {
    Color? color;
    if (run.textColorHex != null) {
      try {
        final hex = run.textColorHex!.replaceAll('#', '');
        color = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    Color? highlight;
    if (run.highlightColorHex != null) {
      if (run.highlightColorHex == 'yellow') highlight = Colors.yellow;
      else if (run.highlightColorHex == 'green') highlight = Colors.greenAccent;
      else if (run.highlightColorHex == 'cyan') highlight = Colors.cyanAccent;
      else if (run.highlightColorHex == 'magenta') highlight = Colors.pinkAccent;
    }

    TextStyle style = TextStyle(
      fontSize: run.fontSizePt,
      fontWeight: run.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
      decoration: TextDecoration.combine([
        if (run.underline) TextDecoration.underline,
        if (run.strikethrough) TextDecoration.lineThrough,
      ]),
      color: color ?? baseStyle?.color,
      backgroundColor: highlight,
    );

    return style.copyWith(fontFamily: run.fontFamily);
  }

  /// Synchronize edits back to the block's text runs
  void syncRunsFromText() {
    if (block.runs.isEmpty) {
      block.runs.add(WordTextRun(text: text));
    } else if (block.runs.length == 1) {
      block.runs[0].text = text;
    } else {
      // Re-align single modified paragraph text across runs
      final totalRunLen = block.runs.fold<int>(0, (acc, r) => acc + r.text.length);
      if (text.length == totalRunLen) return;
      block.runs.clear();
      block.runs.add(WordTextRun(text: text));
    }
  }

  /// Apply formatting across selected range
  void applyFormatting({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    String? fontFamily,
    double? fontSizePt,
    Color? textColor,
    Color? highlightColor,
  }) {
    final sel = selection;
    if (!sel.isValid || sel.isCollapsed) {
      // Format entire paragraph if no selection
      for (final r in block.runs) {
        if (bold != null) r.bold = bold;
        if (italic != null) r.italic = italic;
        if (underline != null) r.underline = underline;
        if (strikethrough != null) r.strikethrough = strikethrough;
        if (fontFamily != null) r.fontFamily = fontFamily;
        if (fontSizePt != null) r.fontSizePt = fontSizePt;
        if (textColor != null) {
          r.textColorHex = '#${textColor.value.toRadixString(16).padLeft(8, '0').substring(2)}';
        }
        if (highlightColor != null) {
          r.highlightColorHex = 'yellow';
        }
      }
      notifyListeners();
      return;
    }

    final start = sel.start;
    final end = sel.end;

    final newRuns = <WordTextRun>[];
    int currentOffset = 0;

    for (final r in block.runs) {
      final rStart = currentOffset;
      final rEnd = currentOffset + r.text.length;
      currentOffset = rEnd;

      if (rEnd <= start || rStart >= end) {
        // Outside selection
        newRuns.add(r);
      } else {
        // Overlaps selection
        // 1. Pre-selection chunk
        if (rStart < start) {
          newRuns.add(r.copyWith(text: r.text.substring(0, start - rStart)));
        }

        // 2. Selected chunk
        final chunkStart = math.max(0, start - rStart);
        final chunkEnd = math.min(r.text.length, end - rStart);
        final chunkText = r.text.substring(chunkStart, chunkEnd);

        final updated = r.copyWith(
          text: chunkText,
          bold: bold ?? r.bold,
          italic: italic ?? r.italic,
          underline: underline ?? r.underline,
          strikethrough: strikethrough ?? r.strikethrough,
          fontFamily: fontFamily ?? r.fontFamily,
          fontSizePt: fontSizePt ?? r.fontSizePt,
          textColorHex: textColor != null
              ? '#${textColor.value.toRadixString(16).padLeft(8, '0').substring(2)}'
              : r.textColorHex,
          highlightColorHex: highlightColor != null ? 'yellow' : r.highlightColorHex,
        );
        newRuns.add(updated);

        // 3. Post-selection chunk
        if (rEnd > end) {
          newRuns.add(r.copyWith(text: r.text.substring(end - rStart)));
        }
      }
    }

    block.runs.clear();
    block.runs.addAll(newRuns);
    notifyListeners();
  }

  void refresh() {
    notifyListeners();
  }
}

/// Interactive paper canvas rendering Word pages, ruler, tables, and images
class WordPageCanvas extends StatefulWidget {
  final WordDocumentModel document;
  final bool isEditMode;
  final bool isReflowMode;
  final double zoomScale;
  final String? searchQuery;
  final VoidCallback? onContentChanged;
  final Function(WordFormattingState state)? onSelectionFormatChanged;
  final ValueChanged<double>? onZoomScaleChanged;

  const WordPageCanvas({
    super.key,
    required this.document,
    this.isEditMode = false,
    this.isReflowMode = false,
    this.zoomScale = 1.0,
    this.searchQuery,
    this.onContentChanged,
    this.onSelectionFormatChanged,
    this.onZoomScaleChanged,
  });

  @override
  State<WordPageCanvas> createState() => WordPageCanvasState();
}

class WordPageCanvasState extends State<WordPageCanvas> {
  final Map<String, RichParagraphEditingController> _controllers = {};
  String? _activeBlockId;
  late final TransformationController _transformationController;
  double _fitScale = 1.0;
  bool _initializedScale = false;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController();
    _transformationController.addListener(_onTransformationChanged);
    _initControllers();
  }

  void _onTransformationChanged() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    widget.onZoomScaleChanged?.call(currentScale);
  }

  @override
  void didUpdateWidget(covariant WordPageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != oldWidget.searchQuery) {
      for (final ctrl in _controllers.values) {
        ctrl.searchQuery = widget.searchQuery;
        ctrl.refresh();
      }
    }
    if (widget.isEditMode != oldWidget.isEditMode) {
      for (final ctrl in _controllers.values) {
        ctrl.isEditing = widget.isEditMode;
        ctrl.refresh();
      }
    }
  }

  Future<void> _handleLinkTap(String rawUrl) async {
    final url = RichParagraphEditingController.normalizeUrl(rawUrl);
    final uri = Uri.tryParse(url);
    if (uri != null) {
      try {
        bool launched = false;
        try {
          launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          launched = false;
        }
        if (!launched) {
          try {
            launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
          } catch (_) {
            launched = false;
          }
        }
        if (!launched && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open link: $url')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error opening link: $e')),
          );
        }
      }
    }
  }

  void zoomIn() {
    _zoomBy(1.15);
  }

  void zoomOut() {
    _zoomBy(1 / 1.15);
  }

  void toggleFitOrOriginal() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    if ((currentScale - _fitScale).abs() < 0.08) {
      _setZoomScale(1.0);
    } else {
      _setZoomScale(_fitScale);
    }
  }

  void _zoomBy(double factor) {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final newScale = (currentScale * factor).clamp(0.2, 3.5);
    _setZoomScale(newScale);
  }

  void _setZoomScale(double targetScale) {
    final matrix = _transformationController.value.clone();
    final currentScale = matrix.getMaxScaleOnAxis();
    if (currentScale == 0) return;
    final scaleFactor = targetScale / currentScale;
    matrix.scale(scaleFactor, scaleFactor);
    _transformationController.value = matrix;
  }

  void _initControllers() {
    for (final b in widget.document.blocks) {
      if (b is WordParagraphBlock) {
        final ctrl = RichParagraphEditingController(
          block: b,
          searchQuery: widget.searchQuery,
          onLinkTap: _handleLinkTap,
        )..isEditing = widget.isEditMode;
        ctrl.addListener(() {
          ctrl.syncRunsFromText();
          widget.onContentChanged?.call();
        });
        _controllers[b.id] = ctrl;
      }
    }
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformationChanged);
    _transformationController.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  RichParagraphEditingController? get activeController =>
      _activeBlockId != null ? _controllers[_activeBlockId] : null;

  void applyFormattingToActiveSelection({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    String? fontFamily,
    double? fontSizePt,
    Color? textColor,
    Color? highlightColor,
  }) {
    activeController?.applyFormatting(
      bold: bold,
      italic: italic,
      underline: underline,
      strikethrough: strikethrough,
      fontFamily: fontFamily,
      fontSizePt: fontSizePt,
      textColor: textColor,
      highlightColor: highlightColor,
    );
    widget.onContentChanged?.call();
    setState(() {});
  }

  void setAlignmentOnActiveBlock(String align) {
    if (_activeBlockId == null) return;
    for (final b in widget.document.blocks) {
      if (b is WordParagraphBlock && b.id == _activeBlockId) {
        b.alignment = align;
        widget.onContentChanged?.call();
        setState(() {});
        break;
      }
    }
  }

  void setHeadingLevelOnActiveBlock(int level) {
    if (_activeBlockId == null) return;
    for (final b in widget.document.blocks) {
      if (b is WordParagraphBlock && b.id == _activeBlockId) {
        b.headingLevel = level;
        widget.onContentChanged?.call();
        setState(() {});
        break;
      }
    }
  }

  void setListTypeOnActiveBlock(String listType) {
    if (_activeBlockId == null) return;
    for (final b in widget.document.blocks) {
      if (b is WordParagraphBlock && b.id == _activeBlockId) {
        b.listType = listType;
        widget.onContentChanged?.call();
        setState(() {});
        break;
      }
    }
  }

  void setLineSpacingOnActiveBlock(double spacing) {
    if (_activeBlockId == null) return;
    for (final b in widget.document.blocks) {
      if (b is WordParagraphBlock && b.id == _activeBlockId) {
        b.lineSpacing = spacing;
        widget.onContentChanged?.call();
        setState(() {});
        break;
      }
    }
  }

  void insertTable(int rows, int cols) {
    final tableRows = <WordTableRow>[];
    for (int r = 0; r < rows; r++) {
      final cells = <WordTableCell>[];
      for (int c = 0; c < cols; c++) {
        final p = WordParagraphBlock(id: 'p_tbl_${DateTime.now().millisecondsSinceEpoch}_${r}_$c');
        _controllers[p.id] = RichParagraphEditingController(block: p, onLinkTap: _handleLinkTap);
        cells.add(WordTableCell(paragraphs: [p]));
      }
      tableRows.add(WordTableRow(cells: cells));
    }
    final block = WordTableBlock(
      id: 'tbl_${DateTime.now().millisecondsSinceEpoch}',
      rows: tableRows,
    );
    widget.document.blocks.add(block);
    widget.onContentChanged?.call();
    setState(() {});
  }

  void insertPageBreak() {
    final pb = WordPageBreakBlock(id: 'pb_${DateTime.now().millisecondsSinceEpoch}');
    widget.document.blocks.add(pb);
    widget.onContentChanged?.call();
    setState(() {});
  }

  void insertDivider() {
    final p = WordParagraphBlock(
      id: 'div_${DateTime.now().millisecondsSinceEpoch}',
      runs: [WordTextRun(text: '────────────────────────────────────────')],
      alignment: 'center',
    );
    _controllers[p.id] = RichParagraphEditingController(block: p, onLinkTap: _handleLinkTap);
    widget.document.blocks.add(p);
    widget.onContentChanged?.call();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final canvasBg = isDark ? const Color(0xFF181A1B) : const Color(0xFFE8EAED);

    return Container(
      color: canvasBg,
      child: Column(
        children: [
          // Horizontal Page Ruler
          if (!widget.isReflowMode) _buildHorizontalRuler(isDark),

          // Interactive Zoomable & Pannable Canvas Area
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewportWidth = constraints.maxWidth;

                // Auto-fit to display width on first layout
                if (!_initializedScale && viewportWidth > 0) {
                  _initializedScale = true;
                  const double paperWidth = 816.0;
                  final availableWidth = viewportWidth - 32.0;
                  _fitScale = (availableWidth / paperWidth).clamp(0.2, 2.0);

                  final initialX = (viewportWidth - (paperWidth * _fitScale)) / 2;
                  const initialY = 16.0;
                  _transformationController.value = Matrix4.identity()
                    ..translate(initialX, initialY)
                    ..scale(_fitScale, _fitScale, 1.0);

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      widget.onZoomScaleChanged?.call(_fitScale);
                    }
                  });
                }

                return InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 0.2,
                  maxScale: 3.5,
                  panEnabled: true,
                  scaleEnabled: true,
                  boundaryMargin: const EdgeInsets.symmetric(vertical: 400, horizontal: 200),
                  constrained: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: SelectionArea(
                      child: widget.isReflowMode
                          ? _buildReflowView(theme, isDark)
                          : _buildPaper(theme, isDark),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHorizontalRuler(bool isDark) {
    return Container(
      height: 20,
      width: double.infinity,
      color: isDark ? const Color(0xFF282A2C) : const Color(0xFFF1F3F4),
      child: CustomPaint(
        painter: _RulerPainter(isDark: isDark),
      ),
    );
  }

  Widget _buildPaper(ThemeData theme, bool isDark) {
    const double paperWidth = 816.0; // Standard A4 width at 96 DPI

    return Container(
      width: paperWidth,
      constraints: const BoxConstraints(minHeight: 1056.0),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF242526) : Colors.white,
        borderRadius: BorderRadius.circular(2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.4 : 0.15),
            blurRadius: 10,
            spreadRadius: 2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: EdgeInsets.symmetric(
        horizontal: widget.document.pageSetup.marginLeftPt,
        vertical: widget.document.pageSetup.marginTopPt,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widget.document.blocks.map((block) => _buildBlockWidget(block, theme)).toList(),
      ),
    );
  }

  Widget _buildReflowView(ThemeData theme, bool isDark) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 640),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF242526) : Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widget.document.blocks.map((block) => _buildBlockWidget(block, theme)).toList(),
      ),
    );
  }

  Widget _buildBlockWidget(WordBlock block, ThemeData theme) {
    if (block is WordPageBreakBlock) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 24),
        child: Row(
          children: [
            const Expanded(child: Divider(thickness: 1, color: Colors.blueAccent)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Page Break',
                style: TextStyle(fontSize: 11, color: Colors.blueAccent.shade700, fontWeight: FontWeight.bold),
              ),
            ),
            const Expanded(child: Divider(thickness: 1, color: Colors.blueAccent)),
          ],
        ),
      );
    }

    if (block is WordImageBlock) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(
            block.imageBytes,
            width: block.width,
            height: block.height,
            fit: BoxFit.contain,
          ),
        ),
      );
    }

    if (block is WordTableBlock) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400, width: 1.0),
        ),
        child: Table(
          border: TableBorder.all(color: Colors.grey.shade300, width: 0.5),
          children: block.rows.map((row) {
            return TableRow(
              children: row.cells.map((cell) {
                Color? bg;
                if (cell.backgroundColorHex != null) {
                  try {
                    final h = cell.backgroundColorHex!.replaceAll('#', '');
                    bg = Color(int.parse('FF$h', radix: 16));
                  } catch (_) {}
                }
                return Container(
                  color: bg,
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: cell.paragraphs.map((p) => _buildParagraphWidget(p, theme)).toList(),
                  ),
                );
              }).toList(),
            );
          }).toList(),
        ),
      );
    }

    if (block is WordParagraphBlock) {
      return _buildParagraphWidget(block, theme);
    }

    return const SizedBox.shrink();
  }

  Widget _buildParagraphWidget(WordParagraphBlock p, ThemeData theme) {
    final ctrl = _controllers[p.id] ??= RichParagraphEditingController(
      block: p,
      searchQuery: widget.searchQuery,
      onLinkTap: _handleLinkTap,
    );
    ctrl.searchQuery = widget.searchQuery;
    ctrl.isEditing = widget.isEditMode;

    TextAlign align = TextAlign.left;
    if (p.alignment == 'center') align = TextAlign.center;
    else if (p.alignment == 'right') align = TextAlign.right;
    else if (p.alignment == 'justify') align = TextAlign.justify;

    double fontSize = 11.0;
    FontWeight fontWeight = FontWeight.normal;
    if (p.headingLevel == 1) {
      fontSize = 20.0;
      fontWeight = FontWeight.bold;
    } else if (p.headingLevel == 2) {
      fontSize = 16.0;
      fontWeight = FontWeight.bold;
    } else if (p.headingLevel == 3) {
      fontSize = 14.0;
      fontWeight = FontWeight.bold;
    } else if (p.headingLevel == 7) {
      fontSize = 26.0;
      fontWeight = FontWeight.bold;
    } else if (p.headingLevel == 8) {
      fontSize = 14.0;
      fontWeight = FontWeight.w500;
    }

    final isList = p.listType != 'none';
    final bullet = p.listType == 'bullet' ? '•  ' : '1.  ';

    return Padding(
      padding: EdgeInsets.only(
        left: p.indentLeft + (isList ? 16.0 : 0.0),
        bottom: p.headingLevel > 0 ? 8.0 : 4.0,
        top: p.headingLevel > 0 ? 12.0 : 0.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isList)
            Text(
              bullet,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                height: p.lineSpacing,
              ),
            ),
          Expanded(
            child: widget.isEditMode
                ? Focus(
                    onFocusChange: (hasFocus) {
                      if (hasFocus) {
                        setState(() => _activeBlockId = p.id);
                        final firstRun = p.runs.isNotEmpty ? p.runs.first : WordTextRun(text: '');
                        widget.onSelectionFormatChanged?.call(WordFormattingState(
                          fontFamily: firstRun.fontFamily,
                          fontSizePt: firstRun.fontSizePt,
                          isBold: firstRun.bold,
                          isItalic: firstRun.italic,
                          isUnderline: firstRun.underline,
                          isStrikethrough: firstRun.strikethrough,
                          alignment: p.alignment,
                          headingLevel: p.headingLevel,
                          listType: p.listType,
                          lineSpacing: p.lineSpacing,
                        ));
                      }
                    },
                    child: TextField(
                      controller: ctrl,
                      maxLines: null,
                      textAlign: align,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: fontWeight,
                        height: p.lineSpacing,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  )
                : Text.rich(
                    ctrl.buildTextSpan(
                      context: context,
                      withComposing: false,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: fontWeight,
                        height: p.lineSpacing,
                        color: theme.textTheme.bodyMedium?.color ?? Colors.black87,
                      ),
                    ),
                    textAlign: align,
                  ),
          ),
        ],
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  final bool isDark;
  _RulerPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isDark ? Colors.white30 : Colors.black26
      ..strokeWidth = 1.0;

    const double step = 20.0;
    for (double x = 0; x < size.width; x += step) {
      final isMajor = (x ~/ step) % 5 == 0;
      final h = isMajor ? size.height * 0.6 : size.height * 0.3;
      canvas.drawLine(Offset(x, size.height - h), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
