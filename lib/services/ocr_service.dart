import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Rect;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

/// Individual recognized text line with exact bounding box coordinates in image space
class OcrTextLine {
  final String text;
  final Rect boundingBox; // Pixel coordinates in source image (left, top, width, height)

  const OcrTextLine({
    required this.text,
    required this.boundingBox,
  });
}

/// Recognized text block containing one or more lines
class OcrTextBlock {
  final String text;
  final Rect boundingBox;
  final List<OcrTextLine> lines;

  const OcrTextBlock({
    required this.text,
    required this.boundingBox,
    required this.lines,
  });
}

/// Container for structured OCR results with exact bounding boxes and image dimensions
class OcrResult {
  final String fullText;
  final List<String> lines; // String lines for quick access
  final List<OcrTextLine> textLines; // Structured lines with exact bounding boxes
  final List<OcrTextBlock> blocks;
  final int imageWidth;
  final int imageHeight;
  final int blockCount;
  final bool hasText;

  const OcrResult({
    required this.fullText,
    required this.lines,
    this.textLines = const [],
    this.blocks = const [],
    this.imageWidth = 0,
    this.imageHeight = 0,
    required this.blockCount,
    required this.hasText,
  });

  factory OcrResult.empty() => const OcrResult(
        fullText: '',
        lines: [],
        textLines: [],
        blocks: [],
        imageWidth: 0,
        imageHeight: 0,
        blockCount: 0,
        hasText: false,
      );
}

/// Offline on-device Optical Character Recognition service
class OcrService {
  static final OcrService _instance = OcrService._internal();
  factory OcrService() => _instance;
  OcrService._internal();

  /// Recognize text from an image file on disk with exact bounding boxes
  Future<OcrResult> recognizeText(String imagePath) async {
    final file = File(imagePath);
    if (!file.existsSync()) {
      return OcrResult.empty();
    }

    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      // Decode image dimensions to ensure pixel-perfect coordinate scaling
      int imgW = 0;
      int imgH = 0;
      try {
        final bytes = await file.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          imgW = decoded.width;
          imgH = decoded.height;
        }
      } catch (_) {}

      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);

      final fullText = recognizedText.text.trim();
      final stringLines = <String>[];
      final structuredLines = <OcrTextLine>[];
      final structuredBlocks = <OcrTextBlock>[];

      for (final block in recognizedText.blocks) {
        final blockLines = <OcrTextLine>[];
        for (final line in block.lines) {
          final t = line.text.trim();
          if (t.isNotEmpty) {
            stringLines.add(t);
            final ocrLine = OcrTextLine(
              text: t,
              boundingBox: line.boundingBox,
            );
            blockLines.add(ocrLine);
            structuredLines.add(ocrLine);
          }
        }

        structuredBlocks.add(
          OcrTextBlock(
            text: block.text.trim(),
            boundingBox: block.boundingBox,
            lines: blockLines,
          ),
        );
      }

      return OcrResult(
        fullText: fullText,
        lines: stringLines,
        textLines: structuredLines,
        blocks: structuredBlocks,
        imageWidth: imgW,
        imageHeight: imgH,
        blockCount: recognizedText.blocks.length,
        hasText: fullText.isNotEmpty,
      );
    } catch (e) {
      debugPrint('[OcrService] OCR recognition failed: $e');
      return OcrResult.empty();
    } finally {
      await textRecognizer.close();
    }
  }
}
