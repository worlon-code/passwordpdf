import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto; // sha256 key-health token
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'logging_service.dart';

/// Service for encryption key management
class EncryptionService {
  static final EncryptionService _instance = EncryptionService._internal();
  factory EncryptionService() => _instance;
  EncryptionService._internal();

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final LoggingService _log = LoggingService();

  // Developer password for accessing sensitive info
  static const String _developerPassword = 'Portal123!';
  String? _encryptionKey;

  // v2 AES key: Keystore-backed, minted once. Daily use, no master password.
  static const String _aesKeyStorageKey = 'aes_key_v2';
  // Legacy XOR key: READ-ONLY forever for v1 reads. Never written again.
  static const String _legacyKeyStorageKey = 'encryption_key';
  // sha256(legacy key) recorded when health is known-good; gates all overwrites.
  static const String _legacyKeyHealthToken = 'legacy_key_health_v1';
  static const String _v2Tag = 'v2:'; // ciphertext namespace tag (read-both)

  SecretKey? _aesKey; // cached v2 key (decoded)
  bool _legacyKeyHealthy = false; // true only after token matches

  /// Call ONCE from single-threaded startup, before any encrypt/decrypt.
  Future<void> initCrypto() async {
    // Idempotency guard: re-entry within a process is a no-op so a second
    // aes_key_v2 can never be minted (double-mint protection, code-level).
    if (_aesKey != null) return;
    // 1) Ensure v2 key exists (mint once).
    var b64 = await _secureStorage.read(key: _aesKeyStorageKey);
    if (b64 == null || b64.isEmpty) {
      final fresh = await AesGcm.with256bits().newSecretKey();
      final bytes = await fresh.extractBytes();
      b64 = base64Encode(bytes);
      await _secureStorage.write(key: _aesKeyStorageKey, value: b64);
      _log.info('EncryptionService', 'Minted aes_key_v2 (256-bit)');
    }
    _aesKey = SecretKey(base64Decode(b64));

    // 2) Key-health gate on the LEGACY key.
    final legacy = await _secureStorage.read(key: _legacyKeyStorageKey);
    if (legacy != null && legacy.isNotEmpty) {
      final tokenNow = crypto.sha256.convert(utf8.encode(legacy)).toString();
      final stored = await _secureStorage.read(key: _legacyKeyHealthToken);
      if (stored == null) {
        await _secureStorage.write(key: _legacyKeyHealthToken, value: tokenNow);
        _legacyKeyHealthy = true; // first-run trust-on-first-use
      } else {
        _legacyKeyHealthy = stored == tokenNow;
        if (!_legacyKeyHealthy) {
          _log.error(
            'EncryptionService',
            'Legacy key health MISMATCH — migration/overwrites DISABLED',
          );
        }
      }
    } else {
      _legacyKeyHealthy = false; // no legacy key => nothing to read-migrate
    }
  }

  bool get canOverwriteLegacy => _legacyKeyHealthy && _aesKey != null;

  // Callback to notify when key is set
  void Function()? onKeySet;

  /// Check if encryption key is already set
  Future<bool> isKeySet() async {
    final key = await _secureStorage.read(key: 'encryption_key');
    return key != null && key.isNotEmpty;
  }

  /// Set encryption key (one-time)
  Future<bool> setEncryptionKey(String key) async {
    try {
      final existing = await _secureStorage.read(key: 'encryption_key');
      if (existing != null && existing.isNotEmpty) {
        _log.warn('EncryptionService', 'Encryption key already set');
        return false; // Already set
      }

      await _secureStorage.write(key: 'encryption_key', value: key);
      _encryptionKey = key;
      _log.info('EncryptionService', 'Encryption key set successfully');

      // Notify listeners
      onKeySet?.call();

      return true;
    } catch (e) {
      _log.error('EncryptionService', 'Failed to set encryption key', e);
      return false;
    }
  }

  /// Get encryption key (requires developer password)
  Future<String?> getEncryptionKey(String password) async {
    if (password != _developerPassword) {
      _log.warn('EncryptionService', 'Invalid developer password');
      return null;
    }

    try {
      _encryptionKey = await _secureStorage.read(key: 'encryption_key');
      _log.info('EncryptionService', 'Encryption key retrieved');
      return _encryptionKey;
    } catch (e) {
      _log.error('EncryptionService', 'Failed to get encryption key', e);
      return null;
    }
  }

  /// Verify developer password
  bool verifyDeveloperPassword(String password) {
    final valid = password == _developerPassword;
    _log.info(
      'EncryptionService',
      'Developer password verification: ${valid ? 'success' : 'failed'}',
    );
    return valid;
  }

  /// Generate a random encryption key
  String generateRandomKey([int length = 32]) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*';
    final random = Random.secure();
    final key =
        List.generate(
          length,
          (index) => chars[random.nextInt(chars.length)],
        ).join();
    _log.debug('EncryptionService', 'Generated new random key');
    return key;
  }

  /// Encrypt a value using the stored key
  Future<String?> encrypt(String plainText) async {
    try {
      if (_encryptionKey == null) {
        _encryptionKey = await _secureStorage.read(key: 'encryption_key');
      }

      if (_encryptionKey == null) {
        _log.error('EncryptionService', 'No encryption key set');
        return null;
      }

      // Simple XOR encryption for demo (use proper AES in production)
      final keyBytes = utf8.encode(_encryptionKey!);
      final plainBytes = utf8.encode(plainText);
      final encryptedBytes = <int>[];

      for (int i = 0; i < plainBytes.length; i++) {
        encryptedBytes.add(plainBytes[i] ^ keyBytes[i % keyBytes.length]);
      }

      return base64Encode(encryptedBytes);
    } catch (e) {
      _log.error('EncryptionService', 'Encryption failed', e);
      return null;
    }
  }

  Future<String?> decrypt(String encryptedText) async {
    try {
      if (encryptedText.startsWith(_v2Tag)) {
        return await _decryptAesGcm(encryptedText.substring(_v2Tag.length));
      }
      return await _decryptLegacyXor(encryptedText); // untagged == v1
    } catch (e) {
      _log.error('EncryptionService', 'Decryption failed', e);
      return null;
    }
  }

  /// v1 reader. READ-ONLY forever — never produce new XOR ciphertext.
  Future<String?> _decryptLegacyXor(String encryptedText) async {
    _encryptionKey ??= await _secureStorage.read(key: _legacyKeyStorageKey);
    if (_encryptionKey == null) {
      _log.error('EncryptionService', 'No legacy key set');
      return null;
    }
    final keyBytes = utf8.encode(_encryptionKey!);
    final encryptedBytes = base64Decode(encryptedText);
    final plainBytes = <int>[];
    for (int i = 0; i < encryptedBytes.length; i++) {
      plainBytes.add(encryptedBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    // allowMalformed:false so a wrong key (garbage bytes) THROWS -> null,
    // rather than silently returning replacement-char mush.
    return utf8.decode(plainBytes, allowMalformed: false);
  }

  /// Re-encrypt legacy plaintext with the legacy key to compare against the
  /// stored v1 blob. Used by the migration verify (later steps); proves the
  /// legacy decrypt was correct before any overwrite.
  String xorEncryptLegacy(String plainText) {
    final keyBytes = utf8.encode(_encryptionKey!);
    final plainBytes = utf8.encode(plainText);
    final out = <int>[];
    for (int i = 0; i < plainBytes.length; i++) {
      out.add(plainBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    return base64Encode(out);
  }

  Future<String?> _decryptAesGcm(String b64Payload) async {
    if (_aesKey == null) {
      _log.error('EncryptionService', 'AES key not initialised');
      return null;
    }
    final raw = base64Decode(b64Payload);
    // layout: [12-byte nonce][ciphertext...][16-byte GCM tag]
    if (raw.length < 12 + 16) return null;
    final algo = AesGcm.with256bits();
    final nonce = raw.sublist(0, 12);
    final mac = Mac(raw.sublist(raw.length - 16));
    final cipher = raw.sublist(12, raw.length - 16);
    final clear = await algo.decrypt(
      SecretBox(cipher, nonce: nonce, mac: mac),
      secretKey: _aesKey!,
    );
    return utf8.decode(clear, allowMalformed: false);
  }
}
