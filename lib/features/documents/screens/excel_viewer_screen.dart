import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:excel_plus/excel_plus.dart';

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
          title: _colLabel(c), field: 'c',
          type: PlutoColumnType.text(), readOnly: true, // read-only in Part A
        ),
    ];
    final rows = [
      for (final r in s.rows)
        PlutoRow(cells: {
          for (var c = 0; c < cols; c++)
            'c': PlutoCell(value: c < r.length ? r[c] : ''),
        }),
    ];
    return PlutoGrid(columns: columns, rows: rows);
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
