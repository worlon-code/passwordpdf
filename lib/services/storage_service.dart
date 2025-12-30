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
  }

  /// Handle database upgrades
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Handle future schema upgrades here
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
