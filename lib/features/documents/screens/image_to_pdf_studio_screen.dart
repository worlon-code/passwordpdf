import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../services/document_scanner_service.dart';
import '../../../services/document_service.dart';
import '../../../services/pdf_tools_service.dart';
import 'pdf_viewer_screen.dart';

/// Studio screen for converting photos / camera scans to PDF documents
class ImageToPdfStudioScreen extends StatefulWidget {
  const ImageToPdfStudioScreen({super.key});

  @override
  State<ImageToPdfStudioScreen> createState() => _ImageToPdfStudioScreenState();
}

class _ImageToPdfStudioScreenState extends State<ImageToPdfStudioScreen> {
  final DocumentScannerService _scanner = DocumentScannerService();
  final PdfToolsService _pdfTools = PdfToolsService();
  final DocumentService _documentService = DocumentService();

  final List<ScannedPage> _pages = [];
  PageFitPreset _selectedPreset = PageFitPreset.a4Portrait;
  double _margin = 18.0;
  ImageCompressionQuality _quality = ImageCompressionQuality.high;
  bool _enablePassword = false;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pdfNameController = TextEditingController();

  bool _isConverting = false;
  double _convertProgress = 0.0;

  @override
  void initState() {
    super.initState();
    final ts = DateTime.now();
    _pdfNameController.text =
        'Scan_${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _pdfNameController.dispose();
    super.dispose();
  }

  Future<void> _captureFromCamera() async {
    try {
      final page = await _scanner.captureFromCamera();
      if (page != null && mounted) {
        setState(() {
          _pages.add(page);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera error: $e')),
        );
      }
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final newPages = await _scanner.pickFromGallery();
      if (newPages.isNotEmpty && mounted) {
        setState(() {
          _pages.addAll(newPages);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gallery error: $e')),
        );
      }
    }
  }

  Future<void> _rotatePage(int index) async {
    final page = _pages[index];
    final rotated = await _scanner.rotatePage(page);
    if (mounted) {
      setState(() {
        _pages[index] = rotated;
      });
    }
  }

  void _removePage(int index) {
    setState(() {
      _pages.removeAt(index);
    });
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

  Future<void> _convertToPdf() async {
    if (_pages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add at least one page.')),
      );
      return;
    }

    if (_enablePassword && _passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a password for the protected PDF.')),
      );
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

      final options = ImageToPdfOptions(
        preset: _selectedPreset,
        margin: _margin,
        quality: _quality,
        password: _enablePassword ? _passwordController.text.trim() : null,
      );

      final imagePaths = _pages.map((p) => p.imagePath).toList();
      await _pdfTools.convertImagesToPdf(
        imagePaths: imagePaths,
        outputPath: outPath,
        options: options,
        onProgress: (cur, tot) {
          if (mounted) {
            setState(() {
              _convertProgress = cur / tot;
            });
          }
        },
      );

      // Register file with DocumentService so it appears in the documents list
      await _documentService.addFile(outPath, isNew: true);

      if (mounted) {
        setState(() => _isConverting = false);
        _showSuccessDialog(outPath);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConverting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Conversion failed: $e')),
        );
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
            Text('File saved successfully:'),
            const SizedBox(height: 4),
            Text(
              p.basename(pdfPath),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Share.shareXFiles([XFile(pdfPath)]);
            },
            child: const Text('Share'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
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
            child: const Text('Open'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context); // Exit studio back to documents
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Images to PDF Studio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Page & Export Settings',
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // Name input and page count header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pdfNameController,
                    decoration: const InputDecoration(
                      labelText: 'PDF Document Name',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  label: Text('${_pages.length} Pages'),
                  avatar: const Icon(Icons.pages, size: 16),
                ),
              ],
            ),
          ),

          if (_isConverting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Column(
                children: [
                  LinearProgressIndicator(value: _convertProgress),
                  const SizedBox(height: 4),
                  Text('Converting: ${(_convertProgress * 100).toInt()}%'),
                ],
              ),
            ),

          // Main Pages Grid / Reorderable
          Expanded(
            child: _pages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.photo_library_outlined, size: 80, color: Colors.grey.shade400),
                        const SizedBox(height: 16),
                        Text(
                          'No images added yet',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: Colors.grey.shade600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Tap Camera or Gallery below to start building your PDF',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _pages.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex--;
                        final item = _pages.removeAt(oldIndex);
                        _pages.insert(newIndex, item);
                      });
                    },
                    itemBuilder: (context, index) {
                      final page = _pages[index];
                      return Card(
                        key: ValueKey(page.id),
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.file(
                              File(page.imagePath),
                              width: 50,
                              height: 65,
                              fit: BoxFit.cover,
                            ),
                          ),
                          title: Text('Page ${index + 1}'),
                          subtitle: Text('Rotation: ${page.rotationDegrees}°'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.rotate_right),
                                tooltip: 'Rotate 90°',
                                onPressed: () => _rotatePage(index),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                tooltip: 'Remove Page',
                                onPressed: () => _removePage(index),
                              ),
                              const Icon(Icons.drag_handle),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Bottom Action Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  offset: const Offset(0, -2),
                  blurRadius: 4,
                ),
              ],
            ),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _isConverting ? null : _captureFromCamera,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _isConverting ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: (_isConverting || _pages.isEmpty) ? null : _convertToPdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Create PDF'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
