import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'package:path/path.dart' as path;
import '../../../models/document_item_model.dart';
import '../../../models/word_document_model.dart';
import '../../../services/document_service.dart';
import '../../../services/word_edit_service.dart';
import '../../../services/word_to_pdf_service.dart';
import '../../common/utils/file_conflict_resolver.dart';
import '../services/office_open_router.dart';
import '../widgets/duplicate_files_dialog.dart';
import '../widgets/folder_selection_dialog.dart';
import '../widgets/word_page_canvas.dart';
import '../widgets/word_ribbon_toolbar.dart';
import 'file_info_screen.dart';
import 'file_system_browser.dart';

/// Unified Microsoft Word & Google Docs Workspace
class WordViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  final bool initialEditMode;

  const WordViewerScreen({
    super.key,
    required this.filePath,
    required this.fileName,
    this.initialEditMode = false,
  });

  @override
  State<WordViewerScreen> createState() => _WordViewerScreenState();
}

class _WordViewerScreenState extends State<WordViewerScreen> {
  final WordEditService _editService = WordEditService();
  final GlobalKey<WordPageCanvasState> _canvasKey = GlobalKey<WordPageCanvasState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  WordDocumentModel? _document;
  bool _isLoading = true;
  String? _error;
  bool _isDirty = false;
  late bool _isEditMode;
  bool _isReflowMode = false;
  double _zoomScale = 1.0;

  // Formatting state
  WordFormattingState _formatState = const WordFormattingState();

  // Find & Replace
  bool _showFindReplace = false;
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _isEditMode = widget.initialEditMode;
    _loadDocument();
  }

  @override
  void dispose() {
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final targetPath = widget.filePath;
      final doc = await _editService.loadRichDocument(targetPath);
      if (!mounted) return;
      setState(() {
        _document = doc;
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
    if (_document == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(overwrite ? 'Saving document…' : 'Saving a copy…')),
    );

    try {
      final res = await _editService.saveRichDocument(
        sourcePath: widget.filePath,
        document: _document!,
        overwriteOriginal: overwrite,
      );

      final name = res.savedPath.split(Platform.pathSeparator).last;
      messenger.showSnackBar(
        SnackBar(
          content: Text(overwrite ? 'Document saved.' : 'Saved copy: $name'),
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

  Future<void> _exportToPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Exporting to PDF…')));
    try {
      final pdfPath = await WordToPdfService().convertDocxToPdf(widget.filePath);
      final pdfName = pdfPath.split(Platform.pathSeparator).last;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Exported to PDF: $pdfName'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () {
              if (mounted) {
                openDocument(context, pdfPath);
              }
            },
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

  void _shareDocument() {
    Share.shareXFiles([XFile(widget.filePath)], text: widget.fileName);
  }

  void _handleFind() {
    setState(() {
      _showFindReplace = !_showFindReplace;
      if (!_showFindReplace) {
        _searchQuery = '';
        _findController.clear();
      }
    });
  }

  void _executeReplace() {
    final find = _findController.text;
    final replace = _replaceController.text;
    if (find.isEmpty || _document == null) return;

    bool replacedAny = false;
    for (final b in _document!.blocks) {
      if (b is WordParagraphBlock) {
        for (final r in b.runs) {
          if (r.text.contains(find)) {
            r.text = r.text.replaceAll(find, replace);
            replacedAny = true;
          }
        }
      }
    }

    if (replacedAny) {
      setState(() {
        _isDirty = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Replaced occurrences.')),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildOutlineDrawer(context),
      appBar: AppBar(
        backgroundColor: const Color(0xFF185ABD), // Word Blue
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
          // Viewing / Editing pill toggle
          InkWell(
            onTap: () => setState(() => _isEditMode = !_isEditMode),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _isEditMode ? const Color(0xFF0F4A9E) : Colors.white24,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white38, width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isEditMode ? Icons.edit : Icons.visibility,
                    size: 13,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isEditMode ? 'Editing' : 'Viewing',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Document Outline',
            icon: const Icon(Icons.list_alt),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          IconButton(
            tooltip: 'Find & Replace',
            icon: const Icon(Icons.search),
            onPressed: _handleFind,
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
              else if (val == 'pdf') _exportToPdf();
              else if (val == 'share') _shareDocument();
              else if (val == 'open_external') OpenFilex.open(widget.filePath);
            },
            itemBuilder: (ctx) {
              final iconColor = isDark ? Colors.white70 : const Color(0xFF424242);
              final textColor = isDark ? Colors.white : const Color(0xFF212121);
              return [
                if (_isEditMode) ...[
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
                      Text('Save Copy', style: TextStyle(color: textColor)),
                    ]),
                  ),
                  const PopupMenuDivider(),
                ],
                PopupMenuItem(
                  value: 'file_info',
                  child: Row(children: [
                    Icon(Icons.info_outline, color: iconColor),
                    const SizedBox(width: 8),
                    Text('File info', style: TextStyle(color: textColor)),
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
                  value: 'pdf',
                  child: Row(children: [
                    Icon(Icons.picture_as_pdf, color: iconColor),
                    const SizedBox(width: 8),
                    Text('Export to PDF', style: TextStyle(color: textColor)),
                  ]),
                ),
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
                        Text('Error opening Word document:\n$_error', textAlign: TextAlign.center),
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
                    // Find & Replace slide-down banner
                    if (_showFindReplace) _buildFindReplaceBar(isDark),

                    // Formatting Ribbon (shown when in edit mode)
                    if (_isEditMode)
                      WordRibbonToolbar(
                        state: _formatState,
                        onFontFamilyChanged: (f) {
                          _canvasKey.currentState?.applyFormattingToActiveSelection(fontFamily: f);
                          setState(() => _formatState = _formatState.copyWith(fontFamily: f));
                        },
                        onFontSizeChanged: (sz) {
                          _canvasKey.currentState?.applyFormattingToActiveSelection(fontSizePt: sz);
                          setState(() => _formatState = _formatState.copyWith(fontSizePt: sz));
                        },
                        onToggleBold: () {
                          final newVal = !_formatState.isBold;
                          _canvasKey.currentState?.applyFormattingToActiveSelection(bold: newVal);
                          setState(() => _formatState = _formatState.copyWith(isBold: newVal));
                        },
                        onToggleItalic: () {
                          final newVal = !_formatState.isItalic;
                          _canvasKey.currentState?.applyFormattingToActiveSelection(italic: newVal);
                          setState(() => _formatState = _formatState.copyWith(isItalic: newVal));
                        },
                        onToggleUnderline: () {
                          final newVal = !_formatState.isUnderline;
                          _canvasKey.currentState?.applyFormattingToActiveSelection(underline: newVal);
                          setState(() => _formatState = _formatState.copyWith(isUnderline: newVal));
                        },
                        onToggleStrikethrough: () {
                          final newVal = !_formatState.isStrikethrough;
                          _canvasKey.currentState?.applyFormattingToActiveSelection(strikethrough: newVal);
                          setState(() => _formatState = _formatState.copyWith(isStrikethrough: newVal));
                        },
                        onTextColorChanged: (c) {
                          _canvasKey.currentState?.applyFormattingToActiveSelection(textColor: c);
                          setState(() => _formatState = _formatState.copyWith(textColor: c));
                        },
                        onHighlightColorChanged: (c) {
                          _canvasKey.currentState?.applyFormattingToActiveSelection(highlightColor: c);
                          setState(() => _formatState = _formatState.copyWith(highlightColor: c));
                        },
                        onAlignmentChanged: (a) {
                          _canvasKey.currentState?.setAlignmentOnActiveBlock(a);
                          setState(() => _formatState = _formatState.copyWith(alignment: a));
                        },
                        onHeadingLevelChanged: (h) {
                          _canvasKey.currentState?.setHeadingLevelOnActiveBlock(h);
                          setState(() => _formatState = _formatState.copyWith(headingLevel: h));
                        },
                        onListTypeChanged: (lt) {
                          _canvasKey.currentState?.setListTypeOnActiveBlock(lt);
                          setState(() => _formatState = _formatState.copyWith(listType: lt));
                        },
                        onLineSpacingChanged: (ls) {
                          _canvasKey.currentState?.setLineSpacingOnActiveBlock(ls);
                          setState(() => _formatState = _formatState.copyWith(lineSpacing: ls));
                        },
                        onInsertTable: () {
                          _showInsertTableDialog(context);
                        },
                        onInsertPageBreak: () {
                          _canvasKey.currentState?.insertPageBreak();
                        },
                        onInsertDivider: () {
                          _canvasKey.currentState?.insertDivider();
                        },
                      ),

                    // Paper Canvas
                    Expanded(
                      child: WordPageCanvas(
                        key: _canvasKey,
                        document: _document!,
                        isEditMode: _isEditMode,
                        isReflowMode: _isReflowMode,
                        zoomScale: _zoomScale,
                        searchQuery: _searchQuery,
                        onContentChanged: () {
                          setState(() => _isDirty = true);
                        },
                        onSelectionFormatChanged: (state) {
                          setState(() => _formatState = state);
                        },
                      ),
                    ),

                    // Bottom Status Bar
                    _buildBottomStatusBar(isDark),
                  ],
                ),
    );
  }

  Widget _buildFindReplaceBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: isDark ? const Color(0xFF2C2D30) : const Color(0xFFE9EEF4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _findController,
              decoration: InputDecoration(
                hintText: 'Find…',
                isDense: true,
                filled: true,
                fillColor: isDark ? const Color(0xFF383A3C) : Colors.white,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              onChanged: (val) {
                setState(() => _searchQuery = val);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _replaceController,
              decoration: InputDecoration(
                hintText: 'Replace with…',
                isDense: true,
                filled: true,
                fillColor: isDark ? const Color(0xFF383A3C) : Colors.white,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF185ABD),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: _executeReplace,
            child: const Text('Replace', style: TextStyle(color: Colors.white, fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () {
              setState(() {
                _showFindReplace = false;
                _searchQuery = '';
                _findController.clear();
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomStatusBar(bool isDark) {
    final words = _document?.wordCount ?? 0;
    final chars = _document?.characterCount ?? 0;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF202124) : const Color(0xFFF1F3F4),
        border: Border(top: BorderSide(color: Colors.grey.withOpacity(0.3))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Text('Words: $words', style: const TextStyle(fontSize: 11)),
              const SizedBox(width: 12),
              Text('Characters: $chars', style: const TextStyle(fontSize: 11)),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  _isReflowMode ? Icons.view_headline : Icons.layers,
                  size: 16,
                ),
                tooltip: _isReflowMode ? 'Switch to Print Layout' : 'Switch to Reflow',
                onPressed: () => setState(() => _isReflowMode = !_isReflowMode),
              ),
              IconButton(
                icon: const Icon(Icons.remove, size: 14),
                tooltip: 'Zoom Out',
                onPressed: () {
                  if (_zoomScale > 0.6) setState(() => _zoomScale -= 0.1);
                },
              ),
              Text('${(_zoomScale * 100).toInt()}%', style: const TextStyle(fontSize: 11)),
              IconButton(
                icon: const Icon(Icons.add, size: 14),
                tooltip: 'Zoom In',
                onPressed: () {
                  if (_zoomScale < 2.0) setState(() => _zoomScale += 0.1);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOutlineDrawer(BuildContext context) {
    final headings = _document?.headings ?? [];
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF185ABD),
              width: double.infinity,
              child: const Text(
                'Document Outline',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            if (headings.isEmpty)
              const Expanded(
                child: Center(
                  child: Text('No headings found.\nAdd Heading styles to generate outline.',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: headings.length,
                  itemBuilder: (ctx, i) {
                    final h = headings[i];
                    return ListTile(
                      contentPadding: EdgeInsets.only(left: 16.0 * (h.level == 7 ? 1 : h.level)),
                      title: Text(
                        h.title,
                        style: TextStyle(
                          fontWeight: h.level <= 2 ? FontWeight.bold : FontWeight.normal,
                          fontSize: h.level == 1 ? 15 : 13,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(context);
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

  void _showInsertTableDialog(BuildContext context) {
    int rows = 3;
    int cols = 3;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Insert Table'),
        content: StatefulBuilder(
          builder: (c, setDState) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Rows'),
                  DropdownButton<int>(
                    value: rows,
                    items: [1, 2, 3, 4, 5, 6, 8, 10].map((n) {
                      return DropdownMenuItem(value: n, child: Text('$n'));
                    }).toList(),
                    onChanged: (v) => setDState(() => rows = v ?? 3),
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Columns'),
                  DropdownButton<int>(
                    value: cols,
                    items: [1, 2, 3, 4, 5, 6, 8].map((n) {
                      return DropdownMenuItem(value: n, child: Text('$n'));
                    }).toList(),
                    onChanged: (v) => setDState(() => cols = v ?? 3),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _canvasKey.currentState?.insertTable(rows, cols);
            },
            child: const Text('Insert'),
          ),
        ],
      ),
    );
  }
}
