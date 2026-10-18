import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../storage_service.dart';

/// Coordinator that extracts text from PDFs, chunks them, and indexes them in SQLite FTS5 & vector tables
class PdfIndexingCoordinator {
  static final PdfIndexingCoordinator _instance = PdfIndexingCoordinator._internal();
  factory PdfIndexingCoordinator() => _instance;
  PdfIndexingCoordinator._internal();

  final StorageService _storage = StorageService();

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

    // Check if already indexed with same modified time
    final existingDoc = await _storage.getAiDocument(docId);
    if (existingDoc != null &&
        existingDoc['status'] == 'completed' &&
        existingDoc['last_modified'] == stat.modified.millisecondsSinceEpoch) {
      return docId;
    }

    PdfDocument? document;
    try {
      document = PdfDocument(
        inputBytes: bytes,
        password: (password != null && password.isNotEmpty) ? password : null,
      );

      final totalPages = document.pages.count;

      // Upsert document record in indexing state
      await _storage.upsertAiDocument({
        'doc_id': docId,
        'file_path': filePath,
        'file_name': p.basename(filePath),
        'file_size': stat.size,
        'last_modified': stat.modified.millisecondsSinceEpoch,
        'total_pages': totalPages,
        'indexed_pages': 0,
        'status': 'indexing',
        'index_version': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Clear previous chunks and pages for this docId
      await _storage.deleteAiDocument(docId);
      // Re-insert indexing entry
      await _storage.upsertAiDocument({
        'doc_id': docId,
        'file_path': filePath,
        'file_name': p.basename(filePath),
        'file_size': stat.size,
        'last_modified': stat.modified.millisecondsSinceEpoch,
        'total_pages': totalPages,
        'indexed_pages': 0,
        'status': 'indexing',
        'index_version': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      final pagesBatch = <Map<String, dynamic>>[];
      final chunksBatch = <Map<String, dynamic>>[];

      for (int pageIndex = 0; pageIndex < totalPages; pageIndex++) {
        final pageNum = pageIndex + 1;
        onProgress?.call(pageNum, totalPages);

        String pageText = '';
        try {
          final textExtractor = PdfTextExtractor(document);
          pageText = textExtractor.extractText(startPageIndex: pageIndex, endPageIndex: pageIndex);
        } catch (_) {}

        final pageId = '${docId}_p$pageNum';
        pagesBatch.add({
          'page_id': pageId,
          'doc_id': docId,
          'page_number': pageNum,
          'extracted_text': pageText,
          'char_count': pageText.length,
          'has_ocr': 0,
        });

        // Chunking: sliding window of ~500 chars with 100 char overlap
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
        'file_name': p.basename(filePath),
        'file_size': stat.size,
        'last_modified': stat.modified.millisecondsSinceEpoch,
        'total_pages': totalPages,
        'indexed_pages': totalPages,
        'status': 'completed',
        'index_version': 1,
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
        'index_version': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      rethrow;
    } finally {
      document?.dispose();
    }
  }

  /// Split text into sliding window chunks
  List<String> _chunkText(String text, {int chunkSize = 500, int overlap = 100}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return [];
    if (trimmed.length <= chunkSize) return [trimmed];

    final chunks = <String>[];
    int start = 0;
    while (start < trimmed.length) {
      int end = start + chunkSize;
      if (end > trimmed.length) end = trimmed.length;

      // Try breaking at word boundary if not at end
      if (end < trimmed.length) {
        final lastSpace = trimmed.lastIndexOf(' ', end);
        if (lastSpace > start + (chunkSize / 2)) {
          end = lastSpace;
        }
      }

      final piece = trimmed.substring(start, end).trim();
      if (piece.isNotEmpty) {
        chunks.add(piece);
      }

      if (end >= trimmed.length) break;
      start = end - overlap;
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
