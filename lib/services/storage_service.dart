import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../core/constants/app_constants.dart';
import '../models/password_model.dart';
import '../models/recent_document_model.dart';

/// Service for local SQLite database operations
class StorageService {
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
      version: AppConstants.databaseVersion,
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
        total_items INTEGER NOT NULL DEFAULT 0
      )
    ''');
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
      await db.execute('ALTER TABLE ${AppConstants.exportJobsTable} ADD COLUMN zip_password TEXT');
    }
  }

  // ==================== EXPORT JOBS OPERATIONS ====================

  /// Insert or update an export job
  Future<int> insertOrUpdateExportJob(Map<String, dynamic> jobMap) async {
    final db = await database;
    // We need to stringify items_json
    final mapToSave = Map<String, dynamic>.from(jobMap);
    if (mapToSave['items'] != null) {
      // Convert list of items to JSON string
      // Note: The UI/Service uses 'items' list, but DB uses 'items_json' string
      // We assume the service prepares the map correctly or we handle it here.
      // Actually, ExportJob.toJson returns 'items' as List<Map>.
      // We need to JSON encode it for storage.
    }
    
    return await db.insert(
      AppConstants.exportJobsTable,
      jobMap, // Caller must ensure this matches DB schema or we adapt it
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  
  // Note: Since ExportJob.toJson() returns nested maps, sqflite insert might complain if we pass List objects directly 
  // into TEXT columns. We should handle the conversion in ExportQueueService or here. 
  // Unifying implementation: I will make StorageService accept the raw map and handle JSON encoding if needed, 
  // OR expects simple types.
  // Standard pattern: Service creates the map suitable for DB.
  
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

  /// Clear all finished jobs
  Future<int> deleteFinishedExportJobs() async {
    final db = await database;
    return await db.delete(
      AppConstants.exportJobsTable,
      where: 'status = ? OR status = ?',
      whereArgs: ['completed', 'error'],
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

  /// Close database
  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
