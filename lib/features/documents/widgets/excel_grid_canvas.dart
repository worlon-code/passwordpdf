import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/excel_workbook_model.dart';
import '../../../services/excel_formula_engine.dart';

/// Selection details reported to formula bar and live aggregation footer
class ExcelSelectionInfo {
  final int activeRow;
  final int activeCol;
  final ExcelCellRange? range;
  final ExcelCellData? activeCellData;

  const ExcelSelectionInfo({
    required this.activeRow,
    required this.activeCol,
    this.range,
    this.activeCellData,
  });

  String get coordinate => rowColToCellCoordinate(activeRow, activeCol);
  String get displayCoordinate => range != null && range!.cellCount > 1
      ? range!.toA1String()
      : coordinate;
}

/// 2D Virtualized Spreadsheet Grid for Microsoft Excel / Google Sheets
class ExcelGridCanvas extends StatefulWidget {
  final ExcelSheetModel sheet;
  final ExcelWorkbookModel? workbook;
  final bool isReadOnly;
  final Function(ExcelSelectionInfo info)? onSelectionChanged;
  final VoidCallback? onCellModified;

  const ExcelGridCanvas({
    super.key,
    required this.sheet,
    this.workbook,
    this.isReadOnly = false,
    this.onSelectionChanged,
    this.onCellModified,
  });

  @override
  State<ExcelGridCanvas> createState() => ExcelGridCanvasState();
}

class ExcelGridCanvasState extends State<ExcelGridCanvas> {
  final ScrollController _hScrollController = ScrollController();
  final ScrollController _vScrollController = ScrollController();
  final ScrollController _headerHScrollController = ScrollController();
  final ScrollController _headerVScrollController = ScrollController();

  int _activeRow = 0;
  int _activeCol = 0;
  ExcelCellRange? _selectedRange;

  // Inline Editing
  bool _isEditing = false;
  final TextEditingController _editController = TextEditingController();
  final FocusNode _editFocusNode = FocusNode();

  // Drag-to-resize column and row handles
  int? _resizingCol;
  double? _resizeStartX;
  double? _colStartWidth;

  int? _resizingRow;
  double? _resizeStartY;
  double? _rowStartHeight;

  // Drag selection
  bool _isDraggingSelection = false;
  int _dragStartRow = 0;
  int _dragStartCol = 0;

  @override
  void initState() {
    super.initState();
    // Synchronize sticky headers with content
    _hScrollController.addListener(() {
      if (_headerHScrollController.hasClients &&
          _headerHScrollController.offset != _hScrollController.offset) {
        _headerHScrollController.jumpTo(_hScrollController.offset);
      }
    });
    _headerHScrollController.addListener(() {
      if (_hScrollController.hasClients &&
          _hScrollController.offset != _headerHScrollController.offset) {
        _hScrollController.jumpTo(_headerHScrollController.offset);
      }
    });
    _vScrollController.addListener(() {
      if (_headerVScrollController.hasClients &&
          _headerVScrollController.offset != _vScrollController.offset) {
        _headerVScrollController.jumpTo(_vScrollController.offset);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ExcelGridCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sheet != oldWidget.sheet) {
      _selectedRange = null;
      _activeRow = 0;
      _activeCol = 0;
      _notifySelection();
    }
  }

  @override
  void dispose() {
    _hScrollController.dispose();
    _vScrollController.dispose();
    _headerHScrollController.dispose();
    _headerVScrollController.dispose();
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  void _notifySelection() {
    final cell = widget.sheet.getCell(_activeRow, _activeCol);
    widget.onSelectionChanged?.call(ExcelSelectionInfo(
      activeRow: _activeRow,
      activeCol: _activeCol,
      range: _selectedRange,
      activeCellData: cell,
    ));
  }

  static const BoxBorder _defaultBorder = Border(
    right: BorderSide(color: Color(0x339E9E9E), width: 0.5),
    bottom: BorderSide(color: Color(0x339E9E9E), width: 0.5),
  );
  static const BoxBorder _activeBorder = Border.fromBorderSide(
    BorderSide(color: Color(0xFF107C41), width: 2.0),
  );

  int get totalRows => math.max(30, widget.sheet.maxRow + 10);
  int get totalCols => math.max(12, widget.sheet.maxCol + 4);

  double get totalGridWidth {
    double w = 0;
    for (int c = 0; c < totalCols; c++) {
      w += getColWidth(c);
    }
    return w;
  }

  double getColWidth(int col) => widget.sheet.getColumnWidth(col);
  double getRowHeight(int row) => widget.sheet.getRowHeight(row);

  void navigateToCell(String coord) {
    final rc = cellCoordinateToRowCol(coord);
    if (rc != null) {
      setState(() {
        _activeRow = rc.$1;
        _activeCol = rc.$2;
        _selectedRange = ExcelCellRange(
          startRow: rc.$1,
          startCol: rc.$2,
          endRow: rc.$1,
          endCol: rc.$2,
        );
      });
      _scrollToCell(rc.$1, rc.$2);
      _notifySelection();
    }
  }

  void updateActiveCellFormulaOrValue(String value) {
    final cell = widget.sheet.getOrCreateCell(_activeRow, _activeCol);
    final trimmed = value.trim();
    if (trimmed.startsWith('=')) {
      cell.formula = trimmed;
      cell.rawValue = trimmed;
    } else {
      cell.formula = null;
      cell.rawValue = value;
      cell.evaluatedValue = value;
    }
    ExcelFormulaEngine().recalculateSheet(widget.sheet, widget.workbook);
    widget.onCellModified?.call();
    setState(() {});
    _notifySelection();
  }

  void _scrollToCell(int row, int col) {
    double x = 0;
    for (int c = 0; c < col; c++) x += getColWidth(c);
    double y = 0;
    for (int r = 0; r < row; r++) y += getRowHeight(r);

    if (_hScrollController.hasClients) {
      if (x < _hScrollController.offset || x > _hScrollController.offset + 300) {
        _hScrollController.animateTo(x, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    }
    if (_vScrollController.hasClients) {
      if (y < _vScrollController.offset || y > _vScrollController.offset + 400) {
        _vScrollController.animateTo(y, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    }
  }

  void _startEditing([String? initialText]) {
    if (widget.isReadOnly) return;
    final cell = widget.sheet.getCell(_activeRow, _activeCol);
    final text = initialText ?? cell?.formula ?? cell?.rawValue ?? '';
    _editController.text = text;
    _editController.selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    setState(() {
      _isEditing = true;
    });
    _editFocusNode.requestFocus();
  }

  void _commitEdit() {
    if (!_isEditing) return;
    updateActiveCellFormulaOrValue(_editController.text);
    setState(() {
      _isEditing = false;
    });
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Keyboard Navigation
  // ---------------------------------------------------------------------------

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    if (_isEditing) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _cancelEdit();
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        _commitEdit();
        _moveActiveCell(1, 0);
      }
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveActiveCell(1, 0);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveActiveCell(-1, 0);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight || event.logicalKey == LogicalKeyboardKey.tab) {
      _moveActiveCell(0, 1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _moveActiveCell(0, -1);
    } else if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.f2) {
      _startEditing();
    } else if (event.logicalKey == LogicalKeyboardKey.delete || event.logicalKey == LogicalKeyboardKey.backspace) {
      _clearSelectedCells();
    }
  }

  void _moveActiveCell(int dRow, int dCol) {
    final newR = math.max(0, math.min(totalRows - 1, _activeRow + dRow));
    final newC = math.max(0, math.min(totalCols - 1, _activeCol + dCol));
    setState(() {
      _activeRow = newR;
      _activeCol = newC;
      _selectedRange = ExcelCellRange(
        startRow: newR,
        startCol: newC,
        endRow: newR,
        endCol: newC,
      );
    });
    _scrollToCell(newR, newC);
    _notifySelection();
  }

  void _clearSelectedCells() {
    if (widget.isReadOnly) return;
    final r = _selectedRange ??
        ExcelCellRange(
          startRow: _activeRow,
          startCol: _activeCol,
          endRow: _activeRow,
          endCol: _activeCol,
        );

    for (int row = r.minRow; row <= r.maxRow; row++) {
      for (int col = r.minCol; col <= r.maxCol; col++) {
        widget.sheet.setCell(row, col, ExcelCellData(rawValue: ''));
      }
    }
    widget.onCellModified?.call();
    setState(() {});
    _notifySelection();
  }

  // ---------------------------------------------------------------------------
  // Build Methods
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const double rowHeaderWidth = 44.0;
    const double colHeaderHeight = 26.0;

    return KeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      onKeyEvent: _handleKeyEvent,
      child: Column(
        children: [
          // Sticky Top Column Header Row (with Corner Box)
          Row(
            children: [
              // 1. Top-Left Select-All Corner Box
              InkWell(
                onTap: () {
                  setState(() {
                    _activeRow = 0;
                    _activeCol = 0;
                    _selectedRange = ExcelCellRange(
                      startRow: 0,
                      startCol: 0,
                      endRow: totalRows - 1,
                      endCol: totalCols - 1,
                    );
                  });
                  _notifySelection();
                },
                child: Container(
                  width: rowHeaderWidth,
                  height: colHeaderHeight,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF2C2D30) : const Color(0xFFE8EAED),
                    border: Border.all(color: Colors.grey.withOpacity(0.4), width: 0.5),
                  ),
                  child: Center(
                    child: CustomPaint(
                      size: const Size(8, 8),
                      painter: _TrianglePainter(isDark: isDark),
                    ),
                  ),
                ),
              ),

              // 2. Horizontal Column Headers (A, B, C...)
              Expanded(
                child: SingleChildScrollView(
                  controller: _headerHScrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: Row(
                    children: List.generate(totalCols, (c) => _buildColumnHeader(c, colHeaderHeight, isDark)),
                  ),
                ),
              ),
            ],
          ),

          // Main Viewport (Sticky Row Headers + Virtualized 2D Grid)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 3. Vertical Row Headers (1, 2, 3...)
                SizedBox(
                  width: rowHeaderWidth,
                  child: ListView.builder(
                    controller: _headerVScrollController,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: totalRows,
                    itemExtentBuilder: (index, _) => getRowHeight(index),
                    itemBuilder: (context, r) => _buildRowHeader(r, rowHeaderWidth, isDark),
                  ),
                ),

                // 4. Virtualized Spreadsheet Cells Grid
                Expanded(
                  child: SingleChildScrollView(
                    controller: _hScrollController,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: SizedBox(
                      width: totalGridWidth,
                      child: ListView.builder(
                        controller: _vScrollController,
                        physics: const ClampingScrollPhysics(),
                        itemCount: totalRows,
                        itemExtentBuilder: (index, _) => getRowHeight(index),
                        itemBuilder: (context, r) {
                          return Row(
                            children: List.generate(totalCols, (c) => _buildCell(r, c, isDark)),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColumnHeader(int col, double height, bool isDark) {
    final width = getColWidth(col);
    final letters = colIndexToLetters(col);
    final isColActive = _activeCol == col ||
        (_selectedRange != null && col >= _selectedRange!.minCol && col <= _selectedRange!.maxCol);

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: isColActive
                  ? const Color(0xFF107C41).withOpacity(0.2)
                  : (isDark ? const Color(0xFF2C2D30) : const Color(0xFFF1F3F4)),
              border: Border(
                right: BorderSide(color: Colors.grey.withOpacity(0.4), width: 0.5),
                bottom: BorderSide(color: Colors.grey.withOpacity(0.4), width: 0.5),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              letters,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isColActive ? FontWeight.bold : FontWeight.w600,
                color: isColActive
                    ? const Color(0xFF107C41)
                    : (isDark ? Colors.white70 : const Color(0xFF333333)),
              ),
            ),
          ),
          // Drag handle for resizing column
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 8,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (details) {
                _resizingCol = col;
                _resizeStartX = details.globalPosition.dx;
                _colStartWidth = width;
              },
              onHorizontalDragUpdate: (details) {
                if (_resizingCol == col && _resizeStartX != null && _colStartWidth != null) {
                  final delta = details.globalPosition.dx - _resizeStartX!;
                  final newW = math.max(30.0, _colStartWidth! + delta);
                  setState(() {
                    widget.sheet.columnWidths[col] = newW;
                  });
                }
              },
              onHorizontalDragEnd: (_) {
                _resizingCol = null;
              },
              child: const MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRowHeader(int row, double width, bool isDark) {
    final height = getRowHeight(row);
    final isRowActive = _activeRow == row ||
        (_selectedRange != null && row >= _selectedRange!.minRow && row <= _selectedRange!.maxRow);

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: isRowActive
                  ? const Color(0xFF107C41).withOpacity(0.2)
                  : (isDark ? const Color(0xFF2C2D30) : const Color(0xFFF1F3F4)),
              border: Border(
                bottom: BorderSide(color: Colors.grey.withOpacity(0.4), width: 0.5),
                right: BorderSide(color: Colors.grey.withOpacity(0.4), width: 0.5),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '${row + 1}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: isRowActive ? FontWeight.bold : FontWeight.w600,
                color: isRowActive
                    ? const Color(0xFF107C41)
                    : (isDark ? Colors.white70 : const Color(0xFF333333)),
              ),
            ),
          ),
        // Drag handle for resizing row
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 8,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (details) {
              _resizingRow = row;
              _resizeStartY = details.globalPosition.dy;
              _rowStartHeight = height;
            },
            onVerticalDragUpdate: (details) {
              if (_resizingRow == row && _resizeStartY != null && _rowStartHeight != null) {
                final delta = details.globalPosition.dy - _resizeStartY!;
                final newH = math.max(18.0, _rowStartHeight! + delta);
                setState(() {
                  widget.sheet.rowHeights[row] = newH;
                });
              }
            },
            onVerticalDragEnd: (_) {
              _resizingRow = null;
            },
            child: const MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ],
    ),
    );
  }

  Widget _buildGridBody(bool isDark) {
    // Render cells in row-by-row structure
    return GestureDetector(
      onPanStart: (details) {
        final pos = _findRowColFromOffset(details.localPosition);
        if (pos != null) {
          setState(() {
            _dragStartRow = pos.$1;
            _dragStartCol = pos.$2;
            _activeRow = pos.$1;
            _activeCol = pos.$2;
            _selectedRange = ExcelCellRange(
              startRow: pos.$1,
              startCol: pos.$2,
              endRow: pos.$1,
              endCol: pos.$2,
            );
            _isDraggingSelection = true;
          });
          _notifySelection();
        }
      },
      onPanUpdate: (details) {
        if (_isDraggingSelection) {
          final pos = _findRowColFromOffset(details.localPosition);
          if (pos != null) {
            setState(() {
              _selectedRange = ExcelCellRange(
                startRow: _dragStartRow,
                startCol: _dragStartCol,
                endRow: pos.$1,
                endCol: pos.$2,
              );
            });
            _notifySelection();
          }
        }
      },
      onPanEnd: (_) {
        _isDraggingSelection = false;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(totalRows, (r) {
          return Row(
            children: List.generate(totalCols, (c) => _buildCell(r, c, isDark)),
          );
        }),
      ),
    );
  }

  Widget _buildCell(int row, int col, bool isDark) {
    final cell = widget.sheet.getCell(row, col);
    final width = getColWidth(col);
    final height = getRowHeight(row);

    final isSelected = _selectedRange != null && _selectedRange!.contains(row, col);
    final isActive = _activeRow == row && _activeCol == col;

    // Check if cell is part of merged range
    final merged = widget.sheet.getMergedRangeForCell(row, col);
    if (merged != null && (row != merged.minRow || col != merged.minCol)) {
      return const SizedBox.shrink(); // Covered by primary merged cell
    }

    double cellWidth = width;
    double cellHeight = height;
    if (merged != null) {
      cellWidth = 0;
      for (int c = merged.minCol; c <= merged.maxCol; c++) cellWidth += getColWidth(c);
      cellHeight = 0;
      for (int r = merged.minRow; r <= merged.maxRow; r++) cellHeight += getRowHeight(r);
    }

    // Fast path for empty, non-selected, non-active cells
    final isEmpty = cell == null || cell.rawValue.isEmpty;
    if (isEmpty && !isActive && !isSelected) {
      return SizedBox(
        width: cellWidth,
        height: cellHeight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _selectCell(row, col),
          onDoubleTap: () {
            _selectCell(row, col);
            _startEditing();
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              border: _defaultBorder,
            ),
          ),
        ),
      );
    }

    // Styling
    Color? cellBg;
    if (cell?.style.fillColorHex != null) {
      try {
        final h = cell!.style.fillColorHex!.replaceAll('#', '');
        cellBg = Color(int.parse('FF$h', radix: 16));
      } catch (_) {}
    }

    Color? textColor;
    if (cell?.style.textColorHex != null) {
      try {
        final h = cell!.style.textColorHex!.replaceAll('#', '');
        textColor = Color(int.parse('FF$h', radix: 16));
      } catch (_) {}
    }

    // Cell borders
    BoxBorder border = _defaultBorder;
    if (isActive) {
      border = _activeBorder;
    } else if (cell?.style.borders.hasAny == true) {
      final b = cell!.style.borders;
      border = Border(
        top: b.top ? const BorderSide(color: Colors.black, width: 1.0) : BorderSide.none,
        bottom: b.bottom ? const BorderSide(color: Colors.black, width: 1.0) : BorderSide.none,
        left: b.left ? const BorderSide(color: Colors.black, width: 1.0) : BorderSide.none,
        right: b.right ? const BorderSide(color: Colors.black, width: 1.0) : BorderSide.none,
      );
    }

    final effectiveBg = isSelected && !isActive
        ? const Color(0x1F107C41)
        : cellBg ?? (isDark ? const Color(0xFF1E1E1E) : Colors.white);

    Widget content;
    if (isActive && _isEditing) {
      content = TextField(
        controller: _editController,
        focusNode: _editFocusNode,
        style: const TextStyle(fontSize: 11),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (_) => _commitEdit(),
      );
    } else {
      final align = cell?.style.horizontalAlign == TextAlign.right
          ? Alignment.centerRight
          : cell?.style.horizontalAlign == TextAlign.center
              ? Alignment.center
              : Alignment.centerLeft;

      final textWidget = Align(
        alignment: align,
        child: Text(
          cell?.displayValue ?? '',
          maxLines: cell?.style.wrapText == true ? null : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: cell?.style.fontSize ?? 11,
            fontWeight: cell?.style.bold == true ? FontWeight.bold : FontWeight.normal,
            fontStyle: cell?.style.italic == true ? FontStyle.italic : FontStyle.normal,
            decoration: cell?.style.underline == true ? TextDecoration.underline : TextDecoration.none,
            color: textColor ?? (isDark ? Colors.white : const Color(0xFF1F1F1F)),
          ),
        ),
      );

      if (isActive) {
        content = Stack(
          clipBehavior: Clip.none,
          children: [
            textWidget,
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 6,
                height: 6,
                color: const Color(0xFF107C41),
              ),
            ),
          ],
        );
      } else {
        content = textWidget;
      }
    }

    return SizedBox(
      width: cellWidth,
      height: cellHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectCell(row, col),
        onDoubleTap: () {
          _selectCell(row, col);
          _startEditing();
        },
        child: Container(
          width: cellWidth,
          height: cellHeight,
          decoration: BoxDecoration(
            color: effectiveBg,
            border: border,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: content,
        ),
      ),
    );
  }

  void _selectCell(int row, int col) {
    if (_isEditing) _commitEdit();
    setState(() {
      _activeRow = row;
      _activeCol = col;
      _selectedRange = ExcelCellRange(
        startRow: row,
        startCol: col,
        endRow: row,
        endCol: col,
      );
    });
    _notifySelection();
  }

  (int, int)? _findRowColFromOffset(Offset localPos) {
    double x = 0;
    int? foundCol;
    for (int c = 0; c < totalCols; c++) {
      final w = getColWidth(c);
      if (localPos.dx >= x && localPos.dx <= x + w) {
        foundCol = c;
        break;
      }
      x += w;
    }

    double y = 0;
    int? foundRow;
    for (int r = 0; r < totalRows; r++) {
      final h = getRowHeight(r);
      if (localPos.dy >= y && localPos.dy <= y + h) {
        foundRow = r;
        break;
      }
      y += h;
    }

    if (foundRow != null && foundCol != null) {
      return (foundRow, foundCol);
    }
    return null;
  }
}

class _TrianglePainter extends CustomPainter {
  final bool isDark;
  _TrianglePainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isDark ? Colors.white54 : Colors.black45
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
