import 'package:flutter/foundation.dart';
import '../storage_service.dart';

/// Detailed diagnostic entry capturing the complete RAG and AI inference pipeline
class AiDiagnosticLogEntry {
  final String id;
  final DateTime timestamp;
  final String rawQuery;
  final String detectedIntent; // 'greeting', 'document_rag', 'empty'
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
  final String llmExecutionStatus; // 'executed', 'native_returned_null', 'missing_model', 'greeting'
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
}

/// Service managing in-memory and database diagnostics logs for AI interactions
class AiDiagnosticsService extends ChangeNotifier {
  static final AiDiagnosticsService _instance = AiDiagnosticsService._internal();
  factory AiDiagnosticsService() => _instance;
  AiDiagnosticsService._internal();

  final List<AiDiagnosticLogEntry> _logs = [];

  List<AiDiagnosticLogEntry> get logs => List.unmodifiable(_logs);

  void addLog(AiDiagnosticLogEntry entry) {
    _logs.insert(0, entry); // latest first
    if (_logs.length > 50) {
      _logs.removeLast();
    }
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  /// Get storage stats for diagnostics screen
  Future<Map<String, dynamic>> getStorageDiagnostics() async {
    final storage = StorageService();
    final db = await storage.database;

    final docCount = await db.rawQuery('SELECT COUNT(*) as count FROM ai_documents');
    final chunkCount = await db.rawQuery('SELECT COUNT(*) as count FROM ai_document_chunks');
    final embedCount = await db.rawQuery('SELECT COUNT(*) as count FROM ai_chunk_embeddings');
    final modelRows = await storage.getInstalledModels();

    final docs = await db.query('ai_documents', columns: ['doc_id', 'file_name', 'total_pages', 'status']);

    return {
      'total_documents': docCount.first['count'] ?? 0,
      'total_chunks': chunkCount.first['count'] ?? 0,
      'total_embeddings': embedCount.first['count'] ?? 0,
      'installed_models': modelRows,
      'indexed_docs': docs,
    };
  }
}
