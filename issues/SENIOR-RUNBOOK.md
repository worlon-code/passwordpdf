# PDF Password Manager — SENIOR RUNBOOK (the bigger work)

> **Audience: a senior engineer (NOT a low/auto model).** Every card touches production-sensitive logic — most of it rewrites every user's saved passwords. Apply **ONE sub-step per prompt**, verify (analyze + unit test), and **device-test** before moving on. This is the companion to the low-risk `AGENT-RUNBOOK.md` (already executed).

## Conventions & environment
- **Branch:** `experimental_flutter_upgrade` (current dev branch; prod is `main` @ 1.1.8+117 — untouched). Verify each "Locate" anchor against the working tree before editing; line hints are approximate.
- **Toolchain:** Flutter 3.38.6 / Dart 3.10.7 via FVM.
- **Build (per `.agent/rules/test.md`):** builds go through Gradle and **must be logged UTF-8**:
  - `cd android; .\gradlew.bat assembleDebug` (debug) / `assembleRelease` (release) → output saved to `D:\Repos\passwordpdf\logs\build_<timestamp>.txt` (fallback `logs\` in project root).
  - APK output: `android\app\build\outputs\apk\debug\app-debug.apk` (NOT `build/app/outputs/flutter-apk`).
  - **Version bump in TWO places** before a release build: `pubspec.yaml` `version:` AND `android/local.properties` (`flutter.versionName` + `flutter.versionCode`) — else stale version code / update loops.
- **Device/adb:** `D:\idm\platform-tools-latest-windows\adb.exe` (verify `adb devices` first). Package `com.passwordpdf.passwordpdf_manager`.
- **Release deploy:** copy `app-release.apk` → `passwordpdf-releases\releases\vX.Y.Z\`, update `version.json`, **add the APK `sha256`** (activates the Task-1 update verification), keep only the latest 3 versions, push.

## Chosen crypto key strategy: **Keystore + passphrase backup**
- AES-256 key (`aes_key_v2`) lives in the Android Keystore (via `flutter_secure_storage` EncryptedSharedPreferences), minted once at startup. **No master password for daily use** (zero added friction).
- A **user passphrase** is required **only** for the portable Backup/Restore (Part 1B, Argon2id-wrapped) — that's the recovery path if the Keystore is wiped (device change / restore).
- The legacy XOR key (`encryption_key`) stays **read-only forever** so all existing (v1) ciphertext keeps decrypting.

## Non-negotiable data-safety invariants (the migration must obey ALL)
1. **Read-both first.** Ship the tagged `decrypt()` (v2=AES / untagged=v1 XOR) and let it saturate in production **before** enabling any v2 *write*.
2. **Verify on the LEGACY side before overwriting:** `xorEncryptLegacy(decrypt(x)) == stripTag(x)` (with `utf8.decode(allowMalformed:false)`). AES round-tripping its own output proves nothing — XOR has no integrity, so a wrong key yields valid-looking garbage.
3. **Key-health gate:** compare `sha256(legacy key)` to a stored token; if it mismatches (Keystore wiped/restored), **disable all migration + overwrites** and route to passphrase-restore.
4. **Single writer + compare-and-swap** for every write-back; migrate the `document_passwords` map *through* `PdfPasswordService`'s in-memory map, never raw prefs.
5. **CSPRNG only** for keys/nonces/salts (let the `cryptography` package mint them). Namespace tags: ciphertext `v2:`, PIN `pin:v2:`.
6. **Backup before sweep:** the passphrase Backup (1B) ships before the one-time migration sweep (1C).

## Order of work
1. **Part 1A** — Crypto core (read-both dispatcher, AES-GCM, Keystore key, PIN/dev-gate hardening, zip-pw)
2. **Part 1B** — Passphrase Backup/Restore (Feature 5) — *must precede the sweep*
3. **Part 1C** — Migration (lazy migrate-on-read + key-health-gated sweep)
4. **Part 2** — PDF tools real fidelity (Task 26)
5. **Part 3** — Export "Remove password" (Task 27)
6. **Part 4** — Store refactor onto SQLite (Tasks 30 & 31) — design plan, multi-PR

---
## Part 1A - Crypto core: read-both dispatcher + AES-GCM + Keystore key (Tasks 15 and 19)

> Scope: this section hardens the cryptographic core of `passwordpdf_manager`. Task 15 replaces the legacy XOR cipher with AES-256-GCM while keeping a **read-both** dispatcher so every v1 (untagged XOR) ciphertext stays readable forever. Task 19 hardens the secrets-at-rest surface: the app PIN (plaintext today), the developer gate (hardcoded `Portal123!`), the developer-screen key reveal, and the `zip_password` persisted in the export queue.
>
> **KEY STRATEGY (read this before any card):** Keystore + passphrase backup. The AES key lives in `flutter_secure_storage` (Android Keystore-backed, `EncryptedSharedPreferences`) under a **new** key `'aes_key_v2'`, minted **once** at single-threaded startup. There is **no master password** for daily use. A user passphrase is required **only** for the portable Backup/Restore flow (Task 16, Argon2id-wrapped — out of scope here). The legacy `'encryption_key'` (XOR) stays **read-only forever** for v1 reads.
>
> **ROLLOUT ORDER (hard gate):** read-both (Step 15a–15d) must saturate in production before any v2 **write** is enabled. Passphrase Backup (Task 16) must ship before the migration sweep (Task 18). Do **not** flip a write flag in this section.
>
> Every card below is **Senior-review: apply ONE sub-step per prompt, verify, device-test.**

---

### Step 15a - Add crypto deps and import the AES-GCM primitives
- File(s): `pubspec.yaml`; `lib/services/encryption_service.dart` (branch `experimental_flutter_upgrade`; line hints approximate, VERIFY before editing)
- Goal: add the `cryptography` package (AES-GCM, Argon2id) alongside the existing `crypto` (sha256), and import them in the encryption service.
- Locate (verbatim from the branch) — `pubspec.yaml` dependency block already contains `crypto`:
```yaml
  # Update System
  dio: ^5.7.0
  crypto: ^3.0.3
  package_info_plus: ^8.1.0
```
- Locate (verbatim) — `encryption_service.dart` imports:
```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:math';
import 'logging_service.dart';
```
- Change — `pubspec.yaml` (keep `crypto`; add `cryptography` in the same block):
```yaml
  # Update System
  dio: ^5.7.0
  crypto: ^3.0.3            # sha256 for key-health token + PIN PBKDF2 fallback
  cryptography: ^2.7.0      # AES-256-GCM (Task 15) + Argon2id (Tasks 16/19)
  package_info_plus: ^8.1.0
```
- Change — `encryption_service.dart` imports:
```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto; // sha256 key-health token
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'logging_service.dart';
```
- Why / safeguards: `cryptography` ships a constant-time-ish, well-reviewed `AesGcm` and mints nonces/keys with a CSPRNG, so we never hand-roll AES or a nonce counter. `crypto` is already pinned — reuse it for the sha256 key-health token rather than adding a second hash lib. Pin exact majors so a transitive bump can't silently change the KDF.
- Test: static — `cd android && ./gradlew assembleDebug` after `flutter pub get`, log the result per `.agent/rules/test.md`. Confirm `flutter pub deps | grep cryptography` resolves a single version. No device test for this step.
- WARNING / Data-safety: adding the dep is inert. Do **not** in this step touch `encrypt()`/`decrypt()` — a half-applied dispatcher that writes v2 before read-both saturates strands data on devices still on the old build.

---

### Step 15b - Mint the Keystore-backed `aes_key_v2` once at single-threaded startup + key-health token
- File(s): `lib/services/encryption_service.dart` (VERIFY line numbers)
- Goal: at app init, ensure a 256-bit `aes_key_v2` exists in secure storage (generate once if absent) and record a sha256 health token of the **legacy** key so we can detect a wiped/restored Keystore before any write.
- Locate (verbatim) — current secure-storage field, cached key field, and `isKeySet`:
```dart
final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
  ),
);
```
```dart
String? _encryptionKey;
```
```dart
  {
    final key = await _secureStorage.read(key: 'encryption_key');
    return key != null && key.isNotEmpty;
  }
```
- Change — add fields + a one-shot `initCrypto()` called from single-threaded startup (NOT lazily inside `encrypt`/`decrypt`, to avoid a race that mints two keys):
```dart
  // v2 AES key: Keystore-backed, minted once. Daily use, no master password.
  static const String _aesKeyStorageKey = 'aes_key_v2';
  // Legacy XOR key: READ-ONLY forever for v1 reads. Never written again.
  static const String _legacyKeyStorageKey = 'encryption_key';
  // sha256(legacy key) recorded when health is known-good; gates all overwrites.
  static const String _legacyKeyHealthToken = 'legacy_key_health_v1';

  SecretKey? _aesKey;            // cached v2 key (decoded)
  bool _legacyKeyHealthy = false; // true only after token matches

  /// Call ONCE from single-threaded startup, before any encrypt/decrypt.
  Future<void> initCrypto() async {
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
      final tokenNow =
          crypto.sha256.convert(utf8.encode(legacy)).toString();
      final stored = await _secureStorage.read(key: _legacyKeyHealthToken);
      if (stored == null) {
        await _secureStorage.write(
            key: _legacyKeyHealthToken, value: tokenNow);
        _legacyKeyHealthy = true; // first-run trust-on-first-use
      } else {
        _legacyKeyHealthy = stored == tokenNow;
        if (!_legacyKeyHealthy) {
          _log.error('EncryptionService',
              'Legacy key health MISMATCH — migration/overwrites DISABLED');
        }
      }
    } else {
      _legacyKeyHealthy = false; // no legacy key => nothing to read-migrate
    }
  }

  bool get canOverwriteLegacy => _legacyKeyHealthy && _aesKey != null;
```
- Why / safeguards: minting at single-threaded startup removes the double-mint race that a lazy `if (_aesKey == null)` inside `encrypt`/`decrypt` would create under concurrent first calls. The health token is the kill-switch from the audit: if the Keystore was wiped (device restore, `allowBackup`, factory cipher reset), the legacy bytes change, the sha256 won't match, `_legacyKeyHealthy` goes false, and `canOverwriteLegacy` blocks every write/migration — routing the user to passphrase-restore (Task 16) instead of letting a bad key drive a write. TOFU on first run is acceptable because the legacy ciphertext is itself the ground truth at that point.
- Test: static build + log. Unit test (feasible, pure-Dart with `flutter_secure_storage` mocked via `setMockInitialValues`/a fake): (a) absent `aes_key_v2` → minted, 32 bytes after `base64Decode`; (b) second `initCrypto()` does **not** re-mint (read the value before/after); (c) flipping the stored legacy key after a token is recorded sets `canOverwriteLegacy == false`. Device test: `adb shell am force-stop <pkg>; adb shell am start ...`, then `adb logcat | grep EncryptionService` shows exactly one "Minted aes_key_v2" on first launch and none on relaunch.
- WARNING / Data-safety: never call `initCrypto()` from multiple isolates. The legacy `'encryption_key'` is **read-only** — this step must not write it. If `canOverwriteLegacy` is false, every later write path (Steps 18+, out of scope) MUST no-op and surface restore UI; do not silently fall back to writing with a possibly-wrong key (XOR has no integrity, so a wrong key still yields valid-looking base64 garbage).

---

### Step 15c - Tagged read-both `decrypt()` dispatcher (v2 = AES-GCM, untagged = legacy XOR)
- File(s): `lib/services/encryption_service.dart` (VERIFY line numbers)
- Goal: make `decrypt()` route on a `'v2:'` namespace tag — AES-GCM for tagged, the existing XOR for untagged v1 — preserving the null-on-failure contract.
- Locate (verbatim) — current `decrypt()`:
```dart
Future<String?> decrypt(String encryptedText) async {
  try {
    if (_encryptionKey == null) {
      _encryptionKey = await _secureStorage.read(key: 'encryption_key');
    }
    
    if (_encryptionKey == null) {
      _log.error('EncryptionService', 'No encryption key set');
      return null;
    }
    
    final keyBytes = utf8.encode(_encryptionKey!);
    final encryptedBytes = base64Decode(encryptedText);
    final plainBytes = <int>[];
    
    for (int i = 0; i < encryptedBytes.length; i++) {
      plainBytes.add(encryptedBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    
    return utf8.decode(plainBytes);
  } catch (e) {
    _log.error('EncryptionService', 'Decryption failed', e);
    return null;
  }
}
```
- Change — dispatcher + a renamed read-only legacy path + the new AES-GCM reader. Note the tag constant and the `allowMalformed: false` decode:
```dart
static const String _v2Tag = 'v2:'; // ciphertext namespace tag

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
/// stored v1 blob. Used by the migration verify (Steps 18+), proves the
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
```
- Why / safeguards: the dispatcher is the heart of read-both — untagged blobs (every value written by the current app) keep flowing through the exact XOR math you fetched, byte-for-byte. `_decryptAesGcm` lets `AesGcm.decrypt` verify the GCM tag, so a wrong v2 key or tampered blob throws → caught → `null` (integrity we never had with XOR). `allowMalformed: false` is the audit requirement: a wrong **legacy** key produces non-UTF-8 bytes that now throw instead of returning replacement-character "success". `xorEncryptLegacy` is exposed so the later sweep can prove `xorEncryptLegacy(decrypt(stored)) == stripTag(stored)` before overwriting.
- Test: static build + log. Unit test: (a) a hand-built untagged XOR blob with the known legacy key round-trips through `decrypt`; (b) a `'v2:'` blob produced by Step 15d round-trips; (c) a `'v2:'` blob with one byte flipped → `decrypt` returns `null` (MAC fail); (d) an untagged blob decrypted with a wrong legacy key → `null` (UTF-8 throw). Device: read an existing stored password in the UI after upgrade — it must still display.
- WARNING / Data-safety: this step changes **reads only** — `encrypt()` is untouched here, so nothing new is written yet. Keep the null-on-failure contract: do **not** force-unwrap `_aesKey`/`_encryptionKey`. Never delete or rewrite the legacy `'encryption_key'`. Do not strip the `'v2:'` tag from stored values anywhere except inside `_decryptAesGcm`.

---

### Step 15d - AES-256-GCM `encrypt()` (writes `'v2:'`) — gated, ship AFTER read-both saturates
- File(s): `lib/services/encryption_service.dart` (VERIFY line numbers)
- Goal: replace the XOR `encrypt()` with AES-256-GCM that emits `'v2:'`-tagged ciphertext using the Keystore key and a fresh CSPRNG nonce per call.
- Locate (verbatim) — current `encrypt()`:
```dart
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
```
- Change — AES-GCM writer:
```dart
Future<String?> encrypt(String plainText) async {
  try {
    if (_aesKey == null) {
      _log.error('EncryptionService', 'AES key not initialised; call initCrypto');
      return null;
    }
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce(); // CSPRNG, 12 bytes, fresh per call
    final box = await algo.encrypt(
      utf8.encode(plainText),
      secretKey: _aesKey!,
      nonce: nonce,
    );
    // layout: [12 nonce][ciphertext][16 mac]
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return '$_v2Tag${base64Encode(out.toBytes())}';
  } catch (e) {
    _log.error('EncryptionService', 'Encryption failed', e);
    return null;
  }
}
```
- Why / safeguards: `algo.newNonce()` mints a fresh 12-byte CSPRNG nonce every call — never reuse a nonce under one key (catastrophic for GCM). The output is self-describing (`v2:` tag + nonce + ct + mac) so the dispatcher in 15c can round-trip it without external metadata. Null-on-failure contract preserved. The XOR `encrypt` body is **deleted** so no code path can ever produce new untagged v1 ciphertext again.
- Test: static build + log. Unit test: `decrypt(await encrypt('hunter2')) == 'hunter2'`; two `encrypt` calls on the same plaintext yield different blobs (distinct nonces); the result starts with `'v2:'`. Device test: with the v2-write flag enabled in a **staged** build, save a new password, force-stop, relaunch, confirm it reads back; pull the SQLite row via `adb` and confirm the stored value begins with `v2:`.
- WARNING / Data-safety: **gate this behind the rollout flag and do NOT enable it until Step 15c read-both has saturated production** — older installs without the dispatcher cannot read `v2:` blobs and would see data as corrupt. Write-back to SQLite must be single-writer compare-and-swap (`UPDATE ... WHERE id=? AND encrypted_value=<old>`); the `document_passwords` map must migrate **through** `PdfPasswordService._save()` (its in-memory map), never raw prefs. Honour `canOverwriteLegacy` — if the key-health gate is red, refuse to write.

---

### Step 19a - Salted Argon2id PIN hash with lazy rehash + constant-time compare
- File(s): `lib/features/settings/services/settings_service.dart` (VERIFY line numbers)
- Goal: stop storing the raw PIN. Hash it salted with Argon2id under a `'pin:v2:'` tag; on `verifyPin`, lazily rehash a legacy plaintext PIN **only after** the new hash verifies; compare in constant time.
- Locate (verbatim) — current `verifyPin` body (raw `==` compare against `'app_pin'`):
```dart
try {
  final storedPin = await _secureStorage.read(key: 'app_pin');
  final match = storedPin == pin;
  // NOTE: never log `pin` or `storedPin` (raw secrets). Log only the outcome.
  _log.info('SettingsService', 'PIN verification: ${match ? 'success' : 'failed'}');
  return match;
} catch (e) {
  _log.error('SettingsService', 'Failed to verify PIN', e);
  return false;
}
```
- Locate (verbatim) — current `setPin` body (writes raw PIN):
```dart
try {
  // NOTE: never log `pin` (raw secret). Log only the action.
  _log.info('SettingsService', 'Setting new PIN...');
  await _secureStorage.write(key: 'app_pin', value: pin);
  _hasPinSet = true;
  
  // Update auth method
  if (_authMethod == AuthMethod.fingerprintOnly) {
    await setAuthMethod(AuthMethod.both);
  } else if (_authMethod == AuthMethod.none) {
    await setAuthMethod(AuthMethod.pinOnly);
  }
  
  notifyListeners();
  _log.info('SettingsService', 'PIN set successfully');
  return true;
} catch (e) {
  _log.error('SettingsService', 'Failed to set PIN', e);
  return false;
}
```
- Change — add imports + helpers + the rewritten `verifyPin`/`setPin`. Storage key `'app_pin'` is reused; format is detected by the `'pin:v2:'` prefix:
```dart
// add to imports:
//   import 'package:cryptography/cryptography.dart';
//   import 'dart:convert';
//   import 'dart:typed_data';

static const String _pinV2Tag = 'pin:v2:'; // <tag>base64(salt16):base64(hash)

Future<String> _hashPin(String pin, List<int> salt) async {
  final algo = Argon2id(
    memory: 19 * 1024, // ~19 MiB
    parallelism: 1,
    iterations: 2,
    hashLength: 32,
  );
  final newKey = await algo.deriveKey(
    secretKey: SecretKey(utf8.encode(pin)),
    nonce: salt,
  );
  final bytes = await newKey.extractBytes();
  return '$_pinV2Tag${base64Encode(salt)}:${base64Encode(bytes)}';
}

// Constant-time byte compare — no early return on first mismatch.
bool _constTimeEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Future<bool> verifyPin(String pin) async {
  try {
    final stored = await _secureStorage.read(key: 'app_pin');
    if (stored == null) {
      _log.info('SettingsService', 'PIN verification: failed (none set)');
      return false;
    }

    bool match;
    if (stored.startsWith(_pinV2Tag)) {
      final body = stored.substring(_pinV2Tag.length);
      final sep = body.indexOf(':');
      final salt = base64Decode(body.substring(0, sep));
      final expected = base64Decode(body.substring(sep + 1));
      final candidate = await _hashPin(pin, salt);
      final candBytes =
          base64Decode(candidate.substring(candidate.lastIndexOf(':') + 1));
      match = _constTimeEq(candBytes, expected);
    } else {
      // legacy plaintext PIN
      match = _constTimeEq(utf8.encode(stored), utf8.encode(pin));
      if (match) {
        // LAZY REHASH: build new hash, VERIFY it, then overwrite.
        final salt = _randomSalt();
        final newHash = await _hashPin(pin, salt);
        if (await _verifyHashedBlob(newHash, pin)) {
          await _secureStorage.write(key: 'app_pin', value: newHash);
          _log.info('SettingsService', 'PIN rehashed to pin:v2');
        } else {
          _log.error('SettingsService', 'Rehash self-check failed; kept legacy');
        }
      }
    }
    _log.info('SettingsService', 'PIN verification: ${match ? 'success' : 'failed'}');
    return match;
  } catch (e) {
    _log.error('SettingsService', 'Failed to verify PIN', e);
    return false;
  }
}

List<int> _randomSalt() {
  final r = Random.secure();
  return List<int>.generate(16, (_) => r.nextInt(256));
}

// Re-derive from a freshly-built blob and confirm it matches the plaintext.
Future<bool> _verifyHashedBlob(String blob, String pin) async {
  final body = blob.substring(_pinV2Tag.length);
  final sep = body.indexOf(':');
  final salt = base64Decode(body.substring(0, sep));
  final expected = base64Decode(body.substring(sep + 1));
  final candidate = await _hashPin(pin, salt);
  final candBytes =
      base64Decode(candidate.substring(candidate.lastIndexOf(':') + 1));
  return _constTimeEq(candBytes, expected);
}

Future<bool> setPin(String pin) async {
  try {
    _log.info('SettingsService', 'Setting new PIN...');
    final hashed = await _hashPin(pin, _randomSalt());
    if (!await _verifyHashedBlob(hashed, pin)) {
      _log.error('SettingsService', 'New PIN hash self-check failed; aborting');
      return false; // verify-before-discard: never store an unverifiable hash
    }
    await _secureStorage.write(key: 'app_pin', value: hashed);
    _hasPinSet = true;

    if (_authMethod == AuthMethod.fingerprintOnly) {
      await setAuthMethod(AuthMethod.both);
    } else if (_authMethod == AuthMethod.none) {
      await setAuthMethod(AuthMethod.pinOnly);
    }

    notifyListeners();
    _log.info('SettingsService', 'PIN set successfully');
    return true;
  } catch (e) {
    _log.error('SettingsService', 'Failed to set PIN', e);
    return false;
  }
}
```
(Add `import 'dart:math';` if not already present for `Random.secure`.)
- Why / safeguards: Argon2id with a per-PIN random salt defeats rainbow tables and brute force on a 4–6 digit PIN far better than raw storage. The `'pin:v2:'` tag makes the format self-describing so legacy plaintext PINs keep working until the user next authenticates. **Lazy rehash** only fires after the legacy compare succeeds, and **verify-before-discard** re-derives and checks the new blob *before* it overwrites — so a KDF hiccup can never lock the user out. `_constTimeEq` removes the timing side-channel of `==`/early-return. If `cryptography`'s `Argon2id` is unavailable on a target platform, the senior reviewer may substitute PBKDF2-HMAC-SHA256 (≥210k iterations) from the already-pinned `crypto` package using the identical tag/salt layout.
- Test: static build + log. Unit test: `setPin('1234')` then `verifyPin('1234') == true`, `verifyPin('9999') == false`; stored blob starts with `'pin:v2:'`; seed a raw `'app_pin'='1234'` then `verifyPin('1234')` returns true **and** the stored value is upgraded to `pin:v2:` (assert prefix changed); `verifyPin('0000')` on a legacy value leaves it un-upgraded. Device: set a PIN, force-stop, relaunch, unlock; pull `app_pin` via `adb` (debug) and confirm it is the tagged hash, not the digits.
- WARNING / Data-safety: never log `pin` or the stored blob. The rehash write to `'app_pin'` must remain single-writer (this service owns it). Do **not** widen Argon2 memory beyond what low-end devices can afford at unlock time — 19 MiB is a deliberate ceiling; raising it risks ANR on cold unlock. If `_verifyHashedBlob` fails, keep the legacy value — losing a PIN hash locks the user out of their own vault.

---

### Step 19b - Replace the hardcoded `Portal123!` dev gate with a salted hash + constant-time compare
- File(s): `lib/services/encryption_service.dart` (VERIFY line numbers)
- Goal: remove the plaintext `_developerPassword = 'Portal123!'` and the two `==` compares; gate the developer features on a salted Argon2id hash compared in constant time.
- Locate (verbatim) — the constant and both compare sites:
```dart
static const String _developerPassword = 'Portal123!';
```
```dart
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
```
```dart
bool verifyDeveloperPassword(String password) {
  final valid = password == _developerPassword;
  _log.info('EncryptionService', 'Developer password verification: ${valid ? 'success' : 'failed'}');
  return valid;
}
```
- Change — delete the constant; add a compiled-in salted hash (NOT the plaintext) and a constant-time verifier. Generate `_devGateSalt`/`_devGateHash` once offline from the chosen dev password and paste the base64 here:
```dart
// Dev gate: salted Argon2id digest of the developer password, computed
// offline. The plaintext is NOT in the binary. To rotate, recompute both.
static const String _devGateSalt = 'BASE64_16_BYTE_SALT==';     // <-- fill in
static const String _devGateHash = 'BASE64_32_BYTE_ARGON2ID=='; // <-- fill in

Future<bool> verifyDeveloperPassword(String password) async {
  try {
    final salt = base64Decode(_devGateSalt);
    final algo = Argon2id(
      memory: 19 * 1024, parallelism: 1, iterations: 2, hashLength: 32,
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
    _log.info('EncryptionService',
        'Developer password verification: ${valid ? 'success' : 'failed'}');
    return valid;
  } catch (e) {
    _log.error('EncryptionService', 'Developer password verification error', e);
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
```
- Why / safeguards: `'Portal123!'` in source means anyone with the APK has the dev gate — storing only a salted Argon2id digest removes the plaintext from the binary while still letting the legitimate operator authenticate. Constant-time compare avoids leaking match length/position. Note `getEncryptionKey` now returns the **legacy** key only and feeds Step 19c, which must stop displaying it raw. `verifyDeveloperPassword` becomes `async` — update the one caller in `developer_screen.dart` (Step 19c) to `await` it.
- Test: static build + log. Unit test: the correct dev password → `verifyDeveloperPassword` true; any other → false; assert the string `Portal123!` no longer appears anywhere (`grep -r 'Portal123' lib/` returns nothing). Device: open the developer screen, enter the dev password, confirm the gate passes; enter a wrong one, confirm it is rejected and logged as "failed".
- WARNING / Data-safety: do **not** paste the plaintext dev password anywhere in the repo, tests, or CI logs — only the salt+hash. The dev gate must **never** be the thing protecting user data; it only unlocks diagnostics. Removing the constant will break any other file referencing `_developerPassword` — `grep` for it before building.

---

### Step 19c - Stop displaying the raw key in developer screen `_manageEncryptionKey`
- File(s): `lib/features/developer/screens/developer_screen.dart` (VERIFY line numbers)
- Goal: the developer screen must not render the encryption key in a `SelectableText`; show only a non-reversible fingerprint and `await` the now-async dev gate.
- Locate (verbatim) — the reveal path (note the inline `'Portal123!'` and the `SelectableText(key, ...)`):
```dart
  if (isSet) {
    // View Key
    final key = await _encryptionService.getEncryptionKey('Portal123!'); // Developer password verified
    if (key != null && mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.key, color: Colors.amber),
              SizedBox(width: 8),
              Text('Encryption Key'),
            ],
          ),
          content: SelectableText(
            key,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  } else {
```
- Change — show a sha256 fingerprint and a presence/health line, never the key bytes. (Add `import 'package:crypto/crypto.dart' as crypto;` and `import 'dart:convert';` to this file.)
```dart
  if (isSet) {
    // Status only — NEVER reveal the raw key in the UI.
    final present = await _encryptionService.isKeySet();
    final fingerprint = await _encryptionService.keyFingerprint(); // see below
    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.key, color: Colors.amber),
              SizedBox(width: 8),
              Text('Encryption Key'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(present ? 'Key present: yes' : 'Key present: no'),
              const SizedBox(height: 8),
              const Text('Fingerprint (sha256, first 8 bytes):',
                  style: TextStyle(fontSize: 12)),
              SelectableText(
                fingerprint ?? '(unavailable)',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  } else {
```
Add to `encryption_service.dart` a fingerprint helper (does not expose key bytes):
```dart
/// sha256 of the active v2 key, truncated to 8 bytes hex. Never the key itself.
Future<String?> keyFingerprint() async {
  final b64 = await _secureStorage.read(key: _aesKeyStorageKey);
  if (b64 == null || b64.isEmpty) return null;
  final digest = crypto.sha256.convert(base64Decode(b64)).bytes;
  return digest.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
```
- Why / safeguards: a screenshot, screen-share, or shoulder-surf of the old dialog leaked the entire encryption key. A truncated sha256 fingerprint lets a developer confirm "same key on two devices" or "key changed after restore" without ever exposing key material. The `getEncryptionKey('Portal123!')` call is removed entirely, killing the second plaintext occurrence of the dev password.
- Test: static build + log. Unit test on `keyFingerprint()`: returns null when no key, stable 16-hex-char string when present, and is **not** equal to the base64 key. Manual UI: open developer screen → Manage Encryption Key, confirm the dialog shows "Key present" + fingerprint and the raw key never appears. `grep -r 'Portal123' lib/` returns nothing after 19b+19c.
- WARNING / Data-safety: do not add a "reveal full key" affordance, even behind a long-press — there is no benign reason to render the key. The fingerprint must be sha256-truncated, not a prefix of the key bytes. Keep the "Set Key" else-branch (legacy) read-only-aware; do not let the dev screen mint a second `aes_key_v2`.

---

### Step 19d - Don't persist `zip_password` in plaintext in the export queue
- File(s): `lib/services/export_queue_service.dart` (VERIFY line numbers)
- Goal: stop writing the export ZIP password to disk in plaintext JSON; either never persist it (preferred) or encrypt it via the v2 AES path.
- Locate (verbatim) — the field and its (de)serialization:
```dart
final String? zipPassword;
```
```dart
'zip_password': zipPassword,
```
```dart
zipPassword: json['zip_password'],
```
- Change — **Option A (preferred): no-persist.** Keep `zipPassword` in memory for the live job, but omit it from JSON so a queued job on disk never contains it:
```dart
// field unchanged (in-memory only):
final String? zipPassword;

// toJson — DO NOT serialize the password:
// (remove the 'zip_password': zipPassword, line entirely)

// fromJson — never read a persisted password:
zipPassword: null, // never restored from disk; re-prompt if needed
```
- Change — **Option B (if the password MUST survive an app restart): encrypt at rest** via the v2 path. Make (de)serialization async (or pre-encrypt before enqueue):
```dart
// toJson(): store ciphertext, not plaintext.
'zip_password_enc': zipPassword == null
    ? null
    : await _encryptionService.encrypt(zipPassword!), // 'v2:'-tagged

// fromJson(): decrypt the tagged blob (read-both dispatcher handles it).
zipPassword: json['zip_password_enc'] == null
    ? null
    : await _encryptionService.decrypt(json['zip_password_enc'] as String),
```
- Why / safeguards: a ZIP password sitting in plaintext inside a queued-job JSON file defeats the point of encrypting the archive — anyone reading app storage gets it. Option A is the safest default: the password is the user's intent for one export and need not outlive the process; if the job is resumed after a restart, re-prompt. Option B reuses the Step 15c/d dispatcher so the value is `'v2:'` AES-GCM at rest and transparently read back. Choose A unless background/resumable exports are a hard requirement.
- Test: static build + log. Unit test: serialize a job with a password via `toJson`, assert the resulting map/JSON string does **not** contain the plaintext password (Option A: no key at all; Option B: only the `v2:` blob). Round-trip Option B: `fromJson(toJson(job))` recovers the password. Device: queue an export with a password, force-stop, inspect the persisted queue file via `adb` and confirm no plaintext password; resume and confirm the export still completes (Option A re-prompts; Option B auto-fills).
- WARNING / Data-safety: if you pick Option B, the queue file now depends on the v2 key — honour the key-health gate; a wiped Keystore makes `decrypt` return null, so the resume path must re-prompt rather than crash or export an unprotected ZIP. Never log `zipPassword`. If any other field (e.g. a `toString()` or debug dump) echoes the job, scrub the password there too. Migrating existing on-disk queues: on first read, drop any legacy plaintext `'zip_password'` key (do not re-serialize it).

---

**Cross-cutting checklist for the senior reviewer (apply once, after the cards):**
- `grep -rn "'encryption_key'"` — every remaining hit must be a **read** (no `.write` to that key outside the legacy path).
- `grep -rn 'Portal123'` — must be empty after 19b/19c.
- `grep -rn 'app_pin'` — only `settings_service.dart` may read/write it; value on disk must be `pin:v2:`-tagged after first unlock.
- Confirm `initCrypto()` is invoked exactly once from single-threaded startup and **before** the first `encrypt`/`decrypt`.
- Confirm no v2 **write** flag (Step 15d) is enabled in the build that ships read-both (Steps 15a–15c, 19a–19d).

**Files touched in Part 1A (all branch `experimental_flutter_upgrade`, absolute repo-relative):**
- `pubspec.yaml` (Step 15a)
- `lib/services/encryption_service.dart` (Steps 15a, 15b, 15c, 15d, 19b, 19c)
- `lib/features/settings/services/settings_service.dart` (Step 19a)
- `lib/features/developer/screens/developer_screen.dart` (Step 19c)
- `lib/services/export_queue_service.dart` (Step 19d)

---

## Part 1B - Passphrase Backup/Restore (Feature 5 / Task 16)

This card group adds a portable, Keystore-independent escape hatch BEFORE any v2 migration sweep touches stored data. The output is a single Argon2id-passphrase-wrapped JSON file that survives a wiped Android Keystore, device restore, or `allowBackup`-induced key loss. It is the recovery path the KEY-HEALTH GATE routes to when the legacy key is missing or wrong. Restore reuses the exact duplicate-detection patterns already in `add_password_dialog.dart` and shows a NO-SECRET conflict table.

Ship order reminder: read-both (Task 15) must saturate, then this Backup (Task 16) ships, then the sweep (Task 18). Do not reorder.

Anchors verified against branch `experimental_flutter_upgrade`. Note the key reality discovered in the code: the live `EncryptionService` is a **singleton XOR cipher** reading `flutter_secure_storage` key `'encryption_key'`, exposing `Future<String?> encrypt(...)` / `Future<String?> decrypt(...)` that return null on failure. `StorageService` is the SQLite singleton; passwords live in `AppConstants.passwordsTable` as `PasswordModel` rows (`id`, `key_name`, `encrypted_value`, `created_at`). The backup service exports DECRYPTED secrets re-wrapped under the user passphrase, never the legacy ciphertext (legacy ciphertext is worthless once the Keystore key is gone — which is the entire point of this feature).

---

### Step 16.1 - Add backup dependencies and confirm crypto stack
- File(s): `pubspec.yaml` (branch `experimental_flutter_upgrade`; line hints approximate, VERIFY before editing)
- Goal: pull in `cryptography` (Argon2id + AES-GCM), `file_picker` (Restore load), `share_plus` + `path_provider` + `path` (Backup save).
- Locate (verbatim from the branch): existing deps already present — `flutter_secure_storage`, `sqflite`, `path` are in use (confirmed by imports in `storage_service.dart`):
```dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
```
- Change: add to `pubspec.yaml` under `dependencies:` (pin to versions resolved by your lockfile; these are minimums):
```yaml
  cryptography: ^2.7.0      # Argon2id KDF + AES-GCM AEAD (pure Dart, no platform key needed)
  file_picker: ^8.1.2       # Restore: pick the .pwdbak file
  share_plus: ^10.1.2       # Backup: hand the file to the OS share sheet
  path_provider: ^2.1.4     # temp dir for the file we then share
  # path: already present (transitive of sqflite) — used for join()
```
- Why / safeguards: `cryptography` lets us mint nonces/keys via its own CSPRNG (satisfies "CSPRNG only" — no `Random()`), and runs Argon2id entirely in Dart so passphrase-wrapping does NOT depend on the Android Keystore (the whole reason this file survives a wiped key). `file_picker`/`share_plus` avoid us hand-rolling SAF.
- Test: static — `flutter pub get` then build per `.agent/rules/test.md` (`gradlew assembleDebug`, log the result). No device test for this step.
- WARNING / Data-safety: Do NOT add a dependency that bundles its own native keystore shim; the passphrase wrap MUST be platform-key-independent. Argon2id memory cost on low-RAM devices can OOM — keep `memory` modest (see Step 16.2).

---

### Step 16.2 - Create `password_backup_service.dart` (export half)
- File(s): NEW `lib/services/password_backup_service.dart` (branch `experimental_flutter_upgrade`)
- Goal: serialize every decrypted password row into an Argon2id-passphrase-wrapped AES-GCM JSON blob.
- Locate (verbatim from the branch): the existing read path and the existing decrypt contract this service consumes — `StorageService.getAllPasswords` and `EncryptionService.decrypt`:
```dart
  /// Get all passwords
  Future<List<PasswordModel>> getAllPasswords() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      AppConstants.passwordsTable,
      orderBy: 'created_at DESC',
    );
    return List.generate(maps.length, (i) => PasswordModel.fromMap(maps[i]));
  }
```
```dart
  /// Decrypt a value using the stored key
  Future<String?> decrypt(String encryptedText) async {
    try {
      if (_encryptionKey == null) {
        _encryptionKey = await _secureStorage.read(key: 'encryption_key');
      }

      if (_encryptionKey == null) {
        _log.error('EncryptionService', 'No encryption key set');
        return null;
      }
      ...
      return utf8.decode(plainBytes);
    } catch (e) {
      _log.error('EncryptionService', 'Decryption failed', e);
      return null;
    }
  }
```
- Change: NEW file. Header + types + the export method (`createBackup`). Note `PasswordEntry` carries the PLAINTEXT secret only in memory and inside the encrypted envelope — never logged, never in the conflict table.
```dart
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
  // Argon2id params: tune memory DOWN on low-RAM devices if you see OOM.
  static const int _kdfMemory = 32 * 1024;   // 32 MiB
  static const int _kdfIterations = 3;
  static const int _kdfParallelism = 1;
  static const int _saltLen = 16;            // bytes
  static const int _keyLen = 32;             // AES-256

  /// One backup record. `secret` is PLAINTEXT and lives only here + in the
  /// encrypted envelope. NEVER log it, NEVER surface it in the UI table.
  /// Returns null if the legacy decrypt failed for a row (skip, do not abort).
  Future<List<Map<String, String>>> _collectPlaintext() async {
    final rows = await _storage.getAllPasswords();
    final out = <Map<String, String>>[];
    for (final r in rows) {
      final secret = await _encryption.decrypt(r.encryptedValue);
      if (secret == null) {
        // decrypt() honours its null-on-failure contract; a null here means the
        // legacy key is wrong/missing for this row. Skip — do NOT write a bogus
        // backup entry. Count is reported to the caller for the summary.
        _log.error('PasswordBackupService',
            'Skipping "${r.keyName}" — decrypt returned null');
        continue;
      }
      out.add({'keyName': r.keyName, 'secret': secret});
    }
    return out;
  }

  /// Build the encrypted backup bytes. Throws if passphrase is empty or
  /// there are zero decryptable rows (caller shows a message).
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
    // cryptography's SecretKeyData mints bytes from a CSPRNG — no Random().
    final k = SecretKeyData.random(length: n);
    return Uint8List.fromList(k.bytes);
  }
}
```
- Why / safeguards: Export DECRYPTS via the existing null-on-failure `decrypt()` and SKIPS any row that returns null instead of force-unwrapping — a wrong/missing legacy key must never produce a poisoned backup. Salt + nonce + key all come from `cryptography`'s CSPRNG (no `Random()`). AES-GCM gives integrity so Restore can REJECT a wrong passphrase (the MAC fails) rather than silently importing garbage — exactly the property XOR lacks.
- Test: static (`gradlew assembleDebug`, logged). Unit test (feasible, pure Dart): `final bak = await svc.createBackup('pp'); final back = await svc.restoreFromBytes(bak, 'pp');` assert count round-trips; assert `restoreFromBytes(bak, 'wrong')` throws (MAC failure).
- WARNING / Data-safety: The in-memory `entries` list and the returned bytes contain PLAINTEXT secrets. Never pass them to `_log`. Hold them only for the duration of `createBackup` → share, then drop the reference. Argon2id at 32 MiB can OOM a 1 GB device — if QA reports OOM, lower `_kdfMemory` and bump `_kdfIterations` to compensate. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 16.3 - `password_backup_service.dart` (import/restore half + no-secret conflict model)
- File(s): `lib/services/password_backup_service.dart` (the NEW file from 16.2)
- Goal: decrypt the envelope, then for each backup entry compute a conflict status reusing the EXISTING dup patterns — key-name dup and value-duplicate scan — WITHOUT ever exposing the secret to the UI.
- Locate (verbatim from the branch): the two existing dup patterns from `add_password_dialog.dart` we are reusing — the key-name check delegates to `StorageService.passwordKeyExists`:
```dart
  Future<void> _validateKeyName() async {
    final keyName = _keyNameController.text.trim();
    if (keyName.isEmpty) {
      setState(() => _keyNameError = null);
      return;
    }

    final exists = await _storageService.passwordKeyExists(keyName);
    setState(() {
      _keyNameError = exists ? 'Key name already exists' : null;
    });
  }
```
```dart
    final allPasswords = await _storageService.getAllPasswords();
    for (final pwd in allPasswords) {
      final decrypted = await _encryptionService.decrypt(pwd.encryptedValue);
      if (decrypted == _passwordController.text) {
        // Password already exists - show popup
        ...
        return;
      }
    }
```
And the live `passwordKeyExists`:
```dart
  /// Check if a password key name exists
  Future<bool> passwordKeyExists(String keyName) async {
    final password = await getPasswordByKeyName(keyName);
    return password != null;
  }
```
- Change: append to `PasswordBackupService`. `RestoreConflict` is the row the table binds to — it carries `backupName`, `localName`, `status` and NEVER a secret.
```dart
enum ConflictStatus { fresh, sameNameSameSecret, sameNameDiffSecret, sameSecretDiffName }

enum ConflictResolution { skip, rename, keepBoth }

/// UI-facing conflict row. NO SECRET FIELD — by design.
class RestoreConflict {
  RestoreConflict({
    required this.backupName,
    required this.localName,
    required this.status,
    required Map<String, String> entry, // private payload, never exposed
  }) : _entry = entry,
       resolution = status == ConflictStatus.fresh
           ? ConflictResolution.keepBoth
           : ConflictResolution.skip;

  final String backupName;
  final String localName;       // matched local key, or '' if none
  final ConflictStatus status;
  ConflictResolution resolution; // mutated by the table (skip/rename/keep-both)
  String? renameTo;              // set when resolution == rename
  final Map<String, String> _entry; // {keyName, secret} — DO NOT surface

  String get backupSecret => _entry['secret']!; // import-time only
}

extension RestoreOps on PasswordBackupService {
  /// Decrypt + integrity-check the envelope, then classify each entry against
  /// the CURRENT local store using the existing dup patterns. Throws on bad
  /// passphrase (GCM MAC failure) or malformed file.
  Future<List<RestoreConflict>> restoreFromBytes(
      Uint8List bytes, String passphrase) async {
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
    final entries = (decoded['entries'] as List)
        .map((e) => (e as Map).map((k, v) => MapEntry('$k', '$v')))
        .toList();

    // Pre-load local state ONCE — mirrors add_password_dialog's two checks.
    final locals = await _storage.getAllPasswords();
    final localByName = {for (final p in locals) p.keyName: p};
    final localPlainByName = <String, String>{};
    for (final p in locals) {
      final d = await _encryption.decrypt(p.encryptedValue);
      if (d != null) localPlainByName[p.keyName] = d; // skip undecryptable
    }

    final conflicts = <RestoreConflict>[];
    for (final e in entries) {
      final bName = e['keyName'] ?? '';
      final bSecret = e['secret'] ?? '';
      ConflictStatus status;
      String localName = '';
      if (localByName.containsKey(bName)) {
        // key-name dup (reuses passwordKeyExists semantics)
        localName = bName;
        status = localPlainByName[bName] == bSecret
            ? ConflictStatus.sameNameSameSecret
            : ConflictStatus.sameNameDiffSecret;
      } else {
        // value-duplicate scan (reuses the getAllPasswords decrypt loop)
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
      conflicts.add(RestoreConflict(
        backupName: bName, localName: localName, status: status, entry: e));
    }
    return conflicts;
  }

  /// Apply resolved conflicts. Each insert goes THROUGH StorageService /
  /// EncryptionService — same write path as add_password_dialog, so v2 write
  /// rules and the single-writer invariant are honoured automatically.
  Future<int> applyRestore(List<RestoreConflict> conflicts) async {
    var imported = 0;
    for (final c in conflicts) {
      if (c.resolution == ConflictResolution.skip) continue;
      if (c.status == ConflictStatus.sameNameSameSecret) continue; // no-op
      var name = c.backupName;
      if (c.resolution == ConflictResolution.rename && c.renameTo != null) {
        name = c.renameTo!.trim();
      } else if (c.resolution == ConflictResolution.keepBoth &&
          c.status == ConflictStatus.sameNameDiffSecret) {
        name = await _uniquify(c.backupName);
      }
      final enc = await _encryption.encrypt(c.backupSecret);
      if (enc == null) continue; // never write a null ciphertext
      await _storage.insertPassword(PasswordModel(
        keyName: name, encryptedValue: enc, createdAt: DateTime.now()));
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
```
- Why / safeguards: GCM authentication makes a wrong passphrase fail loudly (`SecretBoxAuthenticationError`) — no silent garbage import. The conflict classifier reuses the two EXACT existing dup patterns (key-name via the `containsKey`/`passwordKeyExists` semantics, value via the `getAllPasswords` decrypt loop). Imports flow through `EncryptionService.encrypt` + `StorageService.insertPassword`, the SAME write path `add_password_dialog` uses — so when v2 writes land in Task 18, restore inherits them with zero changes (single-writer invariant preserved). `encrypt()` returning null is respected (row skipped, never a null ciphertext written).
- Test: static (`gradlew assembleDebug`, logged). Unit: round-trip + wrong-passphrase-throws + a row that collides on name-only resolves to `sameNameDiffSecret` and keep-both produces `name (2)`.
- WARNING / Data-safety: `RestoreConflict` deliberately has NO public secret accessor for the UI — `_entry` is private and `backupSecret` is consumed only inside `applyRestore`. Reviewer: confirm the secret never reaches a `Text(...)`, log, or `toString()`. The value-duplicate scan decrypts LOCAL rows; rows whose legacy decrypt returns null are excluded from matching (they can't be compared) — acceptable, they simply won't dedupe. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 16.4 - Add Backup + Restore buttons to the AppBar
- File(s): `lib/features/password_manager/screens/password_manager_screen.dart` (branch `experimental_flutter_upgrade`; the AppBar is currently a bare two-liner — VERIFY before editing)
- Goal: surface Backup and Restore as AppBar actions that drive the service.
- Locate (verbatim from the branch) — the entire current AppBar and the file's imports:
```dart
import 'package:flutter/material.dart';
import '../../../models/password_model.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';
import '../widgets/add_password_dialog.dart';
```
```dart
      appBar: AppBar(
        title: const Text('Password Manager'),
      ),
```
- Change: add imports and the two actions. Pass a passphrase-prompt dialog result into the service; show the conflict TABLE on restore (table widget defined in Step 16.5).
```dart
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../../../models/password_model.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/password_backup_service.dart';
import '../widgets/add_password_dialog.dart';
import '../widgets/restore_conflict_table.dart';
```
```dart
      appBar: AppBar(
        title: const Text('Password Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.backup_outlined),
            tooltip: 'Backup',
            onPressed: _onBackup,
          ),
          IconButton(
            icon: const Icon(Icons.restore_outlined),
            tooltip: 'Restore',
            onPressed: _onRestore,
          ),
        ],
      ),
```
And add the handlers to the State class (instantiate the service from the existing singletons the screen already holds):
```dart
  PasswordBackupService get _backup =>
      PasswordBackupService(_storageService, _encryptionService);

  Future<void> _onBackup() async {
    final pass = await _promptPassphrase(confirm: true);
    if (pass == null) return;
    try {
      final bytes = await _backup.createBackup(pass);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path,
          'passwords-${DateTime.now().millisecondsSinceEpoch}.pwdbak'));
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path)],
          subject: 'Password Manager backup');
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _onRestore() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.single.bytes == null) return;
    final pass = await _promptPassphrase(confirm: false);
    if (pass == null) return;
    try {
      final conflicts =
          await _backup.restoreFromBytes(picked.files.single.bytes!, pass);
      if (!mounted) return;
      final resolved = await Navigator.of(context).push<List<RestoreConflict>>(
        MaterialPageRoute(
          builder: (_) => RestoreConflictTable(conflicts: conflicts),
        ),
      );
      if (resolved == null) return;
      final n = await _backup.applyRestore(resolved);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Imported $n password(s)')));
        await _loadPasswords(); // existing refresh method on this screen
      }
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }
```
- Why / safeguards: Reuses the screen's existing `_storageService` / `_encryptionService` singletons (confirmed imported) rather than spawning new ones — keeps the single-writer guarantee. Backup writes to the OS temp dir then hands the file to `Share` (no broad storage write). Restore loads bytes in-memory via `file_picker` (`withData: true`) so no path/permission juggling. The passphrase prompt for backup uses `confirm: true` (typed twice) to prevent an un-restorable typo. VERIFY the real refresh method name (`_loadPasswords`) against the file before wiring.
- Test: static (`gradlew assembleDebug`, logged). Device (adb): tap Backup → enter passphrase twice → confirm the OS share sheet appears; `adb shell` the shared file is `.pwdbak`. Tap Restore → pick that file → wrong passphrase shows "Wrong passphrase or corrupted backup"; correct passphrase shows the conflict table.
- WARNING / Data-safety: The `.pwdbak` written to temp is the ENCRYPTED envelope (safe at rest), but still delete-on-exit is good hygiene — schedule a temp cleanup. Never write the plaintext or the passphrase to disk or log. `_promptPassphrase` must use `obscureText: true` and must not persist the entered value anywhere. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 16.5 - Restore conflict TABLE widget (no-secret, skip/rename/keep-both)
- File(s): NEW `lib/features/password_manager/widgets/restore_conflict_table.dart`
- Goal: render the conflict list as a `DataTable` with columns `backupName`, `localName`, `status` and a per-row resolution control — and POP back the mutated list. No column, tooltip, or cell ever renders a secret.
- Locate (verbatim from the branch): pattern reuse only — the existing dup UI copy from `add_password_dialog.dart` we keep consistent with:
```dart
        content: Text(
          'This password already exists under the key name:\n\n"${pwd.keyName}"',
          style: const TextStyle(fontSize: 16),
        ),
```
- Change: NEW widget.
```dart
import 'package:flutter/material.dart';
import '../../../services/password_backup_service.dart';

class RestoreConflictTable extends StatefulWidget {
  const RestoreConflictTable({super.key, required this.conflicts});
  final List<RestoreConflict> conflicts;

  @override
  State<RestoreConflictTable> createState() => _RestoreConflictTableState();
}

class _RestoreConflictTableState extends State<RestoreConflictTable> {
  String _statusLabel(ConflictStatus s) {
    switch (s) {
      case ConflictStatus.fresh:
        return 'New';
      case ConflictStatus.sameNameSameSecret:
        return 'Identical (no-op)';
      case ConflictStatus.sameNameDiffSecret:
        return 'Name clash';
      case ConflictStatus.sameSecretDiffName:
        return 'Same value, other name';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Restore'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, widget.conflicts),
            child: const Text('IMPORT',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Backup name')),
              DataColumn(label: Text('Local name')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Action')),
            ],
            rows: widget.conflicts.map((c) {
              return DataRow(cells: [
                DataCell(Text(c.backupName)),
                DataCell(Text(c.localName.isEmpty ? '—' : c.localName)),
                DataCell(Text(_statusLabel(c.status))),
                DataCell(
                  c.status == ConflictStatus.sameNameSameSecret
                      ? const Text('Skipped')
                      : DropdownButton<ConflictResolution>(
                          value: c.resolution,
                          items: const [
                            DropdownMenuItem(
                                value: ConflictResolution.skip,
                                child: Text('Skip')),
                            DropdownMenuItem(
                                value: ConflictResolution.keepBoth,
                                child: Text('Keep both')),
                            DropdownMenuItem(
                                value: ConflictResolution.rename,
                                child: Text('Rename')),
                          ],
                          onChanged: (v) async {
                            if (v == ConflictResolution.rename) {
                              final name = await _promptRename(c.backupName);
                              if (name == null) return;
                              c.renameTo = name;
                            }
                            setState(() => c.resolution = v!);
                          },
                        ),
                ),
              ]);
            }).toList(),
          ),
        ),
      ),
    );
  }

  Future<String?> _promptRename(String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename on import'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'New key name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }
}
```
- Why / safeguards: The table binds ONLY to `backupName`, `localName`, `status` — there is no `RestoreConflict` accessor for the secret reachable from here, so a future edit can't accidentally render it. `sameNameSameSecret` rows are forced to "Skipped" (no point importing an identical entry). Returning the same (mutated) list keeps resolution state in the model objects `applyRestore` reads.
- Test: static (`gradlew assembleDebug`, logged). Device (adb): with a crafted backup containing one fresh, one name-clash, one same-value entry, confirm three rows render with the right status labels and NO password text anywhere; choose Rename → verify the renamed key appears post-import.
- WARNING / Data-safety: Reviewer must grep this file for any reference to `secret`/`backupSecret`/`_entry` — there should be NONE. The rename dialog pre-fills with the KEY NAME only. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 16.6 - Exclude encrypted prefs + DB from Android Auto Backup
- File(s): `android/app/src/main/AndroidManifest.xml` (branch `experimental_flutter_upgrade`); NEW `android/app/src/main/res/xml/data_extraction_rules.xml`; NEW `android/app/src/main/res/xml/backup_rules.xml`
- Goal: stop Android Auto Backup / device-transfer from copying the EncryptedSharedPreferences and SQLite DB to the cloud — that copy carries ciphertext whose Keystore key does NOT travel, producing exactly the "valid-looking garbage" decrypt the audit warns about. The passphrase backup is the sanctioned portable path instead.
- Locate (verbatim from the branch) — the current `<application>` tag has NO backup attributes:
```xml
<application
    android:label="PDF Manager"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:largeHeap="true">
    <meta-data
        android:name="io.flutter.embedding.android.NormalTheme"
        android:resource="@style/NormalTheme"
        />
```
- Change: add both backup attributes to `<application>`:
```xml
<application
    android:label="PDF Manager"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:largeHeap="true"
    android:fullBackupContent="@xml/backup_rules"
    android:dataExtractionRules="@xml/data_extraction_rules">
    <meta-data
        android:name="io.flutter.embedding.android.NormalTheme"
        android:resource="@style/NormalTheme"
        />
```
NEW `res/xml/data_extraction_rules.xml` (Android 12+, API 31+ — covers both `cloud-backup` and device-to-device `device-transfer`):
```xml
<?xml version="1.0" encoding="utf-8"?>
<data-extraction-rules>
    <cloud-backup>
        <!-- flutter_secure_storage EncryptedSharedPreferences -->
        <exclude domain="sharedpref"
            path="FlutterSecureStorage.xml" />
        <!-- SQLite DB holding encrypted_value rows -->
        <exclude domain="database" />
        <exclude domain="file" path="databases/" />
    </cloud-backup>
    <device-transfer>
        <exclude domain="sharedpref"
            path="FlutterSecureStorage.xml" />
        <exclude domain="database" />
        <exclude domain="file" path="databases/" />
    </device-transfer>
</data-extraction-rules>
```
NEW `res/xml/backup_rules.xml` (legacy Auto Backup, API 23–30 — `fullBackupContent`):
```xml
<?xml version="1.0" encoding="utf-8"?>
<full-backup-content>
    <exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
    <exclude domain="database" path="." />
    <exclude domain="file" path="databases/" />
</full-backup-content>
```
- Why / safeguards: This is a load-bearing data-safety fix. If Auto Backup copies the encrypted prefs/DB but the Keystore-held key stays behind on a restore, the legacy XOR ciphertext decrypts to garbage that LOOKS valid (XOR has no integrity) — the precise failure the KEY-HEALTH GATE is built to catch. Excluding these from backup means a restored install has NO local secrets and the user is cleanly routed to passphrase Restore (Task 16). VERIFY the exact secure-prefs filename on this device build (it can be `FlutterSecureStorage` without the `.xml`, or a custom name) — `adb shell run-as <pkg> ls shared_prefs` before trusting the path. The DB filename should match `AppConstants.passwordsTable`'s database file; widen the `database` exclude to a specific `path="<dbname>"` once confirmed.
- Test: static (`gradlew assembleDebug`, logged). Device (adb): `adb shell bmgr backupnow <pkg>` then `adb shell run-as <pkg> ls shared_prefs databases` to confirm files exist locally but are excluded; inspect `adb logcat | grep BackupManagerService` to see the excludes honored. Best end-to-end: back up, uninstall, reinstall, restore via `bmgr restore` — confirm NO passwords appear (forcing the passphrase-restore path).
- WARNING / Data-safety: Ship this BEFORE the v2 write sweep (Task 18). If the sweep writes v2 ciphertext while Auto Backup is still copying the DB, a cloud restore onto a fresh Keystore yields undecryptable v2 rows AND no recovery path — the user is locked out. The passphrase backup file is the ONLY supported cross-device path; make that explicit in user-facing copy. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

Files referenced/created by this section (all absolute paths are repo-relative on branch `experimental_flutter_upgrade`):
- NEW `lib/services/password_backup_service.dart` (Steps 16.2, 16.3)
- NEW `lib/features/password_manager/widgets/restore_conflict_table.dart` (Step 16.5)
- EDIT `lib/features/password_manager/screens/password_manager_screen.dart` (Step 16.4)
- EDIT `android/app/src/main/AndroidManifest.xml` (Step 16.6)
- NEW `android/app/src/main/res/xml/data_extraction_rules.xml` and `android/app/src/main/res/xml/backup_rules.xml` (Step 16.6)
- EDIT `pubspec.yaml` (Step 16.1)
- Consumes (READ-ONLY, verbatim-anchored): `lib/services/storage_service.dart` (`getAllPasswords`, `insertPassword`, `passwordKeyExists`), `lib/services/encryption_service.dart` (`encrypt`/`decrypt`, null-on-failure XOR), `lib/models/password_model.dart` (`PasswordModel`), `lib/features/password_manager/widgets/add_password_dialog.dart` (dup patterns)

---

## Part 1C - Migration: lazy migrate-on-read + one-time sweep (Tasks 17 and 18)

This part assumes Parts 1A/1B have already landed: `EncryptionService` exposes the v2 primitives (`encrypt`/`decrypt` namespaced `v2:`, null-on-failure), the legacy XOR path is preserved as `xorEncryptLegacy`/`stripTag` plus a read-both path (Task 15), the key-health token (`sha256(legacy key)`) and the Keystore-backed `aes_key_v2` exist, and passphrase Backup/Restore (Task 16) has shipped. **Rollout gate (do not violate): read-both (15) must be saturated in production before any v2 WRITE here; passphrase Backup (16) must ship before the sweep (18).**

The two stores being migrated are intentionally different and must be migrated through different write paths:
- **`passwords` table** (SQLite, `AppConstants.passwordsTable`): rows of `id / key_name / encrypted_value / created_at`. Migrate via `getAllPasswords()` + `updatePassword()` using a **compare-and-swap WHERE clause**.
- **`document_passwords` map** (SharedPreferences JSON, owned by `PdfPasswordService._documentPasswords`): migrate **THROUGH the in-memory map + `_save()`**, never by touching prefs directly, so the single in-memory writer stays authoritative.

---

### Step 17 - Lazy migrate-on-read at the SmartOpen brute-force loop (passwords table, CAS)
- File(s): `lib/features/documents/screens/document_dashboard_screen.dart` (branch `experimental_flutter_upgrade`; `_openDocument` starts ~line 1850, brute-force loop ~line 1900; VERIFY before editing)
- Goal: When a stored `passwords`-table value decrypts and is proven correct on the legacy side, re-encrypt it to `v2:` and write back via compare-and-swap — but only after the file actually verifies the decrypted password.
- Locate (verbatim from the branch):
```dart
      // 3. Try saved passwords [BRUTE-FORCE LOOP STARTS HERE]
      _log.debug('SmartOpen', 'Fetching saved passwords');
      final storage = StorageService();
      final passwords = await storage.getAllPasswords();
      final encryption = context.read<EncryptionService>();
      
      _log.debug('SmartOpen', 'Found ${passwords.length} saved passwords');
      
      String? foundPassword;
      String? foundKeyName;
      
      for (final p in passwords) {
        final decrypted = await encryption.decrypt(p.encryptedValue);
        if (decrypted != null) {
          _log.debug('SmartOpen', 'Trying password: ${p.keyName}');
          if (await tools.verifyPassword(filePath, decrypted)) {
            _log.debug('SmartOpen', 'Password matched!');
            foundPassword = decrypted;
            foundKeyName = p.keyName;
            break;
          }
        }
      }
```
- Change:
```dart
      // 3. Try saved passwords [BRUTE-FORCE LOOP STARTS HERE]
      _log.debug('SmartOpen', 'Fetching saved passwords');
      final storage = StorageService();
      final passwords = await storage.getAllPasswords();
      final encryption = context.read<EncryptionService>();
      
      _log.debug('SmartOpen', 'Found ${passwords.length} saved passwords');
      
      String? foundPassword;
      String? foundKeyName;
      
      for (final p in passwords) {
        final decrypted = await encryption.decrypt(p.encryptedValue);
        if (decrypted != null) {
          _log.debug('SmartOpen', 'Trying password: ${p.keyName}');
          if (await tools.verifyPassword(filePath, decrypted)) {
            _log.debug('SmartOpen', 'Password matched!');
            foundPassword = decrypted;
            foundKeyName = p.keyName;

            // Lazy migrate-on-read: re-encrypt this row to v2 ONLY if
            // (a) it is still a legacy ciphertext (not already 'v2:'),
            // (b) the key-health gate is green, and
            // (c) the LEGACY-side round-trip proves the decrypt was correct.
            // AES round-tripping its own output proves nothing here.
            if (encryption.isLegacyCiphertext(p.encryptedValue) &&
                await encryption.isLegacyKeyHealthy() &&
                encryption.proveLegacyRoundTrip(decrypted, p.encryptedValue)) {
              final reencrypted = await encryption.encrypt(decrypted); // 'v2:' tagged
              if (reencrypted != null) {
                // Compare-and-swap: only overwrite if the row still holds the
                // exact legacy bytes we read. Loses the race safely (rows == 0).
                final rows = await storage.updatePasswordValueCas(
                  p.id,
                  p.encryptedValue, // expected old
                  reencrypted,      // new v2 value
                );
                _log.info('SmartOpen',
                    'Lazy-migrated password ${p.keyName} to v2 (cas rows=$rows)');
              }
            }
            break;
          }
        }
      }
```
- Why / safeguards: The decrypted value is only trusted after `tools.verifyPassword(filePath, decrypted)` succeeds against the real PDF — that is the strongest possible proof. We additionally require `proveLegacyRoundTrip` (which internally does `xorEncryptLegacy(decrypt(stored)) == stripTag(stored)` with `utf8.decode(allowMalformed:false)`) so we never overwrite based on XOR garbage. `isLegacyKeyHealthy()` blocks all writes when the legacy key is missing/wrong. The CAS `updatePasswordValueCas` makes the write a no-op if any other code path migrated the same row first.
- Test:
  - static: build per `.agent/rules/test.md` — `gradlew assembleDebug` (log the run); add the new `StorageService.updatePasswordValueCas` (Step 17b) before this compiles.
  - unit: feed a `PasswordModel` whose `encryptedValue` is a known legacy XOR ciphertext; assert that after a verified open the row's `encrypted_value` starts with `v2:` and that a second open is a CAS no-op (rows == 0).
  - device: `adb` install; open a PDF whose password is stored as legacy; confirm `adb logcat | findstr "Lazy-migrated password"` shows `cas rows=1` once, then `rows=0` on the next open of the same key.
- WARNING / Data-safety: Do NOT move the migration before `verifyPassword` — a non-matching-but-decryptable row must never be rewritten. `encryption.decrypt`/`encrypt` keep their null-on-failure contract; never force-unwrap. If `isLegacyKeyHealthy()` is false, skip migration entirely and let the read-both path still serve the open — route the user to passphrase-restore elsewhere, never let a bad key drive a write. CSPRNG nonces only (the `cryptography` package mints them). Tag stays `v2:`.

---

### Step 17b - Add `updatePasswordValueCas` (single-writer compare-and-swap) to StorageService
- File(s): `lib/services/storage_service.dart` (branch `experimental_flutter_upgrade`; near `updatePassword`; VERIFY before editing)
- Goal: Provide an `UPDATE ... WHERE id=? AND encrypted_value=<old>` so every v2 write-back is conditional on the row being unchanged.
- Locate (verbatim from the branch):
```dart
Future<int> updatePassword(PasswordModel password) async {
  final db = await database;
  return await db.update(
    AppConstants.passwordsTable,
    password.toMap(),
    where: 'id = ?',
    whereArgs: [password.id],
  );
}
```
- Change (add this method alongside the existing one; do not modify `updatePassword`):
```dart
Future<int> updatePassword(PasswordModel password) async {
  final db = await database;
  return await db.update(
    AppConstants.passwordsTable,
    password.toMap(),
    where: 'id = ?',
    whereArgs: [password.id],
  );
}

/// Compare-and-swap write of a single password row's ciphertext.
/// Returns rows affected: 1 = swapped, 0 = lost the race / already migrated.
/// Single-writer invariant for migration: never blind-overwrites.
Future<int> updatePasswordValueCas(
  int id,
  String expectedOldValue,
  String newValue,
) async {
  final db = await database;
  return await db.update(
    AppConstants.passwordsTable,
    {'encrypted_value': newValue},
    where: 'id = ? AND encrypted_value = ?',
    whereArgs: [id, expectedOldValue],
  );
}
```
- Why / safeguards: Only `encrypted_value` is updated; `key_name`, `created_at`, and the autoincrement `id` are untouched. The `AND encrypted_value = ?` predicate is the CAS guard — concurrent migration (lazy + sweep) on the same row resolves to exactly one winner.
- Test:
  - static: `gradlew assembleDebug` (logged).
  - unit: insert a row, call `updatePasswordValueCas(id, correctOld, newV2)` → expect 1; call again with the same `correctOld` → expect 0 (value already changed); confirm `key_name`/`created_at` unchanged.
  - device: covered transitively by Step 17 and Step 18 device tests.
- WARNING / Data-safety: This is the ONLY sanctioned write path for migrating table rows. Never reintroduce a blind `updatePassword` for migration. The `key_name` column is `UNIQUE` — do not write it here.

---

### Step 17c - Lazy migrate-on-read for the document_passwords map (through PdfPasswordService)
- File(s): `lib/services/pdf_password_service.dart` (branch `experimental_flutter_upgrade`; `getPasswordForDocument` region; VERIFY before editing)
- Goal: When a stored per-document password decrypts and is proven on the legacy side, re-encrypt it to v2 and persist through the in-memory map + `_save()` — never raw prefs.
- Locate (verbatim from the branch):
```dart
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
```
- Change:
```dart
  if (encryptedPassword == null || encryptedPassword.isEmpty) {
    return null;
  }
  
  // Empty string means no password needed
  if (encryptedPassword == 'NO_PASSWORD') {
    return '';
  }
  
  // Decrypt the stored password
  final decrypted = await _encryptionService.decrypt(encryptedPassword);
  if (decrypted == null) {
    // null-on-failure contract: serve nothing, do NOT migrate on a failed decrypt.
    return null;
  }

  // Lazy migrate-on-read: only when the value is still legacy, the key is
  // healthy, and the LEGACY-side round-trip proves correctness.
  if (_encryptionService.isLegacyCiphertext(encryptedPassword) &&
      await _encryptionService.isLegacyKeyHealthy() &&
      _encryptionService.proveLegacyRoundTrip(decrypted, encryptedPassword)) {
    final reencrypted = await _encryptionService.encrypt(decrypted); // 'v2:'
    if (reencrypted != null) {
      // Migrate THROUGH the in-memory map of this single writer, then _save().
      // Guard against a concurrent change to the same key (compare-and-swap
      // against the in-memory value we read).
      if (_documentPasswords[filePath] == encryptedPassword) {
        _documentPasswords[filePath] = reencrypted;
        await _save();
        _log.info('PdfPasswordService',
            'Lazy-migrated document password to v2 for: $filePath');
      }
    }
  }

  return decrypted;
}
```
- Why / safeguards: The map is owned exclusively by `PdfPasswordService`; routing the write through `_documentPasswords[...] = ...` + `_save()` keeps the JSON blob consistent and preserves the existing filename-alias entries. The in-memory `==` check is the map's CAS equivalent. `proveLegacyRoundTrip` guarantees we never overwrite XOR garbage. The `NO_PASSWORD` sentinel and `decrypt == null` cases short-circuit before any write.
- Test:
  - static: `gradlew assembleDebug` (logged).
  - unit: seed `_documentPasswords[path]` with a legacy ciphertext; call `getPasswordForDocument(path)`; assert the returned plaintext is correct AND `_documentPasswords[path]` now starts with `v2:`; second call leaves it unchanged.
  - device: open a previously-saved document via its stored association; `adb logcat | findstr "Lazy-migrated document password"` shows exactly one line; reopen shows none.
- WARNING / Data-safety: NEVER write the migrated value via `SharedPreferences` directly — always `_documentPasswords[...] = ...; await _save();`. Do not migrate when `decrypt` returned null or when the key-health gate is red. Keep `'NO_PASSWORD'` as-is (it is a sentinel, not ciphertext). Tag `v2:`.

---

### Step 18 - Stop `initialize()` from zeroing the map on parse error
- File(s): `lib/services/pdf_password_service.dart` (branch `experimental_flutter_upgrade`; `initialize()` region; VERIFY before editing)
- Goal: A transient JSON parse failure must not silently destroy the user's saved per-document passwords (which would later get re-saved as an empty map by `_save()`).
- Locate (verbatim from the branch):
```dart
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
```
- Change:
```dart
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_documentsPasswordsKey);
    if (stored != null) {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      _documentPasswords = decoded.map((k, v) => MapEntry(k, v.toString()));
    }
    _isInitialized = true;
  } catch (e, stack) {
    // DO NOT zero the map: an empty map would be persisted by the next _save()
    // and permanently destroy saved associations. Leave whatever we had,
    // mark the load as failed, and block writes until a clean load succeeds.
    _documentPasswordsLoadFailed = true;
    _isInitialized = true;
    _log.error('PdfPasswordService',
        'Failed to load document_passwords; preserving in-memory state, '
        'blocking saves until next clean load', e, stack);
  }
}
```
- Additional required change — add the field and gate `_save()`:
```dart
  Map<String, String> _documentPasswords = {};
  bool _documentPasswordsLoadFailed = false;
```
```dart
/// Save document password mappings
Future<void> _save() async {
  // Refuse to persist over a store we failed to read: prevents an empty/partial
  // map from clobbering good on-disk data after a transient parse error.
  if (_documentPasswordsLoadFailed) {
    _log.error('PdfPasswordService',
        'Skipping _save(): document_passwords load previously failed');
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_documentsPasswordsKey, jsonEncode(_documentPasswords));
}
```
- Why / safeguards: The original catch sets `_documentPasswords = {}`, and the very next `_save()` (e.g. from the filename-alias migration in `getPasswordForDocument`, or from `saveDocumentPassword`) would overwrite the prefs key with `{}` — irreversible data loss from a recoverable error. Preserving in-memory state plus a `_save()` guard turns a transient failure into a no-op instead of a wipe.
- Test:
  - static: `gradlew assembleDebug` (logged).
  - unit: write malformed JSON to the `_documentsPasswordsKey` pref, call `initialize()`, then call `saveDocumentPassword(...)`; assert the on-disk pref is NOT replaced with `{}` (i.e. `_save()` was skipped).
  - device: corrupt the pref via a debug build, relaunch, confirm `adb logcat` shows "preserving in-memory state" and the original JSON survives in `adb shell run-as <pkg> cat shared_prefs/*.xml`.
- WARNING / Data-safety: This guard intentionally blocks ALL saves after a failed load until a clean `initialize()` succeeds — surface this to the user (or retry load) so they are not silently unable to save new associations. Never replace a populated store with `{}` on a caught exception.

---

### Step 18b - NEW `lib/services/migration_service.dart`: one-time, idempotent, resumable, key-health-gated sweep
- File(s): NEW `lib/services/migration_service.dart` (branch `experimental_flutter_upgrade`)
- Goal: A background sweep that migrates ALL remaining legacy ciphertexts in BOTH stores to v2, exactly once, safely resumable across crashes, gated on key health, with a completion flag set only when both stores are fully drained.
- Locate (verbatim): n/a — new file.
- Change:
```dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'encryption_service.dart';
import 'storage_service.dart';
import 'pdf_password_service.dart';
import 'logging_service.dart';

/// One-time, idempotent, resumable, key-health-gated migration of every
/// legacy (XOR/v1) ciphertext to v2. Runs AFTER read-both (Task 15) is
/// saturated and AFTER passphrase Backup (Task 16) has shipped.
class MigrationService {
  static const String _doneKey = 'migration_v2_complete';
  static const String _doneKeyTmp = 'migration_v2_complete__tmp';

  final EncryptionService _enc;
  final StorageService _storage;
  final PdfPasswordService _pdfPasswords;
  final LoggingService _log = LoggingService();

  MigrationService(this._enc, this._storage, this._pdfPasswords);

  /// Safe to call on every cold start. Returns immediately if already done,
  /// if the key is unhealthy, or if a sweep is already running.
  Future<void> runIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return;

    // KEY-HEALTH GATE: never let a bad/missing legacy key drive writes.
    if (!await _enc.isLegacyKeyHealthy()) {
      _log.error('Migration',
          'Legacy key unhealthy; migration DISABLED, route to passphrase-restore');
      return;
    }

    bool tableDrained = false;
    bool mapDrained = false;
    try {
      tableDrained = await _sweepPasswordsTable();
      mapDrained = await _sweepDocumentPasswords();
    } catch (e, stack) {
      _log.error('Migration', 'Sweep aborted; will resume next launch', e, stack);
      return; // resumable: no completion flag written
    }

    // Completion flag ONLY when BOTH stores fully drained of legacy values.
    if (tableDrained && mapDrained) {
      await _writeCompletionFlagAtomic(prefs);
      _log.info('Migration', 'v2 migration complete (both stores drained)');
    }
  }

  /// Returns true iff no legacy ciphertext remains in the passwords table.
  Future<bool> _sweepPasswordsTable() async {
    final rows = await _storage.getAllPasswords();
    bool allV2 = true;
    for (final p in rows) {
      if (!_enc.isLegacyCiphertext(p.encryptedValue)) continue;
      final decrypted = await _enc.decrypt(p.encryptedValue);
      if (decrypted == null ||
          !_enc.proveLegacyRoundTrip(decrypted, p.encryptedValue)) {
        // Cannot prove correctness: skip, leave legacy in place, NOT drained.
        allV2 = false;
        continue;
      }
      final reencrypted = await _enc.encrypt(decrypted);
      if (reencrypted == null) {
        allV2 = false;
        continue;
      }
      final n = await _storage.updatePasswordValueCas(
          p.id, p.encryptedValue, reencrypted); // CAS write-back
      if (n == 0) allV2 = false; // raced; recheck next pass
    }
    return allV2;
  }

  /// Returns true iff no legacy ciphertext remains in document_passwords.
  /// Migrates THROUGH PdfPasswordService's in-memory map + _save().
  Future<bool> _sweepDocumentPasswords() async {
    await _pdfPasswords.initialize();
    // Delegate to the service so the single in-memory writer stays authoritative.
    return await _pdfPasswords.migrateAllToV2(
      isLegacy: _enc.isLegacyCiphertext,
      keyHealthy: _enc.isLegacyKeyHealthy,
      decrypt: _enc.decrypt,
      proveLegacy: _enc.proveLegacyRoundTrip,
      encrypt: _enc.encrypt,
    );
  }

  /// Crash-safe prefs write: temp key first, then atomic swap to the real key.
  Future<void> _writeCompletionFlagAtomic(SharedPreferences prefs) async {
    await prefs.setBool(_doneKeyTmp, true); // durable temp marker
    await prefs.setBool(_doneKey, true);    // promote
    await prefs.remove(_doneKeyTmp);        // cleanup
  }
}
```
- Companion method to add in `pdf_password_service.dart` (keeps the map's single writer):
```dart
/// Sweep the in-memory document_passwords map, migrating legacy values to v2
/// THROUGH this service's own map + _save(). Returns true iff fully drained.
Future<bool> migrateAllToV2({
  required bool Function(String) isLegacy,
  required Future<bool> Function() keyHealthy,
  required Future<String?> Function(String) decrypt,
  required bool Function(String, String) proveLegacy,
  required Future<String?> Function(String) encrypt,
}) async {
  await initialize();
  if (_documentPasswordsLoadFailed) return false; // never write over a bad load
  if (!await keyHealthy()) return false;
  bool allV2 = true;
  // Snapshot keys: we mutate the map while iterating.
  for (final key in _documentPasswords.keys.toList()) {
    final value = _documentPasswords[key];
    if (value == null || value.isEmpty || value == 'NO_PASSWORD') continue;
    if (!isLegacy(value)) continue;
    final dec = await decrypt(value);
    if (dec == null || !proveLegacy(dec, value)) { allV2 = false; continue; }
    final enc = await encrypt(dec);
    if (enc == null) { allV2 = false; continue; }
    if (_documentPasswords[key] == value) { // in-memory CAS
      _documentPasswords[key] = enc;
    } else {
      allV2 = false; // changed under us; recheck next pass
    }
  }
  await _save();
  return allV2;
}
```
- Why / safeguards: Idempotent (completion flag short-circuits), resumable (no flag written unless a pass fully drains, and any throw returns early leaving partial-but-valid progress), key-health-gated (refuses to run on a bad key), single-writer (table via CAS, map via the service). The completion flag uses a temp-key-then-promote-then-cleanup so a crash mid-write can never leave a half-true flag that strands legacy values. Every overwrite is preceded by `proveLegacyRoundTrip`, so XOR garbage is never written. Rows/keys that cannot be proven are skipped and keep `allV2 = false`, so the sweep correctly does NOT mark itself complete and retries next launch.
- Test:
  - static: `gradlew assembleDebug` (logged).
  - unit: seed both stores with a mix of legacy + already-v2 + unprovable values; run `runIfNeeded()`; assert provable legacy values became `v2:`, unprovable ones untouched, completion flag NOT set (because not drained); then remove the unprovable rows and re-run → flag set. Separately: kill between `_doneKeyTmp` and `_doneKey` (simulate) and assert next run re-derives correctly.
  - unit: with `isLegacyKeyHealthy()` stubbed false, assert zero writes to either store and no flag.
  - device: install over a v1 dataset, launch, `adb logcat | findstr Migration`; confirm "v2 migration complete" appears once; relaunch confirms `runIfNeeded()` returns early (flag set); inspect `shared_prefs` to confirm `migration_v2_complete=true` and no `__tmp` residue.
- WARNING / Data-safety: The sweep must be wired AFTER the existing startup checks (see Step 18c) and only once Task 15 read-both is saturated in the field and Task 16 Backup has shipped — sweeping before read-both saturates risks stranding installs that haven't yet learned to read both formats. If the key-health gate is red, the sweep must do absolutely nothing and the app must route the user to passphrase-restore (handled in the Task 16 surface). Never write the completion flag from a partial pass. CSPRNG nonces only; tags `v2:` / `pin:v2:`.

---

### Step 18c - Kick off the sweep AFTER main.dart startup checks (single-threaded, off the critical path)
- File(s): `lib/main.dart` (branch `experimental_flutter_upgrade`; `main()` ~lines 166–245; VERIFY before editing) and the startup-checks site noted by the codebase as `MainScreen._performStartupChecks()` (~lines 989–1006).
- Goal: Run `MigrationService.runIfNeeded()` exactly once per cold start, after the encryption key (`aes_key_v2`) and key-health token are confirmed established by the existing startup checks — never racing key generation.
- Locate (verbatim from the branch — the end of `main()` before `runApp`):
```dart
    log.info('App', 'Settings loaded:');
    log.info('App', '  - AuthMethod: ${settingsService.authMethod}');
    log.info('App', '  - biometricEnabled: ${settingsService.biometricEnabled}');
    log.info('App', '  - pinEnabled: ${settingsService.pinEnabled}');
    log.info('App', '  - hasPinSet: ${settingsService.hasPinSet}');
    
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settingsService),
          ChangeNotifierProvider.value(value: exportService),
          Provider<EncryptionService>.value(value: EncryptionService()),
          Provider<DocumentService>.value(value: DocumentService()),
          Provider<UpdateService>(create: (_) => UpdateService()),
        ],
        child: const MyApp(),
      ),
    );
```
- Change: Do NOT start the sweep in `main()` — the encryption key is established later in `MainScreen._performStartupChecks()` (the codebase note: "Encryption setup is deferred to `MainScreen._performStartupChecks()` ... `showEncryptionKeySetupDialog()` forces configuration if the key is absent"). Starting it in `main()` would race key generation. Instead, at the END of `_performStartupChecks()`, after the key/health setup has completed, add a fire-and-forget kick-off:
```dart
    // After the encryption key + key-health token are confirmed established
    // by the checks above, run the one-time v2 migration sweep off the
    // critical path. Idempotent + resumable: safe to call every launch.
    final enc = context.read<EncryptionService>();
    MigrationService(enc, StorageService(), PdfPasswordService())
        .runIfNeeded()
        .catchError((e, st) {
      LoggingService().error('App', 'Migration kickoff failed', e, st);
    });
```
- Why / safeguards: Placing the kick-off after `_performStartupChecks()` guarantees `aes_key_v2` and the legacy key-health token already exist (single-threaded startup), so the sweep's key-health gate evaluates against a settled key rather than racing the `showEncryptionKeySetupDialog()` path. Fire-and-forget keeps UI startup latency unchanged; `runIfNeeded()` self-guards against concurrent/duplicate runs and the completion flag.
- Test:
  - static: `gradlew assembleDebug` (logged).
  - unit (widget): pump `MainScreen` with a fake `EncryptionService` reporting a healthy key; assert `runIfNeeded()` is invoked exactly once after startup checks complete.
  - device: cold start over a v1 dataset; confirm via `adb logcat` the order is startup-checks → "v2 migration complete"; force-kill mid-sweep (toggle airplane/kill) and relaunch to confirm resume without data loss.
- WARNING / Data-safety: Never start the sweep before key setup completes — a sweep that runs while `aes_key_v2` is mid-generation could see a transient unhealthy key (correctly aborts) or, worse, race a write. Keep it single-threaded with the rest of startup. The kick-off must remain fire-and-forget with its own `catchError`; a migration failure must never crash or block the app. Ensure the read-both rollout (Task 15) is confirmed saturated and Backup (Task 16) shipped before enabling this kick-off in a release build.

Senior-review: apply ONE sub-step per prompt, verify, device-test. (Applies to every card above: Steps 17, 17b, 17c, 18, 18b, 18c.)

Note on referenced helpers — `EncryptionService.isLegacyCiphertext`, `isLegacyKeyHealthy`, `proveLegacyRoundTrip`, `xorEncryptLegacy`, `stripTag`, and the `aes_key_v2`/key-health-token machinery are defined in Parts 1A/1B (Tasks 13–16) and are consumed here unchanged; `PasswordModel` (id/keyName/encryptedValue) lives outside the four fetched files (not in `storage_service.dart`) — VERIFY its `id` is the autoincrement int before relying on it as the CAS key.

---

## Part 2 - PDF tools real fidelity (Task 26, the genuine fix)

This part addresses the structural lie in the current "fix": `importPageRange` claims to copy pages but actually **rasterizes/flattens** them. The investigation below establishes — with citations — that **syncfusion_flutter_pdf 32.x has NO true non-flatten page-import API in any edition (community or commercial)**, then gives the honest, feasible remediation.

### Investigation findings (cite these in the PR description)

- **Pinned version:** `syncfusion_flutter_pdf: ^32.1.22` (pubspec.yaml, branch `experimental_flutter_upgrade`), SDK `>=3.7.0 <4.0.0`. VERIFY before editing.
- **No `importPage` / `pages.add(existingPage)` / `PdfDocumentBase.merge` exists.** Syncfusion's own KB states: *"Currently, Syncfusion does not have support to import pages from existing PDF documents in Flutter. A feature request has been logged ... but there are no immediate plans to implement this feature."* The only sanctioned mechanism for combining pages is `createTemplate()` + `drawPdfTemplate()`. Source: [How to Insert a Page from Another PDF in Flutter (KB 15390)](https://support.syncfusion.com/kb/article/15390/how-to-insert-a-page-from-another-pdf-in-flutter), [Combine multiple PDF documents in Flutter (KB 15804)](https://support.syncfusion.com/kb/article/15804/how-to-combine-multiple-pdf-documents-using-create-template-method-in-flutter).
- **The template approach is lossy by design.** Syncfusion explicitly warns: *"the created template does not contain the form field, so you will have to manually import the form fields or flatten the fields before importing the page as a template."* Beyond form fields, a template captures only the page's drawing content (`PdfTemplate`) — it does **not** carry annotations, link/widget interactivity, bookmarks (document-level outline), or the page's logical text/structure tree. The result is visually similar, selectable-text-bearing in simple cases, but interactive elements and the outline are dropped.
- **This is NOT a community-vs-commercial gap.** The limitation is the Flutter library's architecture, identical across editions. Upgrading the license will not unlock a real import.

**Conclusion: a drop-in "replace the flatten with a real import" does NOT exist in Syncfusion 32.x.** Therefore this part does two things: (Step 26.1) makes the per-op behavior honest and as-lossless-as-the-engine-allows by operating on the **loaded document in place** where the op permits (no cross-document copy at all), and (Step 26.2) for the ops that genuinely require cross-document assembly (merge), surfaces an explicit user-facing fidelity warning and documents the package-migration escape hatch. Both are realistic; neither pretends Syncfusion can do something it cannot.

### Current ops that route through the flatten (verbatim, fetched)

The extension (`lib/core/extensions/pdf_document_extensions.dart`):

```dart
void importPageRange(PdfDocument sourceDocument, int startIndex, int endIndex) {
  for (int i = startIndex; i <= endIndex; i++) {
    if (i >= 0 && i < sourceDocument.pages.count) {
      final srcPage = sourceDocument.pages[i];
      final template = srcPage.createTemplate();
      final section = sections!.add();
      section.pageSettings.size = srcPage.size;
      section.pageSettings.margins.all = 0;
      final page = section.pages.add();
      page.graphics.drawPdfTemplate(template, const Offset(0, 0));
    }
  }
}
```

Four ops in `lib/services/pdf_tools_service.dart` call it:

```dart
// removePassword
newDocument.importPageRange(document, 0, document.pages.count - 1);

// reorderPages
newDocument.importPageRange(document, index, index);

// splitPdf
newDocument.importPageRange(document, index, index);

// mergePdf
newDocument.importPageRange(sourceDoc, 0, sourceDoc.pages.count - 1);
newDocument.importPageRange(otherDoc, 0, otherDoc.pages.count - 1);
```

The critical realization: **three of the four ops never needed a second document at all.**

- `removePassword` only changes `document.security`; it can re-save the *same* `PdfDocument` with security cleared — zero page copies, zero fidelity loss.
- `reorderPages` is a permutation; Syncfusion exposes `document.pages.reArrange(List<int>)` which reorders in place on the loaded document, preserving everything the engine holds.
- `splitPdf` can be done by loading the document and **removing** the unwanted pages (`pages.removeAt`) on a fresh load per output, instead of template-copying the kept ones.
- `mergePdf` is the only op that fundamentally requires cross-document assembly, and is the only one where Syncfusion forces the lossy template path. That op gets the explicit warning + migration note.

---

### Step 26.1 - Stop flattening for removePassword / reorderPages / splitPdf (operate in place)

- **File(s):** `lib/services/pdf_tools_service.dart`, `lib/core/extensions/pdf_document_extensions.dart` (branch `experimental_flutter_upgrade`; line hints approximate, VERIFY before editing).
- **Goal:** Eliminate the template-flatten for the three ops that can be expressed as in-place mutations of the loaded `PdfDocument`, so forms/annotations/bookmarks/text survive.
- **Locate (verbatim from the branch):**

```dart
// removePassword
newDocument.importPageRange(document, 0, document.pages.count - 1);

// reorderPages
newDocument.importPageRange(document, index, index);

// splitPdf
newDocument.importPageRange(document, index, index);
```

- **Change:** Replace each with the in-place equivalent. (Apply ONE op per prompt — these are three independent edits.)

```dart
// removePassword — no copy at all; clear security and re-save the same document.
// document already loaded with the user's password via PdfDocument(inputBytes: ..., password: ...)
document.security.userPassword = '';
document.security.ownerPassword = '';
final List<int> outBytes = await document.save();
// return outBytes; do NOT construct a newDocument / importPageRange.
```

```dart
// reorderPages — permutation in place. `order` is the new index sequence (0-based)
// covering every page exactly once. reArrange preserves page objects, not templates.
document.pages.reArrange(order);
final List<int> outBytes = await document.save();
```

```dart
// splitPdf — for each output chunk, load a FRESH copy of the source bytes, then
// removeAt the pages NOT in this chunk (descending, so indices stay valid).
final PdfDocument out = PdfDocument(inputBytes: sourceBytes /*, password: ... */);
for (int i = out.pages.count - 1; i >= 0; i--) {
  if (!keepIndices.contains(i)) {
    out.pages.removeAt(i);
  }
}
final List<int> chunkBytes = await out.save();
out.dispose();
```

  Then **delete** `importPageRange` from `pdf_document_extensions.dart` only after Step 26.2 removes its last caller (mergePdf). Until then, leave it.

- **Why / safeguards:** `reArrange` and `removeAt` mutate the in-memory `PdfPageCollection` of the loaded document; they do not re-draw content, so annotations, AcroForm fields, link/widget annotations, and the document outline are retained to the extent Syncfusion models them. `removePassword` doing a plain re-save is strictly lossless. For `splitPdf`, reloading `sourceBytes` per chunk avoids mutating one shared document across chunks (a classic aliasing bug). `dispose()` each transient document to free native PDFium-style buffers.
- **Test:**
  - static: build per `.agent/rules/test.md` — `gradlew assembleDebug`, log the result.
  - unit: feed a fixture PDF that contains a fillable form field + a bookmark; after `reorderPages` and `splitPdf`, reopen the output and assert `doc.form.fields.count > 0` and the outline is non-empty (Syncfusion `PdfDocument.bookmarks.count`). This test will FAIL against the old `importPageRange` and PASS after — that is the regression guard proving the fix is real.
  - device: `adb push` a real form PDF, run each op in-app, `adb pull` the result, open in a viewer, confirm the form is still fillable and bookmarks still navigate.
- **WARNING / Data-safety:** These ops read/write **file bytes**, not crypto state — they do not touch the AES key, `flutter_secure_storage` (`aes_key_v2`), the legacy XOR `encryption_key`, or the SQLite `document_passwords` store, so the crypto invariants are not directly engaged here. BUT: `removePassword` requires the open password, which for app-managed PDFs comes from `PdfPasswordService`'s in-memory map. Read it THROUGH `PdfPasswordService`, never from raw SharedPreferences, and never write a recovered/changed password back except through that service's `_save()` (single-writer + compare-and-swap invariant). `decrypt()` may return null (its null-on-failure contract) — if the password lookup decrypts to null, abort the op and surface an error; do NOT force-unwrap and do NOT attempt any overwrite. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 26.2 - mergePdf: keep the only justified flatten, but make it honest (explicit warning + migration path)

- **File(s):** `lib/services/pdf_tools_service.dart` (mergePdf), the UI surface that invokes it, `lib/core/extensions/pdf_document_extensions.dart` (branch `experimental_flutter_upgrade`; VERIFY).
- **Goal:** For the one op Syncfusion cannot do losslessly, stop silently degrading documents — warn the user before merging that interactive content will be flattened, and document the package-migration option for a future true-fidelity merge.
- **Locate (verbatim from the branch):**

```dart
// mergePdf
newDocument.importPageRange(sourceDoc, 0, sourceDoc.pages.count - 1);
newDocument.importPageRange(otherDoc, 0, otherDoc.pages.count - 1);
```

- **Change:** Keep the template copy (it is the only path Syncfusion offers for cross-document assembly), but (a) detect when a source has interactive content and (b) gate the op behind an explicit user acknowledgement. Pseudocode for the service-level guard:

```dart
// Before assembling: detect interactive content that the template flatten will drop.
bool _hasInteractiveContent(PdfDocument d) =>
    d.form.fields.count > 0 || d.bookmarks.count > 0;

final bool lossy =
    _hasInteractiveContent(sourceDoc) || _hasInteractiveContent(otherDoc);
// Surface `lossy` to the caller; the UI must show a blocking confirmation:
//   "Merging will FLATTEN form fields, annotations, and bookmarks in one or
//    more of these PDFs. The merged file will look the same but will no longer
//    be fillable/interactive. Continue?"
// Only on explicit confirm:
newDocument.importPageRange(sourceDoc, 0, sourceDoc.pages.count - 1);
newDocument.importPageRange(otherDoc, 0, otherDoc.pages.count - 1);
```

- **Why / safeguards:** This is the honest position: Syncfusion 32.x physically cannot merge two documents without flattening (KB 15390 / 15804, quoted above). Silently producing a flattened file is the current bug. The fix is consent, not a phantom API. `importPageRange` already sets `section.pageSettings.size = srcPage.size`, which correctly preserves non-A4 page sizes (Letter/Legal/custom) — keep that; removing it would reintroduce the A4-crop defect.
- **Migration path (document in the runbook, do NOT implement blind):** A genuinely lossless cross-document merge requires leaving Syncfusion for the merge op only:
  - **`pdfrx`** — built on PDFium, supports combining PDFs across Android/iOS/desktop/web; PDFium's `FPDF_ImportPages` does a true object-level page copy (annotations/forms/structure preserved). Strongest candidate for a real fix. Verify the public Dart API exposes import before committing.
  - **`pdf_manipulator`** — cross-platform merge off the main thread; evaluate its merge fidelity on a form fixture before trusting it.
  - **`pdf`** (dart pdf) — a *producer*, not a manipulator; it cannot import existing pages losslessly. **Reject for merge.**
  - **`pdf_merger`** — evaluate, but historically thin; verify it is not itself a Syncfusion/template wrapper.

  Recommendation for a senior: prototype `pdfrx` merge on a form-bearing fixture and compare `form.fields.count` before/after; if PDFium preserves it, scope a follow-up task to route ONLY `mergePdf` through `pdfrx` while the in-place ops from Step 26.1 stay on Syncfusion. Do not migrate the whole service.
- **Test:**
  - static: `gradlew assembleDebug`, logged per `.agent/rules/test.md`.
  - unit: assert `_hasInteractiveContent` returns true for the form/bookmark fixture and false for a plain scanned PDF; assert merge does not proceed without the confirm flag set.
  - device: `adb`-push two PDFs (one with a form), trigger merge in-app, confirm the warning dialog appears and is blocking, accept, `adb pull`, verify the merged file opens and that the flatten warning matched reality (form no longer fillable). For the `pdfrx` spike, repeat and confirm the form IS still fillable.
- **WARNING / Data-safety:** Same boundary as Step 26.1 — merge operates on file bytes and does not touch crypto state, so the AES/Keystore invariants (`aes_key_v2` in `flutter_secure_storage`, legacy XOR `encryption_key` read-only forever, the KEY-HEALTH gate via `sha256(legacy key)`, the SQLite compare-and-swap single-writer, CSPRNG `v2:`/`pin:v2:` tags, Argon2id passphrase backup, rollout order read-both→backup→sweep) are NOT engaged by this code path and MUST NOT be modified here. If any input PDF is password-protected, obtain the password ONLY through `PdfPasswordService`'s in-memory map (never raw prefs), treat a null `decrypt()` as abort (do not force-unwrap, do not overwrite), and never write any recovered password back except via that service's `_save()`. Before adding a new dependency (pdfrx etc.), re-confirm `MANAGE_EXTERNAL_STORAGE`/all-files-access is unaffected and that the package does not bundle its own backup/key behavior. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

**Net honesty statement for the runbook:** Task 26's prior "fix" did not fix fidelity — it relabelled a flatten. Syncfusion 32.x offers no true import (citations above). The genuine fix is (1) remove the cross-document copy entirely for `removePassword`/`reorderPages`/`splitPdf` by mutating the loaded document in place (real, lossless, shippable now), and (2) for `mergePdf`, stop flattening silently — require user consent and schedule a `pdfrx`/PDFium spike for an actual lossless merge.

Relevant files (absolute, this read-only checkout):
- `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\lib\services\pdf_tools_service.dart`
- `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\lib\core\extensions\pdf_document_extensions.dart`
- `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\pubspec.yaml`

---

## Part 3 - Export: optional Remove password from PDFs (Task 27)

This task adds an opt-in checkbox to the bulk ZIP export dialog: **"Remove password from PDFs in the ZIP"**. When checked, every protected PDF in the selection is decrypted to a TEMP file (using its stored password) on the main isolate, and the decrypted bytes are what get archived — the originals on disk stay password-protected. PDFs with no stored password are skipped and reported.

**Critical isolate ordering:** `removePassword()` uses Syncfusion `PdfDocument` (heavy, but synchronous/main-isolate-friendly here) and `PdfPasswordService`/`flutter_secure_storage` (which MUST run on the main isolate — secure storage and the Keystore-backed key are single-threaded). The archive *encode* hop is the only thing that may go through `compute()`. Therefore: do ALL decryption + temp-file writing on the main isolate inside `_addItemsToArchive` (before any `compute()` encode), collect temp paths, then clean them up after the archive bytes are produced.

**Dependency on Task 26:** Output quality of the unlocked PDFs is entirely governed by Task 26's `removePassword` fidelity (`importPageRange` preserving text/links/form fields, no visual flatten). If Task 26 regresses to a render-and-reflatten path, every removed-password export silently degrades. Do not ship Task 27 unless Task 26's fidelity invariant is verified on-device.

**Confirmed signature (from `lib/services/pdf_password_service.dart`):** `Future<String?> getPasswordForDocument(String filePath)` — returns the *decrypted plaintext* password, `''` for the `NO_PASSWORD` sentinel, or `null` when nothing is stored. It calls `_encryptionService.decrypt(...)` internally, which keeps the null-on-failure contract.

---

### Step 27.1 - Add the "Remove password" checkbox to the export dialog
- File(s): `lib/features/documents/screens/document_dashboard_screen.dart` (branch `experimental_flutter_upgrade`; inside `_exportSelectedItems`, line hints approximate, VERIFY before editing)
- Goal: surface a `removePasswords` bool in the ZIP export dialog without disturbing the existing "Protect with Password" flow.
- Locate (verbatim from the branch):
```dart
final confirm = await showDialog<bool>(
  context: context,
  builder: (context) {
    return StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          title: const Text('Export Selected Items'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Export ${_selectedFileIds.length} items as a ZIP file?'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: encrypt,
                    onChanged: (val) => setState(() => encrypt = val ?? false),
                  ),
                  const Text('Protect with Password'),
                ],
              ),
              if (encrypt)
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'ZIP Password',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  obscureText: true,
                  onChanged: (val) => password = val,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.archive),
              onPressed: () => Navigator.pop(context, true),
              label: const Text('Export'),
            ),
          ],
        );
      },
    );
  },
);
```
- Change: declare `bool removePasswords = false;` alongside the existing `encrypt`/`password` locals (VERIFY where those are declared — they are referenced in the `builder` closure, so the new local must sit in the same scope, before `showDialog`), then add the checkbox row inside the `Column.children`:
```dart
              Row(
                children: [
                  Checkbox(
                    value: encrypt,
                    onChanged: (val) => setState(() => encrypt = val ?? false),
                  ),
                  const Text('Protect with Password'),
                ],
              ),
              if (encrypt)
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'ZIP Password',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  obscureText: true,
                  onChanged: (val) => password = val,
                ),
              Row(
                children: [
                  Checkbox(
                    value: removePasswords,
                    onChanged: (val) =>
                        setState(() => removePasswords = val ?? false),
                  ),
                  const Expanded(
                    child: Text('Remove password from PDFs in the ZIP'),
                  ),
                ],
              ),
```
- Why / safeguards: `Expanded` prevents the longer label from overflowing the `AlertDialog`. The checkbox defaults to `false`, so existing export behavior is byte-for-byte unchanged unless the user opts in. The two options are orthogonal — a user can ZIP-encrypt AND strip per-PDF passwords in one pass.
- Test: static (build per `.agent/rules/test.md`: `gradlew assembleDebug`, logged). Device test with adb: launch, multi-select PDFs, open the export dialog, confirm the new checkbox renders and toggles, label does not overflow.
- WARNING / Data-safety: this step only adds a UI bool — no crypto yet. Do not wire it into `addJob` in the same prompt; that is Step 27.2. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 27.2 - Thread `removePasswords` through `addJob` → `ExportJob`
- File(s): `lib/services/export_queue_service.dart` (branch `experimental_flutter_upgrade`; `addJob` + `ExportJob` fields/constructor) and the call site in `lib/features/documents/screens/document_dashboard_screen.dart`
- Goal: carry the opt-in flag from the dialog into the persisted job, so the background processor knows whether to decrypt.
- Locate (verbatim from the branch) — `addJob`:
```dart
Future<String> addJob(String name, List<ExportItem> items, 
    {String? exportDir, String? zipPassword, ExportType type = ExportType.zip, 
    bool isDeveloper = false}) async {
  if (_jobs.length >= 100) {
    final oldest = _jobs.firstWhere(
      (j) => j.status == ExportStatus.completed || j.status == ExportStatus.error, 
      orElse: () => _jobs.first
    );
    await removeJob(oldest.id);
  }
  
  int countItems(List<ExportItem> items) {
    int count = 0;
    for (final item in items) {
      if (item.isFolder) {
        count += countItems(item.children);
      } else {
        count++;
      }
    }
    return count;
  }
  
  final total = countItems(items);
  final job = ExportJob(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: name,
    items: items,
    exportDir: exportDir,
    zipPassword: zipPassword,
    totalItems: total,
    type: type,
    isDeveloper: isDeveloper,
  );
  _jobs.add(job);
  _persistJob(job);
  _log.info('ExportQueueService', 'Job added: ${job.name} with $total files');
  notifyListeners();
  _processQueue();
  return job.id;
}
```
- Locate (verbatim from the branch) — `ExportJob` fields:
```dart
final String id;
final String name;
ExportStatus status;
final DateTime createdAt;
DateTime? completedAt;
String? outputPath;
String? errorMessage;
final List<ExportItem> items;
final String? zipPassword;
final String? exportDir;
final ExportType type;
final bool isDeveloper;
int progress;
int processedItems;
int totalItems;
```
- Locate (verbatim from the branch) — call site:
```dart
_exportQueue.addJob('Bulk Export', exportItems, 
    exportDir: exportPath, zipPassword: zipPassword);
```
- Change — `addJob` signature + `ExportJob` construction (add the named param, default `false`):
```dart
Future<String> addJob(String name, List<ExportItem> items, 
    {String? exportDir, String? zipPassword, ExportType type = ExportType.zip, 
    bool isDeveloper = false, bool removePasswords = false}) async {
```
```dart
  final job = ExportJob(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: name,
    items: items,
    exportDir: exportDir,
    zipPassword: zipPassword,
    totalItems: total,
    type: type,
    isDeveloper: isDeveloper,
    removePasswords: removePasswords,
  );
```
- Change — `ExportJob` field + constructor (VERIFY the constructor: it is a named-param constructor matching the field list above — add `this.removePasswords = false` to it, line hints approximate):
```dart
final bool removePasswords;
```
- Change — call site:
```dart
_exportQueue.addJob('Bulk Export', exportItems, 
    exportDir: exportPath, zipPassword: zipPassword,
    removePasswords: removePasswords);
```
- Why / safeguards: `removePasswords` is `final` and defaulted, so `_persistJob`/restore (VERIFY the JSON (de)serialization for `ExportJob` — if jobs are serialized to disk, add `removePasswords` to `toJson`/`fromJson` with a `?? false` fallback so old persisted jobs deserialize cleanly). Defaulting to `false` keeps every other `addJob` caller (single export, developer export) unaffected.
- Test: static build (`gradlew assembleDebug`, logged). Unit test if feasible: construct an `ExportJob`/`addJob` with `removePasswords: true` and assert the field propagates; round-trip `toJson`/`fromJson` and assert it survives. Device test: trigger an export with the box checked, confirm via log (`Job added: ...`) the job is created without crash.
- WARNING / Data-safety: do NOT yet decrypt anything — this step only persists the flag. If `ExportJob` is serialized, a missing field on an old job must NOT throw; use `?? false`. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 27.3 - Decrypt protected PDFs to TEMP files inside `_addItemsToArchive` (main isolate, before the encode hop)
- File(s): `lib/services/export_queue_service.dart` (`_addItemsToArchive`); depends on `lib/services/pdf_password_service.dart` (`getPasswordForDocument`) and `lib/services/pdf_tools_service.dart` (`removePassword`)
- Goal: when `job.removePasswords` is set, archive the decrypted bytes of each protected PDF (written to a temp file first), skip+report PDFs with no stored password, and leave originals untouched.
- Locate (verbatim from the branch):
```dart
Future<void> _addItemsToArchive(Archive archive, List<ExportItem> items, 
    String pathPrefix, ExportJob job, int notificationId) async {
  for (final item in items) {
    final archivePath = pathPrefix.isEmpty ? item.name : '$pathPrefix/${item.name}';
    if (item.isFolder) {
      await _addItemsToArchive(archive, item.children, archivePath, job, notificationId);
    } else if (item.filePath != null) {
      final file = File(item.filePath!);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
        job.processedItems++;
        if (job.totalItems > 0) {
          job.progress = ((job.processedItems / job.totalItems) * 100).round();
          if (job.processedItems % 5 == 0 || job.progress % 10 == 0) {
            await _showNotification(
              notificationId, 
              'Exporting ${job.name}', 
              '${job.progress}% complete', 
              progress: job.progress, 
              maxProgress: 100
            );
            notifyListeners();
          }
        }
        await Future.delayed(Duration.zero);
      }
    }
  }
}
```
- Change: gate the bytes source on `job.removePasswords`. Decrypt to a temp file, read those bytes, and register the temp path for cleanup. (VERIFY the field names of the two dependency services — `PdfPasswordService` and `PdfToolsService` — and how `_addItemsToArchive` can reach them; if the service isn't already a member, inject/instantiate it at the top of the export-processing method, NOT per-item. Also add a `List<String> tempPaths` accumulator — see Step 27.4 for where it lives and is cleaned up.)
```dart
Future<void> _addItemsToArchive(Archive archive, List<ExportItem> items, 
    String pathPrefix, ExportJob job, int notificationId,
    List<String> tempPaths, List<String> skippedNoPassword) async {
  for (final item in items) {
    final archivePath = pathPrefix.isEmpty ? item.name : '$pathPrefix/${item.name}';
    if (item.isFolder) {
      await _addItemsToArchive(archive, item.children, archivePath, job,
          notificationId, tempPaths, skippedNoPassword);
    } else if (item.filePath != null) {
      final file = File(item.filePath!);
      if (await file.exists()) {
        Uint8List bytes;
        final isPdf = item.filePath!.toLowerCase().endsWith('.pdf');

        if (job.removePasswords && isPdf) {
          // Main-isolate only: secure storage + Keystore key are single-threaded.
          final pwd = await _pdfPasswordService
              .getPasswordForDocument(item.filePath!);
          if (pwd == null) {
            // No stored password -> cannot strip. Skip & report. Original untouched.
            skippedNoPassword.add(item.name);
            _log.warning('ExportQueueService',
                'Skip remove-password (no stored password): ${item.name}');
            job.processedItems++;
            await Future.delayed(Duration.zero);
            continue;
          }
          if (pwd.isEmpty) {
            // NO_PASSWORD sentinel: not actually protected -> archive as-is.
            bytes = await file.readAsBytes();
          } else {
            final tmpDir = await getTemporaryDirectory();
            final tmpPath = path.join(tmpDir.path,
                'unlock_${DateTime.now().microsecondsSinceEpoch}_${item.name}');
            try {
              // removePassword runs on the MAIN isolate, BEFORE any compute() encode.
              final outPath = await _pdfToolsService.removePassword(
                filePath: item.filePath!,
                password: pwd,
                savePath: tmpPath,
              );
              tempPaths.add(outPath);
              bytes = await File(outPath).readAsBytes();
            } catch (e) {
              // Wrong stored password / corrupt PDF: do NOT leak the protected
              // original into an "unlocked" export. Skip & report.
              skippedNoPassword.add(item.name);
              _log.warning('ExportQueueService',
                  'Remove-password failed, skipping ${item.name}: $e');
              job.processedItems++;
              await Future.delayed(Duration.zero);
              continue;
            }
          }
        } else {
          bytes = await file.readAsBytes();
        }

        archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
        job.processedItems++;
        if (job.totalItems > 0) {
          job.progress = ((job.processedItems / job.totalItems) * 100).round();
          if (job.processedItems % 5 == 0 || job.progress % 10 == 0) {
            await _showNotification(
              notificationId, 
              'Exporting ${job.name}', 
              '${job.progress}% complete', 
              progress: job.progress, 
              maxProgress: 100
            );
            notifyListeners();
          }
        }
        await Future.delayed(Duration.zero);
      }
    }
  }
}
```
- Why / safeguards:
  - **Originals stay protected.** `removePassword` (Task 26) takes `filePath` + `savePath` and writes a NEW file at `savePath`; it never overwrites the source. We point `savePath` at a temp file and archive *those* bytes. The on-disk original is never read into the archive when stripping succeeds.
  - **Main-isolate ordering.** Both `getPasswordForDocument` (flutter_secure_storage / Keystore) and `removePassword` (Syncfusion `PdfDocument`) run here, synchronously within the async loop, on the main isolate — strictly before the archive is encoded. Never move secure-storage reads or the stored-password into a `compute()`/background isolate.
  - **Skip-and-report contract.** `getPasswordForDocument` returns `null` when nothing is stored → we skip and record the name; never archive a still-encrypted PDF labeled as unlocked. A decrypt/strip exception (wrong stored password) is treated the same way — skip, don't fall back to the protected original.
  - **`''` sentinel.** `getPasswordForDocument` returns `''` for the `NO_PASSWORD` marker (file isn't really protected); we archive it as-is rather than calling `removePassword` with an empty password.
  - Unique temp names via `microsecondsSinceEpoch` avoid collisions across same-named files in different folders.
- Test: static build (`gradlew assembleDebug`, logged). Unit test if feasible: feed a known protected PDF + a stored password into the strip path and assert the archived bytes open WITHOUT a password while the source file still requires one. Device test with adb: select 1 protected PDF (password stored) + 1 protected PDF (NO password stored) + 1 plain file; export with the box checked; pull the ZIP via `adb pull`; confirm the first PDF opens with no password, the second is reported as skipped, the plain file is intact, and the originals on device still prompt for a password.
- WARNING / Data-safety:
  - Decrypted plaintext (the stored password AND the unlocked PDF bytes) lives transiently in memory and in a temp file on disk. The temp file MUST be deleted (Step 27.4), including on error paths.
  - Do NOT log the password value. The `_log.warning` lines above log only the file name, never `pwd`.
  - The key strategy is unchanged by this task: `getPasswordForDocument` decrypts via `_encryptionService.decrypt` (Keystore-backed `aes_key_v2`, null-on-failure). This task is READ-ONLY w.r.t. stored passwords — it never writes/overwrites a stored password, never touches the legacy `encryption_key` (XOR) values, and triggers no migration. No write path is introduced, so the KEY-HEALTH GATE and compare-and-swap invariants are not exercised here — but do not add any write as a "convenience" in this card.
  - Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

### Step 27.4 - Clean up temp files and surface the skipped-PDF report
- File(s): `lib/services/export_queue_service.dart` (the method that builds the `Archive`, calls `_addItemsToArchive`, then encodes it — VERIFY the exact method name, e.g. `_processJob`/`_runZipExport`; it is the caller that owns the `Archive` and the `compute()`/`ZipEncoder` encode)
- Goal: guarantee temp decrypted PDFs are deleted after the archive bytes are produced (success or failure), and record which PDFs were skipped so the UI/notification can tell the user.
- Locate (verbatim from the branch): VERIFY and fetch the caller of `_addItemsToArchive` before editing — it constructs the `Archive`, invokes `_addItemsToArchive(archive, job.items, '', job, notificationId)`, then encodes the archive (look for `ZipEncoder().encode(...)` and/or a `compute(...)` hop) and writes the output file. (Not re-pasted here because it was not individually fetched; do not edit blind.)
- Change (shape to apply against the verified caller):
```dart
    final tempPaths = <String>[];
    final skippedNoPassword = <String>[];
    try {
      await _addItemsToArchive(
          archive, job.items, '', job, notificationId,
          tempPaths, skippedNoPassword);

      // ... existing encode hop unchanged, e.g.:
      // final encoded = await compute(_encodeArchive, archive);  // or ZipEncoder().encode(archive)
      // ... write encoded bytes to the output file unchanged ...
    } finally {
      // Always remove decrypted temp PDFs, even if the encode threw.
      for (final p in tempPaths) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (e) {
          _log.warning('ExportQueueService', 'Temp cleanup failed: $p ($e)');
        }
      }
    }
    if (skippedNoPassword.isNotEmpty) {
      // Surface via the job (and/or completion notification) so the user knows.
      job.errorMessage =
          'Exported, but ${skippedNoPassword.length} PDF(s) kept their '
          'password (no stored password): ${skippedNoPassword.join(', ')}';
      _log.info('ExportQueueService',
          'Remove-password skipped: ${skippedNoPassword.join(', ')}');
    }
```
- Why / safeguards:
  - **`finally` is mandatory** — the encode hop (especially through `compute()`) can throw or the device can OOM; temp decrypted PDFs must never survive a failed export. Deleting in `finally` (not after a successful write) closes that leak.
  - Temp files are deleted only AFTER `_addItemsToArchive` has read their bytes into the in-memory `Archive`, and after the encode that consumes that `Archive`. Deleting earlier would corrupt the archive if the encoder reads lazily — VERIFY whether the project's `ZipEncoder`/`compute` path holds the bytes eagerly (the `archive.addFile(ArchiveFile(path, len, bytes))` form above passes bytes by value, so post-encode deletion is safe).
  - Reusing `job.errorMessage` for a partial-success notice (VERIFY whether a dedicated `warningMessage` field is preferable so the job isn't marked failed) lets the existing completion UI show which files kept their password. Do not silently swallow skips — a user who asked to remove passwords must be told which files still have them.
- Test: static build (`gradlew assembleDebug`, logged). Device test with adb: (1) successful export — after completion, `adb shell run-as <pkg> ls` the temp dir (or `getTemporaryDirectory()` path) and confirm no `unlock_*` files remain; (2) force-fail the encode (e.g. huge selection / induced exception) and confirm temps are STILL gone; (3) include a protected PDF with no stored password and confirm the completion message names it.
- WARNING / Data-safety: a decrypted, password-free copy of a sensitive PDF sitting in the temp dir is the primary leak vector of this entire feature. The `finally` cleanup is the safety boundary — review it first in any future refactor of the export pipeline. Confirm `getTemporaryDirectory()` (path_provider) resolves to app-private cache, NOT a shared/MediaStore location. This task introduces no stored-password writes, so no migration/CAS/key-health interactions; keep it that way. Senior-review: apply ONE sub-step per prompt, verify, device-test.

---

**Cross-file wiring summary (all on `experimental_flutter_upgrade`):** dialog bool `removePasswords` (27.1) → `addJob(..., removePasswords:)` → `ExportJob.removePasswords` (27.2) → consumed in `_addItemsToArchive` via `job.removePasswords`, which calls `PdfPasswordService.getPasswordForDocument(String filePath)` then `PdfToolsService.removePassword(filePath:, password:, savePath:)` to a temp file ON THE MAIN ISOLATE before the `compute()` encode (27.3) → temp cleanup in `finally` + skipped-PDF report (27.4). Originals remain protected throughout; PDFs with no stored password are skipped and reported. Output fidelity is bounded by Task 26's `removePassword` (`importPageRange`, no flatten) — verify Task 26 before shipping.

---

## Part 4 - Store refactor: collapse onto SQLite (Tasks 30 and 31) - DESIGN PLAN

> Scope: this is a **DESIGN PLAN**, not a set of find/replace cards. It is **senior-only and multi-PR**. The library store (`DocumentService`) currently persists its entire object graph as a single JSON blob in `SharedPreferences` under `documents_items`, while the device-scan store (`DeviceDocumentService`) already lives in SQLite (`files_index`, DB version 14). Tasks 30 and 31 collapse the library onto the same SQLite database, retire the blob, and in doing so **subsume four standing data-integrity bugs** rather than patching them one card at a time. Apply ONE phase per PR, verify, device-test, before the next.

### 0. Current state - verbatim evidence (branch `experimental_flutter_upgrade`, VERIFY before editing)

**Single JSON blob persistence** - `lib/services/document_service.dart`, `_saveDocuments` and key constant:

```dart
static const String _documentsKey = 'documents_items';

Future<void> _saveDocuments() async {
  try {
    final jsonList = _items.map((item) => item.toJson()).toList();
    final jsonString = json.encode(jsonList);
    await _prefs?.setString(_documentsKey, jsonString);
  }
}
```

Every mutation re-serializes the **entire** `_items` list and overwrites the whole key. There is no per-row write and no compare-and-swap; the last in-memory snapshot to call `_saveDocuments()` wins.

**The model carries a DUAL parent representation** - `lib/models/document_item_model.dart`, fields + constructor:

```dart
final String id;
final String name;
final DocumentItemType type;
final String? sourcePath;
final String? parentId;
final List<String> fileIds;
final int size;
final DateTime createdAt;
final DateTime modifiedAt;
final bool isImported;
final bool isImportedFile;
final bool isNew;
final bool missingOnDevice;
final DateTime? addedAt;
final DateTime? lastSynced;
```

```dart
DocumentItem({
  required this.id,
  required this.name,
  required this.type,
  this.sourcePath,
  this.parentId,
  List<String>? fileIds,
  this.size = 0,
  DateTime? createdAt,
  DateTime? modifiedAt,
  this.isImported = false,
  this.isImportedFile = false,
  this.isNew = false,
  this.missingOnDevice = false,
  this.addedAt,
  this.lastSynced,
})  : fileIds = fileIds ?? [],
      createdAt = createdAt ?? DateTime.now(),
      modifiedAt = modifiedAt ?? DateTime.now();
```

A file's membership in a folder is encoded **twice**: on the child via `parentId`, and on the parent via `fileIds`. These two are written independently (see `addFile` below) and there is nothing that keeps them consistent.

**Timestamp ids** - `lib/services/document_service.dart`, inside `addFile`:

```dart
id: DateTime.now().millisecondsSinceEpoch.toString(),
```

**`addFile` writes both sides of the dual model, non-atomically** - `lib/services/document_service.dart`:

```dart
Future<DocumentItem> addFile(String filePath, {String? folderId, String? customName, DateTime? createdAt, DateTime? modifiedAt, bool isNew = false, bool isImportedFile = false}) async {
  final file = File(filePath);
  final stat = await file.stat();
  final size = await file.length();
  final name = customName ?? filePath.split(Platform.pathSeparator).last;

  final newItem = DocumentItem(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: name,
    type: DocumentItemType.file,
    sourcePath: filePath, // Storing ORIGINAL path
    parentId: folderId,
    size: size,
    createdAt: createdAt ?? stat.changed,
    modifiedAt: modifiedAt ?? stat.modified,
    isNew: isNew,
    isImportedFile: isImportedFile, // Set flag
    addedAt: isNew ? DateTime.now() : null,
  );

  _items.add(newItem);

  // If added to a folder, update folder's file list
  if (folderId != null) {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex != -1) {
      final folder = _items[folderIndex];
      final updatedFolder = folder.copyWith(
        fileIds: [...folder.fileIds, newItem.id],
      );
      _items[folderIndex] = updatedFolder;
    }
  }

  await _saveDocuments();
  return newItem;
}
```

**`getFilesInFolder` requires BOTH sides to agree** - `lib/services/document_service.dart`:

```dart
List<DocumentItem> getFilesInFolder(String folderId) {
  final folder = _items.firstWhere(
    (item) => item.id == folderId,
    orElse: () => throw Exception('Folder not found'),
  );
  return _items
      .where((item) => item.isFile && folder.fileIds.contains(item.id))
      .toList();
}
```

Note the filter: `item.isFile && folder.fileIds.contains(item.id)`. A file whose `parentId == folderId` but whose id is **absent from `folder.fileIds`** is invisible here. This is the divergence bug realized.

**`moveFolderToFolder` updates ONLY `parentId`** - `lib/services/document_service.dart`:

```dart
Future<void> moveFolderToFolder(String folderId, String newParentId) async {
  final folderIndex = _items.indexWhere((item) => item.id == folderId);
  if (folderIndex == -1) {
    throw Exception('Folder not found');
  }

  final folder = _items[folderIndex];
  if (!folder.isFolder) {
    throw Exception('Item is not a folder');
  }
  if (newParentId == folderId) {
    throw Exception('Cannot move folder into itself');
  }
  bool isDescendantOf(String candidate, String root) {
    for (final sub in getSubfolders(root)) {
      if (sub.id == candidate || isDescendantOf(candidate, sub.id)) return true;
    }
    return false;
  }
  if (isDescendantOf(newParentId, folderId)) {
    throw Exception('Cannot move folder into its own descendant');
  }

  final conflictingFolder = _items.where((item) =>
      item.isFolder &&
      item.parentId == newParentId &&
      item.name == folder.name &&
      item.id != folderId
  ).toList();

  if (conflictingFolder.isNotEmpty) {
      final existing = conflictingFolder.first;
      if (existing.isImported) {
          throw Exception('Cannot move: An imported folder "${folder.name}" already exists at this location. Please rename your folder first.');
      } else if (folder.isImported) {
          throw Exception('Cannot move: A folder "${folder.name}" already exists at this location. Please rename the existing folder first.');
      } else {
          throw Exception('Cannot move: A folder "${folder.name}" already exists at this location.');
      }
  }

  _items[folderIndex] = folder.copyWith(parentId: newParentId);

  await _saveDocuments();
  _log.info('DocumentService', 'Moved folder ${folder.name} to folder $newParentId');
}
```

`moveFolderToFolder` is itself proof of the divergence: it mutates `parentId` only and never touches the old/new parent's `fileIds`. So a moved **folder** is correctly re-parented (folder traversal uses `parentId` via `getSubfolders`), but if any sibling code relied on `fileIds` the link rots. The model has two sources of truth and the mutators each pick one.

**Size-only dedup** - `lib/services/document_service.dart`, in `addReference` and `checkForDuplicates`:

```dart
// addReference:
final srcLen = await file.length();
// ...
final existingLen = await existingFile.length();
if (srcLen == existingLen) {
  duplicates.add(DuplicateInfo(...));
}
```

```dart
// checkForDuplicates:
final fileSize = await file.length();
// ...
int existingSize = item.size;
// ...
if (fileSize == existingSize) {
    duplicates.add(DuplicateInfo(...));
}
```

Equal byte-length is treated as "duplicate". Two unrelated PDFs that happen to share a size collide; a real duplicate that was re-saved (size drift by one byte) is missed.

**The device store already lives in SQLite** - `lib/services/storage_service.dart` (`_onCreate`, version 14):

```dart
CREATE TABLE files_index (
  path TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  extension TEXT NOT NULL,
  parent_path TEXT NOT NULL,
  size INTEGER NOT NULL,
  created_at INTEGER,
  modified_at INTEGER,
  last_scanned INTEGER,
  is_folder INTEGER DEFAULT 0,
  has_pdf INTEGER DEFAULT 0,
  has_doc INTEGER DEFAULT 0,
  has_excel INTEGER DEFAULT 0,
  is_new INTEGER DEFAULT 0,
  missing_on_device INTEGER DEFAULT 0,
  added_at INTEGER,
  last_synced INTEGER,
  is_imported INTEGER DEFAULT 0,
  is_imported_file INTEGER DEFAULT 0
)
```

`DeviceDocumentService` upserts into this table with `ON CONFLICT(path) DO UPDATE` (per-row, path-keyed). The library store is the **only** store still on a JSON blob; this plan brings it onto the same `Database` instance (`StorageService.database`, `AppConstants.databaseName`, version 14 -> bump per Phase A).

---

### (a) Target SQLite schema for the library

A single `documents` table replaces the `documents_items` JSON blob. **One parent model**: a self-referential `parent_id` (FK to `documents.id`) is the sole truth for hierarchy; the redundant `fileIds` list on folders is **dropped** (it becomes a query: `SELECT id FROM documents WHERE parent_id = ?`). Ids become UUIDv4 strings. A `content_hash` column replaces size-only dedup.

```sql
CREATE TABLE documents (
  id           TEXT PRIMARY KEY,              -- UUIDv4, NOT millisecondsSinceEpoch
  name         TEXT NOT NULL,
  type         TEXT NOT NULL,                 -- 'file' | 'folder' (DocumentItemType.toString())
  source_path  TEXT,                          -- maps DocumentItem.sourcePath (== legacy filePath)
  parent_id    TEXT REFERENCES documents(id) ON DELETE CASCADE,  -- SINGLE parent model
  size         INTEGER NOT NULL DEFAULT 0,
  content_hash TEXT,                          -- sha256 of file bytes (nullable until first hashed)
  created_at   INTEGER NOT NULL,             -- epoch millis (match files_index convention)
  modified_at  INTEGER NOT NULL,
  is_imported       INTEGER NOT NULL DEFAULT 0,
  is_imported_file  INTEGER NOT NULL DEFAULT 0,
  is_new            INTEGER NOT NULL DEFAULT 0,
  missing_on_device INTEGER NOT NULL DEFAULT 0,
  added_at     INTEGER,
  last_synced  INTEGER
);

CREATE INDEX idx_documents_parent ON documents(parent_id);
CREATE INDEX idx_documents_hash   ON documents(content_hash);
CREATE INDEX idx_documents_source ON documents(source_path);
```

Column-to-field mapping (every `DocumentItem` field is preserved except `fileIds`, which is derived):

| DocumentItem field | documents column | note |
|---|---|---|
| `id` | `id` | UUIDv4 (was `millisecondsSinceEpoch.toString()`) |
| `name` | `name` | |
| `type` | `type` | `DocumentItemType.toString()`, same as `toJson` |
| `sourcePath` | `source_path` | legacy JSON wrote both `sourcePath` and `filePath`; collapse to one column |
| `parentId` | `parent_id` | now the ONLY parent representation |
| `fileIds` | (none) | derived: `WHERE parent_id = ?` |
| `size` | `size` | |
| (new) | `content_hash` | sha256, replaces size-equality dedup |
| `createdAt` | `created_at` | stored as epoch millis (`files_index` uses INTEGER millis) |
| `modifiedAt` | `modified_at` | |
| `isImported` | `is_imported` | |
| `isImportedFile` | `is_imported_file` | |
| `isNew` | `is_new` | |
| `missingOnDevice` | `missing_on_device` | |
| `addedAt` | `added_at` | nullable epoch millis |
| `lastSynced` | `last_synced` | nullable |

Note `ON DELETE CASCADE` plus `idx_documents_parent` make folder-delete and folder-listing O(children) instead of full-list scans. `content_hash` is indexed so dedup is a lookup, not an O(n) size loop.

---

### (b) Phased plan (each phase = one or more PRs; senior-review; device-test between)

**Phase A - Add the table + `DocumentRepository` (no behavior change).**
- Bump `_databaseVersion` in `storage_service.dart` (14 -> 15) and add the `documents` table in `_onUpgrade` (NOT only `_onCreate`, or existing installs never get it). New `documents` table is additive; `_onUpgrade` for v15 issues the `CREATE TABLE documents` + indexes.
- Add `lib/services/document_repository.dart` exposing per-row CRUD against `StorageService.database`: `insert(DocumentItem)`, `update(DocumentItem)`, `delete(id)`, `getById(id)`, `childrenOf(parentId)`, `findByContentHash(hash)`, `findBySourcePath(path)`. `childrenOf` is the replacement for `getFilesInFolder`'s `fileIds` filter.
- Add `DocumentItem.fromRow` / `toRow` (epoch-millis + UUID), keeping `fromJson`/`toJson` intact for the blob until Phase E.
- No reads switch yet. `DocumentService` still serves from `_items`/blob. **Risk: none to live data** (additive table, unused). Device-test: install over a populated v14 DB, confirm upgrade runs, library unchanged.

**Phase B - Dual-write.** Every `DocumentService` mutator that currently calls `_saveDocuments()` ALSO performs the equivalent per-row `DocumentRepository` call inside a single SQLite transaction:
- `addFile` -> `repo.insert(newItem)` (note: NO `fileIds` write; parent linkage is `parent_id` only).
- `addReference` -> unchanged (delegates to `addFile`); dedup still size-based here, fixed in Phase D.
- `moveFolderToFolder` -> `repo.update(folder.copyWith(parentId: newParentId))`.
- rename/delete/move-file -> matching `repo.update`/`repo.delete`.
Blob remains the source of truth for reads. Dual-write means the new table is continuously reconciled with live mutations so the Phase C backfill + cutover is seamless. **Risk: write amplification only.** If a repo write throws, log and continue (blob is still authoritative) - do NOT abort the user action in this phase.

**Phase C - Backfill from the prefs blob (idempotent, one-time, gated).**
- On startup, if `documents` row count is 0 and `SharedPreferences` key `documents_items` exists, decode the blob via the existing `DocumentItem.fromJson` and insert every item via `repo.insert`, in a single transaction.
- **Id remap**: legacy ids are `millisecondsSinceEpoch` strings and may collide (see (c)). Backfill mints a fresh UUID per legacy item, builds a `Map<legacyId, uuid>`, then rewrites `parent_id` through that map. `fileIds` is consulted ONLY as a fallback to recover a `parent_id` for any child whose own `parentId` was null but which appears in some folder's `fileIds` (heals the divergence during migration), then discarded.
- Set a `prefs` flag `documents_backfilled_v15 = true` so it never re-runs. **Risk: this is the data-bearing step.** Wrap in a transaction; on any exception, roll back and leave the blob untouched (reads still come from blob until Phase D).

**Phase D - Switch reads to the repository.** Point `DocumentService` getters (`getFilesInFolder`, `getSubfolders`, root listing, search) at `DocumentRepository` queries:
- `getFilesInFolder(folderId)` -> `repo.childrenOf(folderId).where(isFile)` (uses `parent_id`, the divergence bug is gone by construction).
- Dedup (`addReference`, `checkForDuplicates`) -> `repo.findByContentHash(sha256(bytes))`; size becomes a cheap pre-filter only. Hash lazily: compute on import and on first dedup check, persist into `content_hash`.
- `_items` becomes a cache hydrated from SQLite, not the store. **Risk: read-path semantics.** Keep dual-write ON through this phase so a rollback to Phase C reads is possible. Device-test folder listing, move, search, dedup against a backfilled DB.

**Phase E - Retire the blob.** Once D is stable in production: stop writing `documents_items`, remove `_saveDocuments`/`_documentsKey`, drop the `fileIds` field from `DocumentItem` (and `toJson`/`fromJson` references), delete the prefs key on a final migration. **Risk: irreversible.** Ship only after telemetry confirms zero backfill failures and read parity. Keep the blob deletion as the very last sub-step (a separate PR) so an emergency rollback before E can still read the blob.

---

### (c) Bugs this refactor SUBSUMES (with file:line evidence)

1. **Dual parent-model divergence.** Two sources of truth: `parentId` (child) and `fileIds` (parent), in `lib/models/document_item_model.dart`. `addFile` writes both; `moveFolderToFolder` writes only `parentId`; `getFilesInFolder` reads only `fileIds`. The single-parent `parent_id` schema in (a) makes the inconsistency unrepresentable. Evidence: `getFilesInFolder` filter `item.isFile && folder.fileIds.contains(item.id)` vs `moveFolderToFolder`'s `folder.copyWith(parentId: newParentId)` (no `fileIds` touch) - both quoted verbatim in section 0.

2. **`millisecondsSinceEpoch` id collisions.** `addFile`: `id: DateTime.now().millisecondsSinceEpoch.toString()`. Two items created within the same millisecond (e.g. a multi-file import loop) get the same id; `_items.indexWhere((item) => item.id == folderId)` and `fileIds.contains(item.id)` then alias the wrong row. UUIDv4 ids in (a) eliminate this.

3. **Whole-blob last-writer-wins.** `_saveDocuments` re-encodes all of `_items` and overwrites `documents_items` wholesale. Concurrent mutators (an import isolate finishing while the user renames in the UI) clobber each other; there is no per-row write and no CAS. Per-row `DocumentRepository` writes + `UPDATE ... WHERE id=?` make writes independent. Evidence: `_saveDocuments` quoted in section 0.

4. **Size-only dedup.** `addReference` (`if (srcLen == existingLen)`) and `checkForDuplicates` (`if (fileSize == existingSize)`) treat equal byte-count as identity. `content_hash` (sha256) with `idx_documents_hash` replaces this with true content identity (size as pre-filter). Evidence: both comparisons quoted verbatim in section 0.

---

### (d) Reconciliation with the `files_index` device-scan store

`DeviceDocumentService` already persists into SQLite (`files_index`, **path-keyed PRIMARY KEY**, `ON CONFLICT(path) DO UPDATE`), in the **same** `Database` from `StorageService` (version 14). Keep the two tables **separate with distinct identity domains** - do NOT merge:

- `files_index.path` (the on-device filesystem path) is the natural key for the **scan/discovery** store; rows are derived from a directory walk and are disposable (re-derivable by re-scanning).
- `documents.id` (UUID) is the **library/curation** store; rows represent user intent (imports, references, folder structure) and are authoritative.

The bridge between them is **`documents.source_path` -> `files_index.path`** (already indexed via `idx_documents_source`). This mirrors the existing `DocumentItem.sourcePath` semantics ("Storing ORIGINAL path", per `addFile`). Reconciliation rules:
- A library row's `missing_on_device` is computed by checking whether its `source_path` still exists in `files_index` (or on disk) - same flag both tables already carry (`files_index.missing_on_device`, `documents.missing_on_device`).
- A device-scan upsert must NEVER touch `documents` rows; the library is curated, not scan-derived. The two stores share a `Database` and a transaction boundary but not a table.
- Because both now live in one SQLite file, a future "where is this file in my library" lookup is a single join `documents JOIN files_index ON documents.source_path = files_index.path` - no cross-store reconciliation code, no blob parse.

> **WARNING / Data-safety (applies to every phase):**
> - This refactor moves the library's source of truth. Treat Phase C (backfill) and Phase E (blob retirement) as irreversible checkpoints; ship each as its own PR with a rollback path to the prior phase's reads.
> - Do **not** delete `documents_items` until Phase E is confirmed in production. Until then the blob is the recovery anchor.
> - All multi-row work (backfill, dual-write of parent+child, move) runs inside `db.transaction(...)`; partial writes must roll back.
> - **Crypto invariant (document passwords):** the password store is **out of scope** for this refactor and must remain on its existing path. The `document_passwords` map migrates **through the in-memory map of `PdfPasswordService` (its `_save()`), never raw prefs and never the new `documents` table.** Do not co-mingle encrypted password values into `documents`; library rows store no secrets. Any SQLite write-back of an encrypted value elsewhere uses single-writer compare-and-swap (`UPDATE ... WHERE id=? AND encrypted_value=<old>`), which this plan does not introduce into the library store.
> - Ids must come from a CSPRNG-backed UUID (`Random.secure`-seeded UUIDv4), never `millisecondsSinceEpoch`, to avoid both collisions and predictability.

**Tests (per phase):**
- Static: build per `.agent/rules/test.md` (`gradlew assembleDebug`, logged) after each PR.
- Unit: migration test that loads a fixture `documents_items` blob containing (i) two items sharing a `millisecondsSinceEpoch` id, (ii) a child present in a folder's `fileIds` but with null `parentId`, (iii) two distinct files of equal size; assert post-backfill that ids are unique UUIDs, the orphan is re-parented via `parent_id`, and the equal-size pair are NOT flagged as duplicates (distinct `content_hash`).
- Device (adb): install over a populated v14 DB, confirm `_onUpgrade` creates `documents`, exercise import / move folder / open folder / dedup, then `adb shell run-as <pkg> sqlite3` the DB to confirm row counts match the pre-migration blob item count.

**Key file paths (absolute, this workstation):**
- `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\lib\services\document_service.dart`
- `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\lib\services\storage_service.dart`
- `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\lib\services\device_document_service.dart`
- `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\lib\models\document_item_model.dart`
- New: `C:\Users\OYADLAPATI\source\repos\AI-LE\passwordpdf\lib\services\document_repository.dart`
