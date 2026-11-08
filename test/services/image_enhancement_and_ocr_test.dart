import 'dart:io';
import 'dart:ui' show Rect, ColorFilter;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:passwordpdf_manager/services/document_scanner_service.dart';
import 'package:passwordpdf_manager/services/image_enhancement_service.dart';
import 'package:passwordpdf_manager/services/ocr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return Directory.systemTemp.path;
      },
    );
  });

  group('ScanFilterType Verification', () {
    test('contains all 9 Adobe Scan-compatible filters with proper labels', () {
      expect(ScanFilterType.values.length, 9);
      expect(ScanFilterType.original.label, 'Original color');
      expect(ScanFilterType.autoColor.label, 'Auto-color');
      expect(ScanFilterType.vintage.label, 'Vintage look');
      expect(ScanFilterType.lightText.label, 'Light text');
      expect(ScanFilterType.crumpled.label, 'Crumpled');
      expect(ScanFilterType.warm.label, 'Warm color');
      expect(ScanFilterType.cool.label, 'Cool color');
      expect(ScanFilterType.grayscale.label, 'Grayscale');
      expect(ScanFilterType.whiteboard.label, 'Whiteboard');
    });
  });

  group('ScannedPage Model Verification', () {
    test('default properties and copyWith work as expected', () {
      final page = ScannedPage(
        id: 'test_1',
        originalImagePath: '/tmp/test_orig.jpg',
        imagePath: '/tmp/test_orig.jpg',
      );

      expect(page.filter, ScanFilterType.original);
      expect(page.brightness, 0);
      expect(page.contrast, 0);
      expect(page.cropRect, isNull);
      expect(page.ocrText, isNull);
      expect(page.rotationDegrees, 0);

      final updated = page.copyWith(
        filter: ScanFilterType.whiteboard,
        brightness: 15,
        contrast: 25,
        cropRect: const Rect.fromLTWH(0.1, 0.1, 0.8, 0.8),
        ocrText: 'Recognized test string',
        rotationDegrees: 90,
      );

      expect(updated.filter, ScanFilterType.whiteboard);
      expect(updated.brightness, 15);
      expect(updated.contrast, 25);
      expect(updated.cropRect, const Rect.fromLTWH(0.1, 0.1, 0.8, 0.8));
      expect(updated.ocrText, 'Recognized test string');
      expect(updated.rotationDegrees, 90);

      final clearedCrop = updated.copyWith(clearCrop: true);
      expect(clearedCrop.cropRect, isNull);
    });
  });

  group('OcrResult Model Verification', () {
    test('empty factory creates empty non-text container', () {
      final empty = OcrResult.empty();
      expect(empty.fullText, '');
      expect(empty.lines, isEmpty);
      expect(empty.blockCount, 0);
      expect(empty.hasText, isFalse);
    });

    test('populated result correctly exposes lines and flags', () {
      const res = OcrResult(
        fullText: 'Hello\nWorld',
        lines: ['Hello', 'World'],
        blockCount: 1,
        hasText: true,
      );
      expect(res.hasText, isTrue);
      expect(res.lines.length, 2);
      expect(res.fullText, 'Hello\nWorld');
    });
  });

  group('Image Processing & Filters Unit Verification', () {
    late Directory tempDir;
    late String testImagePath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('img_test_');
      final image = img.Image(width: 100, height: 100);
      // Fill with test gradient/pixels
      for (int y = 0; y < 100; y++) {
        for (int x = 0; x < 100; x++) {
          image.setPixelRgb(x, y, (x * 2) % 256, (y * 2) % 256, 128);
        }
      }
      testImagePath = '${tempDir.path}/sample.jpg';
      File(testImagePath).writeAsBytesSync(img.encodeJpg(image));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('processes image with filter and brightness/contrast without error', () async {
      final service = ImageEnhancementService();

      final targetPath = '${tempDir.path}/out_auto.jpg';
      final res = await service.processImage(
        sourcePath: testImagePath,
        filter: ScanFilterType.autoColor,
        brightness: 10,
        contrast: 15,
        customTargetPath: targetPath,
      );

      expect(File(res).existsSync(), isTrue);
      final decoded = img.decodeImage(File(res).readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, 100);
      expect(decoded.height, 100);
    });

    test('processes image with crop normalized bounds', () async {
      final service = ImageEnhancementService();

      final targetPath = '${tempDir.path}/out_crop.jpg';
      final res = await service.processImage(
        sourcePath: testImagePath,
        cropNormalizedRect: const Rect.fromLTWH(0.2, 0.2, 0.5, 0.5),
        customTargetPath: targetPath,
      );

      expect(File(res).existsSync(), isTrue);
      final decoded = img.decodeImage(File(res).readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, 50);
      expect(decoded.height, 50);
    });

    test('detectDocumentBounds returns valid normalized bounds', () async {
      final service = ImageEnhancementService();
      final bounds = await service.detectDocumentBounds(testImagePath);

      expect(bounds.left, greaterThanOrEqualTo(0.0));
      expect(bounds.top, greaterThanOrEqualTo(0.0));
      expect(bounds.right, lessThanOrEqualTo(1.0));
      expect(bounds.bottom, lessThanOrEqualTo(1.0));
      expect(bounds.width, greaterThan(0.2));
      expect(bounds.height, greaterThan(0.2));
    });

    test('getColorFilter produces valid ColorFilter for all 9 filters and adjustments', () {
      for (final filter in ScanFilterType.values) {
        final cf = ImageEnhancementService.getColorFilter(filter, brightness: 20, contrast: -10);
        expect(cf, isA<ColorFilter>());
      }
    });

    test('cropQuadrilateral correctly crops quadrilateral area with bilinear transform', () async {
      final service = ImageEnhancementService();
      final targetPath = '${tempDir.path}/out_quad.jpg';

      final res = await service.cropQuadrilateral(
        sourcePath: testImagePath,
        normalizedQuad: const [
          Offset(0.1, 0.1),
          Offset(0.9, 0.15),
          Offset(0.85, 0.9),
          Offset(0.12, 0.88),
        ],
        customTargetPath: targetPath,
      );

      expect(File(res).existsSync(), isTrue);
      final decoded = img.decodeImage(File(res).readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, greaterThan(30));
      expect(decoded.height, greaterThan(30));
    });
  });
}
