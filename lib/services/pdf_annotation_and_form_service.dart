import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'document_service.dart';

/// Information about an AcroForm field
class FormFieldInfo {
  final String name;
  final String type; // 'text', 'checkbox', 'combobox', 'radio'
  final dynamic currentValue;
  final List<String> options;

  FormFieldInfo({
    required this.name,
    required this.type,
    this.currentValue,
    this.options = const [],
  });
}

/// Service for AcroForm filling, PDF annotations, and transparent signature stamping
class PdfAnnotationAndFormService {
  static final PdfAnnotationAndFormService _instance =
      PdfAnnotationAndFormService._internal();
  factory PdfAnnotationAndFormService() => _instance;
  PdfAnnotationAndFormService._internal();

  final DocumentService _docService = DocumentService();

  /// Inspect PDF document and extract interactive AcroForm fields
  Future<List<FormFieldInfo>> getFormFields({
    required String filePath,
    required String password,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) return [];

    final bytes = await file.readAsBytes();
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes, password: password.isEmpty ? null : password);
      final fields = <FormFieldInfo>[];

      for (int i = 0; i < document.form.fields.count; i++) {
        final field = document.form.fields[i];
        final name = field.name ?? 'field_$i';

        if (field is PdfTextBoxField) {
          fields.add(FormFieldInfo(
            name: name,
            type: 'text',
            currentValue: field.text,
          ));
        } else if (field is PdfCheckBoxField) {
          fields.add(FormFieldInfo(
            name: name,
            type: 'checkbox',
            currentValue: field.isChecked,
          ));
        } else if (field is PdfComboBoxField) {
          final items = <String>[];
          for (int j = 0; j < field.items.count; j++) {
            items.add(field.items[j].text);
          }
          fields.add(FormFieldInfo(
            name: name,
            type: 'combobox',
            currentValue: field.selectedValue,
            options: items,
          ));
        } else if (field is PdfRadioButtonListField) {
          final items = <String>[];
          for (int j = 0; j < field.items.count; j++) {
            items.add(field.items[j].value);
          }
          fields.add(FormFieldInfo(
            name: name,
            type: 'radio',
            currentValue: field.selectedValue,
            options: items,
          ));
        }
      }

      return fields;
    } catch (_) {
      return [];
    } finally {
      document?.dispose();
    }
  }

  /// Fill AcroForm fields and save to a new copy
  Future<String> fillFormFields({
    required String filePath,
    required String password,
    required Map<String, dynamic> fieldValues,
    String? outputFilePath,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('Source file not found');

    final bytes = await file.readAsBytes();
    final document = PdfDocument(
      inputBytes: bytes,
      password: password.isEmpty ? null : password,
    );

    try {
      for (int i = 0; i < document.form.fields.count; i++) {
        final field = document.form.fields[i];
        final name = field.name;
        if (name == null || !fieldValues.containsKey(name)) continue;
        final val = fieldValues[name];

        if (field is PdfTextBoxField && val is String) {
          field.text = val;
        } else if (field is PdfCheckBoxField && val is bool) {
          field.isChecked = val;
        } else if (field is PdfComboBoxField && val is String) {
          field.selectedValue = val;
        } else if (field is PdfRadioButtonListField && val is String) {
          field.selectedValue = val;
        }
      }

      final outPath = outputFilePath ?? _generateCopyPath(filePath, 'form_filled');
      final newBytes = await document.save();
      await File(outPath).writeAsBytes(newBytes);

      // Register new copy with DocumentService
      try {
        await _docService.addFile(outPath, isNew: true);
      } catch (_) {}
      return outPath;
    } finally {
      document.dispose();
    }
  }

  /// Stamp transparent signature PNG onto specified page and bounds
  Future<String> stampSignature({
    required String filePath,
    required String password,
    required Uint8List signaturePngBytes,
    required int pageNumber, // 1-indexed
    required Rect bounds,
    String? outputFilePath,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('Source file not found');

    final bytes = await file.readAsBytes();
    final document = PdfDocument(
      inputBytes: bytes,
      password: password.isEmpty ? null : password,
    );

    try {
      if (pageNumber < 1 || pageNumber > document.pages.count) {
        throw ArgumentError('Invalid page number: $pageNumber');
      }

      final page = document.pages[pageNumber - 1];
      final bitmap = PdfBitmap(signaturePngBytes);

      // Draw the transparent signature image at the requested coordinates
      page.graphics.drawImage(bitmap, bounds);

      final outPath = outputFilePath ?? _generateCopyPath(filePath, 'signed');
      final newBytes = await document.save();
      await File(outPath).writeAsBytes(newBytes);

      // Register new copy with DocumentService
      try {
        await _docService.addFile(outPath, isNew: true);
      } catch (_) {}
      return outPath;
    } finally {
      document.dispose();
    }
  }

  /// Add highlight or text note annotation and save to a new copy
  Future<String> addHighlightAndNote({
    required String filePath,
    required String password,
    required int pageNumber,
    required Rect bounds,
    String? noteText,
    PdfColor? highlightColor,
    String? outputFilePath,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('Source file not found');

    final bytes = await file.readAsBytes();
    final document = PdfDocument(
      inputBytes: bytes,
      password: password.isEmpty ? null : password,
    );

    try {
      if (pageNumber < 1 || pageNumber > document.pages.count) {
        throw ArgumentError('Invalid page number: $pageNumber');
      }

      final page = document.pages[pageNumber - 1];
      final color = highlightColor ?? PdfColor(255, 235, 59, 100);

      // Draw semi-transparent highlight box
      page.graphics.save();
      page.graphics.setTransparency(0.4);
      final brush = PdfSolidBrush(color);
      page.graphics.drawRectangle(
        brush: brush,
        bounds: bounds,
      );
      page.graphics.restore();

      // If a note text is attached, draw a small note indicator or annotation
      if (noteText != null && noteText.trim().isNotEmpty) {
        final font = PdfStandardFont(PdfFontFamily.helvetica, 10);
        final noteBrush = PdfSolidBrush(PdfColor(33, 33, 33));
        page.graphics.drawString(
          noteText,
          font,
          brush: noteBrush,
          bounds: Rect.fromLTWH(bounds.left, bounds.bottom + 2, bounds.width.clamp(100, 300), 20),
        );
      }

      final outPath = outputFilePath ?? _generateCopyPath(filePath, 'annotated');
      final newBytes = await document.save();
      await File(outPath).writeAsBytes(newBytes);

      try {
        await _docService.addFile(outPath, isNew: true);
      } catch (_) {}
      return outPath;
    } finally {
      document.dispose();
    }
  }

  /// Helper to generate non-colliding new copy file path
  String _generateCopyPath(String originalPath, String suffix) {
    final dir = p.dirname(originalPath);
    final base = p.basenameWithoutExtension(originalPath);
    final ext = p.extension(originalPath);
    final ts = DateTime.now().millisecondsSinceEpoch;
    return p.join(dir, '${base}_${suffix}_$ts$ext');
  }

  /// Get size of a page in PDF points (width, height)
  Future<Size> getPageSize({
    required String filePath,
    String? password,
    required int pageNumber,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) return const Size(595.28, 841.89);

    final bytes = await file.readAsBytes();
    PdfDocument? doc;
    try {
      doc = PdfDocument(
        inputBytes: bytes,
        password: (password != null && password.isNotEmpty) ? password : null,
      );
      if (pageNumber >= 1 && pageNumber <= doc.pages.count) {
        final page = doc.pages[pageNumber - 1];
        return Size(page.size.width, page.size.height);
      }
      return const Size(595.28, 841.89);
    } catch (_) {
      return const Size(595.28, 841.89);
    } finally {
      doc?.dispose();
    }
  }
}
