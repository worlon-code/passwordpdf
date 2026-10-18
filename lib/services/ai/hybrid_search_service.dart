import 'dart:typed_data';
import '../../core/constants/app_constants.dart';
import '../logging_service.dart';
import '../storage_service.dart';
import 'pdf_indexing_coordinator.dart';

/// Item returned by hybrid search
class SearchResultItem {
  final String chunkId;
  final String docId;
  final String fileName;
  final String filePath;
  final int pageNumber;
  final String chunkText;
  final double score;

  const SearchResultItem({
    required this.chunkId,
    required this.docId,
    required this.fileName,
    required this.filePath,
    required this.pageNumber,
    required this.chunkText,
    required this.score,
  });
}

/// Service executing Hybrid Lexical (FTS5) + Dense (Subword Vector) search with Reciprocal Rank Fusion
class HybridSearchService {
  static final HybridSearchService _instance = HybridSearchService._internal();
  factory HybridSearchService() => _instance;
  HybridSearchService._internal();

  final StorageService _storage = StorageService();

  /// Execute hybrid search across indexed documents
  Future<List<SearchResultItem>> search({
    required String query,
    String? targetDocId,
    List<String>? targetDocIds,
    int limit = 10,
    double rrfK = 60.0,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final activeDocIds = targetDocIds ?? (targetDocId != null ? [targetDocId] : null);
    if (activeDocIds != null && activeDocIds.isEmpty) {
      return [];
    }

    // Step A: Lexical Search (SQLite FTS5)
    List<Map<String, dynamic>> ftsRows = [];
    try {
      ftsRows = await _storage.searchFtsChunks(trimmed, docIds: activeDocIds, limit: 30);
    } catch (e) {
      LoggingService().warn('HybridSearch', 'FTS search failed or table empty: $e');
    }
    final lexicalRanks = <String, int>{};
    for (int i = 0; i < ftsRows.length; i++) {
      final chunkId = ftsRows[i]['chunk_id'] as String;
      lexicalRanks[chunkId] = i + 1;
    }

    // Step B: Dense Vector Search (Cosine Similarity on subword embeddings)
    final queryEmbedding = PdfIndexingCoordinator.generateSubwordEmbedding(trimmed, dimensions: 128);
    List<Map<String, dynamic>> embeddingRows = [];
    try {
      embeddingRows = await _storage.getAllChunkEmbeddings(
        docId: targetDocId,
        docIds: activeDocIds,
      );
    } catch (e) {
      LoggingService().warn('HybridSearch', 'Vector embeddings query failed or table empty: $e');
    }

    final vectorScores = <String, double>{};
    final chunkMeta = <String, Map<String, dynamic>>{};

    for (final row in embeddingRows) {
      final chunkId = row['chunk_id'] as String;
      final blob = row['embedding_blob'] as Uint8List;
      final byteData = ByteData.sublistView(blob);
      final dim = row['dimensions'] as int? ?? 128;

      double dotProduct = 0.0;
      for (int d = 0; d < dim && d < queryEmbedding.length; d++) {
        final val = byteData.getFloat32(d * 4, Endian.little);
        dotProduct += val * queryEmbedding[d];
      }

      vectorScores[chunkId] = dotProduct;
      chunkMeta[chunkId] = {
        'doc_id': row['doc_id'],
        'page_number': row['page_number'],
        'chunk_text': row['chunk_text'],
      };
    }

    // Sort vector results descending
    final sortedVectorIds = vectorScores.keys.toList()
      ..sort((a, b) => (vectorScores[b] ?? 0).compareTo(vectorScores[a] ?? 0));

    final denseRanks = <String, int>{};
    for (int i = 0; i < sortedVectorIds.length && i < 30; i++) {
      denseRanks[sortedVectorIds[i]] = i + 1;
    }

    // Step C: Reciprocal Rank Fusion (RRF)
    final rrfScores = computeRrfScores(
      lexicalRanks: lexicalRanks,
      denseRanks: denseRanks,
      rrfK: rrfK,
    );

    final topChunkIds = rrfScores.keys.toList()
      ..sort((a, b) => (rrfScores[b] ?? 0).compareTo(rrfScores[a] ?? 0));

    final results = <SearchResultItem>[];
    final docsCache = <String, Map<String, dynamic>>{};

    for (final chunkId in topChunkIds.take(limit)) {
      // Find metadata
      var meta = chunkMeta[chunkId];
      if (meta == null) {
        // Query from DB by chunk_id if chunk was discovered via FTS or exact keyword
        final db = await _storage.database;
        final rows = await db.query(
          AppConstants.aiDocumentChunksTable,
          where: 'chunk_id = ?',
          whereArgs: [chunkId],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          meta = {
            'doc_id': rows.first['doc_id'],
            'page_number': rows.first['page_number'],
            'chunk_text': rows.first['chunk_text'],
          };
        }
      }

      if (meta == null) continue;
      final docId = meta['doc_id'] as String;

      if (!docsCache.containsKey(docId)) {
        final docRow = await _storage.getAiDocument(docId);
        if (docRow != null) {
          docsCache[docId] = docRow;
        }
      }

      final doc = docsCache[docId];
      final fileName = doc?['file_name'] as String? ?? 'Document';
      final filePath = doc?['file_path'] as String? ?? '';

      results.add(SearchResultItem(
        chunkId: chunkId,
        docId: docId,
        fileName: fileName,
        filePath: filePath,
        pageNumber: (meta['page_number'] as int? ?? 1),
        chunkText: meta['chunk_text'] as String? ?? '',
        score: rrfScores[chunkId] ?? 0.0,
      ));
    }

    return results;
  }

  /// Reciprocal Rank Fusion calculation combining multiple ranked lists
  Map<String, double> computeRrfScores({
    required Map<String, int> lexicalRanks,
    required Map<String, int> denseRanks,
    double rrfK = 60.0,
  }) {
    final allChunkIds = {...lexicalRanks.keys, ...denseRanks.keys};
    final rrfScores = <String, double>{};

    for (final chunkId in allChunkIds) {
      double score = 0.0;
      if (lexicalRanks.containsKey(chunkId)) {
        score += 1.0 / (rrfK + lexicalRanks[chunkId]!);
      }
      if (denseRanks.containsKey(chunkId)) {
        score += 1.0 / (rrfK + denseRanks[chunkId]!);
      }
      rrfScores[chunkId] = score;
    }
    return rrfScores;
  }
}
