import 'package:flutter_test/flutter_test.dart';
import 'package:passwordpdf_manager/services/ai/ai_prompt_service.dart';
import 'package:passwordpdf_manager/services/ai/multi_pdf_rag_service.dart';
import 'package:passwordpdf_manager/services/ai/hybrid_search_service.dart';
import 'package:passwordpdf_manager/services/ai/ai_diagnostics_service.dart';
import 'package:passwordpdf_manager/services/ai/ai_diagnostics_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiPromptVersion & Prompt Injection Tests', () {
    test('AiPromptVersion serialization and defaults', () {
      final now = DateTime.now();
      final model = AiPromptVersion(
        id: 1,
        version: 2,
        title: 'Custom Resume Persona',
        description: 'Test description',
        promptText: 'Custom prompt text',
        isActive: true,
        createdAt: now,
      );

      final map = model.toMap();
      expect(map['version'], 2);
      expect(map['title'], 'Custom Resume Persona');
      expect(map['is_active'], 1);

      final revived = AiPromptVersion.fromMap({
        'id': 1,
        'version': 2,
        'title': 'Custom Resume Persona',
        'description': 'Test description',
        'prompt_text': 'Custom prompt text',
        'is_active': 1,
        'created_at': now.toIso8601String(),
      });

      expect(revived.version, 2);
      expect(revived.isActive, isTrue);
      expect(revived.promptText, 'Custom prompt text');
    });

    test('buildGroundedPrompt injects dynamic master system prompt', () {
      final rag = MultiPdfRagService();
      final chunks = [
        const SearchResultItem(
          chunkId: 'chunk1',
          docId: 'doc1',
          fileName: 'resume.pdf',
          filePath: '/path/resume.pdf',
          pageNumber: 1,
          chunkText: 'Education: B.Tech CGPA: 8.5/10',
          score: 0.95,
        ),
      ];

      const customSystemPrompt = 'YOU ARE A CUSTOM SPECIALIZED AGENT WITH STRICT RULES.';

      // ChatML format
      final promptChatML = rag.buildGroundedPrompt(
        userQuery: 'What is my CGPA?',
        evidenceChunks: chunks,
        modelId: 'qwen_1.5b',
        systemPrompt: customSystemPrompt,
      );

      expect(promptChatML.contains(customSystemPrompt), isTrue);
      expect(promptChatML.contains('<|im_start|>system\n$customSystemPrompt'), isTrue);
      expect(promptChatML.contains('Education: B.Tech CGPA: 8.5/10'), isTrue);

      // Gemma format
      final promptGemma = rag.buildGroundedPrompt(
        userQuery: 'What is my CGPA?',
        evidenceChunks: chunks,
        modelId: 'gemma_2b',
        systemPrompt: customSystemPrompt,
      );

      expect(promptGemma.contains(customSystemPrompt), isTrue);
      expect(promptGemma.contains('<start_of_turn>user\n$customSystemPrompt'), isTrue);
    });

    test('AiDiagnosticLogEntry serialization and copyWith with in_progress state', () {
      final entry = AiDiagnosticLogEntry(
        id: 'test_entry_1',
        timestamp: DateTime.now(),
        rawQuery: 'What is CGPA?',
        detectedIntent: 'in_progress',
        extractedKeywords: ['cgpa'],
        stopwordsRemoved: ['what', 'is'],
        ftsQueryString: 'cgpa*',
        attachedDocNames: ['resume.pdf'],
        ftsMatchesCount: 0,
        ftsMatches: const [],
        vectorMatchesCount: 0,
        vectorMatches: const [],
        selectedEvidence: const [],
        activeChatModelId: 'gemma_2b',
        activeChatModelName: 'Gemma 2 2B',
        activeChatModelPath: '/models/gemma.gguf',
        activeChatModelSizeBytes: 1500000000,
        activeEmbeddingModelId: 'embed_gemma',
        activeEmbeddingModelName: 'Embedding Gemma',
        promptSentToLlm: 'evidence...',
        llmExecutionStatus: 'in_progress: Matching vectors & keywords...',
        llmRawResponse: null,
        finalAnswer: 'Analyzing...',
        executionTimeMs: 45,
      );

      final map = entry.toMap();
      expect(map['id'], 'test_entry_1');
      expect(map['detected_intent'], 'in_progress');
      expect(map['llm_execution_status'], 'in_progress: Matching vectors & keywords...');

      final revived = AiDiagnosticLogEntry.fromMap(map);
      expect(revived.id, 'test_entry_1');
      expect(revived.detectedIntent, 'in_progress');
      expect(revived.extractedKeywords, ['cgpa']);
      expect(revived.attachedDocNames, ['resume.pdf']);

      // Test copyWith transitioning from in_progress to executed
      final finished = revived.copyWith(
        detectedIntent: 'document_rag',
        llmExecutionStatus: 'executed',
        finalAnswer: 'CGPA is 8.5/10',
        executionTimeMs: 1200,
      );

      expect(finished.detectedIntent, 'document_rag');
      expect(finished.llmExecutionStatus, 'executed');
      expect(finished.finalAnswer, 'CGPA is 8.5/10');
      expect(finished.executionTimeMs, 1200);
    });
  });

  group('AiDiagnosticsExportService File Generation Tests', () {
    final exportService = AiDiagnosticsExportService();
    final sampleLogs = [
      AiDiagnosticLogEntry(
        id: 'diag_1',
        timestamp: DateTime.now(),
        rawQuery: 'What is the applicant CGPA?',
        detectedIntent: 'profile_query',
        extractedKeywords: ['applicant', 'cgpa'],
        stopwordsRemoved: ['what', 'is', 'the'],
        ftsQueryString: 'applicant* OR cgpa*',
        attachedDocNames: ['resume.pdf'],
        ftsMatchesCount: 3,
        ftsMatches: const [],
        vectorMatchesCount: 2,
        vectorMatches: const [],
        selectedEvidence: const [
          {'fileName': 'resume.pdf', 'pageNumber': 1, 'score': 0.92, 'snippet': 'CGPA: 8.5/10'}
        ],
        activeChatModelId: 'qwen_1.5b',
        activeChatModelName: 'Qwen 2.5 1.5B',
        activeChatModelPath: '/path/model.gguf',
        activeChatModelSizeBytes: 1024000,
        activeEmbeddingModelId: 'gemma_embed',
        activeEmbeddingModelName: 'EmbeddingGemma 300M',
        promptSentToLlm: 'Custom prompt with evidence...',
        llmExecutionStatus: 'executed',
        llmRawResponse: '7.88/10',
        finalAnswer: 'Your CGPA is **8.5/10** as stated in your resume [Doc: resume.pdf, Page 1].',
        executionTimeMs: 120,
      )
    ];

    final sampleStats = {
      'total_indexed_documents': 2,
      'total_text_chunks': 14,
      'total_vector_embeddings': 14,
      'fts_table_status': 'Active (ai_document_fts)',
      'rag_status': 'Active',
    };

    test('generatePdfBytes produces non-empty valid PDF bytes', () async {
      final bytes = await exportService.generatePdfBytes(
        logs: sampleLogs,
        storageStats: sampleStats,
      );

      expect(bytes, isNotEmpty);
      // PDF magic header %PDF-
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('generateWordBytes produces valid DOCX archive bytes', () async {
      final bytes = await exportService.generateWordBytes(
        logs: sampleLogs,
        storageStats: sampleStats,
      );

      expect(bytes, isNotEmpty);
      // DOCX is a zip archive with PK\x03\x04 header
      expect(bytes[0], 0x50); // 'P'
      expect(bytes[1], 0x4B); // 'K'
    });

    test('generateExcelBytes produces valid XLSX archive bytes', () async {
      final bytes = await exportService.generateExcelBytes(
        logs: sampleLogs,
        storageStats: sampleStats,
      );

      expect(bytes, isNotEmpty);
      // XLSX is a zip archive with PK\x03\x04 header
      expect(bytes[0], 0x50); // 'P'
      expect(bytes[1], 0x4B); // 'K'
    });
  });
}
