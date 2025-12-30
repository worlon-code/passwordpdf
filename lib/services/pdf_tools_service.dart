import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/widgets.dart'; // For Offset if needed

/// Service for advanced PDF operations: Split, Merge, Reorder, Remove Password
class PdfToolsService {
  /// Remove password from a PDF and save as new file
  Future<String> removePassword({
    required String filePath,
    required String password,
    String? outputDir,
    String? savePath,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('File not found');

    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    
    final newDocument = PdfDocument();
    
    for (int i = 0; i < document.pages.count; i++) {
      final template = document.pages[i].createTemplate();
      final page = newDocument.pages.add();
      page.graphics.drawPdfTemplate(template, const Offset(0, 0));
    }
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      newPath = path.join(dir, '${filename}_unlocked$ext');
    }
    
    final newBytes = await newDocument.save();
    document.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }

  /// Reorder pages in a PDF
  Future<String> reorderPages({
    required String filePath,
    required String password,
    required List<int> pageOrder, // 0-based indices
    String? outputDir,
    String? savePath,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('File not found');

    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    
    final newDocument = PdfDocument();

    for (final index in pageOrder) {
      if (index >= 0 && index < document.pages.count) {
        final template = document.pages[index].createTemplate();
        final page = newDocument.pages.add();
        page.graphics.drawPdfTemplate(template, const Offset(0, 0));
      }
    }
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      newPath = path.join(dir, '${filename}_reordered$ext');
    }
    
    final newBytes = await newDocument.save();
    document.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }
  
  /// Split PDF pages
  Future<String> splitPdf({
    required String filePath,
    required String password,
    required List<int> pageIndices,
    String? outputDir,
    String? savePath,
  }) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    
    final newDocument = PdfDocument();
    
    for (final index in pageIndices) {
      if (index >= 0 && index < document.pages.count) {
        final template = document.pages[index].createTemplate();
        final page = newDocument.pages.add();
        page.graphics.drawPdfTemplate(template, const Offset(0, 0));
      }
    }
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      final suffix = pageIndices.length > 2 ? '${pageIndices.first+1}-${pageIndices.last+1}' : 'split';
      newPath = path.join(dir, '${filename}_split_$suffix$ext');
    }
    
    final newBytes = await newDocument.save();
    document.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }

  /// Merge PDFs
  Future<String> mergePdf({
    required String sourcePath,
    required String sourcePassword,
    required String otherPath,
    required String otherPassword,
    String? outputDir,
    String? savePath,
  }) async {
    // We create a new document to hold the result
    final newDocument = PdfDocument();
    
    // Helper to copy pages from a doc
    void copyPages(PdfDocument src) {
      for (int i = 0; i < src.pages.count; i++) {
        final template = src.pages[i].createTemplate();
        final page = newDocument.pages.add();
        page.graphics.drawPdfTemplate(template, const Offset(0, 0));
      }
    }

    // Load source
    final sourceFile = File(sourcePath);
    final sourceBytes = await sourceFile.readAsBytes();
    final sourceDoc = PdfDocument(inputBytes: sourceBytes, password: sourcePassword);
    copyPages(sourceDoc);
    
    // Load other
    final otherFile = File(otherPath);
    final otherBytes = await otherFile.readAsBytes();
    final otherDoc = PdfDocument(inputBytes: otherBytes, password: otherPassword);
    copyPages(otherDoc);
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(sourcePath);
      final filename = path.basenameWithoutExtension(sourcePath);
      final ext = path.extension(sourcePath);
      newPath = path.join(dir, '${filename}_merged$ext');
    }
    
    final newBytes = await newDocument.save();
    sourceDoc.dispose();
    otherDoc.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }

  /// Check if a PDF is password protected
  Future<bool> isProtected(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      // Try to load without password
      // If encrypted, it might throw, or load with restrictions
      // Syncfusion behavior: if encrypted and no password, it throws ArgumentError or PdfException
      try {
        final doc = PdfDocument(inputBytes: bytes);
        doc.dispose();
        return false;
      } catch (e) {
        // If it fails, assume protected if error relates to password
        // Check error message if possible, but generally failure to load indicates protection or corruption.
        // Syncfusion throws exception for encrypted docs without password.
        return true;
      }
    } catch (e) {
      return false; // File error
    }
  }
}
