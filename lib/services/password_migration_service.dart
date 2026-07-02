import 'package:shared_preferences/shared_preferences.dart';
import 'encryption_service.dart';
import 'storage_service.dart';

/// One-time migration of stored passwords from legacy XOR (v1, untagged) to
/// AES-256-GCM (v2, 'v2:'). Safe, idempotent, crash-safe:
/// - gated on BOTH keys healthy (can read v1 AND write v2);
/// - proves the legacy decrypt round-trips before touching a row (invariant #2);
/// - proves the new v2 blob decrypts back to the same plaintext BEFORE the
///   destructive replace;
/// - compare-and-swap per row so a concurrent user edit is never clobbered;
/// - one bad row never aborts the sweep; the done-flag is only set when zero v1
///   rows remain, so a partial/crashed run simply resumes next launch.
class PasswordMigrationService {
  final EncryptionService _enc;
  final StorageService _storage;
  PasswordMigrationService(this._enc, this._storage);

  static const String _sweepDoneKey = 'pw_v2_sweep_done_v1';
  static bool _sweeping = false; // re-entrancy guard: one sweep at a time

  /// Returns the number of rows migrated this run.
  Future<int> migrateLegacyToV2() async {
    if (_sweeping) return 0;
    _sweeping = true;
    try {
      // Gate: need to read v1 (legacy healthy) AND write v2 (v2 healthy).
      if (!_enc.canOverwriteLegacy || !_enc.canWriteV2) return 0;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_sweepDoneKey) == true) return 0;

      final all = await _storage.getAllPasswords();
      var migrated = 0;
      var v1remaining = 0;
      for (final p in all) {
        try {
          final ct = p.encryptedValue;
          if (ct.startsWith('v2:')) continue; // already v2
          final id = p.id;
          if (id == null) {
            v1remaining++;
            continue;
          }
          final plain = await _enc.decrypt(ct); // v1 decrypt (read-both)
          if (plain == null) {
            v1remaining++;
            continue;
          }
          // Prove the v1 side: legacy re-encrypt must reproduce ct exactly.
          if (_enc.xorEncryptLegacy(plain) != ct) {
            v1remaining++;
            continue;
          }
          final v2 = await _enc.encrypt(plain);
          if (v2 == null || !v2.startsWith('v2:')) {
            v1remaining++;
            continue;
          }
          // Prove the v2 side round-trips BEFORE the destructive replace.
          final back = await _enc.decrypt(v2);
          if (back != plain) {
            v1remaining++;
            continue;
          }
          // Compare-and-swap: only replace if the row still holds the old ct.
          final n = await _storage.migratePasswordCiphertext(id, ct, v2);
          if (n == 1) {
            migrated++;
          } else {
            v1remaining++;
          }
        } catch (_) {
          v1remaining++; // one bad row never aborts the sweep
        }
      }
      if (v1remaining == 0) await prefs.setBool(_sweepDoneKey, true);
      return migrated;
    } finally {
      _sweeping = false;
    }
  }
}
