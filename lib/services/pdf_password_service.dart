import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'encryption_service.dart';
import 'logging_service.dart';

/// Service for managing PDF document passwords
/// Tracks which documents have been opened successfully with which passwords
class PdfPasswordService {
  static final PdfPasswordService _instance = PdfPasswordService._internal();
  factory PdfPasswordService() => _instance;
  PdfPasswordService._internal();

  final EncryptionService _encryptionService = EncryptionService();
  final LoggingService _log = LoggingService();
  
  static const String _documentsPasswordsKey = 'document_passwords';
  static const String _migrationCompleteKey = 'password_paths_migrated_v2';
  /// TEMP (crypto key testing): when true, PDF password caching + auto-unlock
  /// are DISABLED and any stored PDF passwords are wiped on init. Revert by
  /// setting this to false. MUST be false before shipping to prod.
  static bool cachingDisabled = true;
  
  /// Map of file path -> encrypted password
  Map<String, String> _documentPasswords = {};
  bool _isInitialized = false;

  /// Initialize the service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // TEMP (crypto key testing): caching disabled -> wipe any stored PDF
    // passwords once and skip loading them. Revert with cachingDisabled=false.
    if (cachingDisabled) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_documentsPasswordsKey);
      } catch (_) {}
      _documentPasswords = {};
      _isInitialized = true;
      return;
    }
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_documentsPasswordsKey);
      if (stored != null) {
        final decoded = jsonDecode(stored) as Map<String, dynamic>;
        _documentPasswords = decoded.map((k, v) => MapEntry(k, v.toString()));
      }
      _isInitialized = true;
    } catch (e) {
      _documentPasswords = {};
      _isInitialized = true;
    }
  }

  /// Save document password mappings
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_documentsPasswordsKey, jsonEncode(_documentPasswords));
  }

  /// Get stored password for a document (decrypted)
  /// Checks both exact path and filename match for backward compatibility
  Future<String?> getPasswordForDocument(String filePath) async {
    await initialize();
    if (cachingDisabled) return null; // TEMP: crypto key testing
    
    // 1. Try exact path match first
    var encryptedPassword = _documentPasswords[filePath];
    
    // 2. If not found, try matching by filename (for migrated files)
    if (encryptedPassword == null || encryptedPassword.isEmpty) {
      final fileName = filePath.split(RegExp(r'[/\\]')).last.toLowerCase();
      
      for (final entry in _documentPasswords.entries) {
        final storedFileName = entry.key.split(RegExp(r'[/\\]')).last.toLowerCase();
        if (storedFileName == fileName) {
          encryptedPassword = entry.value;
          
          // Migrate: Add new path as alias
          _documentPasswords[filePath] = encryptedPassword;
          await _save();
          _log.info('PdfPasswordService', 'Migrated password from old path to: $filePath');
          break;
        }
      }
    }
    
    if (encryptedPassword == null || encryptedPassword.isEmpty) {
      return null;
    }
    
    // Empty string means no password needed
    if (encryptedPassword == 'NO_PASSWORD') {
      return '';
    }
    
    // Decrypt the stored password
    return await _encryptionService.decrypt(encryptedPassword);
  }

  /// Store successful password for a document
  Future<void> saveDocumentPassword(String filePath, String password) async {
    await initialize();
    if (cachingDisabled) return; // TEMP: crypto key testing — no PDF pw caching
    
    if (password.isEmpty) {
      // Document doesn't need password
      _documentPasswords[filePath] = 'NO_PASSWORD';
    } else {
      // Encrypt and store
      final encrypted = await _encryptionService.encrypt(password);
      if (encrypted != null) {
        _documentPasswords[filePath] = encrypted;
      }
    }
    
    await _save();
  }

  /// Check if document has a stored password
  Future<bool> hasStoredPassword(String filePath) async {
    await initialize();
    if (cachingDisabled) return false; // TEMP: crypto key testing
    
    // Check exact match
    if (_documentPasswords.containsKey(filePath)) {
      return true;
    }
    
    // Check by filename (for migrated files)
    final fileName = filePath.split(RegExp(r'[/\\]')).last.toLowerCase();
    for (final key in _documentPasswords.keys) {
      final storedFileName = key.split(RegExp(r'[/\\]')).last.toLowerCase();
      if (storedFileName == fileName) {
        return true;
      }
    }
    
    return false;
  }

  /// Clear stored password for a document
  Future<void> clearDocumentPassword(String filePath) async {
    await initialize();
    _documentPasswords.remove(filePath);
    
    // Also clear by filename match
    final fileName = filePath.split(RegExp(r'[/\\]')).last.toLowerCase();
    _documentPasswords.removeWhere((key, _) {
      final storedFileName = key.split(RegExp(r'[/\\]')).last.toLowerCase();
      return storedFileName == fileName;
    });
    
    await _save();
  }

  /// Clear all stored document passwords
  Future<void> clearAll() async {
    _documentPasswords.clear();
    await _save();
  }
  
  /// Get all unique decrypted passwords to try
  Future<List<String>> getAllUniquePasswords() async {
    await initialize();
    if (cachingDisabled) return <String>[]; // TEMP: crypto key testing
    final passwords = <String>{};
    
    for (final encrypted in _documentPasswords.values) {
      if (encrypted == 'NO_PASSWORD' || encrypted.isEmpty) continue;
      
      final decrypted = await _encryptionService.decrypt(encrypted);
      if (decrypted != null && decrypted.isNotEmpty) {
        passwords.add(decrypted);
      }
    }
    
    return passwords.toList();
  }
  
  /// Migrate password keys from old app storage paths to new original paths
  /// Called during app startup with the new document list
  Future<void> migratePasswordPaths(Map<String, String> oldToNewPathMap) async {
    await initialize();
    
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationCompleteKey) == true) {
      return; // Already migrated
    }
    
    int migratedCount = 0;
    final newPasswords = <String, String>{};
    
    for (final entry in _documentPasswords.entries) {
      final oldPath = entry.key;
      final newPath = oldToNewPathMap[oldPath];
      
      if (newPath != null && newPath != oldPath) {
        // Map old path to new path
        newPasswords[newPath] = entry.value;
        migratedCount++;
        _log.info('PdfPasswordService', 'Migrated: $oldPath -> $newPath');
      } else {
        // Keep as-is
        newPasswords[oldPath] = entry.value;
      }
    }
    
    if (migratedCount > 0) {
      _documentPasswords = newPasswords;
      await _save();
      _log.info('PdfPasswordService', 'Migration complete: $migratedCount passwords updated');
    }
    
    await prefs.setBool(_migrationCompleteKey, true);
  }
}
