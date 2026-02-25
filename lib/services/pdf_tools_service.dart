import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/widgets.dart'; // For Offset if needed
import '../services/logging_service.dart';

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
      final srcPage = document.pages[i];
      final template = srcPage.createTemplate();
      // Create section with matching page size
      final section = newDocument.sections!.add();
      section.pageSettings.size = srcPage.size;
      section.pageSettings.margins.all = 0;
      final page = section.pages.add();
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

  /// Add password to a PDF and save as new file
  Future<String> addPassword({
    required String filePath,
    required String password,
    String? outputDir,
    String? savePath,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('File not found');

    final bytes = await file.readAsBytes();
    // Load without password (it's unprotected)
    final document = PdfDocument(inputBytes: bytes);
    
    // Set security
    document.security.userPassword = password;
    document.security.ownerPassword = password;
    // Default security is usually sufficient (RC4 or AES depending on version)
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      newPath = path.join(dir, '${filename}_protected$ext');
    }
    
    final newBytes = await document.save();
    document.dispose();
    
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
        final srcPage = document.pages[index];
        final template = srcPage.createTemplate();
        // Create section with matching page size
        final section = newDocument.sections!.add();
        section.pageSettings.size = srcPage.size;
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();
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
        final srcPage = document.pages[index];
        final template = srcPage.createTemplate();
        // Create section with matching page size
        final section = newDocument.sections!.add();
        section.pageSettings.size = srcPage.size;
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();
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
    
    // Helper to copy pages from a doc preserving size
    void copyPages(PdfDocument src) {
      for (int i = 0; i < src.pages.count; i++) {
        final srcPage = src.pages[i];
        final template = srcPage.createTemplate();
        // Create section with matching page size
        final section = newDocument.sections!.add();
        section.pageSettings.size = srcPage.size;
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();
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

  /// Check if a password is valid for a PDF
  Future<bool> verifyPassword(String filePath, String password) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;
      
      final bytes = await file.readAsBytes();
      try {
        final doc = PdfDocument(inputBytes: bytes, password: password);
        doc.dispose(); // Valid password
        return true;
      } catch (e) {
        return false; // Invalid password
      }
    } catch (e) {
      return false;
    }
  }

  /// Check if a PDF is password protected
  /// Check if a PDF is password protected (Optimized for Low RAM)
  /// checks for '/Encrypt' in the file trailer/header instead of loading the full file.
  Future<bool> isProtected(String filePath) async {
    final logger = LoggingService();
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      
      RandomAccessFile? raf;
      try {
        raf = await file.open(mode: FileMode.read);
        final len = await raf.length();
        
        // Log actual RAM usage
        final startRss = ProcessInfo.currentRss;
        logger.info('RAM', 'Pre-Check Start - Process RAM: ${(startRss / 1024 / 1024).toStringAsFixed(2)} MB');
        
        logger.info('RAM', 'Pre-Check: Checking ${(len / 1024 / 1024).toStringAsFixed(2)}MB file at $filePath');
        logger.info('RAM', 'Pre-Check: Strategy -> Read 2KB Header/Trailer ONLY (Low RAM)');
        
        // 1. Check Header (First 1KB)
        // Some encrypted PDFs have specific markers or garbage at start, but /Encrypt is usually in trailer/obj
        
        // 2. Check Trailer (Last 2KB)
        // PDF structure usually puts the encryption dictionary reference in the trailer
        // "trailer << ... /Encrypt 3 0 R ... >>"
        
        int bufferSize = 2048; // 2KB
        if (len < bufferSize) bufferSize = len;
        
        await raf.setPosition(len - bufferSize);
        final buffer = await raf.read(bufferSize);
        final content = String.fromCharCodes(buffer);
        
        if (content.contains('/Encrypt')) {
          final endRss = ProcessInfo.currentRss;
          logger.info('RAM', 'Pre-Check Found Encrypted (Trailer). End Process RAM: ${(endRss / 1024 / 1024).toStringAsFixed(2)} MB. Delta: ${((endRss - startRss) / 1024 / 1024).toStringAsFixed(2)} MB');
          return true;
        }
        
        // Let's check the first 2KB too just in case
        await raf.setPosition(0);
        final headBuffer = await raf.read(bufferSize);
        final headContent = String.fromCharCodes(headBuffer);
        if (headContent.contains('/Encrypt')) {
           final endRss = ProcessInfo.currentRss;
           logger.info('RAM', 'Pre-Check Found Encrypted (Header). End Process RAM: ${(endRss / 1024 / 1024).toStringAsFixed(2)} MB');
          return true;
        }
        
        final endRss = ProcessInfo.currentRss;
        logger.info('RAM', 'Pre-Check Result: Not Encrypted. End Process RAM: ${(endRss / 1024 / 1024).toStringAsFixed(2)} MB. Delta: ${((endRss - startRss) / 1024 / 1024).toStringAsFixed(2)} MB');
        
        return false;
      
      } catch (e) {
        // Fallback to Syncfusion (Full Load) if file read fails or structure is weird
        // This ensures correctness at cost of RAM for edge cases
        logger.warn('RAM', 'Pre-Check Failed ($e). Switching to Full Load Fallback (High RAM usage)');
        return _isProtectedFallback(file);
      } finally {
        await raf?.close();
      }
    } catch (e) {
      return false; // File error
    }
  }

  /// Fallback using full load (Syncfusion) implementation
  Future<bool> _isProtectedFallback(File file) async {
    try {
      final bytes = await file.readAsBytes();
      try {
        final doc = PdfDocument(inputBytes: bytes);
        doc.dispose();
        return false;
      } catch (e) {
        return true;
      }
    } catch (e) {
      return false;
    }
  }
}
