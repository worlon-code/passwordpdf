import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../core/constants/app_constants.dart';
import '../models/password_model.dart';
import '../models/recent_document_model.dart';

/// Service for local SQLite database operations
class StorageService {
  static const int _databaseVersion = 16;
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  Database? _database;

  /// Get database instance
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Initialize database
  Future<Database> _initDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, AppConstants.databaseName);

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: (db) async {
        try {
          await db.execute('''
            CREATE VIRTUAL TABLE IF NOT EXISTS ${AppConstants.aiChunksFtsTable} USING fts5(
              chunk_id UNINDEXED,
              doc_id UNINDEXED,
              chunk_text,
              tokenize = 'unicode61 remove_diacritics 2'
            )
          ''');
        } catch (_) {
          try {
            await db.execute('''
              CREATE VIRTUAL TABLE IF NOT EXISTS ${AppConstants.aiChunksFtsTable} USING fts5(
                chunk_id UNINDEXED,
                doc_id UNINDEXED,
                chunk_text
              )
            ''');
          } catch (_) {}
        }
      },
    );
  }

  /// Create database tables
  Future<void> _onCreate(Database db, int version) async {
    // Passwords table
    await db.execute('''
      CREATE TABLE ${AppConstants.passwordsTable} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key_name TEXT NOT NULL UNIQUE,
        encrypted_value TEXT NOT NULL,
        created_at TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        encrypted_tags TEXT
      )
    ''');

    // Recent documents table
    await db.execute('''
      CREATE TABLE ${AppConstants.recentDocumentsTable} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL UNIQUE,
        file_name TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        last_accessed TEXT NOT NULL
      )
    ''');
    
    // Export jobs table
    await db.execute('''
      CREATE TABLE ${AppConstants.exportJobsTable} (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        completed_at INTEGER,
        output_path TEXT,
        error_message TEXT,
        export_dir TEXT,
        zip_password TEXT,
        items_json TEXT NOT NULL,
        progress INTEGER NOT NULL DEFAULT 0,
        processed_items INTEGER NOT NULL DEFAULT 0,
        total_items INTEGER NOT NULL DEFAULT 0,
        type TEXT DEFAULT 'zip',
        is_developer INTEGER DEFAULT 0
      )
    ''');

    // Logs table
    await db.execute('''
      CREATE TABLE ${AppConstants.logsTable} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        level TEXT NOT NULL,
        tag TEXT NOT NULL,
        message TEXT NOT NULL,
        stack_trace TEXT
      )
    ''');

    // Files Index table (v6+)
    await db.execute('''
      CREATE TABLE ${AppConstants.filesIndexTable} (
        path TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        extension TEXT NOT NULL,
        parent_path TEXT NOT NULL,
        size INTEGER NOT NULL,
        created_at INTEGER,
        modified_at INTEGER,
        last_scanned INTEGER,
        is_folder INTEGER DEFAULT 0,
        has_pdf INTEGER DEFAULT 0,
        has_doc INTEGER DEFAULT 0,
        has_excel INTEGER DEFAULT 0,
        is_new INTEGER DEFAULT 0,
        missing_on_device INTEGER DEFAULT 0,
        added_at INTEGER,
        last_synced INTEGER,
        is_imported INTEGER DEFAULT 0,
        is_imported_file INTEGER DEFAULT 0,
        is_favorite INTEGER DEFAULT 0,
        encrypted_tags TEXT
      )
    ''');

    // Password History table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.passwordHistoryTable} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        password_id INTEGER NOT NULL,
        encrypted_value TEXT NOT NULL,
        changed_at INTEGER NOT NULL,
        FOREIGN KEY (password_id) REFERENCES ${AppConstants.passwordsTable} (id) ON DELETE CASCADE
      )
    ''');

    // Encrypted Signatures table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.encryptedSignaturesTable} (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        encrypted_png_bytes TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_used_at INTEGER
      )
    ''');

    // AI Tables
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.aiDocumentIndexTable} (
        doc_id TEXT PRIMARY KEY,
        file_path TEXT NOT NULL UNIQUE,
        file_name TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        last_modified INTEGER NOT NULL,
        total_pages INTEGER NOT NULL DEFAULT 0,
        indexed_pages INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        error_message TEXT,
        index_version INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.aiDocumentPagesTable} (
        page_id TEXT PRIMARY KEY,
        doc_id TEXT NOT NULL,
        page_number INTEGER NOT NULL,
        extracted_text TEXT NOT NULL,
        char_count INTEGER NOT NULL,
        has_ocr INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (doc_id) REFERENCES ${AppConstants.aiDocumentIndexTable} (doc_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.aiDocumentChunksTable} (
        chunk_id TEXT PRIMARY KEY,
        doc_id TEXT NOT NULL,
        page_number INTEGER NOT NULL,
        chunk_index INTEGER NOT NULL,
        chunk_text TEXT NOT NULL,
        char_length INTEGER NOT NULL,
        token_estimate INTEGER NOT NULL,
        FOREIGN KEY (doc_id) REFERENCES ${AppConstants.aiDocumentIndexTable} (doc_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.aiChunkEmbeddingsTable} (
        chunk_id TEXT PRIMARY KEY,
        embedding_blob BLOB NOT NULL,
        dimensions INTEGER NOT NULL,
        model_id TEXT NOT NULL,
        FOREIGN KEY (chunk_id) REFERENCES ${AppConstants.aiDocumentChunksTable} (chunk_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.aiInstalledModelsTable} (
        model_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        model_type TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        sha256_hash TEXT NOT NULL,
        downloaded_at INTEGER NOT NULL,
        context_window INTEGER NOT NULL,
        quantization TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.aiChatSessionsTable} (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        attached_doc_ids TEXT,
        folder_id TEXT,
        has_vault_consent INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.aiChatMessagesTable} (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        citations_json TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (session_id) REFERENCES ${AppConstants.aiChatSessionsTable} (id) ON DELETE CASCADE
      )
    ''');

    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS ${AppConstants.aiChunksFtsTable} USING fts5(
          chunk_id UNINDEXED,
          doc_id UNINDEXED,
          chunk_text,
          tokenize = 'unicode61 remove_diacritics 2'
        )
      ''');
    } catch (_) {
      try {
        await db.execute('''
          CREATE VIRTUAL TABLE IF NOT EXISTS ${AppConstants.aiChunksFtsTable} USING fts5(
            chunk_id UNINDEXED,
            doc_id UNINDEXED,
            chunk_text
          )
        ''');
      } catch (_) {}
    }
    
    // Indexes (Robust & Optimized)
    try {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_parent ON ${AppConstants.filesIndexTable} (parent_path)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_ext ON ${AppConstants.filesIndexTable} (extension)');
      
      // Smart Filter Indexes
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_has_pdf ON ${AppConstants.filesIndexTable} (has_pdf)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_has_doc ON ${AppConstants.filesIndexTable} (has_doc)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_has_excel ON ${AppConstants.filesIndexTable} (has_excel)');

      // Sort & Performance Indexes (New)
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_modified ON ${AppConstants.filesIndexTable} (modified_at)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_size ON ${AppConstants.filesIndexTable} (size)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_name ON ${AppConstants.filesIndexTable} (name)');
      
      // Composite Index for "Ultra Fast" Folder View (Parent + Sort)
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_folder_composite ON ${AppConstants.filesIndexTable} (parent_path, is_folder, modified_at)');

      // New Indexes for Badges/Missing
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_is_new ON ${AppConstants.filesIndexTable} (is_new)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_missing ON ${AppConstants.filesIndexTable} (missing_on_device)');

      // New Indexes for Password History and AI
      await db.execute('CREATE INDEX IF NOT EXISTS idx_password_history_pid ON ${AppConstants.passwordHistoryTable} (password_id, changed_at DESC)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_ai_doc_path ON ${AppConstants.aiDocumentIndexTable} (file_path)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_ai_pages_doc ON ${AppConstants.aiDocumentPagesTable} (doc_id)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_ai_chunks_doc ON ${AppConstants.aiDocumentChunksTable} (doc_id)');
    } catch (e) {
      // Ignore
    }
  }

  // Handle database upgrades
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add export_jobs table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.exportJobsTable} (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          completed_at INTEGER,
          output_path TEXT,
          error_message TEXT,
          export_dir TEXT,
          items_json TEXT NOT NULL,
          progress INTEGER NOT NULL DEFAULT 0,
          processed_items INTEGER NOT NULL DEFAULT 0,
          total_items INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    
    if (oldVersion < 3) {
      // Add zip_password column
      try {
        await db.execute('ALTER TABLE ${AppConstants.exportJobsTable} ADD COLUMN zip_password TEXT');
      } catch (e) {
        // Ignore if exists
      }
    }

    if (oldVersion < 4) {
      // Add type and is_developer columns
      try {
        await db.execute('ALTER TABLE ${AppConstants.exportJobsTable} ADD COLUMN type TEXT DEFAULT "zip"');
        await db.execute('ALTER TABLE ${AppConstants.exportJobsTable} ADD COLUMN is_developer INTEGER DEFAULT 0');
      } catch (e) {
        // Ignore column exists error
      }
    }

    if (oldVersion < 5) {
      // Add logs table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.logsTable} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp TEXT NOT NULL,
          level TEXT NOT NULL,
          tag TEXT NOT NULL,
          message TEXT NOT NULL,
          stack_trace TEXT
        )
      ''');
    }

    if (oldVersion < 6) {
      // Add Files Index table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.filesIndexTable} (
          path TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          extension TEXT NOT NULL,
          parent_path TEXT NOT NULL,
          size INTEGER NOT NULL,
          created_at INTEGER,
          modified_at INTEGER,
          last_scanned INTEGER
        )
      ''');
      
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_parent ON ${AppConstants.filesIndexTable} (parent_path)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_ext ON ${AppConstants.filesIndexTable} (extension)');
    }

    if (oldVersion < 7) {
      // Fix missing is_folder column from v6 migration if it exists
      // Check if column exists first to avoid error, or just try-catch ALTER TABLE
      try {
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN is_folder INTEGER DEFAULT 0');
      } catch (e) {
        // Warning: Column might already exist if fresh install v6 (which had correct _onCreate) 
        // vs upgrade v6 (which had broken _onUpgrade).
        // If error is "duplicate column", ignore.
      }
    }
    if (oldVersion < 8) {
      // Add smart filter flags to avoid slow recursive subqueries
      try {
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN has_pdf INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN has_doc INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN has_excel INTEGER DEFAULT 0');
      } catch (e) {
        // Ignore if exists
      }
    }

    if (oldVersion < 9) {
      // Add indexes for smart filter flags to speed up flat list queries
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_files_has_pdf ON ${AppConstants.filesIndexTable} (has_pdf)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_files_has_doc ON ${AppConstants.filesIndexTable} (has_doc)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_files_has_excel ON ${AppConstants.filesIndexTable} (has_excel)');
      } catch (_) {}
    }

    if (oldVersion < 10) {
      // Phase 1.10: Trigram Search (Deprecated/Removed)
      // We skip creating this table as we moved to In-Memory Search.
    }
    
    if (oldVersion < 11) {
       // Phase 1.11: Performance Tuning (Sort & Folder View)
       try {
         await db.execute('CREATE INDEX IF NOT EXISTS idx_files_modified ON ${AppConstants.filesIndexTable} (modified_at)');
         await db.execute('CREATE INDEX IF NOT EXISTS idx_files_size ON ${AppConstants.filesIndexTable} (size)');
         await db.execute('CREATE INDEX IF NOT EXISTS idx_files_name ON ${AppConstants.filesIndexTable} (name)');
         // Composite: Instant Folder Opening
         await db.execute('CREATE INDEX IF NOT EXISTS idx_files_folder_composite ON ${AppConstants.filesIndexTable} (parent_path, is_folder, modified_at)');
       } catch (_) {}
    }

    if (oldVersion < 12) {
      // Phase 1.12: Remove Trigram Table (Cleanup)
      try {
        await db.execute('DROP TABLE IF EXISTS files_search_trigrams');
      } catch (_) {}
    }
    
    if (oldVersion < 13) {
      // Phase 3-5: Sync Tracking & Badges
      try {
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN is_new INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN missing_on_device INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN added_at INTEGER');
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN last_synced INTEGER');
        
        await db.execute('CREATE INDEX IF NOT EXISTS idx_files_is_new ON ${AppConstants.filesIndexTable} (is_new)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_files_missing ON ${AppConstants.filesIndexTable} (missing_on_device)');
      } catch (_) {}
    }
    
    if (oldVersion < 14) {
      // Phase 4: Persistence for Manually Imported Files
      try {
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN is_imported INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN is_imported_file INTEGER DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 15) {
      // Phase 2-5: Favorites, Tags, Password History, Encrypted Signatures, and Local AI Indexes
      try {
        await db.execute('ALTER TABLE ${AppConstants.passwordsTable} ADD COLUMN is_favorite INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE ${AppConstants.passwordsTable} ADD COLUMN encrypted_tags TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN is_favorite INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE ${AppConstants.filesIndexTable} ADD COLUMN encrypted_tags TEXT');
      } catch (_) {}

      // Password History
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.passwordHistoryTable} (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            password_id INTEGER NOT NULL,
            encrypted_value TEXT NOT NULL,
            changed_at INTEGER NOT NULL,
            FOREIGN KEY (password_id) REFERENCES ${AppConstants.passwordsTable} (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_password_history_pid ON ${AppConstants.passwordHistoryTable} (password_id, changed_at DESC)');
      } catch (_) {}

      // Encrypted Signatures
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.encryptedSignaturesTable} (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            encrypted_png_bytes TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_used_at INTEGER
          )
        ''');
      } catch (_) {}

      // AI Tables
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.aiDocumentIndexTable} (
            doc_id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            last_modified INTEGER NOT NULL,
            total_pages INTEGER NOT NULL DEFAULT 0,
            indexed_pages INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            error_message TEXT,
            index_version INTEGER NOT NULL DEFAULT 1,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_ai_doc_path ON ${AppConstants.aiDocumentIndexTable} (file_path)');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.aiDocumentPagesTable} (
            page_id TEXT PRIMARY KEY,
            doc_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            extracted_text TEXT NOT NULL,
            char_count INTEGER NOT NULL,
            has_ocr INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (doc_id) REFERENCES ${AppConstants.aiDocumentIndexTable} (doc_id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_ai_pages_doc ON ${AppConstants.aiDocumentPagesTable} (doc_id)');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.aiDocumentChunksTable} (
            chunk_id TEXT PRIMARY KEY,
            doc_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            chunk_index INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            char_length INTEGER NOT NULL,
            token_estimate INTEGER NOT NULL,
            FOREIGN KEY (doc_id) REFERENCES ${AppConstants.aiDocumentIndexTable} (doc_id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_ai_chunks_doc ON ${AppConstants.aiDocumentChunksTable} (doc_id)');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.aiChunkEmbeddingsTable} (
            chunk_id TEXT PRIMARY KEY,
            embedding_blob BLOB NOT NULL,
            dimensions INTEGER NOT NULL,
            model_id TEXT NOT NULL,
            FOREIGN KEY (chunk_id) REFERENCES ${AppConstants.aiDocumentChunksTable} (chunk_id) ON DELETE CASCADE
          )
        ''');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.aiInstalledModelsTable} (
            model_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            model_type TEXT NOT NULL,
            file_path TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL,
            sha256_hash TEXT NOT NULL,
            downloaded_at INTEGER NOT NULL,
            context_window INTEGER NOT NULL,
            quantization TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 0
          )
        ''');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE VIRTUAL TABLE IF NOT EXISTS ${AppConstants.aiChunksFtsTable} USING fts5(
            chunk_id UNINDEXED,
            doc_id UNINDEXED,
            chunk_text,
            tokenize = 'unicode61 remove_diacritics 2'
          )
        ''');
      } catch (_) {
        try {
          await db.execute('''
            CREATE VIRTUAL TABLE IF NOT EXISTS ${AppConstants.aiChunksFtsTable} USING fts5(
              chunk_id UNINDEXED,
              doc_id UNINDEXED,
              chunk_text
            )
          ''');
        } catch (_) {}
      }
    }

    if (oldVersion < 16) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.aiChatSessionsTable} (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            attached_doc_ids TEXT,
            folder_id TEXT,
            has_vault_consent INTEGER DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_chat_session_updated ON ${AppConstants.aiChatSessionsTable} (updated_at DESC)');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ${AppConstants.aiChatMessagesTable} (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            citations_json TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY (session_id) REFERENCES ${AppConstants.aiChatSessionsTable} (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_chat_msg_session ON ${AppConstants.aiChatMessagesTable} (session_id, created_at ASC)');
      } catch (_) {}
    }
  }

  // ==================== EXPORT JOBS OPERATIONS ====================

  /// Insert or update an export job
  Future<int> insertOrUpdateExportJob(Map<String, dynamic> jobMap) async {
    final db = await database;
    return await db.insert(
      AppConstants.exportJobsTable,
      jobMap, // Caller must ensure this matches DB schema or we adapt it
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  
  /// Insert/Update export job raw
  Future<void> saveExportJob(String id, Map<String, dynamic> data) async {
    final db = await database;
    await db.insert(
      AppConstants.exportJobsTable,
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all export jobs
  Future<List<Map<String, dynamic>>> getAllExportJobs() async {
    final db = await database;
    return await db.query(
      AppConstants.exportJobsTable,
      orderBy: 'created_at DESC',
    );
  }

  /// Delete an export job
  Future<int> deleteExportJob(String id) async {
    final db = await database;
    return await db.delete(
      AppConstants.exportJobsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Clear finished jobs (filtered by developer flag)
  Future<int> deleteFinishedExportJobs(bool isDeveloper) async {
    final db = await database;
    return await db.delete(
      AppConstants.exportJobsTable,
      where: '(status = ? OR status = ?) AND is_developer = ?',
      whereArgs: ['completed', 'error', isDeveloper ? 1 : 0],
    );
  }

  // ==================== PASSWORD OPERATIONS ====================

  /// Insert a new password
  Future<int> insertPassword(PasswordModel password) async {
    final db = await database;
    return await db.insert(
      AppConstants.passwordsTable,
      password.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all passwords
  Future<List<PasswordModel>> getAllPasswords() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      AppConstants.passwordsTable,
      orderBy: 'created_at DESC',
    );
    return List.generate(maps.length, (i) => PasswordModel.fromMap(maps[i]));
  }

  /// Get password by key name
  Future<PasswordModel?> getPasswordByKeyName(String keyName) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      AppConstants.passwordsTable,
      where: 'key_name = ?',
      whereArgs: [keyName],
    );
    if (maps.isEmpty) return null;
    return PasswordModel.fromMap(maps.first);
  }

  /// Update a password
  Future<int> updatePassword(PasswordModel password) async {
    final db = await database;
    if (password.id != null) {
      final oldRows = await db.query(
        AppConstants.passwordsTable,
        where: 'id = ?',
        whereArgs: [password.id],
      );
      if (oldRows.isNotEmpty) {
        final oldCiphertext = oldRows.first['encrypted_value'] as String?;
        if (oldCiphertext != null && oldCiphertext != password.encryptedValue) {
          await db.insert(AppConstants.passwordHistoryTable, {
            'password_id': password.id,
            'encrypted_value': oldCiphertext,
            'changed_at': DateTime.now().millisecondsSinceEpoch,
          });

          // Enforce retention limit: keep at most 5 entries per password
          final historyRows = await db.query(
            AppConstants.passwordHistoryTable,
            columns: ['id'],
            where: 'password_id = ?',
            whereArgs: [password.id],
            orderBy: 'changed_at DESC',
          );
          if (historyRows.length > 5) {
            final toRemove = historyRows.skip(5).map((e) => e['id']).toList();
            for (final hId in toRemove) {
              await db.delete(
                AppConstants.passwordHistoryTable,
                where: 'id = ?',
                whereArgs: [hId],
              );
            }
          }
        }
      }
    }

    return await db.update(
      AppConstants.passwordsTable,
      password.toMap(),
      where: 'id = ?',
      whereArgs: [password.id],
    );
  }

  /// Get password history (last 5 changed passwords)
  Future<List<Map<String, dynamic>>> getPasswordHistory(int passwordId) async {
    final db = await database;
    return await db.query(
      AppConstants.passwordHistoryTable,
      where: 'password_id = ?',
      whereArgs: [passwordId],
      orderBy: 'changed_at DESC',
      limit: 5,
    );
  }

  /// Compare-and-swap a password's ciphertext for the v1->v2 migration sweep.
  /// The WHERE matches BOTH id AND the exact old ciphertext ON PURPOSE: the
  /// encrypted_value predicate makes this a no-op (0 rows) if the row was edited
  /// or replaced underneath us, so a stale sweep write can never clobber a user
  /// change. Do NOT simplify to id-only. Returns rows affected (1=ok, 0=skip).
  Future<int> migratePasswordCiphertext(
      int id, String oldValue, String newValue) async {
    final db = await database;
    return await db.update(
      AppConstants.passwordsTable,
      {'encrypted_value': newValue},
      where: 'id = ? AND encrypted_value = ?',
      whereArgs: [id, oldValue],
    );
  }

  /// Delete a password
  Future<int> deletePassword(int id) async {
    final db = await database;
    try {
      await db.delete(
        AppConstants.passwordHistoryTable,
        where: 'password_id = ?',
        whereArgs: [id],
      );
    } catch (_) {}
    return await db.delete(
      AppConstants.passwordsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Check if a password key name exists
  Future<bool> passwordKeyExists(String keyName) async {
    final password = await getPasswordByKeyName(keyName);
    return password != null;
  }

  /// Rename a password key name
  Future<int> renamePassword(int id, String newKeyName) async {
    final db = await database;
    return await db.update(
      AppConstants.passwordsTable,
      {'key_name': newKeyName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==================== RECENT DOCUMENTS OPERATIONS ====================

  /// Insert or update a recent document
  Future<int> insertOrUpdateRecentDocument(RecentDocumentModel document) async {
    final db = await database;
    return await db.insert(
      AppConstants.recentDocumentsTable,
      document.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all recent documents
  Future<List<RecentDocumentModel>> getRecentDocuments({int? limit}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      AppConstants.recentDocumentsTable,
      orderBy: 'last_accessed DESC',
      limit: limit ?? AppConstants.maxRecentDocuments,
    );
    return List.generate(
      maps.length,
      (i) => RecentDocumentModel.fromMap(maps[i]),
    );
  }

  /// Delete a recent document
  Future<int> deleteRecentDocument(int id) async {
    final db = await database;
    return await db.delete(
      AppConstants.recentDocumentsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Clear all recent documents
  Future<int> clearRecentDocuments() async {
    final db = await database;
    return await db.delete(AppConstants.recentDocumentsTable);
  }

  // ==================== LOGS OPERATIONS ====================

  static int _logInsertCount = 0;

  /// Insert a log entry
  Future<void> insertLog(Map<String, dynamic> log, {int retentionLimit = 8000}) async {
    final db = await database;
    await db.insert(AppConstants.logsTable, log);
    
    // Prune lazily every 200 inserts to avoid SQLite lock contention
    _logInsertCount++;
    if (_logInsertCount >= 200) {
      _logInsertCount = 0;
      try {
        await db.rawDelete(
          'DELETE FROM ${AppConstants.logsTable} WHERE id NOT IN (SELECT id FROM ${AppConstants.logsTable} ORDER BY id DESC LIMIT ?)',
          [retentionLimit],
        );
      } catch (_) {}
    }
  }

  /// Get logs
  Future<List<Map<String, dynamic>>> getLogs({int limit = 1000, int offset = 0}) async {
    final db = await database;
    return await db.query(
      AppConstants.logsTable,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
  }

  /// Clear all logs
  Future<void> clearLogs() async {
    final db = await database;
    await db.delete(AppConstants.logsTable);
  }

  // ==================== ENCRYPTED SIGNATURE OPERATIONS ====================

  /// Insert or update an encrypted signature
  Future<int> insertEncryptedSignature(Map<String, dynamic> row) async {
    final db = await database;
    return await db.insert(
      AppConstants.encryptedSignaturesTable,
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all encrypted signatures
  Future<List<Map<String, dynamic>>> getAllEncryptedSignatures() async {
    final db = await database;
    return await db.query(
      AppConstants.encryptedSignaturesTable,
      orderBy: 'created_at DESC',
    );
  }

  /// Delete an encrypted signature
  Future<int> deleteEncryptedSignature(String id) async {
    final db = await database;
    return await db.delete(
      AppConstants.encryptedSignaturesTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Update last used timestamp for an encrypted signature
  Future<int> touchEncryptedSignature(String id) async {
    final db = await database;
    return await db.update(
      AppConstants.encryptedSignaturesTable,
      {'last_used_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Check if an encrypted signature name already exists (case-insensitive)
  Future<bool> encryptedSignatureNameExists(String name, {String? excludeId}) async {
    final db = await database;
    final where = excludeId != null 
        ? 'LOWER(name) = LOWER(?) AND id != ?' 
        : 'LOWER(name) = LOWER(?)';
    final args = excludeId != null 
        ? [name.trim(), excludeId] 
        : [name.trim()];
    final res = await db.query(
      AppConstants.encryptedSignaturesTable,
      where: where,
      whereArgs: args,
      limit: 1,
    );
    return res.isNotEmpty;
  }

  /// Rename an encrypted signature with new name
  Future<int> renameEncryptedSignature(String id, String newName) async {
    final db = await database;
    return await db.update(
      AppConstants.encryptedSignaturesTable,
      {'name': newName.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==================== LOCAL AI INDEX OPERATIONS ====================

  /// Upsert AI document index row
  Future<int> upsertAiDocument(Map<String, dynamic> docRow) async {
    final db = await database;
    return await db.insert(
      AppConstants.aiDocumentIndexTable,
      docRow,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get AI document index by docId
  Future<Map<String, dynamic>?> getAiDocument(String docId) async {
    final db = await database;
    final res = await db.query(
      AppConstants.aiDocumentIndexTable,
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
    return res.isNotEmpty ? res.first : null;
  }

  /// Get AI document index by file path
  Future<Map<String, dynamic>?> getAiDocumentByPath(String path) async {
    final db = await database;
    final res = await db.query(
      AppConstants.aiDocumentIndexTable,
      where: 'file_path = ?',
      whereArgs: [path],
    );
    return res.isNotEmpty ? res.first : null;
  }

  /// Get all AI documents
  Future<List<Map<String, dynamic>>> getAllAiDocuments() async {
    final db = await database;
    return await db.query(
      AppConstants.aiDocumentIndexTable,
      orderBy: 'updated_at DESC',
    );
  }

  /// Delete an AI document and associated pages/chunks/embeddings/fts
  Future<int> deleteAiDocument(String docId) async {
    final db = await database;
    await db.delete(AppConstants.aiDocumentPagesTable, where: 'doc_id = ?', whereArgs: [docId]);
    await db.delete(AppConstants.aiDocumentChunksTable, where: 'doc_id = ?', whereArgs: [docId]);
    try {
      await db.delete(AppConstants.aiChunksFtsTable, where: 'doc_id = ?', whereArgs: [docId]);
    } catch (_) {}
    return await db.delete(
      AppConstants.aiDocumentIndexTable,
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
  }

  /// Insert extracted pages for an AI document
  Future<void> insertAiPages(List<Map<String, dynamic>> pages) async {
    final db = await database;
    final batch = db.batch();
    for (final page in pages) {
      batch.insert(AppConstants.aiDocumentPagesTable, page, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Insert chunks for an AI document
  Future<void> insertAiChunks(List<Map<String, dynamic>> chunks) async {
    final db = await database;
    final batch = db.batch();
    for (final chunk in chunks) {
      batch.insert(AppConstants.aiDocumentChunksTable, chunk, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Insert FTS entry for a chunk
  Future<void> insertAiChunkFts(String chunkId, String docId, String text) async {
    final db = await database;
    try {
      await db.insert(AppConstants.aiChunksFtsTable, {
        'chunk_id': chunkId,
        'doc_id': docId,
        'chunk_text': text,
      });
    } catch (_) {}
  }

  /// Search FTS chunks scoped to specific document IDs
  Future<List<Map<String, dynamic>>> searchFtsChunks(
    String query, {
    List<String>? docIds,
    int limit = 30,
  }) async {
    final db = await database;
    if (docIds != null && docIds.isEmpty) return [];

    final cleanQuery = query.replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), ' ').trim();
    if (cleanQuery.isEmpty) return [];

    const stopwords = {
      'what', 'is', 'my', 'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'for', 'on', 'with',
      'as', 'by', 'at', 'from', 'this', 'that', 'it', 'are', 'was', 'were', 'be', 'been',
      'have', 'has', 'had', 'do', 'does', 'did', 'can', 'could', 'will', 'would', 'shall',
      'should', 'may', 'might', 'must', 'tell', 'me', 'about', 'show', 'find', 'give', 'how',
      'why', 'where', 'when', 'who', 'which', 'please', 'any', 'some', 'there', 'their', 'they',
      'i', 'you', 'he', 'she', 'we', 'us', 'him', 'her', 'them', 'your', 'his', 'our'
    };

    final allTokens = cleanQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final contentTokens = allTokens.where((t) => !stopwords.contains(t.toLowerCase())).toList();
    final activeTokens = contentTokens.isNotEmpty ? contentTokens : allTokens;

    final hasDocFilter = docIds != null && docIds.isNotEmpty;
    final docFilter = hasDocFilter ? 'AND doc_id IN (${List.filled(docIds.length, '?').join(',')})' : '';
    final docArgs = hasDocFilter ? docIds : <dynamic>[];

    final Map<String, Map<String, dynamic>> combined = {};

    // 1. Direct Substring Match for Exact Keyword Hits (e.g. 'cgpa', 'degree')
    if (activeTokens.isNotEmpty) {
      final likeClauses = activeTokens.map((_) => 'chunk_text LIKE ?').join(' OR ');
      final likeArgs = activeTokens.map((t) => '%$t%').toList();
      final whereClause = hasDocFilter
          ? '($likeClauses) AND doc_id IN (${List.filled(docIds.length, '?').join(',')})'
          : '($likeClauses)';
      final queryArgs = [...likeArgs, ...docArgs, limit];
      try {
        final exactRows = await db.rawQuery('''
          SELECT chunk_id, doc_id, chunk_text, -50.0 as rank
          FROM ${AppConstants.aiDocumentChunksTable}
          WHERE $whereClause
          LIMIT ?
        ''', queryArgs);
        for (final r in exactRows) {
          final id = r['chunk_id'] as String;
          combined[id] = Map<String, dynamic>.from(r);
        }
      } catch (_) {}
    }

    // 2. FTS5 Keyword Search using OR for token coverage
    try {
      final ftsTokens = activeTokens.map((t) => '$t*').join(' OR ');
      final ftsMatches = await db.rawQuery('''
        SELECT chunk_id, doc_id, chunk_text, rank
        FROM ${AppConstants.aiChunksFtsTable}
        WHERE ${AppConstants.aiChunksFtsTable} MATCH ? $docFilter
        ORDER BY rank
        LIMIT ?
      ''', [ftsTokens, ...docArgs, limit]);
      for (final r in ftsMatches) {
        final id = r['chunk_id'] as String;
        if (!combined.containsKey(id)) {
          combined[id] = Map<String, dynamic>.from(r);
        }
      }
    } catch (_) {}

    return combined.values.take(limit).toList();
  }

  /// Insert vector embedding for a chunk
  Future<void> insertChunkEmbedding(String chunkId, List<double> embedding, int dimensions, String modelId) async {
    final db = await database;
    final byteData = ByteData(embedding.length * 4);
    for (int i = 0; i < embedding.length; i++) {
      byteData.setFloat32(i * 4, embedding[i], Endian.little);
    }
    await db.insert(
      AppConstants.aiChunkEmbeddingsTable,
      {
        'chunk_id': chunkId,
        'embedding_blob': byteData.buffer.asUint8List(),
        'dimensions': dimensions,
        'model_id': modelId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get chunk embeddings with chunk metadata
  Future<List<Map<String, dynamic>>> getAllChunkEmbeddings({String? docId, List<String>? docIds}) async {
    final db = await database;
    if (docId != null) {
      return await db.rawQuery('''
        SELECT e.chunk_id, e.embedding_blob, e.dimensions, e.model_id, c.doc_id, c.page_number, c.chunk_text
        FROM ${AppConstants.aiChunkEmbeddingsTable} e
        INNER JOIN ${AppConstants.aiDocumentChunksTable} c ON e.chunk_id = c.chunk_id
        WHERE c.doc_id = ?
      ''', [docId]);
    } else if (docIds != null && docIds.isNotEmpty) {
      final placeholders = List.filled(docIds.length, '?').join(',');
      return await db.rawQuery('''
        SELECT e.chunk_id, e.embedding_blob, e.dimensions, e.model_id, c.doc_id, c.page_number, c.chunk_text
        FROM ${AppConstants.aiChunkEmbeddingsTable} e
        INNER JOIN ${AppConstants.aiDocumentChunksTable} c ON e.chunk_id = c.chunk_id
        WHERE c.doc_id IN ($placeholders)
      ''', docIds);
    }
    return await db.rawQuery('''
      SELECT e.chunk_id, e.embedding_blob, e.dimensions, e.model_id, c.doc_id, c.page_number, c.chunk_text
      FROM ${AppConstants.aiChunkEmbeddingsTable} e
      INNER JOIN ${AppConstants.aiDocumentChunksTable} c ON e.chunk_id = c.chunk_id
    ''');
  }

  /// Insert or update an installed AI model
  Future<int> insertOrUpdateInstalledModel(Map<String, dynamic> model) async {
    final db = await database;
    return await db.insert(
      AppConstants.aiInstalledModelsTable,
      model,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all installed AI models (pruning orphaned rows if files no longer exist)
  Future<List<Map<String, dynamic>>> getInstalledModels() async {
    final db = await database;
    final rows = await db.query(
      AppConstants.aiInstalledModelsTable,
      orderBy: 'downloaded_at DESC',
    );
    final valid = <Map<String, dynamic>>[];
    for (final r in rows) {
      final path = r['file_path'] as String?;
      if (path != null && File(path).existsSync()) {
        valid.add(Map<String, dynamic>.from(r));
      } else {
        // Orphaned record: clean up from database
        try {
          await db.delete(
            AppConstants.aiInstalledModelsTable,
            where: 'model_id = ?',
            whereArgs: [r['model_id']],
          );
        } catch (_) {}
      }
    }
    return valid;
  }

  /// Get active model by type
  Future<Map<String, dynamic>?> getActiveInstalledModel(String type) async {
    final db = await database;
    final res = await db.query(
      AppConstants.aiInstalledModelsTable,
      where: 'model_type = ? AND is_active = 1',
      whereArgs: [type],
      limit: 1,
    );
    if (res.isNotEmpty) {
      final path = res.first['file_path'] as String?;
      if (path != null && File(path).existsSync()) {
        return Map<String, dynamic>.from(res.first);
      } else {
        // Deactivate orphaned model
        try {
          await db.delete(
            AppConstants.aiInstalledModelsTable,
            where: 'model_id = ?',
            whereArgs: [res.first['model_id']],
          );
        } catch (_) {}
      }
    }
    return null;
  }

  // ==================== GENERIC DB OPERATIONS ====================

  /// Get all table names
  Future<List<String>> getTables() async {
    final db = await database;
    final tables = await db.query('sqlite_master', where: 'type = ?', whereArgs: ['table']);
    return tables
        .map((t) => t['name'] as String)
        .where((t) => t != 'android_metadata' && t != 'sqlite_sequence')
        .toList();
  }

  /// Tables that may be addressed through the generic operations below.
  static const Set<String> _allowedTables = {
    AppConstants.passwordsTable,
    AppConstants.recentDocumentsTable,
    AppConstants.settingsTable,
    AppConstants.exportJobsTable,
    AppConstants.logsTable,
    AppConstants.filesIndexTable,
    AppConstants.passwordHistoryTable,
    AppConstants.encryptedSignaturesTable,
    AppConstants.aiDocumentIndexTable,
    AppConstants.aiDocumentPagesTable,
    AppConstants.aiDocumentChunksTable,
    AppConstants.aiChunkEmbeddingsTable,
    AppConstants.aiInstalledModelsTable,
  };

  // A SQL identifier we are willing to interpolate: letters, digits, underscore only.
  static final RegExp _safeIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Validate a table name against the whitelist. Throws on anything unexpected.
  static String _safeTable(String table) {
    if (!_allowedTables.contains(table)) {
      throw ArgumentError('Disallowed table name: $table');
    }
    return table;
  }

  /// Validate an id column name (identifier-shaped only). Throws otherwise.
  static String _safeColumn(String column) {
    if (!_safeIdentifier.hasMatch(column)) {
      throw ArgumentError('Disallowed column name: $column');
    }
    return column;
  }

  /// Get generic table data
  /// Get generic table data with pagination
  Future<List<Map<String, dynamic>>> getTableData(String table, {int? limit, int? offset}) async {
    final safeTable = _safeTable(table);
    final db = await database;
    return await db.query(safeTable, limit: limit, offset: offset);
  }

  /// Update generic record
  Future<int> updateRecord(String table, String idColumn, dynamic idValue, Map<String, dynamic> data) async {
    final safeTable = _safeTable(table);
    final safeColumn = _safeColumn(idColumn);
    final db = await database;
    return await db.update(safeTable, data, where: '$safeColumn = ?', whereArgs: [idValue]);
  }

  /// Delete generic record
  Future<int> deleteRecord(String table, String idColumn, dynamic idValue) async {
    final safeTable = _safeTable(table);
    final safeColumn = _safeColumn(idColumn);
    final db = await database;
    return await db.delete(safeTable, where: '$safeColumn = ?', whereArgs: [idValue]);
  }

  // ==================== AI CHAT SESSIONS & MESSAGES ====================

  /// Insert a new AI chat session
  Future<int> insertAiChatSession(Map<String, dynamic> session) async {
    final db = await database;
    return await db.insert(
      AppConstants.aiChatSessionsTable,
      session,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Update an AI chat session
  Future<int> updateAiChatSession(String id, Map<String, dynamic> session) async {
    final db = await database;
    return await db.update(
      AppConstants.aiChatSessionsTable,
      session,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Get AI chat session by id
  Future<Map<String, dynamic>?> getAiChatSession(String id) async {
    final db = await database;
    final res = await db.query(
      AppConstants.aiChatSessionsTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return res.isNotEmpty ? res.first : null;
  }

  /// Get all AI chat sessions
  Future<List<Map<String, dynamic>>> getAllAiChatSessions() async {
    final db = await database;
    final rows = await db.query(
      AppConstants.aiChatSessionsTable,
      orderBy: 'updated_at DESC',
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Delete an AI chat session and its messages
  Future<int> deleteAiChatSession(String id) async {
    final db = await database;
    await db.delete(
      AppConstants.aiChatMessagesTable,
      where: 'session_id = ?',
      whereArgs: [id],
    );
    return await db.delete(
      AppConstants.aiChatSessionsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Insert an AI chat message
  Future<int> insertAiChatMessage(Map<String, dynamic> message) async {
    final db = await database;
    return await db.insert(
      AppConstants.aiChatMessagesTable,
      message,
    );
  }

  /// Get all messages for a session
  Future<List<Map<String, dynamic>>> getAiChatMessagesForSession(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      AppConstants.aiChatMessagesTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Clear all messages for a session
  Future<int> deleteAiChatMessagesForSession(String sessionId) async {
    final db = await database;
    return await db.delete(
      AppConstants.aiChatMessagesTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Close database
  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
