# PDF Password Manager — PENDING AGENT RUNBOOK (comprehensive hand-off)

> **Audience: the low/auto fix-agent, running unattended.** This is the SINGLE hand-off doc for every remaining bug + polish + feature on `experimental_flutter_upgrade` (currently **1.2.6+125 LIVE**). Grounded in an exhaustive audit of the actual GitHub branch — 63 verified findings across senior-runbook backlog, code TODOs, analyzer lint, latent bugs, UX/security polish, packaging/release hygiene, and concurrency/lifecycle corners.
>
> Work is grouped into **10 phases**, from lowest-risk to highest-touch. Each card = **one focused commit**. Between phases, run the debug APK on-device and confirm nothing regresses before moving on. Release 1.2.7+126 is Phase 9 (after everything else lands).
>
> If a card's `Locate` text does NOT appear verbatim, STOP and report — do NOT guess an edit location.

---

## 0. Ground rules (MANDATORY — bold items are non-obvious)

1. **Branch:** `experimental_flutter_upgrade`. Start each card with `git pull origin experimental_flutter_upgrade`.
2. **Toolchain:** Flutter/Dart via FVM (`fvm flutter …`). Package `com.passwordpdf.passwordpdf_manager`.
3. **One card = one commit + push, then STOP.** Do NOT batch, reorder, or skip.
4. **Verbatim `Locate` matching.** If the anchor text isn't found, STOP.
5. **NEVER `--no-verify`. NEVER `git push --force`. NEVER `git reset --hard`.** If a hook fails, fix the underlying issue and re-commit.
6. **Release builds go through `release_build.ps1` ONLY** (arm64-only, ~47 MB). NEVER raw `gradlew assembleRelease` (fat 90 MB APK) or `flutter build apk` (mis-reports failure).
7. **Between build and deploy: NEVER rebuild.** Release APKs are non-reproducible; each rebuild has a new sha256.
8. **Version bump lives in TWO files:** `pubspec.yaml` `version:` line AND `android/local.properties` (`flutter.versionName` + `flutter.versionCode`).
9. **NEVER touch the updater's `OpenFilex` calls** in `lib/features/update/services/update_service.dart` / `update_dialogs.dart` — those install APKs.
10. **NEVER touch `AndroidManifest.xml`'s `android:launchMode="singleTask"`** — that is load-bearing for the shipped Open-With intent fix.
11. **NEVER drop `MANAGE_EXTERNAL_STORAGE`** — the app is sideloaded (not on Play), the file scanner requires all-files access. Any card here that would touch that permission is a landmine — STOP.
12. **NEVER re-add `cachingDisabled = true`** or a wipe of `document_passwords` in `pdf_password_service.dart` — that scaffold was intentionally reverted before 1.2.4. Real users would lose PDF auto-unlock.
13. **Singletons:** `SettingsService()`, `DocumentService()`, `StorageService()`, `EncryptionService()`, `PasswordBackupService(...)`, `PasswordMigrationService(...)` — reuse; never `new` these.
14. **`// VERIFY API`** = confirm signature against the pinned pub.dev package example if analyze/build complains. Do NOT invent APIs. The app's OWN code in this runbook is given in full.

## 1. Non-negotiable invariants

1. **Offline only.** No cloud/server calls. No user document bytes leave the device.
2. **Wrong passphrase / wrong magic / corrupt file → modifies NOTHING.** Envelope validated first.
3. **KDF-clamp untrusted params BEFORE deriving** (mem 8*1024..256*1024 KiB, iter 1..10, par 1..4, salt 8..64).
4. **Magic separation:** docs backup = `DOCSETV1`; password backup = `PWDBAK`. Cross-decoding is rejected pre-derive with `FormatException`.
5. **Settings restore whitelist EXCLUDES:** `export_path` (device-local), `auth_method` (lockout), PIN (credential), `developer_mode_enabled` + `last_viewed_build_number` (internal). Already enforced in F-a's `importBackupMap`.
6. **Documents merge is id-preserving; never overwrite or orphan.**
7. **Recents restore strips the `id`** before upsert.
8. **Docs backup has NO dependency on the v2 key** — plaintext metadata under a passphrase envelope. Do NOT copy `adoptCurrentV2KeyAsHealthy` / `isKeySet` / `canWriteV2` guards.
9. **Atomicity:** parse+validate the entire decrypted payload into typed objects BEFORE the first write.
10. **Save-as-copy for user documents.** Any future edit path (Word/Excel — separate runbook) writes a new file, never overwrites the original.

## 2. What's already done (do NOT redo — verified against the branch)

- Crypto migration (Parts 1A/1B/1C) shipped in 1.2.4; wipe-detection + backup lockdown live.
- arm64-only APK via `release_build.ps1 -Ptarget-platform=android-arm64` (~47 MB) — 1.2.5 was superseded by 1.2.6.
- Both Open-With intent bugs fixed (Bug 1 cold-start race + Bug 2 stale replay), MainActivity `onNewIntent{setIntent;super}`, main.dart `_openInitialIntentAfterAuth` — shipped in 1.2.6.
- `SettingsService.exportBackupMap()` / `importBackupMap()` (F-a) — committed.
- `PdfPasswordService.cachingDisabled` scaffold — REVERTED (do not reintroduce).

## 3. Order of phases

- **Phase 0 — repo/build hygiene** (safe, mechanical). Includes fixing 2 landmines in `AGENT-RUNBOOK.md`.
- **Phase 1 — analyzer/lint sweep** (dozens of small mechanical fixes; low risk).
- **Phase 2 — deprecation cleanup** (importFile shim + dead widget file).
- **Phase 3 — Documents + Settings backup feature** (F-b + F-c + F-d).
- **Phase 4 — latent bug fixes** (data-loss traps + logging gaps).
- **Phase 5 — concurrency + lifecycle** (write mutex, ID collisions, subscription leak, overlay stacking).
- **Phase 6 — UX + security polish** (fresh-install flow, passphrase strength, permission rationale, message clarity).
- **Phase 7 — SENIOR-RUNBOOK Part 2 finish** (reorderPages → in-place `reArrange`).
- **Phase 8 — dev-mode Excel export re-enablement or gating**.
- **Phase 9 — release 1.2.7+126** (build + install → STOP for smoke test → deploy).

**Explicitly out of scope** (separate work / covered elsewhere): Word/Excel viewers (see `WORD-EXCEL-EDITING-RUNBOOK.md`), Store refactor A, real release signing key (blocked on complete backup + reinstall path), off-machine keystore backup copy (user-manual), R8/minify (needs proguard-rules audit), lossless mergePdf via pdfrx (senior-owned research spike).

---

## PHASE 0 — Repo & build hygiene

### CARD 0.1 — Delete empty stray `build.ps1`
`git rm build.ps1` (it's 0 bytes; check with `Get-Item build.ps1 | Select-Object Length` first — must be 0).
Commit: `chore: remove empty legacy build.ps1 (superseded by release_build.ps1)`.

### CARD 0.2 — Make `release_build.ps1` and `build_debug.ps1` portable
Both scripts hard-code `D:\Repos\passwordpdf`. Replace with `$PSScriptRoot`.

**File `release_build.ps1` — Locate:**
```
$root = 'D:\Repos\passwordpdf'
```
**Change:**
```
$root = $PSScriptRoot
```

**File `build_debug.ps1` — same substitution** wherever `D:\Repos\passwordpdf` appears in lines 3 and 5.

Self-check: `grep -n "D:\\\\Repos" release_build.ps1 build_debug.ps1` returns nothing (except a Windows path inside a `-Path` argument in the release script for the source APK — leave that; agents build on that machine anyway. The two `$root` assignments are the only ones we're changing).

Commit: `chore: make build scripts portable (use $PSScriptRoot instead of D:\Repos absolute path)`.

### CARD 0.3 — Harden `.gitignore` for Android per-machine + signing secrets
**File `.gitignore` — append at end of file:**
```
# Android per-machine + signing secrets (must never be committed)
**/android/local.properties
**/android/key.properties
**/android/**/*.jks
**/android/**/*.keystore
```
Verify: `git ls-files | grep -Ei 'local\.properties|key\.properties|\.jks$|\.keystore$'` returns empty.

Commit: `chore: gitignore Android per-machine + signing secrets`.

### CARD 0.4 — Add missing `package_info_plus` direct dependency
`main.dart` and `update_service.dart` both `import 'package:package_info_plus/package_info_plus.dart'` but `pubspec.yaml` does not list it — it currently resolves only transitively (fragile).

**File `pubspec.yaml` — Locate:**
```yaml
  crypto: ^3.0.3            # sha256 for key-health token + PIN PBKDF2 fallback
  cryptography: ^2.7.0      # AES-256-GCM (Task 15) + Argon2id (Tasks 16/19)
```
**Change (add right after):**
```yaml
  crypto: ^3.0.3            # sha256 for key-health token + PIN PBKDF2 fallback
  cryptography: ^2.7.0      # AES-256-GCM (Task 15) + Argon2id (Tasks 16/19)
  package_info_plus: ^8.0.0 # used by UpdateService + main.dart for version string
```
Then `fvm flutter pub get`.
Self-check: `fvm flutter pub deps | grep package_info_plus` shows one resolved version.

Commit: `chore: pin package_info_plus as direct dependency (was only transitive)`.

### CARD 0.5 — Neutralize AGENT-RUNBOOK Prompt 23 (Task 25 landmine)
`issues/AGENT-RUNBOOK.md` Prompt 23 / Task 25 tells a future agent to DROP `MANAGE_EXTERNAL_STORAGE`. That would brick the file scanner in this sideloaded app (invariant #11). Fix the runbook doc so no future agent runs it.

**File `issues/AGENT-RUNBOOK.md`:**
1. Search for "Task 25" and "Prompt 23". At the worklist section (around line 43), REMOVE the Task 25 entry from the numbered list.
2. Locate the "DO NOT ATTEMPT — senior-review only" block (around line 50-51) and add `25` to that list.
3. At the Prompt 23 body (around lines 2937-3033), REPLACE its entire body with this stub:
```md
### Prompt 23 / Task 25 — MOVED TO "DO NOT ATTEMPT"

This card previously proposed scoping storage permissions by dropping
`MANAGE_EXTERNAL_STORAGE`. That is a LANDMINE for this app:

- Sideloaded (not on Play), so scoped-storage policy does not apply here.
- The device-file scanner (`lib/services/device_document_service.dart`)
  requires all-files access to find PDFs / docs / xlsx in arbitrary paths.
- Dropping the permission bricks the primary scan feature with no user recourse.

**Do NOT apply. See `MEMORY.md` "MANAGE_EXTERNAL_STORAGE mandatory".**
```

Commit: `docs(agent-runbook): move Task 25 to DO NOT ATTEMPT (would drop mandatory MANAGE_EXTERNAL_STORAGE)`.

### CARD 0.6 — Neutralize AGENT-RUNBOOK Prompt 24 (Task 26 regressive)
Prompt 24 tells the agent to REGRESS `pdf_tools_service.dart` back to the `importPageRange` flatten path — undoing SENIOR-RUNBOOK Part 2's fix.

**File `issues/AGENT-RUNBOOK.md`:**
1. In the worklist, move Task 26 into the "DO NOT ATTEMPT" list.
2. At Prompt 24's body (around lines 3036-3471), REPLACE with this stub:
```md
### Prompt 24 / Task 26 — SUPERSEDED (senior owns PDF fidelity)

This card's `Change` blocks route through `importPageRange`, which
SENIOR-RUNBOOK.md Part 2 proved is the visual flatten (Syncfusion 32.x
has no true page import). The current `lib/services/pdf_tools_service.dart`
already ships the correct in-place fixes for `removePassword` and
`splitPdf`. Applying Prompt 24 as-written would REGRESS those.

The only remaining Part-2 work is `reorderPages` → `pages.reArrange()`,
which is owned by `PENDING-AGENT-RUNBOOK.md` Phase 7 (Card 7.1).

**Do NOT apply this card.** See SENIOR-RUNBOOK.md Part 2.
```

Commit: `docs(agent-runbook): move Task 26 to DO NOT ATTEMPT (would regress SENIOR Part 2 fidelity fix)`.

---

## PHASE 1 — Analyzer / lint sweep

Baseline check before starting: `fvm flutter analyze` — record the total issue count. Each card below should DROP that count by its stated amount.

### CARD 1.1 — Delete dead `lib/core/theme/app_theme.dart` + its dead imports
Nothing references `AppTheme.` anywhere. `main.dart` and `biometric_lock_screen.dart` import it but build `ThemeData` inline via `ColorScheme.fromSeed`.

Steps:
1. `git rm lib/core/theme/app_theme.dart`
2. In `lib/main.dart`, delete the line `import 'core/theme/app_theme.dart';` (around line 6).
3. In `lib/features/authentication/screens/biometric_lock_screen.dart`, delete the line `import '../../../core/theme/app_theme.dart';` (around line 5 — VERIFY exact import path).

Self-check: `grep -rn "AppTheme\|app_theme.dart" lib` returns empty.

Commit: `chore(lint): delete dead app_theme.dart (superseded by ColorScheme.fromSeed)`.

### CARD 1.2 — Remove unused imports in `lib/main.dart` (5 of the 6 imports; the AppTheme one already gone in 1.1)
**File `lib/main.dart` — remove these lines (VERIFY line numbers by grep):**
- `import 'features/password_manager/screens/password_manager_screen.dart';` (PasswordManagerScreen never referenced)
- `import 'features/documents/screens/pdf_viewer_screen.dart';` (PdfViewerScreen never referenced)
- `import 'features/documents/screens/folder_navigation_screen.dart';` (never referenced)
- `import 'package:passwordpdf_manager/features/documents/screens/file_system_browser.dart';` (never referenced)
- `import 'models/document_item_model.dart';` (never referenced directly)

Do NOT remove: StorageService, PermissionService, AllDocumentsScreen, or any 1-hit import you're not sure about — grep each before deleting: `grep -c "<symbol>" lib/main.dart` must be > 1 (import line + at least one usage) to keep it.

Self-check: `fvm flutter analyze lib/main.dart | grep -c "Unused import"` drops by 5.

Commit: `chore(lint): drop 5 unused imports in main.dart`.

### CARD 1.3 — Remove unused imports in `all_documents_screen.dart`
**File `lib/features/documents/screens/all_documents_screen.dart`** — delete these three lines (VERIFY line numbers):
- `import 'package:flutter/material.dart' as material;` (material.dart already imported without prefix)
- `import 'package:passwordpdf_manager/features/documents/screens/folder_navigation_screen.dart';` (unreferenced)
- `import 'package:passwordpdf_manager/features/documents/screens/file_system_browser.dart';` (unreferenced)

Commit: `chore(lint): drop 3 unused imports in all_documents_screen.dart`.

### CARD 1.4 — Remove unused/duplicate imports in `document_dashboard_screen.dart`
**File `lib/features/documents/screens/document_dashboard_screen.dart`** — delete:
- `import '../widgets/password_selection_dialog.dart';` (unreferenced)
- `import '../../common/utils/file_conflict_resolver.dart';` (unreferenced)
- `import 'folder_navigation_screen.dart';` (unreferenced)
- `import '../../../main.dart' show PendingFileOpen;` (DUPLICATE — the top-of-file `import '../../../main.dart';` already brings PendingFileOpen in)

Self-check after: `grep -n "PendingFileOpen" lib/features/documents/screens/document_dashboard_screen.dart` still resolves (usages preserved via the non-showing main.dart import).

Commit: `chore(lint): drop 4 unused/duplicate imports in document_dashboard_screen.dart`.

### CARD 1.5 — Remove unused imports in `settings_screen.dart`
**File `lib/features/settings/screens/settings_screen.dart`** — delete:
- `import '.../debug_logs_screen.dart';` (never referenced — the handler pushes DeveloperScreen instead)
- `import '.../update_info.dart';` (never referenced)

Commit: `chore(lint): drop 2 unused imports in settings_screen.dart`.

### CARD 1.6 — Remove unused imports elsewhere
- **`lib/features/password_manager/screens/password_manager_screen.dart`** — delete `import '../widgets/restore_file_picker.dart';` (already flagged in the previous runbook; the file will be deleted in Phase 2).
- **`lib/services/encryption_service.dart`** — delete `import 'dart:typed_data';` (no `Uint8List`/`ByteData`/`TypedData` references remain).

Commit: `chore(lint): drop unused restore_file_picker + dart:typed_data imports`.

### CARD 1.7 — `Color.withOpacity` → `.withValues(alpha:)` sweep (25 sites)
Deprecated in Flutter 3.27. Files affected (verify with `grep -rn "\.withOpacity(" lib` for the current list):
- `biometric_lock_screen.dart` (7 sites)
- `all_documents_screen.dart` (4 sites)
- `document_dashboard_screen.dart` (8 sites)
- `export_progress_screen.dart` (1 site)
- `file_system_browser.dart` (1 site)
- `password_manager_screen.dart` (1 site)
- `settings_screen.dart` (2 sites)
- `update_dialogs.dart` (1 site)

Mechanical rewrite per file — search-and-replace: `\.withOpacity(<expr>)` → `.withValues(alpha: <expr>)`. Preserve the expression inside the parentheses verbatim.

Self-check per file after each edit: `grep -c "withOpacity" <file>` = 0.

Commit ONCE at the end (single sweep is fine, all mechanical): `refactor(lint): Color.withOpacity → withValues(alpha:) (Flutter 3.27 deprecation)`.

### CARD 1.8 — `Color.value` → `.toARGB32()` (3 sites)
**Files + Locates (each is a single-line change):**

`lib/features/settings/services/settings_service.dart` line ~66 (inside `exportBackupMap`):
- `'accent_color': _accentColor.value,` → `'accent_color': _accentColor.toARGB32(),`

`lib/features/settings/services/settings_service.dart` line ~204 (inside `setAccentColor`):
- `... color.value ...` → `... color.toARGB32() ...`

`lib/features/settings/screens/settings_screen.dart` line ~312 (inside `_showHexColorInput`):
- `settings.accentColor.value.toRadixString(16)` → `settings.accentColor.toARGB32().toRadixString(16)`

**Do NOT change** the read path (`Color(accentColorInt)` from `SharedPreferences.getInt('accent_color')`) — the persisted int layout is identical.

Commit: `refactor(lint): Color.value → toARGB32() (Flutter 3.27 deprecation)`.

### CARD 1.9 — Delete dead `_performStartupChecks` in `_AppEntryState`
**File `lib/main.dart`** — search inside `class _AppEntryState extends State<AppEntry>` body (roughly lines 319-838) for a method named `_performStartupChecks`. It contains `await Future.delayed(Duration.zero);` and has a comment admitting it's dead. Delete the entire method definition (~10 lines).

**Do NOT** touch the identically-named method in `_MainScreenState` (later in the same file, around line 887) — that one IS called.

Self-check: inside the range 319-838, `sed -n '319,838p' lib/main.dart | grep -c _performStartupChecks` returns 0.

Commit: `chore(lint): remove dead _AppEntryState._performStartupChecks`.

### CARD 1.10 — Fix 2 `unnecessary_string_interpolations` + Automatically typo
**File `lib/features/documents/screens/all_documents_screen.dart` line ~483:**
- Locate: `'File "${fileName}" already exists'`
- Change: `'File "$fileName" already exists'`

**File `lib/features/documents/screens/document_dashboard_screen.dart` line ~957:**
- Locate: `'Multiple folders named "${folderName}" already exist.\n\nAutomtically rename existing folders to "${folderName}_1", "${folderName}_2", etc. to proceed?'`
- Change: `'Multiple folders named "$folderName" already exist.\n\nAutomatically rename existing folders to "${folderName}_1", "${folderName}_2", etc. to proceed?'`

Note: keep `${folderName}_1` and `${folderName}_2` — underscore is identifier-continuation, braces are REQUIRED there.

Commit: `chore(lint): drop unnecessary interpolation braces + fix Automtically typo`.

### CARD 1.11 — Add 3 `mounted` guards for `use_build_context_synchronously`
- **`lib/features/documents/screens/document_dashboard_screen.dart` ~line 2902** (SnackBar after `await _docService.syncFolder(...)` on 2903): before the `ScaffoldMessenger.of(context).showSnackBar(...)`, insert `if (!mounted) return;`.
- **`lib/features/documents/screens/export_progress_screen.dart` ~line 137** (catch block SnackBar after `await Share.shareXFiles(...)`): insert `if (!mounted) return;` before the ScaffoldMessenger call.
- **`lib/features/password_manager/widgets/encryption_key_setup_dialog.dart` ~line 98** (after `await encryptionService.setEncryptionKey(key)`): insert `if (!context.mounted) return;` before ScaffoldMessenger.

Commit: `chore(lint): add mounted guards for use_build_context_synchronously (3 sites)`.

### CARD 1.12 — Fix stale `// ignore: unused_local_variable`
**File `lib/features/update/widgets/update_dialogs.dart` line ~123:** delete the `// ignore: unused_local_variable` comment. The variable IS used at ~141 (assignment) and ~167 (read via `UpdateProgressDialog(progress: progress)`).

Commit: `chore(lint): drop stale ignore-unused-local (progress is used)`.

### CARD 1.13 — Delete stale internal-monologue comment block in folder-import
**File `lib/features/documents/screens/document_dashboard_screen.dart` lines ~1035-1058:** delete this stream-of-consciousness block (contains "Quick Hack" and "For now, let's just proceed..." lines). The working code below (`_docService.updateFolderSourcePath(...)` at ~1089) makes it obsolete.

Replace the deleted block with a single comment: `// Create root folder, import files, then persist sourcePath on the root for Sync.`

Commit: `chore(cleanup): remove stale folder-import internal-monologue comments`.

### CARD 1.14 — Remove unused `READ_MEDIA_IMAGES` permission
No image consumer exists (verified by grepping for `READ_MEDIA_IMAGES`, `ImagePicker`, `MediaStore.Images` in lib/ and android/). Delete the declaration to shrink the permissions surface.

**File `android/app/src/main/AndroidManifest.xml`** — delete the line:
```xml
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
```

Commit: `chore(security): drop unused READ_MEDIA_IMAGES permission`.

### CARD 1.15 — `fvm dart fix --apply` full sweep
After all the above, run:
```
fvm dart fix --dry-run   # preview
fvm dart fix --apply     # apply
fvm flutter analyze      # baseline check — should be significantly lower than start
```
Multiple files may be touched (that is expected). If any NEW `error` (not warning/info) appears, STOP and report.

Commit: `chore(lint): dart fix --apply sweep`.

---

## PHASE 2 — Deprecation cleanup

### CARD 2.1 — Delete dead `restore_file_picker.dart`
The file was already superseded by `FileSystemBrowser`. The Phase-1 unused-import removal (Card 1.6) already dropped the last import; now delete the file.

Steps:
1. `grep -rn "restore_file_picker\|RestoreFilePicker" lib --include=*.dart` → MUST be empty. If not, STOP.
2. `git rm lib/features/password_manager/widgets/restore_file_picker.dart`

Commit: `chore: remove dead restore_file_picker.dart (superseded by FileSystemBrowser)`.

### CARD 2.2 — Migrate `importFile` callers to `addReference`, delete deprecated shim
`DocumentService.importFile` is `@deprecated` and just redirects (with a `[LEGACY]` log line) to `addReference`.

Two callers in `lib/features/documents/screens/all_documents_screen.dart` (around lines 443 and 783). Replace each:
- Locate: `docService.importFile(<src>, <name>)` (may pass `allowDuplicate: <bool>`).
- Change: `docService.addReference(<src>, <name>, allowDuplicate: <bool>)` — keep the same params. If the caller passes no `allowDuplicate`, default it to `false`.

Then in `lib/services/document_service.dart`, delete the `importFile` method entirely (around line 412-419) INCLUDING the `@deprecated` docblock.

Self-check: `grep -rn "importFile" lib --include=*.dart` returns empty.

Commit: `chore: migrate importFile callers to addReference; drop deprecated shim`.

---

## PHASE 3 — Documents + Settings backup (F feature)

### CARD 3.1 — F-b: `DocumentService.mergeFromBackup`
**File `lib/services/document_service.dart`** — Locate (verbatim):
```dart
  List<DocumentItem> getAllItems() => List.unmodifiable(_items);
```

Replace with the same line plus the new method. **Full replacement block:**
```dart
  List<DocumentItem> getAllItems() => List.unmodifiable(_items);

  /// Merge document items from a backup into the current library. Id-preserving,
  /// relationship-repairing: NEVER overwrites or orphans an existing item.
  ///  - dedup: files by sourcePath, folders by (name + parentId);
  ///  - added items get FRESH unique ids;
  ///  - folder membership (fileIds) reconstructed from resolved parentId,
  ///    unioned with existing children;
  ///  - refs that resolve to nothing are dropped (dangling parent -> unorganized).
  /// Returns the number of items added.
  Future<int> mergeFromBackup(List<DocumentItem> incoming) async {
    await initialize();

    final existingIds = _items.map((e) => e.id).toSet();
    final existingFileByPath = <String, DocumentItem>{};
    final existingFolderByKey = <String, DocumentItem>{};
    for (final e in _items) {
      if (e.isFolder) {
        existingFolderByKey['${e.name}|${e.parentId ?? ''}'] = e;
      } else if (e.sourcePath != null && e.sourcePath!.isNotEmpty) {
        existingFileByPath[e.sourcePath!] = e;
      }
    }

    final usedIds = {...existingIds};
    final idMap = <String, String>{};
    final additions = <String, DocumentItem>{};
    var seq = DateTime.now().microsecondsSinceEpoch;
    String freshId() {
      var c = (seq++).toString();
      while (usedIds.contains(c)) {
        c = (seq++).toString();
      }
      usedIds.add(c);
      return c;
    }

    for (final item in incoming) {
      DocumentItem? dup;
      if (item.isFolder) {
        dup = existingFolderByKey['${item.name}|${item.parentId ?? ''}'];
      } else if (item.sourcePath != null && item.sourcePath!.isNotEmpty) {
        dup = existingFileByPath[item.sourcePath!];
      }
      if (dup != null) {
        idMap[item.id] = dup.id;
        continue;
      }
      final fid = freshId();
      idMap[item.id] = fid;
      additions[fid] = item;
    }
    if (additions.isEmpty) return 0;

    String? resolveRef(String? ref) {
      if (ref == null) return null;
      final m = idMap[ref];
      if (m != null) return m;
      if (existingIds.contains(ref)) return ref;
      return null;
    }

    final built = <DocumentItem>[];
    additions.forEach((fid, item) {
      built.add(DocumentItem(
        id: fid,
        name: item.name,
        type: item.type,
        sourcePath: item.sourcePath,
        parentId: resolveRef(item.parentId),
        fileIds: const [],
        size: item.size,
        createdAt: item.createdAt,
        modifiedAt: item.modifiedAt,
        isImported: item.isImported,
        isImportedFile: item.isImportedFile,
        isNew: item.isNew,
        missingOnDevice: item.missingOnDevice,
        addedAt: item.addedAt,
        lastSynced: item.lastSynced,
      ));
    });
    _items.addAll(built);

    final touched = <String>{};
    for (final f in built) {
      if (f.isFile && f.parentId != null) touched.add(f.parentId!);
    }
    for (final folderId in touched) {
      final idx = _items.indexWhere((e) => e.id == folderId && e.isFolder);
      if (idx == -1) continue;
      final kids = <String>{..._items[idx].fileIds};
      for (final e in _items) {
        if (e.isFile && e.parentId == folderId) kids.add(e.id);
      }
      _items[idx] = _items[idx].copyWith(fileIds: kids.toList());
    }

    await _saveDocuments();
    return built.length;
  }
```

Self-check: `grep -c "mergeFromBackup" lib/services/document_service.dart` = 1; `fvm flutter analyze lib/services/document_service.dart` clean.

Commit: `feat(F-b): DocumentService.mergeFromBackup (id-preserving, relationship-repairing)`.

### CARD 3.2 — F-c: New `DocsSettingsBackupService`
**File (NEW):** `lib/services/docs_settings_backup_service.dart`

Create with EXACTLY this content:
```dart
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
```

Self-check: `grep -n "DOCSETV1\|adoptCurrentV2KeyAsHealthy\|canWriteV2\|isKeySet" lib/services/docs_settings_backup_service.dart` must show `DOCSETV1` and NOT the other three (invariant #8).

Commit: `feat(F-c): DocsSettingsBackupService — magic DOCSETV1, KDF-clamp, atomic restore`.

### CARD 3.3 — F-d: Settings screen "Backup & Restore" section
**File `lib/features/settings/screens/settings_screen.dart`**

**Change (a) — add imports near the top of the file (do NOT duplicate any that already exist):**
```dart
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../services/document_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/docs_settings_backup_service.dart';
import '../../documents/screens/file_system_browser.dart';
```

**Change (b) — inside `_SettingsScreenState`, add three methods immediately BEFORE `Widget build(BuildContext context) {` (around line ~397 — locate and insert above it):**
```dart
  Future<String?> _promptDocsBackupPassphrase({required bool confirm}) async {
    final one = TextEditingController();
    final two = TextEditingController();
    var obscure = true;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSt) {
          return AlertDialog(
            title: Text(confirm ? 'Create backup passphrase' : 'Enter passphrase'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (confirm)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'This passphrase is the ONLY way to restore this backup. '
                        'It cannot be recovered. Store it somewhere safe.',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  TextField(
                    controller: one,
                    autofocus: true,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'Passphrase',
                      suffixIcon: IconButton(
                        icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setSt(() => obscure = !obscure),
                      ),
                    ),
                  ),
                  if (confirm) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: two,
                      obscureText: obscure,
                      decoration: const InputDecoration(labelText: 'Confirm passphrase'),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final a = one.text;
                  final b = two.text;
                  if (a.length < 8) return;         // strength minimum
                  if (confirm && a != b) return;
                  Navigator.pop(ctx, a);
                },
                child: const Text('OK'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _onDocsBackup() async {
    final pass = await _promptDocsBackupPassphrase(confirm: true);
    if (pass == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final svc = DocsSettingsBackupService(
          SettingsService(), DocumentService(), StorageService());
      final bytes = await svc.createBackup(pass);
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final fname = 'docs-settings-backup-$ts.json';

      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save your backup'),
          content: const Text(
              'The file is encrypted with your passphrase. Anyone with BOTH the file and the passphrase can restore your data.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save to device')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'share'), child: const Text('Share')),
          ],
        ),
      );
      if (choice == 'save') {
        final dir = Directory(p.join(SettingsService().exportPath, 'Backup'));
        await dir.create(recursive: true);
        final out = File(p.join(dir.path, fname));
        await out.writeAsBytes(bytes, flush: true);
        if (!mounted) return;
        messenger.showSnackBar(SnackBar(content: Text('Saved: ${out.path}')));
      } else if (choice == 'share') {
        final tmp = await getTemporaryDirectory();
        final file = File(p.join(tmp.path, fname));
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles([XFile(file.path)],
            subject: 'Documents & Settings Backup');
      }
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      LoggingService().error('Settings', 'Docs backup failed', e);
      messenger.showSnackBar(const SnackBar(content: Text('Backup failed. Check Developer > Logs.')));
    }
  }

  Future<void> _onDocsRestore() async {
    final backupDir = Directory(p.join(SettingsService().exportPath, 'Backup'));
    final initialPath = backupDir.existsSync()
        ? backupDir.path
        : (Directory('/storage/emulated/0/Download').existsSync()
            ? '/storage/emulated/0/Download'
            : null);
    final paths = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FileSystemBrowser(
          initialPath: initialPath,
          allowedExtensions: const ['json'],
          allowMultiple: false,
        ),
      ),
    );
    if (paths == null || paths.isEmpty || !mounted) return;
    final path = paths.first;

    final pass = await _promptDocsBackupPassphrase(confirm: false);
    if (pass == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await File(path).readAsBytes();
      final svc = DocsSettingsBackupService(
          SettingsService(), DocumentService(), StorageService());
      final result = await svc.restoreFromBytes(bytes, pass);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(
          'Restored: settings applied, ${result.documentsAdded} document(s) added, ${result.recentsAdded} recent(s).',
        ),
      ));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      LoggingService().error('Settings', 'Docs restore failed', e);
      messenger.showSnackBar(const SnackBar(content: Text('Restore failed. Check Developer > Logs.')));
    }
  }
```

**Change (c) — add the section above "About".** Locate (verbatim):
```dart
          // About Section
          _buildSectionHeader('About'),
```
Replace with:
```dart
          _buildSectionHeader('Backup & Restore'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Backup Documents & Settings'),
                  subtitle: const Text('Encrypted with a passphrase; saved as .json'),
                  onTap: _onDocsBackup,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: const Text('Restore Documents & Settings'),
                  subtitle: const Text('Merges documents; replaces settings'),
                  onTap: _onDocsRestore,
                ),
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Password backup lives under Password Manager → Backup'),
                  dense: true,
                ),
              ],
            ),
          ),

          // About Section
          _buildSectionHeader('About'),
```

Self-checks:
```
grep -n "_onDocsBackup\|_onDocsRestore\|_promptDocsBackupPassphrase\|Backup & Restore" lib/features/settings/screens/settings_screen.dart
fvm flutter analyze lib/features/settings/screens/settings_screen.dart
```

Commit: `feat(F-d): Settings 'Backup & Restore' section (Documents + Settings)`.

---

## PHASE 4 — Latent bug fixes (data-loss traps + logging gaps)

### CARD 4.1 — PdfPasswordService.initialize: preserve corrupt JSON before writing empty
The catch at ~lines 36-38 silently blanks the map; the next `_save()` writes `{}` — permanent loss. Preserve the raw string first, gate future writes.

**File `lib/services/pdf_password_service.dart` — Locate (verbatim):**
```dart
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
```
**Replace with:**
```dart
  bool _loadFailed = false;

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
```
And in the `_save()` method, add at the very top: `if (_loadFailed) return;`

Commit: `fix(pdf-pw): preserve corrupt blob on load fail, gate writes to prevent silent nuke`.

### CARD 4.2 — DocumentService._saveDocuments: report write failure + backup previous JSON
Currently the catch just logs; callers think mutation persisted.

**File `lib/services/document_service.dart`** — Locate `Future<void> _saveDocuments() async {`. Change signature to `Future<bool> _saveDocuments() async {` and body:
- Before the write, read the current stored JSON string and write it to a rolling backup pref `${_documentsKey}_bak`.
- On success return `true`; in catch, log and return `false`.

Also update `initialize()` / `_loadDocuments` if it currently accesses `documents_items_bak` — otherwise leave the bak untouched (it's a passive safety net).

**Do NOT** change any public method's signature. This card only refactors the private save.

Commit: `fix(doc-service): _saveDocuments returns bool + writes rolling bak (silent-loss defense)`.

### CARD 4.3 — PasswordMigrationService: poison-row tracking
A permanently-undecryptable row currently pins `_sweepDoneKey=false` forever → every launch re-scans + re-decrypts + re-encrypts every row.

**File `lib/services/password_migration_service.dart`** — Locate the class + `migrateLegacyToV2`. Add:
- Constant `static const String _poisonKey = 'pw_v2_poison_ids_v1';`
- Load `Set<int>` of poison ids from prefs at the top of the migration.
- Skip rows whose id is in the poison set (don't count them toward `v1remaining`).
- Track per-run counter for each row that fails; if it fails more than N=3 launches, add its id to `_poisonKey`.

Set `_sweepDoneKey=true` when `v1remaining == 0` (poison rows are excluded from this count).

Commit: `fix(pw-migrate): poison-row tracking so a bad row can't pin re-sweep forever`.

### CARD 4.4 — PdfPasswordService: v1→v2 sweep for stored PDF passwords
`document_passwords` still holds XOR-era ciphertext. Migration only covered the SQL passwords table.

**File `lib/services/pdf_password_service.dart`** — add new method:
```dart
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
```

Wire it in `main.dart` right after the existing `PasswordMigrationService(...).migrateLegacyToV2()` fire-and-forget block (search for that block; put `PdfPasswordService().migratePdfPasswordsToV2()` in the same fire-and-forget pattern).

Commit: `feat(pdf-pw): v1→v2 sweep for stored PDF passwords (idempotent, fire-and-forget)`.

### CARD 4.5 — PdfPasswordService: fix alias-migration doubling
The filename-fallback path adds a new key without removing the old one → duplicates.

**File `lib/services/pdf_password_service.dart`** — locate the block inside `getPasswordForDocument` around lines 55-68 where the filename-fallback matches. Find the line `_documentPasswords[filePath] = encryptedPassword;` and immediately BEFORE that line, add:
```dart
        // Remove the old alias so the map stays single-entry-per-file.
        _documentPasswords.remove(entry.key);
```
(`entry` is the matching MapEntry.)

Then move `await _save();` to fire AFTER both operations.

Commit: `fix(pdf-pw): alias migration deletes the old key (was doubling entries on move)`.

### CARD 4.6 — UpdateService: hard-fail on missing sha256 in manifest
Currently a missing sha256 silently skips verification.

**File `lib/features/update/services/update_service.dart`** — find the block around lines 201-216 that logs "No expected sha256 supplied; skipping checksum verification". Replace that branch with:
- Log `_log.error('UpdateService', 'Manifest missing sha256; refusing to install unverified APK');`
- Delete the downloaded file.
- Return `null`.

Commit: `fix(update): hard-fail install when version.json omits sha256 (was silently skipped)`.

### CARD 4.7 — PDF viewer: log wrong-password attempts
**File `lib/features/documents/screens/pdf_viewer_screen.dart`** — around lines 100-140 (`_getPassword` callback). When `_passwordAttempted && _candidateIndex > 0`, add a `_log.warn('PdfViewer', 'PDF password candidate ${_candidateIndex} failed');` before returning the next candidate.

Commit: `chore(pdf-viewer): log wrong-password attempts (was silent)`.

### CARD 4.8 — Delete dead `_lastConsumedIntentPath`
Written twice but never read. `main.dart`.

Remove the field declaration at ~line 330, the two assignments (~line 372 in `_checkInitialIntents`, ~line 409 in `_handleSharedFiles`), and the log line at ~line 378.

Self-check: `grep -c "_lastConsumedIntentPath" lib/main.dart` = 0.

Commit: `chore(main): remove dead _lastConsumedIntentPath (was written but never read)`.

---

## PHASE 5 — Concurrency + lifecycle

### CARD 5.1 — DocumentService write mutex + unique IDs
`ms-timestamp` IDs can collide inside the multi-file share loop; concurrent `addFile()` calls can drop items.

**File `lib/services/document_service.dart`:**
1. Add fields:
```dart
  Future<void> _writeLock = Future.value();
  int _idCounter = 0;
  String _newId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';
```
2. Replace every `DateTime.now().millisecondsSinceEpoch.toString()` used as an item id (inside `createFolder`, `addFile`, `addReference`) with `_newId()`.
3. Wrap the body of `addFile`, `addReference`, `createFolder`, `addFileToFolder`, `removeFileFromFolder`, `renameItem`, `moveFolder`, `deleteItem`, and any other public mutator that ends in `_saveDocuments()`:
```dart
  Future<T> _serialize<T>(Future<T> Function() body) {
    final result = _writeLock.then((_) => body());
    _writeLock = result.then((_) => null, onError: (_) => null);
    return result;
  }
```
Then change each mutator to `return _serialize(() async { ... existing body ... });`.

Commit: `fix(doc-service): serialize writes + unique IDs (was ms-timestamp collisions + race)`.

### CARD 5.2 — Auto-lock overlay: prevent stacking
**File `lib/main.dart`** — inside `didChangeAppLifecycleState`'s resumed branch (around lines 725-745): add a static/instance flag `bool _lockOverlayShowing = false;` on `_AppEntryState`. Set it `true` immediately BEFORE `Navigator.of(context).push(PageRouteBuilder(...))`, and inside the `onAuthenticated` callback set it `false` BEFORE `Navigator.of(context).pop()`. Guard the whole `.push` block: `if (_lockOverlayShowing) return;`.

Commit: `fix(main): guard biometric auto-lock overlay against stacking on repeated resumes`.

### CARD 5.3 — Queue `_handleSharedFiles` instead of dropping
**File `lib/main.dart`** — replace the boolean `_isProcessingIntent` with a queue.

Fields:
```dart
  final List<List<SharedMediaFile>> _pendingIntentQueue = [];
  bool _intentDraining = false;
```
Public entry:
```dart
  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    _pendingIntentQueue.add(files);
    if (_intentDraining) return;
    _intentDraining = true;
    try {
      while (_pendingIntentQueue.isNotEmpty) {
        final batch = _pendingIntentQueue.removeAt(0);
        await _processSharedFilesBatch(batch);
      }
    } finally {
      _intentDraining = false;
    }
  }
```
Rename the current `_handleSharedFiles` body to `_processSharedFilesBatch(List<SharedMediaFile> files) async {...}` (keep all the existing logic verbatim).

Commit: `fix(main): queue shared-intent batches (was silently dropping overlapping shares)`.

### CARD 5.4 — Capture `getMediaStream` subscription; cancel in dispose
**File `lib/main.dart`** — add field `StreamSubscription<List<SharedMediaFile>>? _intentSub;` and change the `getMediaStream().listen(...)` at ~line 353 to `_intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(...)`. In `dispose()` (~line 687), add `_intentSub?.cancel();` before `super.dispose()`. Add import `import 'dart:async';` if not present.

Commit: `chore(main): cancel intent-stream subscription in dispose (hot-restart safety)`.

### CARD 5.5 — Cached-future initialize() on 3 singletons
For each of `SettingsService.initialize`, `DocumentService.initialize`, `ExportQueueService.init`: wrap with the cached-future pattern:
```dart
  Future<void>? _initFuture;
  Future<void> initialize() => _initFuture ??= _doInit();
  Future<void> _doInit() async { /* existing body */ }
```
(rename the existing body accordingly).

Commit: `chore(services): cached-future initialize() on Settings/Document/ExportQueue singletons`.

---

## PHASE 6 — UX + security polish

### CARD 6.1 — Skip legacy XOR key setup on fresh installs
The current gate at `main.dart` ~line 894 uses `isKeySet()` which reads the LEGACY key slot — fresh installs get forced into a misleading dialog even though v2 is already healthy.

**File `lib/main.dart`** — find `_performStartupChecks` in `_MainScreenState` (around line 887+). The current guard is `if (!hasKey)`. Change to only prompt if BOTH conditions hold: legacy key is missing AND `canWriteV2` is false. Concretely:
```dart
    final hasLegacy = await encryptionService.isKeySet();
    if (!hasLegacy && !encryptionService.canWriteV2) {
      final success = await showEncryptionKeySetupDialog(context, force: true);
      ...
    }
```
Also in `lib/features/password_manager/widgets/add_password_dialog.dart` (~lines 54-63): replace the setup-dialog invocation with a simple `if (!encryptionService.canWriteV2) { snackbar('Encryption not ready — try again'); return; }`.

Commit: `fix(ux): skip legacy XOR key setup on fresh installs (v2 already healthy)`.

### CARD 6.2 — Rewrite `encryption_key_setup_dialog.dart` copy
**File `lib/features/password_manager/widgets/encryption_key_setup_dialog.dart`** — update body text (~lines 34-39 and 76-79):
- Old (misleading): 'Your encryption key will be used to secure all password values.' / '⚠️ Remember this key! You cannot recover it if lost.'
- New: 'Legacy compatibility key (only needed if you have passwords saved before v1.2.6). Skip if this is a fresh install.'

Add a prominent "Skip" button in the dialog actions that pops with `null`.

Commit: `chore(ux): fix encryption_key_setup_dialog copy (legacy-only, not the real crypto)`.

### CARD 6.3 — Backup passphrase warning + reveal toggle + min length
**File `lib/features/password_manager/screens/password_manager_screen.dart`** — inside `_promptPassphrase` (~line 32-96):
- Add a red-tinted line at top when `confirm==true`: `'This passphrase is the ONLY way to restore this backup. It cannot be recovered. Store it in a password manager.'`
- Add a reveal-eye `IconButton` (Icons.visibility / visibility_off) as `suffixIcon` on both TextFields (state via StatefulBuilder).
- OK button disabled unless `a.length >= 8` (and `a == b` when confirming).

Commit: `feat(ux): passphrase dialog — warning, reveal toggle, 8-char min`.

### CARD 6.4 — Better applyRestore result surfacing
**File `lib/services/password_backup_service.dart`** — change `applyRestore` to return a small result object (or `Map<String, int>`) with `{imported, skipped}`.

**File `lib/features/password_manager/screens/password_manager_screen.dart`** — in `_onRestore`, if `skipped > 0` show a follow-up dialog: `'Imported $imported. Skipped $skipped passwords because the device key could not encrypt them. Check Developer > Logs.'`

Commit: `feat(ux): restore surfaces skipped rows (was silently dropping)`.

### CARD 6.5 — MANAGE_EXTERNAL_STORAGE first-run rationale
**File `lib/services/permission_service.dart`** — before calling the raw system permission request for `Permission.manageExternalStorage`, check a SharedPreferences bool `has_seen_storage_rationale`. If false, show a dialog first (via the AppEntry navigator key):
- Title: "All-Files Access"
- Body: "PDF Manager scans your device to find PDFs, Word, and Excel files. Android requires All-Files-Access to do this. Nothing leaves your phone."
- Buttons: [Not now] / [Grant Access]

Only proceed to the system permission if the user taps Grant Access. On permanent-deny (`.isPermanentlyDenied`), surface a persistent banner on the docs screen linking to `openAppSettings()`.

Commit: `feat(ux): MANAGE_EXTERNAL_STORAGE rationale dialog on first run`.

### CARD 6.6 — Dev-mode error SnackBars: use error color, not accent
**File `lib/features/developer/screens/developer_screen.dart` lines ~741-743 and ~847-849:** replace `backgroundColor: settings.accentColor` with `backgroundColor: Theme.of(context).colorScheme.error`.

Commit: `chore(ux): dev error snackbars use theme error color (accent was unreadable)`.

### CARD 6.7 — Remove version-tap developer-mode hint
**File `lib/features/settings/screens/settings_screen.dart` ~lines 826-834** (inside App Version onTap): delete the `else if (_versionTapCount >= 3)` block that shows "N taps to unlock developer mode". Keep the silent 5-tap trigger.

Commit: `chore(security): remove developer-mode unlock hint SnackBar (was broadcasting entry)`.

### CARD 6.8 — Redact raw exception strings in restore/backup snackbars
**File `lib/features/password_manager/screens/password_manager_screen.dart`** — in `_onRestore` catch (~line 230-234) and `_onBackup` catch (~line 155-160): replace `'Restore failed: $e'` / `'Backup failed: $e'` with a fixed message and log to `_log.error`:
```dart
    LoggingService().error('PasswordManager', 'restore failed', e);
    messenger.showSnackBar(const SnackBar(content: Text('Restore failed. Check Developer > Logs for details.')));
```
(same for backup.)

Commit: `chore(ux): redact raw exception in backup/restore snackbars (log to dev logs instead)`.

### CARD 6.9 — Update "Public Release Channel" jargon
**File `lib/features/settings/screens/settings_screen.dart` ~lines 989-993** (`_checkForUpdates` up-to-date message): replace `'App is up to date based on Public Release Channel'` with `"You're on the latest version."`.

Commit: `chore(ux): plain-English update message`.

### CARD 6.10 — Rewrite "Secure & Private" info box
**File `lib/features/settings/screens/settings_screen.dart` ~lines 944-981** (Security Info container): replace body text with:
```
Your passwords are encrypted with AES-256-GCM using a key stored in Android's hardware-backed Keystore. Documents stay on this device. Use Password Manager → Backup to save a passphrase-encrypted copy in case this device is lost or reset.
```

Commit: `chore(ux): security info box mentions AES-256-GCM + Keystore + passphrase backup`.

### CARD 6.11 — Pre-install rationale for REQUEST_INSTALL_PACKAGES
**File `lib/features/update/widgets/update_dialogs.dart`** — before the actual install trigger, show an AlertDialog:
- Title: "Android install permission"
- Body: "Android will now ask permission to install updates from PDF Manager. This is normal for apps installed outside the Play Store. You can revoke it in Settings > Apps > PDF Manager > Install unknown apps."
- Buttons: Cancel / Continue (Continue proceeds to the current install call).

Commit: `feat(ux): rationale dialog before REQUEST_INSTALL_PACKAGES system prompt`.

---

## PHASE 7 — SENIOR-RUNBOOK Part 2 finish

### CARD 7.1 — `reorderPages` → in-place `pages.reArrange()` + remove flatten warning
**File `lib/services/pdf_tools_service.dart`** — locate `reorderPages` (around lines 139-185). Replace its body's `newDocument`/`importPageRange` loop with a single call:
```dart
    document.pages.reArrange(pageOrder); // VERIFY API — Syncfusion 32.x
    await document.save(...);            // existing save target
```
No more `newDocument`; no more `confirmedFlatten` parameter. Remove the `_hasInteractiveContent` check.

Then delete the `willFlattenOnReorder` method entirely (around lines 14-31).

**File `lib/features/documents/screens/pdf_viewer_screen.dart` lines ~547-565:** delete the pre-check + confirmation-dialog block that gated on `willFlattenOnReorder`. Then the call to `reorderPages(...)` at ~line 567 must drop the `confirmedFlatten:` named arg.

**Do NOT** touch `willFlattenOnMerge` or the merge confirmation dialog — mergePdf legitimately still flattens until the pdfrx spike.

Self-check: `grep -rn "willFlattenOnReorder\|confirmedFlatten" lib` returns empty.

Commit: `feat(pdf): reorderPages in-place via pages.reArrange (Task 26.1 finish; drops flatten warning)`.

---

## PHASE 8 — Dev-mode Excel export re-enable or gating

### CARD 8.1 — Gate the two "Export to Excel" dev-mode buttons that currently throw
Both `_processExcelJob` and `_processLogsJob` in `lib/services/export_queue_service.dart` throw "temporarily unavailable" due to a pdfrx-dependency conflict. Two options:

**Chosen (safer): hide the buttons.**
- **File `lib/features/developer/screens/developer_screen.dart` ~line 974** (Database Export button): wrap the button in `if (false) ...` OR delete the ListTile/Button, replacing it with a `ListTile(title: Text('Database Excel export — temporarily disabled'), enabled: false, subtitle: Text('Pending dependency resolution.'))`.
- **Same file line ~360** (`_exportLogs` trigger): change the "Logs Excel export queued" snackbar to "Logs Excel export is temporarily disabled." and NOT enqueue the job.

**Do NOT** delete the `_processExcelJob` / `_processLogsJob` service methods — leave them + their TODO for the future re-enable.

Commit: `chore(dev): disable buttons for the two 'temporarily unavailable' Excel exports`.

---

## PHASE 9 — Release 1.2.7+126 (build + install → STOP → deploy)

### CARD 9.1 — Test debug build after all preceding phases
```
git pull origin experimental_flutter_upgrade
adb devices                                                 # RZ8N90X627R; else STOP
cd android; cmd /c ".\gradlew.bat assembleDebug"            # must BUILD SUCCESSFUL
adb install -r -d "android\app\build\outputs\apk\debug\app-debug.apk"
```
Report result. **STOP.** User runs the on-device validation checklist below before Card 9.2.

**On-device validation (user runs this on the debug build):**
1. **Documents+Settings backup:** Settings → Backup Documents & Settings → set an 8+-char passphrase → Save to device. A `docs-settings-backup-*.json` appears under `Download/PDF Manager/Backup/`.
2. Change some settings (theme, accent color) + add a new doc.
3. Restore Documents & Settings → pick the backup → passphrase → confirms "settings applied; N document(s) added; M recent(s)".
4. Settings snap back; documents still there; no duplicates; `export_path` UNCHANGED (excluded).
5. **Cross-restore rejection:** try to restore a password backup file via this Settings restore → clean error.
6. **Regressions:** open a saved password PDF; Password Manager Backup/Restore still works; PDF from Gmail opens first-try (Bug-1 fix); Open-With PDF-A → Home → Open-With PDF-B → B opens (Bug-2 fix).
7. **UX polish:** fresh-install-like path (clear app data first if needed) does NOT force the legacy encryption-key dialog. Version-tap SnackBar no longer says "N taps to unlock developer mode".
8. **PDF tools:** reorder pages on a form-bearing PDF → confirm form fields survive (Card 7.1).
9. **Dev mode:** the disabled Excel-export buttons say "temporarily disabled" and do not crash.
10. `adb logcat -d | grep -iE "Password migration|pdf_pw_sweep|migratePdfPasswordsToV2"` shows either "N row(s) -> v2" or nothing (sweep already done).

### CARD 9.2 — Release build 1.2.7+126
Bump `pubspec.yaml`: `version: 1.2.6+125` → `version: 1.2.7+126`. Bump `android/local.properties` to match (`flutter.versionName=1.2.7`, `flutter.versionCode=126`).

```
git add pubspec.yaml
git commit -m "release: bump to 1.2.7+126"
git push origin experimental_flutter_upgrade
git log -1 --pretty=format:%H

git checkout -- release_build.ps1
powershell -ExecutionPolicy Bypass -File .\release_build.ps1
# Wait for '=== RESULT: RELEASE BUILD SUCCESSFUL ==='. Note APK path, SIZE (~47MB), SHA256.
# If SIZE ~90MB or it FAILS, STOP.

adb install -r -d "<APK path>"
```
Report. **STOP.** User re-runs the validation checklist on the RELEASE build.

### CARD 9.3 — Deploy to passwordpdf-releases (only after user says "deploy")
```
cd <local passwordpdf-releases clone>
git pull

powershell -Command "(Get-FileHash -Algorithm SHA256 'D:\Repos\passwordpdf\android\app\build\outputs\apk\release\app-release.apk').Hash.ToLower()"
# must equal Card 9.2 SHA256; else STOP

New-Item -ItemType Directory -Force -Path 'releases\v1.2.7' | Out-Null
Copy-Item 'D:\Repos\passwordpdf\android\app\build\outputs\apk\release\app-release.apk' 'releases\v1.2.7\app-release.apk'

powershell -Command "(Get-FileHash -Algorithm SHA256 'releases\v1.2.7\app-release.apk').Hash.ToLower()"
# must equal Card 9.2 SHA256; else STOP

# Write version.json (own-hash, no BOM). Release notes describe user-visible changes.
powershell -Command "$a='releases\v1.2.7\app-release.apk'; $h=(Get-FileHash -Algorithm SHA256 $a).Hash.ToLower(); $j='{' + \"`n\" + '    \"version\": \"1.2.7\",' + \"`n\" + '    \"buildNumber\": 126,' + \"`n\" + '    \"downloadUrl\": \"https://github.com/worlon-code/passwordpdf-releases/raw/main/releases/v1.2.7/app-release.apk\",' + \"`n\" + '    \"sha256\": \"' + $h + '\",' + \"`n\" + '    \"releaseNotes\": \"Update v1.2.7:\n\n1. New: Documents + Settings backup and restore under Settings.\n2. Faster, cleaner PDF page reorder — preserves form fields, bookmarks, and links.\n3. Better handling of shared and imported files (queue instead of drop).\n4. UX polish across settings, backup dialogs, and error messages.\n5. Reliability and security improvements throughout.\"' + \"`n\" + '}'; [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'version.json'), $j, (New-Object System.Text.UTF8Encoding($false))); Get-Content version.json; Write-Host ('HASH: ' + $h)"

# Prune to latest 3 (keep v1.2.7, v1.2.6, v1.2.4). git rm any older.
git rm -r releases\v1.2.3

git add releases/v1.2.7/app-release.apk version.json
git add -A releases
git status
git commit -m "release: v1.2.7 (Docs+Settings backup, lint sweep, latent-bug fixes, UX polish)"
git push origin main
git log -1 --pretty=format:%H
```

Report the two SHA256 checks, the version.json content, git status, commit hash, push result.

---

## APPENDIX A — What was audited but not fixed here

- **Store refactor A** (SharedPreferences → SQLite consolidation) — big refactor, needs its own plan.
- **Real release signing key** — blocked on complete backup + user reinstall migration path.
- **Off-machine keystore backup** — user manual action (copy `~/.android/debug.keystore` off the machine).
- **R8/minify (APK size lever B)** — blocked on a proguard-rules audit of receive_sharing_intent, pdfrx, dio, flutter_secure_storage, local_auth, syncfusion_flutter_pdf.
- **`build_release.ps1` cache hygiene** (flutter clean / .dart_tool wipe) — decided against because arm64 -Ptarget-platform builds have been reproducible without a clean.
- **`If-None-Match`/ETag** on version.json fetches — bandwidth micro-optimization.
- **pdfrx / PDFium lossless mergePdf spike** — senior-owned research.
- **Word/Excel view/edit + Word→PDF conversion** — separate runbook (`WORD-EXCEL-EDITING-RUNBOOK.md`).
- **Migration test suite** — the audit lens returned garbage, so no coverage cards; add ad-hoc tests only when a specific regression justifies one.

## APPENDIX B — Rollback

```
git revert <that card's commit hash>   # new commit that undoes it
git push origin experimental_flutter_upgrade
```
Never `--force`, never rewrite history. Then STOP and report — the user decides the next step.
