# PDF Password Manager — Master Issues, Bugs & Requests

> Comprehensive, line-anchored findings for the `passwordpdf_manager` Flutter app (v1.1.8+117).
> Produced by reading all 60 Dart files in full and tracing 12 subsystems branch-by-branch. Every claim cites a `file.dart:line`.
> **Identification & planning only — no application code was changed.** Companion to `CODEBASE_DEEP_DIVE.md` and the two HTML reports in this folder.

## Contents
- **Part I — Architecture Overview** (big picture, layering, data model, security model, key flows, consolidated risks)
- **Part II — Subsystem Integration** (seam analysis, the full verified Bug Ledger, highest-leverage fixes)
- **Appendix A — AES vs XOR** (why the encryption is broken and how to fix it)
- **Part U — User-Reported Bugs & Feature Requests** (the 5 items: 1 bug + 4 features, each with a code-level plan)

---
# Part I — Architecture Overview

## Architecture Understanding (detailed)

*A Flutter, Android-first personal app for managing PDFs and the passwords that unlock them. This document is written for an engineer who must confidently modify the code. File:line references point at the as-read source.*

---

## 1. Big Picture

**What it does.** A single-user, Android-first app that lets you:
- Browse the device filesystem ("All Docs") and a curated in-app library ("Documents").
- Open password-protected PDFs, auto-unlocking by trying saved passwords, then remembering which password opened which file.
- Run PDF tools: remove/add password, reorder, split, merge.
- Store standalone passwords ("My Passwords").
- Export files/folders as (optionally password-protected) ZIPs via a background queue with notifications.
- Self-update by pulling an APK from a GitHub release manifest.
- Lock the app behind biometrics/PIN with an auto-lock timeout, gated further by a hardcoded "developer password" for debug tools.

**Architectural style.**
- **Feature-first folders** under `lib/features/*` (documents, settings, password_manager, authentication, developer, update, recent_documents, debug, common), with shared `lib/services/*`, `lib/models/*`, and `lib/core/*`.
- **Service singletons** for all cross-cutting logic (`DocumentService`, `StorageService`, `EncryptionService`, `ExportQueueService`, `LoggingService`, `SettingsService`, `PdfPasswordService`, plus stateless helpers `PdfToolsService`, `BiometricService`, `PermissionService`, `CleanupService`). Most are `factory` singletons returning a static `_instance`.
- **Provider DI** only at the top (`MultiProvider` in `main.dart`), but inconsistently honored — many screens call `SomeService()` directly relying on the singleton property rather than reading from Provider.
- **Global mutable statics** as a side-channel router: `PendingFileOpen`, `DashboardFolderNavigation.pendingFolderId`, `AppEntry.ignoreNextPause/backgroundTime`, and a global `navigatorKey`.

A defining feature is the **zero-copy document index**: imported files are never copied; the library stores the original device `sourcePath` and references it in place.

---

## 2. Layering & Dependency Map

```
main.dart (bootstrap + shell)
  ├─ runZonedGuarded + FlutterError.onError  → LoggingService
  ├─ CleanupService().runCleanup()           (fire-and-forget)
  ├─ SettingsService().initialize()          (shared_preferences)
  ├─ ExportQueueService().init()             (notifications + SQLite export_jobs)
  ├─ receive_sharing_intent listeners        → PendingFileOpen (static)
  └─ MultiProvider
       ├─ ChangeNotifierProvider.value: SettingsService, ExportQueueService
       └─ Provider: EncryptionService, DocumentService, UpdateService
            └─ MyApp (Consumer<SettingsService> → theme)
                 └─ AppEntry (auth gate + lifecycle observer)
                      └─ MainScreen (IndexedStack: AllDocs / Dashboard / Settings)
```

### Key singletons and how they're shared

| Singleton | Backing store | Shared via | Notes |
|---|---|---|---|
| `SettingsService` | shared_preferences + flutter_secure_storage (`app_pin`) | Provider (`.value`) **and** `SettingsService()` direct | ChangeNotifier; drives theme + auth + auto-lock |
| `DocumentService` | **shared_preferences** JSON blob (`documents_items`) | Provider **and** direct | NOT SQLite; in-memory `_items` is source of truth |
| `StorageService` | SQLite `passwordpdf.db` v14 | direct `StorageService()` | passwords, recent_documents, export_jobs, logs, **files_index** |
| `EncryptionService` | flutter_secure_storage (`encryption_key`) | Provider (`context.read`) **and** direct | XOR cipher; developer-password gate |
| `ExportQueueService` | SQLite `export_jobs` + notifications | Provider (`.value`) **and** direct | ChangeNotifier; Timer worker + isolate ZIP |
| `LoggingService` | SQLite `logs` (via StorageService) | direct | Universal dependency; in-mem ring + DB persist |
| `PdfPasswordService` | shared_preferences (`document_passwords`) | direct | path→encrypted-password map |
| `DeviceDocumentService` | SQLite `files_index` (via StorageService) | **non-singleton**, `new` per screen | Isolate device scan |

**Critical layering fact:** there are **two parallel persistence backends that don't talk to each other.**
- `DocumentService` (the *live* library) persists to **shared_preferences** as one JSON blob.
- `StorageService` defines a rich SQLite `files_index` schema (and migrates it through v14) that `DocumentService` never touches. The only consumer of `files_index` is `DeviceDocumentService` (the device-scan "All Docs" tab). So the SQLite zero-copy index, trigram search, badges, and `missing_on_device` machinery in `StorageService` is **dead relative to the library model** — duplicated concepts in two stores.

`AppConstants` is meant to be the persistence vocabulary, but `SettingsService` uses inline string literals instead of `AppConstants.settings*`, and `AppConstants.databaseVersion = 3` is stale (`StorageService._databaseVersion = 14`).

---

## 3. Data Model & Persistence

### SQLite — `passwordpdf.db`, schema version **14** (StorageService)

| Table | Columns | Used? |
|---|---|---|
| `passwords` | `id` PK AUTOINC, `key_name` TEXT UNIQUE NOT NULL, `encrypted_value` TEXT NOT NULL, `created_at` TEXT | **Live** (My Passwords) |
| `recent_documents` | `id` PK AUTOINC, `file_path` TEXT UNIQUE NOT NULL, `file_name`, `file_size` INTEGER, `last_accessed` TEXT | Table live, **writer never called** (dead feature) |
| `export_jobs` | `id` TEXT PK, `name`, `status`, `created_at` INT(ms), `completed_at` INT, `output_path`, `error_message`, `export_dir`, **`zip_password` TEXT (plaintext)**, `items_json` TEXT NOT NULL, `progress`/`processed_items`/`total_items` INT, `type` TEXT='zip', `is_developer` INT=0 | **Live** |
| `logs` | `id` PK AUTOINC, `timestamp` TEXT(ISO8601), `level`, `tag`, `message`, `stack_trace` | **Live**; pruned to newest 8000 on each insert |
| `files_index` | `path` PK, `name`, `extension`, `parent_path`, `size`, `created_at`/`modified_at`/`last_scanned`/`added_at`/`last_synced` INT, `is_folder`/`has_pdf`/`has_doc`/`has_excel`/`is_new`/`missing_on_device`/`is_imported`/`is_imported_file` INT=0 + indexes | **Live only via DeviceDocumentService**; no CRUD in StorageService |
| `files_search_trigrams` | `token`, `path` | Created `_onCreate` but **dropped** in `_onUpgrade` v12 → fresh vs migrated installs diverge |

Migrations: `_onUpgrade` v2→v14; all `ALTER TABLE` wrapped in try/catch that **swallow every exception**.

### shared_preferences keys

| Key | Owner | Value |
|---|---|---|
| `documents_items` | DocumentService | JSON array of `DocumentItem` (the entire library) |
| `document_passwords` | PdfPasswordService | JSON map `path → base64(XOR) password` or `'NO_PASSWORD'` |
| `password_paths_migrated_v2` | PdfPasswordService | migration guard bool |
| `theme_mode`, `auth_method`, `accent_color` (int), `font_size_adjustment`, `max_log_count`, `developer_mode_enabled`, `default_screen_index`, `auto_lock_timeout`, `last_viewed_build_number`, `auto_check_updates`, `export_path` | SettingsService | inline literals (not AppConstants) |
| `update_available` (bool), `last_update_check_time` (ISO8601) | UpdateService | |

### flutter_secure_storage keys

| Key | Owner | Value |
|---|---|---|
| `encryption_key` | EncryptionService | the single symmetric XOR key |
| `app_pin` | SettingsService | the app PIN **in plaintext** |

> Note: `AppConstants.encryptionKeyName = 'pdf_encryption_key'`, but `EncryptionService` actually uses the literal `'encryption_key'`. Another source-of-truth drift.

### Model classes (`lib/models/*`)

- **`DocumentItem`** — the zero-copy record. Fields: `id`, `name`, `type` (folder/file), `sourcePath?`, `parentId?`, `fileIds` (folders), `size`, `createdAt/modifiedAt`, `isImported`, `isImportedFile`, `isNew`, `missingOnDevice`, `addedAt?`, `lastSynced?`. `toJson` writes path under **both** `sourcePath` and legacy `filePath`. `fromJson` parses `type` via `firstWhere` with **no `orElse`** → a corrupt `type` throws and can abort loading the whole library. `copyWith` resets `modifiedAt` to `now()` whenever omitted (easy to accidentally bump).
- **`PasswordModel`** — DTO: `id?`, `keyName`, `encryptedValue` (already-encrypted), `createdAt`. snake_case columns; no crypto in the model.
- **`RecentDocumentModel`** — DTO for `recent_documents`.
- **`ConflictResolution`** — `ConflictActionType {rename, overwrite, skip}`, `ConflictAction {type, renameSuffix?}`, `ConflictItem {sourceId, name, originalPath, isFolder}`. No serialization → interrupted imports lose chosen actions.

### Zero-copy index & duplicate detection

- **Zero-copy:** `DocumentService.addReference` (document_service.dart L85-155) stores the original `sourcePath`; bytes are never copied into app storage. `getPhysicalPathForFolder` resolves to `SettingsService().exportPath` for manual folders or the folder's `sourcePath` for imported ones.
- **Duplicate detection is SIZE-ONLY.** `addReference` first matches exact `sourcePath`, then matches by **byte length** (L116); `checkForDuplicates` compares `fileSize == existingSize` (L491). No hash/content compare → two distinct files of equal length are flagged as duplicates. `FileOccurrencesScreen` even carries an unused `contentHash` field but matches purely on size.

---

## 4. Security Model — and Its Weaknesses

This section is the most important for anyone touching the app. **The security posture is demo-grade and several "protections" are cosmetic.**

### Password value "encryption" — `EncryptionService`
- The cipher is **repeating-key XOR + base64** (encryption_service.dart L89-114, L117-141), *despite comments saying "use AES in production."* XOR with a reused, on-device key is trivially reversible (known-plaintext via base64 framing and common PDF password shapes). It provides obfuscation, not encryption.
- **No MAC/integrity.** Tampering is undetectable; wrong key → `utf8.decode` throws and is swallowed, masking "wrong key" vs "corrupt data."
- The key lives in flutter_secure_storage (`encryption_key`); `setEncryptionKey` **refuses rotation** once set (L36-39) and there's no migration path — rotate it and every stored value becomes undecryptable.
- The key is cached in plaintext in process memory for app lifetime; never zeroized.

### Where passwords actually live
- **My Passwords** (`passwords` table): values encrypted via `EncryptionService` before insert — but only XOR-grade, and stored in a plain (no SQLCipher) SQLite DB.
- **Per-document associations** (`PdfPasswordService`, `document_passwords` pref): also XOR-encrypted, but stored in **shared_preferences** (the app's plaintext prefs file), not secure storage. `getAllUniquePasswords()` decrypts the whole pool to brute-force-try against any opened document.
- **Export ZIP passwords** (`export_jobs.zip_password`): stored **in plaintext** in SQLite, bypassing EncryptionService entirely.
- **App PIN** (`app_pin`): stored **plaintext** in secure storage; `verifyPin` is `storedPin == pin` (no hash, no salt, non-constant-time).

### Auth: biometric + PIN
- `BiometricLockScreen` enforces biometric>PIN priority off `SettingsService.authMethod` (`none/pinOnly/fingerprintOnly/both`).
- `BiometricService.authenticate` is intentionally weakened: `biometricOnly:false` + `sensitiveTransaction:false` → device PIN/pattern and **Class-2 (weak) Face Unlock** can satisfy the lock.
- **Attempt lockout is fake.** Both `BiometricLockScreen` (L172) and `PinEntryScreen` (L121) show "X attempts left / too many attempts" but never disable the numpad. Combined with plaintext PIN compare → unlimited offline-equivalent guessing. The counter is in-memory and resets on screen rebuild.

### Auto-lock
- In `AppEntry.didChangeAppLifecycleState` (main.dart L642-701): on resume, lock only if `diff.inMinutes >= settings.autoLockTimeout` AND `(biometric||pin)` AND `_isAuthenticated`.
- **Whole-minute comparison** (`inMinutes`) means a 9m59s background never locks if timeout is 10; sub-minute resumes never lock.
- The lock overlay is pushed **after** resume with `opaque:false`, so sensitive content is visible for a frame before the lock paints.
- `SettingsScreen` sets `AppEntry.ignoreNextPause = true` (L504) before the folder picker. If the user cancels the picker, the flag is still set and the *next genuine* background event skips one auto-lock.

### Developer-password gate
- The "developer password" is the **hardcoded constant `'Portal123!'`** (encryption_service.dart L20), compiled into the APK, compared by plaintext `==`. It is also hardcoded inline in `developer_screen.dart` L41 and `settings_screen.dart` L190.
- **The gate is bypassable.** `_openDebugLogs` (settings) calls `showDeveloperPasswordDialog` — but once developer mode is unlocked (5 taps on version tile), a persistent "Developer Tools" tile navigates straight to `DeveloperScreen` with **no password check**. The Developer DB tab can read/edit/delete every table (including the `passwords` ciphertext) and **view the raw encryption key in cleartext** (SelectableText).
- The DB tab's only protection is a string match on the literal `'encryption_key'`, which is a *secure-storage key name*, not a DB row — so it does **not** actually protect password rows from edit/delete.

### Self-update supply chain (high severity for a password manager)
- `UpdateService` fetches `version.json` from a hardcoded GitHub raw URL and downloads the APK from a `downloadUrl` inside that JSON. The **only** integrity check is the ZIP `PK` magic bytes (update_service.dart L167). No signature, no checksum, no pinning → MITM or a compromised/typo-squatted repo can serve an arbitrary APK that the app hands to the OS installer.

### No re-auth on sensitive paths
- Opening a protected document, iterating all saved passwords, and the recent-docs deep-link path do **not** re-check the app lock; they assume the global gate was satisfied.

---

## 5. Key End-to-End Flows

### (a) Cold start + auth gate
1. `main()` runs in `runZonedGuarded`; installs `FlutterError.onError`; fires `CleanupService().runCleanup()`; awaits `SettingsService.initialize()` and `ExportQueueService.init()`; subscribes to notification taps; `runApp(MultiProvider→MyApp)`.
2. `MyApp` derives theme from `settings.accentColor` + font scale and renders `AppEntry`.
3. `AppEntry.initState` → `_checkInitialIntents` (cold share) + `_initialize` (permissions, update init, decides `needsAuth = biometricEnabled||pinEnabled`).
4. `AppEntry.build`: `_isLoading` → splash; else `!_isAuthenticated` → `BiometricLockScreen(onAuthenticated:_onAuthenticated)`; else `MainScreen`.
5. `MainScreen` post-frame **startup gauntlet** (L820-886): force `EncryptionService` key setup if `!isKeySet()` → `cleanupUpdateFile()` → WhatsNew gate vs `lastViewedBuildNumber` → `checkForUpdate` → `UpdateAvailableDialog` → `_performUpdate`.

### (b) "Open With" / share-intent file open + duplicates
- Two divergent entry paths (a real bug):
  - **Hot stream** (`getMediaStream` → `_handleSharedFiles`, main.dart L354-585): shows "Importing…" dialog, runs duplicate detection, fixes `.pdf` extension, resolves `content://` by copying to temp, sets `isTemporary`, and either pushes `MainScreen(initialIndex:1)` (if authenticated) or defers to the dashboard via `PendingFileOpen`.
  - **Cold start** (`_checkInitialIntents`, L323-337): writes `file.path` **directly** into `PendingFileOpen.filePath` with none of the above logic — can leave a non-PDF or raw `content://` URI as the pending file.
- Duplicate resolution surfaces via `DuplicateFilesDialog` / a notification (`open_duplicates` / `open_folder:<id>`). The dashboard drains `PendingFileOpen` in `_initialize` (document_dashboard_screen.dart L368-393): `findFileIdByPath` → `_openDocument`, else pushes `PdfViewerScreen(isExternal:true, deleteOnClose:isTemporary)`.

### (c) Opening a password-protected PDF (auto-unlock → prompt → save)
`DocumentDashboardScreen._openDocument` (L1670-1837):
1. `PdfPasswordService.getPasswordForDocument(path)` → if a stored association exists, open immediately.
2. `PdfToolsService.isProtected` (2KB head/tail `/Encrypt` sniff). If not protected → open with `''` and save `''` association.
3. **Brute force:** load all `passwords`, decrypt each via EncryptionService, `tools.verifyPassword` in a loop; first hit → `saveDocumentPassword(path, pw)` (plaintext-equivalent), green snackbar, open.
4. Fallback `_showSmartPasswordDialogAndOpen`: manual entry → verify → optional encrypt+insert into `passwords` → `saveDocumentPassword` → open viewer.

The actual viewer (`features/documents/screens/pdf_viewer_screen.dart`) re-implements the same multi-candidate strategy via pdfrx's `passwordProvider` (`_getPassword`, L121-180): widget password → stored → all unique → `PasswordSelectionDialog`.

### (d) PDF tools (split / merge / reorder / remove password)
- Viewer overflow menu → dialogs (`PageNavigationDialog`, `ReorderPagesDialog`, `SplitPdfDialog`, `PasswordSelectionDialog`) → `_runToolOperation` (L765-795): compute output path from `SettingsService().exportPath`, `FileConflictResolver.resolve`, show modal progress, call `PdfToolsService`.
- `PdfToolsService` rebuilds each page via `createTemplate()+drawPdfTemplate` — **a visual flatten** that drops form fields, annotations, bookmarks, links, metadata. It reads whole files into memory (OOM risk) and lacks try/finally disposal on error (native handle leak).

### (e) Export queue + notifications
- `ExportQueueService.addJob` → persist to `export_jobs` (fire-and-forget) → `_processQueue` (maxConcurrent=2) → `_processZipJob`: `_addItemsToArchive` reads every file fully into RAM, then `compute(_encodeArchive)` builds a password-protected ZIP in an isolate, writes to `exportDir` or systemTemp, marks complete. Progress + completion drive `flutter_local_notifications`. `ExportProgressScreen` subscribes to the singleton (ChangeNotifier) for live UI; supports developer/user isolation via `is_developer`.
- On restart, `init` force-fails any in-progress **and queued** jobs as "Interrupted by app restart" → pending exports are silently abandoned.

### (f) All-Docs device scan + sync + missing-file detection
- `DeviceDocumentService.syncAndIndex`: re-entrancy-guarded; permission check; `Isolate.run(_scanIsolate)` DFS over `/storage/emulated/0` (+ priority dirs); `_syncToDatabase` precomputes folder `has_pdf/doc/excel` flags, upserts with `ConflictAlgorithm.replace`, ensures parent folder rows, then **mark-and-sweep deletes** any row with `last_scanned < syncTime`.
- `AllDocumentsScreen` reads via `getDocuments()` and **re-`statSync()`s each visible row on the UI thread** (ignores the size/date already in the index). Missing-file/NEW-badge columns exist in the schema but are **not rendered** at this layer.

### (g) Self-update (check → download → install)
- `checkForUpdate` (weekly throttle): fetch `version.json` (cache-busted) → `UpdateInfo` → if `info.buildNumber > currentBuild`, set `update_available` and return info; else clear flag.
- `downloadUpdate`: dio download to external cache as `update_<epochMs>.apk`, validate size>1000 & `PK` magic → `installUpdate` → `OpenFilex.open` (system installer).
- `_performUpdate` is **triplicated** (update_dialogs.dart, main.dart, settings_screen.dart) with divergent error handling.

---

## 6. State Management & Lifecycle

- **Provider** is used only for the top-level MultiProvider; `SettingsService` and `ExportQueueService` are `ChangeNotifierProvider.value`, the rest plain `Provider`. Screens frequently bypass Provider and call `SomeService()` directly — safe **only because** those are real singletons. `MainScreen.initState` constructs a fresh `SettingsService()` (main.dart L793) relying on that.
- **`UpdateService` is NOT a singleton.** The Provider instance backs the red-dot badge, but `settings_screen._checkForUpdates` (L876) and the startup check create their own `UpdateService()`, so a manual check updates a *different* notifier and the live badge isn't refreshed (only on next `initialize()` via prefs).
- **GlobalKeys:** `navigatorKey` (notification-driven navigation outside the tree); `_mainScreenKey`, `_allDocsKey`, `_dashboardKey` for back-handling; static `currentState` on `AllDocumentsScreen`/`DocumentDashboardScreen` so `MainScreen` can drive hardware-back (`navigateUp`/`clearSelection`).
- **App lifecycle / background tracking:** `AppEntry` is the `WidgetsBindingObserver`; `static backgroundTime` + `static ignoreNextPause` drive auto-lock and the picker exemption. `didChangeAppLifecycleState` uses `Provider.of`/`Navigator.of` with **no mounted guard**.
- **IndexedStack tab persistence:** `MainScreen` keeps all three tabs alive in an `IndexedStack` behind an inline 3-tab `NavigationBar`; `_currentIndex` resolves from `settings.defaultScreenIndex` and `DashboardFolderNavigation.pendingFolderId`. Back handling is a `PopScope(canPop:false)` chain per tab → Exit dialog.

---

## 7. Cross-Cutting Risks & Tech Debt (consolidated, ranked)

### SECURITY (highest)
1. **Unverified APK self-update** — only a ZIP magic-byte check; no signature/checksum/pinning. (update_service.dart L15, L167; forceUpdate not actually enforced — `showUpdateDialog` is dismissible, update_dialogs.dart L106-113.)
2. **XOR "encryption" for all stored passwords** — reversible obfuscation, no MAC, key cached in memory, non-rotatable. (encryption_service.dart L89-141, L36-39.)
3. **Hardcoded developer password `'Portal123!'`** compiled into the APK, plaintext `==`, replicated in 3 files; gate bypassable once dev mode is on; Developer DB tab can edit/delete the `passwords` table and view the raw key in cleartext. (encryption_service.dart L20; developer_screen.dart L41, L620; settings_screen.dart L190.)
4. **Plaintext PIN** in secure storage + plaintext compare + **fake lockout** (unlimited guesses). (settings_service.dart L209/L232; biometric_lock_screen.dart L172; pin_entry_screen.dart L121.)
5. **Plaintext ZIP passwords** in `export_jobs.zip_password`. (export_queue_service.dart L81; storage_service.dart schema.)
6. **Per-document passwords + brute-force-all** — passwords stored XOR'd in shared_preferences; opening any doc tries every saved password; auto-saves a matched password as the file's association without consent. (pdf_password_service.dart; document_dashboard_screen.dart L1774-1794.)
7. **Weakened biometric** (`biometricOnly:false`, Class-2 face). (biometric_service.dart L62-63.)
8. **Auto-lock holes** — whole-minute granularity, content visible before overlay, `ignoreNextPause` can skip one legitimate lock after a cancelled picker. (main.dart L665-688; settings_screen.dart L504.)
9. **SQL identifier injection** in generic DB helpers — `updateRecord`/`deleteRecord`/`getTableData` interpolate table/column names. (storage_service.dart L502-528.) Reachable only from developer tools today.
10. **No re-auth** before opening protected docs / recent-docs deep links.
11. **Logs persist secrets/PII** — verbatim messages (incl. PIN lifecycle, file paths) written to the `logs` table and exportable via dev tools. (settings_service.dart L208/L233/L256; logging_service.dart.)
12. **Over-broad permission** `MANAGE_EXTERNAL_STORAGE` (Play-policy sensitive); scoped-storage incorrectness on Android 13+. (permission_service.dart L23, L73-80.)

### DATA LOSS / INTEGRITY
13. **`DocumentService` whole-list JSON rewrite** on every mutation, **no concurrency control**, **ID collisions** from `millisecondsSinceEpoch` in tight sync loops, double-save in `deleteItem`. (document_service.dart L596/L617/L869-870, L913-922.)
14. **`files_index` mark-and-sweep purges curated rows** — `ConflictAlgorithm.replace` and the sweep wipe `is_new/is_imported/missing_on_device/added_at` on every scan because those fields aren't re-stamped. (device_document_service.dart L176, L228-232.)
15. **Duplicate detection by file size only** (no hash) across the app. (document_service.dart L116/L491; file_info_screen L57; file_occurrences contentHash unused.)
16. **Overwrite-before-import** in multi-import deletes the existing item before importing the replacement, with no rollback → loss on partial failure. (all_documents_screen.dart L758-785.)
17. **PDF tools flatten pages** — forms/annotations/bookmarks/metadata dropped by `createTemplate`+`drawPdfTemplate`. (pdf_tools_service.dart L26-32 et al.)
18. **`isProtected` is a 2KB head/tail `/Encrypt` sniff** — false negatives on large/linearized PDFs, false positives on stream data. (pdf_tools_service.dart L289-307.)
19. **`cleanupUpdateFile` no-op** (deletes `update.apk`, downloads are `update_<epoch>.apk`) → APKs accumulate in cache. (update_service.dart L123 vs L196.)
20. **Filename-collision password leak** — `PdfPasswordService` matches by basename only; same-named files share/clear each other's passwords. (pdf_password_service.dart L58-62, L132-136.)
21. **`_pickFiles` rename physically copies into the source/Downloads dir** and never cleans up. (document_dashboard_screen.dart L763-772.)
22. **Folder-scoping mismatch** — `RemovedFilesScreen` scopes by `parentId` while containment elsewhere uses `fileIds`. (removed_files_screen.dart L34.)
23. **`'root'` vs `null` folder-id inconsistency** across navigation call sites → wrong/empty folder. (duplicate_files_dialog.dart L76 raw vs main.dart L964 normalized.)
24. **Recent-documents feature is dead** — `addRecentDocument` is never called; table stays empty. (recent_service.dart L10.)
25. **Corrupt-record fragility** — `DocumentItem.fromJson` / model `DateTime.parse` throw with no orElse/try-catch, aborting whole-list loads. (document_item_model.dart L103-117.)

### CRASH / ASYNC
26. **Pervasive missing `mounted` guards after await** — `didChangeAppLifecycleState`, `_handleSharedFiles`, `_openDocument`, password dialogs, password_manager_screen, settings download path, export share path, recent/occurrences screens. High "setState/Navigator/ScaffoldMessenger after dispose" risk on fast navigation.
27. **Synchronous I/O on the UI thread** — `statSync`/`lengthSync` per row in list builders (`AllDocumentsScreen` L1223, `DocumentCard`, `file_info_screen` build), `CleanupService.listSync` at startup, `FileSystemBrowser` double-stat sort.
28. **`DocumentCard`/`document_search` etc. crash on deleted source files** (zero-copy points at external files; no try-catch around stat). 
29. **`_folderCountCache` / `_filterType`-mutation hack** in dashboard — stale counts after import/move/delete; non-reentrant filter-count computation. (document_dashboard_screen.dart L2625-2629.)
30. **Race in `ExportQueueService`** — `maxConcurrent` counted before async status settles; `_jobs` mutated from multiple callbacks without a lock; notification IDs = `job.id.hashCode` (collisions).

### SMELLS / DEAD CODE
- **Two `PdfViewerScreen` classes** (see §8).
- Dead theming/widgets: `AppTheme` (main builds its own `ColorScheme.fromSeed`), `AppBottomNavBar` (4-tab, doesn't even match the real 3-tab shell), `AppLogo` (splash uses `AnimatedSplashLogo`).
- Dead/duplicated logic: `_AppEntryState._performStartupChecks` (never called), the `open_duplicates` sheet duplicated by `_showDuplicateSelectionSheet` (with the root-id divergence bug), `_showFolderConflictDialog`/`_showDuplicateDialog`/`_getNewFileName` in dashboard, `_openDebugLogs`/`_showHexColorInput`/unused `EncryptionService` field in settings, dead imports (`path_provider`/`path` in DocumentService, `local_auth_platform_interface`, `dart:io`/`dart:convert` in developer_screen, `app_theme` in lock screen).
- Stringly-typed contracts: `'open'` magic pop value, `'__ROOT__'` sentinel, `'NO_PASSWORD'` sentinel.
- Inconsistent time encoding: `logs` use ISO8601 strings, `export_jobs` use epoch-ms.
- Deprecated APIs: `Color.withOpacity`, `WillPopScope`, `PopScope.onPopInvoked`, `MaterialStateProperty`, `surfaceVariant`.

---

## 8. Notable Observations

- **Two `PdfViewerScreen` classes with the same name.**
  - `lib/features/documents/screens/pdf_viewer_screen.dart` — the **real** pdfrx viewer.
  - `lib/features/pdf_tools/screens/pdf_viewer_screen.dart` — a **dead stub** StatelessWidget that just renders "PDF viewer temporarily unavailable" (leftover from the abandoned Syncfusion viewer during the pdfrx v2 migration). It accepts a `password` param it ignores and prints the full `filePath` in the UI. **If any call site imports the wrong one, PDFs silently become "unavailable."** Worth deleting.
- **Two parallel search implementations.** `DocumentSearchDelegate` searches a *one-time snapshot* of the in-app library (`getAllItems()`), while `AllDocumentsScreen` has its own 300ms-debounced search over the device `files_index`. They return different result universes depending on entry point.
- **Two parallel storage backends** (shared_preferences blob vs SQLite `files_index`) duplicating the same "file index, is_new, missing_on_device, is_imported, last_synced" concepts. The SQLite side is largely dead relative to the live model.
- **Fresh-install vs migrated-install schema divergence** because `files_search_trigrams` is created in `_onCreate` but dropped in `_onUpgrade` v12.
- **`AppConstants` is partly decorative** — `databaseVersion=3` (real is 14), `encryptionKeyName='pdf_encryption_key'` (real is `'encryption_key'`), settings keys unused. Don't trust it as source of truth.
- **The Excel/logs export paths are disabled** (`package:excel` blocked by a pdfrx v2 conflict) — `_processExcelJob`/`_processLogsJob` throw immediately.
- **`debug_logs_screen.dart` is an orphaned legacy logs viewer** (reads only the ~100-entry in-memory ring, not the 8000-row SQLite logs) with no live navigation route; superseded by the Logs tab in `DeveloperScreen`.

---

### Quick orientation for common edits
- **Change how the library persists?** Touch `DocumentService` only — it's the live store (shared_preferences `documents_items`), not `StorageService.files_index`.
- **Touch password storage/crypto?** `EncryptionService` (cipher), `PdfPasswordService` (per-doc map), `StorageService.passwords` (My Passwords). Note all three are XOR-grade.
- **Auth/lock behavior?** `SettingsService` (state/PIN), `BiometricService` (hardware), `AppEntry` (enforcement/lifecycle), `BiometricLockScreen`/`PinEntryScreen` (UI).
- **Device scan / All-Docs?** `DeviceDocumentService` + `AllDocumentsScreen` (the SQLite `files_index` path) — beware the mark-and-sweep purge and Android-only `/storage/emulated/0`.
- **Anything async + UI:** add `if (!mounted) return;` after every await before using `context`/`setState` — the codebase is systematically missing these.

---

# Part II — Subsystem Integration (Seams, Bug Ledger, Fixes)

## Subsystem Integration (detailed)

## Table of Contents

- **dashboard-pt1 — Document Dashboard Screen: State, Lifecycle, Sync, Navigation, Selection & Rendering** — How `DocumentDashboardScreenState` drains `PendingFileOpen`/`DashboardFolderNavigation` in `_initialize`, runs auto-sync + pull-to-sync gestures, and renders the folder/file grid with the stale `_folderCountCache`.
- **dashboard-pt2 — File/Folder Operations & Smart-Open Subsystem** — Zero-copy import (`addReference`), FilePicker/full-folder import, conflict + cross-folder-duplicate resolution, move/rename/delete cascades, ZIP export, and the smart-open protected-PDF flow.
- **pdf-unlock-statemachine — Password-Unlock State Machine (storage → decrypt → verify → pdfrx)** — The two password stores (per-document associations vs the reusable pool), the viewer's `_getPassword` candidate ordering, `PdfPasswordService`, the XOR `EncryptionService`, and the manual-entry dialog.
- **document-service-engine — DocumentService (in-memory model + SharedPreferences persistence)** — The dual parent model (`parentId` vs `fileIds`), `addReference` size-dedup, ID generation, move/delete cascades, and the disk→app `syncFolder` engine.
- **storage-sqlite — Local SQLite Persistence Layer** — The `sqflite` singleton, the v2→v14 migration ladder with its create/drop divergences, log pruning, and the generic introspection/injection surface.
- **device-scan — DeviceDocumentService (filesystem scan → files_index)** — The worker-isolate DFS scan and the mark-and-sweep sync that wipes curated flags, plus paginated/filtered/searched reads.
- **export-queue-isolate — Export Queue Subsystem** — The singleton `ChangeNotifier` job queue, restart recovery, the fire-and-forget worker, in-RAM ZIP build via `compute`, and notification plumbing.
- **auth-lifecycle — Auth + Auto-Lock State Machine** — The four-state `AuthMethod` machine projected onto two booleans, the resume-overlay auto-lock, biometric→PIN fallback, and PIN persistence.
- **pdf-tools — PDF Tools Subsystem** — Stateless `PdfToolsService` operations (remove/add password, reorder, split, merge), the visual-flatten core that drops forms/annotations, and the 2KB `isProtected` sniff.
- **self-update — Self-Update Subsystem** — GitHub-manifest-driven APK download/install with no signature/TLS verification, the triplicated `_performUpdate`, and half-wired `forceUpdate`.
- **all-docs-screen — All Documents Screen: view modes, pagination, search, multi-select, import/open** — Flat/folder views over `DeviceDocumentService`, infinite scroll, debounced search, conflict/duplicate import, and stored-password open.
- **developer-tools — Developer Screen subsystem** — The 2-tab DB viewer/editor and persisted-log viewer, encryption-key reveal/set actions, and the developer-password gate (and its ungated bypass).

---

## Seam Analysis

### Seam 1 — `dashboard._openDocument` → `PdfPasswordService` → `EncryptionService` → `PdfToolsService`/pdfrx

**Hand-off contract.** `_openDocument` (`document_dashboard_screen.dart:1670`) opens by `item.sourcePath` (not id). Step 1 calls `PdfPasswordService.getPasswordForDocument(filePath)` (`:1707`), whose return contract is the load-bearing sentinel: `null` = nothing stored, `''` = `'NO_PASSWORD'` (verified-unprotected), non-empty = decrypted password (`pdf_password_service.dart:79-84`). The branch at `:1708` is taken on **non-null**, so `''` short-circuits straight into the viewer with `password: ''`. Decryption crosses into `EncryptionService.decrypt` (`encryption_service.dart:117`), which returns `null` on missing key/corrupt ciphertext — and that `null` is returned verbatim by `getPasswordForDocument` (`pdf_password_service.dart:84`), collapsing into the "nothing stored" meaning. Step 3 brute-forces the *other* store, `StorageService.getAllPasswords()` (`:1764`), decrypting each and trial-opening via `PdfToolsService.verifyPassword`. Every success path constructs `PdfViewerScreen(password: <verified|''>)`; `null` is never passed (converted to `''` in viewer `initState:68`).

**Where bugs cluster.** (a) The ambiguous `null` (decrypt-fail vs absent) means a genuinely stored password is treated as absent and re-prompted (`pdf_password_service.dart:84`, consumed at `dashboard:1708`). (b) The stored-association fast path never re-verifies (`dashboard:1708-1721`), so a stale/externally-changed password opens the viewer wrong with no fallback. (c) Loading-dialog pops use the screen context guarded only by a `dialogOpen` bool, not `mounted` (`dashboard:1743`, `:1788`). (d) Two password stores diverge: the viewer's auto-try candidates come from `_documentPasswords` values (`pdf_viewer_screen.dart:146`), NOT `StorageService`'s pool — only the dashboard Step 3 tries the real pool.

### Seam 2 — share-intent / notification → `PendingFileOpen` / `DashboardFolderNavigation` → `dashboard._initialize`

**Hand-off contract.** These are static globals owned by `main.dart` (`document_dashboard_screen.dart:36`): `PendingFileOpen.{hasPending, filePath, fileName, isTemporary, clearOpen()}` and `DashboardFolderNavigation.{pendingFolderId, clear()}`. The contract is "set externally (notification tap / share intent), drained exactly once in `_initialize`." `_initialize` reads `pendingFolderId`, captures it locally, then `clear()` (`:358-365`); then reads `PendingFileOpen.filePath!` (`:369`, force-unwrap guarded by `hasPending` at `:368`), derives the name, captures `isTemp`, and `clearOpen()` (`:372`) before either resolving to an existing item via `findFileIdByPath` → `_openDocument`, or falling back to `PdfViewerScreen(isExternal:true, deleteOnClose:isTemp)` (`:381-391`). `all_documents_screen.dart` also writes `PendingFileOpen.duplicateOptions` (`:392`) and emits notification payload sentinels `'open_duplicates'` / `'open_folder:<id>'` (`:394-409`).

**Where bugs cluster.** The drain runs inside `_initialize`'s `finally` and is `mounted`-guarded (`:351`), but the deleteOnClose temp-file handoff is fragile: the viewer fires `File(widget.filePath).delete().catchError((_){})` unawaited in `dispose` (`pdf_viewer_screen.dart:104-108`), so a temp file may leak or race a reader. The notification-payload sentinels are matched as substrings (`'open_folder:'`) — brittle string coupling between `all_documents_screen.dart:399-409` and the tap handler.

### Seam 3 — dashboard/all-docs → `DocumentService.addReference` → `addFile` → in-memory `_items` blob

**Hand-off contract.** `addReference(path, name, {allowDuplicate, folderId, isNew}) → ImportResult` (`document_service.dart:85`; contract `document_service.dart:11-36`). Sentinels: duplicate = `success:false, isDuplicate:true, duplicates:set`; error = `success:false, isDuplicate:false, errorMessage:set`. `_importFiles` branches `isDuplicate` first (`dashboard-pt2 L201`), then `success` (L275). `addReference` delegates to `addFile`, which writes BOTH `parentId` (`:621`) AND the parent's `fileIds` list (`:633-642`) — the **dual parent model**. The whole DB is one mutable `List<DocumentItem>` persisted as a single JSON blob under `'documents_items'` (`:68`).

**Where bugs cluster.** This is the densest boundary. (a) The two membership sources diverge: `getFilesInFolder` reads only `fileIds` (`:534`) while sync's missing-pass reads only `parentId` (`:346`); `moveFilesToRoot`/`removeFileFromFolder` edit only `fileIds` and never clear `parentId` (`:749-763`, `:666-678`) → "shown-but-missing" / "missing-but-shown" / orphan-on-delete. (b) `addReference` dedups by byte-size only (`:116`) → false-positive duplicates. (c) Full-blob last-writer-wins: concurrent sync + UI mutation clobber each other (`:913-917`). (d) ID collision from `millisecondsSinceEpoch` (`:596`, `:617`) makes `removeWhere(id==…)` delete both colliding items (`:857`).

### Seam 4 — `DocumentService` prefs blob vs `StorageService.files_index` vs `DeviceDocumentService` curated flags

**Hand-off contract.** There are **two parallel document indexes that never reconcile**: `DocumentService._items` (SharedPreferences JSON blob, the *curated* library) and `StorageService.files_index` (SQLite, the *device scan* mirror). `DeviceDocumentService.syncAndIndex` owns `files_index` and writes only 13 of 18 columns, omitting the curated columns `is_new`, `missing_on_device`, `added_at`, `is_imported`, `is_imported_file`, `last_synced` (`device_document_service.dart:163-174`). The schema defines those columns with DEFAULT 0/NULL (`storage_service.dart:107-112`) expecting the curated/badge feature to populate them.

**Where bugs cluster.** Structural incompatibility: every `syncAndIndex` either clobbers survivors via `ConflictAlgorithm.replace` (`device_document_service.dart:176` — REPLACE deletes the row and re-inserts with column defaults) or sweeps non-rescanned rows via `last_scanned < syncTime` (`:228-232`). Net: imported files and "NEW" badges cannot survive a single scan. Meanwhile `DocumentService`'s own `isNew`/badge state lives entirely in the prefs blob and is invisible to `files_index`. The two stores are queried by different screens (`all_documents_screen` uses `DeviceDocumentService.getDocuments`; the dashboard uses `DocumentService`), so the same physical file has two divergent metadata records.

### Seam 5 — `DocumentService` / dashboard / dev-screen → `StorageService` (SQLite)

**Hand-off contract.** `StorageService` is the shared `sqflite` singleton. Cross-file contracts: `PasswordModel`/`RecentDocumentModel` must round-trip exact column sets; export jobs/logs/`files_index` pass as raw `Map<String,dynamic>`. Upsert relies on UNIQUE/PK columns (`key_name`, `file_path`, `id`) with `ConflictAlgorithm.replace`. `getTables()` returns real table names that flow into the developer screen as `_selectedTable`. The generic helpers interpolate the table name and `idColumn` directly: `updateRecord`/`deleteRecord` use `where: '$idColumn = ?'` (`storage_service.dart:521`, `:527`).

**Where bugs cluster.** (a) The injection surface (`storage_service.dart:515/521/527`) is currently safe only because callers pass schema-derived names + hardcoded `'id'` (`developer_screen.dart:705/746`) — safety lives in the caller, not the helper. (b) `idColumn='id'` is wrong for `files_index` (PK is `path`, no `id` column) → SQLite error or 0-row no-op (`developer_screen.dart:705/746`). (c) Migration `CREATE TABLE` steps without `IF NOT EXISTS` (`storage_service.dart:156/195/209-223`) abort the whole upgrade on a partially-migrated DB, bricking DB access. (d) `files_search_trigrams` is created fresh-v14 (`:139-146`) but dropped at v12 (`:276`) → its existence depends on install lineage, and it surfaces via `getTables()` into the dev screen.

### Seam 6 — `dashboard`/`all-docs` `_exportSelectedItems` → `ExportQueueService.addJob` → SQLite `export_jobs` → `compute(_encodeArchive)`

**Hand-off contract.** `addJob(name, List<ExportItem>, {exportDir, zipPassword})` where `ExportItem = {itemId, name, isFolder, filePath?, children?}` (`dashboard-pt1 §10`). `_buildExportItemsFromFolder` includes only files with non-null `sourcePath` (`dashboard-pt2 L1151`). Persistence moves `json['items']` → `items_json` column on write (`export_queue_service.dart:456-459`) and reverses on read (`:211-213`). The developer DB-export smuggles its row-limit as a fake `ExportItem(itemId:'config_limit', name: finalLimit.toString())` with `-1` = unlimited (`developer_screen.dart:817-821`). Encode crosses into an isolate via `compute(_encodeArchive, {archive, password})` returning `List<int>?` where `null` = failure (`:502-503`, `:543-553`).

**Where bugs cluster.** (a) `zipPassword` is persisted plaintext in `export_jobs` and never cleared (`:76`, round-tripped `:91`). (b) Empty-but-non-null password: `encrypt ? password : null` yields `''` not null → ZIP "encrypted" with empty password (`dashboard-pt2 L1289/L521`). (c) The whole `Archive` (every file's bytes) crosses the isolate boundary via `SendPort`, doubling memory (`:502`). (d) Un-sanitized `job.name` in the temp-path branch → path traversal (`:515`). (e) Restart recovery force-fails in-memory but doesn't re-persist (`:218-222`), so DB rows stay `inProgress`.

### Seam 7 — `main.AppEntry` auth gate → `BiometricLockScreen` → `BiometricService`/`SettingsService` PIN

**Hand-off contract.** `AuthMethod.{none,pinOnly,fingerprintOnly,both}` (`settings_service.dart:7-12`) projected onto `biometricEnabled` (=fingerprintOnly||both) and `pinEnabled` (=pinOnly||both) (`:45-46`). `AppEntry._initialize` computes `needsAuth = biometricEnabled || pinEnabled` (`main.dart:615`); the resume overlay decision uses static `AppEntry.{ignoreNextPause, backgroundTime}` (`main.dart:276/279`) mutated by other screens (`:1071-1072`). `BiometricService.authenticate → Future<bool>` (false on unsupported/error). `verifyPin → Future<bool>` (`true` iff `storedPin == pin`, `settings_service.dart:232`). PIN stored plaintext under `app_pin`.

**Where bugs cluster.** The gate is an in-tree boolean `_isAuthenticated` with no cryptographic binding to decrypted data. `ignoreNextPause` is a process-wide one-shot consumed by the wrong pause → `backgroundTime` left null → resume never evaluates timeout (`main.dart:644-650,657`). `inMinutes` flooring defeats the timeout for the whole first interval (`main.dart:665`). `biometricOnly:false` lets the device credential bypass the app PIN entirely (`biometric_service.dart:62`).

### Seam 8 — `pdf_viewer_screen._runToolOperation` → `PdfToolsService` → output path → `FileConflictResolver`

**Hand-off contract.** Operation closure `Future<String> Function(PdfToolsService, String)` (`pdf_viewer_screen.dart:765-768`): returns the output path on success, throws on failure (no sentinel). The closure receives a pre-resolved `savePath` (`:783`) which always wins inside every service method (e.g. `pdf_tools_service.dart:36-37`), making the auto-suffix branches dead code on this path. Page-index contracts are 0-based: dialogs subtract 1 (`split_pdf_dialog.dart:34-35`, `reorder_pages_dialog.dart:22`). `_currentPassword` (default `''`) feeds `password:`/`sourcePassword:`; merge's `otherPassword` is hardcoded `''` (`pdf_viewer_screen.dart:572`).

**Where bugs cluster.** (a) The visual-flatten core (`createTemplate`+`drawPdfTemplate`, `pdf_tools_service.dart:26-32` etc.) silently drops forms, annotations, signatures, bookmarks, metadata from every rebuild operation. (b) Native-handle leak on any thrown load (`PdfDocument` dispose is success-path-only, `:46-47`). (c) `savePath` resolved via `FileConflictResolver.resolve` then the progress dialog popped via screen `context` guarded only by `mounted`, not the dialog route (`pdf_viewer_screen.dart:786/791`). (d) Out-of-range split/reorder indices silently filtered (`:106`/`:151`) → empty/invalid PDF.

### Seam 9 — GitHub manifest → `UpdateInfo.fromJson` → `downloadUpdate` → `installUpdate`

**Hand-off contract.** `checkForUpdate → UpdateInfo?` where `null` overloads "no update / throttle-skip / error". `UpdateInfo.fromJson` does unchecked casts on network JSON (`update_info.dart:16-26`). `downloadUpdate(url, onProgress) → File?` (null = any failure); the only validation is `>1000` bytes + `PK` magic (`update_service.dart:157-170`). `installUpdate(File) → OpenResult`. `forceUpdate` is consumed only to hide the "Later" button (`update_dialogs.dart:50`).

**Where bugs cluster.** No TLS pinning/signature/hash check anywhere → MITM controls `downloadUrl` and a `PK`-prefixed malicious APK installs (RCE). Triplicated `_performUpdate` (`update_dialogs.dart:116`, `main.dart:888`, `settings_screen.dart:897`) drift; the startup path even uses two different impls (`main.dart:608` global vs `:882` member). `forceUpdate` dialogs are barrier-/back-dismissible (no `barrierDismissible:false`/`PopScope`).

---

## Verified Bug Ledger

| Severity | Subsystem | file:line | Trigger | Consequence | Fix idea |
|---|---|---|---|---|---|
| security | self-update | update_service.dart:157-170 | Any attacker ZIP ≥1000B starting `PK` (via MITM'd manifest) | Arbitrary APK installed — full RCE supply-chain path | Verify SHA-256 + signing cert from manifest before install |
| security | self-update | update_service.dart:15,101-104 | MITM / compromised CA on manifest fetch | Attacker dictates downloadUrl/buildNumber/forceUpdate | TLS cert pinning; verify origin |
| security | self-update | update_service.dart:118,131,139 | Manifest downloadUrl or redirect to any host | Arbitrary download source (cross-origin redirect followed) | Host allow-list; disable cross-origin redirects |
| security | pdf-unlock / dev-tools | encryption_service.dart:20 | Decompile/read binary | Hardcoded `Portal123!` gates dev mode + reveals master key | Server/salted-hash verification; remove literal |
| security | pdf-unlock | encryption_service.dart:105-107,132-133 | Any stored password | XOR-with-repeating-key over base64 in clear-text prefs is trivially reversible → all PDF passwords effectively plaintext | AES-GCM via platform keystore |
| security | dev-tools | settings_screen.dart:715 | Dev mode enabled, tap "Developer Tools" | Ungated push of DeveloperScreen — password gate fully bypassed | Move auth check inside DeveloperScreen / remove Entry B |
| security | dev-tools | developer_screen.dart:41,53 | Reach screen (incl. ungated path) | Raw master encryption key shown as copyable SelectableText | Fresh password prompt; never display raw key |
| security | auth | biometric_service.dart:62 | Any unlock with biometrics on | `biometricOnly:false` lets device PIN bypass app PIN + lockout | Set `biometricOnly:true`; route PIN via verifyPin |
| security | auth | biometric_lock_screen.dart:140-181; pin_entry_screen.dart:32-127 | Wrong PIN ≥5 times | Lockout counters are UI-only; unlimited 10⁴ brute-force; reset on rebuild | Gate input on attempts; persist count + backoff |
| security | auth | settings_service.dart:209,232 | PIN set | PIN stored plaintext; non-constant-time `==` compare | Salted hash (PBKDF2/scrypt) |
| security | auth | main.dart:644-650,657 | `ignoreNextPause` consumed by a real background event | backgroundTime left null → resume never locks regardless of elapsed time | Scope exemption to a specific expected event w/ expiry |
| security | auth | main.dart:665 | Backgrounded < timeout+1 whole minutes | `inMinutes` floors → auto-lock never trips for the interval | Compare `inSeconds >= timeout*60` |
| security | export-queue | export_queue_service.dart:76,91 | Any password-protected export | zipPassword persisted plaintext in export_jobs, never cleared | Never persist; null after encode |
| security | export-queue | export_queue_service.dart:515 | Job name with `/` or `..` (temp-path branch) | Path traversal — write outside temp dir | Sanitize name in both branches |
| security | storage-sqlite | storage_service.dart:515,521,527 | Future caller passes user-controlled table/idColumn/data keys | SQL injection / arbitrary-table access (today safe only by caller discipline) | Validate table/columns against whitelist inside helpers |
| security | self-update | update_dialogs.dart:50,107; main.dart:878; settings_screen.dart:883 | `forceUpdate==true` | Barrier-/back-dismissible → forced update trivially bypassed | `barrierDismissible:false` + `PopScope` |
| data-loss | device-scan | device_document_service.dart:163-174,176,228-232 | Any `syncAndIndex()` over curated rows | REPLACE + sweep wipe is_new/is_imported/added_at/missing_on_device every scan | Preserve via UPDATE/COALESCE; exclude imported rows from sweep |
| data-loss | document-service | document_service.dart:901-903 | One malformed stored record | `clear()` then map throws → entire library blanked, next save overwrites with `[]` | Per-record try/catch; decode before clear() |
| data-loss | all-docs | all_documents_screen.dart:758-763,769 | Overwrite-import where importFile then fails | Original deleted before import, never restored — permanent loss | Import to temp then atomic swap |
| data-loss | pdf-tools | pdf_tools_service.dart:26-32,108-114,153-159,198-204 | Remove-pw/reorder/split/merge on signed/form PDF | Visual flatten silently drops forms, annotations, signatures, bookmarks, metadata | Use importPageRange; warn on forms/sigs |
| data-loss | document-service | document_service.dart:838,854 | `deleteFromDevice:true` on zero-copy reference | Permanently deletes the user's original source file | Confirm caller intent; guard |
| data-loss | document-service | document_service.dart:399-401 | Sync a folder with any missing file | `every(!missing)` gate skips save → lastSynced lost on reload | Unconditional save for timestamp |
| crash | document-service | document_service.dart:708,742,273,319,844-847 | Move folder into its own descendant | No cycle check → infinite recursion / stack overflow in sync/delete | Ancestor check before move |
| crash | dashboard-pt2 | document_dashboard_screen.dart:251-252 | Rename-import of extension-less colliding filename | `substring(0,-1)` RangeError aborts import | Guard `parts.length>1` |
| crash | dashboard-pt2 | document_dashboard_screen.dart:1390,1463 | Selected id deleted concurrently / case-dup dest | `firstWhere` no `orElse` throws → whole move aborts | Add `orElse`/`firstOrNull` |
| crash | document-service | document_service.dart:450 | Export folder deleted between render and call | `getPhysicalPathForFolder` firstWhere no orElse → StateError | orElse fallback to baseDir |
| crash | storage-sqlite | storage_service.dart:156,195,209-223 | Partially-migrated DB, table already exists | CREATE TABLE/INDEX without IF NOT EXISTS aborts upgrade → DB unreachable | Add IF NOT EXISTS to these steps |
| crash | storage-sqlite | storage_service.dart:531-534 | `close()` then later `database` getter | Re-opens then never nulls `_database` → returns closed-DB handle | Guard on `_database`; null after close |
| crash | export-queue | export_queue_service.dart:96,100 | Row with null/unknown status or null created_at | `firstWhere` no orElse / `fromMillisecondsSinceEpoch(null)` throws → job silently dropped | orElse fallback; null-guard createdAt |
| crash | pdf-tools | pdf_tools_service.dart:20,65,101,146,211,217 | Wrong password / corrupt input | dispose success-path-only → native handle + RAM leak on every failure | try/finally dispose |
| crash | dashboard/all-docs | document_dashboard_screen.dart:1743,1788; pdf_viewer_screen.dart:177; all_documents_screen.dart:442 | Navigate away during await | Unguarded Navigator.pop/push on stale context → wrong-route pop / deactivated-widget crash | Capture dialog Navigator; `if(!mounted)return` |
| crash | dashboard/all-docs/auth | document_dashboard_screen.dart:285,785,1549; biometric_lock_screen.dart:114,175; pin_entry_screen.dart:117 | dispose during async loop | setState-after-dispose | Guard `mounted` after await |
| crash | self-update | update_info.dart:21-24 | Manifest emits buildNumber as string / non-bool forceUpdate | Unchecked `as` cast throws, swallowed → update silently never offered | `int.tryParse(...toString())` |
| crash | all-docs | all_documents_screen.dart:216 | getDocuments throws on page 2 | No try/finally → `_isLoadingMore` stuck true, paging dead | Wrap in try/finally |
| crash | dashboard-pt2 | document_dashboard_screen.dart:3267 | deleteItem throws mid multi-delete loop | No try/finally → `_isLoading` stuck true (spinner forever) | try/finally reset |
| correctness | pdf-unlock | pdf_password_service.dart:84 (consumed dashboard:1708) | Encryption key missing/changed | decrypt→null treated as "no stored password" → re-prompt despite stored association | Distinguish "no entry" from "decrypt failed" |
| correctness | pdf-unlock | document_dashboard_screen.dart:1708-1721 | Stored password stale/changed externally | Viewer opens with wrong password, no fallback to brute-force/manual | verifyPassword before trusting |
| correctness | pdf-unlock | pdf_viewer_screen.dart:170,177 | User taps "No Password" (`''`) on prompt | `''` fails `isNotEmpty` → pops viewer instead of empty-pw open | Treat non-null (incl `''`) as a real attempt |
| correctness | pdf-unlock | pdf_password_service.dart:58-62,115-118 | Two unrelated PDFs named `statement.pdf` | Filename-only fallback leaks/clears passwords across distinct files | Match on content hash or full path |
| correctness | pdf-unlock | pdf_viewer_screen.dart:146 | Pool password never used for this doc | Viewer auto-try uses `_documentPasswords`, not StorageService pool → asymmetric | Unify candidate source |
| correctness | document-service | document_service.dart:116,491 | Distinct files of equal byte length | Size-only dedup → false "duplicate", import blocked/mismerged | Content hash |
| correctness | document-service | document_service.dart:596,617 | Two items created same millisecond | Duplicate ids; removeWhere deletes both (857) | UUID |
| correctness | document-service | document_service.dart:534 vs 346; 666-678; 749-763 | Move/remove edits only fileIds or only parentId | File shown-but-missing / missing-but-shown / orphaned on folder delete | Single source of truth |
| correctness | device-scan | device_document_service.dart:288 | Search query matches >100 files | `.take(100)` caps before SQL paging → results beyond 100 unreachable | Push search into SQL (LIKE) |
| correctness | dashboard-pt1/pt2 | document_dashboard_screen.dart:343,2386,2599 | Add/move/delete; or switch filter | `_folderCountCache` never invalidated + key ignores filter → stale folder counts | Clear/version cache on mutate + per-filter key |
| correctness | dashboard-pt1 | document_dashboard_screen.dart:2065 | Search-result navigation | Selection not cleared → ghost selection acts on off-screen items | Clear selection in search setState |
| correctness | dashboard-pt1 | document_dashboard_screen.dart:2218 vs 2239-2244 | Long pull-to-sync, 200ms ScrollEnd reset wins | Deliberate long-pull silently downgrades to plain refresh | Let onRefresh own the reset |
| correctness | dashboard-pt2 | document_dashboard_screen.dart:1939 | encrypt returns null with "save to list" checked | Password silently not saved; dialog reports success | Surface failure in errorMessage |
| correctness | all-docs | all_documents_screen.dart:247-265 | Filter change | Inline query skips sortDocuments + try/catch → wrong order, unhandled throw | Route through _loadDocuments |
| correctness | all-docs | all_documents_screen.dart:128 | Rapid 300ms-spaced searches | No request-id → stale completion can land after newer one | Monotonic request token |
| correctness | all-docs | all_documents_screen.dart:440 vs 545 | Same PDF opened via two paths | Password keyed on sourcePath vs raw path → wrong/null password | Unify on canonical path |
| correctness | self-update | update_service.dart:196 vs :123 | Every download (writes `update_<epoch>.apk`) | cleanupUpdateFile only deletes `update.apk` → APKs accumulate forever | Glob `update_*.apk` |
| correctness | self-update | update_info.dart:21 + update_service.dart:85-91 | Manifest missing buildNumber → parses to 0 | `_clearUpdateFlag` wipes a valid pending update flag | Distinguish parse-fail from 0 |
| correctness | self-update | update_service.dart:163-165 | raf.read(2) throws | No try/finally → leaked RandomAccessFile handle | try/finally close |
| correctness | dev-tools | developer_screen.dart:443 vs 252 | Default descending sort | Double-reverse → list shows oldest-first, contradicting "Latest First" | Index `_logs[index]` |
| correctness | dev-tools | developer_screen.dart:429-430 | Tap clear logs | `clearLogs()` unawaited then `_loadLogs()` → stale logs reappear | await clearLogs |
| correctness | dev-tools | developer_screen.dart:233-235 vs 449-452 | Logs stored as 'INFO'/'ERROR' | Count match (contains) vs row icon (`==`lowercase) disagree → all rows show info icon | Normalize level at ingestion |
| correctness | dev-tools | developer_screen.dart:700,644 | Edit numeric column | TEXT written to int/real columns | Coerce by original runtime type |
| correctness | dev-tools | developer_screen.dart:705,746 | Edit/delete row in files_index (PK=path) | `idColumn='id'` → SQLite error or 0-row no-op | Derive PK column per table |
| correctness | export-queue | export_queue_service.dart:357-371 | Re-entrant _processQueue (addJob + timer + tail) | maxConcurrent over-subscription | Synchronous in-flight counter/mutex |
| correctness | export-queue | export_queue_service.dart:385,486 | Two job ids hash-collide | Wrong job's notification overwritten/cancelled | Incrementing int id per job |
| correctness | export-queue | export_queue_service.dart:218-222 | App restart with interrupted job | In-memory force-fail not persisted → DB stays inProgress | _persistJob in recovery block |
| correctness | export-queue | export_queue_service.dart:420 | Non-folder item with null filePath / deleted file | Silently skipped, processedItems not incremented → omitted with no error | Count skips; surface partial-export flag |
| correctness | dashboard-pt2 | document_dashboard_screen.dart:1289/521 | Check "encrypt" then clear field | Empty-but-non-null password → ZIP "encrypted" with `''` | Treat `''` as null |
| correctness | device-scan | device_document_service.dart:278,237 | Search before scan / after sweep | Stale `_cachedPaths` (only refreshed when empty) → wrong/fewer search hits | Invalidate cache every sync |
| correctness | device-scan | device_document_service.dart:388 | iOS / non-primary storage / SD card | Hardcoded `/storage/emulated/0` → nothing indexed off primary storage | Derive roots from getExternalStorageDirectories |
| correctness | storage-sqlite | storage_service.dart:487 vs 476 | Clock skew / non-ISO timestamps | getLogs orders by TEXT timestamp, pruning by id → "newest" ≠ "kept" | Order by id DESC |
| correctness | dashboard-pt2 | document_dashboard_screen.dart:766-769 | Rename-on-import | Copies renamed file into source dir (not cache) → pollutes user storage, breaks zero-copy | Copy to app cache |
| correctness | dashboard-pt1 | document_dashboard_screen.dart:1990,1992 | Current folder deleted concurrently | navigateUp orElse-empty → null parentId → dumped to root | Re-derive from stored parent stack |
| correctness | document-service | document_service.dart:1042,1058 | Recursive import, child listed before parent in stream | `parentId ?? rootFolder.id` → misfiled into root | Two-pass: create all dirs first |
| correctness | pdf-tools | pdf_tools_service.dart:289-307 | Large/incremental/xref-stream PDF; or literal `/Encrypt` in first/last 2KB | isProtected false-negative (no prompt) / false-positive | Fall through to Syncfusion fallback on clean miss |
| correctness | pdf-tools | pdf_viewer_screen.dart:572 | Merge with encrypted second file | Hardcoded `otherPassword:''` → merge fails | Prompt for second file's password |
| correctness | self-update | update_dialogs.dart:116; main.dart:888; settings_screen.dart:897 | Maintenance | Triplicated divergent _performUpdate; (B)/(C) discard install result + no setState guard | Collapse to single global impl |
| smell | document-service | document_service.dart:869-870 | Every delete | Redundant double `_saveDocuments` → 2× I/O | Drop line 870 |
| smell | dashboard-pt2 | document_dashboard_screen.dart:1624,1183,1311,1488,1901,572,1087 | Repeated dialogs | TextEditingControllers never disposed (1901 recreated each rebuild → caret reset) | Dispose / hoist into State |
| smell | dev-tools | developer_screen.dart:68,267,641,754 | Each key-set/edit/export | Controllers never disposed → leak | Dispose |
| smell | export-queue | export_queue_service.dart:238 | Teardown | `_notificationTapController` never closed; no dispose() override | Add dispose() |
| smell | device-scan | device_document_service.dart:119-129 | Every sync | `existingFiles` prefetch is dead code (full-table scan, result unused) | Delete or repurpose to preserve curated columns |
| smell | self-update | update_service.dart:20-36 | Every init | initialize() computes currentBuild then does nothing | Remove dead code |
| smell | document-service | document_service.dart:1022-1037 | — | Dead deliberation comment block left in source | Delete |
| smell | pdf-unlock | pdf_password_service.dart:66-67 | Open a migrated file | Disk write (`_save`) inside a getter; concurrent-open race clobbers aliases | Make getter pure; explicit migrate step |

---

## Highest-leverage fixes

1. **Replace XOR + hardcoded `Portal123!` with real crypto and a proper gate** (`encryption_service.dart:20,105-107,132-133`; `pdf_password_service.dart`): use AES-GCM via platform keystore, salted-hash the dev password and PIN, and stop displaying the raw key (`developer_screen.dart:53`) — this single change neutralizes the password store, the dev gate, and the PIN store at once.

2. **Verify the update before installing and pin the manifest** (`update_service.dart:15,101-104,157-170`): add TLS pinning, a manifest-supplied SHA-256 + signing-cert check, and a download-host allow-list — closes the RCE supply-chain path, the most severe finding in the whole app.

3. **Stop `DeviceDocumentService.syncAndIndex` from destroying curated metadata** (`device_document_service.dart:163-176,228-232`): preserve `is_new`/`is_imported`/`missing_on_device`/`added_at` via COALESCE/UPDATE and scope the sweep to `is_imported = 0`, so imports and badges survive a scan — fixes the structural incompatibility between the `files_index` and `DocumentService` indexes.

4. **Serialize all `DocumentService._items` mutations and replace size-only dedup + timestamp IDs** (`document_service.dart:116/491,596/617,913-917`): a write mutex plus UUIDs and a content hash eliminates lost-update races, duplicate-id double-deletes, and false-positive duplicate blocking in one pass.

5. **Make the auto-lock and biometric flow actually enforce** (`main.dart:644-650,657,665`; `biometric_service.dart:62`; `biometric_lock_screen.dart:140-181`): compare `inSeconds`, drop the global `ignoreNextPause` one-shot, set `biometricOnly:true`, and persist a real attempt counter with backoff — turns the decorative lock into a real boundary.

6. **Disambiguate the password-store sentinel and stop trusting stale associations** (`pdf_password_service.dart:84`; `document_dashboard_screen.dart:1708-1721`; `pdf_viewer_screen.dart:170`): distinguish "no entry" from "decrypt-failed," `verifyPassword` before trusting a stored association, and treat the `''` "No Password" choice as a real open attempt — fixes the most common unlock-flow misbehaviors.

7. **Harden the rebuild PDF operations** (`pdf_tools_service.dart:20-217`): wrap every method in `try/finally` for `PdfDocument.dispose()` and switch from `createTemplate`/`drawPdfTemplate` to page import — stops native-handle leaks and the silent destruction of forms/annotations/signatures on remove-password/split/merge.

8. **Add `IF NOT EXISTS` to the migration `CREATE TABLE/INDEX` steps** (`storage_service.dart:156,195,209-223`): prevents a partially-migrated DB from permanently bricking all SQLite access, a low-effort fix for a high-blast-radius crash.

---

# Appendix A — AES vs XOR: Why the Encryption Is Broken (and How to Fix It)

> This expands on Security finding **#2 (XOR "encryption")** and the password-store findings. It is the single most important thing to understand about this app's security posture, because for a *password manager* the cipher is the whole product.

## What the app does today

`EncryptionService.encrypt/decrypt` (`encryption_service.dart:89-141`) is **repeating-key XOR + base64**, not a real cipher:

```dart
// encrypt (encryption_service.dart ~:105-107)
for (var i = 0; i < plainBytes.length; i++) {
  encrypted.add(plainBytes[i] ^ keyBytes[i % keyBytes.length]); // repeating key
}
return base64Encode(encrypted);

// decrypt (~:132-133) — XOR is its own inverse
for (var i = 0; i < cipherBytes.length; i++) {
  decrypted.add(cipherBytes[i] ^ keyBytes[i % keyBytes.length]);
}
```

The same single key (`flutter_secure_storage` key `encryption_key`) encrypts **every** value, and for per-document passwords the base64-XOR blob is stored in **clear-text SharedPreferences** (`document_passwords`), not even the keystore (`pdf_password_service.dart`).

## Why repeating-key XOR is obfuscation, not encryption

1. **It is the Vigenere cipher** — broken since the 1800s. base64 is encoding, not secrecy.
2. **Known-plaintext = instant key recovery.** `ciphertext XOR plaintext = key`. Any single known/guessed stored value (a password the attacker set, common PDF-password shapes, or the `'NO_PASSWORD'` sentinel that lives in the same store) yields key bytes. Because the key *repeats*, recovering a few bytes recovers the whole key — which then decrypts **every** stored password.
3. **Key reuse leaks relationships.** One key for everything means `c1 XOR c2 = p1 XOR p2`: XOR two ciphertexts together and the key cancels, leaking how the plaintexts relate (crib-dragging).
4. **No integrity / authentication.** XOR is *malleable*: flipping a bit in the ciphertext flips the same bit in the decrypted password, undetectably. There is no MAC, so the code cannot distinguish "wrong key" from "corrupted data" (it merely catches the `utf8.decode` exception).
5. **Length leakage.** XOR does not pad, so ciphertext length reveals the password length.
6. **Key is on the same device, cached in plaintext in memory** for the app lifetime, and is **non-rotatable** (`setEncryptionKey` refuses to overwrite once set, `encryption_service.dart:36-39`).

Net: it stops a casual person from reading the prefs file; it does **not** stop anyone who actually tries. For a password manager, the core promise fails.

## What AES is, and why it fixes this

AES (Advanced Encryption Standard) is the vetted, standardized block cipher (128-bit blocks; 128/256-bit keys; decades of cryptanalysis, no practical break). Use it in **AES-GCM** (Galois/Counter Mode), an *authenticated* mode that provides confidentiality **and** integrity at once.

| Property | Repeating-key XOR (current) | AES-256-GCM (recommended) |
|---|---|---|
| Confidentiality | Trivially reversible | Computationally infeasible to break |
| Known-plaintext attack | Recovers the whole key | Useless to the attacker |
| Same input encrypted twice | Identical ciphertext (leaks) | Different each time (random nonce) |
| Tamper detection | None (malleable) | Built-in 128-bit auth tag rejects any change |
| Wrong key vs corruption | Indistinguishable | Tag fails cleanly |
| Standardized / audited | No (homemade) | Yes (NIST FIPS-197 / SP 800-38D) |

Recipe:
- A fresh random **nonce/IV** per encryption (so the same password encrypts differently every time).
- Key from the **Android Keystore / iOS Keychain** (hardware-backed, non-extractable) via `flutter_secure_storage`, **or** derived from a user **master passphrase** using **PBKDF2 / scrypt / Argon2id + per-vault salt** (better for a *portable* backup — ties into Feature 5 Backup/Restore).
- Store `base64(nonce ‖ ciphertext ‖ tag)`.
- Dart packages: `cryptography` (AES-GCM, X25519, Argon2) or `pointycastle`.

## Migration (the key is currently non-rotatable)

Because existing data is XOR-encrypted under a non-rotatable key, a one-time migration is required:
1. On first launch after the change, for each stored value: XOR-decrypt with the **old** key, then AES-GCM-encrypt with the **new** key, then save.
2. Keep the old key until migration completes, then remove it.
3. Gate this behind a version flag so it runs exactly once.

## Bottom line for an interview

> "I shipped a personal build using XOR as a stand-in cipher — it's effectively obfuscation. The first thing I'd harden for any real release is the crypto: swap to **AES-256-GCM** with a per-message nonce and an authentication tag, key it from the platform keystore (or a passphrase-derived key via Argon2id for portable backups), and add a one-time migration. That single change fixes the password store, the per-document store, and gives me tamper detection I don't have today."
---

# Part U — User-Reported Bugs & Feature Requests

These items were reported by the app owner and each was traced against the real source. (1 bug + 4 feature requests.)

## Bug 1 — "Open With" reopens the previous document, not the new one

## 1. What exists today

**Static holder** — `PendingFileOpen` (`lib/main.dart:36-64`). `clearOpen()` nulls `filePath/fileName/isTemporary` (`:50-54`); `hasPending => filePath != null` (`:63`).

**Cold-start path** — `_checkInitialIntents()` (`lib/main.dart:323-337`), called from `initState` (`:306`):
```
final sharedFiles = await ReceiveSharingIntent.instance.getInitialMedia();   // :325
if (...) { PendingFileOpen.filePath = file.path; ReceiveSharingIntent.instance.reset(); }  // :329-331
```

**Hot path (stream)** — `getMediaStream().listen(...)` in `initState` (`lib/main.dart:313-320`) → `_handleSharedFiles(value)` when non-empty.

**Resume path** — `didChangeAppLifecycleState`, `resumed` branch (`lib/main.dart:654-700`). After the auto-lock check, at `:696-699`:
```
if (!_isProcessingIntent) {
  _checkForPendingIntent();
}
```
`_checkForPendingIntent()` (`:703-715`):
```
final media = await ReceiveSharingIntent.instance.getInitialMedia();   // :705  <-- RE-READS INITIAL MEDIA
if (media.isNotEmpty) {
  _handleSharedFiles(media);            // :708
  ReceiveSharingIntent.instance.reset();// :709
}
```

**`_handleSharedFiles`** (`lib/main.dart:354-585`) sets `PendingFileOpen.filePath/fileName` (`:509-510`) and, only if `_isAuthenticated`, navigates to `MainScreen(initialIndex:1)` (`:516-521`).

**Dashboard drain** — `_initialize` (`lib/features/documents/screens/document_dashboard_screen.dart:342-399`). At `:368-393`: if `PendingFileOpen.hasPending`, it reads `filePath`, calls `PendingFileOpen.clearOpen()` (`:372`), then `findFileIdByPath` (`:375`) → `_openDocument` or fallback `PdfViewerScreen(isExternal:true, deleteOnClose:isTemp)` (`:381-391`).

**Android side** — `MainActivity` is `android:launchMode="singleTask"` (`AndroidManifest.xml:21`) with `SEND`/`VIEW` filters.

## 2. Root cause

The mechanism is **stale `getInitialMedia()` re-read on resume, combined with `singleTask` launch mode**.

Branch-by-branch for the reported scenario (open A, background, open B):

1. **Open A (cold start):** Activity launches with intent A. `_checkInitialIntents` reads A via `getInitialMedia()` (`:325`), sets `PendingFileOpen.filePath = A`, and calls `reset()` (`:331`). A opens correctly. So far so good.

2. **App backgrounded.** Process stays alive (user "closed/backgrounded for a while" but Android kept it).

3. **Open B via "Open With":** Because `launchMode="singleTask"` (`AndroidManifest.xml:21`), Android does **not** create a new Activity. The existing Activity is brought to front and intent B is delivered via **`onNewIntent`**. In `receive_sharing_intent` 1.8.1, `onNewIntent` pushes B onto the **`getMediaStream`** sink — it does **not** repopulate the value returned by `getInitialMedia()`. The stream listener (`:313`) fires with B and `_handleSharedFiles([B])` runs, setting `PendingFileOpen.filePath = B`. Good — but now the resume branch also runs.

4. **The resume branch double-fires the OLD intent.** Bringing the Activity to front triggers `AppLifecycleState.resumed` → `didChangeAppLifecycleState` (`:654`). At `:696` it checks `!_isProcessingIntent` and calls `_checkForPendingIntent()` (`:698`), which calls `getInitialMedia()` **again** (`:705`).

   Here is the defect: **`getInitialMedia()` returns whatever the native layer still holds as the initial launch intent.** The earlier `reset()` at `lib/main.dart:331` was on the *original* plugin state, but the relationship between the native cached initial intent and `reset()` across a `singleTask` re-entry is exactly the "zombie intent" the code's own comment at `:330` was trying to kill — and it does not reliably stay cleared. On the resume after opening B, `getInitialMedia()` resolves with the **stale A** intent (the launch intent that originally started the still-alive process), so `_handleSharedFiles([A])` runs and **overwrites** `PendingFileOpen.filePath = B` back to `A` (`:509`).

5. **Race / ordering decides the winner.** Both `_handleSharedFiles([B])` (from the stream) and `_handleSharedFiles([A])` (from resume) target the same global `PendingFileOpen`. They are gated by the `_isProcessingIntent` latch (`:356-359`, reset in `finally` `:582`), so they **serialize** rather than merge. Whichever finishes last writes `PendingFileOpen.filePath`. The resume callback frequently runs after the stream settles, so **A wins**, and the dashboard drain (`document_dashboard_screen.dart:368-393`) opens A.

Why the symptom is specifically "old A, not new B": the only source of "A" after step 1 is the stale `getInitialMedia()` value re-read at `:705`. The stream path can only ever deliver B. So the bug is unambiguously the resume-time `getInitialMedia()` re-read resurrecting the launch intent.

Contributing factors:
- `_handleSharedFiles` always writes `PendingFileOpen.filePath` (`:509`) with **no guard** that the file equals the one already pending or that this is a newer intent — so a stale resume read silently clobbers a fresh stream read.
- `reset()` is called *after* `_handleSharedFiles` in `_checkForPendingIntent` (`:709`, async) — the re-read at `:705` already returned stale A before any reset for this cycle.
- The dashboard drain clears via `clearOpen()` (`:372`) but that only runs once the dashboard rebuilds; between the two `_handleSharedFiles` calls nothing clears the global, so the last writer wins.

## 3. Implementation plan

Minimal, targeted fix. Two coordinated changes in `lib/main.dart`; no new files/models needed.

**Change A — stop the resume branch from re-reading the launch intent.** The `getMediaStream` listener (`:313`) already handles every intent delivered to a live `singleTask` Activity via `onNewIntent`. `_checkForPendingIntent()` is only needed for intents that arrived *while the Dart side wasn't listening* — which is the cold-start case already covered by `_checkInitialIntents()`. The resume re-read is pure double-handling. Make `_checkForPendingIntent` consume-once: track whether the initial media was already drained and skip the re-read.

- Add a one-shot guard flag `_initialIntentConsumed` (instance field on `_AppEntryState`, near `:294`).
- In `_checkInitialIntents` set `_initialIntentConsumed = true` once it has read media (after `:329`).
- In `_checkForPendingIntent` (`:703`) early-return if `_initialIntentConsumed` is already true — the stream is authoritative for hot intents.

**Change B — make `_handleSharedFiles` reset the native initial media immediately after consuming, and have the dashboard clear deterministically.** Move `ReceiveSharingIntent.instance.reset()` to fire right after the value is captured (before the async file loop), so a subsequent resume can never re-read the same intent. Reuse the existing `reset()` call (currently `:331` and `:709`); centralize it at the top of `_handleSharedFiles`.

**Change C (defensive, reuses existing code):** The dashboard drain already calls `PendingFileOpen.clearOpen()` (`document_dashboard_screen.dart:372`) — keep it, it is correct. No change there.

Net effect: only the stream delivers B, the stale A can never be re-read, and `PendingFileOpen.filePath` ends as B.

## 4. Code sketch

```dart
// _AppEntryState fields (near lib/main.dart:294)
bool _isProcessingIntent = false;
bool _initialIntentConsumed = false; // NEW: one-shot guard for cold-start media

Future<void> _checkInitialIntents() async {
  try {
    final sharedFiles = await ReceiveSharingIntent.instance.getInitialMedia();
    _initialIntentConsumed = true;                       // NEW: claim it once
    if (sharedFiles.isNotEmpty && sharedFiles.first.path != null) {
      PendingFileOpen.filePath = sharedFiles.first.path;
      ReceiveSharingIntent.instance.reset();
    }
  } catch (e) {
    LoggingService().error('App', 'Error checking initial intents', e);
  }
}

Future<void> _checkForPendingIntent() async {
  // Hot intents arrive via getMediaStream (onNewIntent) under singleTask.
  // getInitialMedia() here would re-surface the STALE launch intent → Bug 1.
  if (_initialIntentConsumed) {
    _log.info('AppEntry', 'Initial media already consumed - skipping resume re-read');
    return;
  }
  try {
    final media = await ReceiveSharingIntent.instance.getInitialMedia();
    _initialIntentConsumed = true;
    if (media.isNotEmpty) {
      ReceiveSharingIntent.instance.reset();   // reset BEFORE async handling
      _handleSharedFiles(media);
    }
  } catch (e) {
    _log.error('AppEntry', 'Error checking pending intent', e);
  }
}
```

(Optional hardening in `_handleSharedFiles`: call `ReceiveSharingIntent.instance.reset()` at entry, immediately after `_isProcessingIntent = true` at `:361`, so any path that consumes the stream also invalidates the native initial cache.)

## 5. Edge cases & risks

- **True cold start still works:** if the process was killed and relaunched for B, `getMediaStream` won't have fired, but `_checkInitialIntents` (`:306`) reads B fresh and sets `_initialIntentConsumed=true`; the resume guard then correctly suppresses a re-read of the same B (no double-open).
- **Auth gate timing:** when auth is on, `_handleSharedFiles` only stages `PendingFileOpen` and does not navigate (`:516-524`); the dashboard drains it post-auth (`document_dashboard_screen.dart:368`). The fix doesn't change this, but verify the stream's B is staged before the lock screen is dismissed — it is, since both write the same global.
- **`content://` paths / temp copies:** `_handleSharedFiles` may rewrite `finalPath` and set `isTemporary=true` (`:457-486`). With the stale-A clobber removed, `deleteOnClose:isTemp` (`document_dashboard_screen.dart:388`) now correctly reflects B, not A — previously it could mismatch.
- **Missing `DocumentItem` on external open:** `findFileIdByPath` (`document_service.dart:552`) returns null for temp/external files, so the fallback `PdfViewerScreen(isExternal:true)` path is the norm for "Open With"; ensure B's path is what reaches it.
- **`_isProcessingIntent` latch:** the resume branch already guards on it (`:696`); with the re-read gone there's no second `_handleSharedFiles` competing, so the serialize-and-last-writer-wins race disappears.
- **Plugin internals:** behavior of `reset()` vs `getInitialMedia()` is version-specific (1.8.1, `pubspec.lock`). The fix does not *rely* on `reset()` clearing native state — the `_initialIntentConsumed` guard is the real protection — so it is robust even if `reset()` is a no-op for the cached initial intent.
- **Non-rotatable XOR key / persistence backends:** irrelevant to this intent path; no interaction.
- **Multi-file `SEND_MULTIPLE`:** unaffected — guard is per-app-launch, not per-file.

## 6. Effort

**Size: S.** ~10–15 lines in a single file (`lib/main.dart`), one new bool field, no new files/models/migrations.

Touched subsystems:
- Share-intent lifecycle (`lib/main.dart` `_AppEntryState`: `_checkInitialIntents` `:323`, `_checkForPendingIntent` `:703`, optionally `_handleSharedFiles` `:354`).
- Reads-only dependency: dashboard drain (`document_dashboard_screen.dart:368-393`) and `PendingFileOpen` (`main.dart:36-64`) — no change required.

Key evidence lines: stale re-read `lib/main.dart:705`; clobber `:509`; cold-start consume+reset `:325-331`; resume trigger `:696-698`; `singleTask` `AndroidManifest.xml:21`; dashboard drain `document_dashboard_screen.dart:368-393`.

---

## Feature 2 — "Remove password from PDFs" checkbox on ZIP export

## 1. What exists today

**The two export dialogs (dashboard) are nearly identical, each with one "Protect with Password" checkbox only.**

- `_exportSelectedItems()` — `document_dashboard_screen.dart:402`. Local state `String? password; bool encrypt = false;` (`:403-404`). The dialog has a single `Checkbox` bound to `encrypt` (`:421-426`) plus a conditional ZIP-password `TextField` (`:428-438`). After confirm: `final zipPassword = encrypt ? password : null;` (`:461`). Builds `ExportItem`s (`:484-509`) and calls `_exportQueue.addJob('Bulk Export', exportItems, exportDir: exportPath, zipPassword: zipPassword);` (`:521`).
- `_exportFolderAsZip(folder)` — `:1230`. Same pattern: `:1231-1232`, checkbox `:1249-1254`, `final zipPassword = encrypt ? password : null;` (`:1289`), `addJob(folder.name, items, exportDir: exportPath, zipPassword: zipPassword);` (`:1318`).
- `_buildExportItemsFromFolder(folderId)` — `:1144-1173`. Recursively builds `ExportItem`s from `file.sourcePath` and subfolders. **Note: it carries only `itemId`, `name`, `filePath`, `isFolder`, `children` — no protection/password info.**

**ExportItem / ExportJob models** — `export_queue_service.dart`:
- `ExportItem` (`:110-146`): fields `itemId`, `filePath`, `name`, `isFolder`, `children`. `toJson`/`fromJson` at `:125-145`. **No password/decrypt field.**
- `ExportJob` (`:18-107`): has `zipPassword` (`:27`), `exportDir`, `type`, `isDeveloper`. **No "remove inner PDF passwords" flag.** `toJson`/`fromJson` persist all fields to SQLite (`:65-106`).
- `addJob(...)` signature — `:307`: `addJob(String name, List<ExportItem> items, {String? exportDir, String? zipPassword, ExportType type, bool isDeveloper})`. Constructs the `ExportJob` at `:333-342`.

**The archive build** — this is the critical insertion point:
- `_processZipJob(job, notificationId)` — `:489`. Creates `Archive()` (`:490`), calls `_addItemsToArchive(...)` (`:493`), then encodes in an isolate: `compute(_encodeArchive, {'archive': archive, 'password': job.zipPassword})` (`:502`).
- `_addItemsToArchive(...)` — `:413-449`. For each non-folder item with a `filePath`: reads `final bytes = await file.readAsBytes();` (`:423`) and `archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));` (`:424`). **This is where original (still-encrypted) bytes go straight into the archive.** This method is `async` and runs **on the main isolate** (only the final ZIP *encoding* is offloaded via `compute` at `:502`).

**Decryption primitives already available:**
- `PdfToolsService.removePassword({filePath, password, outputDir, savePath})` — `pdf_tools_service.dart:10-51`. Loads `PdfDocument(inputBytes, password:)`, rebuilds pages into a new doc, writes to `savePath`/derived path, returns the new path. Runs synchronously on the calling isolate (confirmed by its only existing caller, `pdf_viewer_screen.dart:504` via `_runToolOperation` at `:765-795`, which calls it directly with no `compute`).
- `PdfToolsService.isProtected(filePath)` — `:261-325`. Cheap 2KB header/trailer `/Encrypt` scan; falls back to full Syncfusion load (`:328-341`).
- `PdfToolsService.verifyPassword(filePath, password)` — `:240-256`.
- `PdfPasswordService.getPasswordForDocument(filePath)` — `pdf_password_service.dart:50-85`. Returns the decrypted stored password (exact-path then filename match), `''` for `NO_PASSWORD`, or `null` if none stored. Singleton (`:10-12`).

## 2. Gap

Nothing in the pipeline can decrypt-on-export:
1. **No UI control** — both dialogs expose only the *ZIP* password checkbox (`:421`, `:1249`); there is no "remove PDF passwords inside the ZIP" toggle.
2. **No data path** — `addJob` (`:307`) has no flag, `ExportJob` (`:18`) has no field, so the worker has nothing to branch on.
3. **`_addItemsToArchive` always embeds originals** — `:423-424` reads and adds the raw on-disk bytes unconditionally; protected PDFs land in the ZIP still encrypted.
4. **No password lookup at export time** — the export pipeline never touches `PdfPasswordService`; the stored password is invisible to the queue.

The originals-stay-unchanged requirement is automatically satisfied if we decrypt to a **temp copy** and only the temp bytes are added (we never write back to `filePath`).

## 3. Implementation plan

Thread a single `bool removeInnerPasswords` flag UI → `addJob` → `ExportJob`, and branch inside `_addItemsToArchive`. **Decryption must happen on the main isolate inside `_addItemsToArchive` (before `compute` at `:502`)** — Syncfusion `PdfDocument` + `dart:io` file writes are used there today on the main isolate, and the `Archive` object is only handed to `compute` for ZIP *encoding*. Do **not** move decryption into `_encodeArchive` (`:543`): that isolate has no `PdfPasswordService`/SharedPreferences access and receives an already-built `Archive`.

**A. Model + service signature changes (`export_queue_service.dart`)**

1. `ExportJob`: add `final bool removeInnerPasswords;` near `:27`; add ctor param defaulting `false` (`:35-48`); persist in `toJson` (`:65`, e.g. `'remove_inner_passwords': removeInnerPasswords ? 1 : 0`) and read in `fromJson` (`:85`, `removeInnerPasswords: json['remove_inner_passwords'] == 1`).
2. `addJob` (`:307`): add `bool removeInnerPasswords = false` to the param list; pass it into the `ExportJob(...)` at `:333-342`.
3. Add imports at top (`:1-9`): `import 'pdf_tools_service.dart';` and `import 'pdf_password_service.dart';`.

**B. Decryption in the archive builder (`export_queue_service.dart`)**

4. `_processZipJob` (`:489`): create a per-job temp dir for decrypted copies (e.g. `Directory.systemTemp.createTempSync('export_dec_')`), pass it into `_addItemsToArchive`, and **delete it in a `finally`** after `compute` (`:502`) returns. Optionally collect a `List<String> skipped` for files that couldn't be decrypted and surface it via the completion notification (`:528`) / `job.errorMessage`.
5. `_addItemsToArchive` (`:413-449`): add params `bool removeInnerPasswords` and `Directory tempDir`. Inside the `item.filePath != null` branch, **before** `readAsBytes` (`:423`):
   - If `removeInnerPasswords` and the file ends in `.pdf` and `await _pdfTools.isProtected(path)` (reuse `:261`):
     - `final pwd = await _pwdService.getPasswordForDocument(path)` (reuse `pdf_password_service.dart:50`).
     - If `pwd != null && pwd.isNotEmpty`: `final tmp = await _pdfTools.removePassword(filePath: path, password: pwd, savePath: <tempDir>/<unique>.pdf)` (reuse `pdf_tools_service.dart:10`), then read **tmp** bytes instead of the original.
     - If no stored password (or `removePassword`/`verifyPassword` fails): **skip decryption, add the original encrypted bytes, and record the name in `skipped`** (report-not-fail; matches the app's defensive style). Wrap in try/catch so one bad PDF can't abort the whole job.
   - Else: unchanged (`:423-424`).
   - Use `await _pdfTools.verifyPassword(path, pwd)` (`:240`) first if you want to avoid a thrown exception from `removePassword` on a stale stored password.

**C. UI (`document_dashboard_screen.dart`)** — apply to **both** dialogs:

6. `_exportSelectedItems`: add `bool removeInnerPw = false;` beside `:404`; add a second `Checkbox` row (mirroring `:419-427`) labelled "Remove password from PDF files in the ZIP" inside the `Column` (`:413-439`); after confirm, pass to `addJob` at `:521`: `removeInnerPasswords: removeInnerPw`.
7. `_exportFolderAsZip`: same — state beside `:1232`, checkbox in `Column` (`:1241-1267`), pass into `addJob` at `:1318`.

No new files or models are strictly required (just a flag + a field). `ExportItem` does **not** need a password field — the password is looked up by `filePath` at export time via `PdfPasswordService`, so the existing `_buildExportItemsFromFolder` (`:1144`) is untouched.

## 4. Code sketch

```dart
// export_queue_service.dart — inside _addItemsToArchive (replaces the read at :420-424)
} else if (item.filePath != null) {
  final file = File(item.filePath!);
  if (await file.exists()) {
    List<int> bytes;
    final isPdf = item.filePath!.toLowerCase().endsWith('.pdf');

    if (removeInnerPasswords && isPdf && await _pdfTools.isProtected(item.filePath!)) {
      final pwd = await _pwdService.getPasswordForDocument(item.filePath!); // :50
      if (pwd != null && pwd.isNotEmpty &&
          await _pdfTools.verifyPassword(item.filePath!, pwd)) {           // :240
        try {
          final tmpPath = '${tempDir.path}/dec_${job.processedItems}_${item.name}';
          await _pdfTools.removePassword(                                  // :10
            filePath: item.filePath!, password: pwd, savePath: tmpPath);
          bytes = await File(tmpPath).readAsBytes(); // decrypted copy; ORIGINAL untouched
        } catch (e) {
          _log.warn('ExportQueueService', 'Decrypt failed for ${item.name}: $e');
          bytes = await file.readAsBytes();          // fall back to original
          job.skippedDecrypt.add(item.name);
        }
      } else {
        bytes = await file.readAsBytes();            // no stored password -> keep encrypted
        job.skippedDecrypt.add(item.name);
      }
    } else {
      bytes = await file.readAsBytes();              // unchanged path (:423)
    }

    archive.addFile(ArchiveFile(archivePath, bytes.length, bytes)); // :424
    // ...existing progress code (:427-445)...
  }
}
```

Fields/wiring: `final _pdfTools = PdfToolsService(); final _pwdService = PdfPasswordService();` on the service; `final List<String> skippedDecrypt = [];` on `ExportJob`; `removeInnerPasswords` threaded through `addJob`/`ExportJob`/`_processZipJob`/`_addItemsToArchive`.

## 5. Edge cases & risks

- **Isolate boundary (the big one).** Decryption must stay on the main isolate inside `_addItemsToArchive` (it runs there today; only ZIP encoding is in `compute` at `:502`). The `_encodeArchive` isolate (`:543`) cannot reach `PdfPasswordService` (SharedPreferences/`EncryptionService`) — don't move decryption there. Doing Syncfusion decryption + full-file reads on the main isolate for many/large PDFs can jank the UI and spike RAM (`removePassword` at `pdf_tools_service.dart:19-49` reads all bytes, builds a whole new `PdfDocument`, and `archive` holds *every* file's bytes in memory simultaneously before `compute`). The existing `await Future.delayed(Duration.zero)` yield (`:445`) helps but won't bound memory.
- **Missing stored password.** `getPasswordForDocument` returns `null` when nothing is stored (`pdf_password_service.dart:74-76`). Plan: skip + report (add to `skippedDecrypt`, embed original). Prompting is impossible — the worker runs in the background with no `BuildContext`.
- **Stale/wrong stored password.** Passwords are keyed by path with filename fallback (`:57-72`); after the documented path migrations a stored password may be wrong. `removePassword` will throw on a bad password — guard with `verifyPassword` (`:240`) and/or try/catch, fall back to original.
- **content:// / SAF paths.** `ExportItem.filePath` comes from `item.sourcePath`. If a `sourcePath` is a content URI rather than a real filesystem path, `File(...).exists()` (`:422`), `isProtected`'s `RandomAccessFile` open (`:269`), and `removePassword`'s `File.readAsBytes` (`pdf_tools_service.dart:19`) will all fail — the try/catch must degrade to embedding the original (or skipping), never crash the job.
- **`isProtected` false negatives/positives.** It scans only 2KB header+trailer for `/Encrypt` (`:286-307`); a linearized/oddly-structured PDF could be missed, or `/Encrypt` could appear in a non-encrypted edge case. Worst case is "embedded still encrypted" (reported) — acceptable.
- **Originals integrity.** Requirement met *only* because we write to a temp `savePath` and read that. Never pass `outputDir`/default-path that resolves next to the original, and never write back to `filePath`.
- **Temp cleanup / disk.** Decrypted temp copies must be deleted in a `finally` in `_processZipJob` even on error/throw; otherwise plaintext PDFs leak into `systemTemp`. Security note: decrypted copies briefly exist unencrypted on disk.
- **Persistence/restart.** Jobs persist to SQLite (`:452-464`) and are marked `error` on restart (`:217-222`), so a mid-flight decrypt job won't silently resume — fine. New `removeInnerPasswords`/`skippedDecrypt` need `toJson`/`fromJson` handling with null-safe defaults for old rows.
- **Non-rotatable XOR key.** Stored passwords are decrypted via the repeating-key XOR `EncryptionService`; if the key ever changed, `getPasswordForDocument` yields garbage and decryption fails → falls back to skip+report. No new exposure, but the failure mode routes through the same guard.
- **Concurrency.** Up to `maxConcurrent = 2` jobs (`:159`) run together; two jobs doing Syncfusion decryption simultaneously roughly doubles peak RAM. Give each job a *unique* temp dir to avoid collisions.
- **Folders & duplicate names.** Temp filenames must be unique (use `processedItems`/a counter, not just `item.name`) since two files in different folders can share a name.

## 6. Effort

**Size: M.** Mechanically small per file, but touches the model, the worker's hot loop, adds isolate/memory/temp-file/error-handling concerns, and duplicates the UI change across two dialogs.

Touched subsystems:
- `lib/services/export_queue_service.dart` — `ExportJob` model (+field, +`skippedDecrypt`), `addJob` (`:307`), `_processZipJob` (`:489`, temp dir + cleanup), `_addItemsToArchive` (`:413`, decryption branch), new imports.
- `lib/features/documents/screens/document_dashboard_screen.dart` — `_exportSelectedItems` (`:402`) and `_exportFolderAsZip` (`:1230`): new checkbox + state + `addJob` arg.
- Reused as-is (no change): `PdfToolsService.removePassword`/`isProtected`/`verifyPassword` (`pdf_tools_service.dart:10/261/240`), `PdfPasswordService.getPasswordForDocument` (`pdf_password_service.dart:50`), `_buildExportItemsFromFolder` (`:1144`), `_encodeArchive` (`:543`).

---

## Feature 3 — Share icon on the All-Documents-opened viewer

## 1. What exists today

**The Share button already exists in `PdfViewerScreen` and is NOT gated by `isExternal`.** It sits in the AppBar `actions` in the "normal" (not-loading, not-searching) branch:

`pdf_viewer_screen.dart:268-284`
```
] else ...[
  if (widget.isExternal)            // ← only the SAVE button is gated
    IconButton(
      icon: const Icon(Icons.save_alt),
      tooltip: 'Save to Folder',
      onPressed: () => _handleSaveFile(context),
    ),
  IconButton(                        // ← Share button: UNCONDITIONAL
    icon: const Icon(Icons.share),
    tooltip: 'Share File',
    onPressed: () => _handleShareFile(),
  ),
  IconButton(icon: const Icon(Icons.search), onPressed: _startSearch),
],
```

The share implementation to reuse is `_handleShareFile()` at `pdf_viewer_screen.dart:593-601`:
```
Future<void> _handleShareFile() async {
  try {
    await Share.shareXFiles([XFile(widget.filePath)], text: widget.fileName);
  } ...
}
```
It uses `share_plus` (`Share.shareXFiles`), imported at `pdf_viewer_screen.dart:9`.

**How All Documents opens a file** — two paths, both construct `PdfViewerScreen` WITHOUT `isExternal`/`deleteOnClose` (so both default to `false`, per the constructor at `pdf_viewer_screen.dart:36-37`):
- `_importAndOpenSingle` after import — `all_documents_screen.dart:442-450` (passes `filePath`, `fileName`, `password` only).
- `_openFile` for duplicates/existing copies — `all_documents_screen.dart:547-555` (same three params).

The "Open With" / external-intent flow opens the viewer with `isExternal: true` (that's why it shows the extra **Save** button), but the Share button is shared by both because it's outside the `if (widget.isExternal)` guard.

## 2. Gap

**There is effectively no gap — the feature is already present.** The Share `IconButton` at `pdf_viewer_screen.dart:275-279` renders for every successfully-loaded document regardless of how it was opened, because it is not wrapped in any `isExternal` condition. A document opened from All Documents (via `_importAndOpenSingle` or `_openFile`) reaches the same `else` branch and shows the share icon.

The only way the Share icon would be *missing* is during one of these AppBar states (`pdf_viewer_screen.dart:247-284`):
- `_isLoading == true` → actions render `SizedBox.shrink()` (no share until the PDF finishes loading), or
- `_isSearching == true` → only search-navigation buttons show.

So if the user reports the share icon is absent on All-Docs-opened files, the likely real causes are: (a) they looked while the PDF was still loading / on the password-required error banner (`_isLoading` never flips, so actions stay hidden — see `errorBannerBuilder` at `:428-451`), or (b) confusion with a different/stub viewer. Note the memory trap: there are **two `PdfViewerScreen` classes**; `features/pdf_tools/screens/` is a dead "temporarily unavailable" stub with no share. All Documents correctly imports the real one (`all_documents_screen.dart:4`), so that's not the issue here.

## 3. Implementation plan

No functional change is required to satisfy the literal request. Minimal options:

**Option A (recommended — verify only / no-op):** Confirm with the user that the icon appears once the PDF finishes loading. No code change.

**Option B (defensive hardening, if you want share available even while loading/on password error):** Move the Share `IconButton` out of the `_isLoading`-gated branch so it's always visible. Edit the actions list in `pdf_viewer_screen.dart` (build method, `:246-284`) to render Share before the `if (_isLoading)` switch. Reuse the existing `_handleShareFile()` (`:593`) unchanged.

**Option C (only if a separate icon on the All Documents *list* is wanted, not the viewer):** Add a Share entry to the per-row `PopupMenuButton` in `_buildDocumentItem` at `all_documents_screen.dart:1260-1279`, calling `Share.shareXFiles([XFile(file.path)])`. This needs a new `import 'package:share_plus/share_plus.dart';` in `all_documents_screen.dart` (not currently imported) and handling the `onSelected` switch (`:1262`). This is additive scope beyond the request.

No new files, models, or data-flow changes are needed for A or B.

## 4. Code sketch

Option B — make Share always present (build method actions, `pdf_viewer_screen.dart:246`):
```dart
actions: [
  // Always allow sharing the underlying file, even while loading / on password error.
  if (!_isSearching)
    IconButton(
      icon: const Icon(Icons.share),
      tooltip: 'Share File',
      onPressed: () => _handleShareFile(),   // existing impl at :593
    ),
  if (_isLoading) ...[
    const SizedBox.shrink(),
  ] else if (_isSearching && _textSearcher != null) ...[
    // ...existing search nav buttons...
  ] else ...[
    if (widget.isExternal)
      IconButton(
        icon: const Icon(Icons.save_alt),
        tooltip: 'Save to Folder',
        onPressed: () => _handleSaveFile(context),
      ),
    // (remove the now-duplicate Share IconButton that was here at :275-279)
    IconButton(icon: const Icon(Icons.search), onPressed: _startSearch),
  ],
  // ...PopupMenuButton unchanged...
],
```

## 5. Edge cases & risks

- **Path type (content:// vs real path).** All-Docs files are real filesystem paths from `DeviceDocumentService` (`File(...)`/`file.path`), so `XFile(widget.filePath)` works. The external "Open With" flow may pass a `content://` URI; `_handleShareFile` already runs there today, so no regression — but if any caller passes a content URI, `XFile` may need a resolved temp path. Not a concern for the All-Docs path.
- **Loading/error state.** With the current code (`:247-248`), Share is hidden while `_isLoading`. If the password is wrong, `_onDocumentLoaded`/`onViewerReady` never fire, `_isLoading` stays true (see `errorBannerBuilder` at `:428`), so actions stay hidden — this is the most plausible "share is missing" report. Option B fixes this by rendering Share regardless of `_isLoading`.
- **`mounted` after await.** Per the memory trap (systemic missing `mounted` guards), `_handleShareFile` already guards its `catch` with `if (mounted)` (`:597`) — fine as-is.
- **No `DocumentItem` on external/duplicate open.** Sharing only needs `widget.filePath`, which is always set, so the absence of a library `DocumentItem` (duplicate-open via `_openFile`, `all_documents_screen.dart:496`/`:515`) does not affect share.
- **XOR key / encryption, concurrency, isolates.** Not touched — share copies the on-disk file bytes via the OS share sheet; no decryption or isolate boundary involved.
- **Option C risk:** sharing from the list row shares the *unimported device file* (`file.path`), not the app-library copy, and triggers `statSync`-adjacent UI work; also needs the new `share_plus` import.

## 6. Effort

**S** (extra-small). Option A is zero code. Option B is a ~6-line reposition in one file (`pdf_viewer_screen.dart` build actions). 

Touched subsystems: PDF viewer UI (AppBar actions) only; reuses existing `share_plus` integration (`_handleShareFile`). No services, models, or persistence touched.

Files cited: `C:/Users/OYADLAPATI/source/repos/AI-LE/passwordpdf/lib/features/documents/screens/pdf_viewer_screen.dart` and `C:/Users/OYADLAPATI/source/repos/AI-LE/passwordpdf/lib/features/documents/screens/all_documents_screen.dart`.

---

## Feature 4 — "File info" entry in the PDF viewer 3-dots menu

## 1. What exists today

The viewer's overflow menu is a `PopupMenuButton<String>` at `pdf_viewer_screen.dart:287-313`. Its `onSelected` dispatch (`pdf_viewer_screen.dart:288-295`) handles exactly six values: `remove_password`, `add_password`, `reorder`, `split`, `merge`, `go_to_page`. The `itemBuilder` (`:296-311`) returns: "Go to Page", a divider, "Split PDF", "Merge PDF", "Reorder Pages", and then conditionally "Remove Password" (if `_currentPassword.isNotEmpty`) or "Add Password". There is **no** "File info" entry.

The viewer is constructed only from primitives — `filePath`, `fileName`, `password`, `isExternal`, `deleteOnClose` (`pdf_viewer_screen.dart:20-38`). It never holds a `DocumentItem`.

`FileInfoScreen` requires a full `DocumentItem`:
```
final DocumentItem file;          // file_info_screen.dart:11
const FileInfoScreen({ ... required this.file });  // :13-16
```
It reads `file.name`, `file.sourcePath`, `file.size`, `file.isPdf`, `file.createdAt`, `file.modifiedAt`, `file.id` (`:36-67`, `:82-184`). Notably `_loadOccurrences` (`:48-67`) excludes self by `f.id != file.id` and compares `f.size`, and the "Open File" button pops with the string result `'open'` (`:199`).

`DocumentService` lookup helpers available:
- `findFileIdByPath(String path)` → returns the **id string** or null (`document_service.dart:552-559`), matching on `sourcePath == path`.
- `getAllItems()` → `List<DocumentItem>` (`:509`).
- There is **no** `getItemById`/`getItem` returning a `DocumentItem` (confirmed by grep). To resolve an id to a `DocumentItem` you must scan `getAllItems()`.

`DocumentItem` has a public unnamed constructor (`document_item_model.dart:19-37`) with `id`, `name`, `type` required and everything else optional/defaulted, so a lightweight instance can be constructed on the fly.

## 2. Gap

Two things block the feature:
1. No menu entry/dispatch case exists for file info (`:288-311`).
2. The viewer has no `DocumentItem` and `FileInfoScreen` mandates one (`file_info_screen.dart:11`). For library files we can recover it via path→id→scan, but on **external open** (`isExternal == true`, e.g. a `content://`-derived temp path) the file is not in `DocumentService._items`, so `findFileIdByPath` returns null and we must synthesize a `DocumentItem` from `File.statSync()`.

## 3. Implementation plan

Minimal, single-file change to `pdf_viewer_screen.dart` (FileInfoScreen and DocumentItem are reused as-is; no model/service changes).

1. **Add import** at top of `pdf_viewer_screen.dart`:
   - `import 'file_info_screen.dart';`
   - `import '../../../models/document_item_model.dart';`
   (`document_service.dart` is already imported at line 18.)

2. **Add dispatch case** in `onSelected` (`:294`, after the `go_to_page` branch):
   `else if (value == 'file_info') await _handleFileInfo(context);`

3. **Add menu item** in `itemBuilder`. Best placement: at the **end** of the returned list (after the password item, `:310`), preceded by a `PopupMenuDivider`, so info sits visually separate from the editing tools. Value `'file_info'`, icon `Icons.info_outline`, label `'File info'`.

4. **Add new method `_handleFileInfo`** that resolves a `DocumentItem` then `Navigator.push`es `FileInfoScreen`. Resolution strategy:
   - `await DocumentService().initialize();` (FileInfoScreen also calls it, but the occurrences logic needs `_items` loaded — initializing first is safe).
   - `final id = DocumentService().findFileIdByPath(widget.filePath);`
   - If `id != null`, find the matching item via `getAllItems().firstWhere((i) => i.id == id)` (no helper exists; inline scan).
   - Else (external / not in library) build a lightweight `DocumentItem` from `File(widget.filePath).statSync()`.

No data-flow change to the viewer's constructor is needed.

## 4. Code sketch

```dart
// onSelected (after the go_to_page branch, ~line 294):
else if (value == 'file_info') await _handleFileInfo(context);

// itemBuilder, appended after the password PopupMenuItem (~line 310):
const PopupMenuDivider(),
const PopupMenuItem(
  value: 'file_info',
  child: Row(children: [Icon(Icons.info_outline), SizedBox(width: 8), Text('File info')]),
),

// New method:
Future<void> _handleFileInfo(BuildContext context) async {
  final docService = DocumentService();
  await docService.initialize();

  DocumentItem? item;
  final id = docService.findFileIdByPath(widget.filePath);
  if (id != null) {
    try {
      item = docService.getAllItems().firstWhere((i) => i.id == id);
    } catch (_) { item = null; }
  }

  // External open / not in library: synthesize from file stat.
  if (item == null) {
    final f = File(widget.filePath);
    final stat = f.existsSync() ? f.statSync() : null;
    item = DocumentItem(
      id: 'ephemeral:${widget.filePath}',     // unique, won't collide with library ids
      name: widget.fileName,
      type: DocumentItemType.file,
      sourcePath: widget.filePath,
      size: stat?.size ?? 0,
      createdAt: stat?.changed ?? DateTime.now(),
      modifiedAt: stat?.modified ?? DateTime.now(),
    );
  }

  if (!mounted) return;
  final result = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => FileInfoScreen(file: item!)),
  );
  // 'open' result is meaningless here (we're already viewing the file) — ignore it.
  if (result == 'open') { /* no-op: already open */ }
}
```

## 5. Edge cases & risks

- **External open / no DocumentItem (the key case):** `isExternal == true` files (often a temp path derived from a `content://` URI) are not in `DocumentService._items`, so `findFileIdByPath` returns null — the synthesized-item branch is mandatory, not optional. Use a non-colliding ephemeral id (e.g. prefixed). With a unique id, `_loadOccurrences` (`file_info_screen.dart:56-59`) excludes self correctly and only matches real library files by size.
- **Occurrences false-positive when item came from library:** if the same physical file is also represented elsewhere, occurrences counts size matches — pre-existing behavior, unchanged.
- **The "Open File" button (`file_info_screen.dart:193-207`) pops `'open'`.** Since we're *already* viewing this PDF, popping back returns to the viewer; the sketch ignores `'open'`. Don't recursively push another viewer.
- **`statSync` on the UI thread** (per memory note: sync stat in builders is a systemic issue). `_handleFileInfo` runs `statSync` once on tap — acceptable, not in a list builder, but it can briefly block; could be wrapped in `File.stat()` (async) if desired.
- **`mounted` guard after await** — memory flags missing guards everywhere; the sketch adds `if (!mounted) return;` before `Navigator.push` after the `initialize()` await.
- **content:// paths:** `widget.filePath` is always a real filesystem path here (the viewer uses `PdfViewer.file` and `File(widget.filePath).existsSync()` at `:209`), so `File(...).statSync()` is valid; no content-URI handling needed.
- **Protection check:** `FileInfoScreen._checkProtection` re-runs `PdfToolsService().isProtected` in an isolate (`:38`) — independent of the viewer's `_currentPassword`; harmless but redundant work. No XOR-key concern (no encryption-key access on this path).
- **No concurrency/isolate-boundary risk** in the viewer change itself; the only isolate work is inside FileInfoScreen, already in production use.

## 6. Effort

**Size: S.** Single file edited (`pdf_viewer_screen.dart`): 2 imports, 1 dispatch line, 1 divider + 1 menu item, 1 new ~25-line method. Reuses existing `FileInfoScreen`, `DocumentItem` ctor, and `DocumentService.findFileIdByPath`/`getAllItems`.

Touched subsystems: documents UI (viewer overflow menu), DocumentService (read-only lookup), DocumentItem model (construction only). No models/services modified.

Relevant files:
- `C:/Users/OYADLAPATI/source/repos/AI-LE/passwordpdf/lib/features/documents/screens/pdf_viewer_screen.dart` (menu `:287-313`, dispatch `:288-295`)
- `C:/Users/OYADLAPATI/source/repos/AI-LE/passwordpdf/lib/features/documents/screens/file_info_screen.dart` (ctor `:11-16`, occurrences `:48-67`, open-button `:193-207`)
- `C:/Users/OYADLAPATI/source/repos/AI-LE/passwordpdf/lib/models/document_item_model.dart` (ctor `:19-37`)
- `C:/Users/OYADLAPATI/source/repos/AI-LE/passwordpdf/lib/services/document_service.dart` (`findFileIdByPath` `:552-559`, `getAllItems` `:509`)

---

## Feature 5 — Backup & Restore for the Password Manager (no-secret duplicate table)

## 1. What exists today

**Password store (SQLite).** Single table `passwords` with a `UNIQUE` constraint on `key_name`:
- `storage_service.dart:40-46` — `CREATE TABLE passwords (id …, key_name TEXT NOT NULL UNIQUE, encrypted_value TEXT NOT NULL, created_at TEXT NOT NULL)`. Table name literal `'passwords'` (`app_constants.dart:12`).
- `storage_service.dart:356-363` — `insertPassword()` uses `ConflictAlgorithm.replace`, so inserting a row whose `key_name` already exists **silently overwrites** the existing row (UPSERT-by-key). Important for restore design.
- `storage_service.dart:366-373` — `getAllPasswords()` returns all rows ordered by `created_at DESC`.
- `storage_service.dart:376-385` — `getPasswordByKeyName()`; `storage_service.dart:408-412` — `passwordKeyExists()`; `storage_service.dart:414-423` — `renamePassword(id, newKeyName)` (does a bare `UPDATE key_name` with **no uniqueness pre-check** — caller must guard).

**Model.** `password_model.dart:2-49` — `PasswordModel{ id, keyName, encryptedValue, createdAt }`, with `toMap()` (16-23) and `fromMap()` (26-33). Already round-trips cleanly to a JSON-friendly map; only `createdAt` needs ISO string handling (it already uses `toIso8601String()` / `DateTime.parse`).

**Encryption.** `encryption_service.dart:89-141` — repeating-key **XOR + base64**, not AES (comment at line 100 admits it). Single key under secure-storage literal `'encryption_key'` (28, 41). Key is **non-rotatable**: `setEncryptionKey()` returns `false` if a key already exists (35-39). `encrypt()`/`decrypt()` lazily load the key and return `null` on any failure (95-98, 123-126) — they never throw.

**Existing duplicate detection (the patterns to REUSE).**
- *Key-name collision (real-time):* `add_password_dialog.dart:34-45` `_validateKeyName()` → `passwordKeyExists()`.
- *Value-duplicate scan (decrypts the whole pool):* `add_password_dialog.dart:64-95` — loops `getAllPasswords()`, calls `_encryptionService.decrypt(pwd.encryptedValue)` for each, compares plaintext, and on a hit shows a dialog naming the existing `keyName` **without showing the value** (82). This is exactly the "same decrypted value under a different name" detector restore needs.

**Screen.** `password_manager_screen.dart` — `AppBar` has only a title (157-159); actions list is empty. Add via `FloatingActionButton.extended` (297-301). `_loadPasswords()` (29-41) reloads after mutations; `_showError`/`_showSuccess` snackbar helpers (87-97). The screen already holds both `_storageService` and `_encryptionService` (16-17).

**Plumbing already in the app (no new deps needed).** `pubspec.yaml`: `share_plus ^10` (31), `path_provider ^2.1.4` (32), `file_picker ^10.3.8` (38). Confirmed usage conventions:
- Picking: `FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: [...], allowMultiple: …)` (`document_dashboard_screen.dart:653-657`); `result.files.first.path`.
- Sharing a file: `Share.shareXFiles([XFile(path)], text: …)` (`document_dashboard_screen.dart:1601`, `export_progress_screen.dart:134`, `pdf_viewer_screen.dart:595`).
- Temp dir: `getTemporaryDirectory()` (`cleanup_service.dart:23`, `main.dart:463`).

## 2. Gap

There is **no export/import path for the `passwords` table at all** — `StorageService` exposes only single-row CRUD (`storage_service.dart:353-423`); no bulk serialize/deserialize, no file I/O. The screen's AppBar `actions` is empty (`password_manager_screen.dart:157-159`), so there's no entry point. No conflict-table UI exists; the only dup UX is the single-record AlertDialog at `add_password_dialog.dart:71-92`.

Two structural blockers specific to this app:
1. **Non-rotatable XOR key.** A raw `encryptedValue` export is only readable on a device whose secure-storage `'encryption_key'` matches. Since the key can never be reset (`encryption_service.dart:35-39`), a raw export is **not portable** to a fresh install/new device — defeating the point of backup.
2. **`ConflictAlgorithm.replace`** in `insertPassword` (`storage_service.dart:361`) means a naive restore would **silently clobber** local entries on key-name collision — the user would never see the duplicate. Restore must detect collisions *before* inserting.

## 3. Implementation plan

### Backup format decision (recommend: passphrase-wrapped, portable)
Export should re-wrap each secret under a **user-supplied backup passphrase**, not ship the raw XOR `encryptedValue`. Rationale: the device key is non-rotatable and lives only in secure storage (`encryption_service.dart:28,41`), so raw export is unreadable after reinstall. Flow: `decrypt()` each row with the device key → XOR-encrypt the plaintext under the passphrase (reuse the exact XOR loop, but with `passphrase` bytes instead of `_encryptionKey`) → store that as `wrappedValue` plus a `verifier` token so a wrong passphrase is detected at restore. The JSON itself never contains plaintext. (Honest caveat: XOR-with-a-passphrase is weak crypto — same limitation as the existing scheme — but it makes the backup *portable* and *no worse* than the live store, which is the realistic minimal step here.)

### New file — `lib/services/password_backup_service.dart`
A singleton mirroring `EncryptionService`/`StorageService` style. Methods:
- `Future<String> exportToJson({required String passphrase})` — `getAllPasswords()` (reuse `storage_service.dart:366`), `decrypt` each (reuse `encryption_service.dart:117`), re-wrap under passphrase, build `{ version, createdAt, verifier, entries:[{keyName, createdAt, wrappedValue}] }`, write to `getTemporaryDirectory()`/`pdf_passwords_backup_<ts>.json`, return path. Caller hands path to `Share.shareXFiles`.
- `Future<BackupParseResult> parseBackup(String path, String passphrase)` — read file, `jsonDecode`, validate `version`/shape, check `verifier` to fail fast on wrong passphrase; return parsed entries (each with un-wrapped plaintext held only in memory) or a typed error (`malformed` / `wrongPassphrase` / `empty`).
- `Future<List<RestoreConflict>> detectConflicts(List<BackupEntry> entries)` — load `getAllPasswords()` once, decrypt the local pool once into a `Map<plaintext, localKeyName>` (reuse the decrypt-the-pool pattern from `add_password_dialog.dart:64-68`). For each backup entry classify:
  - `keyNameCollision` — `passwordKeyExists(entry.keyName)` (reuse `storage_service.dart:408`),
  - `valueDuplicateDifferentName` — its plaintext matches a local plaintext under a *different* key name,
  - `clean` — neither.
  Return rows of `{ backupName, localName, status }` — **plaintext never stored in the row**.
- `Future<void> applyRestore(List<RestoreDecision> decisions, String passphrase)` — for each: `skip` → nothing; `keepBoth`/`rename` → encrypt the plaintext with the **device** key (`encrypt()`, `encryption_service.dart:89`) under a new unique key name, `insertPassword`; `overwrite` → insert under the same key name (the existing `ConflictAlgorithm.replace` at `storage_service.dart:361` does the UPSERT).

### New conflict-table widget — `lib/features/password_manager/widgets/restore_conflict_dialog.dart`
A `DataTable` with columns **Backup Key | Local Key | Status** and a per-row resolution dropdown (`Skip` / `Rename` / `Keep both`). Status text "Password already exists under this name" for key-name collisions; "Same password, different name" for value duplicates. No password column anywhere. Returns `List<RestoreDecision>`.

### Screen wiring — `password_manager_screen.dart`
Add to the `AppBar` (currently bare at line 157-159) a `PopupMenuButton` with **Backup** and **Restore**:
- Backup → prompt for passphrase (small AlertDialog with a `TextField`, like the rename dialog at `password_manager_screen.dart:99-126`) → `exportToJson` → `Share.shareXFiles([XFile(path)], text: …)`.
- Restore → `FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'])` (pattern from `document_dashboard_screen.dart:653`) → prompt passphrase → `parseBackup` → if conflicts, show `RestoreConflictDialog` → `applyRestore` → `_loadPasswords()` (line 29) + `_showSuccess` (93).

No model changes required — `PasswordModel.toMap`/`fromMap` already serialize cleanly. No `StorageService` schema change. Add `restoredAt`/keep `createdAt` from backup as-is.

## 4. Code sketch

```dart
// lib/services/password_backup_service.dart  (NEW)
class PasswordBackupService {
  static final _i = PasswordBackupService._();
  factory PasswordBackupService() => _i;
  PasswordBackupService._();
  final _storage = StorageService();
  final _enc = EncryptionService();
  static const _version = 1;

  // Reuse the XOR loop from EncryptionService, but keyed by the passphrase (portable).
  String _xorB64(String plain, String pass) {
    final k = utf8.encode(pass), p = utf8.encode(plain), out = <int>[];
    for (var i = 0; i < p.length; i++) out.add(p[i] ^ k[i % k.length]);
    return base64Encode(out);
  }
  String _unXor(String b64, String pass) {
    final k = utf8.encode(pass), c = base64Decode(b64), out = <int>[];
    for (var i = 0; i < c.length; i++) out.add(c[i] ^ k[i % k.length]);
    return utf8.decode(out);
  }

  Future<String> exportToJson({required String passphrase}) async {
    final rows = await _storage.getAllPasswords();          // storage_service.dart:366
    final entries = <Map<String, dynamic>>[];
    for (final r in rows) {
      final plain = await _enc.decrypt(r.encryptedValue);    // device key
      if (plain == null) continue;                           // skip unreadable rows
      entries.add({'keyName': r.keyName,
                   'createdAt': r.createdAt.toIso8601String(),
                   'wrapped': _xorB64(plain, passphrase)});
    }
    final doc = {'version': _version, 'createdAt': DateTime.now().toIso8601String(),
                 'verifier': _xorB64('PWMGR_OK', passphrase), 'entries': entries};
    final f = File('${(await getTemporaryDirectory()).path}/pwd_backup_${DateTime.now().millisecondsSinceEpoch}.json');
    await f.writeAsString(jsonEncode(doc));
    return f.path;
  }

  // Conflict row carries NO plaintext.
  Future<List<RestoreConflict>> detectConflicts(List<_Entry> entries) async {
    final local = await _storage.getAllPasswords();
    final byPlain = <String, String>{};                      // reuse decrypt-the-pool: add_password_dialog.dart:64-68
    for (final l in local) {
      final p = await _enc.decrypt(l.encryptedValue);
      if (p != null) byPlain[p] = l.keyName;
    }
    final out = <RestoreConflict>[];
    for (final e in entries) {
      if (await _storage.passwordKeyExists(e.keyName)) {     // storage_service.dart:408
        out.add(RestoreConflict(e.keyName, e.keyName, ConflictKind.keyName));
      } else if (byPlain.containsKey(e.plain) && byPlain[e.plain] != e.keyName) {
        out.add(RestoreConflict(e.keyName, byPlain[e.plain]!, ConflictKind.value));
      }
    }
    return out;                                              // UI shows backupName | localName | status only
  }
}
```

## 5. Edge cases & risks

- **Wrong passphrase on restore.** XOR-decrypting with the wrong key yields garbage, and `utf8.decode` may **throw** (unlike `EncryptionService.decrypt`, which swallows it). Guard with the `verifier` token compare *before* un-wrapping entries, and wrap `utf8.decode` in try/catch — surface "wrong passphrase," not a crash.
- **Non-rotatable XOR key.** On restore to a *fresh install* the device `'encryption_key'` may be **unset** — `encrypt()` returns `null` (`encryption_service.dart:95-98`). `applyRestore` must trigger `showEncryptionKeySetupDialog` (as `add_password_dialog.dart:55-62` does) before inserting, else rows silently fail to save.
- **`ConflictAlgorithm.replace` clobber.** Any restore path that inserts under an existing `key_name` overwrites the local row (`storage_service.dart:361`). Only do this for an explicit `overwrite` decision; default to skip/rename.
- **Rename / keep-both uniqueness.** `renamePassword` and the keep-both path must ensure the new name is unique (`passwordKeyExists`) — `renamePassword` itself does **no** uniqueness check (`storage_service.dart:414-423`); auto-suffix (e.g. ` (restored)`) and re-check in a loop.
- **Empty store / empty backup.** Backup of 0 rows → produce a valid file with `entries: []` (or warn). Restore of `entries: []` → "nothing to import."
- **Malformed / non-JSON file.** `jsonDecode` throws and `file_picker` can hand back a file with wrong content despite the `.json` filter; validate `version` and shape, catch `FormatException`.
- **`content://` URIs.** On Android `file_picker` may return a cached copy or a path needing `result.files.first.path` (can be null for SAF). Null-check the path like `document_dashboard_screen.dart:661` does (`where((f) => f.path != null)`).
- **`mounted` after await.** Per the memory note, this codebase systematically omits `mounted` guards after awaits — the multi-step Restore flow (pick → passphrase → parse → table → apply → reload) crosses many awaits; guard every `setState`/`ScaffoldMessenger`/`Navigator` with `if (!mounted) return;`.
- **Plaintext leakage.** Un-wrapped plaintext exists only in memory inside `detectConflicts`/`applyRestore`; never put it in `RestoreConflict`, logs (`LoggingService`), or the temp JSON. Consider deleting the temp backup file after share completes (it sits in `getTemporaryDirectory()`).
- **Decrypt failures during backup.** If a local row was written under a different (impossible here, but defensive) or corrupt state, `decrypt` returns `null`; the sketch skips it — surface a "N rows skipped" notice rather than silently dropping secrets.

## 6. Effort

**Size: M** (one new service ~150 LOC, one new dialog widget ~150 LOC, ~30 LOC of AppBar wiring; no schema/model/migration changes, no new dependencies).

**Touched subsystems:**
- NEW `lib/services/password_backup_service.dart`
- NEW `lib/features/password_manager/widgets/restore_conflict_dialog.dart`
- EDIT `lib/features/password_manager/screens/password_manager_screen.dart` (AppBar actions 157-159; reuse `_loadPasswords` 29, `_showSuccess/_showError` 87-97)
- REUSE (no edit): `StorageService.getAllPasswords/passwordKeyExists/insertPassword/renamePassword` (`storage_service.dart:356-423`), `EncryptionService.encrypt/decrypt/isKeySet` (`encryption_service.dart:89-141, 27`), the decrypt-the-pool dup pattern (`add_password_dialog.dart:64-95`), `encryption_key_setup_dialog.dart`, and the existing `file_picker`/`share_plus`/`path_provider` conventions.