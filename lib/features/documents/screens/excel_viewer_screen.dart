import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/excel_edit_service.dart';

/// Plain, isolate-safe representation of a parsed workbook.
class _SheetData {
  final String name;
  final List<List<String>> rows; // stringified cell values
  _SheetData(this.name, this.rows);
}

/// Runs in a background isolate via compute() — pure, no Flutter refs.
List<_SheetData> _parseXlsx(Uint8List bytes) {
  final excel = Excel.decodeBytes(bytes);
  final out = <_SheetData>[];
  for (final name in excel.tables.keys) {
    final sheet = excel[name];
    final rows = <List<String>>[];
    for (final row in sheet.rows) {
      rows.add(row.map((c) => c?.value?.toString() ?? '').toList());
    }
    out.add(_SheetData(name, rows));
  }
  return out;
}

class ExcelViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  const ExcelViewerScreen({super.key, required this.filePath, required this.fileName});

  @override
  State<ExcelViewerScreen> createState() => _ExcelViewerScreenState();
}

class _ExcelViewerScreenState extends State<ExcelViewerScreen> {
  bool _loading = true;
  String? _error;
  List<_SheetData> _sheets = const [];
  final Map<String, String> _dirty = {}; // sheet!r,c -> newValue

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final sheets = await compute(_parseXlsx, bytes); // off UI isolate (invariant 7)
      if (!mounted) return;
      setState(() { _sheets = sheets; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = ''; _loading = false; });
    }
  }

  int _maxCols(_SheetData s) =>
      s.rows.fold(0, (m, r) => r.length > m ? r.length : m);

  Future<void> _checkEditingNotice() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool('office_editing_notice_shown') ?? false;
    if (!shown && mounted) {
      await prefs.setBool('office_editing_notice_shown', true);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.info_outline, size: 36),
          title: const Text('Office Document Editing'),
          content: const Text(
            'In-app editing creates a safe copy and preserves cell values. Complex features (charts, macros, embedded drawings) may not be retained. Your original file remains untouched.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _saveCopy() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Saving copy with edits…')));
    try {
      final result = await ExcelEditService().saveCopyWithEdits(
        widget.filePath,
        _dirty,
      );
      final savedName = result.savedPath.split(Platform.pathSeparator).last;
      if (result.verified) {
        if (result.notes.isNotEmpty && mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Save Notice'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your edits were verified and saved to a copy. Note:'),
                  const SizedBox(height: 8),
                  for (final note in result.notes)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                          const SizedBox(width: 6),
                          Expanded(child: Text(note, style: const TextStyle(fontSize: 13))),
                        ],
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          );
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved a copy: $savedName'),
            action: SnackBarAction(
              label: 'Replace Original',
              onPressed: () => _confirmReplaceOriginal(result.savedPath),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        setState(() {
          _dirty.clear();
        });
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved a copy ($savedName) but verification failed. Original is untouched.'),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _confirmReplaceOriginal(String copyPath) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace Original File?'),
        content: const Text(
          'This will overwrite your original file with the edited copy. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Replace'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await File(copyPath).copy(widget.filePath);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Original file updated successfully')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Replace failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _sheets;
    return DefaultTabController(
      length: tabs.isEmpty ? 1 : tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Save a copy',
              icon: const Icon(Icons.save_outlined),
              onPressed: _dirty.isNotEmpty ? _saveCopy : null,
            ),
            IconButton(
              tooltip: 'Open with another app',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => OpenFilex.open(widget.filePath), // invariant 8
            ),
          ],
          bottom: (tabs.length > 1)
              ? TabBar(isScrollable: true, tabs: [for (final s in tabs) Tab(text: s.name)])
              : null,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorFallback(path: widget.filePath, error: _error!)
                : TabBarView(children: [for (final s in tabs) _grid(s)]),
      ),
    );
  }

  Widget _grid(_SheetData s) {
    final cols = _maxCols(s);
    final columns = [
      for (var c = 0; c < cols; c++)
        PlutoColumn(
          title: _colLabel(c),
          field: 'c$c',
          type: PlutoColumnType.text(),
          readOnly: false, // Editable in Part B
        ),
    ];
    final rows = [
      for (final r in s.rows)
        PlutoRow(cells: {
          for (var c = 0; c < cols; c++)
            'c$c': PlutoCell(value: c < r.length ? r[c] : ''),
        }),
    ];
    return PlutoGrid(
      columns: columns,
      rows: rows,
      onChanged: (PlutoGridOnChangedEvent e) {
        _dirty['${s.name}!${e.rowIdx},${e.column.field}'] = e.value?.toString() ?? '';
        _checkEditingNotice();
        setState(() {});
      },
    );
  }

  static String _colLabel(int i) {
    var n = i; final sb = StringBuffer();
    do { sb.write(String.fromCharCode(65 + n % 26)); n = n ~/ 26 - 1; } while (n >= 0);
    return sb.toString().split('').reversed.join();
  }
}

class _ErrorFallback extends StatelessWidget {
  final String path; final String error;
  const _ErrorFallback({required this.path, required this.error});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, size: 48),
      const SizedBox(height: 12),
      const Text("Couldn't open this file in-app."),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: () => OpenFilex.open(path),
        icon: const Icon(Icons.open_in_new), label: const Text('Open with another app')),
    ]),
  );
}
