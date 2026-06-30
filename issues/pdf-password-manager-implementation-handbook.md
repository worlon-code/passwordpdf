# PDF Password Manager — Implementation Handbook

> Executable, line-anchored fix instructions derived from `pdf-password-manager-fix-order.md`, `pdf-password-manager-observed-bugs-and-requests.md`, and `CODEBASE_DEEP_DIVE.md`.
> Each task is a self-contained card: **Locate** (verbatim current code) → **Change** (verbatim new code) → **Why** → **How to test** → **Done when** → **Cautions**.

## How to use this with a low-capability model (Gemini etc.)

1. **One task per prompt.** Never paste multiple task cards at once. Apply, test, commit, then move to the next.
2. **Match on the code, not the line number.** Line numbers are *hints as of authoring* and **shift after every edit**. Tell the model to find the exact "current code" block by string match and replace it; if it can't find an exact match, STOP and re-read the file — do not guess.
3. **Follow the order.** The cards are ordered by phase for a reason (dependencies + data-safety). Do Phase 0 → 1 → 2 → 3 → 4 → 5. Within a phase, top to bottom.
4. **Respect the `Low-model-safe` flag on each card:**
   - `Yes` — fine to hand to a weak model with a human glancing at the diff.
   - `With-care` — behavioral change; a human should test the result manually.
   - `No (senior review)` — **do NOT let a weak model run it unattended.** These are the Phase 2 crypto-migration cards: a data migration on a live password store. Apply one sub-step at a time with a human verifying and a backup taken first.
5. **Test after every card** before proceeding: `fvm flutter analyze` must be clean, run the card's unit test if given, and do the manual steps. If anything fails, revert that card.
6. **Never skip the crypto safeguards.** For Phase 2: verify on the legacy (XOR) side before overwriting, gate on key-health, use a CSPRNG, keep `decrypt()` returning null on failure, and ship the passphrase backup before the sweep. These are repeated as ⚠️ Cautions on each card — they are not optional.

## Project conventions

- **Toolchain:** Flutter 3.38.6 / Dart 3.10.7 via **FVM**. Commands: `fvm flutter analyze`, `fvm flutter test`, `fvm flutter pub get`, `fvm flutter build apk` (plain `flutter ...` also works if FVM isn't wired).
- **Logging:** use the existing `LoggingService` (`_log.info/_log.error(tag, msg, [err])`) — match the surrounding call style, don't add `print`.
- **State:** services are singletons; match existing error handling (most async returns null/false on failure rather than throwing — preserve that).
- **Tests:** put new tests under `test/`; use `flutter_test`. For pure-logic fixes prefer a unit test; for UI prefer a widget test or explicit manual steps.
- **Safety:** this app is **in production with real users who have many saved passwords.** No card may delete or overwrite stored user data without the verification described in that card.

## Phase index

- **Phase 0 — Stop the bleeding** (Tasks 1–10): RCE, data-loss, crashes, the Open-With bug.
- **Phase 1 — Quick wins** (Tasks 11–14): Features 3 & 4, small correctness, start hygiene.
- **Phase 2 — Crypto migration** (Tasks 15–19 + Feature 5): senior-review only.
- **Phase 3 — Remaining security** (Tasks 20–25).
- **Phase 4 — PDF tools + Feature 2** (Tasks 26–27).
- **Phase 5 — Architecture & smells** (Task 28+; refactors 30–31 are project briefs, not recipes).

---

# PHASE 0 — Stop the bleeding

### Task 2 — Make library load resilient (per-record try/catch before clearing the list)
- **Roadmap:** Phase 1, step 2 (from fix-order.md)
- **Type:** Data-loss · **Effort:** S · **Risk if done wrong:** med · **Low-model-safe:** Yes
- **File(s):** `lib/services/document_service.dart` (~lines 895–910 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Decode the JSON and parse each record defensively so a single corrupt record can no longer wipe or block loading the entire library.

**Step 1 — Locate.** In `lib/services/document_service.dart`, find this EXACT block (copy-paste anchor):
```dart
  /// Load documents from storage
  Future<void> _loadDocuments() async {
    try {
      final String? jsonString = _prefs?.getString(_documentsKey);
      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        _items.clear();
        _items.addAll(
          jsonList.map((json) => DocumentItem.fromJson(json)).toList(),
        );
        _log.info('DocumentService', 'Loaded ${_items.length} items');
      }
    } catch (e) {
      _log.error('DocumentService', 'Failed to load documents', e);
    }
  }
```

**Step 2 — Change.** Replace it with:
```dart
  /// Load documents from storage
  Future<void> _loadDocuments() async {
    try {
      final String? jsonString = _prefs?.getString(_documentsKey);
      if (jsonString != null) {
        // Decode FIRST. If decoding fails we throw before touching _items,
        // so a corrupt blob cannot blank the in-memory library.
        final List<dynamic> jsonList = json.decode(jsonString);

        // Parse each record defensively into a temp list BEFORE clearing.
        final parsed = <DocumentItem>[];
        int skipped = 0;
        for (final json in jsonList) {
          try {
            parsed.add(DocumentItem.fromJson(json));
          } catch (recordError) {
            skipped++;
            _log.error('DocumentService', 'Skipping corrupt document record: $recordError', recordError);
          }
        }

        _items.clear();
        _items.addAll(parsed);
        _log.info('DocumentService', 'Loaded ${_items.length} items (skipped $skipped corrupt)');
      }
    } catch (e) {
      _log.error('DocumentService', 'Failed to load documents', e);
    }
  }
```

**Why:** The original cleared `_items` and then mapped every record in one expression; a single record that fails `DocumentItem.fromJson` threw mid-`addAll`, leaving the library empty and unsaved-but-blanked in memory. Parsing into a temp list and only clearing after success means one bad record is skipped, not catastrophic.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for the touched file.
- *Manual:*
  1. Run the app with several documents/folders already imported. Force-close and reopen → expect all items still listed and a log line `Loaded N items (skipped 0 corrupt)`.
  2. (Optional, if you can edit SharedPreferences in a debug build) corrupt one record inside the `documents_items` JSON array (e.g. remove a required field). Reopen → expect the other items still load and a log line `Skipping corrupt document record: ...` plus `Loaded N items (skipped 1 corrupt)`.

**Done when:** A corrupt single record no longer empties the library; the remaining valid items load and the skipped count appears in the logs.

**⚠️ Cautions:** Do NOT reorder so that `_items.clear()` runs before parsing completes — clearing must stay after the loop. Keep the `json` loop-variable name to match the file's existing closure style.

---

### Task 5 — Guard device deletion so it never deletes the user's original source file
- **Roadmap:** Phase 2, step 5 (from fix-order.md)
- **Type:** Data-loss · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** With-care
- **File(s):** `lib/services/document_service.dart` (~lines 823–891 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Prevent "delete from device" from physically deleting files that are imported references to the user's own original files (`isImportedFile == true`), which live outside app storage.

> NOTE (differs from roadmap line hints): the actual physical deletion is centralized in the private helper `_deleteFileFromDevice(String? path)` (~:875), which is called from `deleteItem` (~:838, :854) and from the public wrapper `deleteFileFromDevice` (~:889). Because the helper only receives a `path` (not the item), the safe place to add the guard is at each call site in `deleteItem`, where the `DocumentItem` and its `isImportedFile` flag are in scope. We add the guard there.

**Step 1 — Locate.** In `lib/services/document_service.dart`, find this EXACT block (inside `deleteItem`, the folder-contents loop):
```dart
      final filesInFolder = getFilesInFolder(itemId);
      for (final file in filesInFolder) {
        if (deleteFromDevice) {
           await _deleteFileFromDevice(file.sourcePath);
        }
        _items.removeWhere((i) => i.id == file.id);
      }
```

**Step 2 — Change.** Replace it with:
```dart
      final filesInFolder = getFilesInFolder(itemId);
      for (final file in filesInFolder) {
        // SAFETY: Never physically delete the user's original source file.
        // Imported references (isImportedFile) point at the user's own files
        // outside app storage; only remove our reference, not the file on disk.
        if (deleteFromDevice && !file.isImportedFile) {
           await _deleteFileFromDevice(file.sourcePath);
        } else if (deleteFromDevice && file.isImportedFile) {
           _log.info('DocumentService', 'Skipping device delete for imported reference: ${file.name}');
        }
        _items.removeWhere((i) => i.id == file.id);
      }
```

**Step 3 — Locate.** Find this EXACT block (the single-item deletion near the end of `deleteItem`):
```dart
    // Remove the item itself
    if (deleteFromDevice && item.isFile) {
       await _deleteFileFromDevice(item.sourcePath);
    }
```

**Step 4 — Change.** Replace it with:
```dart
    // Remove the item itself
    // SAFETY: Never physically delete the user's original source file.
    if (deleteFromDevice && item.isFile && !item.isImportedFile) {
       await _deleteFileFromDevice(item.sourcePath);
    } else if (deleteFromDevice && item.isFile && item.isImportedFile) {
       _log.info('DocumentService', 'Skipping device delete for imported reference: ${item.name}');
    }
```

**Why:** `addReference` stores the user's ORIGINAL device path with `isImportedFile: true` (Zero-Copy) — these are not app-owned copies. Without this guard, "delete from device" would erase the user's source PDF, an irreversible data-loss bug.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for the touched file.
- *Manual:*
  1. Import a PDF via "Add Files" so it becomes a reference (`isImportedFile == true`). Note the original file's location on disk.
  2. Select the imported file → Delete → choose "Delete from device". Expect: the item disappears from the app, the ORIGINAL file still exists on disk, and a log line `Skipping device delete for imported reference: <name>`.
  3. For a genuinely app-owned/non-imported file (`isImportedFile == false`), "Delete from device" still removes the file on disk as before.

**Done when:** Deleting an imported reference with "delete from device" removes only the app reference and leaves the original file on disk; non-imported files still get physically deleted.

**⚠️ Cautions:** Do NOT add the guard inside `_deleteFileFromDevice` or the public `deleteFileFromDevice` wrapper — they receive only a `String path` and cannot know whether the path is an imported reference, and other callers may legitimately delete by path. The flag check must stay at the `deleteItem` call sites where the `DocumentItem` is available. Do not batch this edit with Task 7 (both touch this file) — apply and verify one at a time.

---

### Task 7 — Block moving a folder into its own descendant (cycle check)
- **Roadmap:** Phase 3, step 7 (from fix-order.md)
- **Type:** Crash · **Effort:** M · **Risk if done wrong:** med · **Low-model-safe:** With-care
- **File(s):** `lib/services/document_service.dart` (~lines 708–746 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Reject `moveFolderToFolder` when the destination is the folder itself or any of its descendants, preventing an orphaned cycle and infinite recursion in `syncFolder`.

**Step 1 — Locate.** In `lib/services/document_service.dart`, find this EXACT block at the start of `moveFolderToFolder`:
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
    
    // Check for name conflict at destination
```

**Step 2 — Change.** Replace it with:
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

    // CYCLE CHECK: A folder cannot be moved into itself or any of its
    // descendants (that would orphan the subtree and cause infinite recursion
    // in syncFolder). Walk DOWN from folderId and ensure newParentId is not
    // the folder itself or below it.
    if (newParentId == folderId) {
      throw Exception('Cannot move a folder into itself.');
    }
    final descendantIds = <String>{};
    final queue = <String>[folderId];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final child in _items) {
        if (child.isFolder && child.parentId == current && descendantIds.add(child.id)) {
          queue.add(child.id);
        }
      }
    }
    if (descendantIds.contains(newParentId)) {
      throw Exception('Cannot move a folder into one of its own subfolders.');
    }
    
    // Check for name conflict at destination
```

**Why:** Without a cycle check, moving a parent folder under one of its own children sets up a parent/child loop; `syncFolder` recurses through `parentId` chains and would recurse infinitely (stack overflow / hang), and the subtree becomes unreachable from root.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for the touched file.
- *Unit test* (if feasible) in `test/document_service_cycle_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
// import the service + model; initialize with SharedPreferences mock as the project does elsewhere.

void main() {
  test('moveFolderToFolder rejects moving a folder into its own descendant', () async {
    final svc = DocumentService();
    final parent = await svc.createFolder('Parent');
    final child = await svc.createFolder('Child', parentId: parent.id);

    expect(
      () => svc.moveFolderToFolder(parent.id, child.id),
      throwsA(isA<Exception>()),
    );
    // Moving into itself is also rejected:
    expect(
      () => svc.moveFolderToFolder(parent.id, parent.id),
      throwsA(isA<Exception>()),
    );
  });
}
```
- *Manual:*
  1. Create folder "A", and inside it a subfolder "B". Try to move "A" into "B".
  2. Expect: the move is rejected with the message "Cannot move a folder into one of its own subfolders." and the folder tree is unchanged.

**Done when:** Attempting to move a folder into itself or any nested subfolder throws and no `parentId` is changed; legitimate moves to unrelated folders still succeed.

**⚠️ Cautions:** The cycle is detected via the `parentId` hierarchy (folder containment), not `fileIds`. Place the check BEFORE the name-conflict block and BEFORE the `copyWith(parentId: ...)` write. Do not batch with Task 5.

---

### Task 8 — Add orElse to getPhysicalPathForFolder firstWhere
- **Roadmap:** Phase 3, step 8 (from fix-order.md)
- **Type:** Crash · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/services/document_service.dart` (~line 450 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Stop `getPhysicalPathForFolder` from throwing an unhandled `StateError` when the folder id is not found; fall back to the base export directory.

**Step 1 — Locate.** In `lib/services/document_service.dart`, find this EXACT block inside `getPhysicalPathForFolder`:
```dart
    if (folderId == null) {
      return baseDir;
    }

    final folder = _items.firstWhere((i) => i.id == folderId);
    
    // If it's a synced/imported folder, it has a physical source path
    if (folder.sourcePath != null) {
      return folder.sourcePath!;
    }
```

**Step 2 — Change.** Replace it with:
```dart
    if (folderId == null) {
      return baseDir;
    }

    final folderIndex = _items.indexWhere((i) => i.id == folderId);
    if (folderIndex == -1) {
      // Folder id not found (e.g. deleted mid-operation). Fall back to base dir
      // instead of throwing an unhandled StateError from firstWhere.
      _log.error('DocumentService', 'getPhysicalPathForFolder: folder not found for id $folderId, using base dir');
      return baseDir;
    }
    final folder = _items[folderIndex];
    
    // If it's a synced/imported folder, it has a physical source path
    if (folder.sourcePath != null) {
      return folder.sourcePath!;
    }
```

**Why:** `firstWhere` with no `orElse` throws `Bad state: No element` when the id is missing (e.g. the folder was deleted concurrently), crashing the export/save path. Using `indexWhere` + guard returns a safe fallback and logs the condition.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for the touched file.
- *Unit test* (if feasible) in `test/document_service_path_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
// import the service; initialize SettingsService().exportPath as the project does.

void main() {
  test('getPhysicalPathForFolder returns base dir for unknown id', () async {
    final svc = DocumentService();
    final result = await svc.getPhysicalPathForFolder('does-not-exist');
    expect(result, isNotNull); // returns base export dir, does not throw
  });
}
```
- *Manual:*
  1. Trigger an export/save targeting a folder that has just been removed (or pass an unknown folder id in a debug build).
  2. Expect: no crash; the operation uses the base export directory and a log line `getPhysicalPathForFolder: folder not found for id ...` appears.

**Done when:** Calling `getPhysicalPathForFolder` with a non-existent id returns the base export dir and logs the miss instead of throwing.

**⚠️ Cautions:** Keep the existing `sourcePath`/manual-folder logic below unchanged — only the lookup is being made null-safe.

---

### Task 6 — Add IF NOT EXISTS to migration CREATE TABLE statements
- **Roadmap:** Phase 2, step 6 (from fix-order.md)
- **Type:** Crash · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/services/storage_service.dart` (~lines 153–224 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Make the `_onUpgrade` `CREATE TABLE` / `CREATE INDEX` statements idempotent so a partially-applied or re-run migration cannot crash with "table already exists".

> NOTE (differs from roadmap line hints): in `_onUpgrade` the v2 (export_jobs), v5 (logs), and v6 (files index + its two indexes) CREATE statements still lack `IF NOT EXISTS`; the later migrations (v9+) already use it. We fix the three bare ones below.

**Step 1 — Locate.** In `lib/services/storage_service.dart`, find this EXACT block (v2 migration):
```dart
    if (oldVersion < 2) {
      // Add export_jobs table
      await db.execute('''
        CREATE TABLE ${AppConstants.exportJobsTable} (
```

**Step 2 — Change.** Replace it with:
```dart
    if (oldVersion < 2) {
      // Add export_jobs table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.exportJobsTable} (
```

**Step 3 — Locate.** Find this EXACT block (v5 migration):
```dart
    if (oldVersion < 5) {
      // Add logs table
      await db.execute('''
        CREATE TABLE ${AppConstants.logsTable} (
```

**Step 4 — Change.** Replace it with:
```dart
    if (oldVersion < 5) {
      // Add logs table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.logsTable} (
```

**Step 5 — Locate.** Find this EXACT block (v6 migration — table + its two indexes):
```dart
    if (oldVersion < 6) {
      // Add Files Index table
      await db.execute('''
        CREATE TABLE ${AppConstants.filesIndexTable} (
          path TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          extension TEXT NOT NULL,
          parent_path TEXT NOT NULL,
          size INTEGER NOT NULL,
          created_at INTEGER,
          modified_at INTEGER,
          last_scanned INTEGER
        )
      ''');
      
      await db.execute('CREATE INDEX idx_files_parent ON ${AppConstants.filesIndexTable} (parent_path)');
      await db.execute('CREATE INDEX idx_files_ext ON ${AppConstants.filesIndexTable} (extension)');
    }
```

**Step 6 — Change.** Replace it with:
```dart
    if (oldVersion < 6) {
      // Add Files Index table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${AppConstants.filesIndexTable} (
          path TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          extension TEXT NOT NULL,
          parent_path TEXT NOT NULL,
          size INTEGER NOT NULL,
          created_at INTEGER,
          modified_at INTEGER,
          last_scanned INTEGER
        )
      ''');
      
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_parent ON ${AppConstants.filesIndexTable} (parent_path)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_files_ext ON ${AppConstants.filesIndexTable} (extension)');
    }
```

**Why:** These three migration steps create tables/indexes without `IF NOT EXISTS`; if a migration is re-entered (e.g. an earlier upgrade step partially completed, or a manual repair recreated an object), the bare `CREATE` throws `table/index already exists` and aborts the whole upgrade. Adding `IF NOT EXISTS` matches the pattern already used by the v9+ steps and by `_onCreate`.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for the touched file.
- *Manual:*
  1. Fresh install (no DB) → launch the app → expect tables created via `_onCreate`, no errors.
  2. Upgrade path: launch with an existing pre-v6 database and let it migrate to v14 → expect a successful upgrade with no "table/index already exists" exception in the logs, and the Files Index / export jobs / logs tables present.

**Done when:** Re-running or partially re-applying the v2/v5/v6 migration steps does not throw "already exists"; `getTables()` shows the expected tables after upgrade.

**⚠️ Cautions:** Only add `IF NOT EXISTS`; do NOT change any column definitions or index names — the `idx_files_parent` / `idx_files_ext` names must remain identical so the v6 indexes match those created in `_onCreate`. Leave the `ALTER TABLE ... ADD COLUMN` statements (which are already wrapped in try/catch) untouched.

---

### Task 3 — Stop syncAndIndex wiping curated columns (COALESCE upsert + scoped sweep)
- **Roadmap:** Phase ?, step 3 (from fix-order.md)
- **Type:** Data-loss · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** With-care
- **File(s):** `lib/services/device_document_service.dart` (~lines 160–177 upsert; ~lines 227–233 sweep — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Make the device scan stop overwriting user/curated columns (`is_new`, `missing_on_device`, `added_at`, `is_imported`, `is_imported_file`) and stop the mark-and-sweep from deleting imported rows.

**Context you must know (do NOT edit these, just for understanding):** The table `files_index` (defined in `lib/services/storage_service.dart` ~lines 94–113) has `path` as PRIMARY KEY and these curated columns set elsewhere: `is_new`, `missing_on_device`, `added_at`, `last_synced`, `is_imported`, `is_imported_file`. The current scan writes the row with `ConflictAlgorithm.replace`, which DELETEs the existing row and re-inserts it — silently zeroing every column the scan does not list (all five curated columns). The sweep then deletes any row whose `last_scanned < syncTime`; imported rows (`is_imported = 1`) are not produced by the filesystem scan, so they get swept away.

**Step 1 — Locate.** In `lib/services/device_document_service.dart`, find this EXACT block (the main file upsert inside the batch loop):
```dart
              batch.insert(
                AppConstants.filesIndexTable,
                {
                  'path': file.path,
                  'name': name,
                  'extension': ext,
                  'parent_path': parent,
                  'size': stat.size,
                  'created_at': stat.changed.millisecondsSinceEpoch,
                  'modified_at': currentMod,
                  'last_scanned': syncTime,
                  'is_folder': isFolder,
                  'has_pdf': hasPdf,
                  'has_doc': hasDoc,
                  'has_excel': hasExcel
                },
                conflictAlgorithm: ConflictAlgorithm.replace
              );
```

**Step 2 — Change.** Replace it with this block. It uses an `INSERT ... ON CONFLICT(path) DO UPDATE` raw statement so the five curated columns (`is_new`, `missing_on_device`, `added_at`, `is_imported`, `is_imported_file`) are NEVER touched on update, and only scan-owned columns are refreshed:
```dart
              // Phase ?, Step 3: Upsert that preserves curated columns.
              // Using raw ON CONFLICT DO UPDATE instead of ConflictAlgorithm.replace,
              // because replace DELETEs the row and wipes is_new/missing_on_device/
              // added_at/is_imported/is_imported_file. We only refresh scan-owned columns.
              batch.rawInsert(
                'INSERT INTO ${AppConstants.filesIndexTable} '
                '(path, name, extension, parent_path, size, created_at, modified_at, '
                'last_scanned, is_folder, has_pdf, has_doc, has_excel) '
                'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
                'ON CONFLICT(path) DO UPDATE SET '
                'name = excluded.name, '
                'extension = excluded.extension, '
                'parent_path = excluded.parent_path, '
                'size = excluded.size, '
                'created_at = COALESCE(${AppConstants.filesIndexTable}.created_at, excluded.created_at), '
                'modified_at = excluded.modified_at, '
                'last_scanned = excluded.last_scanned, '
                'is_folder = excluded.is_folder, '
                'has_pdf = excluded.has_pdf, '
                'has_doc = excluded.has_doc, '
                'has_excel = excluded.has_excel',
                [
                  file.path,
                  name,
                  ext,
                  parent,
                  stat.size,
                  stat.changed.millisecondsSinceEpoch,
                  currentMod,
                  syncTime,
                  isFolder,
                  hasPdf,
                  hasDoc,
                  hasExcel,
                ],
              );
```

**Step 3 — Locate (sweep).** In the same file, find this EXACT block (inside `_syncToDatabase`, after `await batch.commit(noResult: true);`):
```dart
         // Sweep: Delete old records
         final deleted = await txn.delete(
            AppConstants.filesIndexTable, 
            where: 'last_scanned < ?', 
            whereArgs: [syncTime]
         );
         _log.info('DeviceDocumentService', 'Sync complete. Removed $deleted stale records.');
```

**Step 4 — Change (sweep).** Replace it with this block, which scopes the delete to scan-owned rows only (`is_imported = 0`) so imported rows survive the sweep:
```dart
         // Phase ?, Step 3: Sweep only scan-owned rows. Imported rows
         // (is_imported = 1) are not produced by the filesystem scan, so
         // their last_scanned is always stale — scoping to is_imported = 0
         // prevents the sweep from deleting user-imported files.
         final deleted = await txn.delete(
            AppConstants.filesIndexTable, 
            where: 'last_scanned < ? AND is_imported = 0', 
            whereArgs: [syncTime]
         );
         _log.info('DeviceDocumentService', 'Sync complete. Removed $deleted stale records.');
```

**Step 5 — Note on the parent-folder upsert.** The recursive-folder upsert lower in the loop already uses `conflictAlgorithm: ConflictAlgorithm.ignore` (it inserts only when the folder row is absent, and never overwrites). **Do NOT change that block** — `ignore` does not wipe curated columns, so it is safe as-is.

**Why:** `ConflictAlgorithm.replace` is a DELETE+INSERT, so any rescan silently zeroed the curated columns and the unscoped sweep deleted user-imported rows. COALESCE/targeted UPDATE + `is_imported = 0` scope keeps curated data intact.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for `lib/services/device_document_service.dart`.
- *Unit test (sqflite_common_ffi):* in `test/device_sync_preserve_test.dart`, create the `files_index` table, insert a row for path `/storage/emulated/0/Download/a.pdf` with `is_imported = 1, is_new = 1, added_at = 111`, run the upsert path with a fresh `syncTime`, then assert the row's `is_imported`, `is_new`, and `added_at` are still `1, 1, 111` and that the sweep with the new `WHERE last_scanned < ? AND is_imported = 0` did NOT delete it.
- *Manual:* 1. Import a PDF (it appears with its imported state). 2. Pull-to-refresh / trigger a rescan. 3. Expect the imported PDF to still be present AND still flagged imported (not duplicated, not reverted to a plain device file).

**Done when:** After a rescan, rows with `is_imported = 1` still exist and their `is_new` / `missing_on_device` / `added_at` / `is_imported` / `is_imported_file` values are unchanged; device-only rows that disappeared from disk are still swept.

**⚠️ Cautions:** Data-safety critical — apply both edits (upsert AND sweep) together; applying only one leaves the bug half-fixed. The `ON CONFLICT(path)` clause relies on `path` being the PRIMARY KEY (it is). Do NOT touch the `ConflictAlgorithm.ignore` parent-folder insert.

---

### Task 4 — Overwrite-import temp-then-swap (don't delete before the new file is safe)
- **Roadmap:** Phase ?, step 4 (from fix-order.md)
- **Type:** Data-loss · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** With-care
- **File(s):** `lib/features/documents/screens/all_documents_screen.dart` (~lines 756–789 — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** When overwriting an existing file on import, only delete the old item AFTER the new import succeeds, so a failed import can never leave the user with neither file.

**Context you must know:** `docService.importFile(...)` returns an `ImportResult` (defined in `lib/services/document_service.dart` ~line 11) with `result.success` (bool) and `result.importItem` (nullable). The current code deletes the existing item FIRST, then imports — if the import then fails, the old file is already gone (data loss).

**Step 1 — Locate.** In `lib/features/documents/screens/all_documents_screen.dart`, find this EXACT block inside the import loop:
```dart
      try {
        // Handle Overwrite: Delete existing file first
        if (filesToOverwrite.contains(file.path)) {
           final existingId = docService.getFileIdInFolder(fileName, folderId);
           if (existingId != null) {
             _log.info('AllDocumentsScreen', 'Overwriting: Deleting existing item $existingId');
             await docService.deleteItem(existingId);
           }
        }
        
        // Import
        // Note: importFile logic handles creating NEW file. 
        // If we are overwriting, we just deleted the old one, so it's a new import.
        final result = await docService.importFile(
          file.path, 
          fileName, 
          targetName: targetName,
          allowDuplicate: forceImport
        );
        
        if (result.success && result.importItem != null) {
          successCount++;
          // If we imported into specific folder, move it there
          if (folderId != null) {
             await docService.addFileToFolder(result.importItem!.id, folderId);
          }
        } else {
          failCount++;
          _log.warn('AllDocumentsScreen', 'Failed to import ${file.path}: ${result.errorMessage}');
        }
      } catch (e) {
        failCount++;
        _log.error('AllDocumentsScreen', 'Exception importing ${file.path}', e);
      }
```

**Step 2 — Change.** Replace it with this block. It resolves the existing item id FIRST (but does not delete), imports the new file under a temporary unique name when overwriting, and only after the import succeeds deletes the old item and then we keep the new one — so a failed import leaves the original untouched:
```dart
      try {
        // Phase ?, Step 4: Overwrite = temp-then-swap.
        // Resolve the existing item id up front but DO NOT delete it yet.
        // We import the new file first; only after it succeeds do we delete
        // the old item. This guarantees a failed import can never leave the
        // user with neither the old nor the new file.
        final bool isOverwrite = filesToOverwrite.contains(file.path);
        String? existingId;
        String importName = targetName;
        if (isOverwrite) {
           existingId = docService.getFileIdInFolder(fileName, folderId);
           // Import the new copy under a temporary unique name so it does not
           // collide with the still-present original.
           importName = '__import_tmp_${DateTime.now().millisecondsSinceEpoch}_$targetName';
        }

        // Import (always allow duplicate when overwriting, since the original
        // is intentionally still present at this point).
        final result = await docService.importFile(
          file.path, 
          fileName, 
          targetName: importName,
          allowDuplicate: forceImport || isOverwrite
        );
        
        if (result.success && result.importItem != null) {
          // New file is safely imported. Now it is safe to remove the old one.
          if (isOverwrite && existingId != null) {
             _log.info('AllDocumentsScreen', 'Overwrite: import succeeded, deleting old item $existingId');
             await docService.deleteItem(existingId);
             // Rename the temp import to the intended final name.
             await docService.renameItem(result.importItem!.id, targetName);
          }
          successCount++;
          // If we imported into specific folder, move it there
          if (folderId != null) {
             await docService.addFileToFolder(result.importItem!.id, folderId);
          }
        } else {
          // Import failed: original (if overwrite) is untouched. No data loss.
          failCount++;
          _log.warn('AllDocumentsScreen', 'Failed to import ${file.path}: ${result.errorMessage}');
        }
      } catch (e) {
        failCount++;
        _log.error('AllDocumentsScreen', 'Exception importing ${file.path}', e);
      }
```

**Step 3 — Rename API confirmed (no action needed).** This card calls `docService.renameItem(result.importItem!.id, targetName)`. That method **exists** in `lib/services/document_service.dart`: `Future<void> renameItem(String itemId, String newName)` (≈ line 801), and its signature matches the call. Apply Step 2 exactly as written — there is no API ambiguity and no judgment required.

**Why:** The old code deleted the existing file before the new import ran, so any import failure destroyed the original with nothing to replace it. Importing to a temp name and deleting the old item only on success makes overwrite atomic from the user's point of view.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for `lib/features/documents/screens/all_documents_screen.dart`.
- *Manual (success):* 1. Have file `report.pdf` already imported. 2. Import another `report.pdf` and choose Overwrite. 3. Expect exactly one `report.pdf`, with the new content, no temp-named leftovers.
- *Manual (failure):* 1. Have `report.pdf` imported. 2. Force the import to fail (e.g. point at a path that becomes unreadable) and choose Overwrite. 3. Expect the original `report.pdf` to still be present and openable; failCount increments; no `__import_tmp_*` file remains.

**Done when:** A failed overwrite import always leaves the original file intact; a successful overwrite results in exactly one file with the intended final name and no temp-named residue.

**⚠️ Cautions:** Data-safety critical. Do NOT reorder so the delete happens before the success check.

---

### Task 9 — Wrap pagination / multi-delete loops in try/finally so loading flags can't stick
- **Roadmap:** Phase ?, step 9 (from fix-order.md)
- **Type:** Crash (stuck-state) · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/features/documents/screens/all_documents_screen.dart` (~lines 207–233, `_loadMoreDocuments`); `lib/features/documents/screens/document_dashboard_screen.dart` (~lines 3261–3282, multi-delete) — VERIFY before editing; line numbers shift after earlier edits.
- **Goal:** Guarantee `_isLoadingMore` and `_isLoading` are always cleared even if the awaited work throws, so the UI never gets stuck in a permanent loading state.

**Step 1 — Locate (pagination).** In `lib/features/documents/screens/all_documents_screen.dart`, find this EXACT method body:
```dart
  Future<void> _loadMoreDocuments() async {
    if (_isLoadingMore) return;
    
    setState(() {
      _isLoadingMore = true;
    });

    await Future.delayed(const Duration(milliseconds: 100));

    final moreFiles = await _deviceService.getDocuments(
      offset: _currentOffset,
      limit: _pageSize,
      filterType: _selectedFilter,
      searchQuery: _searchQuery,
      parentPath: _isFolderView ? _currentFolderPath : null,
      flatList: !_isFolderView,
    );

    if (mounted) {
      setState(() {
        _displayedFiles.addAll(moreFiles);
        _currentOffset += moreFiles.length;
        _hasMore = moreFiles.length >= _pageSize;
        _isLoadingMore = false;
      });
    }
  }
```

**Step 2 — Change.** Replace it with this version. The fetch/state-update is wrapped in `try`, errors are logged, and a `finally` clears `_isLoadingMore` no matter what:
```dart
  Future<void> _loadMoreDocuments() async {
    if (_isLoadingMore) return;
    
    setState(() {
      _isLoadingMore = true;
    });

    try {
      await Future.delayed(const Duration(milliseconds: 100));

      final moreFiles = await _deviceService.getDocuments(
        offset: _currentOffset,
        limit: _pageSize,
        filterType: _selectedFilter,
        searchQuery: _searchQuery,
        parentPath: _isFolderView ? _currentFolderPath : null,
        flatList: !_isFolderView,
      );

      if (mounted) {
        setState(() {
          _displayedFiles.addAll(moreFiles);
          _currentOffset += moreFiles.length;
          _hasMore = moreFiles.length >= _pageSize;
        });
      }
    } catch (e) {
      // Phase ?, Step 9: log but never leave the loading flag stuck.
      _log.error('AllDocumentsScreen', 'Load more failed', e);
    } finally {
      // Always clear the flag, even on error, so pagination can retry.
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      } else {
        _isLoadingMore = false;
      }
    }
  }
```

**Step 3 — Locate (multi-delete).** In `lib/features/documents/screens/document_dashboard_screen.dart`, find this EXACT block:
```dart
    // Perform Delete
    setState(() => _isLoading = true);

    int deletedCount = 0;
    final ids = List<String>.from(_selectedFileIds);
    
    for (final id in ids) {
       await _docService.deleteItem(id, deleteFromDevice: deleteFromDevice);
       deletedCount++;
    }
    
    setState(() {
      _selectedFileIds.clear();
      _isLoading = false;
    });
    
    if (mounted) {
       ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(content: Text('Deleted $deletedCount items')),
       );
    }
```

**Step 4 — Change.** Replace it with this version. The delete loop is wrapped in `try`, each item's failure is caught so one bad delete doesn't abort the rest, and `finally` always clears `_isLoading` and the selection:
```dart
    // Perform Delete
    setState(() => _isLoading = true);

    int deletedCount = 0;
    final ids = List<String>.from(_selectedFileIds);
    
    try {
      for (final id in ids) {
         try {
            await _docService.deleteItem(id, deleteFromDevice: deleteFromDevice);
            deletedCount++;
         } catch (e) {
            // Phase ?, Step 9: skip the failing item, keep deleting the rest.
            _log.error('DocumentDashboardScreen', 'Failed to delete item $id', e);
         }
      }
    } finally {
      // Always clear the loading flag and selection, even if the loop threw.
      if (mounted) {
        setState(() {
          _selectedFileIds.clear();
          _isLoading = false;
        });
      } else {
        _selectedFileIds.clear();
        _isLoading = false;
      }
    }
    
    if (mounted) {
       ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(content: Text('Deleted $deletedCount items')),
       );
    }
```

**Step 5 — VERIFY logger field names.** This card uses `_log.error(...)` in both files. Confirm each file already has a `LoggingService` instance field named `_log` (search each file for `_log`). In `all_documents_screen.dart` it is referenced as `_log` (e.g. `_log.info('AllDocumentsScreen', ...)`), so `_log` is correct there. In `document_dashboard_screen.dart`, search for `LoggingService` / `_log`; if the instance is named differently (e.g. `_logger` or `LoggingService()` is used inline), use that exact reference instead. Keep the tag string matching the screen's existing log tags.

**Why:** If `getDocuments` or `deleteItem` throws, the original code never reaches the `setState` that clears the loading flag, so the list spinner or busy overlay sticks forever. `try/finally` guarantees the flag is reset on every path.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for both touched files.
- *Manual (pagination):* 1. Scroll a long document list to trigger load-more while temporarily forcing `getDocuments` to throw. 2. Expect: the inline "loading more" spinner clears (does not spin forever) and scrolling can trigger another attempt.
- *Manual (multi-delete):* 1. Select several items, delete them, with one item rigged to throw. 2. Expect: the busy state clears, the other items are deleted, the selection is cleared, and a "Deleted N items" snackbar shows (N excludes the failed one).

**Done when:** After any error in either flow, `_isLoadingMore` / `_isLoading` are observably `false` (UI not stuck) and the selection is cleared in the delete case.

**⚠️ Cautions:** Keep the early `if (_isLoadingMore) return;` guard at the very top of `_loadMoreDocuments` (outside the try) — moving it inside the try would break the re-entrancy guard. Confirm the `_log` reference name per Step 5 before applying to the dashboard file.

---

**Verification notes (deviations from line hints):** The roadmap's hint of "~:160-180 upsert" matches `lib/services/device_document_service.dart` lines 160–177 exactly. The sweep hinted at "~:225-235" is at lines 227–233 (the `txn.delete` block after `batch.commit`). The curated columns confirmed from `lib/services/storage_service.dart` (table DDL, lines 94–113) are `is_new`, `missing_on_device`, `added_at`, `last_synced`, `is_imported`, `is_imported_file`. The Task 4 overwrite block is at `all_documents_screen.dart` ~756–789 (hint said ~755-785 — close). Task 9 pagination is at `all_documents_screen.dart` 207–233 (hint ~210-220) and dashboard multi-delete at `document_dashboard_screen.dart` 3261–3282 (hint ~3260-3275). Task 4 depends on a `renameItem`-style API that I could NOT confirm exists in `document_service.dart` (only `importFile`, `addReference`, `getFileIdInFolder`, `deleteItem`, `addFileToFolder` were located) — Step 3 of Task 4 gives a fallback path if rename is absent; the implementer MUST verify before applying.

---

### Task 10 — One-shot intent guard so "Open With" stops reopening the previous document
- **Roadmap:** Phase 3, step 10 (from fix-order.md)
- **Type:** Correctness · **Effort:** S · **Risk if done wrong:** med · **Low-model-safe:** With-care
- **File(s):** `lib/main.dart` (~lines 294, 323–337, 354–361, 703–715 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Add a one-shot `_initialIntentConsumed` guard so the resume path (`_checkForPendingIntent`) does not re-read the stale launch intent via `getInitialMedia()` after the cold-start intent was already handled.

**Step 1 — Locate.** In `lib/main.dart`, find this EXACT block (the field declarations inside `_AppEntryState`):
```dart
  bool _isAuthenticated = false;
  bool _isLoading = true;
  bool _isProcessingIntent = false;
  int _selectedIndex = 0; // Added for default screen index
```

**Step 2 — Change.** Replace it with:
```dart
  bool _isAuthenticated = false;
  bool _isLoading = true;
  bool _isProcessingIntent = false;
  // One-shot guard: once the cold-start launch intent has been consumed,
  // the resume path must NOT re-read the stale intent via getInitialMedia().
  bool _initialIntentConsumed = false;
  int _selectedIndex = 0; // Added for default screen index
```

**Step 3 — Locate.** Find this EXACT block (`_checkInitialIntents`, the cold-start handler):
```dart
  Future<void> _checkInitialIntents() async {
    try {
      final sharedFiles = await ReceiveSharingIntent.instance.getInitialMedia();
      if (sharedFiles.isNotEmpty) {
        final file = sharedFiles.first;
        if (file.path != null) {
           PendingFileOpen.filePath = file.path;
           // Fix for "Zombie Intent": Clear it so it doesn't reappear on resume
           ReceiveSharingIntent.instance.reset();
        }
      }
    } catch (e) {
      LoggingService().error('App', 'Error checking initial intents', e);
    }
  }
```

**Step 4 — Change.** Replace it with:
```dart
  Future<void> _checkInitialIntents() async {
    try {
      final sharedFiles = await ReceiveSharingIntent.instance.getInitialMedia();
      if (sharedFiles.isNotEmpty) {
        final file = sharedFiles.first;
        if (file.path != null) {
           PendingFileOpen.filePath = file.path;
           // Fix for "Zombie Intent": Clear it so it doesn't reappear on resume
           ReceiveSharingIntent.instance.reset();
        }
      }
    } catch (e) {
      LoggingService().error('App', 'Error checking initial intents', e);
    } finally {
      // Mark the launch intent as consumed exactly once. The resume path
      // (_checkForPendingIntent) checks this flag and will NOT re-read the
      // stale launch intent via getInitialMedia() again.
      _initialIntentConsumed = true;
      _log.info('AppEntry', 'Initial intent consumed - resume path will skip getInitialMedia()');
    }
  }
```

**Step 5 — Locate.** Find this EXACT block (the start of `_checkForPendingIntent`, the resume handler):
```dart
  Future<void> _checkForPendingIntent() async {
    try {
      final media = await ReceiveSharingIntent.instance.getInitialMedia();
```

**Step 6 — Change.** Replace it with:
```dart
  Future<void> _checkForPendingIntent() async {
    // One-shot guard: the cold-start launch intent was already consumed by
    // _checkInitialIntents(). On resume, getInitialMedia() still returns that
    // stale intent, which caused "Open With" to reopen the previous document.
    // Skip it; only the live getMediaStream() should deliver new resume intents.
    if (_initialIntentConsumed) {
      _log.info('AppEntry', 'Initial intent already consumed - skipping getInitialMedia() on resume');
      return;
    }
    try {
      final media = await ReceiveSharingIntent.instance.getInitialMedia();
```

**Step 7 — Locate.** Find this EXACT block (the top of `_handleSharedFiles`, right after the `_isProcessingIntent` gate sets the flag):
```dart
    _isProcessingIntent = true;
    _log.info('AppEntry', 'Received ${files.length} shared files');
```

**Step 8 — Change.** Replace it with:
```dart
    _isProcessingIntent = true;
    // Consume the native launch intent immediately so it cannot be re-read by
    // getInitialMedia() on a later resume (root cause of "Open With" reopening
    // the previous document). Mark the one-shot guard too.
    _initialIntentConsumed = true;
    ReceiveSharingIntent.instance.reset();
    _log.info('AppEntry', 'Received ${files.length} shared files');
```

**Why:** `getInitialMedia()` keeps returning the original launch intent across resumes; without a one-shot guard, resuming the app re-runs `_handleSharedFiles` on the stale intent and reopens the last document. The flag plus an immediate native `reset()` ensures the launch intent is read and cleared exactly once.

**How to test:**
- *Static:* `fvm flutter analyze` (or `flutter analyze`) must be clean for `lib/main.dart`.
- *Unit/widget test:* Not feasible — `ReceiveSharingIntent.instance` is a platform-channel singleton and `_initialIntentConsumed` is private state; this is a manual/integration scenario.
- *Manual:*
  1. From another app (e.g. Files/Gmail), use "Open With" → PDF Password Manager on document A → expect document A opens.
  2. Press Home, then reopen PDF Password Manager from Recents (resume) → expect the app resumes to its current state and does NOT reopen document A.
  3. Background the app again, then "Open With" → document B from another app → expect document B opens (the live `getMediaStream` path still works).
  4. Resume the app from Recents again → expect NO document auto-opens.

**Done when:** Resuming the app from background/Recents never re-opens a previously shared document, while a fresh "Open With" share still opens the newly shared file. Logs show `Initial intent consumed` once on cold start and `Initial intent already consumed - skipping getInitialMedia() on resume` on subsequent resumes.

**⚠️ Cautions:**
- Apply Steps 1–8 together as a single unit — the guard field, the setter in `_checkInitialIntents`, the early-return in `_checkForPendingIntent`, and the reset in `_handleSharedFiles` are interdependent; do not batch this with unrelated intent changes.
- Do NOT remove the existing `ReceiveSharingIntent.instance.reset();` call already inside `_checkForPendingIntent` (after `_handleSharedFiles(media)`); leave it as-is.
- Order matters in Step 8: set `_initialIntentConsumed = true;` and call `reset()` BEFORE the file-processing loop runs, so a mid-processing resume cannot re-read the intent.

Note on line hints vs. actual code: the roadmap's hints matched the file as read. The field block is at ~292–295 (not exactly 294), and both `_checkInitialIntents` (323–337) and `_checkForPendingIntent` (703–715) match the hinted ranges.

## Self-update track (Task 1 ships in Phase 0; Tasks 13 & 29 batched here for file locality)
### Task 1 — Harden self-update: verify APK SHA-256, pin host, block cross-origin redirects, lock force-update dialogs, harden JSON casts
- **Roadmap:** Phase 1, step 1 (from fix-order.md) — NOTE: `fix-order.md` does not exist in the repo at the time of writing; phase/step taken from the task brief.
- **Type:** Security · **Effort:** L · **Risk if done wrong:** high · **Low-model-safe:** With-care
- **File(s):** `lib/features/update/models/update_info.dart` (~lines 1–27), `lib/features/update/services/update_service.dart` (~lines 99–190), `lib/features/update/widgets/update_dialogs.dart` (~lines 49–67, 106–114), `lib/main.dart` (~lines 878–885), `lib/features/settings/screens/settings_screen.dart` (~lines 883–889), `pubspec.yaml`
- **Goal:** Make the in-app self-updater verify the downloaded APK against a server-supplied SHA-256, refuse cross-origin/redirected download URLs, lock force-update dialogs so they cannot be dismissed, and parse the manifest defensively.

**SERVER PREREQUISITE (document, do not code here):** The release manifest `version.json` (served from `https://raw.githubusercontent.com/worlon-code/passwordpdf-releases/main/version.json`) MUST gain a new string field `sha256` containing the lowercase hex SHA-256 of the published APK, e.g. `"sha256": "9f86d0818..."`. Until that field exists, leave checksum enforcement in "verify-if-present" mode (code below already does this: it only fails when a checksum IS supplied and does NOT match). Once the server always emits it, a follow-up task should make `expectedSha256 == null` a hard failure.

**SIGNING-CERT PINNING (flag — NOT codeable here):** True APK signing-certificate pinning (verifying the downloaded APK is signed by our known release certificate before `OpenFilex.open`) requires (a) the known SHA-256 of our signing cert/public key, and (b) native Android work (a platform channel calling `PackageManager.getPackageArchiveInfo(..., GET_SIGNING_CERTIFICATES)` or parsing `META-INF`), because Dart has no API to read APK signatures. This card does NOT implement cert pinning. The SHA-256-of-file check below is the Dart-only mitigation; cert pinning must be a separate native task with a senior review.

---

**Step 1 — Locate.** In `pubspec.yaml`, find this EXACT line:
```yaml
  dio: ^5.7.0
```

**Step 2 — Change.** Replace it with:
```yaml
  dio: ^5.7.0
  crypto: ^3.0.3
```
(This adds the `crypto` package, which provides `sha256`. After editing `pubspec.yaml` you MUST run `fvm flutter pub get` once.)

---

**Step 3 — Locate.** In `lib/features/update/models/update_info.dart`, find this EXACT block:
```dart
class UpdateInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;

  UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.releaseNotes,
    this.forceUpdate = false,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    // Robust parsing with fallbacks
    return UpdateInfo(
      // Support 'latestVersion' legacy key if 'version' is missing or null
      version: (json['version'] ?? json['latestVersion'] ?? '') as String,
      buildNumber: (json['buildNumber'] ?? 0) as int,
      downloadUrl: (json['downloadUrl'] ?? '') as String,
      releaseNotes: (json['releaseNotes'] ?? '') as String,
      forceUpdate: (json['forceUpdate'] ?? false) as bool,
    );
  }
}
```

**Step 4 — Change.** Replace it with:
```dart
class UpdateInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;
  final String? sha256;

  UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.releaseNotes,
    this.forceUpdate = false,
    this.sha256,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    // Robust parsing with fallbacks (defensive casts: never blindly cast dynamic)
    final rawSha = json['sha256'];
    final shaStr = (rawSha == null || rawSha.toString().trim().isEmpty)
        ? null
        : rawSha.toString().trim().toLowerCase();
    return UpdateInfo(
      // Support 'latestVersion' legacy key if 'version' is missing or null
      version: (json['version'] ?? json['latestVersion'] ?? '').toString(),
      buildNumber: int.tryParse((json['buildNumber'] ?? 0).toString()) ?? 0,
      downloadUrl: (json['downloadUrl'] ?? '').toString(),
      releaseNotes: (json['releaseNotes'] ?? '').toString(),
      forceUpdate: (json['forceUpdate']?.toString().toLowerCase() == 'true'),
      sha256: shaStr,
    );
  }
}
```

---

**Step 5 — Locate.** In `lib/features/update/services/update_service.dart`, find this EXACT block (top of file, the import list):
```dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../../../services/logging_service.dart';
import '../models/update_info.dart';
```

**Step 6 — Change.** Replace it with:
```dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../../../services/logging_service.dart';
import '../models/update_info.dart';
```

---

**Step 7 — Locate.** In `lib/features/update/services/update_service.dart`, find this EXACT block (the whole `downloadUpdate` method, lines ~118–179). Note the signature currently takes only `(String url, Function(int, int) onProgress)`:
```dart
  Future<File?> downloadUpdate(String url, Function(int, int) onProgress) async {
    try {
      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();
      
      final fileName = 'update_${DateTime.now().millisecondsSinceEpoch}.apk';
      final savePath = '${dir.path}/$fileName';

      _log.info('UpdateService', 'Starting download from: $url');
      _log.info('UpdateService', 'Saving to: $savePath');

      final dio = Dio();
      final response = await dio.download(
        url,
        savePath,
        onReceiveProgress: onProgress,
        options: Options(
          headers: {
            'User-Agent': 'Mozilla/5.0 (Android; Mobile; rv:100.0) Gecko/100.0 Firefox/100.0',
            'Accept': '*/*',
          },
          followRedirects: true,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      _log.info('UpdateService', 'Download Response Status: ${response.statusCode}');
      _log.info('UpdateService', 'Response Headers: ${response.headers.map}');

      if (response.statusCode != 200) {
        _log.error('UpdateService', 'Download failed: Server returned ${response.statusCode}', null);
        return null;
      }

      final file = File(savePath);
      if (await file.exists()) {
        final bytes = await file.length();
        _log.info('UpdateService', 'Downloaded file size: $bytes bytes');

        if (bytes < 1000) {
           _log.error('UpdateService', 'Downloaded file is unexpectedly small ($bytes bytes)', null);
           return null;
        }

        // Verify APK magic number (ZIP format: PK...)
        final raf = await file.open();
        final head = await raf.read(2);
        await raf.close();

        if (head.length < 2 || head[0] != 0x50 || head[1] != 0x4B) {
           _log.error('UpdateService', 'Downloaded file is not a valid APK/ZIP (Magic: ${head.toList()})', null);
           return null;
        }

        return file;
      }
      return null;
    } catch (e, stack) {
      _log.error('UpdateService', 'Download exception', e, stack);
      return null;
    }
  }
```

**Step 8 — Change.** Replace the ENTIRE block above with:
```dart
  /// Host that release artifacts must be served from. The download URL host
  /// must equal this (or be a subdomain of it); cross-origin URLs are rejected.
  static const String _releaseHost = 'github.com';

  bool _isAllowedHost(String host) {
    final h = host.toLowerCase();
    return h == _releaseHost || h.endsWith('.$_releaseHost');
  }

  Future<File?> downloadUpdate(
    String url,
    Function(int, int) onProgress, {
    String? expectedSha256,
  }) async {
    try {
      // SECURITY: only allow downloads from the trusted release host. Reject
      // anything pointing elsewhere before we ever make a request.
      final parsed = Uri.tryParse(url);
      if (parsed == null || !parsed.isAbsolute || !parsed.isScheme('https') || !_isAllowedHost(parsed.host)) {
        _log.error('UpdateService', 'Refusing download: untrusted or non-https URL host ($url)', null);
        return null;
      }

      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();

      final fileName = 'update_${DateTime.now().millisecondsSinceEpoch}.apk';
      final savePath = '${dir.path}/$fileName';

      _log.info('UpdateService', 'Starting download from: $url');
      _log.info('UpdateService', 'Saving to: $savePath');

      final dio = Dio();
      final response = await dio.download(
        url,
        savePath,
        onReceiveProgress: onProgress,
        options: Options(
          headers: {
            'User-Agent': 'Mozilla/5.0 (Android; Mobile; rv:100.0) Gecko/100.0 Firefox/100.0',
            'Accept': '*/*',
          },
          // SECURITY: do NOT follow redirects. A redirect could bounce the
          // download to an attacker-controlled host that bypasses the host check.
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      _log.info('UpdateService', 'Download Response Status: ${response.statusCode}');
      _log.info('UpdateService', 'Response Headers: ${response.headers.map}');

      if (response.statusCode != 200) {
        _log.error('UpdateService', 'Download failed: Server returned ${response.statusCode}', null);
        return null;
      }

      final file = File(savePath);
      if (await file.exists()) {
        final bytes = await file.length();
        _log.info('UpdateService', 'Downloaded file size: $bytes bytes');

        if (bytes < 1000) {
           _log.error('UpdateService', 'Downloaded file is unexpectedly small ($bytes bytes)', null);
           return null;
        }

        // Verify APK magic number (ZIP format: PK...)
        final raf = await file.open();
        final head = await raf.read(2);
        await raf.close();

        if (head.length < 2 || head[0] != 0x50 || head[1] != 0x4B) {
           _log.error('UpdateService', 'Downloaded file is not a valid APK/ZIP (Magic: ${head.toList()})', null);
           await file.delete().catchError((_) => file);
           return null;
        }

        // SECURITY: verify the SHA-256 supplied by the manifest, if present.
        // (When the server always emits sha256, a follow-up task should make a
        //  missing checksum a hard failure.)
        if (expectedSha256 != null && expectedSha256.isNotEmpty) {
          final fileBytes = await file.readAsBytes();
          final actual = sha256.convert(fileBytes).toString().toLowerCase();
          if (actual != expectedSha256.toLowerCase()) {
            _log.error('UpdateService',
                'APK checksum mismatch. expected=$expectedSha256 actual=$actual', null);
            await file.delete().catchError((_) => file);
            return null;
          }
          _log.info('UpdateService', 'APK checksum verified OK');
        } else {
          _log.info('UpdateService', 'No expected sha256 supplied; skipping checksum verification');
        }

        return file;
      }
      return null;
    } catch (e, stack) {
      _log.error('UpdateService', 'Download exception', e, stack);
      return null;
    }
  }
```

---

**Step 9 — Locate.** In `lib/features/update/widgets/update_dialogs.dart`, find this EXACT block (the global `performUpdate`, which is the single shared helper all callers will use after Task 29) — the `service.downloadUpdate(...)` call:
```dart
                  started = true;
                  service.downloadUpdate(info.downloadUrl, (received, total) {
```

**Step 10 — Change.** Replace it with:
```dart
                  started = true;
                  service.downloadUpdate(info.downloadUrl, (received, total) {
```
...and update the closing of that same `downloadUpdate(...)` call so the manifest checksum is passed. Concretely, in the SAME `performUpdate` function, find this EXACT block:
```dart
                  }).then((file) async {
                      if (dialogContext.mounted) Navigator.pop(dialogContext); // Close progress
```
Replace it with:
```dart
                  }, expectedSha256: info.sha256).then((file) async {
                      if (dialogContext.mounted) Navigator.pop(dialogContext); // Close progress
```

---

**Step 11 — Locate (non-dismissible force-update dialog — the dialog widget).** In `lib/features/update/widgets/update_dialogs.dart`, find this EXACT block (the `actions:` of `UpdateAvailableDialog`):
```dart
      actions: [
        if (!updateInfo.forceUpdate)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
```

This is already correct (no "Later" button when `forceUpdate` is true). Leave the `actions:` as-is. Instead, wrap the whole dialog so the back button cannot dismiss it on a forced update.

**Step 12 — Change.** In the SAME file, find this EXACT block (the `build` of `UpdateAvailableDialog`):
```dart
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update, color: Colors.blue),
          const SizedBox(width: 8),
          const Text('Update Available'),
        ],
      ),
```
Replace it with:
```dart
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !updateInfo.forceUpdate,
      child: AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update, color: Colors.blue),
          const SizedBox(width: 8),
          const Text('Update Available'),
        ],
      ),
```

**Step 13 — Change (close the PopScope).** In the SAME `build` method, find this EXACT block (the end of the `AlertDialog`):
```dart
        StatefulBuilder(
          builder: (context, setState) {
             return ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                onUpdate();
              },
              child: const Text('Download & Install'),
            );
          }
        ),
      ],
    );
  }
}
```
Replace it with:
```dart
        StatefulBuilder(
          builder: (context, setState) {
             return ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                onUpdate();
              },
              child: const Text('Download & Install'),
            );
          }
        ),
      ],
    ),
    );
  }
}
```
(The added `),` closes the new `PopScope`.)

---

**Step 14 — Locate (lock the showDialog barrier — global helper).** In `lib/features/update/widgets/update_dialogs.dart`, find this EXACT block:
```dart
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
    showDialog(
      context: context,
      builder: (ctx) => UpdateAvailableDialog(
        updateInfo: info,
        onUpdate: () => performUpdate(ctx, info),
      ),
    );
}
```

**Step 15 — Change.** Replace it with:
```dart
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
    showDialog(
      context: context,
      barrierDismissible: !info.forceUpdate,
      builder: (ctx) => UpdateAvailableDialog(
        updateInfo: info,
        onUpdate: () => performUpdate(ctx, info),
      ),
    );
}
```

---

**Step 16 — Locate (lock the showDialog barrier — main.dart call site).** In `lib/main.dart`, find this EXACT block (inside `_performStartupChecks`):
```dart
      await showDialog(
        context: context,
        builder: (ctx) => UpdateAvailableDialog(
           updateInfo: updateInfo,
           onUpdate: () => _performUpdate(ctx, updateService, updateInfo),
        )
      );
```

**Step 17 — Change.** Replace it with:
```dart
      await showDialog(
        context: context,
        barrierDismissible: !updateInfo.forceUpdate,
        builder: (ctx) => UpdateAvailableDialog(
           updateInfo: updateInfo,
           onUpdate: () => _performUpdate(ctx, updateService, updateInfo),
        )
      );
```
**⚠️ ORDER: apply this Step 16/17 BEFORE Task 29.** If Task 29 was already applied, the Locate block above will not match (the `onUpdate:` line now reads `performUpdate(ctx, updateInfo)`). In that case find the same `await showDialog( context: context, builder: (ctx) => UpdateAvailableDialog(` block and insert ONLY the new line `barrierDismissible: !updateInfo.forceUpdate,` immediately after `context: context,` — do not touch the `onUpdate:` line.

---

**Step 18 — Locate (lock the showDialog barrier — settings_screen.dart call site).** In `lib/features/settings/screens/settings_screen.dart`, find this EXACT block (inside `_checkForUpdates`):
```dart
      showDialog(
        context: context,
        builder: (ctx) => UpdateAvailableDialog(
          updateInfo: info,
          onUpdate: () => _performUpdate(ctx, service, info),
        ),
      );
```

**Step 19 — Change.** Replace it with:
```dart
      showDialog(
        context: context,
        barrierDismissible: !info.forceUpdate,
        builder: (ctx) => UpdateAvailableDialog(
          updateInfo: info,
          onUpdate: () => _performUpdate(ctx, service, info),
        ),
      );
```
(Same note as Step 17: if Task 29 ran first, the `onUpdate:` line becomes `onUpdate: () => performUpdate(ctx, info),` — keep whichever is present; only add the `barrierDismissible:` line.)

**Why:** Without a checksum, host pin, and redirect block, a MITM or compromised CDN/redirect can feed a malicious APK that passes the ZIP-magic check; without locked dialogs a user can dodge a mandatory security update. These close the client-side gaps that the SHA-256 in `version.json` is meant to anchor.

**How to test:**
- *Static:* `fvm flutter pub get` then `fvm flutter analyze` must be clean for all five touched files (no unused-import or type errors).
- *Unit test* (feasible for the model parser) — create `test/update_info_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:passwordpdf_manager/features/update/models/update_info.dart';

void main() {
  test('fromJson parses string buildNumber and sha256', () {
    final info = UpdateInfo.fromJson({
      'version': '1.2.3',
      'buildNumber': '42',
      'downloadUrl': 'https://github.com/x/y/app.apk',
      'forceUpdate': 'true',
      'sha256': 'ABC123',
    });
    expect(info.buildNumber, 42);
    expect(info.forceUpdate, isTrue);
    expect(info.sha256, 'abc123');
  });

  test('fromJson tolerates missing sha256', () {
    final info = UpdateInfo.fromJson({'version': '1.0.0', 'buildNumber': 1});
    expect(info.sha256, isNull);
  });
}
```
Run `fvm flutter test test/update_info_test.dart` — both tests pass.
- *Manual:*
  1. Publish a `version.json` whose `downloadUrl` points to a non-github.com host → trigger Settings ▸ Check for updates ▸ Download & Install → expect download to fail (snackbar "Download failed") and a log line `Refusing download: untrusted or non-https URL host`.
  2. Publish `version.json` with a correct `sha256` for the real APK → update completes and the installer opens.
  3. Publish `version.json` with a deliberately wrong `sha256` → expect "Download failed" snackbar, the temp `update_*.apk` is deleted, and a log line `APK checksum mismatch`.
  4. Publish `version.json` with `"forceUpdate": true` → on the Update Available dialog, tapping outside it and pressing Android back both do nothing; only "Download & Install" works (no "Later" button).

**Done when:** Downloads from non-`github.com` hosts and redirected responses are rejected; a manifest `sha256` mismatch deletes the file and aborts install; force-update dialogs cannot be dismissed by back button or barrier tap; `UpdateInfo.fromJson` no longer throws on a string `buildNumber`/`forceUpdate`; analyze and the unit tests pass.

**⚠️ Cautions:**
- Do the `pubspec.yaml` edit + `pub get` FIRST or the `crypto` import will not resolve and analyze will fail across the whole task.
- Apply Task 29 (collapse `_performUpdate`) and this task in a known order. The `expectedSha256: info.sha256` change in Steps 9–10 targets the GLOBAL `performUpdate` in `update_dialogs.dart`. If you apply THIS task before Task 29, you must ALSO add `, expectedSha256: info.sha256` to the two per-screen `_performUpdate` copies (`main.dart` ~line 906 and `settings_screen.dart` ~line 915) at their `}).then((file)` boundary, or those paths stay unverified. Cleanest: apply Task 29 first, then this task only has one download call to touch.
- This task does NOT implement signing-cert pinning (see the flagged note at top) — do not claim the updater is fully hardened without that native follow-up.

### Task 13 — cleanupUpdateFile must delete `update_*.apk`, not the literal `update.apk`
- **Roadmap:** Phase 2, step 13 (from fix-order.md) — NOTE: `fix-order.md` absent; step from brief.
- **Type:** Correctness (storage leak) · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/features/update/services/update_service.dart` (~lines 192–205)
- **Goal:** Delete every downloaded `update_<timestamp>.apk` left in the cache dir, since downloads are never named `update.apk`.

**Step 1 — Locate.** In `lib/features/update/services/update_service.dart`, find this EXACT block:
```dart
  Future<void> cleanupUpdateFile() async {
    try {
      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();
      final file = File('${dir.path}/update.apk');
      
      if (await file.exists()) {
        await file.delete();
        _log.info('UpdateService', 'Cleaned up install file');
      }
    } catch (e, stack) {
      _log.error('UpdateService', 'Cleanup failed', e, stack);
    }
  }
```

**Step 2 — Change.** Replace it with:
```dart
  Future<void> cleanupUpdateFile() async {
    try {
      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();

      // Downloads are named 'update_<timestamp>.apk' (see downloadUpdate), so
      // delete every matching leftover, not a single literal 'update.apk'.
      int deleted = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last
              : '';
          if (name.startsWith('update_') && name.endsWith('.apk')) {
            try {
              await entity.delete();
              deleted++;
            } catch (e, stack) {
              _log.error('UpdateService', 'Failed to delete stale update file: ${entity.path}', e, stack);
            }
          }
        }
      }
      if (deleted > 0) {
        _log.info('UpdateService', 'Cleaned up $deleted stale update file(s)');
      }
    } catch (e, stack) {
      _log.error('UpdateService', 'Cleanup failed', e, stack);
    }
  }
```

**Why:** `downloadUpdate` writes `update_${millis}.apk` (line ~123), so the old code matched a filename that is never created and every downloaded APK accumulated in the external cache forever.

**How to test:**
- *Static:* `fvm flutter analyze` clean for `update_service.dart`.
- *Manual:*
  1. Trigger an update download (Settings ▸ Check for updates ▸ Download & Install) so at least one `update_*.apk` exists in the app's external cache dir.
  2. Cold-restart the app (this runs `_performStartupChecks` → `cleanupUpdateFile`).
  3. Inspect the external cache dir → expect no `update_*.apk` files remain and a log line `Cleaned up N stale update file(s)`.

**Done when:** After a startup cleanup, no `update_*.apk` files remain in the cache directory and the count is logged; a missing directory or delete error is logged, not thrown.

**⚠️ Cautions:** `dir.list()` is a `Stream`; keep the `await for`. Do not switch to `listSync()` (blocks the UI isolate). This runs at startup before other update logic — keep it ordered before `checkForUpdate`.

### Task 29 — Collapse the triplicated `_performUpdate` into the single global `performUpdate`
- **Roadmap:** Phase 4, step 29 (from fix-order.md) — NOTE: `fix-order.md` absent; step from brief.
- **Type:** Arch (de-duplication) · **Effort:** M · **Risk if done wrong:** med · **Low-model-safe:** With-care
- **File(s):** `lib/main.dart` (~lines 878–925), `lib/features/settings/screens/settings_screen.dart` (~lines 883–934)
- **Goal:** Make both screens call the one global `performUpdate(BuildContext, UpdateInfo)` in `update_dialogs.dart` and delete their private `_performUpdate` copies.

The canonical implementation already exists in `lib/features/update/widgets/update_dialogs.dart`:
```dart
Future<void> performUpdate(BuildContext context, UpdateInfo info) async {
```
Both target files already `import '.../update/widgets/update_dialogs.dart';` (main.dart line 30, settings_screen.dart line 20), so no new import is needed. Note: the global `performUpdate` constructs its OWN `UpdateService()` internally, so callers no longer pass a `service` argument.

---

**Step 1 — Locate (main.dart call site).** In `lib/main.dart`, find this EXACT line:
```dart
           onUpdate: () => _performUpdate(ctx, updateService, updateInfo),
```

**Step 2 — Change.** Replace it with:
```dart
           onUpdate: () => performUpdate(ctx, updateInfo),
```

**Step 3 — Locate (delete the main.dart private copy).** In `lib/main.dart`, find this EXACT block and DELETE it entirely:
```dart
  Future<void> _performUpdate(BuildContext context, UpdateService service, UpdateInfo info) async {
    bool started = false;
    double progress = 0;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
           builder: (context, setDialogState) {
              if (!started) {
                  started = true;
                  service.downloadUpdate(info.downloadUrl, (received, total) {
                      if (total != -1) {
                         setDialogState(() {
                            progress = received / total;
                         });
                      }
                  }).then((file) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext); // Close progress
                      
                      if (file != null) {
                         service.installUpdate(file);
                      } else {
                         if (context.mounted) {
                           ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Download failed')),
                           );
                         }
                      }
                  });
              }
              return UpdateProgressDialog(progress: progress);
           }
        );
      }
    );
  }
```

**Step 4 — Change.** Replace that block with NOTHING (remove it; the preceding `}` of `_performStartupChecks` and the following `void _showDuplicateSelectionSheet()` stay intact).

---

**Step 5 — Locate (settings_screen.dart call site).** In `lib/features/settings/screens/settings_screen.dart`, find this EXACT line:
```dart
          onUpdate: () => _performUpdate(ctx, service, info),
```

**Step 6 — Change.** Replace it with:
```dart
          onUpdate: () => performUpdate(ctx, info),
```

**Step 7 — Locate (delete the settings_screen.dart private copy).** In `lib/features/settings/screens/settings_screen.dart`, find this EXACT block and DELETE it entirely:
```dart
  Future<void> _performUpdate(BuildContext context, UpdateService service, UpdateInfo info) async {
    bool started = false;
    double progress = 0;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
           builder: (context, setDialogState) {
              if (!started) {
                  started = true;
                  service.downloadUpdate(info.downloadUrl, (received, total) {
                      if (total != -1) {
                         setDialogState(() {
                            progress = received / total;
                         });
                      }
                  }).then((file) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext); // Close progress
                      
                      if (file != null) {
                         service.installUpdate(file);
                      } else {
                         if (context.mounted) {
                           ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Download failed')),
                           );
                         }
                      }
                  });
              }
              return UpdateProgressDialog(progress: progress);
           }
        );
      }
    );
  }
```

**Step 8 — Change.** Replace that block with NOTHING. NOTE: In `settings_screen.dart` this is the last method of the class; after deletion ensure exactly ONE closing `}` for the class remains (the file ends with `}` then a blank line). Do not delete the class's closing brace.

**Why:** Three near-identical copies of the download/install dialog drift apart (e.g. the global copy already handles install-failure snackbars and `async`, the private copies do not) and triple the surface for security fixes like Task 1. One implementation means one place to harden.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `main.dart` and `settings_screen.dart` — specifically zero "The declaration '_performUpdate' isn't referenced" and zero "method isn't defined" errors. After the edits the local `updateService`/`service` variables are still used elsewhere (the `checkForUpdate` calls), so no new unused-variable warnings should appear; if analyze reports one, leave the variable (it is still referenced by `checkForUpdate`).
- *Manual:*
  1. Startup with a pending update (main.dart path) → Update Available dialog → Download & Install → progress dialog appears, downloads, installer opens. On failure a "Download failed" snackbar shows.
  2. Settings ▸ Check for updates with a pending update (settings path) → same behavior.
- *Both paths now exercise the identical global `performUpdate`.*

**Done when:** No `_performUpdate` method exists in `main.dart` or `settings_screen.dart`; both `onUpdate:` callbacks call the global `performUpdate(ctx, info)`; analyze is clean; both update entry points download and install correctly.

**⚠️ Cautions:**
- Sequencing with Task 1: prefer applying THIS task first, then Task 1 — that way Steps 9–10 of Task 1 (`expectedSha256: info.sha256`) only need to touch the single global `performUpdate`. If you applied Task 1 first, re-verify the checksum argument survived and that you are not re-introducing an un-hardened copy here.
- Do not also delete the `UpdateService updateService`/`service` local declarations — they are still used by `cleanupUpdateFile`, `getLatestReleaseInfo`, and `checkForUpdate` in those methods.

---

# PHASE 1 — Quick wins
### Task 11 — Add Share action to the viewer AppBar (reuse `_handleShareFile`)
- **Roadmap:** Phase 3 (Features), step 11 (from fix-order.md)
- **Type:** Feature · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/features/documents/screens/pdf_viewer_screen.dart` (~lines 268–284 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Ensure the viewer AppBar always shows a working Share button that reuses the existing `_handleShareFile()` method, so PDFs opened from All Documents can be shared.

**IMPORTANT — read this first:** The Share `IconButton` ALREADY EXISTS in this file. Verify by string-matching the block in Step 1 below. The share method is the existing `Future<void> _handleShareFile()` at ~line 593, which uses `Share.shareXFiles([XFile(widget.filePath)], text: widget.fileName)` (import `package:share_plus/share_plus.dart` is already present at line 9). 

**Gating / how All-Docs opens the viewer (context, no edit needed):**
- All Documents opens the viewer via `_importAndOpenSingle` and `_openFile` in `lib/features/documents/screens/all_documents_screen.dart` (~lines 442 and 547). Both push `PdfViewerScreen(filePath:..., fileName:..., password: storedPassword)` and DO NOT pass `isExternal`, so `isExternal` defaults to `false`.
- The Share button is NOT gated by `isExternal` — only the "Save to Folder" (`Icons.save_alt`) button is wrapped in `if (widget.isExternal)`. The Share button sits OUTSIDE that `if`, so it shows for All-Docs-opened files already.

**Step 1 — Locate.** In `lib/features/documents/screens/pdf_viewer_screen.dart`, find this EXACT block:
```dart
          ] else ...[
            if (widget.isExternal)
              IconButton(
                icon: const Icon(Icons.save_alt),
                tooltip: 'Save to Folder',
                onPressed: () => _handleSaveFile(context),
              ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Share File',
              onPressed: () => _handleShareFile(),
            ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _startSearch,
            ),
          ],
```

**Step 2 — Change.** This block is already correct. Make NO code change. Confirm that:
1. The `IconButton` with `icon: const Icon(Icons.share)` is present and its `onPressed` calls `_handleShareFile()`.
2. The Share `IconButton` is OUTSIDE the `if (widget.isExternal)` guard (i.e. not indented under it).

If — and only if — the Share `IconButton` is missing, insert it immediately AFTER the closing `),` of the `if (widget.isExternal) IconButton(...)` block and BEFORE the `IconButton(icon: const Icon(Icons.search), ...)`, using exactly:
```dart
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Share File',
              onPressed: () => _handleShareFile(),
            ),
```

**Why:** The Share action reuses the existing `_handleShareFile()` (share_plus) and is intentionally NOT gated by `isExternal`, so files opened from All Documents (which pass `isExternal=false`) can still be shared.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `pdf_viewer_screen.dart` (no unused-import / undefined-method errors).
- *Manual:*
  1. Open All Documents → tap any PDF → viewer opens.
  2. In the AppBar (not searching, not loading), expect a Share icon (`Icons.share`) to be visible.
  3. Tap Share → expect the OS share sheet to appear listing the file. On failure expect a red SnackBar "Share failed: …".

**Done when:** A Share icon appears in the viewer AppBar for PDFs opened from All Documents, and tapping it opens the native share sheet (or shows the red "Share failed:" SnackBar on error).

**⚠️ Cautions:** Do NOT move the Share button inside the `if (widget.isExternal)` block — that would hide it for All-Docs-opened files. Do not duplicate the button (it already exists).

---

### Task 12 — Add "File info" to the viewer overflow menu (push `FileInfoScreen`)
- **Roadmap:** Phase 3 (Features), step 12 (from fix-order.md)
- **Type:** Feature · **Effort:** M · **Risk if done wrong:** med · **Low-model-safe:** With-care
- **File(s):** `lib/features/documents/screens/pdf_viewer_screen.dart` (imports ~lines 16–18; menu handler ~lines 288–295; menu items ~lines 296–311)
- **Goal:** Add a "File info" `PopupMenuItem` to the viewer's overflow (`⋮`) menu that builds a `DocumentItem` for the current file and pushes `FileInfoScreen`.

**Context — `FileInfoScreen` constructor & how to build a `DocumentItem` (no edit, read only):**
- `FileInfoScreen` constructor (in `lib/features/documents/screens/file_info_screen.dart`, ~line 13): `const FileInfoScreen({super.key, required this.file})` where `file` is a `DocumentItem`.
- `DocumentItem` constructor (in `lib/models/document_item_model.dart`, ~line 19) requires `id`, `name`, `type`; relevant optionals: `sourcePath`, `size`, `createdAt`, `modifiedAt`. The `isPdf` getter relies on `sourcePath` ending in `.pdf`.
- The All-Docs lookup pattern to copy is `_showFileInfo` in `all_documents_screen.dart` (~lines 916–934): it calls `docService.findFileIdByPath(file.path)` for the id (else a `temp_...` id) and fills `size`/`createdAt`/`modifiedAt` from `file.statSync()` (`stat.size`, `stat.changed`, `stat.modified`).
- In the viewer, `DocumentService()` is already imported (line 18) and is a singleton-style class exposing `findFileIdByPath(String path)`. The viewer also already imports `dart:io` (line 3) for `File`.

**Step 1 — Locate (imports).** In `lib/features/documents/screens/pdf_viewer_screen.dart`, find this EXACT block:
```dart
import '../widgets/duplicate_files_dialog.dart';
import '../../../services/document_service.dart';
```

**Step 2 — Change (imports).** Replace it with:
```dart
import '../widgets/duplicate_files_dialog.dart';
import '../../../services/document_service.dart';
import 'file_info_screen.dart';
import '../../../models/document_item_model.dart';
```

**Step 3 — Locate (menu `onSelected` handler).** Find this EXACT block:
```dart
            onSelected: (value) async {
              if (value == 'remove_password') await _handleRemovePassword(context);
              else if (value == 'add_password') await _handleAddPassword(context);
              else if (value == 'reorder') await _handleReorder(context);
              else if (value == 'split') await _handleSplit(context);
              else if (value == 'merge') await _handleMerge(context);
              else if (value == 'go_to_page') await _handleGoToPage(context);
            },
```

**Step 4 — Change (menu `onSelected` handler).** Replace it with:
```dart
            onSelected: (value) async {
              if (value == 'remove_password') await _handleRemovePassword(context);
              else if (value == 'add_password') await _handleAddPassword(context);
              else if (value == 'reorder') await _handleReorder(context);
              else if (value == 'split') await _handleSplit(context);
              else if (value == 'merge') await _handleMerge(context);
              else if (value == 'go_to_page') await _handleGoToPage(context);
              else if (value == 'file_info') await _handleFileInfo(context);
            },
```

**Step 5 — Locate (menu items list).** Find this EXACT block:
```dart
                const PopupMenuItem(
                  value: 'go_to_page',
                  child: Row(children: [Icon(Icons.directions), SizedBox(width: 8), Text('Go to Page')]),
                ),
                const PopupMenuDivider(),
```

**Step 6 — Change (menu items list).** Replace it with:
```dart
                const PopupMenuItem(
                  value: 'go_to_page',
                  child: Row(children: [Icon(Icons.directions), SizedBox(width: 8), Text('Go to Page')]),
                ),
                const PopupMenuItem(
                  value: 'file_info',
                  child: Row(children: [Icon(Icons.info_outline), SizedBox(width: 8), Text('File info')]),
                ),
                const PopupMenuDivider(),
```

**Step 7 — Locate (insertion point for the new handler method).** Find this EXACT block (the existing `_handleGoToPage` method, used only as an anchor):
```dart
  Future<void> _handleGoToPage(BuildContext context) async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => PageNavigationDialog(
        totalPages: _totalPages,
        currentPage: _currentPage,
      ),
    );

    if (result != null && mounted) {
      _pdfViewerController.goToPage(pageNumber: result);
    }
  }
```

**Step 8 — Change (insert the new handler).** Replace the block from Step 7 with that SAME block followed by the new method:
```dart
  Future<void> _handleGoToPage(BuildContext context) async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => PageNavigationDialog(
        totalPages: _totalPages,
        currentPage: _currentPage,
      ),
    );

    if (result != null && mounted) {
      _pdfViewerController.goToPage(pageNumber: result);
    }
  }

  Future<void> _handleFileInfo(BuildContext context) async {
    // Build a DocumentItem for the currently-open file.
    // Prefer the library id if this file is already imported (findFileIdByPath),
    // otherwise construct a temp item from the on-disk File stat.
    final file = File(widget.filePath);
    if (!file.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File not found'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    final stat = file.statSync();
    final existingId = DocumentService().findFileIdByPath(widget.filePath);

    final item = DocumentItem(
      id: existingId ?? 'temp_${DateTime.now().millisecondsSinceEpoch}',
      name: widget.fileName,
      type: DocumentItemType.file,
      sourcePath: widget.filePath,
      size: stat.size,
      createdAt: stat.changed,
      modifiedAt: stat.modified,
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FileInfoScreen(file: item)),
    );
  }
```

**Why:** Exposes file metadata (size, type, password-protected status, occurrences) from inside the viewer by reusing the existing `FileInfoScreen`, building the `DocumentItem` the same way All Documents already does (`findFileIdByPath` + `File.statSync()`).

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `pdf_viewer_screen.dart`. Confirm no "undefined name `DocumentItem`/`FileInfoScreen`/`DocumentItemType`" errors (the two new imports satisfy these).
- *Manual:*
  1. Open a password-protected PDF → tap `⋮` → tap "File info" → expect the File Information screen with the file name, Size, Type "PDF Document", and Security "Password Protected".
  2. Open a non-protected PDF → `⋮` → "File info" → expect Security "No Password".
  3. From the File Info screen tap back → expect to return to the viewer with the PDF still open.

**Done when:** A "File info" item with `Icons.info_outline` appears above the first divider in the viewer's overflow menu, and selecting it pushes `FileInfoScreen` showing correct size/type/security for the open file.

**⚠️ Cautions:**
- `DocumentService()` here is the direct singleton instance (matching line 18 usage), NOT a Provider lookup — do not change it to `Provider.of<DocumentService>(context)`; the viewer is not always inside that Provider scope.
- Do not remove or reorder the existing menu items; only insert the new `PopupMenuItem` exactly where shown (immediately after `go_to_page`, before the `PopupMenuDivider`).
- `_checkProtection()` inside `FileInfoScreen` runs its own protection check via `PdfToolsService().isProtected(...)`; you do NOT need to pass a password.

---

### Task 13 — Treat "No Password" ('') as a real empty-password attempt in `_getPassword`
- **Roadmap:** Phase (No-Password), step 13 (from fix-order.md)
- **Type:** Correctness · **Effort:** S · **Risk if done wrong:** med · **Low-model-safe:** With-care
- **File(s):** `lib/features/documents/screens/pdf_viewer_screen.dart` (~lines 164–179 as of writing — VERIFY before editing)
- **Goal:** When the `PasswordSelectionDialog` returns `''` (the explicit "No Password" choice), submit `''` as a genuine empty-password attempt to the PDF engine instead of treating it as a cancel and popping the viewer.

**Context (read only):** `_getPassword()` is the `passwordProvider` for `PdfViewer.file` (wired at ~line 322: `passwordProvider: () => _getPassword()`). The dialog `showDialog<String>` can return three things: `null` (user dismissed / cancelled), `''` (user chose "No Password"), or a non-empty password string. Today the code uses `if (password != null && password.isNotEmpty)` so `''` falls through to the cancel branch and calls `Navigator.pop(context)`, closing the viewer. The fix distinguishes `null` (cancel) from `''` (empty-password attempt).

**Step 1 — Locate.** In `lib/features/documents/screens/pdf_viewer_screen.dart`, find this EXACT block:
```dart
    // 4. If all candidates fail, Prompt User
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PasswordSelectionDialog(),
    );
    
    if (password != null && password.isNotEmpty) {
      _currentPassword = password;
      return password;
    }
    
    // User cancelled
    if (mounted) {
       Navigator.pop(context);
    }
    return null;
```

**Step 2 — Change.** Replace it with:
```dart
    // 4. If all candidates fail, Prompt User
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PasswordSelectionDialog(),
    );

    // Distinguish: null  = user cancelled/dismissed (pop the viewer),
    //              ''    = user chose "No Password" -> attempt empty password,
    //              other = a real password attempt.
    if (password != null) {
      _currentPassword = password;
      return password;
    }

    // User cancelled
    if (mounted) {
       Navigator.pop(context);
    }
    return null;
```

**Why:** Some PDFs report as encrypted but open with an empty owner/user password; previously choosing "No Password" popped the viewer instead of letting the engine try `''`. Returning `''` lets pdfrx attempt the empty password, and only a true `null` (cancel) closes the screen.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `pdf_viewer_screen.dart`.
- *Manual:*
  1. Open a PDF that is flagged encrypted but actually has an empty password → when the password dialog appears choose "No Password" → expect the PDF to open (the viewer should NOT pop back to the list).
  2. Open a genuinely password-protected PDF → choose "No Password" → expect the pdfrx error banner "Password Required" with the "Enter Password" button (the engine rejects `''`), and the viewer stays open.
  3. On the password dialog, dismiss/cancel (return `null`) → expect the viewer to pop back to the previous screen (unchanged behavior).
- *Widget test (optional, if `PasswordSelectionDialog` can be stubbed):* assert that when the dialog future completes with `''`, `_getPassword()` resolves to `''` and `Navigator.pop` is NOT invoked; when it completes with `null`, `Navigator.pop` IS invoked.

**Done when:** Choosing "No Password" returns `''` to the password provider (PDF opens if `''` is valid, or shows the in-viewer "Password Required" banner if not), and only a `null` result (true cancel) pops the viewer.

**⚠️ Cautions:**
- Verify `PasswordSelectionDialog` actually returns `''` (not `null`) for its "No Password" / empty action before relying on this; if that dialog pops with `null` for "No Password", this card has no effect and the dialog must be fixed first (out of scope here — flag for senior review).
- Do NOT also change the candidate-loop logic above (lines ~125–161); the empty-string handling only applies to the manual dialog branch.
- After this change, a wrong/empty password still surfaces via the existing `errorBannerBuilder` ("No password supplied") path — do not remove that banner.

---

### Task 13 — Treat empty-but-checked ZIP password as no-password; key folder-count cache by active filter
- **Roadmap:** Phase 1, step 13 (from fix-order.md)
- **Type:** Correctness · **Effort:** M · **Risk if done wrong:** med · **Low-model-safe:** With-care
- **File(s):** `lib/features/documents/screens/document_dashboard_screen.dart` (~lines 1289, 2386–2390, 2499–2503, 2683, 2695, 2600 — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** When the user checks "Protect with Password" but leaves the field blank, export with NO password instead of an empty-string password; and make the folder-count cache correct when the active file-type filter (`_filterType`) changes.

This task has TWO independent parts (13a and 13b). Apply both.

---

**Part 13a — empty-but-checked ZIP password.**

**Step 1 — Locate.** In `lib/features/documents/screens/document_dashboard_screen.dart`, this EXACT block appears at **TWO** locations (≈ line 460 in `_exportSelectedItems`, and ≈ line 1288 in `_exportFolderAsZip`). Apply the SAME replacement to **BOTH** (use replace-all, or do two separate edits):
```dart
    // Use password only if encrypt checked
    final zipPassword = encrypt ? password : null;
```

**Step 2 — Change.** Replace it with:
```dart
    // Use password only if encrypt checked AND a non-empty password was entered.
    // An empty-but-checked password must be treated as no password.
    final zipPassword = (encrypt && password != null && password!.trim().isNotEmpty)
        ? password
        : null;
```

---

**Part 13b — key the folder-count cache by the active filter.**

The cache stores `fileCount` that is computed with `_applyFileFilter(...)`, so its value depends on `_filterType`. It is keyed only by `folder.id`, so switching filter chips shows stale counts. Key every cache access by a composite `'$_filterType:$folderId'`. There are FOUR access sites; change all four, then invalidate on the filter chip tap.

**Step 1 — Locate** (root-level pre-populate loop; unique because of `subfolderCount` spelling and `getSubfolders`):
```dart
      for (final folder in folders) {
        if (!_folderCountCache.containsKey(folder.id)) {
          final files = _docService.getFilesInFolder(folder.id);
          final fileCount = _applyFileFilter(files).length;
          final subfolderCount = _docService.getSubfolders(folder.id).length;
          _folderCountCache[folder.id] = (fileCount, subfolderCount);
        }
      }
```

**Step 2 — Change.** Replace it with:
```dart
      for (final folder in folders) {
        final cacheKey = '$_filterType:${folder.id}';
        if (!_folderCountCache.containsKey(cacheKey)) {
          final files = _docService.getFilesInFolder(folder.id);
          final fileCount = _applyFileFilter(files).length;
          final subfolderCount = _docService.getSubfolders(folder.id).length;
          _folderCountCache[cacheKey] = (fileCount, subfolderCount);
        }
      }
```

**Step 3 — Locate** (subfolder pre-populate loop; unique because of `subCount` and `getSubfolders`):
```dart
      for (final folder in subfolders) {
        if (!_folderCountCache.containsKey(folder.id)) {
          final folderFiles = _docService.getFilesInFolder(folder.id);
          final fileCount = _applyFileFilter(folderFiles).length;
          final subCount = _docService.getSubfolders(folder.id).length;
          _folderCountCache[folder.id] = (fileCount, subCount);
        }
      }
```

**Step 4 — Change.** Replace it with:
```dart
      for (final folder in subfolders) {
        final cacheKey = '$_filterType:${folder.id}';
        if (!_folderCountCache.containsKey(cacheKey)) {
          final folderFiles = _docService.getFilesInFolder(folder.id);
          final fileCount = _applyFileFilter(folderFiles).length;
          final subCount = _docService.getSubfolders(folder.id).length;
          _folderCountCache[cacheKey] = (fileCount, subCount);
        }
      }
```

**Step 5 — Locate** (the `_buildFolderSubtitle` body; unique because of the `cached != null` line):
```dart
  String _buildFolderSubtitle(String folderId) {
    // Check cache first to avoid expensive service calls during scroll
    final cached = _folderCountCache[folderId];
    if (cached != null) {
      final (fileCount, subfolderCount) = cached;
      final filePart = '$fileCount ${fileCount == 1 ? 'file' : 'files'}';
      final folderPart = '$subfolderCount ${subfolderCount == 1 ? 'folder' : 'folders'}';
      return '$filePart, $folderPart';
    }
    
    // Fallback: compute and cache (should rarely happen)
    final allFiles = _docService.getFilesInFolder(folderId);
    final fileCount = _applyFileFilter(allFiles).length;
    final subfolderCount = _docService.getSubfolders(folderId).length;
    _folderCountCache[folderId] = (fileCount, subfolderCount);
```

**Step 6 — Change.** Replace it with:
```dart
  String _buildFolderSubtitle(String folderId) {
    final cacheKey = '$_filterType:$folderId';
    // Check cache first to avoid expensive service calls during scroll
    final cached = _folderCountCache[cacheKey];
    if (cached != null) {
      final (fileCount, subfolderCount) = cached;
      final filePart = '$fileCount ${fileCount == 1 ? 'file' : 'files'}';
      final folderPart = '$subfolderCount ${subfolderCount == 1 ? 'folder' : 'folders'}';
      return '$filePart, $folderPart';
    }
    
    // Fallback: compute and cache (should rarely happen)
    final allFiles = _docService.getFilesInFolder(folderId);
    final fileCount = _applyFileFilter(allFiles).length;
    final subfolderCount = _docService.getSubfolders(folderId).length;
    _folderCountCache[cacheKey] = (fileCount, subfolderCount);
```

**Step 7 — Locate** (the filter-chip tap; unique because of `_filterType = type`):
```dart
                onSelected: (selected) {
                  setState(() => _filterType = type);
                },
```

**Step 8 — Change.** Replace it with (invalidate the cache on filter change so subtitles recompute under the new filter):
```dart
                onSelected: (selected) {
                  setState(() {
                    _folderCountCache.clear();
                    _filterType = type;
                  });
                },
```

**Why:** An empty checked password produced a "password-protected" ZIP whose password is the empty string, which most archive tools cannot open; treating it as no-password is the safe behavior. The count cache mixed values computed under different `_filterType` values under the same key, so chip switches showed wrong file counts.

**How to test:**
- *Static:* `fvm flutter analyze lib/features/documents/screens/document_dashboard_screen.dart` must be clean.
- *Manual (13a):* 1. Open a folder → ⋮ → Export as ZIP. 2. Tick "Protect with Password", leave the field blank, tap Export. 3. Open the produced ZIP → expect it opens WITHOUT a password prompt. 4. Repeat but type a real password → expect the ZIP requires that password.
- *Manual (13b):* 1. Open a folder containing a mix of PDF and DOC files (and a subfolder with mixed files). 2. Note a subfolder's subtitle count under "All". 3. Tap the "PDF" filter chip → expect the subfolder subtitle's file count drops to only PDFs. 4. Tap back to "All" → expect the count returns to the full count (no stale value).

**Done when:** Empty-checked-password exports open without a password; and toggling filter chips immediately updates folder subtitle file counts to match the selected filter.

**⚠️ Cautions:** Change ALL FOUR cache key sites (Steps 1–6) plus the chip invalidation (Step 7–8) together — leaving any single read/write keyed by the bare `folder.id` while others use the composite key will permanently desync the cache. Do not batch this task with Task 9 unless you re-verify line numbers, since both touch this file.

---

### Task 8 — Add `orElse` to the move/select `firstWhere` sites
- **Roadmap:** Phase 1, step 8 (from fix-order.md)
- **Type:** Crash · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/features/documents/screens/document_dashboard_screen.dart` (~lines 1389–1391, 1463 — VERIFY before editing)
- **Goal:** Prevent `StateError` ("No element") when a selected id or a destination duplicate is not found by `firstWhere`.

**Step 1 — Locate** (the move-source mapping; unique because of `_selectedFileIds.map`):
```dart
      final filesToMove = _selectedFileIds.map((id) => 
        _docService.getAllItems().firstWhere((item) => item.id == id)
      ).toList();
```

**Step 2 — Change.** Replace it with:
```dart
      final filesToMove = _selectedFileIds
          .map((id) => _docService.getAllItems().firstWhere(
                (item) => item.id == id,
                orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.file),
              ))
          .where((item) => item.id.isNotEmpty)
          .toList();
```

**Step 3 — Locate** (the overwrite destination lookup; unique because of `// Delete Destination File`):
```dart
             // Delete Destination File
             final destFile = destinationFiles.firstWhere((f) => f.name.toLowerCase() == file.name.toLowerCase());
             await _docService.deleteItem(destFile.id); // This deletes the destination entry
```

**Step 4 — Change.** Replace it with:
```dart
             // Delete Destination File
             final destFile = destinationFiles.firstWhere(
               (f) => f.name.toLowerCase() == file.name.toLowerCase(),
               orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.file),
             );
             if (destFile.id.isNotEmpty) {
               await _docService.deleteItem(destFile.id); // This deletes the destination entry
             }
```

**Why:** Without `orElse`, `firstWhere` throws `StateError` and aborts the whole move when a selected id is stale (e.g. file deleted on another device) or the overwrite duplicate no longer exists, crashing the operation instead of skipping the missing item.

**How to test:**
- *Static:* `fvm flutter analyze lib/features/documents/screens/document_dashboard_screen.dart` must be clean. The sentinel `DocumentItem(id: '', name: '', type: DocumentItemType.file)` already appears at the nearby destination-folder `firstWhere` (around line 1370–1372), so the constructor signature is correct for this file.
- *Manual:* 1. Multi-select several files → Move → pick a destination folder that already contains a same-named file → choose "Overwrite" in the conflict dialog → expect the move completes and existing file is replaced (no crash). 2. Normal multi-select move with no conflicts → expect all files move successfully.

**Done when:** A move with a stale selection id or a resolvable overwrite no longer throws, and the move completes for the remaining valid items.

**⚠️ Cautions:** Keep the sentinel `DocumentItem(...)` constructor IDENTICAL to the one already used near line 1371 in this file. Do not change the conflict-detection loop above it.

---

### Task 9 — Guard the rename-import `substring` RangeError
- **Roadmap:** Phase 1, step 9 (from fix-order.md)
- **Type:** Crash · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/features/documents/screens/document_dashboard_screen.dart` (~lines 250–255 — VERIFY before editing)
- **Goal:** Prevent a `RangeError` when auto-renaming an imported file whose name has no extension (then `ext == newName`, so `newName.length - ext.length - 1 == -1`).

**Step 1 — Locate** (the auto-rename loop in the import conflict handler; unique because of `getFileIdInFolder` + `nameNoExt`):
```dart
                     // Auto-rename: Append number
                     String newName = fileName;
                     int i = 1;
                     while (_docService.getFileIdInFolder(newName, _currentFolderId) != null) {
                         final ext = newName.split('.').last;
                         final nameNoExt = newName.substring(0, newName.length - ext.length - 1);
                         newName = '${nameNoExt}_$i.$ext';
                         i++;
                     }
```

**Step 2 — Change.** Replace it with:
```dart
                     // Auto-rename: Append number
                     String newName = fileName;
                     int i = 1;
                     while (_docService.getFileIdInFolder(newName, _currentFolderId) != null) {
                         final dotIndex = newName.lastIndexOf('.');
                         // No dot, or leading-dot only (e.g. ".bashrc") => treat as no extension.
                         final hasExt = dotIndex > 0;
                         final ext = hasExt ? newName.substring(dotIndex + 1) : '';
                         final nameNoExt = hasExt ? newName.substring(0, dotIndex) : newName;
                         newName = hasExt ? '${nameNoExt}_$i.$ext' : '${nameNoExt}_$i';
                         i++;
                     }
```

**Why:** For an extensionless name like `report`, `split('.').last` returns the whole string, so `newName.length - ext.length - 1` is `-1` and `substring(0, -1)` throws `RangeError`, crashing the import-with-rename path. Using `lastIndexOf('.')` with a `dotIndex > 0` guard handles no-extension and dotfile names safely.

**How to test:**
- *Static:* `fvm flutter analyze lib/features/documents/screens/document_dashboard_screen.dart` must be clean.
- *Manual:* 1. Have a file named `report` (no extension) already in the current folder. 2. Import another file named `report` → in the conflict dialog choose the auto-rename option. 3. Expect the import succeeds and the new item is named `report_1` (no crash). 4. Repeat with a normal `invoice.pdf` collision → expect `invoice_1.pdf`.

**Done when:** Importing a colliding extensionless file via auto-rename produces `<name>_<n>` without throwing, and extensioned files still produce `<name>_<n>.<ext>`.

**⚠️ Cautions:** None. This block is self-contained; do not alter the surrounding `ConflictActionType.rename` case logic.

---

Notes on roadmap-vs-code discrepancies: the line hints matched the real code closely. For Task 13, the "active filter" is the `String _filterType` field declared at line 66 (values `'All' | 'PDF' | 'DOC' | 'Excel'`) — there is no enum/`FilterType`; the cards use `_filterType` accordingly. The cache mutate-invalidation already exists in `_initialize` (`_folderCountCache.clear()`, ~line 343) and is left as-is; Task 13b adds the filter-change invalidation that was missing.

---

# PHASE 2 — Crypto migration (SENIOR REVIEW ONLY)

> ## ⚠️ READ THIS BEFORE PHASE 2
> Every card in this phase is **Low-model-safe: NO**. This is a data migration on a **live password store**. Do **not** feed these to a weak model to run unattended. Apply **one sub-step per prompt**, with a human verifying the diff and a backup taken first. The single inviolable rule: **never overwrite or delete a legacy value until its AES replacement has been proven to decrypt back to the exact original — verified on the legacy (XOR) side.** AES round-tripping its own output proves nothing, because XOR has no integrity and a wrong key produces valid-looking garbage.
> ### 🔧 Senior implementer checklist — fill/confirm BEFORE running any Phase-2 card
> The cards below are a correct design with most code, but a human MUST supply the items a weak model cannot. Verification flagged these gaps:
> - **EncryptionService:** the `encrypt()`/`decrypt()` **Locate** anchors are written by intent — before editing, replace them with the EXACT current method bodies (≈ lines 89–141). Provide verbatim `_encryptXorLegacy` / `_decryptXorLegacy` bodies (factored from the current XOR code). The secure-storage field is **`_secureStorage`** (the cards now use it). Add `import 'package:crypto/crypto.dart';` and add **`crypto:`** + **`cryptography:`** to `pubspec.yaml` (for `sha256` and AES-GCM). Replace the `<build-baked-random>` / `<sha256…>` placeholders with real baked values, and add a verbatim `_constantTimeEq` body.
> - **`primeAesKey` is public** (the cards now call `EncryptionService().primeAesKey()`); add an explicit Locate in `_performStartupChecks` for the insertion point.
> - **`settings_service.dart` is edited by BOTH Task 24 (log redaction) and Task 19 (PIN rehash).** Apply **Task 24 first** (it only changes log lines), then Task 19's `verifyPin`/`setPin` rewrite. For Task 19 Step 1, use the EXACT current `verifyPin` body (≈ lines 229–239) as the Locate anchor, and add `dart:convert` / `dart:math` imports plus the `_pbkdf2` / `_rng` bodies.
> - **Prose-only steps need verbatim anchors before automation:** Task 16 Step 4 (password_manager AppBar ≈ lines 156–159, currently only `title:` — add an `actions:` list), Task 17 SmartOpen loop (document_dashboard_screen ≈ lines 1774–1785) and the PdfPasswordService side, Task 19 Step 3/4 (developer_screen ≈ 39–65 key dialog; export_queue_service `toJson` line 77 / `fromJson` line 91 / post-encode NULL write in `_processZipJob`).
> - **Task 27:** confirm `lib/services/pdf_password_service.dart` exposes `Future<String?> getPasswordForDocument(String path)` before applying its Step 13.

### Task 15 — Read-both dispatcher + AES-256-GCM + separate key + key-health token
- **Roadmap:** Phase 2, step 15
- **Type:** Security · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** No (senior review)
- **File(s):** `lib/services/encryption_service.dart` (the `encrypt`/`decrypt` bodies ~:89–141 and the cache fields ~:8–21), `pubspec.yaml`, `lib/main.dart` (startup ~:820–833)
- **Goal:** Make `decrypt()` read **both** formats (legacy XOR and new AES-GCM) so existing passwords keep working on day one, make `encrypt()` emit AES-GCM, introduce a **separate** Keystore-backed key (leaving the old key read-only), and add a key-health check token — all additive, no existing value rewritten yet.

**Step 1 — Add the dependency.** In `pubspec.yaml` under `dependencies:` add:
```yaml
  cryptography: ^2.7.0
```
Run `fvm flutter pub get`.

**Step 2 — Locate** the existing `encrypt`/`decrypt` in `lib/services/encryption_service.dart` (the repeating-key XOR bodies, roughly):
```dart
  Future<String?> encrypt(String plainText) async {
    // ... XOR loop + base64Encode ...
  }

  Future<String?> decrypt(String encryptedText) async {
    // ... base64Decode + XOR loop + utf8.decode ...
  }
```
**Step 2 — Change.** Keep the **null-on-failure** contract (do NOT throw, do NOT force-unwrap the key). Factor the existing XOR bodies into private `_encryptXorLegacy` / `_decryptXorLegacy` (unchanged logic), and make the public methods route by tag:
```dart
import 'package:cryptography/cryptography.dart';

static const String _tagV2 = 'v2:'; // AES-GCM ciphertext

final AesGcm _aes = AesGcm.with256bits();

/// Public decrypt — routes by tag. Untagged => legacy XOR (v1). Null on any failure.
Future<String?> decrypt(String stored) async {
  try {
    if (stored.isEmpty || stored == 'NO_PASSWORD') return stored;
    if (stored.startsWith(_tagV2)) {
      return await _decryptAesGcm(stored.substring(_tagV2.length));
    }
    return await _decryptXorLegacy(stored); // bare/legacy
  } catch (e) {
    _log.error('EncryptionService', 'decrypt failed', e);
    return null; // PRESERVE the existing contract — callers treat null as "couldn't decrypt"
  }
}

/// Public encrypt — always emits v2 (AES-GCM). Null on failure.
Future<String?> encrypt(String plainText) async {
  try {
    final key = await _getAesKey();                 // see Step 4
    final nonce = _aes.newNonce();                  // CSPRNG, 12 bytes
    final box = await _aes.encrypt(utf8.encode(plainText), secretKey: key, nonce: nonce);
    final payload = <int>[...nonce, ...box.cipherText, ...box.mac.bytes];
    return _tagV2 + base64Encode(payload);
  } catch (e) {
    _log.error('EncryptionService', 'encrypt failed', e);
    return null;
  }
}

Future<String> _decryptAesGcm(String b64) async {
  final key = await _getAesKey();
  final raw = base64Decode(b64);
  final nonce = raw.sublist(0, 12);
  final mac = Mac(raw.sublist(raw.length - 16));
  final ct = raw.sublist(12, raw.length - 16);
  final clear = await _aes.decrypt(SecretBox(ct, nonce: nonce, mac: mac), secretKey: key);
  return utf8.decode(clear); // GCM auth tag throws on tamper/wrong key — never silently wrong
}
```
*(Keep `_encryptXorLegacy`/`_decryptXorLegacy` as the old code verbatim — they are still needed to read v1 data and to verify migration, Task 17.)*

**Step 3 — Locate** the secure-storage handle / key cache fields (~:8–21) and **add** an AES key cache + accessor. The new key lives under a **new** storage key `aes_key_v2`; the legacy `encryption_key` and its non-rotatable guard (~:33–53) are **left untouched**.
```dart
SecretKey? _aesKey;
final Random _rng = Random.secure(); // CSPRNG only

/// Returns the AES key, creating it ONCE. Must be primed at startup (Step 4) so two isolates can't race-create it.
Future<SecretKey> _getAesKey() async {
  if (_aesKey != null) return _aesKey!;
  var b64 = await _secureStorage.read(key: 'aes_key_v2');
  if (b64 == null) {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    b64 = base64Encode(bytes);
    await _secureStorage.write(key: 'aes_key_v2', value: b64);
  }
  _aesKey = SecretKey(base64Decode(b64));
  return _aesKey!;
}

/// Key-health: prove the LEGACY key is the correct one before any migration is allowed (rule 3).
Future<bool> legacyKeyHealthy() async {
  final key = await _secureStorage.read(key: 'encryption_key');
  if (key == null || key.isEmpty) return false;
  final token = sha256.convert(utf8.encode(key)).toString();
  final saved = await _secureStorage.read(key: 'encryption_key_kc');
  if (saved == null) { await _secureStorage.write(key: 'encryption_key_kc', value: token); return true; }
  return saved == token;
}
```

**Step 4 — Prime the key at single-threaded startup.** In `lib/main.dart` `_performStartupChecks` (~:820–833, after the key-setup enforcement), call `await EncryptionService().primeAesKey();` (add a public `primeAesKey` that just `await _getAesKey()`), so the key is created on the main isolate before any encrypt path or the sweep can race it.

**Why:** Dual-read means the instant users update, their v1 passwords still decrypt; new saves are AES. A separate key preserves the ability to read v1 during migration. The key-health token converts the "Keystore wiped" silent-corruption path into a safe no-op (Task 18 gate).

**How to test:**
- *Static:* `fvm flutter analyze` clean.
- *Unit (`test/encryption_service_test.dart`):* encrypt "hunter2" → result starts with `v2:`; decrypt it → "hunter2"; two encrypts of "hunter2" differ (nonce); feed a known **legacy** XOR base64 (no tag) → decrypts to the original.
- *Manual upgrade test:* on a build that already has saved passwords (v1), install this build → open the password list and a protected PDF → existing passwords still work; add a new password → its stored value now begins `v2:`.

**Done when:** v1 and v2 both decrypt; new writes are v2; `aes_key_v2` exists; `legacyKeyHealthy()` returns true on the same device and false after a data-clear.

**⚠️ Cautions:** Do NOT remove the XOR path or delete `encryption_key`. Keep `decrypt()` returning `null` on failure — never `_encryptionKey!`. Ship this and let it saturate the field **before** enabling any sweep (Task 18).

---

### Task 16 — Feature 5: passphrase Backup/Restore + Auto-Backup exclusion (must precede the sweep)
- **Roadmap:** Phase 2, step 16
- **Type:** Feature + Security · **Effort:** M–L · **Risk if done wrong:** med · **Low-model-safe:** No (senior review)
- **File(s):** new `lib/services/password_backup_service.dart`; `lib/features/password_manager/screens/password_manager_screen.dart` (AppBar actions); `lib/features/password_manager/widgets/add_password_dialog.dart` (reuse its dup-detection); `lib/services/storage_service.dart` (passwords CRUD); `android/app/src/main/AndroidManifest.xml`
- **Goal:** Portable, passphrase-protected export/import of the password vault (survives a wiped Keystore / new device), with a no-secret conflict table on restore.

**Step 1 — New `PasswordBackupService`.**
- *Export:* read all rows (`StorageService.getAllPasswords()`), decrypt each via `EncryptionService.decrypt`, build `{keyName, value}` list, then encrypt the whole JSON under a key derived from a user **passphrase** with **Argon2id** (`cryptography` `Argon2id`, e.g. memory 64 MiB, iterations 3, parallelism 1) over a random 16-byte salt; write a backup file `{ "salt": b64, "params": {...}, "blob": base64(AES-GCM(nonce|ct|tag)) }`. Save via `share_plus`/`path_provider`.
- *Restore:* `file_picker` to load → re-derive key from the re-entered passphrase + stored salt → AES-GCM decrypt → get `{keyName, value}` list.

**Step 2 — Duplicate detection on restore (REUSE existing patterns).** From `add_password_dialog.dart`'s existing checks: key-name collision (`StorageService.passwordKeyExists`) and value-collision (decrypt each local row and compare plaintext). Build a conflict list and show a **no-secret table** — columns **`Backup name | Local name | Status`** (Status ∈ {`new`, `same name`, `same password, different name`}). **Never render the password value.** Offer per-row resolution: Skip / Rename / Keep both.

**Step 3 — Insert/merge.** For accepted entries, `EncryptionService.encrypt(value)` (→ v2) then `StorageService.insertPassword`.

**Step 4 — AppBar buttons** in `password_manager_screen.dart`: "Backup" and "Restore" actions wired to the service.

**Step 5 — Exclude the encrypted store from Android Auto Backup** so users can't restore an undecryptable blob onto a device whose Keystore key is gone. In `AndroidManifest.xml` `<application>` add `android:dataExtractionRules="@xml/data_extraction_rules"` and `android:fullBackupContent="@xml/backup_rules"`, and add `android/app/src/main/res/xml/backup_rules.xml` / `data_extraction_rules.xml` that `<exclude>` the `FlutterSecureStorage` prefs file and `passwordpdf.db`.

**Why:** Once the corpus is AES + device-bound (after the sweep), a new phone = total loss unless there is a portable, passphrase-based escape hatch. This is the ONLY off-device recovery path and **must ship before Task 18**.

**How to test:** Export with passphrase "P@ss" → file created. Wrong passphrase on restore → clean "incorrect passphrase" error, nothing imported. Correct passphrase with one same-named + one identical-value-different-name entry → table shows both with the right Status and no password text; choosing Skip/Rename/Keep-both behaves accordingly. Verify the manifest rules exclude the secure prefs from `adb backup`.

**Done when:** A backup made on device A restores correctly on a fresh install of device B using only the passphrase; the conflict table never shows a password.

**⚠️ Cautions:** Argon2id params must be stored in the backup header (needed to re-derive). Use `Random.secure()`/the library for salt+nonce. Ship before the sweep (Task 18).

---

### Task 17 — Lazy migrate-on-read (legacy-side verify + compare-and-swap)
- **Roadmap:** Phase 2, step 17
- **Type:** Security · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** No (senior review)
- **File(s):** `lib/services/encryption_service.dart` (add `migrateValue`), `lib/services/pdf_password_service.dart` (~:79–84, in-memory map), `lib/features/documents/screens/document_dashboard_screen.dart` (SmartOpen loop ~:1766–1785), `lib/features/password_manager/widgets/add_password_dialog.dart` (pool scan), `lib/services/storage_service.dart` (CAS update)
- **Goal:** When a legacy value is read, upgrade it to v2 — but only after proving the decrypt was correct, and only via a race-safe write.

**Step 1 — `migrateValue` with LEGACY-SIDE proof** (in `EncryptionService`):
```dart
bool isLegacy(String stored) =>
    stored.isNotEmpty && stored != 'NO_PASSWORD' && !stored.startsWith(_tagV2);

/// Returns a v2 value ONLY if the legacy decrypt is provably correct; else null (keep old).
Future<String?> migrateValue(String stored) async {
  if (!isLegacy(stored)) return null;
  if (!await legacyKeyHealthy()) return null;        // rule 3: bad key => never write
  final String plain;
  try { plain = await _decryptXorLegacy(stored); }   // may be garbage on wrong key
  catch (_) { return null; }
  // LEGACY-SIDE round-trip proof (rule 2): XOR is deterministic.
  final reXor = await _encryptXorLegacy(plain);
  if (reXor != stored) return null;                  // decrypt was lossy/garbage => ABORT
  final v2 = await encrypt(plain);
  if (v2 == null) return null;
  return v2;
}
```

**Step 2 — Compare-and-swap write for the SQLite path** (`StorageService`): add `updatePasswordValueCas(int id, String oldVal, String newVal)` doing `UPDATE passwords SET encrypted_value=? WHERE id=? AND encrypted_value=?`; if `rowsAffected == 0`, skip (row changed under us). Call it from the pool-decrypt loop in `add_password_dialog.dart` and the SmartOpen loop after a successful `decrypt`.

**Step 3 — `document_passwords` map: migrate THROUGH the service.** Add `PdfPasswordService.migrateValuesToV2()` that operates on the in-memory `_documentPasswords` map (the single writer), skips `NO_PASSWORD`, uses `migrateValue`, and calls the existing `_save()`. Run it under an in-service write-lock, **after** `migratePasswordPaths` completes. Do NOT touch `_prefs` directly.

**Why:** The legacy-side proof is the only check that catches wrong-key garbage (Task 18 audit C1/C2). CAS + single-writer eliminate the lost-update races (C3/C4).

**How to test:** Unit-test `migrateValue`: correct key → returns `v2:...` that decrypts to the original; simulated wrong key (garbage that base64-decodes) → returns `null` (no write). Manual: open a v1 PDF → its stored association becomes `v2:`; edit a password in the UI while a scan runs → the edit is never reverted.

**Done when:** Reading any v1 value upgrades it to a verified v2 value; no upgrade ever occurs when the key is unhealthy; concurrent edits are never clobbered.

**⚠️ Cautions:** Never write back without the legacy-side proof AND the key-health gate. Never migrate the prefs map by writing `_prefs` directly.

---

### Task 18 — One-time background sweep (key-health-gated, resumable, crash-safe)
- **Roadmap:** Phase 2, step 18
- **Type:** Security · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** No (senior review)
- **File(s):** new `lib/services/migration_service.dart`; invoked from `lib/main.dart` (~:820–833 after startup checks); uses `StorageService.getAllPasswords/updatePasswordValueCas` and `PdfPasswordService.migrateValuesToV2`
- **Goal:** Upgrade values the user never opens, safely and once.

**Step 1 — `runV2Sweep()`** guarded by a `crypto_migrated_v2` flag and the key-health gate:
```dart
Future<void> runV2Sweep() async {
  if (await _settings.getBool('crypto_migrated_v2') == true) return;
  if (!await _enc.legacyKeyHealthy()) return;        // rule 3: never sweep with a bad key
  // Store A: passwords table (CAS write-back)
  for (final row in await _storage.getAllPasswords()) {
    final v2 = await _enc.migrateValue(row.encryptedValue);
    if (v2 != null) await _storage.updatePasswordValueCas(row.id!, row.encryptedValue, v2);
  }
  // Store B: through the service's single writer
  await _pdfPwd.migrateValuesToV2();
  // Only mark done if NOTHING legacy remains (resumable across kills)
  if (await _allMigrated()) await _settings.setBool('crypto_migrated_v2', true);
}
```
Kick off post-startup as a low-priority task. Stage rollout behind a flag (1%→10%→50%→100%).

**Step 2 — Crash-safe prefs write** in `PdfPasswordService._save()`: write to `document_passwords_next`, commit, then swap to `document_passwords` (so a kill mid-commit can't truncate the live map). On `initialize()`, recover from `_next` if the primary is empty/corrupt.

**Step 3 — Stop the silent-zeroing bug.** In `PdfPasswordService.initialize()` change the catch (~:36–39) so a JSON parse failure does **not** set `_documentPasswords = {}` and does **not** `_save()` — preserve the raw string and surface an error instead (audit H3).

**Why:** Lazy migration never reaches unopened values; the sweep finishes the job. The flag-when-fully-drained logic makes it resumable; the crash-safe write + non-zeroing catch prevent a mid-sweep kill from wiping the map.

**How to test:** Seed v1 values, run the sweep, kill the app mid-run → relaunch → it resumes and finishes; afterward all values are `v2:` and the flag is set. Verify a forced parse error no longer empties `document_passwords`.

**Done when:** After a full sweep both stores contain only `v2:`/`NO_PASSWORD`, the flag is set, and an interrupted run resumes without loss.

**⚠️ Cautions:** Sweep must NOT run before Task 16 (passphrase backup) ships. Sweep must be gated on `legacyKeyHealthy()`. Set the completion flag only when fully drained.

---

### Task 19 — Salted PIN hash, dev-gate hash, hide raw key, zip-password
- **Roadmap:** Phase 2, step 19
- **Type:** Security · **Effort:** M · **Risk if done wrong:** high (PIN) · **Low-model-safe:** No (senior review)
- **File(s):** `lib/features/settings/services/settings_service.dart` (~:206–268), `lib/services/encryption_service.dart` (~:20, :57, :74), `lib/features/settings/screens/settings_screen.dart` (~:190), `lib/features/developer/screens/developer_screen.dart` (~:36–65, :41), `lib/services/export_queue_service.dart` (~:76, :91)
- **Goal:** Stop storing/showing secrets in plaintext: hash the PIN and dev password, never display the raw key, never persist the zip password.

**Step 1 — PIN: lazy rehash on next successful verify (verify-before-discard).** In `settings_service.dart`, change `verifyPin`:
```dart
Future<bool> verifyPin(String pin) async {
  final stored = await _secureStorage.read(key: 'app_pin');
  if (stored == null) return false;
  if (stored.startsWith('pin:v2:')) {
    final parts = stored.substring('pin:v2:'.length).split('\$'); // [saltB64, hashB64], '\$' not in base64
    final actual = await _pbkdf2(pin, base64Decode(parts[0]));
    return _constantTimeEq(actual, base64Decode(parts[1]));
  }
  // Legacy plaintext: compare, and on success rehash (we have the correct PIN in hand).
  if (stored == pin) {
    final salt = List<int>.generate(16, (_) => _rng.nextInt(256));
    final hash = await _pbkdf2(pin, salt);
    final v2 = 'pin:v2:${base64Encode(salt)}\$${base64Encode(hash)}';
    // VERIFY before discarding the only copy:
    await _secureStorage.write(key: 'app_pin', value: v2);
    if (!await verifyPin(pin)) { await _secureStorage.write(key: 'app_pin', value: pin); } // rollback
    return true;
  }
  return false;
}
```
Add `_pbkdf2` (PBKDF2-HMAC-SHA256, 100k iters, 256-bit) and `_constantTimeEq`. Make `setPin`/`changePin` write the `pin:v2:` form directly.

**Step 2 — Dev gate.** Replace the hardcoded `static const String _developerPassword = 'Portal123!';` (~:20) with a baked salted hash and a constant-time check:
```dart
static const String _devSalt = '<build-baked-random>';
static const String _devHash = '<sha256(_devSalt + password) hex, baked>';
bool verifyDeveloperPassword(String input) =>
    _constantTimeEq(utf8.encode(sha256.convert(utf8.encode(_devSalt + input)).toString()), utf8.encode(_devHash));
```
Then point the two inline `== 'Portal123!'` compares at `verifyDeveloperPassword`:
- `lib/features/settings/screens/settings_screen.dart` (≈ line 190): replace `      if (controller.text == 'Portal123!') {` with `      if (EncryptionService().verifyDeveloperPassword(controller.text)) {` (add `import '../../../services/encryption_service.dart';` if not already imported).
- `lib/features/developer/screens/developer_screen.dart` (≈ line 41): the `getEncryptionKey('Portal123!')` call is removed entirely by Step 3 below.
Better still: gate the whole developer screen behind `--dart-define=DEV_TOOLS=true` and compile it out of release.

**Step 3 — Hide the raw key.** In `developer_screen.dart` `_manageEncryptionKey` (~:36–65) remove the `getEncryptionKey(...)` call and the `SelectableText` that renders the key; show a non-reversible status ("Key configured ✓") and, at most, the passphrase **export** (Task 16). Downgrade `EncryptionService.getEncryptionKey` to return a boolean "is set".

**Step 4 — zip password.** In `export_queue_service.dart` stop serializing `zip_password` as plaintext (~:76): keep it in memory on the in-flight job; if the queue must survive restart, `encrypt()` it (v2) before persisting and decrypt at consume (~:91/:502); `UPDATE export_jobs SET zip_password=NULL` once `_encodeArchive` completes.

**Why:** A plaintext PIN/dev-password/key/zip-password defeats every cipher the moment storage is dumped. Lazy-rehash with verify-before-discard means a user can never be locked out by a bad hash.

**How to test:** Set a PIN (legacy build) → upgrade → first correct unlock rehashes to `pin:v2:`; wrong PIN still rejected; killing right after the rehash write still unlocks (verify-before-discard / rollback). Dev tools no longer show the key. An exported encrypted ZIP still opens with its password; the `export_jobs` row's `zip_password` is null after completion.

**Done when:** `app_pin` is `pin:v2:`, dev password is hashed (or compiled out), the raw key is never shown, and no completed export retains a usable password.

**⚠️ Cautions:** Never eager-overwrite the only PIN copy without the verify-and-rollback. Use `Random.secure()` for the salt. The `pin:v2:` tag is a **different** namespace from the ciphertext `v2:` — keep them distinct (audit H1).

---

# PHASE 3 — Remaining security hardening
### Task 20 — Force biometricOnly authentication

- **Roadmap:** Phase (security), step 20 (from fix-order.md)
- **Type:** Security · **Effort:** S · **Risk if done wrong:** med · **Low-model-safe:** Yes
- **File(s):** `lib/services/biometric_service.dart` (~lines 58–66 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Require a real biometric (no device-PIN/pattern fallback) when the app authenticates, by setting `biometricOnly: true`.

**Step 1 — Locate.** In `lib/services/biometric_service.dart`, find this EXACT block (copy-paste anchor; included context makes it unique):
```dart
      final authenticated = await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          sensitiveTransaction: false, // CRITICAL: Allows Face Unlock (Weak/Class 2) on Android
          useErrorDialogs: true,
        ),
      );
```

**Step 2 — Change.** Replace it with:
```dart
      final authenticated = await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
          sensitiveTransaction: false, // CRITICAL: Allows Face Unlock (Weak/Class 2) on Android
          useErrorDialogs: true,
        ),
      );
```

**Why:** With `biometricOnly: false`, `local_auth` lets the OS fall back to the device PIN/pattern/password, which defeats the purpose of a biometric gate. Setting it to `true` requires an enrolled biometric.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `lib/services/biometric_service.dart`.
- *Manual:*
  1. On a device with a fingerprint/face enrolled, enable biometric lock in Settings, send app to background past the auto-lock timeout, reopen → expect the system biometric prompt with NO "Use PIN/Pattern" fallback button.
  2. On a device with NO biometric enrolled, attempt to enable biometric lock → expect authentication to fail/return `false` (it no longer silently falls back to device credential).

**Done when:** The biometric prompt offers only biometric verification (no device-credential fallback button) and `authenticate` returns `false` when no biometric is enrolled.

**⚠️ Cautions:** Confirm the Settings biometric-enable flow still gracefully handles the "no biometric enrolled" case (it should already, via `isDeviceSupported`); do not also change `sensitiveTransaction` — Face Unlock support depends on it staying `false`.

---

### Task 21 — Robust auto-lock timing + scoped picker exemption

- **Roadmap:** Phase (security), step 21 (from fix-order.md)
- **Type:** Security · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** With-care (behavioral)
- **File(s):** `lib/main.dart` (~lines 276–279, 642–694, 1071–1072 as of writing — VERIFY before editing; line numbers shift after earlier edits) and `lib/features/settings/screens/settings_screen.dart` (~line 504)
- **Goal:** Compare elapsed background time in seconds against `timeout*60` (so sub-minute timeouts work and rounding can't skip a lock) and replace the unbounded global `ignoreNextPause` one-shot with a short, time-boxed exemption so a backgrounded file picker can't permanently suppress auto-lock.

**Step 1 — Locate.** In `lib/main.dart`, find this EXACT block (the static field declarations):
```dart
  // Flag to ignore valid user interactions that pause the app (e.g. File Picker)
  static bool ignoreNextPause = false;

  // Track when the app went into background (Static to allow forcing timeout from other screens)
  static DateTime? backgroundTime;
```

**Step 2 — Change.** Replace it with:
```dart
  // Timestamp until which a single backgrounding is exempt from auto-lock
  // (e.g. the OS file/directory picker briefly pauses the app). Expires fast
  // so it can never permanently suppress the lock screen.
  static DateTime? pauseExemptUntil;

  // Duration of the picker exemption window.
  static const Duration pauseExemptionWindow = Duration(seconds: 30);

  /// Mark the next backgrounding (within [pauseExemptionWindow]) as exempt
  /// from auto-lock timeout tracking. Call immediately before launching a
  /// system picker / share sheet.
  static void exemptNextPause() {
    pauseExemptUntil = DateTime.now().add(pauseExemptionWindow);
  }

  // Track when the app went into background (Static to allow forcing timeout from other screens)
  static DateTime? backgroundTime;
```

**Step 3 — Locate.** In `lib/main.dart`, find this EXACT block inside `didChangeAppLifecycleState`:
```dart
    if (state == AppLifecycleState.paused) {
      if (AppEntry.ignoreNextPause) {
         _log.info('AppEntry', 'App paused but ignoreNextPause is true - Skipping timeout tracking');
         AppEntry.ignoreNextPause = false; // Reset flag
         return;
      }
      
      AppEntry.backgroundTime = DateTime.now();
      _log.info('AppEntry', 'App paused - tracking background time: ${AppEntry.backgroundTime}');
    }
```

**Step 4 — Change.** Replace it with:
```dart
    if (state == AppLifecycleState.paused) {
      final exemptUntil = AppEntry.pauseExemptUntil;
      if (exemptUntil != null && DateTime.now().isBefore(exemptUntil)) {
         _log.info('AppEntry', 'App paused but within picker exemption window - Skipping timeout tracking');
         AppEntry.pauseExemptUntil = null; // One-shot: consume the exemption
         return;
      }
      AppEntry.pauseExemptUntil = null; // Expired/unused exemption never lingers

      AppEntry.backgroundTime = DateTime.now();
      _log.info('AppEntry', 'App paused - tracking background time: ${AppEntry.backgroundTime}');
    }
```

**Step 5 — Locate.** In `lib/main.dart`, find this EXACT block inside the `resumed` branch:
```dart
       if (AppEntry.backgroundTime != null) {
         final diff = DateTime.now().difference(AppEntry.backgroundTime!);
         _log.info('AppEntry', 'Background duration: ${diff.inMinutes} minutes');
         
         // Auto-lock only after user-configured timeout (default 10m)
         final settings = Provider.of<SettingsService>(context, listen: false);
         final timeoutMinutes = settings.autoLockTimeout;
         
         if (diff.inMinutes >= timeoutMinutes) {
```

**Step 6 — Change.** Replace it with:
```dart
       if (AppEntry.backgroundTime != null) {
         final diff = DateTime.now().difference(AppEntry.backgroundTime!);
         _log.info('AppEntry', 'Background duration: ${diff.inSeconds} seconds');
         
         // Auto-lock only after user-configured timeout (default 10m).
         // Compare in seconds against timeout*60 so sub-minute timeouts work
         // and integer-minute truncation can never skip the lock.
         final settings = Provider.of<SettingsService>(context, listen: false);
         final timeoutMinutes = settings.autoLockTimeout;
         
         if (diff.inSeconds >= timeoutMinutes * 60) {
```

**Step 7 — Locate.** In `lib/main.dart`, find this EXACT block (the "Timeout not reached" log line):
```dart
         } else {
            _log.info('AppEntry', 'Timeout not reached (<10m) - access granted');
         }
```

**Step 8 — Change.** Replace it with:
```dart
         } else {
            _log.info('AppEntry', 'Timeout not reached (<$timeoutMinutes m) - access granted');
         }
```

**Step 9 — Locate.** In `lib/main.dart`, find this EXACT block (the Exit-App handler):
```dart
          if (shouldExit == true) {
            AppEntry.backgroundTime = DateTime(2000);
            AppEntry.ignoreNextPause = true;
            SystemNavigator.pop();
          }
```

**Step 10 — Change.** Replace it with:
```dart
          if (shouldExit == true) {
            AppEntry.backgroundTime = DateTime(2000);
            AppEntry.exemptNextPause();
            SystemNavigator.pop();
          }
```

**Step 11 — Locate.** In `lib/features/settings/screens/settings_screen.dart`, find this EXACT line:
```dart
                    AppEntry.ignoreNextPause = true; // Prevent auto-lock
```

**Step 12 — Change.** Replace it with:
```dart
                    AppEntry.exemptNextPause(); // Prevent auto-lock during picker (time-boxed)
```

**Why:** The old `inMinutes >= timeoutMinutes` truncates seconds, so a 0/sub-minute timeout never fires and a backgrounding of e.g. 9m59s rounds to 9; comparing `inSeconds >= timeoutMinutes * 60` is exact. The global boolean `ignoreNextPause` could be set and then never consumed (e.g. user cancels the picker without re-pausing), leaving auto-lock silently disabled forever; a time-boxed, one-shot timestamp self-expires.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `lib/main.dart` and `lib/features/settings/screens/settings_screen.dart`. There must be ZERO remaining references to `ignoreNextPause` (grep the repo).
- *Manual:*
  1. Enable PIN or biometric lock, set auto-lock timeout to the lowest value, background the app past the timeout, reopen → expect the lock screen overlay.
  2. In Settings → Download Location, tap to open the directory picker, then immediately cancel/return → expect NO lock screen (exemption applied), AND if you then background the app normally and wait past the timeout → expect the lock screen (exemption did not persist).
- *Unit/widget test (if feasible):* In `test/auto_lock_exemption_test.dart`, after `AppEntry.exemptNextPause()` assert `AppEntry.pauseExemptUntil!.isAfter(DateTime.now())`, then assert it is at most `AppEntry.pauseExemptionWindow` ahead.

**Done when:** Auto-lock fires for any backgrounding `>= timeout*60` seconds; the only way to suppress it is a picker exemption that expires within `pauseExemptionWindow` and is consumed after one pause; no `ignoreNextPause` symbol remains anywhere in `lib/`.

**⚠️ Cautions:** Steps 1–12 are one atomic change — `exemptNextPause()` and the removal of `ignoreNextPause` must land together or the build breaks (the two call sites reference the old symbol). Do not batch this task with Task 20. Re-verify line numbers in `settings_screen.dart` since it is a separate file.

---

### Task 23 — Whitelist table/idColumn in generic DB operations

- **Roadmap:** Phase (security), step 23 (from fix-order.md)
- **Type:** Security · **Effort:** M · **Risk if done wrong:** med · **Low-model-safe:** Yes
- **File(s):** `lib/services/storage_service.dart` (~lines 499–528 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Prevent SQL identifier injection by validating the `table` and `idColumn` arguments of `getTableData`, `updateRecord`, and `deleteRecord` against a fixed allow-list before they are interpolated into queries.

**Step 1 — Locate.** In `lib/services/storage_service.dart`, find this EXACT block (the three generic operations plus the `getTables` method just above them):
```dart
  /// Get all table names
  Future<List<String>> getTables() async {
    final db = await database;
    final tables = await db.query('sqlite_master', where: 'type = ?', whereArgs: ['table']);
    return tables
        .map((t) => t['name'] as String)
        .where((t) => t != 'android_metadata' && t != 'sqlite_sequence')
        .toList();
  }

  /// Get generic table data
  /// Get generic table data with pagination
  Future<List<Map<String, dynamic>>> getTableData(String table, {int? limit, int? offset}) async {
    final db = await database;
    return await db.query(table, limit: limit, offset: offset);
  }

  /// Update generic record
  Future<int> updateRecord(String table, String idColumn, dynamic idValue, Map<String, dynamic> data) async {
    final db = await database;
    return await db.update(table, data, where: '$idColumn = ?', whereArgs: [idValue]);
  }

  /// Delete generic record
  Future<int> deleteRecord(String table, String idColumn, dynamic idValue) async {
    final db = await database;
    return await db.delete(table, where: '$idColumn = ?', whereArgs: [idValue]);
  }
```

**Step 2 — Change.** Replace it with:
```dart
  /// Get all table names
  Future<List<String>> getTables() async {
    final db = await database;
    final tables = await db.query('sqlite_master', where: 'type = ?', whereArgs: ['table']);
    return tables
        .map((t) => t['name'] as String)
        .where((t) => t != 'android_metadata' && t != 'sqlite_sequence')
        .toList();
  }

  /// Tables that may be addressed through the generic operations below.
  static const Set<String> _allowedTables = {
    AppConstants.passwordsTable,
    AppConstants.recentDocumentsTable,
    AppConstants.settingsTable,
    AppConstants.exportJobsTable,
    AppConstants.logsTable,
    AppConstants.filesIndexTable,
  };

  // A SQL identifier we are willing to interpolate: letters, digits, underscore only.
  static final RegExp _safeIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Validate a table name against the whitelist. Throws on anything unexpected.
  static String _safeTable(String table) {
    if (!_allowedTables.contains(table)) {
      throw ArgumentError('Disallowed table name: $table');
    }
    return table;
  }

  /// Validate an id column name (identifier-shaped only). Throws otherwise.
  static String _safeColumn(String column) {
    if (!_safeIdentifier.hasMatch(column)) {
      throw ArgumentError('Disallowed column name: $column');
    }
    return column;
  }

  /// Get generic table data
  /// Get generic table data with pagination
  Future<List<Map<String, dynamic>>> getTableData(String table, {int? limit, int? offset}) async {
    final safeTable = _safeTable(table);
    final db = await database;
    return await db.query(safeTable, limit: limit, offset: offset);
  }

  /// Update generic record
  Future<int> updateRecord(String table, String idColumn, dynamic idValue, Map<String, dynamic> data) async {
    final safeTable = _safeTable(table);
    final safeColumn = _safeColumn(idColumn);
    final db = await database;
    return await db.update(safeTable, data, where: '$safeColumn = ?', whereArgs: [idValue]);
  }

  /// Delete generic record
  Future<int> deleteRecord(String table, String idColumn, dynamic idValue) async {
    final safeTable = _safeTable(table);
    final safeColumn = _safeColumn(idColumn);
    final db = await database;
    return await db.delete(safeTable, where: '$safeColumn = ?', whereArgs: [idValue]);
  }
```

**Why:** `table` and `idColumn` are interpolated directly into SQL (the table name and the `where: '$idColumn = ?'` clause), so a caller-supplied identifier is an injection vector; only `idValue` is parameterized. The allow-list (tables) and identifier regex (columns) reject anything not anticipated. `AppConstants` is already imported at the top of this file (`import '../core/constants/app_constants.dart';`), so no new import is needed.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `lib/services/storage_service.dart`.
- *Unit test (if feasible):* In `test/storage_generic_ops_test.dart`, assert `expect(() => StorageService().getTableData('passwords; DROP TABLE passwords'), throwsArgumentError);` and assert `getTableData(AppConstants.logsTable)` does NOT throw.
- *Manual:*
  1. Open the Developer screen → DB browser, select each table in the dropdown → expect rows to load exactly as before (all six real tables work).
  2. Edit/delete a record from the Developer DB browser → expect the operation to succeed for the legitimate `id` column.

**Done when:** All six real tables load and edit/delete in the Developer DB browser, and passing an unknown table name or a non-identifier column string throws `ArgumentError` instead of executing.

**⚠️ Cautions:** If the Developer screen ever calls these with an `idColumn` other than a plain column name (e.g. a quoted identifier), that path will now throw — verify the Developer DB browser still functions before considering this done.

---

### Task 24 — Redact secrets/PII from log messages

- **Roadmap:** Phase (security), step 24 (from fix-order.md)
- **Type:** Security · **Effort:** M · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/services/logging_service.dart` (~lines 58–82 as of writing) and `lib/features/settings/services/settings_service.dart` (~lines 206–239 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Add a defense-in-depth redactor in `LoggingService` so PIN/secret/password-shaped substrings are masked before any log is stored or printed, and make the PIN log call sites explicit about never passing raw secrets.

**Step 1 — Locate.** In `lib/services/logging_service.dart`, find this EXACT block (the `_addLog` method):
```dart
  void _addLog(String level, String tag, String message, [String? stackTrace]) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      stackTrace: stackTrace,
    );
    
    _logs.insert(0, entry); // Add at beginning for newest first
    
    // Keep max logs limit (memory)
    if (_logs.length > _maxLogsInMem) {
      _logs.removeLast();
    }
    
    // Also print to debug console
    debugPrint('[$level] $tag: $message');
    if (stackTrace != null) {
      debugPrint(stackTrace);
    }
    
    // Persist async
    _storage.insertLog(entry.toMap(), retentionLimit: _maxLogLimit);
  }
```

**Step 2 — Change.** Replace it with:
```dart
  /// Mask secret/PII-shaped substrings before a message is stored or printed.
  /// Defense-in-depth: call sites should already avoid logging raw secrets,
  /// but this guarantees nothing sensitive lands in the persisted log table.
  static String _redact(String input) {
    var out = input;
    // key: value / key= value where key looks sensitive (pin, password, secret, token, otp)
    out = out.replaceAllMapped(
      RegExp(r'(?i)\b(pin|password|passwd|pwd|secret|token|otp|api[_-]?key)\b\s*[:=]\s*\S+'),
      (m) => '${m.group(1)}: [REDACTED]',
    );
    return out;
  }

  void _addLog(String level, String tag, String message, [String? stackTrace]) {
    final safeMessage = _redact(message);
    final safeStack = stackTrace != null ? _redact(stackTrace) : null;
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: safeMessage,
      stackTrace: safeStack,
    );
    
    _logs.insert(0, entry); // Add at beginning for newest first
    
    // Keep max logs limit (memory)
    if (_logs.length > _maxLogsInMem) {
      _logs.removeLast();
    }
    
    // Also print to debug console
    debugPrint('[$level] $tag: $safeMessage');
    if (safeStack != null) {
      debugPrint(safeStack);
    }
    
    // Persist async
    _storage.insertLog(entry.toMap(), retentionLimit: _maxLogLimit);
  }
```

**Step 3 — Locate.** In `lib/features/settings/services/settings_service.dart`, find this EXACT block (`setPin`):
```dart
  /// Set PIN
  Future<bool> setPin(String pin) async {
    try {
      _log.info('SettingsService', 'Setting new PIN...');
      await _secureStorage.write(key: 'app_pin', value: pin);
```

**Step 4 — Change.** Replace it with:
```dart
  /// Set PIN
  Future<bool> setPin(String pin) async {
    try {
      // NOTE: never log `pin` (raw secret). Log only the action.
      _log.info('SettingsService', 'Setting new PIN...');
      await _secureStorage.write(key: 'app_pin', value: pin);
```

**Step 5 — Locate.** In `lib/features/settings/services/settings_service.dart`, find this EXACT block (`verifyPin`):
```dart
  /// Verify PIN
  Future<bool> verifyPin(String pin) async {
    try {
      final storedPin = await _secureStorage.read(key: 'app_pin');
      final match = storedPin == pin;
      _log.info('SettingsService', 'PIN verification: ${match ? 'success' : 'failed'}');
      return match;
```

**Step 6 — Change.** Replace it with:
```dart
  /// Verify PIN
  Future<bool> verifyPin(String pin) async {
    try {
      final storedPin = await _secureStorage.read(key: 'app_pin');
      final match = storedPin == pin;
      // NOTE: never log `pin` or `storedPin` (raw secrets). Log only the outcome.
      _log.info('SettingsService', 'PIN verification: ${match ? 'success' : 'failed'}');
      return match;
```

**Why:** The persisted SQLite `logs` table is readable from the Developer screen and any device backup, so a secret accidentally logged there leaks; the `_redact` pass masks `pin/password/secret/token/otp`-shaped values regardless of which call site emits them. The comments at the PIN sites stop a future edit from interpolating the raw `pin` into the message.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for both files.
- *Unit test (if feasible):* In `test/log_redaction_test.dart`: call `LoggingService().info('T', 'pin: 1234')`, then read `LoggingService().logs.first.message` and assert it equals `'pin: [REDACTED]'` and does NOT contain `1234`.
- *Manual:*
  1. Set/verify a PIN, then open Developer screen → logs → search the log list for the PIN digits → expect ZERO matches and entries reading "Setting new PIN..." / "PIN verification: success".

**Done when:** A message containing `pin: <value>` (or password/secret/token/otp) is stored with the value replaced by `[REDACTED]`, and existing PIN log lines still appear with their action/outcome text intact.

**⚠️ Cautions:** The regex only catches `key: value` / `key=value` shapes — it is a safety net, not a license to log secrets; keep call sites secret-free. Do not lower the redaction (e.g. remove the `(?i)` flag) without senior review.

---

### Task 25 — Scope storage permissions / drop MANAGE_EXTERNAL_STORAGE

- **Roadmap:** Phase (security), step 25 (from fix-order.md)
- **Type:** Security · **Effort:** M · **Risk if done wrong:** high · **Low-model-safe:** With-care (behavioral)
- **File(s):** `lib/services/permission_service.dart` (~lines 14–100 as of writing — VERIFY before editing; line numbers shift after earlier edits)
- **Goal:** Stop requesting the all-files `MANAGE_EXTERNAL_STORAGE` permission and use scoped, version-appropriate media/storage permissions instead (Android 13+ `READ_MEDIA_*`, legacy `READ_EXTERNAL_STORAGE`), so the app stays within Google Play policy.

**Step 1 — Locate.** In `lib/services/permission_service.dart`, find this EXACT block (the Android branch of `requestAllPermissions`):
```dart
    if (Platform.isAndroid) {
      permissions.addAll([
        Permission.storage,
        Permission.manageExternalStorage,
        Permission.notification,
      ]);
    } else if (Platform.isIOS) {
```

**Step 2 — Change.** Replace it with:
```dart
    if (Platform.isAndroid) {
      // Scoped permissions only. On Android 13+ (API 33) READ_EXTERNAL_STORAGE
      // is ignored and the granular READ_MEDIA_* permissions apply instead;
      // requesting all of them is safe (the OS grants only what's relevant).
      // We intentionally DO NOT request MANAGE_EXTERNAL_STORAGE (all-files
      // access) — it triggers a Google Play sensitive-permission policy review
      // and is unnecessary for this app's use of the file picker / scoped dirs.
      permissions.addAll([
        Permission.storage,        // legacy READ/WRITE_EXTERNAL_STORAGE (<= API 32)
        Permission.photos,         // READ_MEDIA_IMAGES (API 33+)
        Permission.notification,
      ]);
    } else if (Platform.isIOS) {
```

**Step 3 — Locate.** In `lib/services/permission_service.dart`, find this EXACT block (the Android check in `areAllPermissionsGranted`):
```dart
    final storage = await Permission.storage.isGranted;
    _log.debug(_tag, 'Storage permission: $storage');
    
    // For Android 11+, check manage external storage
    final manageStorage = await Permission.manageExternalStorage.isGranted;
    _log.debug(_tag, 'Manage external storage permission: $manageStorage');
    
    return storage || manageStorage;
```

**Step 4 — Change.** Replace it with:
```dart
    final storage = await Permission.storage.isGranted;
    _log.debug(_tag, 'Storage permission (legacy): $storage');
    
    // Android 13+ uses granular media permissions instead of storage.
    final media = await Permission.photos.isGranted;
    _log.debug(_tag, 'Media (photos) permission: $media');
    
    return storage || media;
```

**Step 5 — Locate.** In `lib/services/permission_service.dart`, find this EXACT block (inside `getPermissionStatus`):
```dart
    status['storage'] = (await Permission.storage.status).toString();
    status['manageExternalStorage'] = (await Permission.manageExternalStorage.status).toString();
    
    _log.info(_tag, 'Permission status: $status');
```

**Step 6 — Change.** Replace it with:
```dart
    status['storage'] = (await Permission.storage.status).toString();
    status['photos'] = (await Permission.photos.status).toString();
    
    _log.info(_tag, 'Permission status: $status');
```

**Why:** `MANAGE_EXTERNAL_STORAGE` (all-files access) is a Google Play sensitive permission that requires a special declaration/review and is disallowed unless the app's core function is file management; scoped permissions (`READ_EXTERNAL_STORAGE` pre-33, `READ_MEDIA_*` on 33+) cover the picker-based workflow and keep the app policy-compliant. There must be NO remaining reference to `manageExternalStorage` in Dart after this change.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean for `lib/services/permission_service.dart`. Grep `lib/` for `manageExternalStorage` → expect ZERO matches.
- *Manual:*
  1. Fresh-install on an Android 13+ device → on first launch expect the media/notification permission prompts, and expect NO "Allow access to manage all files" full-screen settings page.
  2. Open a PDF via the in-app file picker and save/export to the chosen download location → expect it to still work (file picker grants per-file access regardless of these permissions).
  3. On an Android 12 (or lower) device → expect the legacy storage prompt and the same picker/export flow to work.

**Done when:** The app no longer requests all-files access, fresh installs on Android 13+ only see scoped media + notification prompts, and the open/save/export flows still function on both Android 12 and 13+.

**⚠️ Cautions:** This is behavioral and policy-sensitive — also remove the matching `<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>` from `android/app/src/main/AndroidManifest.xml` (out of scope for these Dart cards but REQUIRED for the policy fix to take effect) and have a senior reviewer confirm no feature relies on browsing arbitrary directories outside the picker before shipping. Do not batch with Task 21 even though both touch picker-adjacent behavior. `Permission.photos` maps to `READ_MEDIA_IMAGES`; if the app must also open audio/video, add `Permission.audios`/`Permission.videos` accordingly.

---

# PHASE 4 — PDF-tools fidelity & Feature 2
### Task 26 — PDF-tools fidelity: real page import + guaranteed disposal + true isProtected fallback
- **Roadmap:** Phase (PDF tools), step 26 (from fix-order.md)
- **Type:** Correctness/Data-loss · **Effort:** L · **Risk if done wrong:** high · **Low-model-safe:** With-care
- **File(s):** `lib/services/pdf_tools_service.dart` (~lines 9–217 for the five ops; ~261–325 for `isProtected`. VERIFY before editing — line numbers shift after earlier edits.)
- **Goal:** Replace the `createTemplate()` + `drawPdfTemplate()` visual-flatten copy in `removePassword`, `addPassword`, `reorderPages`, `splitPdf`, and `mergePdf` with real page import (`importPageRange`), wrap every operation in `try/finally` so every `PdfDocument` is disposed even on error, and make `isProtected` fall through to a genuine Syncfusion check.

**Why:** `createTemplate()`/`drawPdfTemplate()` rasterizes each page onto a blank page, destroying selectable text, hyperlinks, form fields, and bookmarks, and bloating file size. `importPageRange` copies the real page objects. The current code also leaks native `PdfDocument` handles when `save()` throws (dispose is only called on the success path).

---

**Step 1 — Locate (removePassword).** In `lib/services/pdf_tools_service.dart`, find this EXACT block:
```dart
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    
    final newDocument = PdfDocument();
    
    for (int i = 0; i < document.pages.count; i++) {
      final srcPage = document.pages[i];
      final template = srcPage.createTemplate();
      // Create section with matching page size
      final section = newDocument.sections!.add();
      section.pageSettings.size = srcPage.size;
      section.pageSettings.margins.all = 0;
      final page = section.pages.add();
      page.graphics.drawPdfTemplate(template, const Offset(0, 0));
    }
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      newPath = path.join(dir, '${filename}_unlocked$ext');
    }
    
    final newBytes = await newDocument.save();
    document.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }
```

**Step 2 — Change.** Replace it with:
```dart
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    final newDocument = PdfDocument();
    try {
      // Real page import preserves text/links/form fields (no visual flatten)
      newDocument.importPageRange(document, 0, document.pages.count - 1);

      String newPath;
      if (savePath != null) {
        newPath = savePath;
      } else {
        final dir = outputDir ?? path.dirname(filePath);
        final filename = path.basenameWithoutExtension(filePath);
        final ext = path.extension(filePath);
        newPath = path.join(dir, '${filename}_unlocked$ext');
      }

      final newBytes = await newDocument.save();
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      document.dispose();
      newDocument.dispose();
    }
  }
```

---

**Step 3 — Locate (addPassword).** Find this EXACT block:
```dart
    final bytes = await file.readAsBytes();
    // Load without password (it's unprotected)
    final document = PdfDocument(inputBytes: bytes);
    
    // Set security
    document.security.userPassword = password;
    document.security.ownerPassword = password;
    // Default security is usually sufficient (RC4 or AES depending on version)
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      newPath = path.join(dir, '${filename}_protected$ext');
    }
    
    final newBytes = await document.save();
    document.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }
```

**Step 4 — Change.** Replace it with:
```dart
    final bytes = await file.readAsBytes();
    // Load without password (it's unprotected)
    final document = PdfDocument(inputBytes: bytes);
    try {
      // Set security
      document.security.userPassword = password;
      document.security.ownerPassword = password;
      // Default security is usually sufficient (RC4 or AES depending on version)

      String newPath;
      if (savePath != null) {
        newPath = savePath;
      } else {
        final dir = outputDir ?? path.dirname(filePath);
        final filename = path.basenameWithoutExtension(filePath);
        final ext = path.extension(filePath);
        newPath = path.join(dir, '${filename}_protected$ext');
      }

      final newBytes = await document.save();
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      document.dispose();
    }
  }
```

---

**Step 5 — Locate (reorderPages).** Find this EXACT block:
```dart
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    
    final newDocument = PdfDocument();

    for (final index in pageOrder) {
      if (index >= 0 && index < document.pages.count) {
        final srcPage = document.pages[index];
        final template = srcPage.createTemplate();
        // Create section with matching page size
        final section = newDocument.sections!.add();
        section.pageSettings.size = srcPage.size;
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();
        page.graphics.drawPdfTemplate(template, const Offset(0, 0));
      }
    }
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      newPath = path.join(dir, '${filename}_reordered$ext');
    }
    
    final newBytes = await newDocument.save();
    document.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }
```

**Step 6 — Change.** Replace it with:
```dart
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    final newDocument = PdfDocument();
    try {
      for (final index in pageOrder) {
        if (index >= 0 && index < document.pages.count) {
          // Import one real page at a time, in the requested order
          newDocument.importPageRange(document, index, index);
        }
      }

      String newPath;
      if (savePath != null) {
        newPath = savePath;
      } else {
        final dir = outputDir ?? path.dirname(filePath);
        final filename = path.basenameWithoutExtension(filePath);
        final ext = path.extension(filePath);
        newPath = path.join(dir, '${filename}_reordered$ext');
      }

      final newBytes = await newDocument.save();
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      document.dispose();
      newDocument.dispose();
    }
  }
```

---

**Step 7 — Locate (splitPdf).** Find this EXACT block:
```dart
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    
    final newDocument = PdfDocument();
    
    for (final index in pageIndices) {
      if (index >= 0 && index < document.pages.count) {
        final srcPage = document.pages[index];
        final template = srcPage.createTemplate();
        // Create section with matching page size
        final section = newDocument.sections!.add();
        section.pageSettings.size = srcPage.size;
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();
        page.graphics.drawPdfTemplate(template, const Offset(0, 0));
      }
    }
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(filePath);
      final filename = path.basenameWithoutExtension(filePath);
      final ext = path.extension(filePath);
      final suffix = pageIndices.length > 2 ? '${pageIndices.first+1}-${pageIndices.last+1}' : 'split';
      newPath = path.join(dir, '${filename}_split_$suffix$ext');
    }
    
    final newBytes = await newDocument.save();
    document.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }
```

**Step 8 — Change.** Replace it with:
```dart
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes, password: password);
    final newDocument = PdfDocument();
    try {
      for (final index in pageIndices) {
        if (index >= 0 && index < document.pages.count) {
          // Import the real page (preserves text/links), not a flattened template
          newDocument.importPageRange(document, index, index);
        }
      }

      String newPath;
      if (savePath != null) {
        newPath = savePath;
      } else {
        final dir = outputDir ?? path.dirname(filePath);
        final filename = path.basenameWithoutExtension(filePath);
        final ext = path.extension(filePath);
        final suffix = pageIndices.length > 2 ? '${pageIndices.first+1}-${pageIndices.last+1}' : 'split';
        newPath = path.join(dir, '${filename}_split_$suffix$ext');
      }

      final newBytes = await newDocument.save();
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      document.dispose();
      newDocument.dispose();
    }
  }
```

---

**Step 9 — Locate (mergePdf).** Find this EXACT block:
```dart
    // We create a new document to hold the result
    final newDocument = PdfDocument();
    
    // Helper to copy pages from a doc preserving size
    void copyPages(PdfDocument src) {
      for (int i = 0; i < src.pages.count; i++) {
        final srcPage = src.pages[i];
        final template = srcPage.createTemplate();
        // Create section with matching page size
        final section = newDocument.sections!.add();
        section.pageSettings.size = srcPage.size;
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();
        page.graphics.drawPdfTemplate(template, const Offset(0, 0));
      }
    }

    // Load source
    final sourceFile = File(sourcePath);
    final sourceBytes = await sourceFile.readAsBytes();
    final sourceDoc = PdfDocument(inputBytes: sourceBytes, password: sourcePassword);
    copyPages(sourceDoc);
    
    // Load other
    final otherFile = File(otherPath);
    final otherBytes = await otherFile.readAsBytes();
    final otherDoc = PdfDocument(inputBytes: otherBytes, password: otherPassword);
    copyPages(otherDoc);
    
    String newPath;
    if (savePath != null) {
      newPath = savePath;
    } else {
      final dir = outputDir ?? path.dirname(sourcePath);
      final filename = path.basenameWithoutExtension(sourcePath);
      final ext = path.extension(sourcePath);
      newPath = path.join(dir, '${filename}_merged$ext');
    }
    
    final newBytes = await newDocument.save();
    sourceDoc.dispose();
    otherDoc.dispose();
    newDocument.dispose();
    
    await File(newPath).writeAsBytes(newBytes);
    return newPath;
  }
```

**Step 10 — Change.** Replace it with:
```dart
    // We create a new document to hold the result
    final newDocument = PdfDocument();

    // Load source
    final sourceFile = File(sourcePath);
    final sourceBytes = await sourceFile.readAsBytes();
    final sourceDoc = PdfDocument(inputBytes: sourceBytes, password: sourcePassword);

    // Load other
    final otherFile = File(otherPath);
    final otherBytes = await otherFile.readAsBytes();
    final otherDoc = PdfDocument(inputBytes: otherBytes, password: otherPassword);

    try {
      // Import real pages from both docs (preserves text/links/form fields)
      if (sourceDoc.pages.count > 0) {
        newDocument.importPageRange(sourceDoc, 0, sourceDoc.pages.count - 1);
      }
      if (otherDoc.pages.count > 0) {
        newDocument.importPageRange(otherDoc, 0, otherDoc.pages.count - 1);
      }

      String newPath;
      if (savePath != null) {
        newPath = savePath;
      } else {
        final dir = outputDir ?? path.dirname(sourcePath);
        final filename = path.basenameWithoutExtension(sourcePath);
        final ext = path.extension(sourcePath);
        newPath = path.join(dir, '${filename}_merged$ext');
      }

      final newBytes = await newDocument.save();
      await File(newPath).writeAsBytes(newBytes);
      return newPath;
    } finally {
      sourceDoc.dispose();
      otherDoc.dispose();
      newDocument.dispose();
    }
  }
```

---

**Step 11 — Locate (isProtected fall-through).** The current `isProtected` returns `false` from the inner success path when it does NOT find `/Encrypt` in the 2KB header/trailer scan. That heuristic gives false negatives (the `/Encrypt` reference can live deeper than the last 2KB, e.g. linearized or large-trailer PDFs). Find this EXACT block:
```dart
        final endRss = ProcessInfo.currentRss;
        logger.info('RAM', 'Pre-Check Result: Not Encrypted. End Process RAM: ${(endRss / 1024 / 1024).toStringAsFixed(2)} MB. Delta: ${((endRss - startRss) / 1024 / 1024).toStringAsFixed(2)} MB');
        
        return false;
      
      } catch (e) {
```

**Step 12 — Change.** Replace it with:
```dart
        final endRss = ProcessInfo.currentRss;
        logger.info('RAM', 'Pre-Check Result: No /Encrypt marker found in header/trailer. Falling through to Syncfusion check. End Process RAM: ${(endRss / 1024 / 1024).toStringAsFixed(2)} MB. Delta: ${((endRss - startRss) / 1024 / 1024).toStringAsFixed(2)} MB');
        
        // Heuristic header/trailer scan can miss /Encrypt; confirm with a real Syncfusion check
        return _isProtectedFallback(file);
      
      } catch (e) {
```
(The `RandomAccessFile? raf` is still closed by the existing `finally { await raf?.close(); }` block before `_isProtectedFallback` runs, because `return _isProtectedFallback(file);` is awaited as the function result after `finally` executes. Do not move or remove that `finally`.)

**Why (isProtected):** A false "not protected" result causes downstream code to open the PDF with no password and fail; falling through to `_isProtectedFallback` (which already does a genuine Syncfusion load that throws on encrypted input) makes the answer correct at the cost of a full load only when the fast scan is inconclusive.

**How to test:**
- *Static:* `fvm flutter analyze lib/services/pdf_tools_service.dart` must report no new errors. Confirm the `import 'package:flutter/widgets.dart';` line is now unused only if no other `Offset`/widget symbol remains in the file — if analyze flags it as unused, remove that single import line; otherwise leave it.
- *Manual (fidelity):* 1. Take a text-based PDF with selectable text and a hyperlink. 2. Run `removePassword` (or `splitPdf` on all pages). 3. Open the output in a PDF reader → expected: text is still selectable/searchable and the hyperlink still works (previously it would be a flat image). 
- *Manual (isProtected):* 1. Provide an encrypted PDF whose `/Encrypt` reference is NOT in the last 2KB (e.g. a large linearized file). 2. Call `isProtected(path)` → expected return `true` (previously `false`). 3. Provide a normal unencrypted PDF → expected `false`.
- *Manual (dispose on error):* 1. Call `removePassword` with a wrong `password` so the `PdfDocument(...)` or `save()` throws. 2. Confirm the exception propagates and no "PdfDocument not disposed" assertion/leak warning appears (the `finally` runs).

**Done when:** All five ops use `importPageRange` (no remaining `createTemplate(`/`drawPdfTemplate(` in the file), every op disposes its documents via `finally`, `isProtected` returns `_isProtectedFallback(file)` instead of bare `false` on the no-marker path, and `flutter analyze` is clean for the file.

**⚠️ Cautions:**
- `importPageRange(sourceDocument, startIndex, endIndex)` uses **0-based, inclusive** indices. For a whole document the end index is `pages.count - 1` — guard `count > 0` (done in mergePdf) so you never pass `-1`.
- Do NOT delete the `RandomAccessFile` `finally { await raf?.close(); }` block in `isProtected`.
- Keep the `Offset`/`flutter/widgets.dart` import only if still referenced after edits; removing it while still referenced will break the build.

---

### Task 27 — ZIP export: optional "Remove password from PDFs" (decrypt to temp before encode hop)
- **Roadmap:** Phase (Feature 2 — export), step 27 (from fix-order.md)
- **Type:** Feature · **Effort:** L · **Risk if done wrong:** high · **Low-model-safe:** No (senior review)
- **File(s):**
  - `lib/services/export_queue_service.dart` (add field to `ExportJob` ~18–106; `addJob` ~307–353; `_addItemsToArchive` ~413–449; `_processZipJob` ~489–529)
  - `lib/features/documents/screens/document_dashboard_screen.dart` (bulk-export dialog `_exportSelectedItems` ~402–549; folder-export dialog `_exportFolderAsZip` ~1230–1346)
- **Goal:** Add a "Remove password from PDFs" checkbox to the ZIP export dialog; thread a `removePasswords` bool through `addJob` → `ExportJob` → `_addItemsToArchive`; for each protected PDF, fetch the stored password and decrypt it to a TEMP file on the MAIN isolate BEFORE the `compute()` ZIP-encode hop, add the temp bytes to the archive, then delete the temp file. Originals are never modified. PDFs that are protected but have no stored password are SKIPPED and reported.

**Why:** Users want a shareable ZIP of unlocked PDFs without altering their library originals. Decryption must happen on the main isolate (the Syncfusion/native handle and `PdfPasswordService` are not isolate-portable), so it must run inside `_addItemsToArchive` before the bytes are handed to `compute(_encodeArchive, …)`.

---

**Step 1 — Locate (ExportJob field).** In `lib/services/export_queue_service.dart`, find this EXACT block:
```dart
  final ExportType type;
  final bool isDeveloper; // New field
  int progress;
  int processedItems;
  int totalItems;

  ExportJob({
    required this.id,
    required this.name,
    required this.items,
    this.type = ExportType.zip,
    this.isDeveloper = false, // Default false
    this.exportDir,
    this.zipPassword,
    this.status = ExportStatus.queued,
    this.progress = 0,
    this.processedItems = 0,
    this.totalItems = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
```

**Step 2 — Change.** Replace it with:
```dart
  final ExportType type;
  final bool isDeveloper; // New field
  final bool removePasswords; // If true, decrypt protected PDFs to temp before zipping
  int progress;
  int processedItems;
  int totalItems;

  ExportJob({
    required this.id,
    required this.name,
    required this.items,
    this.type = ExportType.zip,
    this.isDeveloper = false, // Default false
    this.removePasswords = false,
    this.exportDir,
    this.zipPassword,
    this.status = ExportStatus.queued,
    this.progress = 0,
    this.processedItems = 0,
    this.totalItems = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
```

---

**Step 3 — Locate (toJson).** Find this EXACT block:
```dart
      'type': type.name,
      'is_developer': isDeveloper ? 1 : 0, // Save flag
    };
  }
```

**Step 4 — Change.** Replace it with:
```dart
      'type': type.name,
      'is_developer': isDeveloper ? 1 : 0, // Save flag
      'remove_passwords': removePasswords ? 1 : 0,
    };
  }
```

---

**Step 5 — Locate (fromJson).** Find this EXACT block:
```dart
      isDeveloper: json['is_developer'] == 1, // Load flag
      status: ExportStatus.values.firstWhere((e) => e.name == json['status']),
```

**Step 6 — Change.** Replace it with:
```dart
      isDeveloper: json['is_developer'] == 1, // Load flag
      removePasswords: json['remove_passwords'] == 1,
      status: ExportStatus.values.firstWhere((e) => e.name == json['status']),
```

---

**Step 7 — Locate (addJob signature + construction).** Find this EXACT block:
```dart
  Future<String> addJob(String name, List<ExportItem> items, {String? exportDir, String? zipPassword, ExportType type = ExportType.zip, bool isDeveloper = false}) async {
```

**Step 8 — Change.** Replace it with:
```dart
  Future<String> addJob(String name, List<ExportItem> items, {String? exportDir, String? zipPassword, ExportType type = ExportType.zip, bool isDeveloper = false, bool removePasswords = false}) async {
```

**Step 9 — Locate (job construction inside addJob).** Find this EXACT block:
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
    );
```

**Step 10 — Change.** Replace it with:
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

---

**Step 11 — Add imports.** At the top of `lib/services/export_queue_service.dart`, the existing imports are:
```dart
import 'logging_service.dart';
import 'storage_service.dart';
```
Replace that pair with (adds the password + tools services; both live in the same `services/` folder):
```dart
import 'logging_service.dart';
import 'storage_service.dart';
import 'pdf_password_service.dart';
import 'pdf_tools_service.dart';
```

---

**Step 12 — Locate (the protected-PDF branch in `_addItemsToArchive`).** Find this EXACT block (the file-add branch):
```dart
      } else if (item.filePath != null) {
        final file = File(item.filePath!);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
          
          // Update progress
          job.processedItems++;
```

**Step 13 — Change.** Replace ONLY that portion with the following (the lines from `// Update progress` onward are unchanged and shown for context — keep everything below `job.processedItems++;` exactly as it already is):
```dart
      } else if (item.filePath != null) {
        final file = File(item.filePath!);
        if (await file.exists()) {
          List<int> bytes;
          final isPdf = item.filePath!.toLowerCase().endsWith('.pdf');

          if (job.removePasswords && isPdf && await _pdfTools.isProtected(item.filePath!)) {
            // Decrypt to a temp file on the MAIN isolate BEFORE the compute() encode hop.
            final storedPassword = await _pdfPasswords.getPasswordForDocument(item.filePath!);
            if (storedPassword == null || storedPassword.isEmpty) {
              // No stored password -> cannot unlock. Skip and report.
              job.skippedProtected.add(item.name);
              _log.warn('ExportQueueService', 'Skipped (no stored password): ${item.name}');
              job.processedItems++;
              await Future.delayed(Duration.zero);
              continue;
            }

            final tempPath = '${Directory.systemTemp.path}/unlocked_${job.id}_${job.processedItems}_${item.name}';
            try {
              final outPath = await _pdfTools.removePassword(
                filePath: item.filePath!,
                password: storedPassword,
                savePath: tempPath,
              );
              final tempFile = File(outPath);
              bytes = await tempFile.readAsBytes();
              archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
              // Clean up temp file; original is never touched.
              try {
                await tempFile.delete();
              } catch (_) {}
            } catch (e) {
              // Decryption/import failed -> skip this file rather than abort the whole job.
              job.skippedProtected.add(item.name);
              _log.error('ExportQueueService', 'Failed to remove password for ${item.name}', e);
              job.processedItems++;
              await Future.delayed(Duration.zero);
              continue;
            }
          } else {
            bytes = await file.readAsBytes();
            archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
          }

          // Update progress
          job.processedItems++;
```
(Everything from `if (job.totalItems > 0) {` down to the closing braces of this branch stays exactly as it is now. You are only replacing the segment that ends right after the `// Update progress` comment and the line `job.processedItems++;` — leave that single `job.processedItems++;` in place so the unchanged tail still runs.)

---

**Step 14 — Add the service instances + skip tracker to `ExportQueueService`.** Locate this EXACT block (existing fields near the top of the class):
```dart
  final LoggingService _log = LoggingService();
  final List<ExportJob> _jobs = [];
  Timer? _workerTimer;
```

**Step 15 — Change.** Replace it with:
```dart
  final LoggingService _log = LoggingService();
  final PdfPasswordService _pdfPasswords = PdfPasswordService();
  final PdfToolsService _pdfTools = PdfToolsService();
  final List<ExportJob> _jobs = [];
  Timer? _workerTimer;
```

**Step 16 — Add the `skippedProtected` list to `ExportJob`.** Locate this EXACT block (the `progress`/counters declared as instance fields):
```dart
  final bool removePasswords; // If true, decrypt protected PDFs to temp before zipping
  int progress;
  int processedItems;
  int totalItems;
```

**Step 17 — Change.** Replace it with:
```dart
  final bool removePasswords; // If true, decrypt protected PDFs to temp before zipping
  final List<String> skippedProtected = []; // Names of protected PDFs skipped (no/invalid stored password)
  int progress;
  int processedItems;
  int totalItems;
```

---

**Step 18 — Report skipped files after the ZIP completes.** Locate this EXACT block in `_processZipJob`:
```dart
    _log.info('ExportQueueService', 'Job completed: ${job.name} -> ${file.path}');
    
    await _showNotification(notificationId, 'Export Complete', '${job.name} saved successfully.');
  }
```

**Step 19 — Change.** Replace it with:
```dart
    _log.info('ExportQueueService', 'Job completed: ${job.name} -> ${file.path}');
    
    if (job.skippedProtected.isNotEmpty) {
      _log.warn('ExportQueueService', 'Export skipped ${job.skippedProtected.length} protected PDF(s) with no stored password: ${job.skippedProtected.join(', ')}');
      await _showNotification(
        notificationId,
        'Export Complete (with skips)',
        '${job.name} saved. Skipped ${job.skippedProtected.length} locked PDF(s) without a saved password.',
      );
    } else {
      await _showNotification(notificationId, 'Export Complete', '${job.name} saved successfully.');
    }
  }
```

---

**Step 20 — Locate (dashboard bulk-export dialog UI — `_exportSelectedItems`).** In `lib/features/documents/screens/document_dashboard_screen.dart`, find this EXACT block:
```dart
  Future<void> _exportSelectedItems() async {
    String? password;
    bool encrypt = false;

    final confirm = await showDialog<bool>(
```

**Step 21 — Change.** Replace it with:
```dart
  Future<void> _exportSelectedItems() async {
    String? password;
    bool encrypt = false;
    bool removePasswords = false;

    final confirm = await showDialog<bool>(
```

**Step 22 — Locate (bulk dialog checkbox area).** Find this EXACT block (inside `_exportSelectedItems`):
```dart
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
```

**Step 23 — Change.** Replace it with:
```dart
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
                        onChanged: (val) => setState(() => removePasswords = val ?? false),
                      ),
                      const Expanded(
                        child: Text('Remove password from PDFs'),
                      ),
                    ],
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
```

**Step 24 — Locate (bulk addJob call).** Find this EXACT block:
```dart
      // Add to queue
      _exportQueue.addJob('Bulk Export', exportItems, exportDir: exportPath, zipPassword: zipPassword);
```

**Step 25 — Change.** Replace it with:
```dart
      // Add to queue
      _exportQueue.addJob('Bulk Export', exportItems, exportDir: exportPath, zipPassword: zipPassword, removePasswords: removePasswords);
```

---

**Step 26 — Locate (folder-export dialog — `_exportFolderAsZip`).** Find this EXACT block:
```dart
  Future<void> _exportFolderAsZip(DocumentItem folder) async {
    String? password;
    bool encrypt = false;
    
    final confirm = await showDialog<bool>(
```

**Step 27 — Change.** Replace it with:
```dart
  Future<void> _exportFolderAsZip(DocumentItem folder) async {
    String? password;
    bool encrypt = false;
    bool removePasswords = false;
    
    final confirm = await showDialog<bool>(
```

**Step 28 — Locate (folder dialog checkbox area).** Find this EXACT block (inside `_exportFolderAsZip`):
```dart
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
                  icon: const Icon(Icons.download),
                  onPressed: () => Navigator.pop(context, true),
                  label: const Text('Export'),
                ),
              ],
```

**Step 29 — Change.** Replace it with:
```dart
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
                        onChanged: (val) => setState(() => removePasswords = val ?? false),
                      ),
                      const Expanded(
                        child: Text('Remove password from PDFs'),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  onPressed: () => Navigator.pop(context, true),
                  label: const Text('Export'),
                ),
              ],
```

**Step 30 — Locate (folder addJob call).** Find this EXACT block:
```dart
      // Add to queue
      _exportQueue.addJob(folder.name, items, exportDir: exportPath, zipPassword: zipPassword);
```

**Step 31 — Change.** Replace it with:
```dart
      // Add to queue
      _exportQueue.addJob(folder.name, items, exportDir: exportPath, zipPassword: zipPassword, removePasswords: removePasswords);
```

**Why:** The checkbox sets `removePasswords`, which flows through `addJob` into the persisted `ExportJob`. `_addItemsToArchive` runs on the main isolate, so it can use `PdfPasswordService.getPasswordForDocument` and `PdfToolsService.removePassword` to write a decrypted temp file, add those bytes, and delete the temp — all before the archive is shipped to the `compute(_encodeArchive, …)` isolate. Files with no recoverable password are recorded in `skippedProtected` and surfaced in the completion notification + log.

**How to test:**
- *Static:* `fvm flutter analyze lib/services/export_queue_service.dart lib/features/documents/screens/document_dashboard_screen.dart` must be clean.
- *Manual (happy path):* 1. Open a password-protected PDF in the app and enter the correct password (so it is saved via `PdfPasswordService`). 2. Select that file → Export → tick "Remove password from PDFs" → Export. 3. When the job completes, open the produced ZIP and open the PDF inside → expected: it opens with NO password prompt, and its text is still selectable (uses `importPageRange` from Task 26). 4. Confirm the ORIGINAL file in the library still opens only with its password (untouched).
- *Manual (skip path):* 1. Import a protected PDF but never enter its password (no stored password). 2. Export with the checkbox ticked → expected: job completes, the locked PDF is absent from the ZIP (or present-but-skipped per implementation — here it is omitted), and the completion notification reads "Export Complete (with skips) … Skipped 1 locked PDF(s)…"; the log shows a `Skipped (no stored password)` warning with the file name.
- *Manual (checkbox off):* Export with the box unticked → behaves exactly as before (protected PDFs are zipped as-is, still locked).

**Done when:**
- The ZIP dialog (both bulk and folder export) shows a "Remove password from PDFs" checkbox.
- With it ticked, protected PDFs that have a stored password appear decrypted inside the ZIP; originals are unchanged; temp files are deleted.
- Protected PDFs without a stored password are skipped and reported (notification + log), and the job still completes successfully.
- `flutter analyze` is clean for both files.

**⚠️ Cautions:**
- Decryption MUST stay inside `_addItemsToArchive` (main isolate). Do NOT move `removePassword`/`PdfDocument` work into `_encodeArchive` / the `compute()` isolate — Syncfusion native handles and `PdfPasswordService` (SharedPreferences-backed) are not isolate-safe.
- This task depends on Task 26's `removePassword` using `importPageRange`; apply Task 26 first so the unlocked PDFs in the ZIP keep selectable text.
- Never write the unlocked output over `item.filePath` — always to a temp path under `Directory.systemTemp`, and delete it after adding to the archive.
- `getPasswordForDocument` can return `''` (the `NO_PASSWORD` sentinel). The code treats null OR empty as "no usable password" before attempting `removePassword`; keep that guard.

---

Notes on what I verified against the real code (differs from / refines the roadmap hints):
- `pdf_tools_service.dart` uses `createTemplate()` + `section.pages.add()` + `drawPdfTemplate(...)` in all five ops (lines ~24-33, 105-116, 150-161, 195-205) — replaced with `importPageRange`. Syncfusion is `^32.1.22` (confirms `importPageRange(PdfDocument, startIndex, endIndex)` is available).
- `isProtected` currently `return false;` on the no-marker path (line ~312); changed to fall through to the existing `_isProtectedFallback(File)` (lines ~328-341), which already does a real Syncfusion load.
- There are TWO export dialogs in the dashboard, not one: `_exportSelectedItems` (~402) and `_exportFolderAsZip` (~1230). Both call `_exportQueue.addJob(...)` (~521 and ~1318) and both need the checkbox + the `removePasswords:` argument. The `addJob` signature is at line ~307; `_addItemsToArchive` at ~413; `_processZipJob` completion notification at ~528.
- `PdfPasswordService.getPasswordForDocument` (singleton) returns `String?` and may return `''` for the `NO_PASSWORD` sentinel — handled in the guard.

---

# PHASE 5 — Architecture & code-smell cleanup
### Task 28 — Delete dead duplicate `PdfViewerScreen` stub
- **Roadmap:** Phase (cleanup), step 28 (from fix-order.md)
- **Type:** Smell (dead code) · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/features/pdf_tools/screens/pdf_viewer_screen.dart` (entire file, 49 lines as of writing — VERIFY before editing)
- **Goal:** Remove the unused stub `PdfViewerScreen` so only the real implementation at `lib/features/documents/screens/pdf_viewer_screen.dart` remains.

**Step 1 — Confirm no imports (already verified, re-confirm).** Run a search across `lib/` for any import that ends in `lib/features/pdf_tools/screens/pdf_viewer_screen.dart`. Search pattern (string-match, case-sensitive):
```
pdf_tools/screens/pdf_viewer_screen
```
Expected result: **zero matches** in any `.dart` file. (Confirmed at time of writing: every `import` of `pdf_viewer_screen.dart` resolves to `lib/features/documents/screens/pdf_viewer_screen.dart` — see `lib/main.dart:22`, `lib/features/documents/screens/all_documents_screen.dart:4`, `lib/features/documents/screens/document_dashboard_screen.dart:26`, `lib/features/recent_documents/screens/recent_documents_screen.dart:6`. None reference `pdf_tools`.)

If — and only if — a match exists, repoint that import to `package:passwordpdf_manager/features/documents/screens/pdf_viewer_screen.dart` and STOP (do not delete until the search returns zero).

**Step 2 — Delete the file.** The entire current contents of `lib/features/pdf_tools/screens/pdf_viewer_screen.dart` are:
```dart
// TEMPORARY STUB: Original file used syncfusion_flutter_pdfviewer which conflicts with pdfrx v2
// TODO: Migrate to use pdfrx or remove this feature
import 'package:flutter/material.dart';

/// Stub PDF Viewer screen - original implementation used Syncfusion pdfviewer
/// which is incompatible with the current pdfrx v2 migration
class PdfViewerScreen extends StatelessWidget {
  final String filePath;
  final String password;

  const PdfViewerScreen({
    super.key,
    required this.filePath,
    this.password = '',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Viewer (Unavailable)'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning_amber, size: 64, color: Colors.orange),
            const SizedBox(height: 16),
            const Text(
              'This PDF viewer is temporarily unavailable.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'File: $filePath',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}
```
Delete the whole file (`rm lib/features/pdf_tools/screens/pdf_viewer_screen.dart`). If the `lib/features/pdf_tools/screens/` directory is now empty, leave it (do not chase empty-dir cleanup in this task).

**Why:** This is a dead duplicate class with the same name `PdfViewerScreen`; nothing imports it, and its presence is a long-standing source of confusion with the real viewer.

**How to test:**
- *Static:* `fvm flutter analyze` must be clean (no "uri does not exist" / "isn't defined" errors). Note: the project's `analyze_full.txt` previously listed errors against this stub path (e.g. `undefined_method 'PdfViewerController'`); those must disappear.
- *Manual:* 1. `fvm flutter run`. 2. Open any password-protected PDF from the dashboard → expect the REAL viewer (`lib/features/documents/screens/pdf_viewer_screen.dart`), never a screen titled "PDF Viewer (Unavailable)".

**Done when:** the file no longer exists, `flutter analyze` is clean, and the app builds and opens PDFs.

**⚠️ Cautions:** Do NOT delete `lib/features/documents/screens/pdf_viewer_screen.dart` — that is the live one. Only the `pdf_tools/` copy is dead.

---

### Task 28a — Remove redundant double `_saveDocuments()` in `deleteItem`
- **Roadmap:** Phase (smells/hygiene), step 28 (from fix-order.md)
- **Type:** Smell · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/services/document_service.dart` (~lines 869–870 as of writing — VERIFY before editing)
- **Goal:** Persist once, not twice, at the end of `deleteItem`.

**Step 1 — Locate.** In `lib/services/document_service.dart`, find this EXACT block:
```dart
    await _saveDocuments();
    await _saveDocuments();
    _log.info('DocumentService', 'Deleted item: ${item.name} (Device delete: $deleteFromDevice)');
```

**Step 2 — Change.** Replace it with:
```dart
    await _saveDocuments();
    _log.info('DocumentService', 'Deleted item: ${item.name} (Device delete: $deleteFromDevice)');
```

**Why:** The second `await _saveDocuments();` re-serializes and rewrites the entire document list to storage for no benefit — pure redundant I/O.

**How to test:**
- *Static:* `fvm flutter analyze` clean for `lib/services/document_service.dart`.
- *Manual:* 1. Delete a document (and a folder) from the dashboard. 2. Restart the app → expect the deleted item stays gone (persistence still works after removing the duplicate call).

**Done when:** Only a single `await _saveDocuments();` precedes the "Deleted item" log line.

---

### Task 28b — Remove dead `existingFiles` prefetch in `_syncToDatabase`
- **Roadmap:** Phase (smells/hygiene), step 28 (from fix-order.md)
- **Type:** Smell (dead code / wasted query) · **Effort:** S · **Risk if done wrong:** med (must also remove the now-orphaned reads of `existingFiles`) · **Low-model-safe:** With-care
- **File(s):** `lib/services/device_document_service.dart` (~lines 119–129 declare it; ~lines 156–158 read it — VERIFY before editing)
- **Goal:** Delete the unused `existingFiles` map (and its now-dead consumers) since trigram/modified-diff logic was removed.

**Step 1 — Locate (the prefetch).** In `lib/services/device_document_service.dart`, find this EXACT block:
```dart
      // Pre-fetch existing file stats to optimize updates
      final Map<String, int> existingFiles = {}; // path -> modified_at
      try {
         final existingRows = await db.query(
            AppConstants.filesIndexTable, 
            columns: ['path', 'modified_at']
         );
         for (final row in existingRows) {
            existingFiles[row['path'] as String] = row['modified_at'] as int;
         }
      } catch (_) {}

```

**Step 2 — Change.** Replace it with nothing (delete the entire block, including the trailing blank line).

**Step 3 — Locate (the dead consumer).** Still in the same method, find this EXACT block:
```dart
              // Check if file is modified or new
              final lastMod = existingFiles[file.path];
              final currentMod = stat.modified.millisecondsSinceEpoch;
              // final isModified = lastMod == null || lastMod != currentMod; // Unused without Trigrams

```

**Step 4 — Change.** Replace it with:
```dart
              final currentMod = stat.modified.millisecondsSinceEpoch;

```
(`currentMod` is still used below in `'modified_at': currentMod`; only the `existingFiles` lookup, `lastMod`, and the commented-out `isModified` line are removed.)

**Why:** `existingFiles` is populated by a full table scan but only read into `lastMod`, which is never used (the modified-diff path was removed when trigram search was dropped — see the `// Phase 1.10: Trigrams REMOVED` comment). The prefetch is pure wasted I/O on every sync.

**How to test:**
- *Static:* `fvm flutter analyze` clean for `lib/services/device_document_service.dart` — in particular no "unused local variable" remains and no reference to `existingFiles` or `lastMod` survives. Confirm with a search: pattern `existingFiles` and pattern `lastMod` must both return **zero matches** in this file.
- *Manual (Android device only):* 1. Trigger a device scan (Dashboard sync). 2. Expect the file list to populate as before and the log to show "Sync complete. Removed N stale records." (the mark-and-sweep is unaffected — it relies on `last_scanned`, not on `existingFiles`).

**Done when:** `existingFiles` and `lastMod` no longer appear in the file, sync still indexes files correctly, and analyze is clean.

**⚠️ Cautions:** Do NOT remove `currentMod` — it is still written into the batch insert. Remove only the prefetch and the `lastMod` read.

---

### Task 28c — Close export `_notificationTapController` and add `dispose()`
- **Roadmap:** Phase (smells/hygiene), step 28 (from fix-order.md)
- **Type:** Smell (resource leak) · **Effort:** S · **Risk if done wrong:** low · **Low-model-safe:** Yes
- **File(s):** `lib/services/export_queue_service.dart` (~line 238 declares the controller; class ends ~line 554 — VERIFY before editing)
- **Goal:** Give `ExportQueueService` a `dispose()` that cancels the worker timer and closes the broadcast `StreamController`.

**Step 1 — Locate (anchor at end of class).** In `lib/services/export_queue_service.dart`, find this EXACT block (the last method of the class plus the closing brace):
```dart
  /// Isolate function to encode archive
  // Accepts Map with 'archive' and optional 'password'
  static List<int>? _encodeArchive(Map<String, dynamic> params) {
    try {
      final archive = params['archive'] as Archive;
      final password = params['password'] as String?;
      
      final encoder = ZipEncoder(password: password);
      return encoder.encode(archive);
    } catch (e) {
      return null;
    }
  }
}
```

**Step 2 — Change.** Replace it with (insert the new `dispose()` immediately before the final `}` of the class):
```dart
  /// Isolate function to encode archive
  // Accepts Map with 'archive' and optional 'password'
  static List<int>? _encodeArchive(Map<String, dynamic> params) {
    try {
      final archive = params['archive'] as Archive;
      final password = params['password'] as String?;
      
      final encoder = ZipEncoder(password: password);
      return encoder.encode(archive);
    } catch (e) {
      return null;
    }
  }

  @override
  void dispose() {
    _workerTimer?.cancel();
    _workerTimer = null;
    if (!_notificationTapController.isClosed) {
      _notificationTapController.close();
    }
    _log.info('ExportQueueService', 'Disposed');
    super.dispose();
  }
}
```

**Why:** `_notificationTapController` (line ~238) is a `StreamController.broadcast()` that is never closed, and the class (a `ChangeNotifier`) has no `dispose()`, so its timer and stream leak. `@override` is valid because `ChangeNotifier` defines `dispose()`.

**How to test:**
- *Static:* `fvm flutter analyze` clean for `lib/services/export_queue_service.dart` (the `@override` must resolve against `ChangeNotifier.dispose`).
- *Manual:* 1. App still starts, exports still run and emit notifications (no regression). 2. (Optional) In a `test/`, instantiate the singleton, call `startWorker()` then `dispose()`, and assert no exception is thrown.

**Done when:** `ExportQueueService` has a `dispose()` that cancels `_workerTimer` and closes `_notificationTapController`, and analyze is clean.

**⚠️ Cautions:** `ExportQueueService` is a **singleton** (`factory ExportQueueService() => _instance`). Do NOT add a `dispose()` call anywhere in app startup/teardown that would close it while the app is still running — this card only ADDS the method so the resource *can* be released (e.g. in tests or a future shutdown hook). Do not wire it into `document_dashboard_screen.dart`'s `dispose()` (that already calls `stopWorker()`, which is correct).

---

### Task 28d — Dispose dialog-local `TextEditingController`s in `developer_screen.dart`
- **Roadmap:** Phase (smells/hygiene), step 28 (from fix-order.md)
- **Type:** Smell (controller leak) · **Effort:** S · **Risk if done wrong:** med (dispose only AFTER `await showDialog` returns) · **Low-model-safe:** With-care
- **File(s):** `lib/features/developer/screens/developer_screen.dart` (~lines 68, 267, 641, 754 — VERIFY before editing)
- **Goal:** Dispose each `TextEditingController` that is created locally inside a dialog method, right after that dialog closes.

> NOTE (trust the code over the roadmap): the line hints :68/:267/:641/:754 point at *local* controllers created inside async dialog methods, NOT State fields. They therefore cannot be disposed in `dispose()`; the correct fix is to call `.dispose()` after the `await showDialog(...)` completes in each method. Four independent edits follow.

**Edit A — `_manageEncryptionKey` (controller ~line 68).**

**Step 1 — Locate.** Find this EXACT block:
```dart
      if (result == true && controller.text.isNotEmpty) {
        final success = await _encryptionService.setEncryptionKey(controller.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(success ? 'Encryption key set' : 'Failed to set key'),
              backgroundColor: success ? Colors.green : Colors.red,
            ),
          );
        }
      }
    }
  }
```

**Step 2 — Change.** Replace it with:
```dart
      if (result == true && controller.text.isNotEmpty) {
        final success = await _encryptionService.setEncryptionKey(controller.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(success ? 'Encryption key set' : 'Failed to set key'),
              backgroundColor: success ? Colors.green : Colors.red,
            ),
          );
        }
      }
      controller.dispose();
    }
  }
```
(The `controller.dispose()` goes inside the `else` branch that owns the `final controller = TextEditingController();`, after the `if (result == true ...)` handling.)

**Edit B — `_showLogSettings` (controller ~line 267).**

**Step 1 — Locate.** Find this EXACT block:
```dart
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs() async {
```

**Step 2 — Change.** Replace it with:
```dart
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _exportLogs() async {
```
(This places `controller.dispose()` immediately after the `await showDialog(...)` returns, before the method's closing brace.)

**Edit C — record-edit dialog (controllers map ~line 641).**

**Step 1 — Locate.** Find this EXACT block:
```dart
      if (newData.isNotEmpty) {
        await _storage.updateRecord(_selectedTable!, 'id', id, newData);
        _loadTableData();
      }
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
```

**Step 2 — Change.** Replace it with:
```dart
      if (newData.isNotEmpty) {
        await _storage.updateRecord(_selectedTable!, 'id', id, newData);
        _loadTableData();
      }
    }
    for (final c in controllers.values) {
      c.dispose();
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
```
(Disposes every controller in the `controllers` map created at `final controllers = <String, TextEditingController>{};`, after the dialog and the `if (confirm == true)` handling.)

**Edit D — `_exportDatabase` (`limitController` ~line 754).**

**Step 1 — Locate.** Find this EXACT block:
```dart
    if (result == null || result['proceed'] != true) return;
    
    final isUnlimited = result['unlimited'] == true;
```

**Step 2 — Change.** Replace it with:
```dart
    limitController.dispose();

    if (result == null || result['proceed'] != true) return;
    
    final isUnlimited = result['unlimited'] == true;
```
(Dispose `limitController` right after `await showDialog(...)` returns and BEFORE the early `return`, so it is freed on both the cancel and proceed paths. `result['limit']` was already read into the map by the dialog's button, so the controller is no longer needed.)

**Why:** Each of these `TextEditingController`s is allocated per dialog invocation and never released, leaking a small amount of memory on every Developer-screen interaction.

**How to test:**
- *Static:* `fvm flutter analyze` clean for `lib/features/developer/screens/developer_screen.dart`. There must be NO "use after dispose" — verify each `.dispose()` is after the last `.text` read.
- *Manual:* In the Developer screen: 1. Set/View Encryption Key dialog → Set a key → expect success snackbar, no crash. 2. Log Settings → Save → expect "Max logs set to N". 3. Edit a DB record → Update → expect the row updates. 4. Export Database → choose limit → Export → expect the export progress screen. Re-open each dialog a second time → expect it still works (controllers are recreated fresh each call).

**Done when:** Every dialog-local controller in this file is disposed after its dialog closes, all four dialogs still function, and analyze is clean.

**⚠️ Cautions:** Do NOT move these into the State `dispose()` — they are method-local, not fields, and disposing them in `dispose()` is impossible (they don't exist there). Do NOT dispose before the controller's `.text` is read (e.g. Edit D must dispose AFTER `showDialog` returns, since the dialog reads `limitController.text` into the result map).

---

### Task 28e — Fix the leaking inline `TextEditingController` in the smart-password dialog
- **Roadmap:** Phase (smells/hygiene), step 28 (from fix-order.md)
- **Type:** Smell (controller leak + state reset bug) · **Effort:** S · **Risk if done wrong:** med (preserve the prefilled filename) · **Low-model-safe:** With-care
- **File(s):** `lib/features/documents/screens/document_dashboard_screen.dart` (~line 1901, inside `_showSmartPasswordDialogAndOpen` which starts ~line 1839 — VERIFY before editing)
- **Goal:** Stop creating a fresh `TextEditingController(text: saveName)` on every rebuild; use one controller created once for the dialog and dispose it.

**Step 1 — Locate (controller creation site).** In `lib/features/documents/screens/document_dashboard_screen.dart`, find this EXACT block at the top of `_showSmartPasswordDialogAndOpen`:
```dart
    String password = '';
    bool saveToList = false;
    String saveName = fileName;
    String? errorMessage;
    
    bool obscurePassword = true;

    await showDialog(
```

**Step 2 — Change.** Replace it with:
```dart
    String password = '';
    bool saveToList = false;
    String saveName = fileName;
    String? errorMessage;
    
    bool obscurePassword = true;

    final saveNameController = TextEditingController(text: saveName);

    await showDialog(
```

**Step 3 — Locate (the leaking inline controller).** Find this EXACT block:
```dart
                    if (saveToList)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: TextField(
                          controller: TextEditingController(text: saveName),
                          decoration: const InputDecoration(
                            labelText: 'Password Name (e.g. Bank Statement)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (val) => saveName = val,
                        ),
                      ),
```

**Step 4 — Change.** Replace it with:
```dart
                    if (saveToList)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: TextField(
                          controller: saveNameController,
                          decoration: const InputDecoration(
                            labelText: 'Password Name (e.g. Bank Statement)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (val) => saveName = val,
                        ),
                      ),
```

**Step 5 — Locate (after the dialog closes).** Find this EXACT block (the `.then(...)` chained onto `showDialog`):
```dart
    ).then((result) async {
      if (result == true) {
        // Password was valid (checked in dialog)
        await pdfService.saveDocumentPassword(filePath, password);
```

**Step 6 — Change.** Replace it with:
```dart
    ).then((result) async {
      saveNameController.dispose();
      if (result == true) {
        // Password was valid (checked in dialog)
        await pdfService.saveDocumentPassword(filePath, password);
```

**Why:** `controller: TextEditingController(text: saveName)` was built inside the `StatefulBuilder`'s `build`, so a brand-new controller was allocated (and leaked) on every rebuild, and the text field's cursor/content was reset to `saveName` whenever the dialog rebuilt (e.g. toggling the password-visibility eye). Hoisting one controller fixes both the leak and the reset; `onChanged` still keeps `saveName` in sync for the save logic below.

**How to test:**
- *Static:* `fvm flutter analyze` clean for `lib/features/documents/screens/document_dashboard_screen.dart`.
- *Manual:* 1. Open an encrypted PDF whose stored/brute-forced password is unknown so the manual dialog appears. 2. Tick "Add to My Passwords list?" → the name field shows the filename prefilled. 3. Type a custom name, then toggle the password-visibility eye icon → expect your typed name to REMAIN (previously it reset to the filename). 4. Enter the correct password → Open → expect the viewer opens and the password is saved under your typed name.

**Done when:** Exactly one `saveNameController` is created per dialog, it is disposed in the `.then` callback, the name field keeps user input across rebuilds, and analyze is clean.

**⚠️ Cautions:** Dispose in the `.then` callback (after the dialog future resolves), NOT inside the builder. Do not batch this edit with Task 28d — different file. Keep `onChanged: (val) => saveName = val` so the save path still sees the latest name.

---

### Task 30 & 31 — Store refactor + architecture cleanup (PROJECT BRIEF)
- **Roadmap:** Phase (arch), steps 30 & 31 (from fix-order.md)
- **Type:** Arch · **Effort:** L · **Risk if done wrong:** high · **Low-model-safe:** No (senior review)
- **File(s):** Cross-cutting — primarily `lib/features/documents/screens/document_dashboard_screen.dart`, `lib/services/document_service.dart`, `lib/services/device_document_service.dart`, `lib/services/export_queue_service.dart`, `lib/features/documents/screens/pdf_viewer_screen.dart`, and their callers.
- **Goal:** This is NOT a string-match recipe. It is a scoping brief so the owner schedules it as senior engineering work and does NOT hand it to a low-capability model.

**Scope.** Two intertwined problems the app has accumulated:
1. **State/store fragmentation.** Document state lives in at least two places with overlapping responsibilities and different storage backends: `DocumentService` (in-memory `_items` list persisted to `SharedPreferences` as a JSON blob, with manual `_saveDocuments()` calls scattered through mutators) and `DeviceDocumentService` (a SQLite `files_index` table populated by an isolate filesystem scan, with its own in-memory `_cachedPaths` search cache). The dashboard, all-documents, and recent-documents screens each read/write through these directly. There is no single source of truth, no reactive store, and persistence is by ad-hoc `await _saveX()` calls (one of which was even duplicated — see Task 28a).
2. **Singletons holding lifecycle/native resources.** `ExportQueueService` and the services above are app-lifetime singletons that own timers, a notification plugin, a broadcast stream, and (in the viewer) native PDF handles. Ownership and teardown are unclear: the dashboard's `dispose()` calls `_exportQueue.stopWorker()` even though the queue is a global singleton, and the queue had no `dispose()` at all (added in Task 28c only so the resource *can* be freed).

**Bugs this refactor subsumes (do these as part of the redesign, not piecemeal):**
- Stored-password fast path never re-verifies before opening the viewer (documented at `CODEBASE_DEEP_DIVE.md` ~L839): a stale/changed PDF password opens a broken viewer with no fallback to brute-force/manual entry.
- `PdfViewerScreen` pushed across async gaps without `mounted` / `Navigator.canPop` guards after awaiting the stored password (dashboard `_openFile` and `_importAndOpenSingle`, and similar push sites at ~:384/:1713/:1751/:1802/:1967) — disposed-context crash if the user backs out mid-await.
- Plaintext passwords held in long-lived `String`s and passed through multiple layers (`foundPassword` / `password` → `PdfViewerScreen(password:)` → `saveDocumentPassword`) — a store redesign is the right moment to confine password handling to one component with a defined lifetime.
- Manual-save fragility in `DocumentService` (the duplicated `_saveDocuments()` was a symptom): mutation + persistence are not transactional, so a crash between mutate and save loses or corrupts state.
- Search-cache coherence: `DeviceDocumentService._cachedPaths` can drift from the DB between scans; the In-Memory search and the SQLite index are two sources that can disagree.

**Suggested approach (for the senior owner; not a step list to execute blindly):**
- Introduce a single document **store** (e.g. a `ChangeNotifier`/Riverpod/Bloc — match whatever the team standardizes on) as the one source of truth, backed by SQLite. Collapse `DocumentService`'s SharedPreferences JSON blob into the same DB so there is one persistence layer. Persistence should happen inside store mutators (ideally transactionally), eliminating scattered `_saveDocuments()` calls.
- Make screens consume the store reactively (no direct service reads/writes from widget code; no manual `setState` for data changes).
- Define explicit ownership for singletons: who starts/stops the export worker, who owns the notification plugin, and a clear disposal path. Decide whether `ExportQueueService` should remain a singleton or be provided/scoped.
- Centralize the open-PDF flow (smart-open) into one method that always verifies the password (fixing the stale-password bug) and guards every navigation with `mounted` checks. Confine plaintext passwords to that flow.
- Land it behind tests: store unit tests for mutate→persist→reload, and widget tests for the open-PDF decision tree (stored-valid / stored-stale / brute-force / manual).

**Why this is "Low-model-safe: No":** it spans many files, requires choosing an architecture, touches data persistence and migration (risk of data loss for existing users' saved passwords/document lists), involves native handle and async lifecycle correctness, and the individual "bugs" are entangled — fixing them in isolation with string-match edits would create half-migrations and regressions. Schedule as a planned senior task with a migration plan and test coverage; do not feed to a weak model.

**Done when:** there is a single reactive store as source of truth, one persistence backend, transactional mutations, a centralized + guarded open-PDF flow that re-verifies stored passwords, explicit singleton lifecycle ownership, and passing store + open-flow tests. (The smells in Tasks 28a–28e may be done first as safe warm-ups; they reduce, but do not replace, this work.)

**⚠️ Cautions:** Existing users have saved passwords and document lists in SharedPreferences and SQLite — any storage consolidation MUST include a one-time migration and be tested against a populated install before release.

---

Notes for the handbook owner:
- Verified by grep at time of writing: **no file imports** `lib/features/pdf_tools/screens/pdf_viewer_screen.dart`; all `pdf_viewer_screen.dart` imports resolve to `features/documents/screens/...`. Task 28 deletion is safe.
- The developer-screen "controllers" at the roadmap's :68/:267/:641/:754 are **method-local**, not State fields, so the fix is post-`showDialog` disposal (Task 28d), not `dispose()`-method additions.
- The dashboard :1901 controller is created **inline in build** (worst case — leaks every rebuild and resets text); Task 28e hoists it.
