import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../services/ai/pdf_indexing_coordinator.dart';
import '../../../services/pdf_tools_service.dart';
import '../../../services/pdf_password_service.dart';
import '../widgets/reorder_pages_dialog.dart';
import '../widgets/split_pdf_dialog.dart';
import '../widgets/password_selection_dialog.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/page_navigation_dialog.dart';
import 'file_system_browser.dart';
import '../../settings/services/settings_service.dart';
import '../../common/utils/file_conflict_resolver.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../widgets/folder_selection_dialog.dart';
import '../widgets/duplicate_files_dialog.dart';
import '../../../services/document_service.dart';
import 'file_info_screen.dart';
import '../../../models/document_item_model.dart';
import '../../../services/logging_service.dart';
import '../../../services/pdf_annotation_and_form_service.dart';
import '../widgets/signature_pad_dialog.dart';
import '../widgets/pdf_form_fill_dialog.dart';
import '../widgets/pdf_element_placement_dialog.dart';

class PdfViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  final String? password;
  final VoidCallback? onPasswordRequired;
  final VoidCallback? onSuccess;
  final bool isExternal;
  final bool deleteOnClose;
  final int? initialPageNumber;

  const PdfViewerScreen({
    super.key,
    required this.filePath,
    required this.fileName,
    this.password,
    this.onPasswordRequired,
    this.onSuccess,
    this.isExternal = false,
    this.deleteOnClose = false,
    this.initialPageNumber,
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final PdfViewerController _pdfViewerController = PdfViewerController();
  PdfTextSearcher? _textSearcher;
  Key _viewerKey = UniqueKey();
  final LoggingService _log = LoggingService();
  
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

  // On-Page Placement State
  bool _isPlacingElement = false;
  PlacementType _placementType = PlacementType.signature;
  Uint8List? _placementSignatureBytes;
  String? _placementNoteText;
  int _placementTargetPage = 1;
  double _placementNormX = 0.55;
  double _placementNormY = 0.78;
  double _placementNormWidth = 0.35;
  double _placementNormHeight = 0.12;

  @override
  void initState() {
    super.initState();
    _currentPassword = widget.password ?? '';
    _candidatesLoadFuture = _loadCandidatesOnce();
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
  final List<String> _candidatePasswords = [];
  int _candidateIndex = 0;
  Future<void>? _candidatesLoadFuture;
  Future<String?>? _inFlightPasswordRequest;

  Future<void> _loadCandidatesOnce() async {
    final service = PdfPasswordService();
    await service.initialize();

    // 1. Initial password from widget (if passed)
    if (widget.password != null && widget.password!.isNotEmpty) {
      if (!_candidatePasswords.contains(widget.password!)) {
        _candidatePasswords.add(widget.password!);
      }
    }

    // 2. Priority: Specific password for this document (path or filename match)
    final specificPwd = await service.getPasswordForDocument(widget.filePath);
    if (specificPwd != null && specificPwd.isNotEmpty) {
      if (!_candidatePasswords.contains(specificPwd)) {
        _candidatePasswords.insert(0, specificPwd);
      }
    }

    // 3. Fallback: All other unique passwords
    final allPwds = await service.getAllUniquePasswords();
    for (final pwd in allPwds) {
      if (!_candidatePasswords.contains(pwd)) {
        _candidatePasswords.add(pwd);
      }
    }
  }

  Future<String?> _getPassword() {
    if (_inFlightPasswordRequest != null) {
      return _inFlightPasswordRequest!;
    }
    final req = _doGetPassword();
    _inFlightPasswordRequest = req;
    req.whenComplete(() {
      _inFlightPasswordRequest = null;
    });
    return req;
  }

  Future<String?> _doGetPassword() async {
    if (_passwordAttempted) {
      _log.warn('PdfViewer', 'PDF open rejected password attempt for ${widget.filePath}');
    }
    _passwordAttempted = true; // Mark as attempted for subsequent calls

    if (!mounted) return null;

    _candidatesLoadFuture ??= _loadCandidatesOnce();
    await _candidatesLoadFuture;

    // 3. Try next candidate
    if (_candidateIndex < _candidatePasswords.length) {
       final pwd = _candidatePasswords[_candidateIndex];
       _candidateIndex++;
       // Update cached password so if it works, we know which one it was
       _currentPassword = pwd; 
       return pwd;
    }

    // 4. If all candidates fail, Prompt User
    if (_isLoading && mounted) {
      setState(() => _isLoading = false);
    }

    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PasswordSelectionDialog(),
    );

    // Distinguish: null  = user cancelled/dismissed (pop the viewer),
    //              ''    = user chose "No Password" -> attempt empty password,
    //              other = a real password attempt.
    if (password != null) {
      _currentPassword = password;
      if (mounted) setState(() => _isLoading = true);
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
    if (_isPlacingElement) {
      _cancelPlacement();
      return;
    }
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
          if (_isLoading) ...[
            const SizedBox.shrink(),
          ] else if (_isSearching && _textSearcher != null) ...[
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
          ] else ...[
            if (widget.isExternal)
              IconButton(
                icon: const Icon(Icons.save_alt),
                tooltip: 'Save to Folder',
                onPressed: () => _handleSaveFile(context),
              ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Share File',
              onPressed: () => _handleShareFile(),
            ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _startSearch,
            ),
          ],
          
          if (!_isSearching)
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'remove_password') await _handleRemovePassword(context);
              else if (value == 'add_password') await _handleAddPassword(context);
              else if (value == 'sign_pdf') await _handleSignDocument(context);
              else if (value == 'fill_form') await _handleFillForm(context);
              else if (value == 'add_highlight') await _handleAddHighlight(context);
              else if (value == 'reorder') await _handleReorder(context);
              else if (value == 'split') await _handleSplit(context);
              else if (value == 'merge') await _handleMerge(context);
              else if (value == 'go_to_page') await _handleGoToPage(context);
              else if (value == 'file_info') await _handleFileInfo(context);
            },
            itemBuilder: (context) {
              final isProtected = _currentPassword.isNotEmpty;
              return [
                const PopupMenuItem(
                  value: 'sign_pdf',
                  child: Row(children: [Icon(Icons.draw), SizedBox(width: 8), Text('Sign Document')]),
                ),
                const PopupMenuItem(
                  value: 'fill_form',
                  child: Row(children: [Icon(Icons.assignment), SizedBox(width: 8), Text('Fill Form Fields')]),
                ),
                const PopupMenuItem(
                  value: 'add_highlight',
                  child: Row(children: [Icon(Icons.highlight), SizedBox(width: 8), Text('Add Highlight')]),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'go_to_page',
                  child: Row(children: [Icon(Icons.directions), SizedBox(width: 8), Text('Go to Page')]),
                ),
                const PopupMenuItem(
                  value: 'file_info',
                  child: Row(children: [Icon(Icons.info_outline), SizedBox(width: 8), Text('File info')]),
                ),
                const PopupMenuDivider(),
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
              linkHandlerParams: null,
              linkWidgetBuilder: (context, link, size) {
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    splashColor: Colors.blue.withValues(alpha: 0.2),
                    highlightColor: Colors.blue.withValues(alpha: 0.1),
                    onTap: () => _openPdfLink(link),
                  ),
                );
              },


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
              // Per-page indicator & on-page placement using pageOverlaysBuilder
              pageOverlaysBuilder: (context, pageRect, page) {
                final totalPages = _pdfViewerController.document?.pages.length ?? 0;
                final overlays = <Widget>[
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

                if (_isPlacingElement && page.pageNumber == _placementTargetPage) {
                  overlays.add(
                    Positioned(
                      left: _placementNormX * pageRect.width,
                      top: _placementNormY * pageRect.height,
                      width: _placementNormWidth * pageRect.width,
                      height: _placementNormHeight * pageRect.height,
                      child: _buildOnPageDraggableElement(pageRect, page),
                    ),
                  );
                }

                return overlays;
              },
              // Search Highlighting
              pagePaintCallbacks: _textSearcher != null ? [
                _textSearcher!.pageTextMatchPaintCallback
              ] : [],
              // Error Handling
              errorBannerBuilder: (context, error, stackTrace, documentRef) {
                if (_isLoading) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _isLoading) setState(() => _isLoading = false);
                  });
                }
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
                               _candidateIndex = _candidatePasswords.length;
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
                if (widget.initialPageNumber != null &&
                    widget.initialPageNumber! >= 1 &&
                    widget.initialPageNumber! <= document.pages.length) {
                  controller.goToPage(pageNumber: widget.initialPageNumber!);
                }
                // Trigger local background text indexing & vector embedding
                unawaited(
                  PdfIndexingCoordinator()
                      .indexPdfDocument(
                        filePath: widget.filePath,
                        password: _currentPassword.isNotEmpty ? _currentPassword : null,
                      )
                      .catchError((_) => ''),
                );
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

          // Floating placement controls toolbar
          if (_isPlacingElement)
            _buildFloatingPlacementControls(),
            
         // Page indicator now handled by PdfPageNumber in viewerOverlayBuilder
        ],
      ),
    ),  // Close PopScope
  );
  }

  Future<void> _openPdfLink(PdfLink link) async {
    if (link.url != null) {
      await _launchResolvedUrl(context, link.url.toString());
    } else if (link.dest != null) {
      await _pdfViewerController.goToDest(link.dest);
    }
  }

  Future<void> _launchResolvedUrl(BuildContext context, String rawUrl) async {
    var text = rawUrl.trim();
    while (text.endsWith('.') || text.endsWith(',') || text.endsWith(';') || text.endsWith(')')) {
      text = text.substring(0, text.length - 1).trim();
    }

    Uri? uri;
    if (text.startsWith('mailto:') || text.startsWith('http://') || text.startsWith('https://') || text.startsWith('tel:')) {
      uri = Uri.tryParse(text);
    } else if (text.contains('@') && !text.contains('/')) {
      uri = Uri.tryParse('mailto:$text');
    } else {
      uri = Uri.tryParse('https://$text');
    }

    if (uri == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid link: $rawUrl')),
        );
      }
      return;
    }

    try {
      bool launched = false;
      try {
        launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        launched = false;
      }
      if (!launched) {
        try {
          launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
        } catch (_) {
          launched = false;
        }
      }
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open link: $rawUrl')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening link: $e')),
        );
      }
    }
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

     final tools = PdfToolsService();
     bool confirmedFlatten = true;
     if (await tools.willFlattenOnReorder(filePath: widget.filePath, password: _currentPassword)) {
       if (context.mounted) {
         confirmedFlatten = await showDialog<bool>(
           context: context,
           builder: (c) => AlertDialog(
             title: const Text('Flatten Interactive Content?'),
             content: const Text('Reordering pages will flatten form fields, annotations, and bookmarks. The document will look the same but will no longer be interactive. Do you want to continue?'),
             actions: [
               TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
               TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continue')),
             ],
           ),
         ) ?? false;
       } else {
         confirmedFlatten = false;
       }
     }
     if (!confirmedFlatten) return;

     if (!context.mounted) return;
     await _runToolOperation(context, (tools, savePath) => tools.reorderPages(
       filePath: widget.filePath,
       password: _currentPassword,
       pageOrder: newOrder,
       confirmedFlatten: confirmedFlatten,
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
    
    final tools = PdfToolsService();
    bool confirmedFlatten = true;
    if (await tools.willFlattenOnMerge(
      sourcePath: widget.filePath,
      sourcePassword: _currentPassword,
      otherPath: result.first,
      otherPassword: '',
    )) {
      if (context.mounted) {
        confirmedFlatten = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Flatten Interactive Content?'),
            content: const Text('Merging PDFs will flatten form fields, annotations, and bookmarks. The merged file will look the same but will no longer be interactive. Do you want to continue?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continue')),
            ],
          ),
        ) ?? false;
      } else {
        confirmedFlatten = false;
      }
    }
    if (!confirmedFlatten) return;

    if (!context.mounted) return;
    await _runToolOperation(context, (tools, savePath) => tools.mergePdf(
       sourcePath: widget.filePath,
       sourcePassword: _currentPassword,
       otherPath: result.first,
       otherPassword: '', 
       confirmedFlatten: confirmedFlatten,
       savePath: savePath
    ), '_merged');
  }

  // --- Feature Implementation ---

  Future<void> _handleGoToPage(BuildContext context) async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => PageNavigationDialog(
        totalPages: _totalPages,
        currentPage: _currentPage,
      ),
    );

    if (result != null && mounted) {
      _pdfViewerController.goToPage(pageNumber: result);
    }
  }

  Future<void> _handleSignDocument(BuildContext context) async {
    final signatureBytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => const SignaturePadDialog(),
    );
    if (signatureBytes == null || !mounted) return;

    setState(() {
      _isPlacingElement = true;
      _placementType = PlacementType.signature;
      _placementSignatureBytes = signatureBytes;
      _placementNoteText = null;
      _placementTargetPage = _currentPage;
      _placementNormX = 0.55;
      _placementNormY = 0.78;
      _placementNormWidth = 0.35;
      _placementNormHeight = 0.12;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Drag signature on the actual page to position. Pinch & zoom document freely.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _handleFillForm(BuildContext context) async {
    final annotService = PdfAnnotationAndFormService();
    final fields = await annotService.getFormFields(
      filePath: widget.filePath,
      password: _currentPassword,
    );

    if (!mounted) return;
    if (fields.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No interactive form fields found in this document.')),
      );
      return;
    }

    final filledValues = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => PdfFormFillDialog(fields: fields),
    );

    if (filledValues == null || !mounted) return;

    try {
      final outPath = await annotService.fillFormFields(
        filePath: widget.filePath,
        password: _currentPassword,
        fieldValues: filledValues,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Form filled copy created: ${path.basename(outPath)}'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PdfViewerScreen(
                      filePath: outPath,
                      fileName: path.basename(outPath),
                      password: _currentPassword,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fill form fields: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleAddHighlight(BuildContext context) async {
    final noteController = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add Highlight & Note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Highlight a note section on Page $_currentPage.'),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(
                labelText: 'Note Text (Optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, null), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, noteController.text.trim()),
            child: const Text('Add Highlight'),
          ),
        ],
      ),
    );

    if (note == null || !mounted) return;

    setState(() {
      _isPlacingElement = true;
      _placementType = PlacementType.highlight;
      _placementSignatureBytes = null;
      _placementNoteText = note.isNotEmpty ? note : 'Highlighted Section';
      _placementTargetPage = _currentPage;
      _placementNormX = 0.08;
      _placementNormY = 0.15;
      _placementNormWidth = 0.84;
      _placementNormHeight = 0.05;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Drag highlight rectangle on the page to position. Pinch & zoom freely.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _cancelPlacement() {
    setState(() {
      _isPlacingElement = false;
      _placementSignatureBytes = null;
      _placementNoteText = null;
    });
  }

  Future<void> _confirmPlacement() async {
    if (!_isPlacingElement) return;

    try {
      final annotService = PdfAnnotationAndFormService();
      final pageSize = await annotService.getPageSize(
        filePath: widget.filePath,
        password: _currentPassword,
        pageNumber: _placementTargetPage,
      );

      final pdfX = _placementNormX * pageSize.width;
      final pdfY = _placementNormY * pageSize.height;
      final pdfWidth = _placementNormWidth * pageSize.width;
      final pdfHeight = _placementNormHeight * pageSize.height;
      final placedBounds = Rect.fromLTWH(pdfX, pdfY, pdfWidth, pdfHeight);

      String outPath;
      if (_placementType == PlacementType.signature && _placementSignatureBytes != null) {
        outPath = await annotService.stampSignature(
          filePath: widget.filePath,
          password: _currentPassword,
          signaturePngBytes: _placementSignatureBytes!,
          pageNumber: _placementTargetPage,
          bounds: placedBounds,
        );
      } else {
        outPath = await annotService.addHighlightAndNote(
          filePath: widget.filePath,
          password: _currentPassword,
          pageNumber: _placementTargetPage,
          bounds: placedBounds,
          noteText: _placementNoteText,
        );
      }

      setState(() {
        _isPlacingElement = false;
        _placementSignatureBytes = null;
        _placementNoteText = null;
      });

      if (mounted) {
        final label = _placementType == PlacementType.signature ? 'Signed' : 'Annotated';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$label copy created: ${path.basename(outPath)}'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PdfViewerScreen(
                      filePath: outPath,
                      fileName: path.basename(outPath),
                      password: _currentPassword,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stamp: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildOnPageDraggableElement(Rect pageRect, PdfPage page) {
    final isSig = _placementType == PlacementType.signature;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) {
        setState(() {
          _placementNormX = (_placementNormX + details.delta.dx / pageRect.width).clamp(0.0, 1.0 - _placementNormWidth);
          _placementNormY = (_placementNormY + details.delta.dy / pageRect.height).clamp(0.0, 1.0 - _placementNormHeight);
        });
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Main Body Box
          Container(
            decoration: BoxDecoration(
              color: isSig ? Colors.blue.withValues(alpha: 0.12) : Colors.yellow.withValues(alpha: 0.38),
              border: Border.all(
                color: isSig ? Colors.blue.shade700 : Colors.amber.shade800,
                width: 2.0,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: isSig && _placementSignatureBytes != null
                ? Image.memory(
                    _placementSignatureBytes!,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: double.infinity,
                  )
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        _placementNoteText ?? 'Highlight',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
          ),

          // Top Drag Label Badge
          Positioned(
            left: 0,
            top: -18,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isSig ? Colors.blue.shade700 : Colors.amber.shade800,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.open_with, size: 10, color: Colors.white),
                  const SizedBox(width: 3),
                  Text(
                    isSig ? 'Signature (Drag to move)' : 'Highlight (Drag)',
                    style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),

          // Bottom-Right Corner Resize Handle
          Positioned(
            right: -6,
            bottom: -6,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                setState(() {
                  _placementNormWidth = (_placementNormWidth + details.delta.dx / pageRect.width).clamp(0.08, 0.95 - _placementNormX);
                  _placementNormHeight = (_placementNormHeight + details.delta.dy / pageRect.height).clamp(0.03, 0.95 - _placementNormY);
                });
              },
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: isSig ? Colors.blue.shade700 : Colors.amber.shade800,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
                child: const Icon(Icons.open_in_full, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingPlacementControls() {
    final isSig = _placementType == PlacementType.signature;
    final colorScheme = Theme.of(context).colorScheme;

    return Positioned(
      left: 12,
      right: 12,
      bottom: 20,
      child: SafeArea(
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).cardColor,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(isSig ? Icons.draw : Icons.highlight, color: colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isSig
                            ? 'Position Signature on Page $_placementTargetPage of $_totalPages'
                            : 'Position Highlight on Page $_placementTargetPage of $_totalPages',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_totalPages > 1) ...[
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Previous Page',
                        onPressed: _placementTargetPage > 1
                            ? () {
                                setState(() => _placementTargetPage--);
                                _pdfViewerController.goToPage(pageNumber: _placementTargetPage);
                              }
                            : null,
                      ),
                      Text('$_placementTargetPage', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Next Page',
                        onPressed: _placementTargetPage < _totalPages
                            ? () {
                                setState(() => _placementTargetPage++);
                                _pdfViewerController.goToPage(pageNumber: _placementTargetPage);
                              }
                            : null,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.aspect_ratio, size: 16, color: Colors.grey),
                    const SizedBox(width: 8),
                    const Text('Size:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Expanded(
                      child: Slider(
                        value: _placementNormWidth,
                        min: 0.10,
                        max: 0.85,
                        onChanged: (val) {
                          setState(() {
                            final ratio = _placementNormHeight / _placementNormWidth;
                            _placementNormWidth = val.clamp(0.10, 1.0 - _placementNormX);
                            _placementNormHeight = (_placementNormWidth * ratio).clamp(0.03, 1.0 - _placementNormY);
                          });
                        },
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _cancelPlacement,
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                      ),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Stamp Here'),
                      onPressed: _confirmPlacement,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleFileInfo(BuildContext context) async {
    // Build a DocumentItem for the currently-open file.
    // Prefer the library id if this file is already imported (findFileIdByPath),
    // otherwise construct a temp item from the on-disk File stat.
    final file = File(widget.filePath);
    if (!file.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File not found'), backgroundColor: Colors.red),
        );
      }
      return;
    }

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

  Future<void> _handleShareFile() async {
    try {
      await Share.shareXFiles([XFile(widget.filePath)], text: widget.fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Share failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _handleSaveFile(BuildContext context) async {
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
      await _saveToLibrary(context);
    } else if (choice == 'device') {
      await _saveToDevice(context);
    }
  }

  Future<void> _saveToLibrary(BuildContext context) async {
    final docService = DocumentService();
    
    // 1. Library Duplicate Check
    final duplicates = await docService.checkForDuplicates([widget.filePath]);
    if (duplicates.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => DuplicateFilesDialog(duplicates: duplicates),
      );
      if (proceed != true) return;
    }

    // 2. Folder Selection
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

      // 3. Resolve Physical Path
      // Updated DocumentService uses Flat Storage for manual folders, resolving to Root Export Path
      final targetDir = await docService.getPhysicalPathForFolder(targetFolderId);
      if (!Directory(targetDir).existsSync()) {
        await Directory(targetDir).create(recursive: true);
      }

      final targetPath = path.join(targetDir, widget.fileName);

      // 4. Conflict Resolution
      final resolvedPath = await FileConflictResolver.resolve(context: context, filePath: targetPath);
      if (resolvedPath == null) {
        if (mounted) Navigator.pop(context); // Close loading
        return;
      }

      // 5. Copy File
      await File(widget.filePath).copy(resolvedPath);

      // 6. Add to Library
      await docService.addFile(resolvedPath, folderId: targetFolderId, isNew: true, isImportedFile: true);

      if (mounted) {
        Navigator.pop(context); // Close loading
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
      // 1. Pick Folder
      final result = await Navigator.push<List<String>>(
          context,
          MaterialPageRoute(
               builder: (context) => const FileSystemBrowser(
                   allowFolderSelection: true,
                   allowMultiple: false,
                   initialPath: '/storage/emulated/0', // Start at root
               )
          )
      );
      
      if (result == null || result.isEmpty) return;
      final targetDir = result.first;
      
      try {
          if (mounted) showDialog(context: context, barrierDismissible: false, builder: (c) => const Center(child: CircularProgressIndicator()));
          
          final targetPath = path.join(targetDir, widget.fileName);
          
          // 2. Conflict Resolution (Standard: Rename/Overwrite)
          // FileConflictResolver handles "File already exists" dialog
          final resolvedPath = await FileConflictResolver.resolve(context: context, filePath: targetPath);
          
          if (resolvedPath == null) {
              if (mounted) Navigator.pop(context); // Close loading
              return;
          }
          
          // 3. Copy File
          await File(widget.filePath).copy(resolvedPath);
          
          if (mounted) {
              Navigator.pop(context); // Close loading
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Saved to ${path.basename(targetDir)}'), backgroundColor: Colors.green)
              );
          }
      } catch (e) {
         if (mounted) {
            if (Navigator.canPop(context)) Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
         }
      }
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
