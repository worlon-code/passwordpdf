import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../../core/constants/app_constants.dart';
import '../logging_service.dart';
import '../storage_service.dart';

/// Detailed diagnostic entry capturing the complete RAG and AI inference pipeline
class AiDiagnosticLogEntry {
  final String id;
  final DateTime timestamp;
  final String rawQuery;
  final String detectedIntent; // 'greeting', 'document_rag', 'empty', 'in_progress'
  final List<String> extractedKeywords;
  final List<String> stopwordsRemoved;
  final String ftsQueryString;
  final List<String> attachedDocNames;

  final int ftsMatchesCount;
  final List<Map<String, dynamic>> ftsMatches;

  final int vectorMatchesCount;
  final List<Map<String, dynamic>> vectorMatches;

  final List<Map<String, dynamic>> selectedEvidence;

  final String? activeChatModelId;
  final String? activeChatModelName;
  final String? activeChatModelPath;
  final int? activeChatModelSizeBytes;

  final String? activeEmbeddingModelId;
  final String? activeEmbeddingModelName;

  final String promptSentToLlm;
  final String llmExecutionStatus; // 'in_progress:...', 'executed', 'native_returned_null', 'missing_model', 'greeting'
  final String? llmRawResponse;
  final String finalAnswer;
  final int executionTimeMs;

  const AiDiagnosticLogEntry({
    required this.id,
    required this.timestamp,
    required this.rawQuery,
    required this.detectedIntent,
    required this.extractedKeywords,
    required this.stopwordsRemoved,
    required this.ftsQueryString,
    required this.attachedDocNames,
    required this.ftsMatchesCount,
    required this.ftsMatches,
    required this.vectorMatchesCount,
    required this.vectorMatches,
    required this.selectedEvidence,
    required this.activeChatModelId,
    required this.activeChatModelName,
    required this.activeChatModelPath,
    required this.activeChatModelSizeBytes,
    required this.activeEmbeddingModelId,
    required this.activeEmbeddingModelName,
    required this.promptSentToLlm,
    required this.llmExecutionStatus,
    required this.llmRawResponse,
    required this.finalAnswer,
    required this.executionTimeMs,
  });

  AiDiagnosticLogEntry copyWith({
    String? id,
    DateTime? timestamp,
    String? rawQuery,
    String? detectedIntent,
    List<String>? extractedKeywords,
    List<String>? stopwordsRemoved,
    String? ftsQueryString,
    List<String>? attachedDocNames,
    int? ftsMatchesCount,
    List<Map<String, dynamic>>? ftsMatches,
    int? vectorMatchesCount,
    List<Map<String, dynamic>>? vectorMatches,
    List<Map<String, dynamic>>? selectedEvidence,
    String? activeChatModelId,
    String? activeChatModelName,
    String? activeChatModelPath,
    int? activeChatModelSizeBytes,
    String? activeEmbeddingModelId,
    String? activeEmbeddingModelName,
    String? promptSentToLlm,
    String? llmExecutionStatus,
    String? llmRawResponse,
    String? finalAnswer,
    int? executionTimeMs,
  }) {
    return AiDiagnosticLogEntry(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      rawQuery: rawQuery ?? this.rawQuery,
      detectedIntent: detectedIntent ?? this.detectedIntent,
      extractedKeywords: extractedKeywords ?? this.extractedKeywords,
      stopwordsRemoved: stopwordsRemoved ?? this.stopwordsRemoved,
      ftsQueryString: ftsQueryString ?? this.ftsQueryString,
      attachedDocNames: attachedDocNames ?? this.attachedDocNames,
      ftsMatchesCount: ftsMatchesCount ?? this.ftsMatchesCount,
      ftsMatches: ftsMatches ?? this.ftsMatches,
      vectorMatchesCount: vectorMatchesCount ?? this.vectorMatchesCount,
      vectorMatches: vectorMatches ?? this.vectorMatches,
      selectedEvidence: selectedEvidence ?? this.selectedEvidence,
      activeChatModelId: activeChatModelId ?? this.activeChatModelId,
      activeChatModelName: activeChatModelName ?? this.activeChatModelName,
      activeChatModelPath: activeChatModelPath ?? this.activeChatModelPath,
      activeChatModelSizeBytes: activeChatModelSizeBytes ?? this.activeChatModelSizeBytes,
      activeEmbeddingModelId: activeEmbeddingModelId ?? this.activeEmbeddingModelId,
      activeEmbeddingModelName: activeEmbeddingModelName ?? this.activeEmbeddingModelName,
      promptSentToLlm: promptSentToLlm ?? this.promptSentToLlm,
      llmExecutionStatus: llmExecutionStatus ?? this.llmExecutionStatus,
      llmRawResponse: llmRawResponse ?? this.llmRawResponse,
      finalAnswer: finalAnswer ?? this.finalAnswer,
      executionTimeMs: executionTimeMs ?? this.executionTimeMs,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'raw_query': rawQuery,
        'detected_intent': detectedIntent,
        'extracted_keywords': jsonEncode(extractedKeywords),
        'stopwords_removed': jsonEncode(stopwordsRemoved),
        'fts_query_string': ftsQueryString,
        'attached_doc_names': jsonEncode(attachedDocNames),
        'fts_matches_count': ftsMatchesCount,
        'fts_matches': jsonEncode(ftsMatches),
        'vector_matches_count': vectorMatchesCount,
        'vector_matches': jsonEncode(vectorMatches),
        'selected_evidence': jsonEncode(selectedEvidence),
        'active_chat_model_id': activeChatModelId,
        'active_chat_model_name': activeChatModelName,
        'active_chat_model_path': activeChatModelPath,
        'active_chat_model_size_bytes': activeChatModelSizeBytes,
        'active_embedding_model_id': activeEmbeddingModelId,
        'active_embedding_model_name': activeEmbeddingModelName,
        'prompt_sent_to_llm': promptSentToLlm,
        'llm_execution_status': llmExecutionStatus,
        'llm_raw_response': llmRawResponse,
        'final_answer': finalAnswer,
        'execution_time_ms': executionTimeMs,
      };

  factory AiDiagnosticLogEntry.fromMap(Map<String, dynamic> map) {
    List<String> decodeStringList(dynamic raw) {
      if (raw == null) return [];
      if (raw is List) return raw.map((e) => e.toString()).toList();
      try {
        final decoded = jsonDecode(raw.toString());
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {}
      return [];
    }

    List<Map<String, dynamic>> decodeMapList(dynamic raw) {
      if (raw == null) return [];
      if (raw is List) return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      try {
        final decoded = jsonDecode(raw.toString());
        if (decoded is List) {
          return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {}
      return [];
    }

    final rawTs = map['timestamp'];
    final DateTime ts = (rawTs is int)
        ? DateTime.fromMillisecondsSinceEpoch(rawTs)
        : (DateTime.tryParse(rawTs?.toString() ?? '') ?? DateTime.now());

    return AiDiagnosticLogEntry(
      id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: ts,
      rawQuery: map['raw_query'] as String? ?? '',
      detectedIntent: map['detected_intent'] as String? ?? 'document_rag',
      extractedKeywords: decodeStringList(map['extracted_keywords']),
      stopwordsRemoved: decodeStringList(map['stopwords_removed']),
      ftsQueryString: map['fts_query_string'] as String? ?? '',
      attachedDocNames: decodeStringList(map['attached_doc_names']),
      ftsMatchesCount: map['fts_matches_count'] as int? ?? 0,
      ftsMatches: decodeMapList(map['fts_matches']),
      vectorMatchesCount: map['vector_matches_count'] as int? ?? 0,
      vectorMatches: decodeMapList(map['vector_matches']),
      selectedEvidence: decodeMapList(map['selected_evidence']),
      activeChatModelId: map['active_chat_model_id'] as String?,
      activeChatModelName: map['active_chat_model_name'] as String?,
      activeChatModelPath: map['active_chat_model_path'] as String?,
      activeChatModelSizeBytes: map['active_chat_model_size_bytes'] as int?,
      activeEmbeddingModelId: map['active_embedding_model_id'] as String?,
      activeEmbeddingModelName: map['active_embedding_model_name'] as String?,
      promptSentToLlm: map['prompt_sent_to_llm'] as String? ?? '',
      llmExecutionStatus: map['llm_execution_status'] as String? ?? 'completed',
      llmRawResponse: map['llm_raw_response'] as String?,
      finalAnswer: map['final_answer'] as String? ?? '',
      executionTimeMs: map['execution_time_ms'] as int? ?? 0,
    );
  }
}

/// Service managing in-memory and database diagnostics logs for AI interactions
class AiDiagnosticsService extends ChangeNotifier {
  static final AiDiagnosticsService _instance = AiDiagnosticsService._internal();
  factory AiDiagnosticsService() => _instance;
  AiDiagnosticsService._internal() {
    ensureInitialized();
  }

  final StorageService _storage = StorageService();
  final List<AiDiagnosticLogEntry> _logs = [];
  bool _isInitialized = false;

  List<AiDiagnosticLogEntry> get logs => List.unmodifiable(_logs);

  /// Ensure persisted historical diagnostic logs are loaded from SQLite
  Future<void> ensureInitialized({bool force = false}) async {
    if (_isInitialized && !force) return;
    try {
      final rows = await _storage.getAllAiDiagnosticLogs(limit: 100);
      _logs.clear();
      for (final r in rows) {
        try {
          _logs.add(AiDiagnosticLogEntry.fromMap(r));
        } catch (_) {}
      }
      _isInitialized = true;
      notifyListeners();
      LoggingService().info('AiDiagnostics', 'Loaded ${_logs.length} historical diagnostic logs from database');
    } catch (e) {
      LoggingService().warn('AiDiagnostics', 'Failed loading initial diagnostic logs: $e');
    }
  }

  /// Add a new diagnostic log entry (persists to SQLite immediately)
  Future<void> addLog(AiDiagnosticLogEntry entry) async {
    await ensureInitialized();
    _logs.removeWhere((l) => l.id == entry.id);
    _logs.insert(0, entry); // latest first
    if (_logs.length > 100) {
      _logs.removeLast();
    }
    notifyListeners();

    try {
      await _storage.insertOrUpdateAiDiagnosticLog(entry.toMap());
    } catch (e) {
      LoggingService().error('AiDiagnostics', 'Error saving diagnostic log to DB: $e');
    }
  }

  /// Update an existing diagnostic log entry in real time (e.g. updating in-progress status)
  Future<void> updateLog(AiDiagnosticLogEntry entry) async {
    await ensureInitialized();
    final idx = _logs.indexWhere((l) => l.id == entry.id);
    if (idx != -1) {
      _logs[idx] = entry;
    } else {
      _logs.insert(0, entry);
    }
    notifyListeners();

    try {
      await _storage.insertOrUpdateAiDiagnosticLog(entry.toMap());
    } catch (e) {
      LoggingService().error('AiDiagnostics', 'Error updating diagnostic log in DB: $e');
    }
  }

  /// Clear all diagnostic logs from memory and database
  Future<void> clearLogs() async {
    _logs.clear();
    notifyListeners();
    try {
      await _storage.clearAiDiagnosticLogs();
    } catch (e) {
      LoggingService().error('AiDiagnostics', 'Error clearing diagnostic logs: $e');
    }
  }

  /// Get storage stats for diagnostics screen
  Future<Map<String, dynamic>> getStorageDiagnostics() async {
    try {
      final db = await _storage.database;

      final docCount = await db.rawQuery('SELECT COUNT(*) as count FROM ${AppConstants.aiDocumentIndexTable}');
      final chunkCount = await db.rawQuery('SELECT COUNT(*) as count FROM ${AppConstants.aiDocumentChunksTable}');
      final embedCount = await db.rawQuery('SELECT COUNT(*) as count FROM ${AppConstants.aiChunkEmbeddingsTable}');
      final modelRows = await _storage.getInstalledModels();

      final docs = await db.query(AppConstants.aiDocumentIndexTable, columns: ['doc_id', 'file_name', 'total_pages', 'status']);

      return {
        'total_documents': Sqflite.firstIntValue(docCount) ?? 0,
        'total_chunks': Sqflite.firstIntValue(chunkCount) ?? 0,
        'total_embeddings': Sqflite.firstIntValue(embedCount) ?? 0,
        'installed_models': modelRows,
        'indexed_docs': docs,
      };
    } catch (e, stack) {
      LoggingService().error('AiDiagnostics', 'Failed to retrieve storage diagnostics: $e', e, stack);
      return {
        'total_documents': 0,
        'total_chunks': 0,
        'total_embeddings': 0,
        'installed_models': <Map<String, dynamic>>[],
        'indexed_docs': <Map<String, dynamic>>[],
        'error': e.toString(),
      };
    }
  }

  /// Get detailed documents for storage inspector modal
  Future<List<Map<String, dynamic>>> getDetailedDocuments() async {
    return await _storage.getDetailedIndexedDocuments();
  }

  /// Get detailed chunks for storage inspector modal
  Future<List<Map<String, dynamic>>> getDetailedChunks({String? docId, String? searchFilter}) async {
    return await _storage.getDetailedChunks(docId: docId, searchFilter: searchFilter);
  }

  /// Get detailed embeddings for storage inspector modal
  Future<List<Map<String, dynamic>>> getDetailedEmbeddings() async {
    return await _storage.getDetailedEmbeddings();
  }
}
