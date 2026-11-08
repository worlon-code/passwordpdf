import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:passwordpdf_manager/services/ai/pdf_indexing_coordinator.dart';
import 'package:passwordpdf_manager/services/ai/multi_pdf_rag_service.dart';
import 'package:passwordpdf_manager/services/ai/hybrid_search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('Fix 2: PDF Text Extraction & Word-Per-Line Normalization Tests', () {
    test('normalizeExtractedPdfText collapses single-word lines into complete sentences', () {
      const fragmentedInput = '''
Hyderabad,
Telangana
|
+91-9876543210
|
om.sai@email.com
Results-driven
Analyst
with
approximately
3
years
of
experience
solving
complex
challenges
in
Python,
SQL,
and
cloud
application.
EDUCATION
B.Tech in Computer Science
CGPA:
7.88/10
''';

      final normalized = PdfIndexingCoordinator.normalizeExtractedPdfText(fragmentedInput);

      // Verify words are NOT sliced in half
      expect(normalized.contains('challenges'), isTrue);
      expect(normalized.contains('Python,'), isTrue);
      expect(normalized.contains('application.'), isTrue);

      // Verify single-word lines are collapsed into readable sentences
      expect(normalized.contains('Results-driven Analyst with approximately 3 years of experience'), isTrue);
      expect(normalized.contains('CGPA: 7.88/10') || normalized.contains('CGPA:\n7.88/10'), isTrue);
    });

    test('generateSubwordEmbedding produces normalized 128-dim vectors deterministically', () {
      final vec1 = PdfIndexingCoordinator.generateSubwordEmbedding('Om Sai Resume CGPA 7.88');
      final vec2 = PdfIndexingCoordinator.generateSubwordEmbedding('Om Sai Resume CGPA 7.88');

      expect(vec1.length, equals(128));
      expect(vec2.length, equals(128));
      for (int i = 0; i < 128; i++) {
        expect(vec1[i], closeTo(vec2[i], 0.0001));
      }
    });
  });

  group('Fix 3: Intent Classification & Stopword Wildcard Ban Tests', () {
    test('Chat shorthand is normalized properly', () {
      expect(MultiPdfRagService.normalizeChatShorthand('who r u'), equals('who are you'));
      expect(MultiPdfRagService.normalizeChatShorthand('what is ur name'), equals('what is your name'));
      expect(MultiPdfRagService.normalizeChatShorthand('wat is my cgpa plz'), equals('what is my cgpa please'));
    });

    test('Greetings and assistant-identity queries are classified without querying FTS', () {
      final greeting = MultiPdfRagService.checkConversationalOrMetaIntent('hi', ['Om_Sai_Resume.pdf']);
      expect(greeting, isNotNull);
      expect(greeting!['intent'], equals('greeting'));
      expect(greeting['answer']!.contains('Om_Sai_Resume.pdf'), isTrue);

      final identity = MultiPdfRagService.checkConversationalOrMetaIntent('who are u', ['Om_Sai_Resume.pdf']);
      expect(identity, isNotNull);
      expect(identity!['intent'], equals('assistant_identity'));
      expect(identity['answer']!.contains('100% private'), isTrue);

      final help = MultiPdfRagService.checkConversationalOrMetaIntent('what can you do', []);
      expect(help, isNotNull);
      expect(help!['intent'], equals('assistant_identity'));

      // Real questions should NOT be intercepted as meta intent
      expect(MultiPdfRagService.checkConversationalOrMetaIntent('what is my cgpa', ['Om_Sai_Resume.pdf']), isNull);
      expect(MultiPdfRagService.checkConversationalOrMetaIntent('what is my name', ['Om_Sai_Resume.pdf']), isNull);
    });

    test('Profile query detector correctly flags identity questions', () {
      expect(MultiPdfRagService.isProfileQuery('what is my cgpa'), isTrue);
      expect(MultiPdfRagService.isProfileQuery('what is my name'), isTrue);
      expect(MultiPdfRagService.isProfileQuery('my email and phone'), isTrue);
      expect(MultiPdfRagService.isProfileQuery('where did i study'), isTrue);
    });

    test('Synonym expansion includes filename tokens and key academic terms', () {
      final expanded = MultiPdfRagService.expandKeywords(['cgpa'], 'what is my cgpa', ['Om_Sai_Resume.pdf']);
      expect(expanded.contains('cgpa'), isTrue);
      expect(expanded.contains('gpa'), isTrue);
      expect(expanded.contains('education'), isTrue);

      final nameExpanded = MultiPdfRagService.expandKeywords(['name'], 'what is my name', ['Om_Sai_Resume.pdf']);
      expect(nameExpanded.contains('om'), isTrue);
      expect(nameExpanded.contains('sai'), isTrue);
    });
  });

  group('Fix 4 & 5: Extractive QA Synthesizer & Grounded Prompts', () {
    test('synthesizeExtractiveAnswer extracts CGPA accurately without truncation', () {
      final fakeResults = [
        const SearchResultItem(
          chunkId: 'c1',
          docId: 'd1',
          fileName: 'Om_Sai_Resume.pdf',
          filePath: '/path/Om_Sai_Resume.pdf',
          pageNumber: 2,
          chunkText: 'EDUCATION\nB.Tech in Computer Science and Engineering\nCGPA: 7.88/10\nYear: 2020 - 2024',
          score: 0.95,
        ),
      ];

      final answer = MultiPdfRagService.synthesizeExtractiveAnswer(
        searchResults: fakeResults,
        contentKeywords: ['cgpa'],
        queryLower: 'what is my cgpa',
        activeModel: null,
      );

      expect(answer.contains('7.88/10'), isTrue);
      expect(answer.contains('Om_Sai_Resume.pdf'), isTrue);
      expect(answer.contains('Page 2'), isTrue);
    });

    test('synthesizeExtractiveAnswer resolves Candidate Name from Page 1 hint and email', () {
      final fakeResults = [
        const SearchResultItem(
          chunkId: 'c0',
          docId: 'd1',
          fileName: 'Om_Sai_Resume.pdf',
          filePath: '/path/Om_Sai_Resume.pdf',
          pageNumber: 1,
          chunkText: '[Document File: Om_Sai_Resume.pdf | Document Title / Candidate Hint: Om Sai Resume]\nHyderabad | om.sai@email.com | +91-9876543210',
          score: 1.0,
        ),
      ];

      final answer = MultiPdfRagService.synthesizeExtractiveAnswer(
        searchResults: fakeResults,
        contentKeywords: ['name'],
        queryLower: 'what is my name',
        activeModel: null,
      );

      expect(answer.contains('Om Sai'), isTrue);
      expect(answer.contains('Page 1'), isTrue);
    });

    test('buildGroundedPrompt formats ChatML for Qwen and Gemma tokens for Gemma', () {
      final rag = MultiPdfRagService();
      final evidence = [
        const SearchResultItem(
          chunkId: 'c1',
          docId: 'd1',
          fileName: 'Om_Sai_Resume.pdf',
          filePath: '/path/Om_Sai_Resume.pdf',
          pageNumber: 1,
          chunkText: 'CGPA: 7.88/10',
          score: 1.0,
        ),
      ];

      // Qwen prompt
      final qwenPrompt = rag.buildGroundedPrompt(
        userQuery: 'what is my cgpa',
        evidenceChunks: evidence,
        modelId: 'qwen2.5-1.5b-instruct-q4_k_m',
      );
      expect(qwenPrompt.contains('<|im_start|>system'), isTrue);
      expect(qwenPrompt.contains('<|im_start|>user'), isTrue);
      expect(qwenPrompt.contains('<|im_start|>assistant'), isTrue);

      // Gemma prompt
      final gemmaPrompt = rag.buildGroundedPrompt(
        userQuery: 'what is my cgpa',
        evidenceChunks: evidence,
        modelId: 'gemma-2-2b-it-q4_k_m',
      );
      expect(gemmaPrompt.contains('<start_of_turn>user'), isTrue);
      expect(gemmaPrompt.contains('<start_of_turn>model'), isTrue);
    });
  });
}
