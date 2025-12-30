import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'encryption_service.dart';

/// Service for managing PDF document passwords
/// Tracks which documents have been opened successfully with which passwords
class PdfPasswordService {
  static final PdfPasswordService _instance = PdfPasswordService._internal();
  factory PdfPasswordService() => _instance;
  PdfPasswordService._internal();

  final EncryptionService _encryptionService = EncryptionService();
  static const String _documentsPasswordsKey = 'document_passwords';
  
  /// Map of file path -> encrypted password
  Map<String, String> _documentPasswords = {};
  bool _isInitialized = false;

  /// Initialize the service
  Future<void> initialize() async {
    if (_isInitialized) return;
    
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
  Future<String?> getPasswordForDocument(String filePath) async {
    await initialize();
    
    final encryptedPassword = _documentPasswords[filePath];
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
    return _documentPasswords.containsKey(filePath);
  }

  /// Clear stored password for a document
  Future<void> clearDocumentPassword(String filePath) async {
    await initialize();
    _documentPasswords.remove(filePath);
    await _save();
  }

  /// Clear all stored document passwords
  Future<void> clearAll() async {
    _documentPasswords.clear();
    await _save();
  }
}
