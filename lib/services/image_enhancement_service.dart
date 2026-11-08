import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect, Offset;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ColorFilter;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Available document scan filters matching Adobe Scan Modify standard
enum ScanFilterType {
  original('Original color'),
  autoColor('Auto-color'),
  vintage('Vintage look'),
  lightText('Light text'),
  crumpled('Crumpled'),
  warm('Warm color'),
  cool('Cool color'),
  grayscale('Grayscale'),
  whiteboard('Whiteboard');

  final String label;
  const ScanFilterType(this.label);
}

/// Service for image cropping, enhancement filters, and brightness/contrast adjustments
class ImageEnhancementService {
  static final ImageEnhancementService _instance = ImageEnhancementService._internal();
  factory ImageEnhancementService() => _instance;
  ImageEnhancementService._internal();

  /// Real-time GPU ColorFilter matrix for instant 60 FPS previews in the UI
  static ColorFilter getColorFilter(
    ScanFilterType filter, {
    int brightness = 0,
    int contrast = 0,
  }) {
    List<double> m;
    switch (filter) {
      case ScanFilterType.original:
        m = [
          1, 0, 0, 0, 0,
          0, 1, 0, 0, 0,
          0, 0, 1, 0, 0,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.autoColor:
        m = [
          1.2, 0, 0, 0, -10,
          0, 1.2, 0, 0, -10,
          0, 0, 1.2, 0, -10,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.vintage:
        m = [
          0.393, 0.769, 0.189, 0, 0,
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.lightText:
        m = [
          1.55, 0, 0, 0, -45,
          0, 1.55, 0, 0, -45,
          0, 0, 1.55, 0, -45,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.crumpled:
        m = [
          1.12, 0, 0, 0, 12,
          0, 1.12, 0, 0, 12,
          0, 0, 1.12, 0, 12,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.warm:
        m = [
          1.1, 0, 0, 0, 20,
          0, 1.05, 0, 0, 8,
          0, 0, 0.88, 0, -18,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.cool:
        m = [
          0.88, 0, 0, 0, -16,
          0, 1.0, 0, 0, 5,
          0, 0, 1.18, 0, 24,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.grayscale:
        m = [
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ];
        break;
      case ScanFilterType.whiteboard:
        m = [
          0.45, 1.35, 0.2, 0, -110,
          0.45, 1.35, 0.2, 0, -110,
          0.45, 1.35, 0.2, 0, -110,
          0, 0, 0, 1, 0,
        ];
        break;
    }

    // Apply brightness (-100..100) -> offset (-128..128)
    if (brightness != 0) {
      final bOffset = (brightness / 100.0) * 128.0;
      m[4] += bOffset;
      m[9] += bOffset;
      m[14] += bOffset;
    }

    // Apply contrast (-100..100)
    if (contrast != 0) {
      final cScale = contrast >= 0 ? 1.0 + (contrast / 100.0) : 1.0 + (contrast / 160.0);
      final cOffset = 128.0 * (1.0 - cScale);

      m[0] *= cScale;
      m[1] *= cScale;
      m[2] *= cScale;
      m[4] = m[4] * cScale + cOffset;

      m[5] *= cScale;
      m[6] *= cScale;
      m[7] *= cScale;
      m[9] = m[9] * cScale + cOffset;

      m[10] *= cScale;
      m[11] *= cScale;
      m[12] *= cScale;
      m[14] = m[14] * cScale + cOffset;
    }

    return ColorFilter.matrix(m);
  }

  /// Process an image with specified crop, rotation, filter, brightness, and contrast
  Future<String> processImage({
    required String sourcePath,
    ScanFilterType filter = ScanFilterType.original,
    int brightness = 0, // -100 to 100
    int contrast = 0, // -100 to 100
    Rect? cropNormalizedRect, // normalized (0.0 to 1.0)
    int rotationDegrees = 0, // 0, 90, 180, 270
    String? customTargetPath,
  }) async {
    return compute(_processImageIsolate, {
      'sourcePath': sourcePath,
      'filterIndex': filter.index,
      'brightness': brightness,
      'contrast': contrast,
      'cropL': cropNormalizedRect?.left,
      'cropT': cropNormalizedRect?.top,
      'cropW': cropNormalizedRect?.width,
      'cropH': cropNormalizedRect?.height,
      'rotationDegrees': rotationDegrees,
      'tempDirPath': customTargetPath != null
          ? p.dirname(customTargetPath)
          : (await getTemporaryDirectory()).path,
    });
  }

  /// Auto-detect document bounding box
  Future<Rect> detectDocumentBounds(String sourcePath) async {
    return compute(_detectDocumentBoundsIsolate, sourcePath);
  }

  /// Crop image using 4 arbitrary normalized quadrilateral points [tl, tr, br, bl]
  Future<String> cropQuadrilateral({
    required String sourcePath,
    required List<Offset> normalizedQuad, // [tl, tr, br, bl]
    String? customTargetPath,
  }) async {
    return compute(_cropQuadrilateralIsolate, {
      'sourcePath': sourcePath,
      'tlX': normalizedQuad[0].dx,
      'tlY': normalizedQuad[0].dy,
      'trX': normalizedQuad[1].dx,
      'trY': normalizedQuad[1].dy,
      'brX': normalizedQuad[2].dx,
      'brY': normalizedQuad[2].dy,
      'blX': normalizedQuad[3].dx,
      'blY': normalizedQuad[3].dy,
      'targetPath': customTargetPath,
      'tempDirPath': customTargetPath != null
          ? p.dirname(customTargetPath)
          : (await getTemporaryDirectory()).path,
    });
  }
}

/// Isolate entrypoint for image processing
Future<String> _processImageIsolate(Map<String, dynamic> params) async {
  final sourcePath = params['sourcePath'] as String;
  final filter = ScanFilterType.values[params['filterIndex'] as int];
  final brightness = params['brightness'] as int;
  final contrast = params['contrast'] as int;
  final rotation = params['rotationDegrees'] as int;
  final customTargetPath = params['targetPath'] as String?;
  final tempDirPath = params['tempDirPath'] as String;

  final double? cropL = params['cropL'] as double?;
  final double? cropT = params['cropT'] as double?;
  final double? cropW = params['cropW'] as double?;
  final double? cropH = params['cropH'] as double?;

  final file = File(sourcePath);
  if (!file.existsSync()) throw Exception('Source file not found: $sourcePath');

  final bytes = await file.readAsBytes();
  img.Image? image = img.decodeImage(bytes);
  if (image == null) throw Exception('Failed to decode image');

  // 1. Rotation if specified
  if (rotation != 0) {
    image = img.copyRotate(image, angle: rotation);
  }

  // 2. Crop if specified and valid
  if (cropL != null && cropT != null && cropW != null && cropH != null) {
    final imgW = image.width;
    final imgH = image.height;

    final x = (cropL * imgW).round().clamp(0, imgW - 1);
    final y = (cropT * imgH).round().clamp(0, imgH - 1);
    final w = (cropW * imgW).round().clamp(1, imgW - x);
    final h = (cropH * imgH).round().clamp(1, imgH - y);

    if (w > 10 && h > 10 && (w < imgW || h < imgH || x > 0 || y > 0)) {
      image = img.copyCrop(image, x: x, y: y, width: w, height: h);
    }
  }

  // 3. Apply Filter
  image = _applyScanFilter(image, filter);

  // 4. Apply Brightness & Contrast adjustments
  if (brightness != 0 || contrast != 0) {
    // brightness: -100..100 -> factor ~ 0.5 .. 1.5
    // contrast: -100..100 -> factor ~ 0.5 .. 2.0
    final bFactor = 1.0 + (brightness / 100.0) * 0.5;
    final cFactor = contrast >= 0 ? 1.0 + (contrast / 100.0) : 1.0 + (contrast / 200.0);

    image = img.adjustColor(
      image,
      brightness: bFactor,
      contrast: cFactor,
    );
  }

  // 5. Save encoded JPEG
  final outPath = customTargetPath ??
      p.join(
        tempDirPath,
        'enhanced_${DateTime.now().millisecondsSinceEpoch}_${p.basename(sourcePath)}',
      );

  final encoded = img.encodeJpg(image, quality: 92);
  await File(outPath).writeAsBytes(encoded);

  return outPath;
}

/// Apply Adobe Scan-style filter to image
img.Image _applyScanFilter(img.Image input, ScanFilterType filter) {
  switch (filter) {
    case ScanFilterType.original:
      return input;

    case ScanFilterType.autoColor:
      // Contrast + slight sharpening & saturation boost for clean text & vivid colors
      return img.adjustColor(
        input,
        contrast: 1.25,
        saturation: 1.15,
        brightness: 1.05,
      );

    case ScanFilterType.vintage:
      // Classic warm sepia / parchment tone
      final sepiaImg = img.sepia(input, amount: 0.65);
      return img.adjustColor(sepiaImg, contrast: 1.1, brightness: 0.98);

    case ScanFilterType.lightText:
      // Boost contrast and deepen dark values to make faint pencil/ink highly legible
      var enhanced = img.adjustColor(input, contrast: 1.45, brightness: 0.95);
      return enhanced;

    case ScanFilterType.crumpled:
      // Flatten shadows & creases: lift shadows slightly and boost midtone contrast
      return img.adjustColor(
        input,
        contrast: 1.18,
        brightness: 1.08,
        gamma: 0.92,
      );

    case ScanFilterType.warm:
      // Warm sunlight / amber temperature shift
      return _applyColorTemperature(input, rOffset: 18, gOffset: 8, bOffset: -14);

    case ScanFilterType.cool:
      // Cool fluorescent / daylight blue temperature shift
      return _applyColorTemperature(input, rOffset: -12, gOffset: 4, bOffset: 22);

    case ScanFilterType.grayscale:
      // Pure clean grayscale
      final gray = img.grayscale(input);
      return img.adjustColor(gray, contrast: 1.2, brightness: 1.02);

    case ScanFilterType.whiteboard:
      // High-contrast clean whiteboard effect: cleans background to white, darkens strokes
      final gray = img.grayscale(input);
      final out = img.Image(width: gray.width, height: gray.height);

      for (int y = 0; y < gray.height; y++) {
        for (int x = 0; x < gray.width; x++) {
          final pixel = gray.getPixel(x, y);
          final lum = pixel.r.toInt(); // In grayscale, r=g=b=luminance

          // Smooth thresholding curve: values > 140 pushed toward 255 (white)
          // values < 110 darkened toward black (crisp strokes)
          int newLum;
          if (lum > 155) {
            newLum = 255;
          } else if (lum < 95) {
            newLum = (lum * 0.7).toInt();
          } else {
            // Linear ramp between 95 and 155
            final t = (lum - 95) / (155 - 95);
            newLum = (66 + t * (255 - 66)).toInt();
          }

          out.setPixelRgb(x, y, newLum, newLum, newLum);
        }
      }
      return out;
  }
}

/// Helper for warm/cool color temperature offset
img.Image _applyColorTemperature(
  img.Image input, {
  required int rOffset,
  required int gOffset,
  required int bOffset,
}) {
  final out = img.Image(width: input.width, height: input.height);

  for (int y = 0; y < input.height; y++) {
    for (int x = 0; x < input.width; x++) {
      final pixel = input.getPixel(x, y);
      final r = (pixel.r + rOffset).clamp(0, 255).toInt();
      final g = (pixel.g + gOffset).clamp(0, 255).toInt();
      final b = (pixel.b + bOffset).clamp(0, 255).toInt();
      out.setPixelRgba(x, y, r, g, b, pixel.a);
    }
  }

  return out;
}


/// Document border auto-detection isolate
Future<Rect> _detectDocumentBoundsIsolate(String sourcePath) async {
  try {
    final file = File(sourcePath);
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return const Rect.fromLTWH(0.04, 0.04, 0.92, 0.92);

    // Downscale for fast edge analysis
    final small = img.copyResize(image, width: 200);
    final gray = img.grayscale(small);

    // Calculate background border luminance estimate
    double borderLumSum = 0;
    int borderCount = 0;
    final w = gray.width;
    final h = gray.height;

    for (int x = 0; x < w; x++) {
      borderLumSum += gray.getPixel(x, 0).r;
      borderLumSum += gray.getPixel(x, h - 1).r;
      borderCount += 2;
    }
    for (int y = 0; y < h; y++) {
      borderLumSum += gray.getPixel(0, y).r;
      borderLumSum += gray.getPixel(w - 1, y).r;
      borderCount += 2;
    }
    final bgLum = borderLumSum / borderCount;

    // Scan inward from each side to detect significant document contrast threshold
    const double threshold = 28.0;
    int left = 0;
    int right = w - 1;
    int top = 0;
    int bottom = h - 1;

    // Scan from top
    for (int y = 0; y < h ~/ 3; y++) {
      double rowDiff = 0;
      for (int x = w ~/ 4; x < 3 * w ~/ 4; x++) {
        rowDiff += (gray.getPixel(x, y).r - bgLum).abs();
      }
      if ((rowDiff / (w ~/ 2)) > threshold) {
        top = math.max(0, y - 2);
        break;
      }
    }

    // Scan from bottom
    for (int y = h - 1; y > 2 * h ~/ 3; y--) {
      double rowDiff = 0;
      for (int x = w ~/ 4; x < 3 * w ~/ 4; x++) {
        rowDiff += (gray.getPixel(x, y).r - bgLum).abs();
      }
      if ((rowDiff / (w ~/ 2)) > threshold) {
        bottom = math.min(h - 1, y + 2);
        break;
      }
    }

    // Scan from left
    for (int x = 0; x < w ~/ 3; x++) {
      double colDiff = 0;
      for (int y = h ~/ 4; y < 3 * h ~/ 4; y++) {
        colDiff += (gray.getPixel(x, y).r - bgLum).abs();
      }
      if ((colDiff / (h ~/ 2)) > threshold) {
        left = math.max(0, x - 2);
        break;
      }
    }

    // Scan from right
    for (int x = w - 1; x > 2 * w ~/ 3; x--) {
      double colDiff = 0;
      for (int y = h ~/ 4; y < 3 * h ~/ 4; y++) {
        colDiff += (gray.getPixel(x, y).r - bgLum).abs();
      }
      if ((colDiff / (h ~/ 2)) > threshold) {
        right = math.min(w - 1, x + 2);
        break;
      }
    }

    final normL = (left / w).clamp(0.0, 0.4);
    final normT = (top / h).clamp(0.0, 0.4);
    final normR = (right / w).clamp(0.6, 1.0);
    final normB = (bottom / h).clamp(0.6, 1.0);

    return Rect.fromLTRB(normL, normT, normR, normB);
  } catch (e) {
    // Safe default: 4% inset document margin
    return const Rect.fromLTWH(0.04, 0.04, 0.92, 0.92);
  }
}

/// Isolate for bilinear quadrilateral perspective crop
Future<String> _cropQuadrilateralIsolate(Map<String, dynamic> params) async {
  final sourcePath = params['sourcePath'] as String;
  final tempDirPath = params['tempDirPath'] as String;
  final customTargetPath = params['targetPath'] as String?;

  final tl = Offset(params['tlX'] as double, params['tlY'] as double);
  final tr = Offset(params['trX'] as double, params['trY'] as double);
  final br = Offset(params['brX'] as double, params['brY'] as double);
  final bl = Offset(params['blX'] as double, params['blY'] as double);

  final file = File(sourcePath);
  if (!file.existsSync()) throw Exception('Source file not found: $sourcePath');

  final bytes = await file.readAsBytes();
  final image = img.decodeImage(bytes);
  if (image == null) throw Exception('Failed to decode image');

  final origW = image.width;
  final origH = image.height;

  // Calculate target width and height using distances between corners in pixel space
  final widthTop = math.sqrt(math.pow((tr.dx - tl.dx) * origW, 2) + math.pow((tr.dy - tl.dy) * origH, 2));
  final widthBottom = math.sqrt(math.pow((br.dx - bl.dx) * origW, 2) + math.pow((br.dy - bl.dy) * origH, 2));
  final heightLeft = math.sqrt(math.pow((bl.dx - tl.dx) * origW, 2) + math.pow((bl.dy - tl.dy) * origH, 2));
  final heightRight = math.sqrt(math.pow((br.dx - tr.dx) * origW, 2) + math.pow((br.dy - tr.dy) * origH, 2));

  final targetW = math.max(widthTop, widthBottom).round().clamp(30, origW);
  final targetH = math.max(heightLeft, heightRight).round().clamp(30, origH);

  final out = img.Image(width: targetW, height: targetH);

  for (int y = 0; y < targetH; y++) {
    final t = targetH > 1 ? y / (targetH - 1) : 0.0;
    for (int x = 0; x < targetW; x++) {
      final s = targetW > 1 ? x / (targetW - 1) : 0.0;

      // Bilinear quadrilateral interpolation
      final normX = (1 - s) * (1 - t) * tl.dx +
          s * (1 - t) * tr.dx +
          s * t * br.dx +
          (1 - s) * t * bl.dx;

      final normY = (1 - s) * (1 - t) * tl.dy +
          s * (1 - t) * tr.dy +
          s * t * br.dy +
          (1 - s) * t * bl.dy;

      final srcX = (normX * origW).round().clamp(0, origW - 1);
      final srcY = (normY * origH).round().clamp(0, origH - 1);

      out.setPixel(x, y, image.getPixel(srcX, srcY));
    }
  }

  final outPath = customTargetPath ??
      p.join(
        tempDirPath,
        'cropped_${DateTime.now().millisecondsSinceEpoch}_${p.basename(sourcePath)}',
      );

  final encoded = img.encodeJpg(out, quality: 92);
  await File(outPath).writeAsBytes(encoded);

  return outPath;
}

