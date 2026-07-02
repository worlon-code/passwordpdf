import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../models/password_model.dart';
import 'storage_service.dart';
import 'encryption_service.dart';
import 'logging_service.dart';

/// Portable, Keystore-independent backup of all password rows.
/// File format is an Argon2id-passphrase-wrapped AES-GCM JSON envelope.
class PasswordBackupService {
  PasswordBackupService(this._storage, this._encryption);
  final StorageService _storage;
  final EncryptionService _encryption;
  final LoggingService _log = LoggingService();

  static const String _magic = 'PWDBAK';
  static const int _formatVersion = 1;
  static const int _kdfMemory = 32 * 1024; // 32 MiB
  static const int _kdfIterations = 3;
  static const int _kdfParallelism = 1;
  static const int _saltLen = 16;
  static const int _keyLen = 32;

  Future<List<Map<String, String>>> _collectPlaintext() async {
    final rows = await _storage.getAllPasswords();
    final out = <Map<String, String>>[];
    for (final r in rows) {
      final secret = await _encryption.decrypt(r.encryptedValue);
      if (secret == null) {
        _log.error(
          'PasswordBackupService',
          'Skipping "${r.keyName}" — decrypt returned null',
        );
        continue;
      }
      out.add({'keyName': r.keyName, 'secret': secret});
    }
    return out;
  }

  Future<Uint8List> createBackup(String passphrase) async {
    if (passphrase.trim().isEmpty) {
      throw const FormatException('Passphrase required');
    }
    final entries = await _collectPlaintext();
    if (entries.isEmpty) {
      throw const FormatException('No decryptable passwords to back up');
    }

    final algorithm = Argon2id(
      memory: _kdfMemory,
      iterations: _kdfIterations,
      parallelism: _kdfParallelism,
      hashLength: _keyLen,
    );
    final salt = _randomBytes(_saltLen);
    final secretKey = await algorithm.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );

    final aead = AesGcm.with256bits();
    final plaintextJson = utf8.encode(jsonEncode({'entries': entries}));
    final secretBox = await aead.encrypt(plaintextJson, secretKey: secretKey);

    final envelope = {
      'magic': _magic,
      'format': _formatVersion,
      'kdf': {
        'name': 'argon2id',
        'memory': _kdfMemory,
        'iterations': _kdfIterations,
        'parallelism': _kdfParallelism,
        'salt': base64Encode(salt),
      },
      'cipher': 'aes-256-gcm',
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
      'ciphertext': base64Encode(secretBox.cipherText),
      'count': entries.length,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  Uint8List _randomBytes(int n) {
    final k = SecretKeyData.random(length: n);
    return Uint8List.fromList(k.bytes);
  }
}

enum ConflictStatus {
  fresh,
  sameNameSameSecret,
  sameNameDiffSecret,
  sameSecretDiffName,
}

enum ConflictResolution { skip, rename, keepBoth }

/// UI-facing conflict row. NO SECRET FIELD — by design.
class RestoreConflict {
  RestoreConflict({
    required this.backupName,
    required this.localName,
    required this.status,
    required Map<String, String> entry,
  }) : _entry = entry,
       resolution =
           status == ConflictStatus.fresh
               ? ConflictResolution.keepBoth
               : ConflictResolution.skip;

  final String backupName;
  final String localName;
  final ConflictStatus status;
  ConflictResolution resolution;
  String? renameTo;
  final Map<String, String> _entry;

  String get backupSecret => _entry['secret']!;
}

extension RestoreOps on PasswordBackupService {
  Future<List<RestoreConflict>> restoreFromBytes(
    Uint8List bytes,
    String passphrase,
  ) async {
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Not a valid backup file');
    }
    if (env['magic'] != 'PWDBAK') {
      throw const FormatException('Not a valid backup file');
    }
    final kdf = env['kdf'] as Map<String, dynamic>;
    final algorithm = Argon2id(
      memory: kdf['memory'] as int,
      iterations: kdf['iterations'] as int,
      parallelism: kdf['parallelism'] as int,
      hashLength: 32,
    );
    final secretKey = await algorithm.deriveKeyFromPassword(
      password: passphrase,
      nonce: base64Decode(kdf['salt'] as String),
    );
    final aead = AesGcm.with256bits();
    final List<int> clear;
    try {
      clear = await aead.decrypt(
        SecretBox(
          base64Decode(env['ciphertext'] as String),
          nonce: base64Decode(env['nonce'] as String),
          mac: Mac(base64Decode(env['mac'] as String)),
        ),
        secretKey: secretKey,
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('Wrong passphrase or corrupted backup');
    }
    final decoded = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final entries =
        (decoded['entries'] as List)
            .map((e) => (e as Map).map((k, v) => MapEntry('\$k', '\$v')))
            .toList();

    final locals = await _storage.getAllPasswords();
    final localByName = {for (final p in locals) p.keyName: p};
    final localPlainByName = <String, String>{};
    for (final p in locals) {
      final d = await _encryption.decrypt(p.encryptedValue);
      if (d != null) localPlainByName[p.keyName] = d;
    }

    final conflicts = <RestoreConflict>[];
    for (final e in entries) {
      final bName = e['keyName'] ?? '';
      final bSecret = e['secret'] ?? '';
      ConflictStatus status;
      String localName = '';
      if (localByName.containsKey(bName)) {
        localName = bName;
        status =
            localPlainByName[bName] == bSecret
                ? ConflictStatus.sameNameSameSecret
                : ConflictStatus.sameNameDiffSecret;
      } else {
        final match = localPlainByName.entries
            .where((le) => le.value == bSecret)
            .map((le) => le.key)
            .cast<String?>()
            .firstWhere((_) => true, orElse: () => null);
        if (match != null) {
          localName = match;
          status = ConflictStatus.sameSecretDiffName;
        } else {
          status = ConflictStatus.fresh;
        }
      }
      conflicts.add(
        RestoreConflict(
          backupName: bName,
          localName: localName,
          status: status,
          entry: e,
        ),
      );
    }
    return conflicts;
  }

  Future<int> applyRestore(List<RestoreConflict> conflicts) async {
    var imported = 0;
    for (final c in conflicts) {
      if (c.resolution == ConflictResolution.skip) continue;
      if (c.status == ConflictStatus.sameNameSameSecret) continue;
      var name = c.backupName;
      if (c.resolution == ConflictResolution.rename && c.renameTo != null) {
        name = c.renameTo!.trim();
      } else if (c.resolution == ConflictResolution.keepBoth &&
          c.status == ConflictStatus.sameNameDiffSecret) {
        name = await _uniquify(c.backupName);
      }
      final enc = await _encryption.encrypt(c.backupSecret);
      if (enc == null) continue;
      await _storage.insertPassword(
        PasswordModel(
          keyName: name,
          encryptedValue: enc,
          createdAt: DateTime.now(),
        ),
      );
      imported++;
    }
    return imported;
  }

  Future<String> _uniquify(String base) async {
    var i = 2;
    var candidate = '$base ($i)';
    while (await _storage.passwordKeyExists(candidate)) {
      i++;
      candidate = '$base ($i)';
    }
    return candidate;
  }
}
