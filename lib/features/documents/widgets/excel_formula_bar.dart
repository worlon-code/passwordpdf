import 'package:flutter/material.dart';

/// Name Box & fx Formula Bar for Microsoft Excel / Google Sheets
class ExcelFormulaBar extends StatefulWidget {
  final String activeCellCoordinate;
  final String cellFormulaOrValue;
  final ValueChanged<String>? onNavigateToCell;
  final ValueChanged<String>? onFormulaChanged;
  final VoidCallback? onCommit;
  final VoidCallback? onCancel;
  final VoidCallback? onInsertFunction;

  const ExcelFormulaBar({
    super.key,
    required this.activeCellCoordinate,
    required this.cellFormulaOrValue,
    this.onNavigateToCell,
    this.onFormulaChanged,
    this.onCommit,
    this.onCancel,
    this.onInsertFunction,
  });

  @override
  State<ExcelFormulaBar> createState() => _ExcelFormulaBarState();
}

class _ExcelFormulaBarState extends State<ExcelFormulaBar> {
  late TextEditingController _nameBoxController;
  late TextEditingController _formulaController;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _nameBoxController = TextEditingController(text: widget.activeCellCoordinate);
    _formulaController = TextEditingController(text: widget.cellFormulaOrValue);
  }

  @override
  void didUpdateWidget(covariant ExcelFormulaBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeCellCoordinate != oldWidget.activeCellCoordinate) {
      _nameBoxController.text = widget.activeCellCoordinate;
    }
    if (widget.cellFormulaOrValue != oldWidget.cellFormulaOrValue && !_isEditing) {
      _formulaController.text = widget.cellFormulaOrValue;
    }
  }

  @override
  void dispose() {
    _nameBoxController.dispose();
    _formulaController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF202124) : Colors.white;
    final borderColor = isDark ? Colors.white12 : Colors.black12;

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(color: borderColor, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          // 1. Name Box (A1 coordinate navigator)
          SizedBox(
            width: 88,
            child: TextField(
              controller: _nameBoxController,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: isDark ? const Color(0xFF2C2D30) : const Color(0xFFF1F3F4),
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: borderColor),
                ),
              ),
              onSubmitted: (val) {
                widget.onNavigateToCell?.call(val.toUpperCase().trim());
              },
            ),
          ),
          const SizedBox(width: 4),

          // 2. Commit & Cancel buttons when typing
          if (_isEditing) ...[
            IconButton(
              icon: const Icon(Icons.close, size: 16, color: Colors.red),
              tooltip: 'Cancel (Esc)',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: () {
                setState(() {
                  _isEditing = false;
                  _formulaController.text = widget.cellFormulaOrValue;
                });
                widget.onCancel?.call();
              },
            ),
            IconButton(
              icon: const Icon(Icons.check, size: 16, color: Colors.green),
              tooltip: 'Commit (Enter)',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: () {
                setState(() => _isEditing = false);
                widget.onCommit?.call();
              },
            ),
          ] else ...[
            // fx Function Picker Button
            InkWell(
              onTap: widget.onInsertFunction,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: const Text(
                  'fx',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Color(0xFF107C41), // Excel Green
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),

          // 3. Formula input text field
          Expanded(
            child: Container(
              height: 30,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2C2D30) : const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isDark ? Colors.white24 : Colors.grey.shade400,
                  width: 0.8,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              child: TextField(
                controller: _formulaController,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: 'Enter a value or =formula',
                ),
                onChanged: (val) {
                  if (!_isEditing) setState(() => _isEditing = true);
                  widget.onFormulaChanged?.call(val);
                },
                onSubmitted: (_) {
                  setState(() => _isEditing = false);
                  widget.onCommit?.call();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
