import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../storage_service.dart';

/// Coordinator that extracts text from PDFs with clean visual reading order,
/// normalizes line breaks, chunks cleanly on word boundaries, and indexes in SQLite FTS5 & vector tables.
class PdfIndexingCoordinator {
  static final PdfIndexingCoordinator _instance = PdfIndexingCoordinator._internal();
  factory PdfIndexingCoordinator() => _instance;
  PdfIndexingCoordinator._internal();

  final StorageService _storage = StorageService();

  /// Repository index version. Incrementing this triggers re-indexing of documents.
  static const int currentSchemaVersion = 2;

  /// Index an entire PDF document for offline hybrid search and RAG
  Future<String> indexPdfDocument({
    required String filePath,
    String? password,
    void Function(int page, int total)? onProgress,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('File does not exist: $filePath');

    final stat = await file.stat();
    final bytes = await file.readAsBytes();
    final docId = sha256.convert(utf8.encode(filePath)).toString();

    // Check if already indexed with same modified time and current schema version
    final existingDoc = await _storage.getAiDocument(docId);
    if (existingDoc != null &&
        existingDoc['status'] == 'completed' &&
        existingDoc['last_modified'] == stat.modified.millisecondsSinceEpoch &&
        (existingDoc['index_version'] ?? 1) >= currentSchemaVersion) {
      return docId;
    }

    PdfDocument? document;
    try {
      document = PdfDocument(
        inputBytes: bytes,
        password: (password != null && password.isNotEmpty) ? password : null,
      );

      final totalPages = document.pages.count;
      final fileName = p.basename(filePath);
      final humanTitle = p.basenameWithoutExtension(filePath).replaceAll(RegExp(r'[_\\-]+'), ' ').trim();

      // Upsert document record in indexing state
      await _storage.upsertAiDocument({
        'doc_id': docId,
        'file_path': filePath,
        'file_name': fileName,
        'file_size': stat.size,
        'last_modified': stat.modified.millisecondsSinceEpoch,
        'total_pages': totalPages,
        'indexed_pages': 0,
        'status': 'indexing',
        'index_version': currentSchemaVersion,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Clear previous chunks and pages for this docId
      await _storage.deleteAiDocument(docId);

      // Re-insert indexing entry
      await _storage.upsertAiDocument({
        'doc_id': docId,
        'file_path': filePath,
        'file_name': fileName,
        'file_size': stat.size,
        'last_modified': stat.modified.millisecondsSinceEpoch,
        'total_pages': totalPages,
        'indexed_pages': 0,
        'status': 'indexing',
        'index_version': currentSchemaVersion,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      final pagesBatch = <Map<String, dynamic>>[];
      final chunksBatch = <Map<String, dynamic>>[];

      for (int pageIndex = 0; pageIndex < totalPages; pageIndex++) {
        final pageNum = pageIndex + 1;
        onProgress?.call(pageNum, totalPages);

        String pageText = extractPageTextClean(document, pageIndex);

        // For Page 1, prepend document filename and human title hint so header/identity queries resolve
        if (pageIndex == 0) {
          pageText = '[Document File: $fileName | Document Title / Candidate Hint: $humanTitle]\n$pageText';
        }

        final pageId = '${docId}_p$pageNum';
        pagesBatch.add({
          'page_id': pageId,
          'doc_id': docId,
          'page_number': pageNum,
          'extracted_text': pageText,
          'char_count': pageText.length,
          'has_ocr': 0,
        });

        // Chunking: sliding window of ~500 chars with 100 char overlap snapped strictly to whitespace
        final chunks = _chunkText(pageText, chunkSize: 500, overlap: 100);
        for (int cIdx = 0; cIdx < chunks.length; cIdx++) {
          final chunkId = '${docId}_p${pageNum}_c$cIdx';
          final chunkText = chunks[cIdx];
          final tokenEst = (chunkText.length / 4).ceil();

          chunksBatch.add({
            'chunk_id': chunkId,
            'doc_id': docId,
            'page_number': pageNum,
            'chunk_index': cIdx,
            'chunk_text': chunkText,
            'char_length': chunkText.length,
            'token_estimate': tokenEst,
          });

          // Insert into FTS
          await _storage.insertAiChunkFts(chunkId, docId, chunkText);

          // Compute deterministic subword embedding vector (128 dimensions)
          final embedding = generateSubwordEmbedding(chunkText, dimensions: 128);
          await _storage.insertChunkEmbedding(chunkId, embedding, 128, 'deterministic_subword_128');
        }
      }

      await _storage.insertAiPages(pagesBatch);
      await _storage.insertAiChunks(chunksBatch);

      // Mark completed
      await _storage.upsertAiDocument({
        'doc_id': docId,
        'file_path': filePath,
        'file_name': fileName,
        'file_size': stat.size,
        'last_modified': stat.modified.millisecondsSinceEpoch,
        'total_pages': totalPages,
        'indexed_pages': totalPages,
        'status': 'completed',
        'index_version': currentSchemaVersion,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      return docId;
    } catch (e) {
      await _storage.upsertAiDocument({
        'doc_id': docId,
        'file_path': filePath,
        'file_name': p.basename(filePath),
        'file_size': stat.size,
        'last_modified': stat.modified.millisecondsSinceEpoch,
        'total_pages': 0,
        'indexed_pages': 0,
        'status': 'error',
        'error_message': e.toString(),
        'index_version': currentSchemaVersion,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      rethrow;
    } finally {
      document?.dispose();
    }
  }

  /// Extracts text in visual reading order from a page, joining horizontal words and grouping lines cleanly
  static String extractPageTextClean(PdfDocument document, int pageIndex) {
    try {
      final textExtractor = PdfTextExtractor(document);
      final textLines = textExtractor.extractTextLines(
        startPageIndex: pageIndex,
        endPageIndex: pageIndex,
      );

      if (textLines.isNotEmpty) {
        // Group and sort lines by reading order
        final sorted = List<TextLine>.from(textLines);
        sorted.sort((a, b) {
          final dy = (a.bounds.top - b.bounds.top).abs();
          if (dy <= 4.0) return a.bounds.left.compareTo(b.bounds.left);
          return a.bounds.top.compareTo(b.bounds.top);
        });

        final buffer = StringBuffer();
        double? currentLineTop;

        for (final line in sorted) {
          final text = line.text.trim();
          if (text.isEmpty) continue;

          if (currentLineTop == null) {
            currentLineTop = line.bounds.top;
            buffer.write(text);
          } else {
            final dy = (line.bounds.top - currentLineTop).abs();
            if (dy <= 4.0) {
              // Same horizontal line: join with space
              buffer.write(' ');
              buffer.write(text);
            } else {
              // New line
              buffer.write('\n');
              buffer.write(text);
              currentLineTop = line.bounds.top;
            }
          }
        }

        final rawText = buffer.toString();
        return normalizeExtractedPdfText(rawText);
      }
    } catch (_) {}

    // Fallback: standard extraction
    try {
      final textExtractor = PdfTextExtractor(document);
      final fallback = textExtractor.extractText(startPageIndex: pageIndex, endPageIndex: pageIndex);
      return normalizeExtractedPdfText(fallback);
    } catch (_) {
      return '';
    }
  }

  /// Normalizes extracted text: collapses fragmented word-per-line sequences into sentences,
  /// trims whitespace, and preserves section headings / bullet points.
  static String normalizeExtractedPdfText(String raw) {
    if (raw.isEmpty) return '';

    // Standardize line endings
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rawLines = normalized.split('\n');
    final resultLines = <String>[];

    String currentBuffer = '';

    for (int i = 0; i < rawLines.length; i++) {
      final line = rawLines[i].trim();
      if (line.isEmpty) {
        if (currentBuffer.isNotEmpty) {
          resultLines.add(currentBuffer);
          currentBuffer = '';
        }
        continue;
      }

      // Check if this line is an explicit bullet or section heading
      final isBullet = line.startsWith('•') || line.startsWith('- ') || line.startsWith('* ') || line.startsWith('|');
      final isHeading = line.length > 2 && line == line.toUpperCase() && !line.contains(RegExp(r'\d'));
      final endsWithPunct = line.endsWith('.') || line.endsWith(':') || line.endsWith(';') || line.endsWith('!') || line.endsWith('?');

      if (currentBuffer.isEmpty) {
        currentBuffer = line;
      } else {
        // If current buffer is short (< 60 chars) or current line doesn't end with punctuation
        // and next line is not a bullet or heading, join them with space
        final isShortFrag = currentBuffer.split(RegExp(r'\s+')).length <= 4 && !currentBuffer.endsWith(':');
        if (isShortFrag && !isBullet && !isHeading) {
          currentBuffer = '$currentBuffer $line';
        } else if (!currentBuffer.endsWith('.') && !currentBuffer.endsWith(':') && !isBullet && !isHeading && currentBuffer.length < 120) {
          currentBuffer = '$currentBuffer $line';
        } else {
          resultLines.add(currentBuffer);
          currentBuffer = line;
        }
      }

      if (endsWithPunct || isHeading || isBullet) {
        resultLines.add(currentBuffer);
        currentBuffer = '';
      }
    }

    if (currentBuffer.isNotEmpty) {
      resultLines.add(currentBuffer);
    }

    // Collapse multiple whitespace
    return resultLines.join('\n').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  /// Split text into sliding window chunks, strictly breaking on whitespace boundaries
  List<String> _chunkText(String text, {int chunkSize = 500, int overlap = 100}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return [];
    if (trimmed.length <= chunkSize) return [trimmed];

    final chunks = <String>[];
    int start = 0;
    while (start < trimmed.length) {
      int end = start + chunkSize;
      if (end >= trimmed.length) {
        final piece = trimmed.substring(start).trim();
        if (piece.isNotEmpty) chunks.add(piece);
        break;
      }

      // Search backward for the nearest whitespace character to avoid slicing mid-word
      int boundary = -1;
      for (int i = end; i > start + (chunkSize / 2); i--) {
        final char = trimmed[i];
        if (char == ' ' || char == '\n' || char == '\t' || char == '\r') {
          boundary = i;
          break;
        }
      }

      if (boundary != -1) {
        end = boundary;
      }

      final piece = trimmed.substring(start, end).trim();
      if (piece.isNotEmpty) {
        chunks.add(piece);
      }

      start = end - overlap;
      if (start < 0) start = 0;
    }
    return chunks;
  }

  /// Deterministic subword n-gram vector generator (100% offline, zero neural overhead)
  /// Generates a normalized 128-dimensional dense vector representation of input text
  static List<double> generateSubwordEmbedding(String text, {int dimensions = 128}) {
    final vector = List<double>.filled(dimensions, 0.0);
    final lower = text.toLowerCase().trim();
    if (lower.isEmpty) return vector;

    // Generate character 3-grams and 4-grams
    final tokens = <String>[];
    for (int len = 3; len <= 4; len++) {
      for (int i = 0; i <= lower.length - len; i++) {
        tokens.add(lower.substring(i, i + len));
      }
    }
    // Also include word tokens
    tokens.addAll(lower.split(RegExp(r'\s+')));

    for (final token in tokens) {
      if (token.isEmpty) continue;
      final hashBytes = md5.convert(utf8.encode(token)).bytes;
      final bucket = (hashBytes[0] | (hashBytes[1] << 8)) % dimensions;
      final sign = (hashBytes[2] % 2 == 0) ? 1.0 : -1.0;
      vector[bucket] += sign;
    }

    // L2-normalize
    double sumSquares = 0.0;
    for (int i = 0; i < dimensions; i++) {
      sumSquares += vector[i] * vector[i];
    }
    if (sumSquares > 0) {
      final norm = sqrt(sumSquares);
      for (int i = 0; i < dimensions; i++) {
        vector[i] /= norm;
      }
    }

    return vector;
  }
}
