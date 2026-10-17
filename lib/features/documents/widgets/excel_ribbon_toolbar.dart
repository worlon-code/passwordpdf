import 'package:flutter/material.dart';
import '../../../models/excel_workbook_model.dart';

/// Formatting Ribbon for Microsoft Excel / Google Sheets
class ExcelRibbonToolbar extends StatelessWidget {
  final ExcelCellStyle activeStyle;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onCut;
  final VoidCallback? onCopy;
  final VoidCallback? onPaste;
  final VoidCallback? onToggleBold;
  final VoidCallback? onToggleItalic;
  final VoidCallback? onToggleUnderline;
  final ValueChanged<double>? onFontSizeChanged;
  final ValueChanged<Color?>? onTextColorChanged;
  final ValueChanged<Color?>? onFillColorChanged;
  final ValueChanged<String>? onBorderChanged; // 'all', 'outer', 'bottom', 'clear'
  final ValueChanged<TextAlign>? onAlignChanged;
  final VoidCallback? onToggleWrap;
  final VoidCallback? onMergeCenter;
  final ValueChanged<ExcelNumberFormat>? onNumberFormatChanged;
  final VoidCallback? onIncreaseDecimals;
  final VoidCallback? onDecreaseDecimals;
  final VoidCallback? onInsertRowAbove;
  final VoidCallback? onInsertRowBelow;
  final VoidCallback? onDeleteRow;
  final VoidCallback? onInsertColLeft;
  final VoidCallback? onInsertColRight;
  final VoidCallback? onDeleteCol;
  final VoidCallback? onSortAsc;
  final VoidCallback? onSortDesc;

  const ExcelRibbonToolbar({
    super.key,
    required this.activeStyle,
    this.canUndo = false,
    this.canRedo = false,
    this.onUndo,
    this.onRedo,
    this.onCut,
    this.onCopy,
    this.onPaste,
    this.onToggleBold,
    this.onToggleItalic,
    this.onToggleUnderline,
    this.onFontSizeChanged,
    this.onTextColorChanged,
    this.onFillColorChanged,
    this.onBorderChanged,
    this.onAlignChanged,
    this.onToggleWrap,
    this.onMergeCenter,
    this.onNumberFormatChanged,
    this.onIncreaseDecimals,
    this.onDecreaseDecimals,
    this.onInsertRowAbove,
    this.onInsertRowBelow,
    this.onDeleteRow,
    this.onInsertColLeft,
    this.onInsertColRight,
    this.onDeleteCol,
    this.onSortAsc,
    this.onSortDesc,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF202124) : const Color(0xFFF1F3F4);

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.white12 : Colors.black12,
            width: 1.0,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            // Clipboard: Cut, Copy, Paste
            IconButton(
              icon: const Icon(Icons.content_cut, size: 18),
              tooltip: 'Cut (Ctrl+X)',
              onPressed: onCut,
            ),
            IconButton(
              icon: const Icon(Icons.content_copy, size: 18),
              tooltip: 'Copy (Ctrl+C)',
              onPressed: onCopy,
            ),
            IconButton(
              icon: const Icon(Icons.content_paste, size: 18),
              tooltip: 'Paste (Ctrl+V)',
              onPressed: onPaste,
            ),
            _buildDivider(),

            // Undo / Redo
            IconButton(
              icon: const Icon(Icons.undo, size: 18),
              tooltip: 'Undo (Ctrl+Z)',
              onPressed: canUndo ? onUndo : null,
            ),
            IconButton(
              icon: const Icon(Icons.redo, size: 18),
              tooltip: 'Redo (Ctrl+Y)',
              onPressed: canRedo ? onRedo : null,
            ),
            _buildDivider(),

            // Font Size
            _buildFontSizeDropdown(context),
            const SizedBox(width: 4),

            // Bold, Italic, Underline
            _buildToggleButton(
              icon: Icons.format_bold,
              tooltip: 'Bold (Ctrl+B)',
              isActive: activeStyle.bold,
              onPressed: onToggleBold,
            ),
            _buildToggleButton(
              icon: Icons.format_italic,
              tooltip: 'Italic (Ctrl+I)',
              isActive: activeStyle.italic,
              onPressed: onToggleItalic,
            ),
            _buildToggleButton(
              icon: Icons.format_underlined,
              tooltip: 'Underline (Ctrl+U)',
              isActive: activeStyle.underline,
              onPressed: onToggleUnderline,
            ),

            // Text Color
            _buildColorPicker(
              context,
              icon: Icons.format_color_text,
              tooltip: 'Text Color',
              currentColor: _parseHex(activeStyle.textColorHex) ?? (isDark ? Colors.white : Colors.black),
              onSelected: onTextColorChanged,
            ),

            // Fill Color (Bucket)
            _buildColorPicker(
              context,
              icon: Icons.format_color_fill,
              tooltip: 'Fill Color',
              currentColor: _parseHex(activeStyle.fillColorHex),
              isFill: true,
              onSelected: onFillColorChanged,
            ),

            // Borders dropdown
            _buildBordersMenu(context),
            _buildDivider(),

            // Alignment: Left, Center, Right
            _buildToggleButton(
              icon: Icons.format_align_left,
              tooltip: 'Align Left',
              isActive: activeStyle.horizontalAlign == TextAlign.left,
              onPressed: () => onAlignChanged?.call(TextAlign.left),
            ),
            _buildToggleButton(
              icon: Icons.format_align_center,
              tooltip: 'Center',
              isActive: activeStyle.horizontalAlign == TextAlign.center,
              onPressed: () => onAlignChanged?.call(TextAlign.center),
            ),
            _buildToggleButton(
              icon: Icons.format_align_right,
              tooltip: 'Align Right',
              isActive: activeStyle.horizontalAlign == TextAlign.right,
              onPressed: () => onAlignChanged?.call(TextAlign.right),
            ),

            // Text Wrapping
            _buildToggleButton(
              icon: Icons.wrap_text,
              tooltip: 'Wrap Text',
              isActive: activeStyle.wrapText,
              onPressed: onToggleWrap,
            ),

            // Merge & Center
            IconButton(
              icon: const Icon(Icons.call_merge, size: 18),
              tooltip: 'Merge & Center',
              onPressed: onMergeCenter,
            ),
            _buildDivider(),

            // Number Formats: $, %, 1,234.56, decimals
            IconButton(
              icon: const Icon(Icons.attach_money, size: 18),
              tooltip: 'Format as Currency',
              onPressed: () => onNumberFormatChanged?.call(ExcelNumberFormat.currency),
            ),
            IconButton(
              icon: const Icon(Icons.percent, size: 18),
              tooltip: 'Format as Percent',
              onPressed: () => onNumberFormatChanged?.call(ExcelNumberFormat.percent),
            ),
            IconButton(
              icon: const Icon(Icons.tag, size: 18),
              tooltip: 'Format as Number',
              onPressed: () => onNumberFormatChanged?.call(ExcelNumberFormat.number),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_left, size: 18),
              tooltip: 'Increase Decimal Places',
              onPressed: onIncreaseDecimals,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_right, size: 18),
              tooltip: 'Decrease Decimal Places',
              onPressed: onDecreaseDecimals,
            ),
            _buildDivider(),

            // Sheet structure menu
            _buildStructureMenu(context),

            // Sort A->Z, Z->A
            IconButton(
              icon: const Icon(Icons.arrow_downward, size: 18),
              tooltip: 'Sort Column Ascending (A→Z)',
              onPressed: onSortAsc,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_upward, size: 18),
              tooltip: 'Sort Column Descending (Z→A)',
              onPressed: onSortDesc,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.grey.withOpacity(0.3),
    );
  }

  Widget _buildToggleButton({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    VoidCallback? onPressed,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: isActive ? Colors.green.withOpacity(0.2) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: IconButton(
        icon: Icon(icon, size: 18, color: isActive ? const Color(0xFF107C41) : null),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildFontSizeDropdown(BuildContext context) {
    const sizes = [8.0, 9.0, 10.0, 11.0, 12.0, 14.0, 16.0, 18.0, 20.0, 24.0];
    final current = sizes.contains(activeStyle.fontSize) ? activeStyle.fontSize : 11.0;

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400, width: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<double>(
          value: current,
          isDense: true,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
          items: sizes.map((s) {
            return DropdownMenuItem<double>(
              value: s,
              child: Text(s.toInt().toString()),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) onFontSizeChanged?.call(val);
          },
        ),
      ),
    );
  }

  Widget _buildColorPicker(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    Color? currentColor,
    bool isFill = false,
    ValueChanged<Color?>? onSelected,
  }) {
    final palette = [
      Colors.white,
      Colors.black,
      const Color(0xFF107C41), // Excel Green
      const Color(0xFFD9EAD3), // Light Green
      const Color(0xFFFFF2CC), // Light Yellow
      const Color(0xFFFCE5CD), // Light Orange
      const Color(0xFFF4CCCC), // Light Red
      const Color(0xFFC9DAF8), // Light Blue
      Colors.grey.shade300,
    ];

    return PopupMenuButton<Color?>(
      tooltip: tooltip,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          Container(
            height: 3,
            width: 14,
            color: currentColor ?? (isFill ? Colors.transparent : Colors.black),
          ),
        ],
      ),
      itemBuilder: (ctx) => [
        PopupMenuItem<Color?>(
          value: null,
          child: const Text('No Fill / Default'),
        ),
        ...palette.map((c) => PopupMenuItem<Color?>(
              value: c,
              child: Container(
                width: 100,
                height: 20,
                color: c,
              ),
            )),
      ],
      onSelected: onSelected,
    );
  }

  Widget _buildBordersMenu(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Borders',
      icon: const Icon(Icons.border_all, size: 18),
      onSelected: onBorderChanged,
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: 'all',
          child: Row(children: [Icon(Icons.border_all), SizedBox(width: 8), Text('All Borders')]),
        ),
        const PopupMenuItem(
          value: 'outer',
          child: Row(children: [Icon(Icons.border_outer), SizedBox(width: 8), Text('Outer Borders')]),
        ),
        const PopupMenuItem(
          value: 'bottom',
          child: Row(children: [Icon(Icons.border_bottom), SizedBox(width: 8), Text('Bottom Border')]),
        ),
        const PopupMenuItem(
          value: 'clear',
          child: Row(children: [Icon(Icons.border_clear), SizedBox(width: 8), Text('No Border')]),
        ),
      ],
    );
  }

  Widget _buildStructureMenu(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Insert / Delete Rows & Columns',
      icon: const Icon(Icons.table_rows, size: 18),
      onSelected: (val) {
        if (val == 'row_above') onInsertRowAbove?.call();
        else if (val == 'row_below') onInsertRowBelow?.call();
        else if (val == 'del_row') onDeleteRow?.call();
        else if (val == 'col_left') onInsertColLeft?.call();
        else if (val == 'col_right') onInsertColRight?.call();
        else if (val == 'del_col') onDeleteCol?.call();
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(value: 'row_above', child: Text('Insert Row Above')),
        const PopupMenuItem(value: 'row_below', child: Text('Insert Row Below')),
        const PopupMenuItem(value: 'del_row', child: Text('Delete Selected Row')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'col_left', child: Text('Insert Column Left')),
        const PopupMenuItem(value: 'col_right', child: Text('Insert Column Right')),
        const PopupMenuItem(value: 'del_col', child: Text('Delete Selected Column')),
      ],
    );
  }

  Color? _parseHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      final clean = hex.replaceAll('#', '');
      return Color(int.parse('FF$clean', radix: 16));
    } catch (_) {
      return null;
    }
  }
}
