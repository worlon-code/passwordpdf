import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../services/document_scanner_service.dart';
import '../../../services/document_service.dart';
import '../../../services/image_enhancement_service.dart';
import '../../../services/ocr_service.dart';
import '../../../services/pdf_tools_service.dart';
import '../widgets/interactive_crop_view.dart';
import 'pdf_viewer_screen.dart';

enum _ModifyTool {
  none,
  crop,
  filters,
  adjust,
}

enum _AdjustType {
  brightness,
  contrast,
}

/// Advanced Image to PDF Studio with theme-aware UI, real-time GPU filters, free-flow crop, and OCR
class ImageToPdfStudioScreen extends StatefulWidget {
  const ImageToPdfStudioScreen({super.key});

  @override
  State<ImageToPdfStudioScreen> createState() => _ImageToPdfStudioScreenState();
}

class _ImageToPdfStudioScreenState extends State<ImageToPdfStudioScreen> {
  final DocumentScannerService _scanner = DocumentScannerService();
  final ImageEnhancementService _enhancer = ImageEnhancementService();
  final OcrService _ocrService = OcrService();
  final PdfToolsService _pdfTools = PdfToolsService();
  final DocumentService _documentService = DocumentService();

  final List<ScannedPage> _pages = [];
  int _currentPageIndex = 0;
  bool _isGridView = false;

  // Active Tool Mode
  _ModifyTool _activeTool = _ModifyTool.none;
  _AdjustType _activeAdjustType = _AdjustType.brightness;
  bool _applyToAllPages = false;
  bool _isConverting = false;
  double _convertProgress = 0.0;

  // Interactive crop working state
  List<Offset>? _tempCropQuad;
  bool _isProcessingCrop = false;

  // PageController for smooth swipeable navigation between pages
  late final PageController _pageController;

  // PDF Export Settings
  PageFitPreset _selectedPreset = PageFitPreset.a4Portrait;
  double _margin = 18.0;
  ImageCompressionQuality _quality = ImageCompressionQuality.high;
  bool _enablePassword = false;
  bool _includeOcrTranscript = false;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pdfNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentPageIndex);
    final ts = DateTime.now();
    _pdfNameController.text =
        'Scan_${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _pageController.dispose();
    _passwordController.dispose();
    _pdfNameController.dispose();
    super.dispose();
  }

  void _cleanupPageFiles(ScannedPage page) {
    try {
      final f1 = File(page.imagePath);
      if (f1.existsSync()) f1.deleteSync();
      if (page.originalImagePath != page.imagePath) {
        final f2 = File(page.originalImagePath);
        if (f2.existsSync()) f2.deleteSync();
      }
    } catch (_) {}
  }

  void _cleanupAllPages() {
    for (final page in _pages) {
      _cleanupPageFiles(page);
    }
  }

  Future<void> _onBackRequested() async {
    if (_pages.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 26),
            SizedBox(width: 8),
            Text('Discard Changes?'),
          ],
        ),
        content: Text(
          'You have ${_pages.length} scanned page${_pages.length > 1 ? 's' : ''}. '
          'Leaving now will discard all unsaved edits and delete temporary scanned images.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Editing'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard & Leave'),
          ),
        ],
      ),
    );

    if (discard == true && mounted) {
      _cleanupAllPages();
      Navigator.of(context).pop();
    }
  }

  ScannedPage? get _currentPage =>
      (_pages.isNotEmpty && _currentPageIndex < _pages.length) ? _pages[_currentPageIndex] : null;

  // --- Ingestion ---

  Future<void> _captureFromCamera() async {
    try {
      final page = await _scanner.captureFromCamera();
      if (page != null && mounted) {
        setState(() {
          _pages.add(page);
          _currentPageIndex = _pages.length - 1;
        });
      }
    } catch (e) {
      _showSnackbar('Camera error: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final newPages = await _scanner.pickFromGallery();
      if (newPages.isNotEmpty && mounted) {
        setState(() {
          _pages.addAll(newPages);
          _currentPageIndex = _pages.length - 1;
        });
      }
    } catch (e) {
      _showSnackbar('Gallery error: $e');
    }
  }

  // --- Instant Zero-Delay Rotation ---

  void _rotateCurrentPage() {
    final page = _currentPage;
    if (page == null) return;
    setState(() {
      page.rotationDegrees = (page.rotationDegrees + 90) % 360;
    });
  }

  void _deleteCurrentPage() {
    if (_pages.isEmpty) return;
    final removed = _pages.removeAt(_currentPageIndex);
    _cleanupPageFiles(removed);
    setState(() {
      if (_currentPageIndex >= _pages.length && _pages.isNotEmpty) {
        _currentPageIndex = _pages.length - 1;
      }
      _activeTool = _ModifyTool.none;
    });
  }

  // --- Free-Flow Quadrilateral Crop ---

  void _startCrop() {
    final page = _currentPage;
    if (page == null) return;
    setState(() {
      _activeTool = _ModifyTool.crop;
      _tempCropQuad = page.cropQuad ?? [
        const Offset(0.04, 0.04),
        const Offset(0.96, 0.04),
        const Offset(0.96, 0.96),
        const Offset(0.04, 0.96),
      ];
    });
  }

  void _autoDetectCrop() {
    setState(() {
      _tempCropQuad = [
        const Offset(0.06, 0.05),
        const Offset(0.94, 0.05),
        const Offset(0.94, 0.95),
        const Offset(0.06, 0.95),
      ];
    });
  }

  void _noCrop() {
    final page = _currentPage;
    if (page == null) return;
    setState(() {
      page.imagePath = page.originalImagePath;
      page.cropQuad = null;
      _tempCropQuad = [
        const Offset(0.0, 0.0),
        const Offset(1.0, 0.0),
        const Offset(1.0, 1.0),
        const Offset(0.0, 1.0),
      ];
    });
    PaintingBinding.instance.imageCache.evict(FileImage(File(page.imagePath)));
    _showSnackbar('Page restored to uncropped original');
  }

  Future<void> _applyCrop() async {
    final page = _currentPage;
    final quad = _tempCropQuad;
    if (page == null || quad == null) {
      setState(() => _activeTool = _ModifyTool.none);
      return;
    }

    setState(() => _isProcessingCrop = true);
    try {
      final croppedPath = await _enhancer.cropQuadrilateral(
        sourcePath: page.originalImagePath,
        normalizedQuad: quad,
      );

      // Invalidate Flutter image cache so newly cropped bytes display immediately
      PaintingBinding.instance.imageCache.evict(FileImage(File(page.imagePath)));
      PaintingBinding.instance.imageCache.evict(FileImage(File(croppedPath)));

      setState(() {
        page.imagePath = croppedPath;
        page.cropQuad = quad;
        _activeTool = _ModifyTool.none;
        _isProcessingCrop = false;
      });

      _showSnackbar('Page ${_currentPageIndex + 1} cropped successfully');
    } catch (e) {
      setState(() => _isProcessingCrop = false);
      _showSnackbar('Crop error: $e');
    }
  }

  // --- Real-time Filters & Adjustments ---

  void _selectFilter(ScanFilterType filter) {
    setState(() {
      final page = _currentPage;
      if (page != null) {
        page.filter = filter;
      }
      if (_applyToAllPages) {
        for (final p in _pages) {
          p.filter = filter;
        }
      }
    });
  }

  void _toggleApplyToAll(bool val) {
    setState(() {
      _applyToAllPages = val;
      if (val && _currentPage != null) {
        final curFilter = _currentPage!.filter;
        final curB = _currentPage!.brightness;
        final curC = _currentPage!.contrast;
        for (final p in _pages) {
          p.filter = curFilter;
          p.brightness = curB;
          p.contrast = curC;
        }
      }
    });
  }

  void _updateAdjustment({int? brightness, int? contrast}) {
    setState(() {
      if (_applyToAllPages) {
        for (final p in _pages) {
          if (brightness != null) p.brightness = brightness;
          if (contrast != null) p.contrast = contrast;
        }
      } else {
        if (brightness != null) _currentPage?.brightness = brightness;
        if (contrast != null) _currentPage?.contrast = contrast;
      }
    });
  }

  // --- Multi-Page & Range OCR Recognition ---

  Future<void> _showOcrOptions() async {
    if (_pages.isEmpty) return;

    int selectedScope = 0; // 0: Current page, 1: All pages, 2: Range
    int startPage = 1;
    int endPage = _pages.length;
    final startController = TextEditingController(text: '1');
    final endController = TextEditingController(text: '${_pages.length}');

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.document_scanner, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('Document OCR Text'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_pages.any((p) => (p.ocrText != null && p.ocrText!.isNotEmpty) || p.ocrResult != null)) ...[
                    OutlinedButton.icon(
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: const Text('View / Edit Extracted OCR Text'),
                      onPressed: () {
                        Navigator.of(ctx).pop(false);
                        _openOcrSheetForPage(_currentPageIndex);
                      },
                    ),
                    const Divider(height: 24),
                  ],
                  const Text('Select which pages to recognize text on:'),
                  const SizedBox(height: 12),
                  RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    value: 0,
                    groupValue: selectedScope,
                    title: Text('Current Page (Page ${_currentPageIndex + 1})'),
                    onChanged: (val) => setDlgState(() => selectedScope = val!),
                  ),
                  RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    value: 1,
                    groupValue: selectedScope,
                    title: Text('All Pages (${_pages.length} Pages)'),
                    onChanged: (val) => setDlgState(() => selectedScope = val!),
                  ),
                  RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    value: 2,
                    groupValue: selectedScope,
                    title: const Text('Page Range'),
                    onChanged: (val) => setDlgState(() => selectedScope = val!),
                  ),
                  if (selectedScope == 2) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'From Page',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (v) => startPage = int.tryParse(v) ?? 1,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: endController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'To Page',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (v) => endPage = int.tryParse(v) ?? _pages.length,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Start OCR'),
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ],
          );
        },
      ),
    );

    if (proceed != true || !mounted) return;

    List<int> targetIndices;
    if (selectedScope == 0) {
      targetIndices = [_currentPageIndex];
    } else if (selectedScope == 1) {
      targetIndices = List.generate(_pages.length, (i) => i);
    } else {
      final s = (startPage - 1).clamp(0, _pages.length - 1);
      final e = (endPage - 1).clamp(s, _pages.length - 1);
      targetIndices = [for (int i = s; i <= e; i++) i];
    }

    // Show Progress Dialog
    void Function(int)? progressUpdater;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setProgressState) {
          int currentStep = 0;
          progressUpdater = (step) {
            setProgressState(() => currentStep = step);
          };
          return AlertDialog(
            title: const Text('Recognizing Text...'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: targetIndices.isNotEmpty ? (currentStep / targetIndices.length) : null,
                ),
                const SizedBox(height: 16),
                Text('Processing page ${currentStep + 1} of ${targetIndices.length}...'),
              ],
            ),
          );
        },
      ),
    );

    for (int i = 0; i < targetIndices.length; i++) {
      final idx = targetIndices[i];
      final page = _pages[idx];
      progressUpdater?.call(i);
      try {
        final ocrResult = await _ocrService.recognizeText(page.imagePath);
        if (mounted) {
          setState(() {
            _pages[idx].ocrText = ocrResult.fullText;
            _pages[idx].ocrResult = ocrResult;
          });
        }
      } catch (e) {
        // Skip errors for blank pages
      }
    }

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // Dismiss progress dialog
      _showSnackbar('OCR completed for ${targetIndices.length} page(s). Selectable text layer active in PDF.');
      _openOcrSheetForPage(_currentPageIndex);
    }
  }

  void _openOcrSheetForPage(int pageIdx) {
    if (_pages.isEmpty) return;
    final clampedIdx = pageIdx.clamp(0, _pages.length - 1);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return _OcrBottomSheet(
          pages: _pages,
          initialPageIndex: clampedIdx,
          onPageSaved: (idx, text, result) {
            setState(() {
              _pages[idx].ocrText = text;
              if (result != null) {
                _pages[idx].ocrResult = result;
              }
            });
            _showSnackbar('OCR text saved for Page ${idx + 1}');
          },
          onPageChanged: (idx) {
            _jumpToPage(idx);
          },
        );
      },
    );
  }

  // --- PDF Export ---

  Future<void> _convertToPdf() async {
    if (_pages.isEmpty) {
      _showSnackbar('Please add at least one page.');
      return;
    }

    if (_enablePassword && _passwordController.text.trim().isEmpty) {
      _showSnackbar('Please enter a password for the protected PDF.');
      return;
    }

    setState(() {
      _isConverting = true;
      _convertProgress = 0.0;
    });

    try {
      final docDir = await getApplicationDocumentsDirectory();
      String rawName = _pdfNameController.text.trim();
      if (!rawName.toLowerCase().endsWith('.pdf')) {
        rawName = '$rawName.pdf';
      }
      final outPath = p.join(docDir.path, rawName);

      // Pre-process images with their final filter/adjust/rotation settings (using cropped imagePath)
      final processedPaths = <String>[];
      for (int i = 0; i < _pages.length; i++) {
        final page = _pages[i];
        final enhancedPath = await _enhancer.processImage(
          sourcePath: page.imagePath,
          filter: page.filter,
          brightness: page.brightness,
          contrast: page.contrast,
          rotationDegrees: page.rotationDegrees,
        );
        processedPaths.add(enhancedPath);
        if (mounted) {
          setState(() => _convertProgress = (i + 1) / (_pages.length * 2));
        }
      }

      final options = ImageToPdfOptions(
        preset: _selectedPreset,
        margin: _margin,
        quality: _quality,
        password: _enablePassword ? _passwordController.text.trim() : null,
        includeOcrTranscript: _includeOcrTranscript,
      );

      final pageTexts = _pages.map((p) => p.ocrText).toList();
      final pageOcrResults = _pages.map((p) => p.ocrResult).toList();

      await _pdfTools.convertImagesToPdf(
        imagePaths: processedPaths,
        outputPath: outPath,
        pageTexts: pageTexts,
        pageOcrResults: pageOcrResults,
        options: options,
        onProgress: (cur, tot) {
          if (mounted) {
            setState(() => _convertProgress = 0.5 + (cur / tot) * 0.5);
          }
        },
      );

      // Clean up intermediate enhanced image files
      for (final p in processedPaths) {
        try {
          final f = File(p);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }

      await _documentService.addFile(outPath, isNew: true);

      if (mounted) {
        setState(() => _isConverting = false);
        _showSuccessDialog(outPath);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConverting = false);
        _showSnackbar('Conversion failed: $e');
      }
    }
  }

  void _showSuccessDialog(String pdfPath) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('PDF Created!'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('File saved successfully:'),
            const SizedBox(height: 4),
            Text(
              p.basename(pdfPath),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '${_pages.length} pages • ${_pages.where((p) => p.ocrText != null).length} with OCR text',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Share.shareXFiles([XFile(pdfPath)]);
            },
            child: const Text('Share'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _cleanupAllPages();
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => PdfViewerScreen(
                    filePath: pdfPath,
                    fileName: p.basename(pdfPath),
                    password: _enablePassword ? _passwordController.text.trim() : null,
                  ),
                ),
              );
            },
            child: const Text('Open PDF'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _cleanupAllPages();
              Navigator.pop(context);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('Page & Export Settings'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Page Format:', style: TextStyle(fontWeight: FontWeight.bold)),
                  DropdownButton<PageFitPreset>(
                    value: _selectedPreset,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: PageFitPreset.a4Portrait,
                        child: Text('A4 Portrait (Standard Document)'),
                      ),
                      DropdownMenuItem(
                        value: PageFitPreset.a4Landscape,
                        child: Text('A4 Landscape'),
                      ),
                      DropdownMenuItem(
                        value: PageFitPreset.letterPortrait,
                        child: Text('US Letter Portrait'),
                      ),
                      DropdownMenuItem(
                        value: PageFitPreset.fitImage,
                        child: Text('Fit to Image Ratio'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => _selectedPreset = val);
                        setState(() => _selectedPreset = val);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text('Margin:', style: TextStyle(fontWeight: FontWeight.bold)),
                  DropdownButton<double>(
                    value: _margin,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 0.0, child: Text('No Margin (Full Bleed)')),
                      DropdownMenuItem(value: 18.0, child: Text('Standard (18 pt)')),
                      DropdownMenuItem(value: 36.0, child: Text('Wide (36 pt)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => _margin = val);
                        setState(() => _margin = val);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text('Compression Quality:', style: TextStyle(fontWeight: FontWeight.bold)),
                  DropdownButton<ImageCompressionQuality>(
                    value: _quality,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: ImageCompressionQuality.original,
                        child: Text('Original (No Re-encoding)'),
                      ),
                      DropdownMenuItem(
                        value: ImageCompressionQuality.high,
                        child: Text('High Quality (90%)'),
                      ),
                      DropdownMenuItem(
                        value: ImageCompressionQuality.medium,
                        child: Text('Medium Quality (75%)'),
                      ),
                      DropdownMenuItem(
                        value: ImageCompressionQuality.low,
                        child: Text('Low Quality (50% Smallest Size)'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => _quality = val);
                        setState(() => _quality = val);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Include OCR Transcript Page'),
                    subtitle: const Text('Appends clean text pages with recognized OCR text in the PDF', style: TextStyle(fontSize: 11)),
                    value: _includeOcrTranscript,
                    onChanged: (val) {
                      setDialogState(() => _includeOcrTranscript = val);
                      setState(() => _includeOcrTranscript = val);
                    },
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Password Protection'),
                    value: _enablePassword,
                    onChanged: (val) {
                      setDialogState(() => _enablePassword = val);
                      setState(() => _enablePassword = val);
                    },
                  ),
                  if (_enablePassword)
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Enter PDF Password',
                        hintText: 'Password to open PDF',
                        border: OutlineInputBorder(),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showSnackbar(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  // --- Main Build ---

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isTablet = MediaQuery.of(context).size.width >= 720;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _onBackRequested();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _onBackRequested,
          ),
          title: TextField(
            controller: _pdfNameController,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: 'Document Name',
              hintStyle: TextStyle(color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
            ),
          ),
          actions: [
            if (_pages.isNotEmpty)
              IconButton(
                icon: Icon(_isGridView ? Icons.view_carousel : Icons.grid_view),
                tooltip: _isGridView ? 'Modify Single Page' : 'View All Pages Grid',
                onPressed: () {
                  setState(() {
                    _isGridView = !_isGridView;
                    _activeTool = _ModifyTool.none;
                  });
                },
              ),
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'PDF Export Settings',
              onPressed: _showSettingsDialog,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              // Progress Bar
              if (_isConverting)
                LinearProgressIndicator(value: _convertProgress, color: colorScheme.primary),

              // Content Area
              Expanded(
                child: _pages.isEmpty
                    ? _buildEmptyState()
                    : _isGridView
                        ? _buildGridView(isTablet)
                        : _buildSinglePageModifyView(isTablet),
              ),

              // Active Tool Adjuster Drawer / Bar
              if (!_isGridView && _pages.isNotEmpty) ...[
                if (_activeTool == _ModifyTool.crop) _buildCropControlBar(),
                if (_activeTool == _ModifyTool.filters) _buildFilterControlBar(),
                if (_activeTool == _ModifyTool.adjust) _buildAdjustControlBar(),
                _buildBottomModifyStrip(),
              ],

              // Bottom Global CTA Bar
              _buildGlobalBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.document_scanner_outlined, size: 72, color: colorScheme.primary),
            ),
            const SizedBox(height: 20),
            Text(
              'No Pages Added Yet',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Capture documents with Camera or select from Gallery\nto crop, filter, adjust, extract OCR text, and generate PDF',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _captureFromCamera,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: _pickFromGallery,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridView(bool isTablet) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ReorderableListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _pages.length,
      onReorder: (oldIdx, newIdx) {
        setState(() {
          if (newIdx > oldIdx) newIdx--;
          final item = _pages.removeAt(oldIdx);
          _pages.insert(newIdx, item);
        });
      },
      itemBuilder: (context, index) {
        final page = _pages[index];
        final isSelected = index == _currentPageIndex;

        return Card(
          key: ValueKey(page.id),
          color: isSelected ? colorScheme.primaryContainer.withValues(alpha: 0.6) : colorScheme.surfaceContainer,
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: RotatedBox(
                quarterTurns: (page.rotationDegrees ~/ 90) % 4,
                child: ColorFiltered(
                  colorFilter: ImageEnhancementService.getColorFilter(
                    page.filter,
                    brightness: page.brightness,
                    contrast: page.contrast,
                  ),
                  child: Image.file(
                    File(page.originalImagePath),
                    width: 48,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            title: Text('Page ${index + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              '${page.filter.label} • Rot: ${page.rotationDegrees}°${page.ocrText != null ? ' • OCR' : ''}',
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Modify Page',
                  onPressed: () {
                    setState(() {
                      _currentPageIndex = index;
                      _isGridView = false;
                    });
                  },
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: colorScheme.error),
                  onPressed: () {
                    final removed = _pages.removeAt(index);
                    _cleanupPageFiles(removed);
                    setState(() {
                      if (_currentPageIndex >= _pages.length && _pages.isNotEmpty) {
                        _currentPageIndex = _pages.length - 1;
                      }
                    });
                  },
                ),
                const Icon(Icons.drag_handle),
              ],
            ),
            onTap: () {
              setState(() {
                _currentPageIndex = index;
                _isGridView = false;
              });
            },
          ),
        );
      },
    );
  }

  void _jumpToPage(int index) {
    if (index >= 0 && index < _pages.length) {
      setState(() {
        _currentPageIndex = index;
      });
      if (_pageController.hasClients && _pageController.page?.round() != index) {
        _pageController.jumpToPage(index);
      }
    }
  }

  Widget _buildSinglePageModifyView(bool isTablet) {
    if (_pages.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Page Navigation Header "Page X of Y"
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _currentPageIndex > 0
                    ? () {
                        _pageController.previousPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                        );
                      }
                    : null,
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colorScheme.outlineVariant, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Page ${_currentPageIndex + 1} of ${_pages.length}',
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    if (_currentPage?.ocrText != null && _currentPage!.ocrText!.trim().isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle, size: 14, color: colorScheme.primary),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _currentPageIndex < _pages.length - 1
                    ? () {
                        _pageController.nextPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                        );
                      }
                    : null,
              ),
            ],
          ),
        ),

        // Horizontal Swipeable Canvas with PageView
        Expanded(
          child: Container(
            margin: EdgeInsets.symmetric(
              horizontal: isTablet ? 64 : 12,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: PageView.builder(
                controller: _pageController,
                physics: _activeTool == _ModifyTool.crop
                    ? const NeverScrollableScrollPhysics() // Disable swipe during crop adjustment
                    : const BouncingScrollPhysics(),
                itemCount: _pages.length,
                onPageChanged: (idx) {
                  setState(() {
                    _currentPageIndex = idx;
                  });
                },
                itemBuilder: (context, index) {
                  final page = _pages[index];

                  if (_activeTool == _ModifyTool.crop && index == _currentPageIndex) {
                    if (_isProcessingCrop) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return InteractiveCropView(
                      imageFile: File(page.imagePath),
                      initialQuad: _tempCropQuad ?? page.cropQuad,
                      onQuadChanged: (quad) => _tempCropQuad = quad,
                    );
                  }

                  final bool hasOcr = (page.ocrText != null && page.ocrText!.trim().isNotEmpty) ||
                      (page.ocrResult != null && page.ocrResult!.hasText);

                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: InteractiveViewer(
                          maxScale: 4.0,
                          child: RotatedBox(
                            quarterTurns: (page.rotationDegrees ~/ 90) % 4,
                            child: ColorFiltered(
                              colorFilter: ImageEnhancementService.getColorFilter(
                                page.filter,
                                brightness: page.brightness,
                                contrast: page.contrast,
                              ),
                              child: Image.file(
                                File(page.imagePath),
                                key: ValueKey(page.imagePath),
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (hasOcr)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _openOcrSheetForPage(index),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: colorScheme.primary.withValues(alpha: 0.8),
                                    width: 1.2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.15),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.check_circle, size: 14, color: colorScheme.primary),
                                    const SizedBox(width: 4),
                                    Text(
                                      'OCR Ready',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- Tool Control Bars ---

  Widget _buildCropControlBar() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.filter_center_focus, size: 16),
              label: const Text('Auto-detect'),
              onPressed: _autoDetectCrop,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.crop_free, size: 16),
              label: const Text('No crop'),
              onPressed: _noCrop,
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: _isProcessingCrop
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check, size: 16),
              label: const Text('Apply'),
              onPressed: _isProcessingCrop ? null : _applyCrop,
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
              onPressed: () => setState(() => _activeTool = _ModifyTool.none),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterControlBar() {
    final page = _currentPage;
    final currentFilter = page?.filter ?? ScanFilterType.original;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surfaceContainer,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Apply to all pages toggle
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('Filters', style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('Apply to all pages', style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
                const SizedBox(width: 8),
                Switch(
                  value: _applyToAllPages,
                  onChanged: (val) => _toggleApplyToAll(val),
                ),
                IconButton(
                  icon: Icon(Icons.check, color: colorScheme.primary),
                  onPressed: () => setState(() => _activeTool = _ModifyTool.none),
                ),
              ],
            ),
          ),
          // 9 Filters Carousel with instant GPU ColorFilter thumbnails
          SizedBox(
            height: 95,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: ScanFilterType.values.length,
              itemBuilder: (context, index) {
                final filter = ScanFilterType.values[index];
                final isSelected = filter == currentFilter;

                return GestureDetector(
                  onTap: () => _selectFilter(filter),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 76,
                    child: Column(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: isSelected ? colorScheme.primary : colorScheme.outlineVariant,
                              width: isSelected ? 3.0 : 1.0,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            color: colorScheme.surfaceContainerLowest,
                          ),
                          child: Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: ColorFiltered(
                                  colorFilter: ImageEnhancementService.getColorFilter(filter),
                                  child: Image.file(
                                    File(page?.imagePath ?? ''),
                                    fit: BoxFit.cover,
                                    width: 60,
                                    height: 60,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.photo, size: 24),
                                  ),
                                ),
                              ),
                              if (isSelected)
                                Positioned(
                                  top: 3,
                                  right: 3,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.check, size: 10, color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          filter.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdjustControlBar() {
    final page = _currentPage;
    final bVal = page?.brightness ?? 0;
    final cVal = page?.contrast ?? 0;
    final currentVal = _activeAdjustType == _AdjustType.brightness ? bVal : cVal;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Sub-tabs: Brightness / Contrast
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ChoiceChip(
                avatar: const Icon(Icons.wb_sunny_outlined, size: 16),
                label: const Text('Brightness'),
                selected: _activeAdjustType == _AdjustType.brightness,
                onSelected: (_) => setState(() => _activeAdjustType = _AdjustType.brightness),
              ),
              const SizedBox(width: 16),
              ChoiceChip(
                avatar: const Icon(Icons.contrast, size: 16),
                label: const Text('Contrast'),
                selected: _activeAdjustType == _AdjustType.contrast,
                onSelected: (_) => setState(() => _activeAdjustType = _AdjustType.contrast),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.check, color: colorScheme.primary),
                onPressed: () => setState(() => _activeTool = _ModifyTool.none),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Slider & Value Label (-100 to +100)
          Row(
            children: [
              Text(
                _activeAdjustType == _AdjustType.brightness ? 'Brightness' : 'Contrast',
                style: TextStyle(color: colorScheme.onSurface, fontSize: 13),
              ),
              const Spacer(),
              Text(
                '$currentVal',
                style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
          Slider(
            value: currentVal.toDouble(),
            min: -100,
            max: 100,
            divisions: 40,
            label: '$currentVal',
            onChanged: (val) {
              final intVal = val.round();
              if (_activeAdjustType == _AdjustType.brightness) {
                _updateAdjustment(brightness: intVal);
              } else {
                _updateAdjustment(contrast: intVal);
              }
            },
          ),

          // Apply to all pages switch
          Row(
            children: [
              Text('Apply to all pages', style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
              const Spacer(),
              Switch(
                value: _applyToAllPages,
                onChanged: (val) => setState(() => _applyToAllPages = val),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Bottom Tool Strip (Crop, Rotate, OCR, Filters, Adjust, Delete) ---

  Widget _buildBottomModifyStrip() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildToolItem(
              icon: Icons.add_photo_alternate_outlined,
              label: 'Add Page',
              isActive: false,
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  builder: (ctx) => SafeArea(
                    child: Wrap(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.camera_alt),
                          title: const Text('Take Photo with Camera'),
                          onTap: () {
                            Navigator.pop(ctx);
                            _captureFromCamera();
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.photo_library),
                          title: const Text('Pick from Gallery'),
                          onTap: () {
                            Navigator.pop(ctx);
                            _pickFromGallery();
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            _buildToolItem(
              icon: Icons.crop,
              label: 'Crop',
              isActive: _activeTool == _ModifyTool.crop,
              onTap: _startCrop,
            ),
            _buildToolItem(
              icon: Icons.rotate_right,
              label: 'Rotate',
              isActive: false,
              onTap: _rotateCurrentPage,
            ),
            _buildToolItem(
              icon: Icons.document_scanner,
              label: 'OCR Text',
              isActive: _currentPage?.ocrText != null,
              onTap: _showOcrOptions,
            ),
            _buildToolItem(
              icon: Icons.photo_filter,
              label: 'Filters',
              isActive: _activeTool == _ModifyTool.filters || (_currentPage?.filter != ScanFilterType.original),
              onTap: () => setState(() => _activeTool = _ModifyTool.filters),
            ),
            _buildToolItem(
              icon: Icons.tune,
              label: 'Adjust',
              isActive: _activeTool == _ModifyTool.adjust || ((_currentPage?.brightness ?? 0) != 0 || (_currentPage?.contrast ?? 0) != 0),
              onTap: () => setState(() => _activeTool = _ModifyTool.adjust),
            ),
            _buildToolItem(
              icon: Icons.delete_outline,
              label: 'Delete',
              isActive: false,
              color: colorScheme.error,
              onTap: _deleteCurrentPage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolItem({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
    Color? color,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeColor = color ?? colorScheme.primary;
    final itemColor = isActive ? activeColor : (color ?? colorScheme.onSurface);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: isActive
            ? BoxDecoration(
                color: activeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: itemColor),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: itemColor,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Bottom Global Action Bar ("Add Pages" & "Create PDF") ---

  Widget _buildGlobalBottomBar() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _isConverting ? null : _pickFromGallery,
            icon: const Icon(Icons.add),
            label: const Text('Add Pages'),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: (_isConverting || _pages.isEmpty) ? null : _convertToPdf,
            icon: const Icon(Icons.picture_as_pdf),
            label: Text(_pages.isEmpty ? 'Save PDF' : 'Save PDF (${_pages.length})'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal Bottom Sheet for OCR text recognition, multi-page navigation, editing, and copying
class _OcrBottomSheet extends StatefulWidget {
  final List<ScannedPage> pages;
  final int initialPageIndex;
  final void Function(int pageIndex, String text, OcrResult? ocrResult) onPageSaved;
  final ValueChanged<int>? onPageChanged;

  const _OcrBottomSheet({
    required this.pages,
    required this.initialPageIndex,
    required this.onPageSaved,
    this.onPageChanged,
  });

  @override
  State<_OcrBottomSheet> createState() => _OcrBottomSheetState();
}

class _OcrBottomSheetState extends State<_OcrBottomSheet> {
  final OcrService _ocrService = OcrService();
  final TextEditingController _textController = TextEditingController();
  late int _currentPageIndex;
  bool _isLoading = false;
  int _wordCount = 0;
  final Map<int, OcrResult> _cachedResults = {};

  @override
  void initState() {
    super.initState();
    _currentPageIndex = widget.initialPageIndex.clamp(0, widget.pages.length - 1);
    for (int i = 0; i < widget.pages.length; i++) {
      if (widget.pages[i].ocrResult != null) {
        _cachedResults[i] = widget.pages[i].ocrResult!;
      }
    }
    _loadPageOcr(_currentPageIndex);
  }

  void _loadPageOcr(int pageIdx) {
    if (pageIdx < 0 || pageIdx >= widget.pages.length) return;
    final page = widget.pages[pageIdx];

    if (page.ocrText != null && page.ocrText!.isNotEmpty) {
      _textController.text = page.ocrText!;
      _isLoading = false;
      _updateWordCount();
    } else if (_cachedResults[pageIdx]?.hasText == true) {
      _textController.text = _cachedResults[pageIdx]!.fullText;
      _isLoading = false;
      _updateWordCount();
    } else {
      _performOcrForPage(pageIdx);
    }
  }

  void _saveCurrentPageText() {
    if (_currentPageIndex >= 0 && _currentPageIndex < widget.pages.length) {
      final text = _textController.text.trim();
      final res = _cachedResults[_currentPageIndex];
      widget.onPageSaved(_currentPageIndex, text, res);
    }
  }

  void _switchPage(int newIdx) {
    if (newIdx == _currentPageIndex || newIdx < 0 || newIdx >= widget.pages.length) return;
    _saveCurrentPageText();
    setState(() {
      _currentPageIndex = newIdx;
    });
    widget.onPageChanged?.call(newIdx);
    _loadPageOcr(newIdx);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _updateWordCount() {
    final text = _textController.text.trim();
    setState(() {
      _wordCount = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
    });
  }

  Future<void> _performOcrForPage(int pageIdx) async {
    if (pageIdx < 0 || pageIdx >= widget.pages.length) return;
    setState(() => _isLoading = true);
    final result = await _ocrService.recognizeText(widget.pages[pageIdx].imagePath);
    if (mounted) {
      setState(() {
        _cachedResults[pageIdx] = result;
        if (pageIdx == _currentPageIndex) {
          _textController.text = result.fullText;
          _isLoading = false;
          _updateWordCount();
        }
      });
      widget.onPageSaved(pageIdx, result.fullText, result);
    }
  }

  Future<void> _performOcrForAllPages() async {
    setState(() => _isLoading = true);
    for (int i = 0; i < widget.pages.length; i++) {
      try {
        final result = await _ocrService.recognizeText(widget.pages[i].imagePath);
        _cachedResults[i] = result;
        widget.onPageSaved(i, result.fullText, result);
      } catch (_) {}
    }
    if (mounted) {
      final currentRes = _cachedResults[_currentPageIndex];
      setState(() {
        _textController.text = currentRes?.fullText ?? widget.pages[_currentPageIndex].ocrText ?? '';
        _isLoading = false;
        _updateWordCount();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final totalPages = widget.pages.length;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.document_scanner, color: colorScheme.primary),
              const SizedBox(width: 8),
              const Text(
                'On-Device OCR Text Extraction',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  _saveCurrentPageText();
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Extracted text creates an invisible, searchable Sandwich PDF layer and transcript page.',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),

          // Multi-page navigation bar
          if (totalPages > 1) ...[
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  visualDensity: VisualDensity.compact,
                  onPressed: _currentPageIndex > 0 ? () => _switchPage(_currentPageIndex - 1) : null,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Page ${_currentPageIndex + 1} of $totalPages',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  visualDensity: VisualDensity.compact,
                  onPressed: _currentPageIndex < totalPages - 1 ? () => _switchPage(_currentPageIndex + 1) : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: List.generate(totalPages, (i) {
                        final hasText = (widget.pages[i].ocrText != null && widget.pages[i].ocrText!.isNotEmpty) ||
                            (_cachedResults[i]?.hasText == true);
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            selected: _currentPageIndex == i,
                            label: Text('P${i + 1}${hasText ? ' ✓' : ''}'),
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => _switchPage(i),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],

          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Recognizing text with on-device ML Kit...'),
                  ],
                ),
              ),
            )
          else ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Chip(
                    label: Text('$_wordCount Words'),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 6),
                  Chip(
                    label: Text('${_textController.text.length} Chars'),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Re-run Page'),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => _performOcrForPage(_currentPageIndex),
                  ),
                  if (totalPages > 1) ...[
                    const SizedBox(width: 4),
                    TextButton.icon(
                      icon: const Icon(Icons.all_inclusive, size: 16),
                      label: const Text('OCR All'),
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: _performOcrForAllPages,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                border: Border.all(color: colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _textController,
                maxLines: null,
                onChanged: (_) => _updateWordCount(),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.all(12),
                  border: InputBorder.none,
                  hintText: 'No text recognized on this page',
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                  onPressed: _textController.text.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: _textController.text));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Text copied to clipboard')),
                          );
                        },
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.share, size: 16),
                  label: const Text('Share'),
                  onPressed: _textController.text.isEmpty
                      ? null
                      : () {
                          Share.share(_textController.text);
                        },
                ),
                const Spacer(),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Save OCR Text'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                  ),
                  onPressed: () {
                    _saveCurrentPageText();
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}
