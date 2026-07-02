import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto; // sha256 key-health token
import 'package:shared_preferences/shared_preferences.dart'; // v2 key-health mirror (survives Keystore wipe)
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

  // Dev gate: salted Argon2id digest of the developer password, computed
  // offline (tool/gen_devgate.dart). The plaintext is NOT in the binary.
  // To rotate, recompute both with a new password.
  static const String _devGateSalt = 'W2ns6cidnjtLXZKNHegkow==';
  static const String _devGateHash =
      'hJC9zPJE81CwYJOEftyoTISZAySVplRrhrKfUytA9E0=';
  String? _encryptionKey;

  // v2 AES key: Keystore-backed, minted once. Daily use, no master password.
  static const String _aesKeyStorageKey = 'aes_key_v2';
  // Legacy XOR key: READ-ONLY forever for v1 reads. Never written again.
  static const String _legacyKeyStorageKey = 'encryption_key';
  // sha256(legacy key) recorded when health is known-good; gates all overwrites.
  static const String _legacyKeyHealthToken = 'legacy_key_health_v1';
  // sha256(aes_key_v2) mirror stored in PLAIN SharedPreferences so it SURVIVES a
  // Keystore wipe (secure storage vanishes with the Keystore). Lets us detect
  // that aes_key_v2 was wiped + silently re-minted, which would orphan v2 data.
  static const String _v2KeyHealthPref = 'v2_key_health_v1';
  static const String _v2Tag = 'v2:'; // ciphertext namespace tag (read-both)

  SecretKey? _aesKey; // cached v2 key (decoded)
  bool _legacyKeyHealthy = false; // true only after token matches
  bool _v2KeyHealthy = false; // true only when the v2 key matches its health mirror (or fresh)
  bool _initialized = false; // set true only after initCrypto() fully completes

  /// Call ONCE from single-threaded startup, before any encrypt/decrypt.
  Future<void> initCrypto() async {
    // Idempotency guard: re-entry within a process is a no-op. Gated on a
    // DEDICATED flag (not _aesKey) set only AFTER init fully completes, so a
    // partial init (e.g. a prefs write throws) is re-runnable, not latched.
    // (Minting stays double-safe via the `b64 == null` check below.)
    if (_initialized) return;
       // 1) Ensure v2 key exists (mint once) + detect a Keystore wipe/re-mint.
    // Read the plain-prefs health mirror BEFORE minting: if a mirror exists but
    // the current v2 key is gone (or differs), the Keystore was wiped and any v2
    // data written under the old key is now unreadable -> disable v2 writes.
    final prefs = await SharedPreferences.getInstance();
    final priorHealth = prefs.getString(_v2KeyHealthPref);
    var b64 = await _secureStorage.read(key: _aesKeyStorageKey);
    if (b64 == null || b64.isEmpty) {
      final fresh = await AesGcm.with256bits().newSecretKey();
      final bytes = await fresh.extractBytes();
      b64 = base64Encode(bytes);
      await _secureStorage.write(key: _aesKeyStorageKey, value: b64);
      _log.info('EncryptionService', 'Minted aes_key_v2 (256-bit)');
    }
    final keyBytes = base64Decode(b64);
    _aesKey = SecretKey(keyBytes);
    final healthNow = crypto.sha256.convert(keyBytes).toString();
    if (priorHealth == null) {
      // First run of wipe-detection (fresh install, or upgrade from a build that
      // minted the key before detection existed). Trust-on-first-use: record the
      // baseline. Safe because no v2 data can exist before the writer ships.
      await prefs.setString(_v2KeyHealthPref, healthNow);
      _v2KeyHealthy = true;
    } else if (priorHealth == healthNow) {
      _v2KeyHealthy = true; // current key matches its mirror
    } else {
      // Mirror exists but the current key differs: re-minted after a Keystore
      // wipe (or the key changed). v2 data under the old key is orphaned. Keep
      // the old mirror as evidence and DISABLE v2 writes; recovery = passphrase
      // Restore.
      _v2KeyHealthy = false;
      _log.error(
        'EncryptionService',
        'v2 key health MISMATCH (Keystore wipe/re-mint) — v2 writes DISABLED',
      );
    }

    // 1b) v2-key FUNCTIONAL self-test: a hash match only proves the key BYTES
    // are unchanged, not that the Keystore can still perform crypto with them
    // (a key can be present but invalidated). Require a real encrypt->decrypt
    // round-trip before trusting the key to WRITE v2 data.
    if (_v2KeyHealthy) {
      try {
        // Round-trip through the SAME envelope build + slice as real writes/reads,
        // so a future package change to nonce/tag length flips health false
        // (fail-safe) instead of silently writing unreadable v2.
        final raw = await _buildV2Blob('v2_selftest');
        final back = await _decryptAesGcm(base64Encode(raw));
        if (back != 'v2_selftest') {
          _v2KeyHealthy = false;
          _log.error('EncryptionService',
              'v2 key self-test MISMATCH — v2 writes DISABLED');
        }
      } catch (e) {
        _v2KeyHealthy = false;
        _log.error('EncryptionService',
            'v2 key self-test threw — v2 writes DISABLED', e);
      }
    }

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

    // NOTE: initCrypto() intentionally has NO internal try/catch — main.dart
    // wraps this call in a swallowing try/catch, so if secure-storage read/write
    // THROWS (corrupt Keystore) we leave _aesKey null + _v2KeyHealthy false =>
    // canWriteV2 false (fail-safe). Do NOT remove that main.dart guard.
    _initialized = true; // reached only on a fully successful init
  }

  bool get canOverwriteLegacy => _legacyKeyHealthy && _aesKey != null;
  /// Safe to WRITE new v2 ciphertext. The v2 writer + migration MUST gate on
  /// this so a wiped/re-minted key can never produce unreadable v2 data.
  bool get canWriteV2 => _v2KeyHealthy && _aesKey != null;

  /// RESTORE-ONLY re-bless: adopt the current in-Keystore v2 key as healthy.
  /// Functional self-test first; on success, persist the health mirror for the
  /// current key and enable v2 writes. Returns false if the key can't round-trip
  /// (caller MUST abort). Passphrase Restore calls this because it deliberately
  /// re-establishes the password set under the CURRENT device key (e.g. a Keystore
  /// wipe silently re-minted it). DO NOT call from initCrypto/encrypt/startup —
  /// that would mask a real key wipe and defeat the fail-safe.
  Future<bool> adoptCurrentV2KeyAsHealthy() async {
    if (_aesKey == null) return false;
    try {
      final raw = await _buildV2Blob('v2_selftest');
      final back = await _decryptAesGcm(base64Encode(raw));
      if (back != 'v2_selftest') return false;
    } catch (_) {
      return false;
    }
    try {
      final bytes = await _aesKey!.extractBytes();
      final healthNow = crypto.sha256.convert(bytes).toString();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_v2KeyHealthPref, healthNow);
      _v2KeyHealthy = true;
      _log.info('EncryptionService',
          'Adopted current v2 key as healthy (restore re-bless)');
      return true;
    } catch (e) {
      _log.error('EncryptionService', 'adopt: failed to persist health', e);
      return false;
    }
  }

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

  Future<String?> getEncryptionKey(String password) async {
    if (!await verifyDeveloperPassword(password)) {
      _log.warn('EncryptionService', 'Invalid developer password');
      return null;
    }
    try {
      _encryptionKey = await _secureStorage.read(key: _legacyKeyStorageKey);
      _log.info('EncryptionService', 'Encryption key retrieved');
      return _encryptionKey;
    } catch (e) {
      _log.error('EncryptionService', 'Failed to get encryption key', e);
      return null;
    }
  }

  /// sha256 of the active v2 key, truncated to 8 bytes hex. Never the key itself.
  Future<String?> keyFingerprint() async {
    final b64 = await _secureStorage.read(key: _aesKeyStorageKey);
    if (b64 == null || b64.isEmpty) return null;
    final digest = crypto.sha256.convert(base64Decode(b64)).bytes;
    return digest
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Verify developer password (salted Argon2id, constant-time).
  Future<bool> verifyDeveloperPassword(String password) async {
    try {
      final salt = base64Decode(_devGateSalt);
      final algo = Argon2id(
        memory: 19 * 1024,
        parallelism: 1,
        iterations: 2,
        hashLength: 32,
      );
      final key = await algo.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );
      final bytes = await key.extractBytes();
      final expected = base64Decode(_devGateHash);
      var diff = bytes.length ^ expected.length;
      for (var i = 0; i < bytes.length && i < expected.length; i++) {
        diff |= bytes[i] ^ expected[i];
      }
      final valid = diff == 0;
      _log.info(
        'EncryptionService',
        'Developer password verification: ${valid ? 'success' : 'failed'}',
      );
      return valid;
    } catch (e) {
      _log.error(
        'EncryptionService',
        'Developer password verification error',
        e,
      );
      return false;
    }
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
  /// Build a v2 AES-256-GCM envelope for [plainText]: [12B nonce][ciphertext][16B
  /// GCM tag] — the exact layout _decryptAesGcm slices. Shared by encrypt() and
  /// the key self-test. Requires _aesKey != null (callers ensure it).
  Future<List<int>> _buildV2Blob(String plainText) async {
    final algo = AesGcm.with256bits();
    final box = await algo.encrypt(utf8.encode(plainText), secretKey: _aesKey!);
    return <int>[...box.nonce, ...box.cipherText, ...box.mac.bytes];
  }

  /// Encrypt a value as v2 (AES-256-GCM, tagged 'v2:'). Refuses to write (returns
  /// null) when the v2 key is unhealthy/unavailable — NEVER emits legacy XOR or
  /// undecryptable data. Callers already treat null as a failure and surface it.
  Future<String?> encrypt(String plainText) async {
    try {
      if (!canWriteV2) {
        _log.error('EncryptionService',
            'encrypt blocked: v2 key not writable (unhealthy/uninitialised)');
        return null;
      }
      final raw = await _buildV2Blob(plainText);
      return '$_v2Tag${base64Encode(raw)}';
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
    final key = _encryptionKey;
    if (key == null) {
      throw StateError('xorEncryptLegacy: legacy key not loaded');
    }
    final keyBytes = utf8.encode(key);
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
