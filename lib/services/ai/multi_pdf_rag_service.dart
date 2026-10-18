import 'dart:io';
import 'package:flutter/foundation.dart';
import '../logging_service.dart';
import '../storage_service.dart';
import 'ai_diagnostics_service.dart';
import 'hybrid_search_service.dart';
import 'local_llm_inference_service.dart';

/// Citation reference pointing to a specific page and snippet in a document
class RagCitation {
  final String fileName;
  final String filePath;
  final int pageNumber;
  final String snippet;

  const RagCitation({
    required this.fileName,
    required this.filePath,
    required this.pageNumber,
    required this.snippet,
  });
}

/// Result of an offline RAG query
class RagAnswerResult {
  final String answer;
  final List<RagCitation> citations;
  final bool hasLocalLlmRun;

  const RagAnswerResult({
    required this.answer,
    required this.citations,
    required this.hasLocalLlmRun,
  });
}

/// Service executing multi-document Retrieval Augmented Generation (RAG) with injection protection
class MultiPdfRagService {
  static final MultiPdfRagService _instance = MultiPdfRagService._internal();
  factory MultiPdfRagService() => _instance;
  MultiPdfRagService._internal();

  final HybridSearchService _searchService = HybridSearchService();
  final StorageService _storage = StorageService();

  static const Set<String> _stopwords = {
    'what', 'is', 'my', 'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'for', 'on', 'with',
    'as', 'by', 'at', 'from', 'this', 'that', 'it', 'are', 'was', 'were', 'be', 'been',
    'have', 'has', 'had', 'do', 'does', 'did', 'can', 'could', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must', 'tell', 'me', 'about', 'show', 'find', 'give', 'how',
    'why', 'where', 'when', 'who', 'which', 'please', 'any', 'some', 'there', 'their', 'they',
    'i', 'you', 'he', 'she', 'we', 'us', 'him', 'her', 'them', 'your', 'his', 'our'
  };

  /// Detect whether the query is a conversational greeting
  static bool isGreetingQuery(String query) {
    final lower = query.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '');
    final greetingWords = {
      'hi', 'hello', 'hey', 'greetings', 'sup', 'yo', 'howdy', 'hola', 'namaste',
      'good morning', 'good afternoon', 'good evening',
      'who are you', 'what can you do', 'how are you', 'help'
    };
    if (greetingWords.contains(lower)) return true;
    final tokens = lower.split(RegExp(r'\s+'));
    if (tokens.length <= 2 && (tokens.contains('hi') || tokens.contains('hello') || tokens.contains('hey'))) {
      return true;
    }
    return false;
  }

  /// Extract lines matching query keywords to present a clear, targeted answer
  static String? extractTargetedSnippet(String chunkText, List<String> queryKeywords) {
    if (queryKeywords.isEmpty) return null;
    final lines = chunkText.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final matchingLines = <String>[];
    for (final line in lines) {
      final lineLower = line.toLowerCase();
      if (queryKeywords.any((kw) => lineLower.contains(kw.toLowerCase()))) {
        matchingLines.add(line);
      }
    }
    if (matchingLines.isNotEmpty) {
      return matchingLines.join('\n');
    }
    return null;
  }

  /// Ask a question across indexed PDF documents
  Future<RagAnswerResult> answerQuestion({
    required String question,
    List<String>? targetDocIds,
    int maxEvidenceChunks = 4,
  }) async {
    final stopwatch = Stopwatch()..start();
    final trimmedQuery = question.trim();
    if (trimmedQuery.isEmpty) {
      return const RagAnswerResult(
        answer: 'Please enter a question to ask.',
        citations: [],
        hasLocalLlmRun: false,
      );
    }

    LoggingService().info('MultiPdfRag', 'Answering question: "$trimmedQuery" (targets: $targetDocIds)');

    // Resolve attached document names for logging and friendly responses
    final attachedDocNames = <String>[];
    if (targetDocIds != null && targetDocIds.isNotEmpty) {
      for (final docId in targetDocIds) {
        final doc = await _storage.getAiDocument(docId);
        if (doc != null && doc['file_name'] != null) {
          attachedDocNames.add(doc['file_name'] as String);
        }
      }
    }

    // 1. Check for Conversational Greeting intent
    if (isGreetingQuery(trimmedQuery)) {
      final docContext = attachedDocNames.isNotEmpty
          ? 'I have your attached document (${attachedDocNames.join(", ")}) ready and indexed. Ask me anything about it—such as summarizing sections, finding key dates, qualifications, or numbers!'
          : 'You can attach PDFs using the **+ Add PDF** button above to ask questions, extract figures, or summarize sections.';

      final greetingAnswer =
          'Hello! I am your 100% offline, on-device AI document assistant for PasswordPDF.\n\n$docContext';

      // Log in diagnostics
      AiDiagnosticsService().addLog(AiDiagnosticLogEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        rawQuery: trimmedQuery,
        detectedIntent: 'greeting',
        extractedKeywords: [],
        stopwordsRemoved: [],
        ftsQueryString: '',
        attachedDocNames: attachedDocNames,
        ftsMatchesCount: 0,
        ftsMatches: [],
        vectorMatchesCount: 0,
        vectorMatches: [],
        selectedEvidence: [],
        activeChatModelId: null,
        activeChatModelName: null,
        activeChatModelPath: null,
        activeChatModelSizeBytes: null,
        activeEmbeddingModelId: null,
        activeEmbeddingModelName: null,
        promptSentToLlm: '',
        llmExecutionStatus: 'greeting_handled',
        llmRawResponse: null,
        finalAnswer: greetingAnswer,
        executionTimeMs: stopwatch.elapsedMilliseconds,
      ));

      return RagAnswerResult(
        answer: greetingAnswer,
        citations: [],
        hasLocalLlmRun: false,
      );
    }

    // 2. Tokenize and extract keywords / stopwords
    final allWords = trimmedQuery.replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), ' ').split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final contentKeywords = allWords.where((w) => !_stopwords.contains(w.toLowerCase())).toList();
    final stopwordsFiltered = allWords.where((w) => _stopwords.contains(w.toLowerCase())).toList();
    final ftsQueryStr = contentKeywords.isNotEmpty
        ? contentKeywords.map((t) => '$t*').join(' OR ')
        : allWords.map((t) => '$t*').join(' OR ');

    // 3. Retrieve top relevant chunks via Hybrid Search
    List<SearchResultItem> searchResults = [];
    if (targetDocIds == null || targetDocIds.isNotEmpty) {
      try {
        searchResults = await _searchService.search(
          query: trimmedQuery,
          targetDocIds: targetDocIds,
          limit: maxEvidenceChunks,
        );
        LoggingService().info('MultiPdfRag', 'Search returned ${searchResults.length} relevant chunk(s)');
      } catch (e, stack) {
        LoggingService().error('MultiPdfRag', 'Search failed: $e', e, stack);
        searchResults = [];
      }
    }

    if (searchResults.isEmpty) {
      final noEvidenceAnswer = targetDocIds == null || targetDocIds.isEmpty
          ? 'Hello! I am your 100% offline, on-device AI document assistant for PasswordPDF.\n\n'
            'Attach a PDF using **+ Add PDF** to ask questions about your documents!'
          : 'No matching document evidence found for "$trimmedQuery" in the attached PDF(s). '
            'Try phrasing your question with specific terms from the document.';

      AiDiagnosticsService().addLog(AiDiagnosticLogEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        rawQuery: trimmedQuery,
        detectedIntent: 'document_rag',
        extractedKeywords: contentKeywords,
        stopwordsRemoved: stopwordsFiltered,
        ftsQueryString: ftsQueryStr,
        attachedDocNames: attachedDocNames,
        ftsMatchesCount: 0,
        ftsMatches: [],
        vectorMatchesCount: 0,
        vectorMatches: [],
        selectedEvidence: [],
        activeChatModelId: null,
        activeChatModelName: null,
        activeChatModelPath: null,
        activeChatModelSizeBytes: null,
        activeEmbeddingModelId: null,
        activeEmbeddingModelName: null,
        promptSentToLlm: '',
        llmExecutionStatus: 'no_evidence_found',
        llmRawResponse: null,
        finalAnswer: noEvidenceAnswer,
        executionTimeMs: stopwatch.elapsedMilliseconds,
      ));

      return RagAnswerResult(
        answer: noEvidenceAnswer,
        citations: [],
        hasLocalLlmRun: false,
      );
    }

    // 4. Build citations
    final citations = searchResults.map((item) {
      return RagCitation(
        fileName: item.fileName,
        filePath: item.filePath,
        pageNumber: item.pageNumber,
        snippet: item.chunkText.length > 200
            ? '${item.chunkText.substring(0, 197)}...'
            : item.chunkText,
      );
    }).toList();

    // 5. Construct grounded prompt
    final prompt = buildGroundedPrompt(
      userQuery: trimmedQuery,
      evidenceChunks: searchResults,
    );

    // 6. On-Device LLM Inference with Concurrency Mutex and Extractive Fallback
    final localLlm = LocalLlmInferenceService();
    final activeModel = await localLlm.getActiveModelInfo();
    final activeEmbedder = await _storage.getActiveInstalledModel('embedding');
    String? llmAnswer;
    String llmStatus = 'none';

    if (activeModel != null) {
      llmAnswer = await localLlm.generateCompletion(
        prompt: prompt,
        maxTokens: 256,
        temperature: 0.2,
      );
      llmStatus = (llmAnswer != null && llmAnswer.isNotEmpty)
          ? 'executed'
          : 'native_channel_returned_null';
    } else {
      llmStatus = 'no_active_llm_model';
    }

    String finalAnswerText;
    bool hasLocalLlmRun = false;

    if (llmAnswer != null && llmAnswer.isNotEmpty) {
      finalAnswerText = llmAnswer;
      hasLocalLlmRun = true;
    } else {
      // High-precision Grounded Extractive Answer
      final topMatch = searchResults.first;
      final targeted = extractTargetedSnippet(topMatch.chunkText, contentKeywords);

      final snippetEmphasis = targeted != null
          ? '**Key Evidence:**\n> $targeted\n\n'
          : '';

      final modelNote = activeModel != null
          ? '\n\n*(Model ${activeModel['display_name']} active — grounded extractive reference shown)*'
          : '\n\n*(No local chat model active. Download Qwen or Gemma in AI Models to enable full generative synthesis)*';

      finalAnswerText =
          'Based on "${topMatch.fileName}" (Page ${topMatch.pageNumber}):\n\n'
          '$snippetEmphasis'
          '**Context:**\n'
          '${topMatch.chunkText}$modelNote';
    }

    // 7. Log diagnostic entry
    final selectedEvidenceData = searchResults.map((r) => {
      'fileName': r.fileName,
      'pageNumber': r.pageNumber,
      'score': r.score,
      'snippet': r.chunkText.length > 150 ? '${r.chunkText.substring(0, 147)}...' : r.chunkText,
    }).toList();

    AiDiagnosticsService().addLog(AiDiagnosticLogEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      rawQuery: trimmedQuery,
      detectedIntent: 'document_rag',
      extractedKeywords: contentKeywords,
      stopwordsRemoved: stopwordsFiltered,
      ftsQueryString: ftsQueryStr,
      attachedDocNames: attachedDocNames,
      ftsMatchesCount: searchResults.length,
      ftsMatches: selectedEvidenceData,
      vectorMatchesCount: searchResults.length,
      vectorMatches: selectedEvidenceData,
      selectedEvidence: selectedEvidenceData,
      activeChatModelId: activeModel?['model_id'] as String?,
      activeChatModelName: activeModel?['display_name'] as String?,
      activeChatModelPath: activeModel?['file_path'] as String?,
      activeChatModelSizeBytes: (activeModel != null && activeModel['file_path'] != null)
          ? File(activeModel['file_path'] as String).lengthSync()
          : null,
      activeEmbeddingModelId: activeEmbedder?['model_id'] as String?,
      activeEmbeddingModelName: activeEmbedder?['display_name'] as String?,
      promptSentToLlm: prompt,
      llmExecutionStatus: llmStatus,
      llmRawResponse: llmAnswer,
      finalAnswer: finalAnswerText,
      executionTimeMs: stopwatch.elapsedMilliseconds,
    ));

    return RagAnswerResult(
      answer: finalAnswerText,
      citations: citations,
      hasLocalLlmRun: hasLocalLlmRun,
    );
  }

  /// Construct prompt with strict XML encapsulation and prompt injection defense
  String buildGroundedPrompt({
    required String userQuery,
    required List<SearchResultItem> evidenceChunks,
  }) {
    final evidenceBuffer = StringBuffer();
    for (int i = 0; i < evidenceChunks.length; i++) {
      final res = evidenceChunks[i];
      final sanitizedChunk = res.chunkText.replaceAll('</document_evidence>', '');
      evidenceBuffer.writeln(
        '--- Passage ${i + 1} [Source: "${res.fileName}", Page: ${res.pageNumber}] ---\n$sanitizedChunk\n',
      );
    }

    final sanitizedQuery = userQuery.replaceAll('</document_evidence>', '');

    return '''
<system_instruction>
You are PasswordPDF AI, a grounded on-device document assistant.
Answer the user's question accurately using ONLY the verified excerpts inside <document_evidence>.
If the answer cannot be determined from the excerpts, state clearly that the document does not contain this information.
Never fabricate facts or cite outside knowledge. Cite the source document and page number in your response using format [Doc: filename, Page X].
</system_instruction>

<document_evidence>
$evidenceBuffer
</document_evidence>

User Question: $sanitizedQuery
Answer:
''';
  }

  /// Extract structured citations from text response
  List<RagCitation> extractCitationsFromText(String response) {
    final regex = RegExp(r'\[(?:Doc|Source):\s*([^,]+),\s*Page:\s*(\d+)\]', caseSensitive: false);
    final citations = <RagCitation>[];
    for (final match in regex.allMatches(response)) {
      final file = match.group(1)?.trim() ?? '';
      final page = int.tryParse(match.group(2)?.trim() ?? '1') ?? 1;
      if (file.isNotEmpty) {
        citations.add(RagCitation(
          fileName: file,
          filePath: '',
          pageNumber: page,
          snippet: '',
        ));
      }
    }
    return citations;
  }
}
