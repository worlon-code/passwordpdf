import 'package:flutter/material.dart';

/// Formatting state reported and controlled by the ribbon toolbar
class WordFormattingState {
  final String fontFamily;
  final double fontSizePt;
  final bool isBold;
  final bool isItalic;
  final bool isUnderline;
  final bool isStrikethrough;
  final Color? textColor;
  final Color? highlightColor;
  final String alignment; // 'left', 'center', 'right', 'justify'
  final int headingLevel; // 0=Normal, 1..6=H1..H6, 7=Title, 8=Subtitle
  final String listType; // 'none', 'bullet', 'numbered'
  final double lineSpacing;

  const WordFormattingState({
    this.fontFamily = 'Calibri',
    this.fontSizePt = 11.0,
    this.isBold = false,
    this.isItalic = false,
    this.isUnderline = false,
    this.isStrikethrough = false,
    this.textColor,
    this.highlightColor,
    this.alignment = 'left',
    this.headingLevel = 0,
    this.listType = 'none',
    this.lineSpacing = 1.15,
  });

  WordFormattingState copyWith({
    String? fontFamily,
    double? fontSizePt,
    bool? isBold,
    bool? isItalic,
    bool? isUnderline,
    bool? isStrikethrough,
    Color? textColor,
    Color? highlightColor,
    String? alignment,
    int? headingLevel,
    String? listType,
    double? lineSpacing,
  }) {
    return WordFormattingState(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSizePt: fontSizePt ?? this.fontSizePt,
      isBold: isBold ?? this.isBold,
      isItalic: isItalic ?? this.isItalic,
      isUnderline: isUnderline ?? this.isUnderline,
      isStrikethrough: isStrikethrough ?? this.isStrikethrough,
      textColor: textColor ?? this.textColor,
      highlightColor: highlightColor ?? this.highlightColor,
      alignment: alignment ?? this.alignment,
      headingLevel: headingLevel ?? this.headingLevel,
      listType: listType ?? this.listType,
      lineSpacing: lineSpacing ?? this.lineSpacing,
    );
  }
}

/// Word ribbon toolbar formatted like Microsoft Word / Google Docs
class WordRibbonToolbar extends StatelessWidget {
  final WordFormattingState state;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final ValueChanged<String>? onFontFamilyChanged;
  final ValueChanged<double>? onFontSizeChanged;
  final VoidCallback? onToggleBold;
  final VoidCallback? onToggleItalic;
  final VoidCallback? onToggleUnderline;
  final VoidCallback? onToggleStrikethrough;
  final ValueChanged<Color?>? onTextColorChanged;
  final ValueChanged<Color?>? onHighlightColorChanged;
  final ValueChanged<String>? onAlignmentChanged;
  final ValueChanged<int>? onHeadingLevelChanged;
  final ValueChanged<String>? onListTypeChanged;
  final ValueChanged<double>? onLineSpacingChanged;
  final VoidCallback? onClearFormatting;
  final VoidCallback? onInsertTable;
  final VoidCallback? onInsertPageBreak;
  final VoidCallback? onInsertDivider;

  const WordRibbonToolbar({
    super.key,
    required this.state,
    this.canUndo = false,
    this.canRedo = false,
    this.onUndo,
    this.onRedo,
    this.onFontFamilyChanged,
    this.onFontSizeChanged,
    this.onToggleBold,
    this.onToggleItalic,
    this.onToggleUnderline,
    this.onToggleStrikethrough,
    this.onTextColorChanged,
    this.onHighlightColorChanged,
    this.onAlignmentChanged,
    this.onHeadingLevelChanged,
    this.onListTypeChanged,
    this.onLineSpacingChanged,
    this.onClearFormatting,
    this.onInsertTable,
    this.onInsertPageBreak,
    this.onInsertDivider,
  });

  static const List<String> kFontFamilies = [
    'Calibri',
    'Roboto',
    'Arial',
    'Times New Roman',
    'Merriweather',
    'Roboto Mono',
  ];

  static const List<double> kFontSizes = [
    8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72,
  ];

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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            // Undo & Redo
            IconButton(
              icon: const Icon(Icons.undo, size: 20),
              tooltip: 'Undo (Ctrl+Z)',
              onPressed: canUndo ? onUndo : null,
            ),
            IconButton(
              icon: const Icon(Icons.redo, size: 20),
              tooltip: 'Redo (Ctrl+Y)',
              onPressed: canRedo ? onRedo : null,
            ),
            _buildDivider(),

            // Heading / Style selector
            _buildHeadingDropdown(context),
            const SizedBox(width: 6),

            // Font Family
            _buildFontDropdown(context),
            const SizedBox(width: 6),

            // Font Size
            _buildFontSizeDropdown(context),
            _buildDivider(),

            // Bold, Italic, Underline, Strikethrough
            _buildToggleButton(
              icon: Icons.format_bold,
              tooltip: 'Bold (Ctrl+B)',
              isActive: state.isBold,
              onPressed: onToggleBold,
            ),
            _buildToggleButton(
              icon: Icons.format_italic,
              tooltip: 'Italic (Ctrl+I)',
              isActive: state.isItalic,
              onPressed: onToggleItalic,
            ),
            _buildToggleButton(
              icon: Icons.format_underlined,
              tooltip: 'Underline (Ctrl+U)',
              isActive: state.isUnderline,
              onPressed: onToggleUnderline,
            ),
            _buildToggleButton(
              icon: Icons.strikethrough_s,
              tooltip: 'Strikethrough',
              isActive: state.isStrikethrough,
              onPressed: onToggleStrikethrough,
            ),
            _buildDivider(),

            // Text Color
            _buildColorPickerButton(
              context,
              icon: Icons.format_color_text,
              tooltip: 'Text Color',
              currentColor: state.textColor ?? (isDark ? Colors.white : Colors.black),
              onColorSelected: onTextColorChanged,
            ),

            // Highlight Color
            _buildColorPickerButton(
              context,
              icon: Icons.border_color,
              tooltip: 'Highlight Color',
              currentColor: state.highlightColor,
              isHighlight: true,
              onColorSelected: onHighlightColorChanged,
            ),

            // Clear Formatting
            IconButton(
              icon: const Icon(Icons.format_clear, size: 20),
              tooltip: 'Clear Formatting',
              onPressed: onClearFormatting,
            ),
            _buildDivider(),

            // Alignment
            _buildToggleButton(
              icon: Icons.format_align_left,
              tooltip: 'Align Left',
              isActive: state.alignment == 'left',
              onPressed: () => onAlignmentChanged?.call('left'),
            ),
            _buildToggleButton(
              icon: Icons.format_align_center,
              tooltip: 'Align Center',
              isActive: state.alignment == 'center',
              onPressed: () => onAlignmentChanged?.call('center'),
            ),
            _buildToggleButton(
              icon: Icons.format_align_right,
              tooltip: 'Align Right',
              isActive: state.alignment == 'right',
              onPressed: () => onAlignmentChanged?.call('right'),
            ),
            _buildToggleButton(
              icon: Icons.format_align_justify,
              tooltip: 'Justify',
              isActive: state.alignment == 'justify',
              onPressed: () => onAlignmentChanged?.call('justify'),
            ),
            _buildDivider(),

            // Bullet & Numbered List
            _buildToggleButton(
              icon: Icons.format_list_bulleted,
              tooltip: 'Bulleted List',
              isActive: state.listType == 'bullet',
              onPressed: () => onListTypeChanged?.call(state.listType == 'bullet' ? 'none' : 'bullet'),
            ),
            _buildToggleButton(
              icon: Icons.format_list_numbered,
              tooltip: 'Numbered List',
              isActive: state.listType == 'numbered',
              onPressed: () => onListTypeChanged?.call(state.listType == 'numbered' ? 'none' : 'numbered'),
            ),

            // Line Spacing
            _buildLineSpacingDropdown(context),
            _buildDivider(),

            // Insert tools
            IconButton(
              icon: const Icon(Icons.table_chart, size: 20),
              tooltip: 'Insert Table',
              onPressed: onInsertTable,
            ),
            IconButton(
              icon: const Icon(Icons.horizontal_rule, size: 20),
              tooltip: 'Insert Divider',
              onPressed: onInsertDivider,
            ),
            IconButton(
              icon: const Icon(Icons.insert_page_break, size: 20),
              tooltip: 'Insert Page Break',
              onPressed: onInsertPageBreak,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 24,
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
        color: isActive ? Colors.blue.withOpacity(0.2) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: IconButton(
        icon: Icon(icon, size: 20, color: isActive ? const Color(0xFF185ABD) : null),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildHeadingDropdown(BuildContext context) {
    final Map<int, String> styles = {
      0: 'Normal',
      7: 'Title',
      8: 'Subtitle',
      1: 'Heading 1',
      2: 'Heading 2',
      3: 'Heading 3',
    };

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400, width: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: styles.containsKey(state.headingLevel) ? state.headingLevel : 0,
          isDense: true,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
          items: styles.entries.map((e) {
            return DropdownMenuItem<int>(
              value: e.key,
              child: Text(e.value),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) onHeadingLevelChanged?.call(val);
          },
        ),
      ),
    );
  }

  Widget _buildFontDropdown(BuildContext context) {
    final currentFont = kFontFamilies.contains(state.fontFamily)
        ? state.fontFamily
        : 'Calibri';

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400, width: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: currentFont,
          isDense: true,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
          items: kFontFamilies.map((f) {
            return DropdownMenuItem<String>(
              value: f,
              child: Text(f),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) onFontFamilyChanged?.call(val);
          },
        ),
      ),
    );
  }

  Widget _buildFontSizeDropdown(BuildContext context) {
    final currentSize = kFontSizes.contains(state.fontSizePt)
        ? state.fontSizePt
        : 11.0;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400, width: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<double>(
          value: currentSize,
          isDense: true,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
          items: kFontSizes.map((s) {
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

  Widget _buildLineSpacingDropdown(BuildContext context) {
    const spacings = [1.0, 1.15, 1.5, 2.0];
    final current = spacings.contains(state.lineSpacing) ? state.lineSpacing : 1.15;

    return Container(
      height: 32,
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
            fontSize: 13,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
          items: spacings.map((s) {
            return DropdownMenuItem<double>(
              value: s,
              child: Text('${s}x'),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) onLineSpacingChanged?.call(val);
          },
        ),
      ),
    );
  }

  Widget _buildColorPickerButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    Color? currentColor,
    bool isHighlight = false,
    ValueChanged<Color?>? onColorSelected,
  }) {
    final palette = isHighlight
        ? [
            Colors.yellow,
            Colors.greenAccent,
            Colors.cyanAccent,
            Colors.pinkAccent,
            Colors.orangeAccent,
            Colors.purpleAccent,
          ]
        : [
            Colors.black,
            Colors.white,
            const Color(0xFF185ABD), // Word Blue
            Colors.red,
            Colors.green,
            Colors.orange,
            Colors.purple,
            Colors.grey,
          ];

    return PopupMenuButton<Color?>(
      tooltip: tooltip,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          Container(
            height: 3,
            width: 16,
            color: currentColor ?? Colors.transparent,
          ),
        ],
      ),
      itemBuilder: (context) {
        return [
          PopupMenuItem<Color?>(
            value: null,
            child: const Text('None / Default'),
          ),
          ...palette.map((c) {
            return PopupMenuItem<Color?>(
              value: c,
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: c,
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('#${c.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}'),
                ],
              ),
            );
          }),
        ];
      },
      onSelected: onColorSelected,
    );
  }
}
