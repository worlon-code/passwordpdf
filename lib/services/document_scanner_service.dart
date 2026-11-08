import 'dart:io';
import 'dart:ui' show Rect, Offset;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'image_enhancement_service.dart';
import 'ocr_service.dart';

/// Item representing a scanned or imported document page with non-destructive enhancement metadata
class ScannedPage {
  final String id;
  final String originalImagePath;
  String imagePath;
  int rotationDegrees; // 0, 90, 180, 270
  ScanFilterType filter;
  int brightness; // -100 to 100
  int contrast; // -100 to 100
  Rect? cropRect; // Normalized 0.0 to 1.0
  List<Offset>? cropQuad; // 4 normalized points: [tl, tr, br, bl]
  String? ocrText;
  OcrResult? ocrResult; // Structured lines with exact pixel bounding boxes

  ScannedPage({
    required this.id,
    required this.originalImagePath,
    required this.imagePath,
    this.rotationDegrees = 0,
    this.filter = ScanFilterType.original,
    this.brightness = 0,
    this.contrast = 0,
    this.cropRect,
    this.cropQuad,
    this.ocrText,
    this.ocrResult,
  });

  ScannedPage copyWith({
    String? id,
    String? originalImagePath,
    String? imagePath,
    int? rotationDegrees,
    ScanFilterType? filter,
    int? brightness,
    int? contrast,
    Rect? cropRect,
    List<Offset>? cropQuad,
    bool clearCrop = false,
    String? ocrText,
    OcrResult? ocrResult,
  }) {
    return ScannedPage(
      id: id ?? this.id,
      originalImagePath: originalImagePath ?? this.originalImagePath,
      imagePath: imagePath ?? this.imagePath,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      filter: filter ?? this.filter,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      cropRect: clearCrop ? null : (cropRect ?? this.cropRect),
      cropQuad: clearCrop ? null : (cropQuad ?? this.cropQuad),
      ocrText: ocrText ?? this.ocrText,
      ocrResult: ocrResult ?? this.ocrResult,
    );
  }
}

/// Service for capturing and preparing images for PDF conversion
class DocumentScannerService {
  static final DocumentScannerService _instance = DocumentScannerService._internal();
  factory DocumentScannerService() => _instance;
  DocumentScannerService._internal();

  final ImagePicker _picker = ImagePicker();
  final ImageEnhancementService _enhancer = ImageEnhancementService();

  /// Capture image using device camera
  Future<ScannedPage?> captureFromCamera() async {
    final XFile? photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 95,
    );
    if (photo == null) return null;

    final tempDir = await getTemporaryDirectory();
    final targetPath = p.join(
      tempDir.path,
      'scan_orig_${DateTime.now().millisecondsSinceEpoch}_${p.basename(photo.path)}',
    );
    await File(photo.path).copy(targetPath);

    return ScannedPage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      originalImagePath: targetPath,
      imagePath: targetPath,
    );
  }

  /// Pick multiple images from photo gallery
  Future<List<ScannedPage>> pickFromGallery() async {
    final List<XFile> images = await _picker.pickMultiImage(imageQuality: 95);
    if (images.isEmpty) return [];

    final tempDir = await getTemporaryDirectory();
    final pages = <ScannedPage>[];

    for (int i = 0; i < images.length; i++) {
      final imgFile = images[i];
      final targetPath = p.join(
        tempDir.path,
        'gallery_orig_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
      );
      await File(imgFile.path).copy(targetPath);
      pages.add(
        ScannedPage(
          id: '${DateTime.now().microsecondsSinceEpoch}_$i',
          originalImagePath: targetPath,
          imagePath: targetPath,
        ),
      );
    }

    return pages;
  }

  /// Rotate image 90 degrees clockwise and reprocess
  Future<ScannedPage> rotatePage(ScannedPage page) async {
    final nextRotation = (page.rotationDegrees + 90) % 360;
    return reprocessPage(page.copyWith(rotationDegrees: nextRotation));
  }

  /// Reprocess page from original raw file using its current settings
  Future<ScannedPage> reprocessPage(ScannedPage page) async {
    final newPath = await _enhancer.processImage(
      sourcePath: page.originalImagePath,
      filter: page.filter,
      brightness: page.brightness,
      contrast: page.contrast,
      cropNormalizedRect: page.cropRect,
      rotationDegrees: page.rotationDegrees,
    );

    return page.copyWith(imagePath: newPath);
  }
}
