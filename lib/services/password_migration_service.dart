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
  static const String _poisonKey = 'pw_v2_poison_ids_v1';
  static const String _failCountPrefix = 'pw_v2_fail_count_';
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

      final poisonIds = (prefs.getStringList(_poisonKey) ?? [])
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toSet();

      final all = await _storage.getAllPasswords();
      var migrated = 0;
      var v1remaining = 0;
      for (final p in all) {
        final id = p.id;
        if (id != null && poisonIds.contains(id)) continue;

        Future<void> recordFailure() async {
          if (id == null) {
            v1remaining++;
            return;
          }
          final failCount = (prefs.getInt('$_failCountPrefix$id') ?? 0) + 1;
          await prefs.setInt('$_failCountPrefix$id', failCount);
          if (failCount >= 3) {
            poisonIds.add(id);
            await prefs.setStringList(
              _poisonKey,
              poisonIds.map((e) => e.toString()).toList(),
            );
          } else {
            v1remaining++;
          }
        }

        try {
          final ct = p.encryptedValue;
          if (ct.startsWith('v2:')) continue; // already v2
          if (id == null) {
            await recordFailure();
            continue;
          }
          final plain = await _enc.decrypt(ct); // v1 decrypt (read-both)
          if (plain == null) {
            await recordFailure();
            continue;
          }
          // Prove the v1 side: legacy re-encrypt must reproduce ct exactly.
          if (_enc.xorEncryptLegacy(plain) != ct) {
            await recordFailure();
            continue;
          }
          final v2 = await _enc.encrypt(plain);
          if (v2 == null || !v2.startsWith('v2:')) {
            await recordFailure();
            continue;
          }
          // Prove the v2 side round-trips BEFORE the destructive replace.
          final back = await _enc.decrypt(v2);
          if (back != plain) {
            await recordFailure();
            continue;
          }
          // Compare-and-swap: only replace if the row still holds the old ct.
          final n = await _storage.migratePasswordCiphertext(id, ct, v2);
          if (n == 1) {
            await prefs.remove('$_failCountPrefix$id');
            migrated++;
          } else {
            await recordFailure();
          }
        } catch (_) {
          await recordFailure(); // one bad row never aborts the sweep
        }
      }
      if (v1remaining == 0) await prefs.setBool(_sweepDoneKey, true);
      return migrated;
    } finally {
      _sweeping = false;
    }
  }
}
