import 'dart:collection';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'encryption_service.dart';
import 'logging_service.dart';
import 'storage_service.dart';

/// Service for managing PDF document passwords
/// Tracks which documents have been opened successfully with which passwords
class PdfPasswordService {
  static final PdfPasswordService _instance = PdfPasswordService._internal();
  factory PdfPasswordService() => _instance;
  PdfPasswordService._internal();

  final EncryptionService _encryptionService = EncryptionService();
  final LoggingService _log = LoggingService();
  final StorageService _storageService = StorageService();
  
  static const String _documentsPasswordsKey = 'document_passwords';
  static const String _migrationCompleteKey = 'password_paths_migrated_v2';
  
  Map<String, String> _documentPasswords = {};
  bool _isInitialized = false;
  Future<void>? _initFuture;
  bool _loadFailed = false;

  /// Helper to normalize file paths across Windows/POSIX and whitespace
  String _normalizePath(String rawPath) {
    return p.normalize(rawPath.trim()).replaceAll('\\', '/');
  }

  /// Initialize the service (serialized to prevent concurrent init races)
  Future<void> initialize() {
    if (_isInitialized) return Future.value();
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_documentsPasswordsKey);
      if (stored != null) {
        final decoded = jsonDecode(stored) as Map<String, dynamic>;
        _documentPasswords = decoded.map((k, v) => MapEntry(k, v.toString()));
      }
      _isInitialized = true;
    } catch (e) {
      // Preserve the raw (possibly corrupt but still recoverable) blob so we
      // don't overwrite it with '{}' on the next _save(). Gate writes off.
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_documentsPasswordsKey);
        if (raw != null && raw.isNotEmpty) {
          final ts = DateTime.now().millisecondsSinceEpoch;
          await prefs.setString('${_documentsPasswordsKey}_corrupt_$ts', raw);
        }
      } catch (_) {}
      _loadFailed = true;
      _documentPasswords = {};
      _isInitialized = true;
    }
  }

  /// Save document password mappings
  Future<void> _save() async {
    if (_loadFailed) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_documentsPasswordsKey, jsonEncode(_documentPasswords));
  }

  /// Get stored password for a document (decrypted)
  /// Checks exact path, normalized path, and filename match for backward compatibility
  Future<String?> getPasswordForDocument(String filePath) async {
    await initialize();
    
    // 1. Try exact path match first
    var encryptedPassword = _documentPasswords[filePath];
    
    // 2. Try normalized path match second
    final normPath = _normalizePath(filePath);
    if ((encryptedPassword == null || encryptedPassword.isEmpty) && normPath != filePath) {
      encryptedPassword = _documentPasswords[normPath];
    }
    
    // 3. If not found, try matching by filename (for migrated files)
    if (encryptedPassword == null || encryptedPassword.isEmpty) {
      final fileName = p.basename(filePath).toLowerCase();
      
      for (final entry in _documentPasswords.entries) {
        final storedFileName = p.basename(entry.key).toLowerCase();
        if (storedFileName == fileName) {
          encryptedPassword = entry.value;
          
          // Migrate: Add normalized path as alias
          _documentPasswords[normPath] = encryptedPassword;
          await _save();
          _log.info('PdfPasswordService', 'Migrated password from old path to: $normPath');
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
    final normPath = _normalizePath(filePath);
    
    if (password.isEmpty) {
      // Document doesn't need password
      _documentPasswords[filePath] = 'NO_PASSWORD';
      _documentPasswords[normPath] = 'NO_PASSWORD';
    } else {
      // Encrypt and store
      final encrypted = await _encryptionService.encrypt(password);
      if (encrypted != null) {
        _documentPasswords[filePath] = encrypted;
        _documentPasswords[normPath] = encrypted;
      }
    }
    
    await _save();
  }

  /// Save password alias
  Future<void> savePasswordForDocument(String filePath, String password) =>
      saveDocumentPassword(filePath, password);

  /// Check if document has a stored password
  Future<bool> hasStoredPassword(String filePath) async {
    await initialize();
    final normPath = _normalizePath(filePath);
    
    // Check exact or normalized match
    if (_documentPasswords.containsKey(filePath) || _documentPasswords.containsKey(normPath)) {
      return true;
    }
    
    // Check by filename (for migrated files)
    final fileName = p.basename(filePath).toLowerCase();
    for (final key in _documentPasswords.keys) {
      final storedFileName = p.basename(key).toLowerCase();
      if (storedFileName == fileName) {
        return true;
      }
    }
    
    return false;
  }

  /// Clear stored password for a document
  Future<void> clearDocumentPassword(String filePath) async {
    await initialize();
    final normPath = _normalizePath(filePath);
    _documentPasswords.remove(filePath);
    _documentPasswords.remove(normPath);
    
    // Also clear by filename match
    final fileName = p.basename(filePath).toLowerCase();
    _documentPasswords.removeWhere((key, _) {
      final storedFileName = p.basename(key).toLowerCase();
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
    final passwords = LinkedHashSet<String>();
    
    // 1. Favorites from Password Manager first
    try {
      final managerPasswords = await _storageService.getAllPasswords();
      final favorites = managerPasswords.where((p) => p.isFavorite).toList();
      for (final model in favorites) {
        final decrypted = await _encryptionService.decrypt(model.encryptedValue);
        if (decrypted != null && decrypted.trim().isNotEmpty) {
          passwords.add(decrypted);
        }
      }

      // 2. From document history
      for (final encrypted in _documentPasswords.values) {
        if (encrypted == 'NO_PASSWORD' || encrypted.isEmpty) continue;
        
        final decrypted = await _encryptionService.decrypt(encrypted);
        if (decrypted != null && decrypted.trim().isNotEmpty) {
          passwords.add(decrypted);
        }
      }

      // 3. Remaining passwords from Password Manager
      final nonFavorites = managerPasswords.where((p) => !p.isFavorite).toList();
      for (final model in nonFavorites) {
        final decrypted = await _encryptionService.decrypt(model.encryptedValue);
        if (decrypted != null && decrypted.trim().isNotEmpty) {
          passwords.add(decrypted);
        }
      }
    } catch (e) {
      _log.error('PdfPasswordService', 'Failed to load passwords from Password Manager', e);
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
        newPasswords[newPath] = entry.value;
        // MUST NOT also copy oldPath (was leaving both around, bloating the map)
        migratedCount++;
        _log.info('PdfPasswordService', 'Migrated: $oldPath -> $newPath');
      } else {
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

  static const String _pdfSweepDoneKey = 'pdf_pw_sweep_done_v1';
  static bool _sweeping = false;

  Future<int> migratePdfPasswordsToV2() async {
    if (_sweeping) return 0;
    _sweeping = true;
    try {
      final enc = EncryptionService();
      if (!enc.canOverwriteLegacy || !enc.canWriteV2) return 0;

      await initialize();
      if (_loadFailed) return 0;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_pdfSweepDoneKey) == true) return 0;

      var migrated = 0;
      var v1remaining = 0;
      final keys = _documentPasswords.keys.toList(growable: false);
      for (final k in keys) {
        final ct = _documentPasswords[k];
        if (ct == null || ct == 'NO_PASSWORD') continue;
        if (ct.startsWith('v2:')) continue;

        final plain = await enc.decrypt(ct);
        if (plain == null) { v1remaining++; continue; }
        if (enc.xorEncryptLegacy(plain) != ct) { v1remaining++; continue; }

        final v2 = await enc.encrypt(plain);
        if (v2 == null || !v2.startsWith('v2:')) { v1remaining++; continue; }
        final back = await enc.decrypt(v2);
        if (back != plain) { v1remaining++; continue; }

        // CAS-like: only replace if the map still holds the same ct.
        if (_documentPasswords[k] == ct) {
          _documentPasswords[k] = v2;
          migrated++;
        } else {
          v1remaining++;
        }
      }
      if (migrated > 0) await _save();
      if (v1remaining == 0) await prefs.setBool(_pdfSweepDoneKey, true);
      return migrated;
    } finally {
      _sweeping = false;
    }
  }
}
