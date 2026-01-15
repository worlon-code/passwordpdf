import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'dart:io';
import '../../../services/pdf_tools_service.dart';
import '../../../services/pdf_password_service.dart';
import '../widgets/reorder_pages_dialog.dart';
import '../widgets/split_pdf_dialog.dart';
import '../widgets/password_selection_dialog.dart';
import 'file_system_browser.dart';
import '../../settings/services/settings_service.dart';
import '../../common/utils/file_conflict_resolver.dart';
import 'package:path/path.dart' as path;

class PdfViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  final String? password;
  final VoidCallback? onPasswordRequired;
  final VoidCallback? onSuccess;
  final bool deleteOnClose;

  const PdfViewerScreen({
    super.key,
    required this.filePath,
    required this.fileName,
    this.password,
    this.onPasswordRequired,
    this.onSuccess,
    this.deleteOnClose = false,
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final PdfViewerController _pdfViewerController = PdfViewerController();
  PdfTextSearcher? _textSearcher;
  Key _viewerKey = UniqueKey();
  
  bool _hasCalledSuccess = false;
  String _currentPassword = '';
  bool _passwordAttempted = false;
  
  // State Variables
  bool _isLoading = true;
  int _currentPage = 1;
  int _totalPages = 0;
  bool _isSearching = false;
  final TextEditingController _searchFieldController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  
  // Preload progress
  bool _isPreloading = false;
  int _preloadedPages = 0;

  @override
  void initState() {
    super.initState();
    _currentPassword = widget.password ?? '';
    _pdfViewerController.addListener(_onViewerStateChanged);
  }
  
  void _onViewerStateChanged() {
    if (_pdfViewerController.document != null && _isLoading) {
        _onDocumentLoaded(_pdfViewerController.document!);
    }
  }

  Future<void> _onDocumentLoaded(PdfDocument document) async {
        if (!_isLoading) return; // Already handled
        _isLoading = false;
        _totalPages = document.pages.length;
        if (mounted) setState(() {});

        // Initialize Searcher
        _textSearcher = PdfTextSearcher(_pdfViewerController)..addListener(_updateSearchUI);
        
        // SUCCESS HANDLING: Save the working password
        if (_currentPassword.isNotEmpty) {
            await PdfPasswordService().saveDocumentPassword(widget.filePath, _currentPassword);
        }
        
        if (widget.onSuccess != null && !_hasCalledSuccess) {
          _hasCalledSuccess = true;
          widget.onSuccess!();
        }
  }

  @override
  void dispose() {
    _textSearcher?.removeListener(_updateSearchUI);
    _textSearcher?.dispose();
    _searchFieldController.dispose();
    _searchFocusNode.dispose();
    if (widget.deleteOnClose) {
      try {
        File(widget.filePath).delete().catchError((_) {});
      } catch (_) {}
    }
    super.dispose();
  }

  void _updateSearchUI() {
    if (mounted) setState(() {});
  }

  // Password Candidates Logic
  List<String> _candidatePasswords = [];
  int _candidateIndex = 0;
  bool _candidatesLoaded = false;

  Future<String?> _getPassword() async {
    // 1. If we have a current password (from widget or successful user input), use it once.
    // However, if _passwordAttempted is true, it means the viewer called us AGAIN, 
    // implying the previous password FAILED.
    if (!_passwordAttempted && _currentPassword.isNotEmpty) {
      _passwordAttempted = true;
      return _currentPassword;
    }
    _passwordAttempted = true; // Mark as attempted for subsequent calls

    if (!mounted) return null;

    // 2. Load candidates if not already done
    if (!_candidatesLoaded) {
       _candidatesLoaded = true;
       // Load all potential passwords from service
       final service = PdfPasswordService();
       
       // Priority 1: Check specifically for this document (Path or Filename match)
       final specificPwd = await service.getPasswordForDocument(widget.filePath);
       if (specificPwd != null && specificPwd.isNotEmpty) {
          _candidatePasswords.add(specificPwd);
       }
       
       // Priority 2: All other unique passwords (Recursive Check)
       final allPwds = await service.getAllUniquePasswords();
       for (final pwd in allPwds) {
          if (!_candidatePasswords.contains(pwd)) {
             _candidatePasswords.add(pwd);
          }
       }
    }

    // 3. Try next candidate
    if (_candidateIndex < _candidatePasswords.length) {
       final pwd = _candidatePasswords[_candidateIndex];
       _candidateIndex++;
       // Update cached password so if it works, we know which one it was (though we don't persist it here yet)
       _currentPassword = pwd; 
       return pwd;
    }

    // 4. If all candidates fail, Prompt User
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PasswordSelectionDialog(),
    );
    
    if (password != null && password.isNotEmpty) {
      _currentPassword = password;
      return password;
    }
    
    // User cancelled
    if (mounted) {
       Navigator.pop(context);
    }
    return null;
  }

  void _startSearch() {
    if (_textSearcher == null) return;
    setState(() {
      _isSearching = true;
      _searchFocusNode.requestFocus();
    });
  }

  void _stopSearch() {
    setState(() {
      _isSearching = false;
      _textSearcher?.resetTextSearch();
      _searchFieldController.clear();
    });
  }

  Future<void> _handleBackButton() async {
    if (_isSearching) {
      _stopSearch();
      return;
    }
    // Force close screen (ignore zoom state)
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!File(widget.filePath).existsSync()) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: const Center(child: Text('File not found')),
      );
    }

    final isLight = Theme.of(context).brightness == Brightness.light;
    final searchTextColor = isLight ? Colors.black : Colors.white;
    final searchHintColor = isLight ? Colors.black54 : Colors.white70;

    return PopScope(
      canPop: false, // Fully intercept back button
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackButton();
      },
      child: Scaffold(
      appBar: AppBar(
        title: _isSearching 
          ? TextField(
              controller: _searchFieldController,
              focusNode: _searchFocusNode,
              decoration: InputDecoration(
                hintText: 'Search...',
                border: InputBorder.none,
                hintStyle: TextStyle(color: searchHintColor),
              ),
              style: TextStyle(color: searchTextColor),
              onChanged: (text) => _textSearcher?.startTextSearch(text),
              onSubmitted: (_) => _textSearcher?.goToNextMatch(),
            )
          : Text(widget.fileName, overflow: TextOverflow.ellipsis),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBackButton, // Unified Back Behavior
        ),
        actions: [
          if (_isSearching && _textSearcher != null) ...[
             IconButton(
               icon: const Icon(Icons.keyboard_arrow_up),
               onPressed: _textSearcher!.matches.isNotEmpty ? () => _textSearcher!.goToPrevMatch() : null,
             ),
             IconButton(
               icon: const Icon(Icons.keyboard_arrow_down),
               onPressed: _textSearcher!.matches.isNotEmpty ? () => _textSearcher!.goToNextMatch() : null,
             ),
             if (_textSearcher!.currentIndex != null && _textSearcher!.matches.isNotEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(
                      '${_textSearcher!.currentIndex! + 1}/${_textSearcher!.matches.length}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
          ] else if (!_isLoading)
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _startSearch,
            ),
          
          if (!_isSearching)
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'remove_password') await _handleRemovePassword(context);
              else if (value == 'add_password') await _handleAddPassword(context);
              else if (value == 'reorder') await _handleReorder(context);
              else if (value == 'split') await _handleSplit(context);
              else if (value == 'merge') await _handleMerge(context);
            },
            itemBuilder: (context) {
              final isProtected = _currentPassword.isNotEmpty;
              return [
                const PopupMenuItem(value: 'split', child: Row(children: [Icon(Icons.call_split), SizedBox(width: 8), Text('Split PDF')])),
                const PopupMenuItem(value: 'merge', child: Row(children: [Icon(Icons.merge), SizedBox(width: 8), Text('Merge PDF')])),
                const PopupMenuItem(value: 'reorder', child: Row(children: [Icon(Icons.sort), SizedBox(width: 8), Text('Reorder Pages')])),
                if (isProtected)
                  const PopupMenuItem(value: 'remove_password', child: Row(children: [Icon(Icons.lock_open), SizedBox(width: 8), Text('Remove Password')]))
                else
                  const PopupMenuItem(value: 'add_password', child: Row(children: [Icon(Icons.lock), SizedBox(width: 8), Text('Add Password')])),
              ];
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          PdfViewer.file(
            widget.filePath,
            key: _viewerKey,
            controller: _pdfViewerController,
            passwordProvider: () => _getPassword(),
            params: PdfViewerParams(
              maxScale: 8.0,


              // Bug-3 Fix: Center pages if they don't fill the screen (single page issue)
              // Bug-3 Fix: Center pages if they don't fill the screen (single page issue)
              layoutPages: (pages, params) {
                // 1. Calculate Content Size (Stacking pages vertically)
                double width = 0;
                double height = 0;
                List<Rect> pageRects = [];
                
                for (var page in pages) {
                  width = width > page.width ? width : page.width; // Max width
                  pageRects.add(Rect.fromLTWH(0, height, page.width, page.height));
                  height += page.height; 
                }
                
                // 2. Check if content needs centering
                // We compare aspect ratios because PDF units != Screen pixels.
                // Screen Aspect Ratio
                final screenSize = MediaQuery.of(context).size;
                final screenAspectRatio = screenSize.width / screenSize.height;
                
                // Content Aspect Ratio
                final contentAspectRatio = width / height;
                
                // If content is "shorter" (wider) than screen, we have vertical space to fill.
                // We want to extend the DOCUMENT height to match screen aspect ratio, 
                // effectively adding top/bottom padding.
                
                if (contentAspectRatio > screenAspectRatio) {
                   // Calculate target height to match screen aspect ratio
                   // width / targetHeight = screenWidth / screenHeight
                   // targetHeight = width * (screenHeight / screenWidth)
                   final targetHeight = width / screenAspectRatio;
                   
                   final verticalPadding = (targetHeight - height) / 2;
                   
                   // Shift all pages down
                   pageRects = pageRects.map((r) => r.shift(Offset(0, verticalPadding))).toList();
                   
                   return PdfPageLayout(
                      pageLayouts: pageRects,
                      documentSize: Size(width, targetHeight),
                   );
                }
                
                // Otherwise fit to width (default behavior), no extra padding needed
                return PdfPageLayout(
                  pageLayouts: pageRects,
                  documentSize: Size(width, height),
                );
              },
              
              // Enable kinetic scrolling (standard Android clamping)
              scrollPhysics: const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              viewerOverlayBuilder: (context, size, handleLinkTap) => [
                // Capsule scrollbar on right side
                PdfViewerScrollThumb(
                  controller: _pdfViewerController,
                  orientation: ScrollbarOrientation.right,
                  thumbSize: const Size(32, 48),
                  thumbBuilder: (context, thumbSize, pageNumber, controller) => Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade400, width: 0.5),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.keyboard_arrow_up, size: 16, color: Colors.grey.shade600),
                        Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.grey.shade600),
                      ],
                    ),
                  ),
                ),
              ],
              // Per-page indicator using pageOverlaysBuilder
              pageOverlaysBuilder: (context, pageRect, page) {
                final totalPages = _pdfViewerController.document?.pages.length ?? 0;
                return [
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${page.pageNumber} / $totalPages',
                        style: const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                  ),
                ];
              },
              // Search Highlighting
              pagePaintCallbacks: _textSearcher != null ? [
                _textSearcher!.pageTextMatchPaintCallback
              ] : [],
              // Error Handling
              errorBannerBuilder: (context, error, stackTrace, documentRef) {
                if (error.toString().contains('No password supplied')) {
                   return Center(
                     child: Column(
                       mainAxisAlignment: MainAxisAlignment.center,
                       children: [
                         const Text('Password Required', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                         const SizedBox(height: 16),
                         ElevatedButton(
                           onPressed: () {
                             setState(() {
                               _passwordAttempted = false;
                               _currentPassword = ''; // Fix Bug-1: Clear wrong password so dialog shows again
                               _viewerKey = UniqueKey();
                             });
                           },
                           child: const Text('Enter Password'),
                         ),
                       ],
                     ),
                   );
                }
                return Center(child: Text('Error: $error'));
              },
              onViewerReady: (document, controller) {
                if (mounted) {
                  _textSearcher = PdfTextSearcher(controller)..addListener(_updateSearchUI);
                  setState(() {
                    _isLoading = false;
                    _totalPages = document.pages.length;
                  });
                }
                if (!_hasCalledSuccess && widget.onSuccess != null) {
                  _hasCalledSuccess = true;
                  widget.onSuccess!();
                }
                if (_currentPassword.isNotEmpty) {
                   PdfPasswordService().saveDocumentPassword(widget.filePath, _currentPassword);
                }
              },
              onPageChanged: (pageNumber) {
                if (mounted) {
                  setState(() {
                    _currentPage = pageNumber ?? 1;
                  });
                }
              },
            ),
          ),
          
          // Document loading indicator
          if (_isLoading)
            Container(
              color: Colors.black12,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Loading PDF...', style: TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            ),
            
         // Page indicator now handled by PdfPageNumber in viewerOverlayBuilder
        ],
      ),
    ),  // Close PopScope
  );
  }

  // --- PDF Tools Implementation ---
  
  Future<void> _handleRemovePassword(BuildContext context) async {
     await _runToolOperation(context, (tools, savePath) => tools.removePassword(
        filePath: widget.filePath,
        password: _currentPassword,
        savePath: savePath
     ), '_unlocked');
  }

  Future<void> _handleAddPassword(BuildContext context) async {
    final pwd = await showDialog<String>(
      context: context, 
      builder: (c) => const PasswordSelectionDialog()
    );
    if (pwd == null) return;
    
    await _runToolOperation(context, (tools, savePath) => tools.addPassword(
       filePath: widget.filePath,
       password: pwd,
       savePath: savePath
    ), '_protected');
  }

  Future<void> _handleReorder(BuildContext context) async {
     final count = _pdfViewerController.document?.pages.length ?? 0;
     if (count == 0) return;
     
     final newOrder = await showDialog<List<int>>(
       context: context,
       builder: (c) => ReorderPagesDialog(pageCount: count)
     );
     if (newOrder == null) return;

     await _runToolOperation(context, (tools, savePath) => tools.reorderPages(
       filePath: widget.filePath,
       password: _currentPassword,
       pageOrder: newOrder,
       savePath: savePath
     ), '_reordered');
  }

  Future<void> _handleSplit(BuildContext context) async {
     final count = _pdfViewerController.document?.pages.length ?? 0;
     if (count == 0) return;

     final pages = await showDialog<List<int>>(
       context: context,
       builder: (c) => SplitPdfDialog(pageCount: count)
     );
     if (pages == null) return;

     await _runToolOperation(context, (tools, savePath) => tools.splitPdf(
       filePath: widget.filePath,
       password: _currentPassword,
       pageIndices: pages,
       savePath: savePath
     ), '_split');
  }

  Future<void> _handleMerge(BuildContext context) async {
    final result = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (c) => const FileSystemBrowser(allowedExtensions: ['pdf'], allowMultiple: false))
    );
    if (result == null || result.isEmpty) return;
    
    await _runToolOperation(context, (tools, savePath) => tools.mergePdf(
       sourcePath: widget.filePath,
       sourcePassword: _currentPassword,
       otherPath: result.first,
       otherPassword: '', 
       savePath: savePath
    ), '_merged');
  }

  Future<void> _runToolOperation(
    BuildContext context, 
    Future<String> Function(PdfToolsService, String) operation,
    String suffix
  ) async {
    try {
      final exportPath = SettingsService().exportPath;
      final dir = exportPath ?? path.dirname(widget.filePath);
      final filename = path.basenameWithoutExtension(widget.filePath);
      final ext = path.extension(widget.filePath);
      final defaultPath = path.join(dir, '${filename}$suffix$ext');

      final savePath = await FileConflictResolver.resolve(context: context, filePath: defaultPath);
      if (savePath == null) return;

      if (mounted) showDialog(context: context, barrierDismissible: false, builder: (c) => const Center(child: CircularProgressIndicator()));
      
      final tools = PdfToolsService();
      final newPath = await operation(tools, savePath);
      
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved: ${path.basename(newPath)}'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }
}
