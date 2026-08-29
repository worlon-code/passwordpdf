import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../features/settings/services/settings_service.dart';
import '../models/document_item_model.dart';
import '../models/recent_document_model.dart';
import 'document_service.dart';
import 'storage_service.dart';
import 'logging_service.dart';

/// Passphrase-encrypted backup of app STATE (whitelisted settings + document
/// list + recents). NOT the actual document file bytes.
///
/// Envelope is a faithful duplicate of PasswordBackupService's format with a
/// DIFFERENT magic ('DOCSETV1') so a docs backup can never be restored as
/// passwords or vice versa. Duplication is deliberate (extract was rejected in
/// the design review). If either KDF changes, keep both in sync.
class DocsSettingsBackupService {
  DocsSettingsBackupService(this._settings, this._docs, this._storage);
  final SettingsService _settings;
  final DocumentService _docs;
  final StorageService _storage;
  final LoggingService _log = LoggingService();

  static const String _magic = 'DOCSETV1';
  static const int _formatVersion = 1;
  static const int _kdfMemory = 32 * 1024;
  static const int _kdfIterations = 3;
  static const int _kdfParallelism = 1;
  static const int _saltLen = 16;
  static const int _keyLen = 32;

  Future<Uint8List> createBackup(String passphrase) async {
    if (passphrase.trim().isEmpty) {
      throw const FormatException('Passphrase required');
    }
    await _docs.initialize();
    final documentsJson =
        _docs.getAllItems().map((d) => d.toJson()).toList(growable: false);

    final recents = await _storage.getRecentDocuments();
    final recentsJson = recents.map((r) {
      final m = r.toMap();
      // Strip id — on restore we upsert by file_path (UNIQUE); a stale id
      // would let ConflictAlgorithm.replace clobber an UNRELATED local recent.
      m.remove('id');
      return m;
    }).toList(growable: false);

    final settingsJson = _settings.exportBackupMap();

    final payload = {
      'settings': settingsJson,
      'documents': documentsJson,
      'recents': recentsJson,
    };

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
    final plaintextJson = utf8.encode(jsonEncode(payload));
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
      'documentCount': documentsJson.length,
      'recentCount': recentsJson.length,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  Uint8List _randomBytes(int n) {
    final k = SecretKeyData.random(length: n);
    return Uint8List.fromList(k.bytes);
  }

  Future<DocsRestoreResult> restoreFromBytes(
    Uint8List bytes,
    String passphrase,
  ) async {
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Not a valid documents backup file');
    }
    if (env['magic'] != _magic) {
      throw const FormatException(
          'This file is not a Documents & Settings backup. Use the Password Manager for password backups.');
    }

    final int kMem, kIter, kPar;
    final List<int> salt, nonce, mac, ct;
    try {
      final kdf = env['kdf'] as Map<String, dynamic>;
      kMem = kdf['memory'] as int;
      kIter = kdf['iterations'] as int;
      kPar = kdf['parallelism'] as int;
      salt = base64Decode(kdf['salt'] as String);
      nonce = base64Decode(env['nonce'] as String);
      mac = base64Decode(env['mac'] as String);
      ct = base64Decode(env['ciphertext'] as String);
    } catch (_) {
      throw const FormatException('Not a valid documents backup file');
    }
    if (kMem < 8 * 1024 ||
        kMem > 256 * 1024 ||
        kIter < 1 ||
        kIter > 10 ||
        kPar < 1 ||
        kPar > 4 ||
        salt.length < 8 ||
        salt.length > 64) {
      throw const FormatException('Not a valid documents backup file');
    }

    final algorithm = Argon2id(
      memory: kMem,
      iterations: kIter,
      parallelism: kPar,
      hashLength: 32,
    );
    final secretKey = await algorithm.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    final aead = AesGcm.with256bits();
    final List<int> clear;
    try {
      clear = await aead.decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(mac)),
        secretKey: secretKey,
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('Wrong passphrase or corrupted backup');
    }

    final Map<String, dynamic> payload;
    final Map<String, dynamic> settingsMap;
    final List<DocumentItem> docItems;
    final List<Map<String, dynamic>> recentMaps;
    try {
      payload = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      settingsMap = (payload['settings'] as Map).cast<String, dynamic>();
      final rawDocs = (payload['documents'] as List);
      docItems = <DocumentItem>[];
      for (final raw in rawDocs) {
        try {
          docItems.add(DocumentItem.fromJson((raw as Map).cast<String, dynamic>()));
        } catch (recordError) {
          _log.error('DocsSettingsBackupService',
              'Skipping corrupt document record in backup', recordError);
        }
      }
      final rawRecents = (payload['recents'] as List);
      recentMaps = [
        for (final r in rawRecents)
          if (r is Map) (r).cast<String, dynamic>()
      ];
    } catch (_) {
      throw const FormatException('Corrupted backup contents');
    }

    await _settings.importBackupMap(settingsMap);
    final docsAdded = await _docs.mergeFromBackup(docItems);
    final recentsAdded = await _mergeRecents(recentMaps);

    return DocsRestoreResult(
      settingsApplied: true,
      documentsAdded: docsAdded,
      recentsAdded: recentsAdded,
    );
  }

  Future<int> _mergeRecents(List<Map<String, dynamic>> maps) async {
    var added = 0;
    for (final m in maps) {
      try {
        final withoutId = Map<String, dynamic>.of(m)..remove('id');
        final model = RecentDocumentModel.fromMap(withoutId); // VERIFY API
        await _storage.insertOrUpdateRecentDocument(model);
        added++;
      } catch (e) {
        _log.error('DocsSettingsBackupService', 'Skipping corrupt recent row', e);
      }
    }
    return added;
  }
}

class DocsRestoreResult {
  DocsRestoreResult({
    required this.settingsApplied,
    required this.documentsAdded,
    required this.recentsAdded,
  });
  final bool settingsApplied;
  final int documentsAdded;
  final int recentsAdded;
}
