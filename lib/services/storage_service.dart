import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../core/constants/app_constants.dart';
import '../models/password_model.dart';
import '../models/recent_document_model.dart';

/// Service for local SQLite database operations
class StorageService {
  static const int _databaseVersion = 12;
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
      version: _databaseVersion, // was hardcoded to 8
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
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
        created_at TEXT NOT NULL
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
        has_excel INTEGER DEFAULT 0
      )
    ''');
    
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

      // Phase 1.10: Trigram Search (Ultra Fast Substring)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS files_search_trigrams (
          token TEXT NOT NULL,
          path TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_trigram_token ON files_search_trigrams (token)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_trigram_path ON files_search_trigrams (path)');
    } catch (e) {
      // Ignore
    }
  }

  // Handle database upgrades
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add export_jobs table
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
        CREATE TABLE ${AppConstants.logsTable} (
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
        CREATE TABLE ${AppConstants.filesIndexTable} (
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
      
      await db.execute('CREATE INDEX idx_files_parent ON ${AppConstants.filesIndexTable} (parent_path)');
      await db.execute('CREATE INDEX idx_files_ext ON ${AppConstants.filesIndexTable} (extension)');
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
    return await db.update(
      AppConstants.passwordsTable,
      password.toMap(),
      where: 'id = ?',
      whereArgs: [password.id],
    );
  }

  /// Delete a password
  Future<int> deletePassword(int id) async {
    final db = await database;
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

  /// Insert a log entry
  Future<void> insertLog(Map<String, dynamic> log, {int retentionLimit = 8000}) async {
    final db = await database;
    await db.transaction((txn) async {
       await txn.insert(AppConstants.logsTable, log);
       // Prune old logs (Keep last N)
       await txn.rawDelete(
         'DELETE FROM ${AppConstants.logsTable} WHERE id NOT IN (SELECT id FROM ${AppConstants.logsTable} ORDER BY id DESC LIMIT ?)',
         [retentionLimit]
       );
    });
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

  /// Get generic table data
  /// Get generic table data with pagination
  Future<List<Map<String, dynamic>>> getTableData(String table, {int? limit, int? offset}) async {
    final db = await database;
    return await db.query(table, limit: limit, offset: offset);
  }

  /// Update generic record
  Future<int> updateRecord(String table, String idColumn, dynamic idValue, Map<String, dynamic> data) async {
    final db = await database;
    return await db.update(table, data, where: '$idColumn = ?', whereArgs: [idValue]);
  }

  /// Delete generic record
  Future<int> deleteRecord(String table, String idColumn, dynamic idValue) async {
    final db = await database;
    return await db.delete(table, where: '$idColumn = ?', whereArgs: [idValue]);
  }

  /// Close database
  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
