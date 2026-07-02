import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path/path.dart' as path;
import '../core/extensions/pdf_document_extensions.dart';
import '../services/logging_service.dart';

/// Service for advanced PDF operations: Split, Merge, Reorder, Remove Password
class PdfToolsService {
  bool _hasInteractiveContent(PdfDocument document) {
    return document.form.fields.count > 0 || document.bookmarks.count > 0;
  }

  /// Check if reordering will flatten interactive content (forms/bookmarks)
  Future<bool> willFlattenOnReorder({
    required String filePath,
    required String password,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    try {
      final document = PdfDocument(inputBytes: bytes, password: password);
      try {
        return _hasInteractiveContent(document);
      } finally {
        document.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  /// Check if merging will flatten interactive content (forms/bookmarks)
  Future<bool> willFlattenOnMerge({
    required String sourcePath,
    required String sourcePassword,
    required String otherPath,
    required String otherPassword,
  }) async {
    bool sourceHas = false;
    bool otherHas = false;

    final sourceFile = File(sourcePath);
    if (sourceFile.existsSync()) {
      final sourceBytes = await sourceFile.readAsBytes();
      try {
        final sourceDoc = PdfDocument(inputBytes: sourceBytes, password: sourcePassword);
        sourceHas = _hasInteractiveContent(sourceDoc);
        sourceDoc.dispose();
      } catch (_) {}
    }

    final otherFile = File(otherPath);
    if (otherFile.existsSync()) {
      final otherBytes = await otherFile.readAsBytes();
      try {
        final otherDoc = PdfDocument(inputBytes: otherBytes, password: otherPassword);
        otherHas = _hasInteractiveContent(otherDoc);
        otherDoc.dispose();
      } catch (_) {}
    }

    return sourceHas || otherHas;
  }

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
    try {
      // Clear security on the loaded document (lossless)
      document.security.userPassword = '';
      document.security.ownerPassword = '';

      String newPath;
      if (savePath != null) {
        newPath = savePath;
      } else {
        final dir = outputDir ?? path.dirname(filePath);
        final filename = path.basenameWithoutExtension(filePath);
        final ext = path.extension(filePath);
        newPath = path.join(dir, '${filename}_unlocked$ext');
      }

      final newBytes = await document.save();
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      document.dispose();
    }
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
    try {
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
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      document.dispose();
    }
  }

  /// Reorder pages in a PDF
  Future<String> reorderPages({
    required String filePath,
    required String password,
    required List<int> pageOrder, // 0-based indices
    required bool confirmedFlatten,
    String? outputDir,
    String? savePath,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('File not found');

    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    try {
      if (_hasInteractiveContent(document) && !confirmedFlatten) {
        throw Exception('Operation will flatten interactive content (forms/bookmarks). Confirm to proceed.');
      }

      final newDocument = PdfDocument();
      try {
        for (final index in pageOrder) {
          if (index >= 0 && index < document.pages.count) {
            // Import one real page at a time, in the requested order
            newDocument.importPageRange(document, index, index);
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
        await File(newPath).writeAsBytes(newBytes);
        return newPath;
      } finally {
        newDocument.dispose();
      }
    } finally {
      document.dispose();
    }
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
    try {
      // Determine pages to remove (those NOT in pageIndices)
      final keepSet = pageIndices.toSet();
      // Iterate descending to keep indices stable when removing
      for (int i = document.pages.count - 1; i >= 0; i--) {
        if (!keepSet.contains(i)) {
          document.pages.removeAt(i);
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

      final newBytes = await document.save();
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      document.dispose();
    }
  }

  /// Merge PDFs
  Future<String> mergePdf({
    required String sourcePath,
    required String sourcePassword,
    required String otherPath,
    required String otherPassword,
    required bool confirmedFlatten,
    String? outputDir,
    String? savePath,
  }) async {
    // Load source
    final sourceFile = File(sourcePath);
    final sourceBytes = await sourceFile.readAsBytes();
    final sourceDoc = PdfDocument(inputBytes: sourceBytes, password: sourcePassword);

    // Load other
    final otherFile = File(otherPath);
    final otherBytes = await otherFile.readAsBytes();
    final otherDoc = PdfDocument(inputBytes: otherBytes, password: otherPassword);

    try {
      if ((_hasInteractiveContent(sourceDoc) || _hasInteractiveContent(otherDoc)) && !confirmedFlatten) {
        throw Exception('Operation will flatten interactive content (forms/bookmarks). Confirm to proceed.');
      }

      // We create a new document to hold the result
      final newDocument = PdfDocument();
      try {
        // Import real pages from both docs (preserves text/links/form fields)
        if (sourceDoc.pages.count > 0) {
          newDocument.importPageRange(sourceDoc, 0, sourceDoc.pages.count - 1);
        }
        if (otherDoc.pages.count > 0) {
          newDocument.importPageRange(otherDoc, 0, otherDoc.pages.count - 1);
        }

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
        await File(newPath).writeAsBytes(newBytes);
        return newPath;
      } finally {
        newDocument.dispose();
      }
    } finally {
      sourceDoc.dispose();
      otherDoc.dispose();
    }
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
          return await _isProtectedFallback(file);
        }
        
        // Let's check the first 2KB too just in case
        await raf.setPosition(0);
        final headBuffer = await raf.read(bufferSize);
        final headContent = String.fromCharCodes(headBuffer);
        if (headContent.contains('/Encrypt')) {
           final endRss = ProcessInfo.currentRss;
           logger.info('RAM', 'Pre-Check Found Encrypted (Header). End Process RAM: ${(endRss / 1024 / 1024).toStringAsFixed(2)} MB');
          return await _isProtectedFallback(file);
        }
        
        final endRss = ProcessInfo.currentRss;
        logger.info('RAM', 'Pre-Check Result: No /Encrypt marker found in header/trailer. Falling through to Syncfusion check. End Process RAM: ${(endRss / 1024 / 1024).toStringAsFixed(2)} MB. Delta: ${((endRss - startRss) / 1024 / 1024).toStringAsFixed(2)} MB');
        
        // Heuristic header/trailer scan can miss /Encrypt; confirm with a real Syncfusion check
        return _isProtectedFallback(file);
      
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
