import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'dart:io';
import '../../../services/pdf_tools_service.dart';
import '../widgets/reorder_pages_dialog.dart';
import '../widgets/split_pdf_dialog.dart';
import '../widgets/password_selection_dialog.dart';
import 'package:file_picker/file_picker.dart';
import '../../settings/services/settings_service.dart';
import '../../common/utils/file_conflict_resolver.dart';
import 'package:path/path.dart' as path;

/// PDF Viewer Screen - displays PDF files with zoom and scroll
class PdfViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  final String? password;
  final VoidCallback? onPasswordRequired;
  final VoidCallback? onSuccess;

  const PdfViewerScreen({
    super.key,
    required this.filePath,
    required this.fileName,
    this.password,
    this.onPasswordRequired,
    this.onSuccess,
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final GlobalKey<SfPdfViewerState> _pdfViewerKey = GlobalKey();
  bool _hasCalledSuccess = false;
  bool _hasCalledPasswordRequired = false;
  int _pageCount = 0;

  @override
  Widget build(BuildContext context) {
    // Check if file exists
    final file = File(widget.filePath);
    if (!file.existsSync()) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Error'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.red,
              ),
              const SizedBox(height: 16),
              const Text(
                'File not found',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                widget.fileName,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'remove_password') {
                await _handleRemovePassword(context);
              } else if (value == 'reorder') {
                await _handleReorder(context);
              } else if (value == 'split') {
                await _handleSplit(context);
              } else if (value == 'merge') {
                await _handleMerge(context);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'split',
                child: Row(
                  children: [
                    Icon(Icons.call_split),
                    SizedBox(width: 8),
                    Text('Split PDF'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'merge',
                child: Row(
                  children: [
                    Icon(Icons.merge),
                    SizedBox(width: 8),
                    Text('Merge PDF'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'reorder',
                child: Row(
                  children: [
                    Icon(Icons.sort),
                    SizedBox(width: 8),
                    Text('Reorder Pages'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'remove_password',
                child: Row(
                  children: [
                    Icon(Icons.lock_open),
                    SizedBox(width: 8),
                    Text('Remove Password'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SfPdfViewer.file(
        file,
        key: _pdfViewerKey,
        password: widget.password ?? '',
        canShowScrollHead: true,
        canShowScrollStatus: true,
        canShowPaginationDialog: true,
        enableDoubleTapZooming: true,
        canShowPasswordDialog: false, // Disable Syncfusion's password dialog
        onDocumentLoaded: (details) {
          setState(() {
            _pageCount = details.document.pages.count;
          });
          // PDF loaded successfully
          if (!_hasCalledSuccess && widget.onSuccess != null) {
            _hasCalledSuccess = true;
            widget.onSuccess!();
          }
        },
        onDocumentLoadFailed: (details) {
          // Check if password error
          final desc = details.description.toLowerCase();
          final err = details.error.toLowerCase();
          if (desc.contains('password') || err.contains('password') ||
              desc.contains('encrypted') || err.contains('encrypted')) {
            // Password required - trigger callback
            if (!_hasCalledPasswordRequired && widget.onPasswordRequired != null) {
              _hasCalledPasswordRequired = true;
              widget.onPasswordRequired!();
            } else if (widget.onPasswordRequired == null) {
              // No callback set - just go back
              Navigator.pop(context);
            }
          }
        },
      ),
    );
  }

  Future<void> _handleRemovePassword(BuildContext context) async {
    final tools = PdfToolsService();
    
    // Show confirmation
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Password'),
        content: const Text(
          'This will decrypt the current file using the session password and save it as a new file (original_unlocked.pdf).\n\nThe original file will remain unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final exportPath = SettingsService().exportPath;
      final dir = exportPath ?? path.dirname(widget.filePath);
      final filename = path.basenameWithoutExtension(widget.filePath);
      final ext = path.extension(widget.filePath);
      final defaultPath = path.join(dir, '${filename}_unlocked$ext');

      final savePath = await FileConflictResolver.resolve(
        context: context,
        filePath: defaultPath,
      );

      if (savePath == null) return; // Users cancelled

      // Show loading
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (c) => const Center(child: CircularProgressIndicator()),
        );
      }
      
      final newPath = await tools.removePassword(
        filePath: widget.filePath,
        password: widget.password ?? '',
        savePath: savePath,
      );
      
      // Close loading
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to: ${newPath.split(Platform.pathSeparator).last}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      // Close loading
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleReorder(BuildContext context) async {
    if (_pageCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wait for document to load...')),
      );
      return;
    }

    final newOrder = await showDialog<List<int>>(
      context: context,
      builder: (context) => ReorderPagesDialog(pageCount: _pageCount),
    );

    if (newOrder == null || !mounted) return;

    final tools = PdfToolsService();
    try {
      final exportPath = SettingsService().exportPath;
      final dir = exportPath ?? path.dirname(widget.filePath);
      final filename = path.basenameWithoutExtension(widget.filePath);
      final ext = path.extension(widget.filePath);
      final defaultPath = path.join(dir, '${filename}_reordered$ext');

      final savePath = await FileConflictResolver.resolve(
        context: context,
        filePath: defaultPath,
      );

      if (savePath == null) return; // User cancelled

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (c) => const Center(child: CircularProgressIndicator()),
        );
      }
      
      final newPath = await tools.reorderPages(
        filePath: widget.filePath,
        password: widget.password ?? '',
        pageOrder: newOrder,
        savePath: savePath,
      );
      
      if (mounted) {
        Navigator.pop(context); // Pop loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to: ${newPath.split(Platform.pathSeparator).last}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleSplit(BuildContext context) async {
    if (_pageCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wait for document to load...')),
      );
      return;
    }

    final pages = await showDialog<List<int>>(
      context: context,
      builder: (context) => SplitPdfDialog(pageCount: _pageCount),
    );

    if (pages == null || !mounted) return;

    final tools = PdfToolsService();
    try {
      final exportPath = SettingsService().exportPath;
      final dir = exportPath ?? path.dirname(widget.filePath);
      final filename = path.basenameWithoutExtension(widget.filePath);
      final ext = path.extension(widget.filePath);
      final suffix = pages.length > 2 ? '${pages.first+1}-${pages.last+1}' : 'split';
      final defaultPath = path.join(dir, '${filename}_split_$suffix$ext');

      final savePath = await FileConflictResolver.resolve(
        context: context,
        filePath: defaultPath,
      );

      if (savePath == null) return;

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (c) => const Center(child: CircularProgressIndicator()),
        );
      }
      
      final newPath = await tools.splitPdf(
        filePath: widget.filePath,
        password: widget.password ?? '',
        pageIndices: pages,
        savePath: savePath,
      );
      
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to: ${newPath.split(Platform.pathSeparator).last}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleMerge(BuildContext context) async {
    // Pick file
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result == null || result.files.single.path == null) return;
    final otherPath = result.files.single.path!;

    if (mounted) await _performMerge(context, otherPath, '');
  }

  Future<void> _performMerge(BuildContext context, String otherPath, String otherPwd) async {
    final tools = PdfToolsService();
    try {
      final exportPath = SettingsService().exportPath;
      final dir = exportPath ?? path.dirname(widget.filePath);
      final filename = path.basenameWithoutExtension(widget.filePath);
      final ext = path.extension(widget.filePath);
      final defaultPath = path.join(dir, '${filename}_merged$ext');

      final savePath = await FileConflictResolver.resolve(
        context: context,
        filePath: defaultPath,
      );

      if (savePath == null) return;

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (c) => const Center(child: CircularProgressIndicator()),
        );
      }
      
      final newPath = await tools.mergePdf(
        sourcePath: widget.filePath,
        sourcePassword: widget.password ?? '',
        otherPath: otherPath,
        otherPassword: otherPwd,
        savePath: savePath,
      );
      
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to: ${newPath.split(Platform.pathSeparator).last}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // Pop loading

      // Check if password error
      final err = e.toString().toLowerCase();
      if (err.contains('password') || err.contains('encrypted') || err.contains('crypt')) {
        // Prompt for password
        if (!mounted) return;
        final pwd = await showDialog<String>(
          context: context,
          builder: (context) => const PasswordSelectionDialog(),
        );
        
        if (pwd != null && mounted) {
           // Recursive retry with password
           await _performMerge(context, otherPath, pwd);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }
}
