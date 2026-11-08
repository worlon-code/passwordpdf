import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/constants/app_constants.dart';
import '../logging_service.dart';
import '../storage_service.dart';
import 'ai_diagnostics_service.dart';
import 'ai_prompt_service.dart';
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

/// Service executing multi-document Retrieval Augmented Generation (RAG) with injection protection,
/// real GGUF model execution, profile header pinning, and smart extractive QA synthesis.
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
    'i', 'you', 'he', 'she', 'we', 'us', 'him', 'her', 'them', 'your', 'his', 'our',
    'u', 'ur', 'r', 'im', 'ive', 'id'
  };

  /// Normalize chat shorthand before intent detection and tokenization
  static String normalizeChatShorthand(String query) {
    var text = query;
    const shorthandMap = {
      r'\bu\b': 'you',
      r'\bur\b': 'your',
      r'\br\b': 'are',
      r'\bwat\b': 'what',
      r'\bwht\b': 'what',
      r'\bhw\b': 'how',
      r'\bpls\b': 'please',
      r'\bplz\b': 'please',
      r'\bthx\b': 'thanks',
      r'\bty\b': 'thank you',
      r'\bcuz\b': 'because',
      r'\bcos\b': 'because',
    };
    for (final entry in shorthandMap.entries) {
      text = text.replaceAll(RegExp(entry.key, caseSensitive: false), entry.value);
    }
    return text;
  }

  /// Detect whether the query is a conversational greeting or assistant-identity meta question
  static Map<String, String>? checkConversationalOrMetaIntent(String query, List<String> attachedDocNames) {
    final normalized = normalizeChatShorthand(query).trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    final cleanWords = normalized.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (cleanWords.isEmpty) return null;

    final singleGreetings = {'hi', 'hello', 'hey', 'greetings', 'namaste', 'hola', 'sup', 'yo', 'howdy'};
    final joined = cleanWords.join(' ');

    if (singleGreetings.contains(joined) ||
        (cleanWords.length <= 2 && (cleanWords.contains('hi') || cleanWords.contains('hello') || cleanWords.contains('hey')))) {
      final docContext = attachedDocNames.isNotEmpty
          ? 'I have your attached document (${attachedDocNames.join(", ")}) ready and indexed. Ask me anything about it—such as summarizing sections, finding key dates, qualifications, or numbers!'
          : 'You can attach PDFs using the **+ Add PDF** button above to ask questions, extract figures, or summarize sections.';
      return {
        'intent': 'greeting',
        'answer': 'Hello! I am your 100% offline, on-device AI document assistant for PasswordPDF.\n\n$docContext',
      };
    }

    final metaPhrases = [
      'who are you', 'what are you', 'what can you do', 'how do you work',
      'are you offline', 'how does this work', 'help'
    ];
    if (metaPhrases.any((p) => joined == p || joined.startsWith('$p '))) {
      return {
        'intent': 'assistant_identity',
        'answer': 'I am PasswordPDF AI, your 100% private, on-device document assistant.\n\n'
            'I analyze your attached PDFs completely offline without sending any data to external cloud servers. '
            'You can ask me to summarize documents, find specific qualifications, grades (CGPA), contact details, '
            'or answer questions with verified page citations.',
      };
    }

    return null;
  }

  /// Check if the query is asking about candidate profile / identity / header details
  static bool isProfileQuery(String queryLower) {
    final patterns = [
      'name', 'who am i', 'candidate', 'applicant', 'whose resume', 'whose document',
      'cgpa', 'gpa', 'marks', 'percentage', 'grade',
      'email', 'phone', 'mobile', 'contact', 'location', 'address', 'linkedin', 'github',
      'experience', 'company', 'role', 'skills', 'college', 'university', 'degree',
      'study', 'education', 'school', 'qualification'
    ];
    return patterns.any((p) => queryLower.contains(p));
  }

  /// Expand query keywords with synonyms and document title tokens
  static List<String> expandKeywords(List<String> keywords, String queryLower, List<String> attachedDocNames) {
    final expanded = Set<String>.from(keywords.map((k) => k.toLowerCase()));

    if (queryLower.contains('cgpa') || queryLower.contains('gpa') || queryLower.contains('percentage') || queryLower.contains('marks')) {
      expanded.addAll(['cgpa', 'gpa', 'education', 'b.tech', 'degree', '10']);
    }

    if (queryLower.contains('name') || queryLower.contains('who am i') || queryLower.contains('candidate') || queryLower.contains('applicant')) {
      expanded.addAll(['summary', 'professional', 'email', 'linkedin']);
      for (final docName in attachedDocNames) {
        final words = docName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), ' ').split(RegExp(r'\s+'));
        for (final w in words) {
          final wLower = w.toLowerCase();
          if (wLower.length >= 2 && !_stopwords.contains(wLower) && wLower != 'pdf') {
            expanded.add(wLower);
          }
        }
      }
    }

    if (queryLower.contains('experience') || queryLower.contains('work') || queryLower.contains('company')) {
      expanded.addAll(['experience', 'years', 'analyst', 'engineer', 'developer', 'company']);
    }

    return expanded.toList();
  }

  /// Retrieve the Page 1 Chunk 0 header chunk for a document
  Future<SearchResultItem?> getPage1HeaderChunk(String docId) async {
    try {
      final db = await _storage.database;
      final rows = await db.query(
        AppConstants.aiDocumentChunksTable,
        where: 'doc_id = ? AND page_number = 1 AND chunk_index = 0',
        whereArgs: [docId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final doc = await _storage.getAiDocument(docId);
        final fileName = doc?['file_name'] as String? ?? 'Document';
        final filePath = doc?['file_path'] as String? ?? '';
        return SearchResultItem(
          chunkId: rows.first['chunk_id'] as String,
          docId: docId,
          fileName: fileName,
          filePath: filePath,
          pageNumber: 1,
          chunkText: rows.first['chunk_text'] as String,
          score: 1.0,
        );
      }
    } catch (_) {}
    return null;
  }

  /// Ask a question across indexed PDF documents
  Future<RagAnswerResult> answerQuestion({
    required String question,
    List<String>? targetDocIds,
    int maxEvidenceChunks = 4,
    void Function(String status)? onStatusUpdate,
  }) async {
    final stopwatch = Stopwatch()..start();
    final trimmedRaw = question.trim();
    if (trimmedRaw.isEmpty) {
      return const RagAnswerResult(
        answer: 'Please enter a question to ask.',
        citations: [],
        hasLocalLlmRun: false,
      );
    }

    final logId = 'query_${DateTime.now().millisecondsSinceEpoch}';
    final normalizedQuery = normalizeChatShorthand(trimmedRaw);
    final queryLower = normalizedQuery.toLowerCase();

    onStatusUpdate?.call('Analyzing question...');
    LoggingService().info('MultiPdfRag', 'Answering question: "$normalizedQuery" (targets: $targetDocIds)');

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

    // Step 0: Immediate in-progress log entry for post-mortem tracing
    var currentLog = AiDiagnosticLogEntry(
      id: logId,
      timestamp: DateTime.now(),
      rawQuery: trimmedRaw,
      detectedIntent: 'in_progress',
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
      llmExecutionStatus: 'in_progress: Initializing RAG pipeline...',
      llmRawResponse: null,
      finalAnswer: 'Analyzing query...',
      executionTimeMs: 0,
    );
    await AiDiagnosticsService().addLog(currentLog);

    // 1. Check for Conversational Greeting or Assistant Identity Meta Intent
    final metaMatch = checkConversationalOrMetaIntent(normalizedQuery, attachedDocNames);
    if (metaMatch != null) {
      final intent = metaMatch['intent']!;
      final answer = metaMatch['answer']!;

      currentLog = currentLog.copyWith(
        detectedIntent: intent,
        llmExecutionStatus: '${intent}_handled',
        finalAnswer: answer,
        executionTimeMs: stopwatch.elapsedMilliseconds,
      );
      await AiDiagnosticsService().updateLog(currentLog);

      return RagAnswerResult(
        answer: answer,
        citations: [],
        hasLocalLlmRun: false,
      );
    }

    // 2. Tokenize and extract keywords / stopwords (Banning 1-char wildcards)
    final allWords = normalizedQuery.replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), ' ').split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final contentKeywords = allWords
        .where((w) => !_stopwords.contains(w.toLowerCase()) && (w.length >= 2 || RegExp(r'^\d+$').hasMatch(w)))
        .toList();
    final stopwordsFiltered = allWords.where((w) => _stopwords.contains(w.toLowerCase()) || w.length < 2).toList();

    final expandedKeywords = expandKeywords(contentKeywords, queryLower, attachedDocNames);

    final ftsQueryStr = expandedKeywords.isNotEmpty
        ? expandedKeywords.map((t) => '$t*').join(' OR ')
        : allWords.where((w) => w.length >= 2).map((t) => '$t*').join(' OR ');

    onStatusUpdate?.call('Scanning document chunks...');
    currentLog = currentLog.copyWith(
      extractedKeywords: contentKeywords,
      stopwordsRemoved: stopwordsFiltered,
      ftsQueryString: ftsQueryStr,
      llmExecutionStatus: 'in_progress: Searching document chunks with FTS5 and vector similarity...',
    );
    await AiDiagnosticsService().updateLog(currentLog);

    // 3. Retrieve top relevant chunks via Hybrid Search
    List<SearchResultItem> searchResults = [];
    if (targetDocIds == null || targetDocIds.isNotEmpty) {
      try {
        searchResults = await _searchService.search(
          query: expandedKeywords.isNotEmpty ? expandedKeywords.join(' ') : normalizedQuery,
          targetDocIds: targetDocIds,
          limit: maxEvidenceChunks,
        );
        LoggingService().info('MultiPdfRag', 'Search returned ${searchResults.length} relevant chunk(s)');
      } catch (e, stack) {
        LoggingService().error('MultiPdfRag', 'Search failed: $e', e, stack);
        searchResults = [];
      }
    }

    // 4. Pin Page 1 Header Chunk for Profile Queries or Sparse Results
    if (targetDocIds != null && targetDocIds.isNotEmpty) {
      if (isProfileQuery(queryLower) || searchResults.length < 2) {
        for (final docId in targetDocIds) {
          final headerChunk = await getPage1HeaderChunk(docId);
          if (headerChunk != null) {
            // Remove if already in results
            searchResults.removeWhere((r) => r.chunkId == headerChunk.chunkId);
            // Insert at top as Passage 1
            searchResults.insert(0, headerChunk);
          }
        }
      }
    }

    if (searchResults.isEmpty) {
      final noEvidenceAnswer = targetDocIds == null || targetDocIds.isEmpty
          ? 'Hello! I am your 100% offline, on-device AI document assistant for PasswordPDF.\n\n'
            'Attach a PDF using **+ Add PDF** to ask questions about your documents!'
          : 'No matching document evidence found for "$normalizedQuery" in the attached PDF(s). '
            'Try phrasing your question with specific terms from the document.';

      currentLog = currentLog.copyWith(
        detectedIntent: 'document_rag',
        extractedKeywords: contentKeywords,
        stopwordsRemoved: stopwordsFiltered,
        ftsQueryString: ftsQueryStr,
        ftsMatchesCount: 0,
        vectorMatchesCount: 0,
        llmExecutionStatus: 'no_evidence_found',
        finalAnswer: noEvidenceAnswer,
        executionTimeMs: stopwatch.elapsedMilliseconds,
      );
      await AiDiagnosticsService().updateLog(currentLog);

      return RagAnswerResult(
        answer: noEvidenceAnswer,
        citations: [],
        hasLocalLlmRun: false,
      );
    }

    // 5. Build citations
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

    // 6. On-Device LLM Inference with Model Caching and Extractive Fallback
    final localLlm = LocalLlmInferenceService();
    final activeModel = await localLlm.getActiveModelInfo();
    final activeEmbedder = await _storage.getActiveInstalledModel('embedding');
    final activeModelId = activeModel?['model_id'] as String?;
    final activeDisplayName = activeModel?['display_name'] as String? ?? 'On-Device AI';

    onStatusUpdate?.call('Matching vectors & keywords...');

    // Construct grounded prompt with ChatML or Gemma template using active versioned master prompt
    final masterPromptText = await AiPromptService().getActivePromptText();
    final prompt = buildGroundedPrompt(
      userQuery: normalizedQuery,
      evidenceChunks: searchResults,
      modelId: activeModelId,
      systemPrompt: masterPromptText,
      keywords: contentKeywords,
    );

    final selectedEvidenceData = searchResults.map((r) => {
      'fileName': r.fileName,
      'pageNumber': r.pageNumber,
      'score': r.score,
      'snippet': r.chunkText.length > 150 ? '${r.chunkText.substring(0, 147)}...' : r.chunkText,
    }).toList();

    onStatusUpdate?.call('Running on-device AI model ($activeDisplayName)...');
    currentLog = currentLog.copyWith(
      promptSentToLlm: prompt,
      activeChatModelId: activeModelId,
      activeChatModelName: activeDisplayName,
      activeChatModelPath: activeModel?['file_path'] as String?,
      activeChatModelSizeBytes: (activeModel != null && activeModel['file_path'] != null)
          ? File(activeModel['file_path'] as String).lengthSync()
          : null,
      activeEmbeddingModelId: activeEmbedder?['model_id'] as String?,
      activeEmbeddingModelName: activeEmbedder?['display_name'] as String?,
      ftsMatchesCount: searchResults.length,
      ftsMatches: selectedEvidenceData,
      vectorMatchesCount: searchResults.length,
      vectorMatches: selectedEvidenceData,
      selectedEvidence: selectedEvidenceData,
      llmExecutionStatus: 'in_progress: Running on-device LLM inference on $activeDisplayName...',
    );
    await AiDiagnosticsService().updateLog(currentLog);

    String? llmAnswer;
    String llmStatus = 'none';

    if (activeModel != null) {
      try {
        final llmResult = await localLlm.generateCompletion(
          prompt: prompt,
          maxTokens: LocalLlmInferenceService.defaultMaxTokens,
          temperature: 0.1,
        );
        llmAnswer = llmResult.text;
        if (llmResult.isSuccess) {
          llmStatus = 'executed';
        } else {
          llmStatus = '${llmResult.status} (used extractive answer)';
        }
      } catch (e) {
        LoggingService().error('MultiPdfRag', 'LLM generation exception: $e');
        llmStatus = 'llm_error: $e (used extractive answer)';
      }
    } else {
      llmStatus = 'no_active_llm_model (used extractive answer)';
    }

    String finalAnswerText;
    bool hasLocalLlmRun = false;

    if (llmAnswer != null && llmAnswer.isNotEmpty) {
      finalAnswerText = llmAnswer;
      hasLocalLlmRun = true;
    } else {
      // High-precision Grounded Extractive Answer (Fix 5)
      onStatusUpdate?.call('Extracting grounded answer from document...');
      finalAnswerText = synthesizeExtractiveAnswer(
        searchResults: searchResults,
        contentKeywords: contentKeywords,
        queryLower: queryLower,
        activeModel: activeModel,
      );
    }

    onStatusUpdate?.call('Finalizing response...');

    final actualCitations = resolveActualCitations(
      answerText: finalAnswerText,
      evidenceChunks: searchResults,
    );

    currentLog = currentLog.copyWith(
      detectedIntent: 'document_rag',
      llmExecutionStatus: llmStatus,
      llmRawResponse: llmAnswer,
      finalAnswer: finalAnswerText,
      executionTimeMs: stopwatch.elapsedMilliseconds,
    );
    await AiDiagnosticsService().updateLog(currentLog);

    return RagAnswerResult(
      answer: finalAnswerText,
      citations: actualCitations,
      hasLocalLlmRun: hasLocalLlmRun,
    );
  }

  /// Synthesizes high-precision grounded answers via pattern extraction and multi-line windows
  static String synthesizeExtractiveAnswer({
    required List<SearchResultItem> searchResults,
    required List<String> contentKeywords,
    required String queryLower,
    required Map<String, dynamic>? activeModel,
  }) {
    // 1. Direct CGPA / GPA Pattern Extractor
    if (queryLower.contains('cgpa') || queryLower.contains('gpa') || queryLower.contains('percentage') || queryLower.contains('marks')) {
      final cgpaRegex = RegExp(r'(?:CGPA|GPA|Score|Percentage)\s*[:\-]?\s*([0-9]+(?:\.[0-9]+)?(?:\s*\/\s*[0-9]+)?)', caseSensitive: false);
      for (final chunk in searchResults) {
        final match = cgpaRegex.firstMatch(chunk.chunkText);
        if (match != null) {
          final val = match.group(1)?.trim() ?? '';
          final window = extractMultiLineWindow(chunk.chunkText, ['cgpa', 'gpa', val]);
          return 'Your CGPA is **$val** [Doc: ${chunk.fileName}, Page ${chunk.pageNumber}].\n\n'
              '**Source Excerpt:**\n'
              '> $window';
        }
      }
    }

    // 2. Direct Candidate Name / Identity Pattern Extractor
    if (queryLower.contains('name') || queryLower.contains('who am i') || queryLower.contains('candidate') || queryLower.contains('applicant')) {
      for (final chunk in searchResults) {
        // Look for title hint prepended in Chunk 0
        final hintMatch = RegExp(r'Candidate Hint:\s*([^\]\n]+)', caseSensitive: false).firstMatch(chunk.chunkText);
        if (hintMatch != null) {
          var name = hintMatch.group(1)?.trim() ?? '';
          name = name.replaceAll(RegExp(r'\bresume\b|\bcv\b', caseSensitive: false), '').trim();
          if (name.isNotEmpty) {
            return 'Your name is **$name** [Doc: ${chunk.fileName}, Page 1].\n\n'
                '*(Derived from candidate document header and verified filename)*';
          }
        }

        // Look for email local-part
        final emailMatch = RegExp(r'([a-zA-Z0-9._%+-]+)@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}').firstMatch(chunk.chunkText);
        if (emailMatch != null) {
          final local = emailMatch.group(1)!;
          final words = local.split(RegExp(r'[\._\-]')).where((w) => w.length >= 2).map((w) => '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
          if (words.isNotEmpty) {
            return 'Your name is **$words** [Doc: ${chunk.fileName}, Page 1 — email: ${emailMatch.group(0)}].';
          }
        }
      }
    }

    // 3. Multi-line window extraction around matching keywords
    final topMatch = searchResults.first;
    final window = extractMultiLineWindow(topMatch.chunkText, contentKeywords);

    final modelNote = activeModel != null
        ? '\n\n*(Model ${activeModel['display_name']} active — grounded extractive answer shown)*'
        : '\n\n*(No local chat model active. Download Qwen or Gemma in AI Models to enable full generative synthesis)*';

    return 'Based on "${topMatch.fileName}" (Page ${topMatch.pageNumber}):\n\n'
        '**Key Evidence:**\n'
        '> $window\n\n'
        '*(Context excerpt)*:\n'
        '${topMatch.chunkText}$modelNote';
  }

  /// Extracts a multi-line window around matched keywords, preventing single-line truncated outputs
  static String extractMultiLineWindow(String text, List<String> keywords) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return text;
    if (keywords.isEmpty) return lines.take(3).join('\n');

    int matchIdx = -1;
    for (int i = 0; i < lines.length; i++) {
      final lLower = lines[i].toLowerCase();
      if (keywords.any((kw) => lLower.contains(kw.toLowerCase()))) {
        matchIdx = i;
        break;
      }
    }

    if (matchIdx != -1) {
      final start = (matchIdx - 1).clamp(0, lines.length - 1);
      final end = (matchIdx + 3).clamp(0, lines.length);
      return lines.sublist(start, end).join('\n');
    }

    return lines.take(3).join('\n');
  }

  /// Construct prompt with strict ChatML, Gemma, or XML structure
  String buildGroundedPrompt({
    required String userQuery,
    required List<SearchResultItem> evidenceChunks,
    String? modelId,
    String? systemPrompt,
    List<String>? keywords,
  }) {
    final evidenceBuffer = StringBuffer();
    final chunksToUse = evidenceChunks.take(3).toList();
    for (int i = 0; i < chunksToUse.length; i++) {
      final res = chunksToUse[i];
      var sanitizedChunk = res.chunkText.replaceAll('</document_evidence>', '').trim();
      if (sanitizedChunk.length > 450) {
        if (keywords != null && keywords.isNotEmpty) {
          sanitizedChunk = extractMultiLineWindow(sanitizedChunk, keywords);
          if (sanitizedChunk.length > 450) {
            sanitizedChunk = '${sanitizedChunk.substring(0, 447)}...';
          }
        } else {
          sanitizedChunk = '${sanitizedChunk.substring(0, 447)}...';
        }
      }
      evidenceBuffer.writeln(
        '--- Passage ${i + 1} [Source: "${res.fileName}", Page: ${res.pageNumber}] ---\n$sanitizedChunk\n',
      );
    }

    final sanitizedQuery = userQuery.replaceAll('</document_evidence>', '');
    final isQwen = (modelId ?? '').toLowerCase().contains('qwen');
    final isGemma = (modelId ?? '').toLowerCase().contains('gemma');

    final activeSystemPrompt = (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        ? systemPrompt.trim()
        : AiPromptService.defaultMasterPromptText.trim();

    if (isQwen) {
      return '''<|im_start|>system
$activeSystemPrompt<|im_end|>
<|im_start|>user
<document_evidence>
$evidenceBuffer
</document_evidence>

Question: $sanitizedQuery<|im_end|>
<|im_start|>assistant
''';
    }

    if (isGemma) {
      return '''<start_of_turn>user
$activeSystemPrompt

<document_evidence>
$evidenceBuffer
</document_evidence>

Question: $sanitizedQuery<end_of_turn>
<start_of_turn>model
''';
    }

    return '''
<system_instruction>
$activeSystemPrompt
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

  /// Resolves only the actual documents and pages that the answer was taken from or based on
  List<RagCitation> resolveActualCitations({
    required String answerText,
    required List<SearchResultItem> evidenceChunks,
  }) {
    if (evidenceChunks.isEmpty) return [];

    final citedItems = <RagCitation>[];
    final seenKeys = <String>{};

    void addCitation(String fileName, int pageNumber, String filePath, String snippet) {
      final cleanFileName = fileName.trim().replaceAll('"', '');
      final key = '${cleanFileName.toLowerCase()}::$pageNumber';
      if (!seenKeys.contains(key)) {
        seenKeys.add(key);
        citedItems.add(RagCitation(
          fileName: cleanFileName,
          filePath: filePath,
          pageNumber: pageNumber,
          snippet: snippet.length > 200 ? '${snippet.substring(0, 197)}...' : snippet,
        ));
      }
    }

    // 1. Look for explicit citations inside the final answer text
    final explicitPatterns = [
      RegExp(r'\[(?:Doc|Source|Passage):\s*"?([^,\n\]]+)?"?,\s*Page:?\s*(\d+)\]', caseSensitive: false),
      RegExp(r'\["?([^,\n\]]+\.pdf)"?,\s*Page:?\s*(\d+)\]', caseSensitive: false),
      RegExp(r'Based on\s+"?([^"\n\(\)]+\.pdf)"?\s*\((?:Page|p\.)\s*(\d+)\)', caseSensitive: false),
      RegExp(r'"?([^"\n\(\)]+\.pdf)"?\s*\((?:Page|p\.)\s*(\d+)\)', caseSensitive: false),
    ];

    for (final pattern in explicitPatterns) {
      for (final match in pattern.allMatches(answerText)) {
        final fName = match.group(1)?.trim().replaceAll('"', '') ?? '';
        final page = int.tryParse(match.group(2)?.trim() ?? '1') ?? 1;
        if (fName.isNotEmpty) {
          final chunkMatch = evidenceChunks.where((c) =>
            c.fileName.toLowerCase() == fName.toLowerCase() ||
            c.fileName.toLowerCase().contains(fName.toLowerCase()) ||
            fName.toLowerCase().contains(c.fileName.toLowerCase())
          ).firstOrNull;

          if (chunkMatch != null) {
            addCitation(chunkMatch.fileName, page, chunkMatch.filePath, chunkMatch.chunkText);
          } else {
            addCitation(fName, page, '', '');
          }
        }
      }
    }

    // If explicit citations were matched, return ONLY those
    if (citedItems.isNotEmpty) {
      return citedItems;
    }

    // 2. If no explicit tags were present, find which chunk(s) the answer was actually based on
    final answerLower = answerText.toLowerCase();

    // Check if a specific document name appears in the answer
    final matchingDocChunks = evidenceChunks.where((c) {
      final nameLower = c.fileName.toLowerCase();
      final baseName = nameLower.replaceAll('.pdf', '');
      return answerLower.contains(nameLower) || (baseName.length >= 4 && answerLower.contains(baseName));
    }).toList();

    if (matchingDocChunks.isNotEmpty) {
      for (final c in matchingDocChunks) {
        addCitation(c.fileName, c.pageNumber, c.filePath, c.chunkText);
      }
      return citedItems;
    }

    // Check if distinctive content from a chunk appears in the answer
    for (final chunk in evidenceChunks) {
      final clean = chunk.chunkText.replaceAll(RegExp(r'\s+'), ' ').trim();
      final words = clean.split(' ').where((w) => w.length >= 4).toList();
      if (words.isNotEmpty) {
        int matches = 0;
        for (final w in words) {
          if (answerLower.contains(w.toLowerCase())) {
            matches++;
          }
        }
        if ((matches / words.length) >= 0.35) {
          addCitation(chunk.fileName, chunk.pageNumber, chunk.filePath, chunk.chunkText);
        }
      }
    }

    if (citedItems.isNotEmpty) {
      return citedItems;
    }

    // 3. Fallback: Take only the top-1 primary search result rather than displaying irrelevant attachments
    final top = evidenceChunks.first;
    addCitation(top.fileName, top.pageNumber, top.filePath, top.chunkText);
    return citedItems;
  }
}
