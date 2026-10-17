import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../../../models/document_item_model.dart';
import '../../../models/excel_workbook_model.dart';
import '../../../services/document_service.dart';
import '../../../services/excel_edit_service.dart';
import '../../../services/excel_formula_engine.dart';
import '../../common/utils/file_conflict_resolver.dart';
import '../../settings/services/settings_service.dart';
import '../widgets/duplicate_files_dialog.dart';
import '../widgets/excel_formula_bar.dart';
import '../widgets/excel_grid_canvas.dart';
import '../widgets/excel_ribbon_toolbar.dart';
import '../widgets/folder_selection_dialog.dart';
import 'file_info_screen.dart';
import 'file_system_browser.dart';

/// Unified Microsoft Excel / Google Sheets Workspace
class ExcelViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;

  const ExcelViewerScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  @override
  State<ExcelViewerScreen> createState() => _ExcelViewerScreenState();
}

class _ExcelViewerScreenState extends State<ExcelViewerScreen> {
  final ExcelEditService _editService = ExcelEditService();
  final ExcelGridController _gridController = ExcelGridController();

  ExcelWorkbookModel? _workbook;
  bool _isLoading = true;
  String? _error;
  bool _isDirty = false;

  // Active Selection State
  ExcelSelectionInfo _selectionInfo = const ExcelSelectionInfo(activeRow: 0, activeCol: 0);
  ExcelCellStyle _activeStyle = const ExcelCellStyle();
  double _zoomScale = 1.0;

  // Find in Sheet
  bool _showFind = false;
  final TextEditingController _findController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadWorkbook();
  }

  @override
  void dispose() {
    _findController.dispose();
    super.dispose();
  }

  Future<void> _loadWorkbook() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final targetPath = widget.filePath;
      final wb = await _editService.loadRichWorkbook(targetPath);
      if (!mounted) return;
      final firstCell = wb.activeSheet.getCell(0, 0);
      setState(() {
        _workbook = wb;
        _activeStyle = firstCell?.style ?? const ExcelCellStyle();
        _selectionInfo = ExcelSelectionInfo(
          activeRow: 0,
          activeCol: 0,
          activeCellData: firstCell,
        );
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _isLoading = false;
      });
    }
  }

  Future<void> _save({bool overwrite = false}) async {
    if (_workbook == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(overwrite ? 'Saving workbook…' : 'Saving a copy…')),
    );

    try {
      final res = await _editService.saveRichWorkbook(
        sourcePath: widget.filePath,
        workbook: _workbook!,
        overwriteOriginal: overwrite,
      );

      final name = res.savedPath.split(Platform.pathSeparator).last;
      messenger.showSnackBar(
        SnackBar(
          content: Text(overwrite ? 'Workbook saved.' : 'Saved copy: $name'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );

      setState(() {
        _isDirty = false;
      });
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<String> _resolveWritableExportDir() async {
    try {
      final preferred = SettingsService().exportPath;
      final dir = Directory(preferred);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final testFile = File(path.join(dir.path, '.test_write_${DateTime.now().millisecondsSinceEpoch}'));
      await testFile.writeAsString('test', flush: true);
      await testFile.delete();
      return dir.path;
    } catch (_) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final fallbackDir = Directory(path.join(appDocDir.path, 'PDF Manager'));
      if (!await fallbackDir.exists()) {
        await fallbackDir.create(recursive: true);
      }
      return fallbackDir.path;
    }
  }

  String _uniquePath(String targetPath) {
    if (!File(targetPath).existsSync()) return targetPath;
    final dir = path.dirname(targetPath);
    final name = path.basenameWithoutExtension(targetPath);
    final ext = path.extension(targetPath);
    var i = 2;
    while (File(path.join(dir, '$name ($i)$ext')).existsSync()) {
      i++;
    }
    return path.join(dir, '$name ($i)$ext');
  }

  Future<void> _exportActiveSheetToCsv() async {
    if (_workbook == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Exporting sheet to CSV…')));

    try {
      final dir = await _resolveWritableExportDir();
      final base = path.basenameWithoutExtension(widget.filePath);
      final safeSheetName = _workbook!.activeSheet.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final targetPath = _uniquePath(path.join(dir, '$base ($safeSheetName).csv'));
      
      final exportedPath = await _editService.exportSheetToCsv(_workbook!.activeSheet, targetPath);
      final name = path.basename(exportedPath);

      // Register in Document Library so it shows up on Documents screen
      await DocumentService().addFile(
        exportedPath,
        isNew: true,
        isImportedFile: true,
      );

      messenger.showSnackBar(
        SnackBar(
          content: Text('Exported CSV: $name'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => OpenFilex.open(exportedPath),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _handleFileInfo(BuildContext context) async {
    final file = File(widget.filePath);
    if (!file.existsSync()) return;
    final stat = file.statSync();
    final existingId = DocumentService().findFileIdByPath(widget.filePath);

    final item = DocumentItem(
      id: existingId ?? 'temp_${DateTime.now().millisecondsSinceEpoch}',
      name: widget.fileName,
      type: DocumentItemType.file,
      sourcePath: widget.filePath,
      size: stat.size,
      createdAt: stat.changed,
      modifiedAt: stat.modified,
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FileInfoScreen(file: item)),
    );
  }

  Future<void> _handleSaveFile(BuildContext context) async {
    if (_isDirty) {
      await _save(overwrite: true);
    }

    if (!mounted) return;
    final theme = Theme.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
               padding: const EdgeInsets.all(16),
               child: Text('Save File', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.library_books, color: theme.colorScheme.onPrimaryContainer),
              ),
              title: const Text('Save to App Library'),
              subtitle: const Text('Organize in App Folders & Sync'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () => Navigator.pop(c, 'library'),
            ),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.phone_android, color: theme.colorScheme.onSecondaryContainer),
              ),
              title: const Text('Save to Device Storage'),
              subtitle: const Text('Pick a specific folder on device'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () => Navigator.pop(c, 'device'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (choice == 'library') {
      if (context.mounted) await _saveToLibrary(context);
    } else if (choice == 'device') {
      if (context.mounted) await _saveToDevice(context);
    }
  }

  Future<void> _saveToLibrary(BuildContext context) async {
    final docService = DocumentService();
    final duplicates = await docService.checkForDuplicates([widget.filePath]);
    if (duplicates.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => DuplicateFilesDialog(duplicates: duplicates),
      );
      if (proceed != true) return;
    }

    if (!context.mounted) return;
    final folderId = await showDialog<String>(
      context: context,
      builder: (context) => FolderSelectionDialog(
        docService: docService,
        title: 'Save to Document Library',
        subtitle: 'Select destination folder',
      ),
    );
    if (folderId == null) return;
    final targetFolderId = folderId == '__ROOT__' ? null : folderId;

    try {
      if (mounted) showDialog(context: context, barrierDismissible: false, builder: (c) => const Center(child: CircularProgressIndicator()));

      final targetDir = await docService.getPhysicalPathForFolder(targetFolderId);
      if (!Directory(targetDir).existsSync()) {
        await Directory(targetDir).create(recursive: true);
      }

      final targetPath = path.join(targetDir, widget.fileName);
      if (!context.mounted) return;
      final resolvedPath = await FileConflictResolver.resolve(context: context, filePath: targetPath);
      if (resolvedPath == null) {
        if (mounted) Navigator.pop(context);
        return;
      }

      await File(widget.filePath).copy(resolvedPath);
      await docService.addFile(resolvedPath, folderId: targetFolderId, isNew: true, isImportedFile: true);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to ${targetFolderId == null ? 'Root' : 'Folder'}'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        if (Navigator.canPop(context)) Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _saveToDevice(BuildContext context) async {
    final result = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (context) => const FileSystemBrowser(
          allowFolderSelection: true,
          allowMultiple: false,
          initialPath: '/storage/emulated/0',
        ),
      ),
    );
    if (result == null || result.isEmpty) return;
    final targetFolder = result.first;

    try {
      final targetPath = path.join(targetFolder, widget.fileName);
      if (!context.mounted) return;
      final resolvedPath = await FileConflictResolver.resolve(context: context, filePath: targetPath);
      if (resolvedPath == null) return;

      await File(widget.filePath).copy(resolvedPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to: $resolvedPath'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _shareDocument() {
    Share.shareXFiles([XFile(widget.filePath)], text: widget.fileName);
  }

  // ---------------------------------------------------------------------------
  // Sheet Management
  // ---------------------------------------------------------------------------

  void _addNewSheet() {
    if (_workbook == null) return;
    int idx = _workbook!.sheets.length + 1;
    String name = 'Sheet$idx';
    while (_workbook!.getSheetByName(name) != null) {
      idx++;
      name = 'Sheet$idx';
    }
    setState(() {
      _workbook!.sheets.add(ExcelSheetModel(name: name));
      _workbook!.activeSheetIndex = _workbook!.sheets.length - 1;
      _selectionInfo = const ExcelSelectionInfo(activeRow: 0, activeCol: 0);
      _activeStyle = const ExcelCellStyle();
      _isDirty = true;
    });
  }

  void _renameSheet(int index) {
    if (_workbook == null || index >= _workbook!.sheets.length) return;
    final sheet = _workbook!.sheets[index];
    final ctrl = TextEditingController(text: sheet.name);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Sheet'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Sheet Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty) {
                setState(() {
                  sheet.name = newName;
                  _isDirty = true;
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _duplicateSheet(int index) {
    if (_workbook == null || index >= _workbook!.sheets.length) return;
    final source = _workbook!.sheets[index];
    final copyName = '${source.name} (Copy)';
    final newSheet = ExcelSheetModel(
      name: copyName,
      cells: Map.from(source.cells),
      columnWidths: Map.from(source.columnWidths),
      rowHeights: Map.from(source.rowHeights),
      mergedRanges: List.from(source.mergedRanges),
    );
    setState(() {
      _workbook!.sheets.insert(index + 1, newSheet);
      _workbook!.activeSheetIndex = index + 1;
      _selectionInfo = const ExcelSelectionInfo(activeRow: 0, activeCol: 0);
      _activeStyle = const ExcelCellStyle();
      _isDirty = true;
    });
  }

  void _deleteSheet(int index) {
    if (_workbook == null || _workbook!.sheets.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A workbook must have at least one worksheet.')),
      );
      return;
    }
    setState(() {
      _workbook!.sheets.removeAt(index);
      if (_workbook!.activeSheetIndex >= _workbook!.sheets.length) {
        _workbook!.activeSheetIndex = _workbook!.sheets.length - 1;
      }
      _selectionInfo = const ExcelSelectionInfo(activeRow: 0, activeCol: 0);
      _activeStyle = const ExcelCellStyle();
      _isDirty = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Function Picker Dialog
  // ---------------------------------------------------------------------------

  void _showFunctionPicker() {
    final functions = [
      {'name': 'SUM', 'desc': 'Adds all numbers in a range of cells'},
      {'name': 'AVERAGE', 'desc': 'Returns the average of numbers'},
      {'name': 'COUNT', 'desc': 'Counts cells containing numbers'},
      {'name': 'COUNTA', 'desc': 'Counts non-empty cells'},
      {'name': 'MIN', 'desc': 'Returns the smallest number'},
      {'name': 'MAX', 'desc': 'Returns the largest number'},
      {'name': 'IF', 'desc': 'Checks condition: IF(test, then, else)'},
      {'name': 'IFERROR', 'desc': 'Catches formula errors'},
      {'name': 'VLOOKUP', 'desc': 'Looks up value in leftmost column'},
      {'name': 'CONCAT', 'desc': 'Combines text from multiple ranges'},
      {'name': 'ROUND', 'desc': 'Rounds a number to specified digits'},
      {'name': 'TODAY', 'desc': 'Returns current date'},
    ];

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Insert Function',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: const Color(0xFF107C41),
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                itemCount: functions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (c, i) {
                  final fn = functions[i];
                  return ListTile(
                    leading: const Text('fx', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF107C41))),
                    title: Text(fn['name']!, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(fn['desc']!),
                    onTap: () {
                      Navigator.pop(ctx);
                      _gridController.updateActiveCellFormulaOrValue('=${fn['name']}()');
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Live Selection Stats Calculation
  // ---------------------------------------------------------------------------

  Map<String, String> _calculateSelectionStats() {
    if (_workbook == null || _selectionInfo.range == null || _selectionInfo.range!.cellCount <= 1) {
      return {};
    }

    final r = _selectionInfo.range!;
    final sheet = _workbook!.activeSheet;
    final nums = <double>[];
    int count = 0;

    for (int row = r.minRow; row <= r.maxRow; row++) {
      for (int col = r.minCol; col <= r.maxCol; col++) {
        final cell = sheet.getCell(row, col);
        if (cell != null && cell.evaluatedValue.trim().isNotEmpty) {
          count++;
          final num = double.tryParse(cell.evaluatedValue.replaceAll(RegExp(r'[$,₹%]'), '').trim());
          if (num != null) nums.add(num);
        }
      }
    }

    if (count == 0) return {};

    final stats = <String, String>{
      'Count': count.toString(),
    };

    if (nums.isNotEmpty) {
      final sum = nums.fold<double>(0.0, (acc, n) => acc + n);
      final avg = sum / nums.length;
      final min = nums.reduce(math.min);
      final max = nums.reduce(math.max);

      stats['Sum'] = sum == sum.roundToDouble() ? sum.toInt().toString() : sum.toStringAsFixed(2);
      stats['Average'] = avg == avg.roundToDouble() ? avg.toInt().toString() : avg.toStringAsFixed(2);
      stats['Min'] = min == min.roundToDouble() ? min.toInt().toString() : min.toStringAsFixed(2);
      stats['Max'] = max == max.roundToDouble() ? max.toInt().toString() : max.toStringAsFixed(2);
    }

    return stats;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF107C41), // Excel Green
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                widget.fileName.split('.').last.toUpperCase(),
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.fileName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  if (_isDirty)
                    const Text(
                      '• Unsaved changes',
                      style: TextStyle(fontSize: 10, color: Colors.amberAccent),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Find in Sheet',
            icon: const Icon(Icons.search),
            onPressed: () => setState(() => _showFind = !_showFind),
          ),
          IconButton(
            tooltip: _isDirty ? 'Save Changes' : 'Save to Folder',
            icon: Badge(
              isLabelVisible: _isDirty,
              backgroundColor: Colors.amberAccent,
              smallSize: 8,
              child: const Icon(Icons.save),
            ),
            onPressed: () {
              if (_isDirty) {
                _save(overwrite: true);
              } else {
                _handleSaveFile(context);
              }
            },
          ),
          PopupMenuButton<String>(
            color: isDark ? const Color(0xFF242526) : Colors.white,
            elevation: 6,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            icon: const Icon(Icons.more_vert),
            onSelected: (val) {
              if (val == 'save') _save(overwrite: true);
              else if (val == 'save_copy') _save(overwrite: false);
              else if (val == 'save_to_folder') _handleSaveFile(context);
              else if (val == 'file_info') _handleFileInfo(context);
              else if (val == 'export_csv') _exportActiveSheetToCsv();
              else if (val == 'share') _shareDocument();
              else if (val == 'open_external') OpenFilex.open(widget.filePath);
            },
            itemBuilder: (ctx) {
              final iconColor = isDark ? Colors.white70 : const Color(0xFF424242);
              final textColor = isDark ? Colors.white : const Color(0xFF212121);
              return [
                PopupMenuItem(
                  value: 'save',
                  child: Row(children: [
                    Icon(Icons.save, color: iconColor),
                    const SizedBox(width: 8),
                    Text('Save (Overwrite)', style: TextStyle(color: textColor)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'save_copy',
                  child: Row(children: [
                    Icon(Icons.file_copy, color: iconColor),
                    const SizedBox(width: 8),
                    Text('Save Copy (.xlsx)', style: TextStyle(color: textColor)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'save_to_folder',
                  child: Row(children: [
                    Icon(Icons.save_alt, color: iconColor),
                    const SizedBox(width: 8),
                    Text('Save to Folder', style: TextStyle(color: textColor)),
                  ]),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'file_info',
                  child: Row(children: [
                    Icon(Icons.info_outline, color: iconColor),
                    const SizedBox(width: 8),
                    Text('File info', style: TextStyle(color: textColor)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'export_csv',
                  child: Row(children: [
                    Icon(Icons.table_view, color: iconColor),
                    const SizedBox(width: 8),
                    Text('Export Active Sheet as .csv', style: TextStyle(color: textColor)),
                  ]),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'share',
                  child: Row(children: [
                    Icon(Icons.share, color: iconColor),
                    const SizedBox(width: 8),
                    Text('Share File', style: TextStyle(color: textColor)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'open_external',
                  child: Row(children: [
                    Icon(Icons.open_in_new, color: iconColor),
                    const SizedBox(width: 8),
                    Text('Open Externally', style: TextStyle(color: textColor)),
                  ]),
                ),
              ];
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: Colors.red),
                        const SizedBox(height: 12),
                        Text('Error opening Excel spreadsheet:\n$_error', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => OpenFilex.open(widget.filePath),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open with another app'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    // Find bar
                    if (_showFind) _buildFindBar(isDark),

                    // Formatting Ribbon
                    ExcelRibbonToolbar(
                      activeStyle: _activeStyle,
                      onToggleBold: () {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(bold: !cell.style.bold);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onToggleItalic: () {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(italic: !cell.style.italic);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onToggleUnderline: () {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(underline: !cell.style.underline);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onFontSizeChanged: (sz) {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(fontSize: sz);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onTextColorChanged: (c) {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(
                          textColorHex: c != null
                              ? '#${c.value.toRadixString(16).padLeft(8, '0').substring(2)}'
                              : null,
                        );
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onFillColorChanged: (c) {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(
                          fillColorHex: c != null
                              ? '#${c.value.toRadixString(16).padLeft(8, '0').substring(2)}'
                              : null,
                        );
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onAlignChanged: (a) {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(horizontalAlign: a);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onToggleWrap: () {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(wrapText: !cell.style.wrapText);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onNumberFormatChanged: (fmt) {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(numberFormat: fmt);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onIncreaseDecimals: () {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        cell.style = cell.style.copyWith(decimalPlaces: cell.style.decimalPlaces + 1);
                        setState(() {
                          _activeStyle = cell.style;
                          _isDirty = true;
                        });
                      },
                      onDecreaseDecimals: () {
                        final cell = _workbook!.activeSheet.getOrCreateCell(
                          _selectionInfo.activeRow,
                          _selectionInfo.activeCol,
                        );
                        if (cell.style.decimalPlaces > 0) {
                          cell.style = cell.style.copyWith(decimalPlaces: cell.style.decimalPlaces - 1);
                          setState(() {
                            _activeStyle = cell.style;
                            _isDirty = true;
                          });
                        }
                      },
                      onMergeCenter: () {
                        if (_selectionInfo.range != null && _selectionInfo.range!.cellCount > 1) {
                          setState(() {
                            _workbook!.activeSheet.mergedRanges.add(_selectionInfo.range!);
                            _isDirty = true;
                          });
                        }
                      },
                    ),

                    // Name Box & fx Formula Bar
                    ExcelFormulaBar(
                      activeCellCoordinate: _selectionInfo.displayCoordinate,
                      cellFormulaOrValue: _selectionInfo.activeCellData?.formula ??
                          _selectionInfo.activeCellData?.rawValue ??
                          '',
                      onNavigateToCell: (coord) {
                        _gridController.navigateToCell(coord);
                      },
                      onFormulaChanged: (val) {
                        _gridController.updateActiveCellFormulaOrValue(val);
                      },
                      onCommit: () {
                        if (_workbook != null) {
                          ExcelFormulaEngine().recalculateSheet(_workbook!.activeSheet, _workbook);
                        }
                        setState(() {
                          _isDirty = true;
                        });
                      },
                      onInsertFunction: _showFunctionPicker,
                    ),

                    // 2D Virtualized Spreadsheet Grid
                    Expanded(
                      child: ExcelGridCanvas(
                        key: ValueKey('sheet_${_workbook!.activeSheetIndex}_${_workbook!.activeSheet.name}'),
                        controller: _gridController,
                        sheet: _workbook!.activeSheet,
                        workbook: _workbook,
                        zoomScale: _zoomScale,
                        onZoomScaleChanged: (scale) {
                          if (mounted) setState(() => _zoomScale = scale);
                        },
                        onSelectionChanged: (info) {
                          setState(() {
                            _selectionInfo = info;
                            _activeStyle = info.activeCellData?.style ?? const ExcelCellStyle();
                          });
                        },
                        onCellModified: () {
                          // Recalculate dependent formulas
                          ExcelFormulaEngine().recalculateSheet(_workbook!.activeSheet, _workbook);
                          setState(() => _isDirty = true);
                        },
                      ),
                    ),

                    // Bottom Sheet Tabs & Live Aggregation Footer
                    _buildBottomFooter(isDark),
                  ],
                ),
    );
  }

  Widget _buildFindBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: isDark ? const Color(0xFF2C2D30) : const Color(0xFFE9EEF4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _findController,
              decoration: const InputDecoration(
                hintText: 'Find in sheet…',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              onSubmitted: (query) {
                if (query.isEmpty || _workbook == null) return;
                final sheet = _workbook!.activeSheet;
                for (final entry in sheet.cells.entries) {
                  if (entry.value.displayValue.toLowerCase().contains(query.toLowerCase())) {
                    final rc = keyToRowCol(entry.key);
                    if (rc != null) {
                      _gridController.navigateToCell(rowColToCellCoordinate(rc.$1, rc.$2));
                      break;
                    }
                  }
                }
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => setState(() => _showFind = false),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomFooter(bool isDark) {
    final stats = _calculateSelectionStats();

    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF202124) : const Color(0xFFF1F3F4),
        border: Border(top: BorderSide(color: Colors.grey.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          // Sheet Tabs
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            tooltip: 'Add Sheet',
            onPressed: _addNewSheet,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(_workbook!.sheets.length, (i) {
                  final sheet = _workbook!.sheets[i];
                  final isActive = _workbook!.activeSheetIndex == i;
                  return InkWell(
                    onTap: () {
                      setState(() {
                        _workbook!.activeSheetIndex = i;
                        _selectionInfo = const ExcelSelectionInfo(activeRow: 0, activeCol: 0);
                        _activeStyle = const ExcelCellStyle();
                      });
                    },
                    onLongPress: () {
                      _showSheetContextMenu(context, i);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: isActive
                            ? (isDark ? const Color(0xFF2D2E30) : Colors.white)
                            : Colors.transparent,
                        border: Border(
                          bottom: BorderSide(
                            color: isActive ? const Color(0xFF107C41) : Colors.transparent,
                            width: 3.0,
                          ),
                          right: BorderSide(color: Colors.grey.withOpacity(0.3), width: 0.5),
                        ),
                      ),
                      child: Text(
                        sheet.name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                          color: isActive ? const Color(0xFF107C41) : null,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),

          // Live Selection Status Bar (Sum, Avg, Count, Min, Max)
          if (stats.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: stats.entries.map((e) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '${e.key}: ${e.value}',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],

          // Zoom controls: [-] 100% [+]
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove, size: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  tooltip: 'Zoom Out',
                  onPressed: () => setState(() => _zoomScale = (_zoomScale / 1.15).clamp(0.4, 2.5)),
                ),
                GestureDetector(
                  onTap: () => setState(() => _zoomScale = 1.0),
                  child: Tooltip(
                    message: 'Tap to reset zoom (100%)',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        '${(_zoomScale * 100).toInt()}%',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  tooltip: 'Zoom In',
                  onPressed: () => setState(() => _zoomScale = (_zoomScale * 1.15).clamp(0.4, 2.5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showSheetContextMenu(BuildContext context, int index) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename Sheet'),
              onTap: () {
                Navigator.pop(ctx);
                _renameSheet(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Duplicate Sheet'),
              onTap: () {
                Navigator.pop(ctx);
                _duplicateSheet(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete Sheet', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteSheet(index);
              },
            ),
          ],
        ),
      ),
    );
  }
}
