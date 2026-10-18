import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Item representing a scanned or imported page
class ScannedPage {
  final String id;
  String imagePath;
  int rotationDegrees; // 0, 90, 180, 270

  ScannedPage({
    required this.id,
    required this.imagePath,
    this.rotationDegrees = 0,
  });

  ScannedPage copyWith({
    String? id,
    String? imagePath,
    int? rotationDegrees,
  }) {
    return ScannedPage(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    );
  }
}

/// Service for capturing and preparing images for PDF conversion
class DocumentScannerService {
  static final DocumentScannerService _instance = DocumentScannerService._internal();
  factory DocumentScannerService() => _instance;
  DocumentScannerService._internal();

  final ImagePicker _picker = ImagePicker();

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
      'scan_${DateTime.now().millisecondsSinceEpoch}_${p.basename(photo.path)}',
    );
    await File(photo.path).copy(targetPath);

    return ScannedPage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
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
        'gallery_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
      );
      await File(imgFile.path).copy(targetPath);
      pages.add(
        ScannedPage(
          id: '${DateTime.now().microsecondsSinceEpoch}_$i',
          imagePath: targetPath,
        ),
      );
    }

    return pages;
  }

  /// Rotate image file 90 degrees clockwise and save to new file
  Future<ScannedPage> rotatePage(ScannedPage page) async {
    final file = File(page.imagePath);
    if (!file.existsSync()) return page;

    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return page;

    final rotated = img.copyRotate(decoded, angle: 90);
    final newBytes = img.encodeJpg(rotated, quality: 95);

    final tempDir = await getTemporaryDirectory();
    final newPath = p.join(
      tempDir.path,
      'rot_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await File(newPath).writeAsBytes(newBytes);

    return page.copyWith(
      imagePath: newPath,
      rotationDegrees: (page.rotationDegrees + 90) % 360,
    );
  }
}
