import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../../core/constants/app_constants.dart';
import '../logging_service.dart';
import '../storage_service.dart';

/// Represents a versioned Master System Prompt in the database
class AiPromptVersion {
  final int id;
  final int version;
  final String title;
  final String? description;
  final String promptText;
  final bool isActive;
  final DateTime createdAt;

  const AiPromptVersion({
    required this.id,
    required this.version,
    required this.title,
    this.description,
    required this.promptText,
    required this.isActive,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'version': version,
        'title': title,
        'description': description,
        'prompt_text': promptText,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory AiPromptVersion.fromMap(Map<String, dynamic> map) => AiPromptVersion(
        id: map['id'] as int? ?? 0,
        version: map['version'] as int? ?? 1,
        title: map['title'] as String? ?? 'Master System Prompt',
        description: map['description'] as String?,
        promptText: map['prompt_text'] as String? ?? '',
        isActive: (map['is_active'] as int? ?? 0) == 1,
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Service managing versioned master system prompts in SQLite with rollback capability
class AiPromptService extends ChangeNotifier {
  static final AiPromptService _instance = AiPromptService._internal();
  factory AiPromptService() => _instance;
  AiPromptService._internal();

  final StorageService _storage = StorageService();

  static const String defaultMasterPromptText = '''
You are PasswordPDF AI, an elite, 100% private, on-device document intelligence assistant.
Your mission is to provide accurate, concise, grounded answers to user questions using ONLY the verified excerpts provided in <document_evidence>.

### Core Operating Principles:
1. Grounded Accuracy & Strict Anti-Hallucination:
   - Rely strictly and exclusively on the text inside <document_evidence>.
   - Never fabricate credentials, employment history, dates, grades, percentages, or contact details.
   - If the user asks about something not present in the excerpts, state clearly: "The attached document(s) do not contain information regarding [topic]."

2. Verification & Page Citations:
   - Always reference the source document and page number for every key claim using the standard format: [Doc: filename, Page X].

3. Candidate Profile & Personal Inquiries:
   - When asked questions about candidate identity (e.g., "what is my name", "my cgpa", "my email", "phone number", "where did i study", "my experience", "awards"):
     - State the exact answer prominently in bold in the first sentence.
     - Cite the specific document and page: e.g., "Your CGPA is **7.88/10** as stated in your education details [Doc: filename, Page 2]."
     - E.g., "Your name is **Om Sai** [Doc: filename, Page 1]."

4. Response Structure & Formatting:
   - Format answers using clean GitHub-flavored markdown.
   - Use bullet points for lists of qualifications, skills, awards, or achievements.
   - Keep answers focused, crisp, and easy to read on mobile screens without preamble or filler phrases.
   - Never output internal XML tags like <document_evidence> or prompt tokens in your response.
''';

  /// Ensure table exists and insert Default v1 prompt if no records exist
  Future<void> initDefaultPromptIfNeeded() async {
    try {
      final db = await _storage.database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.aiSystemPromptsTable} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          version INTEGER NOT NULL UNIQUE,
          title TEXT NOT NULL,
          description TEXT,
          prompt_text TEXT NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');

      final countRows = await db.rawQuery('SELECT COUNT(*) as count FROM ${AppConstants.aiSystemPromptsTable}');
      final count = Sqflite.firstIntValue(countRows) ?? 0;

      if (count == 0) {
        await db.insert(AppConstants.aiSystemPromptsTable, {
          'version': 1,
          'title': 'Default Detailed Persona & Grounded Document QA',
          'description': 'Factory default system prompt with strict anti-hallucination, page citations, and persona rules.',
          'prompt_text': defaultMasterPromptText.trim(),
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
        });
        LoggingService().info('AiPromptService', 'Initialized Default v1 master prompt in database');
      }
    } catch (e, stack) {
      LoggingService().error('AiPromptService', 'Failed to initialize system prompts table: $e', e, stack);
    }
  }

  /// Get the active prompt text for LLM inference (falls back to default if unavailable)
  Future<String> getActivePromptText() async {
    try {
      await initDefaultPromptIfNeeded();
      final active = await getActivePromptVersion();
      if (active != null && active.promptText.trim().isNotEmpty) {
        return active.promptText.trim();
      }
    } catch (e) {
      LoggingService().warn('AiPromptService', 'Could not load active prompt from DB: $e');
    }
    return defaultMasterPromptText.trim();
  }

  /// Get currently active prompt version object
  Future<AiPromptVersion?> getActivePromptVersion() async {
    try {
      final db = await _storage.database;
      final rows = await db.query(
        AppConstants.aiSystemPromptsTable,
        where: 'is_active = 1',
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return AiPromptVersion.fromMap(rows.first);
      }
      // If no active row, grab highest version
      final latestRows = await db.query(
        AppConstants.aiSystemPromptsTable,
        orderBy: 'version DESC',
        limit: 1,
      );
      if (latestRows.isNotEmpty) {
        return AiPromptVersion.fromMap(latestRows.first);
      }
    } catch (e) {
      LoggingService().error('AiPromptService', 'Error getting active prompt version: $e');
    }
    return null;
  }

  /// Get all prompt versions ordered by version DESC
  Future<List<AiPromptVersion>> getAllPromptVersions() async {
    try {
      await initDefaultPromptIfNeeded();
      final db = await _storage.database;
      final rows = await db.query(
        AppConstants.aiSystemPromptsTable,
        orderBy: 'version DESC',
      );
      return rows.map((r) => AiPromptVersion.fromMap(r)).toList();
    } catch (e) {
      LoggingService().error('AiPromptService', 'Error fetching prompt versions: $e');
      return [];
    }
  }

  /// Save user modifications as a brand new version and set it active
  Future<AiPromptVersion> createNewVersion({
    required String title,
    required String promptText,
    String? description,
  }) async {
    await initDefaultPromptIfNeeded();
    final db = await _storage.database;

    final maxVersionRows = await db.rawQuery('SELECT MAX(version) as max_v FROM ${AppConstants.aiSystemPromptsTable}');
    final currentMax = Sqflite.firstIntValue(maxVersionRows) ?? 0;
    final nextVersion = currentMax + 1;

    await db.transaction((txn) async {
      // Deactivate all previous versions
      await txn.update(
        AppConstants.aiSystemPromptsTable,
        {'is_active': 0},
      );

      // Insert new version as active
      await txn.insert(AppConstants.aiSystemPromptsTable, {
        'version': nextVersion,
        'title': title.trim().isEmpty ? 'Custom Master Prompt v$nextVersion' : title.trim(),
        'description': description?.trim(),
        'prompt_text': promptText.trim(),
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
      });
    });

    LoggingService().info('AiPromptService', 'Created new master prompt version: v$nextVersion');
    notifyListeners();

    final created = await getActivePromptVersion();
    return created!;
  }

  /// Roll back to an earlier version by setting it active and others inactive
  Future<void> rollbackToVersion(int version) async {
    final db = await _storage.database;
    await db.transaction((txn) async {
      await txn.update(
        AppConstants.aiSystemPromptsTable,
        {'is_active': 0},
      );
      final affected = await txn.update(
        AppConstants.aiSystemPromptsTable,
        {'is_active': 1},
        where: 'version = ?',
        whereArgs: [version],
      );
      if (affected == 0) {
        throw Exception('Version $version not found');
      }
    });

    LoggingService().info('AiPromptService', 'Rolled back active master prompt to version v$version');
    notifyListeners();
  }

  /// Delete a specific version (cannot delete if it is the only version or currently active)
  Future<bool> deleteVersion(int version) async {
    final db = await _storage.database;
    final allVersions = await getAllPromptVersions();
    if (allVersions.length <= 1) {
      throw Exception('Cannot delete the only existing prompt version.');
    }

    final target = allVersions.firstWhere((v) => v.version == version, orElse: () => throw Exception('Version $version not found'));
    if (target.isActive) {
      throw Exception('Cannot delete the active prompt version. Roll back to another version first.');
    }

    final deleted = await db.delete(
      AppConstants.aiSystemPromptsTable,
      where: 'version = ?',
      whereArgs: [version],
    );

    LoggingService().info('AiPromptService', 'Deleted prompt version v$version');
    notifyListeners();
    return deleted > 0;
  }

  /// Reset to factory default prompt as a new active version
  Future<AiPromptVersion> resetToFactoryDefault() async {
    return await createNewVersion(
      title: 'Restored Factory Default Master Prompt',
      description: 'Reset from factory template with complete persona and grounding rules.',
      promptText: defaultMasterPromptText.trim(),
    );
  }
}
