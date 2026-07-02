# VERIFICATION REPORT

## Verdict

The handbook is **mostly ready** for a low-capability model, but it is **not safe to hand over wholesale**. Of the 68 findings, 56 cards are clean (anchor matched, unique, complete new code/test/acceptance, low-model-ready) and 12 need attention. Of those 12, four are **expected non-matches** (one `new_file_ok` scoping brief and three `depends_on_prior_step` cards that only match after a prior card runs) and should simply be excluded or sequenced — they are not defects. The remaining **8 cards genuinely need repair** before a weak model touches them: they are missing verbatim Locate/Change blocks, reference undefined or private symbols, have a falsely-claimed-unique anchor, or carry unresolved cross-task ordering conflicts. The clean path: route the 56 ready cards to the low model, repair or fence off the 8 problem cards, and keep the senior-review briefs out of the low-model batch entirely.

## Summary table

| Task | File | Anchor | Unique | New code | Test | Acceptance | Low-model-ready |
|---|---|---|---|---|---|---|---|
| Task 1 — UpdateInfo model (Step 3/4) | update_info.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 1 — import list (Step 5/6) | update_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 1 — downloadUpdate (Step 7/8) | update_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 1 — expectedSha256 in performUpdate (Step 9/10) | update_dialogs.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 1 — force-update dialog (Step 11/12/13) | update_dialogs.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 1 — showDialog barrier (Step 14/15) | update_dialogs.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 1 — showDialog barrier in main.dart (Step 16/17) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Task 1 — barrier in settings _checkForUpdates (Step 18/19) | settings_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 2 — resilient library load | document_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 3 — COALESCE upsert + scoped sweep | device_document_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 4 — overwrite-import temp-then-swap | all_documents_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Task 5 — guard device deletion | document_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 6 — IF NOT EXISTS in migrations | storage_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 7 — folder cycle check | document_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 8 — orElse on getPhysicalPathForFolder | document_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 8 — move-source firstWhere (Step 1/2) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 8 — overwrite dest lookup (Step 3/4) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 9 — pagination try/finally | all_documents_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 9 — multi-delete resilient (Step 3/4) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 9 — rename-import RangeError (Step 1/2) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 10 — intent guard fields (Step 1) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 10 — _checkInitialIntents (Step 3) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 10 — _checkForPendingIntent (Step 5) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 10 — _handleSharedFiles flag (Step 7) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 11 — Share action in viewer AppBar | pdf_viewer_screen.dart (documents) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 12 — File info overflow menu | pdf_viewer_screen.dart (documents) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 13 — cleanupUpdateFile | update_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 13 — empty-password attempt in _getPassword | pdf_viewer_screen.dart (documents) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 13a — empty-but-checked ZIP password (Step 1/2) | document_dashboard_screen.dart | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| Task 13b — root-level pre-populate (Step 1/2) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 13b — subfolder pre-populate (Step 3/4) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 13b — _buildFolderSubtitle (Step 5/6) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 13b — filter-chip onSelected (Step 7/8) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 15 — read-both dispatcher + AES-GCM | encryption_service.dart | ⚠️ | ❌ | ✅ | ✅ | ✅ | ❌ |
| Task 15/16 — prime AES key (Step 4) | main.dart | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| Task 16 — passphrase Backup/Restore (Step 4 AppBar) | password_manager_screen.dart | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| Task 17 — SmartOpen CAS write-back | document_dashboard_screen.dart | ⚠️ | ✅ | ❌ | ✅ | ✅ | ❌ |
| Task 17 — legacy verify + CAS | encryption_service.dart | (dep) | ✅ | ✅ | ✅ | ✅ | ❌ |
| Task 17 — PdfPasswordService side | pdf_password_service.dart | (dep) | ✅ | ❌ | ✅ | ✅ | ❌ |
| Task 19 — verifyPin rehash (Step 1) | settings_service.dart | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ |
| Task 19 — dev gate hash (Step 2) | encryption_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Task 19 — dev screen / zip pw (Step 3/4) | developer_screen.dart | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| Task 19 — zip-password impact (Step 4) | export_queue_service.dart | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| Task 20 — force biometricOnly | biometric_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 20 — exemptNextPause | settings_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 21 — auto-lock fields (Step 1) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 21 — paused branch (Step 3) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 21 — resumed branch (Step 5) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 21 — timeout-not-reached log (Step 7) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 21 — exit-app handler (Step 9) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 23 — whitelist table/idColumn | storage_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 24 — redact logs (Step 1/2) | logging_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 24 — redact setPin (Step 3/4) | settings_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 24 — redact verifyPin (Step 5/6) | settings_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 25 — hash PIN/dev pw (settings ref) | settings_screen.dart | ⚠️ | ✅ | ❌ | ✅ | ✅ | ❌ |
| Task 25 — scope perms requestAll (Step 1/2) | permission_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 25 — scope perms areAllGranted (Step 3/4) | permission_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 25 — scope perms getStatus (Step 5/6) | permission_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 26 — PDF-tools fidelity | pdf_tools_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 27 — ZIP export remove-password | export_queue_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Task 28 — delete dead PdfViewerScreen stub | pdf_viewer_screen.dart (pdf_tools) | ✅ | ✅ | n/a | ✅ | ✅ | ✅ |
| Task 28a — remove double _saveDocuments | document_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 28b — remove dead existingFiles prefetch | device_document_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 28c — dispose() on ExportQueueService | export_queue_service.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 28d — dispose dialog controllers | developer_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 28e — leaking controller create site (Step 1/2) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 28e — leaking controller TextField (Step 3/4) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 28e — .then dispose (Step 5/6) | document_dashboard_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 29 — onUpdate call site (Step 1) | main.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 29 — delete _performUpdate (Step 3) | main.dart | ✅ | ✅ | n/a | ✅ | ✅ | ✅ |
| Task 29 — collapse _performUpdate (Step 5-8) | settings_screen.dart | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Task 30 & 31 — store refactor brief | pdf_viewer_screen.dart (documents) | n/a | n/a | n/a | ❌ | ✅ | ❌ |

## Cards needing repair

These are the actionable defects — anchor partial/not_found, not unique, or `lowModelReady=false` (excluding the expected `new_file_ok`/`depends_on_prior_step` cards listed in the next section).

### 1. Task 1 — showDialog barrier in main.dart (Step 16/17) — `main.dart` lines 878–885
**Problem:** Anchor is verbatim-correct against pristine source, but the inner line 882 `onUpdate: () => _performUpdate(ctx, updateService, updateInfo),` is the same line **Task 29 Step 2 rewrites** to `performUpdate(ctx, updateInfo)`. If Task 29 runs first, this exact anchor no longer byte-matches and a literal replace fails (not_found). The card's own Step 17 note ("keep whichever call form is present; only add the `barrierDismissible:` line") requires judgment a weak model lacks.
**Fix:** Make ordering mechanical — instruct the low model to apply **Task 1 Step 16/17 BEFORE Task 29**. OR supply two variant anchors, each with its own exact replacement: (a) the pristine block containing `_performUpdate(ctx, updateService, updateInfo)`, and (b) the post-Task-29 block containing `performUpdate(ctx, updateInfo)`, with an instruction to match whichever is present.

### 2. Task 4 — overwrite-import temp-then-swap (Step 2) — `all_documents_screen.dart` lines 756–796
**Problem:** Step 1 anchor matches verbatim and is unique. But Step 2's replacement calls `docService.renameItem(result.importItem!.id, targetName)`, and Step 3 plus the handbook note (line 824) state **no `renameItem` API was confirmed to exist** in document_service.dart. A weak model cannot choose between the temp-then-rename path and the fallback path. If it blindly applies Step 2, the code will not compile (undefined method `renameItem`).
**Fix:** Resolve the rename ambiguity for the implementer. Either (a) inline-confirm the real DocumentService rename API name/signature and hard-code it into the Step 2 block, OR (b) make Step 2 the no-rename fallback variant (`importName = targetName`; `allowDuplicate: true`; delete `existingId` on success) so it compiles with no `renameItem` call, and demote the temp-then-rename version to an optional note.

### 3. Task 13a — empty-but-checked ZIP password (Step 1/2) — `document_dashboard_screen.dart` lines 460 AND 1288
**Problem:** The card claims the anchor (`// Use password only if encrypt checked` + `final zipPassword = encrypt ? password : null;`) is **unique. It is NOT** — it appears twice (line 460 in `_exportSelectedItems`/bulk export, line 1288 in `_exportFolderAsZip`/folder export), byte-identical. A single string-replace will either fail (requires replace_all) or fix only one export path, leaving the stated goal (both dialogs) half-done.
**Fix:** Correct the card: remove the "(it is unique)" claim and state the anchor occurs at **lines 460 and 1288**. Instruct the implementer to apply the replacement to **BOTH** occurrences (replace_all, or two separate edits).

### 4. Task 15 — read-both dispatcher + AES-256-GCM — `encryption_service.dart` (partial anchor)
**Problem:** Multiple blockers. (a) Step 2 Locate uses placeholder comments (`// ... XOR loop + base64Encode ...`) instead of the real bodies at lines 89–141 — not string-matchable. (b) Step 3 references `~:8-21` by line number only, no verbatim block. (c) New code references the secure-storage handle as `_storage` but the real field is `_secureStorage` (line 12) — every `_storage` reference fails to compile. (d) New code uses `sha256.convert(...)` from the `crypto` package, which is never imported and never instructed to be added. (e) `_encryptXorLegacy`/`_decryptXorLegacy` have no verbatim bodies. Self-labeled "Low-model-safe: No (senior review)".
**Fix:** Replace Step 2 Locate with the EXACT current bodies of `encrypt()`/`decrypt()` (lines 89–141). Provide verbatim `_encryptXorLegacy`/`_decryptXorLegacy` bodies. Rename every `_storage` → `_secureStorage` in new code. Add an explicit `package:crypto/crypto.dart` import + pubspec dep (or drop sha256). Provide a verbatim anchor for Step 3 (e.g. lines 17–21 insertion point) and verbatim main.dart code for Step 4. Otherwise keep it senior-only.

### 5. Task 15/16 — prime AES key (Step 4) — `main.dart` (not_found)
**Problem:** Step 4 is PROSE only — no Locate block for main.dart. It also requires adding a new method to encryption_service.dart described only parenthetically. Worse, `_primeAesKey` has a leading underscore (PRIVATE in Dart) yet is called cross-file as `EncryptionService()._primeAesKey()` — this **will not compile**.
**Fix:** Add an explicit Locate block quoting the exact insertion anchor in `_performStartupChecks` (e.g. the `if (!success) { return; } }` lines around 820–833) and a Change block inserting `await EncryptionService().primeAesKey();` right after. **Rename the method to public `primeAesKey()`** (no underscore) since it is invoked cross-file, and provide its verbatim body in encryption_service.dart. Until then, not low-model-safe.

### 6. Task 16 — passphrase Backup/Restore (Step 4 AppBar) — `password_manager_screen.dart` (not_found)
**Problem:** Step 4 is one sentence of prose ("'Backup'/'Restore' actions wired to a new PasswordBackupService"). No Locate block, no verbatim new code. The AppBar at lines 156–159 currently has only a title and no `actions:` list, so a weak model would have to author the actions array and handlers from scratch. The bulk of the card is a brand-new service file + Argon2id crypto. Self-labeled "Low-model-safe: No (senior review)".
**Fix:** Do not give to a low model. If a concrete AppBar card is needed, anchor on lines 156–159 (the AppBar with only `title: const Text('Password Manager'),`) and supply the exact `actions: [ IconButton(... Backup), IconButton(... Restore) ]` replacement plus handler bodies. Keep the core service + crypto as senior work.

### 7. Task 17 — SmartOpen CAS write-back — `document_dashboard_screen.dart` (partial, ~lines 1766–1785)
**Problem:** The card provides **no verbatim Locate/Change block** for this file. Step 2 only says in prose: "Call it [updatePasswordValueCas] from the SmartOpen loop after a successful decrypt." The real loop is at lines 1774–1785 but is never quoted. Self-labeled "Low-model-safe: No (senior review)" — a design directive, not a string-replace card.
**Fix:** If it must be low-model-applicable, add a Step-Locate quoting lines 1774–1785 verbatim (`for (final p in passwords) { final decrypted = await encryption.decrypt(p.encryptedValue); ... }`) and a Step-Change showing exactly where/how to call `storage.updatePasswordValueCas(...)` after the successful verify branch. Otherwise keep it flagged "senior review" and exclude it from the low-model batch.

### 8. Task 19 — verifyPin rehash (Step 1) — `settings_service.dart` (not_found)
**Problem:** The Step 1 block is the DESIRED replacement body, not a verbatim Locate anchor — there is nothing to string-match. The current `verifyPin` (lines 229–239) is try/catch wrapped, reads `storedPin`, returns `storedPin == pin`; the card's block has a totally different shape (`pin:v2:` branch). It relies on helpers/imports that do not exist in the file: `_pbkdf2`, `_constantTimeEq`, `_rng`, `base64Decode`/`base64Encode` (no `dart:convert` import), `dart:math` `Random.secure`. Uses `<build-baked-random>` placeholders. **CONFLICT:** rewrites verifyPin/setPin to `pin:v2:`, destroying the verbatim anchors Task 24 Steps 3 & 5 depend on. Self-labeled "Low-model-safe: No (senior review)", "Risk: high (PIN)".
**Fix:** Do not let a low model execute this. If automation is required: convert Step 1 to an explicit Locate (exact current verifyPin lines 229–239) + full Change block; add verbatim `_pbkdf2`/`_constantTimeEq`/`_rng` implementations with insertion anchors and the required `dart:convert`/`dart:math` imports; replace `<build-baked-random>`/`<sha256...>` placeholders with concrete values; and sequence relative to Task 24 (one card must own the verifyPin/setPin edits).

### 9. Task 19 — dev gate hash (Step 2) — `encryption_service.dart` line 20
**Problem:** The Step 2 anchor `static const String _developerPassword = 'Portal123!';` matches verbatim and is unique — but the replacement uses `sha256.convert(...)` (crypto package, not imported, never instructed) and references `_constantTimeEq(...)` which does not exist in EncryptionService and has no body supplied for this file. `_devSalt`/`_devHash` are `<build-baked-random>` placeholders the model cannot compute. Step 3 ("hide raw key" / downgrade `getEncryptionKey` to bool) is prose-only with no Locate block and would break callers.
**Fix:** Add an explicit "add `package:crypto/crypto.dart` import + crypto to pubspec" instruction. Provide a verbatim `_constantTimeEq` body inside EncryptionService (or reference where it is added). Replace the placeholders with a concrete generation procedure or move secret-baking out of the low-model path. For Step 3, add the verbatim current `getEncryptionKey` block (lines 56–70) as the Locate anchor plus the exact bool-returning replacement, and enumerate caller updates.

### 10. Task 19 — dev screen / zip pw (Step 3/4) — `developer_screen.dart` (not_found)
**Problem:** Touches developer_screen.dart (Step 3) and export_queue_service.dart (Step 4) with **no Locate code** for either — prose with approximate hints (`:36-65`, `:41`, `:76`, `:91/:502`). No verbatim new code. Downgrading `getEncryptionKey` to bool would break its caller at line 41 (judgment). Self-labeled "Low-model-safe: No (senior review)".
**Fix:** Do not hand to a low model. If a concrete card is needed: Step 3 anchor = developer_screen.dart lines 39–65 (the `if (isSet) { final key = await _encryptionService.getEncryptionKey('Portal123!'); ... SelectableText(key,...) }` block) replaced with a non-reversible "Key configured" AlertDialog; reconcile the `getEncryptionKey`→bool signature change with its only caller at line 41.

### 11. Task 19 — zip-password impact (Step 4) — `export_queue_service.dart` (not_found)
**Problem:** Step 4 directs changes (stop serializing `'zip_password'` plaintext, encrypt/decrypt at consume, NULL after `_encodeArchive`) with **no Locate/Change blocks** — prose only, and the line hints are slightly off: `toJson` serializes at **line 77** (not :76); `_encodeArchive` is at **line 543**, the `compute()` call at **line 502**. Self-labeled "Low-model-safe: No (senior review)".
**Fix:** If a weak model must execute it, author explicit Locate/Change cards: anchor for `toJson` at line 77 (`'zip_password': zipPassword,`), `fromJson` at line 91 (`zipPassword: json['zip_password']`), and the post-encode NULL write near lines 520–526 in `_processZipJob`. Otherwise keep as senior work.

### 12. Task 25 — hash PIN/dev pw (settings ref) — `settings_screen.dart` line 190 (partial)
**Problem:** Task 25 lists settings_screen.dart (~:190) and Step 2 says "Point the inline literal compares at verifyDeveloperPassword" but provides **no verbatim Locate block** and no replacement text. The real code at line 190 is `if (controller.text == 'Portal123!') {` (unique). A weak model cannot string-match/replace it and must synthesize the new call and figure out which object exposes `verifyDeveloperPassword`.
**Fix:** Add an explicit Step with a verbatim Locate block `if (controller.text == 'Portal123!') {` (line 190, unique) and a verbatim Change block, e.g. `if (settings.verifyDeveloperPassword(controller.text)) {` — and state which object exposes `verifyDeveloperPassword` (the SettingsService `settings` param, via the already-present import) and that the developer-mode flow stays intact.

### 13. Task 27 — ZIP export remove-password — `export_queue_service.dart` (matched but lowModelReady=false)
**Problem:** All Locate blocks byte-match and are unique, BUT Step 13 new code calls `_pdfPasswords.getPasswordForDocument(...)` — `getPasswordForDocument` lives in pdf_password_service.dart (not an assigned file) and is unverified; if its name/signature differs, Step 13 will not compile. Step 11 import requires `pdf_password_service.dart` to exist in lib/services/ (unverified). Self-labeled "Low-model-safe: No (senior review)". (Note: Step 16's anchor depends on Step 2 having added the `removePasswords` field — apply in order; not a defect.)
**Fix:** Before applying, verify `lib/services/pdf_password_service.dart` exists and exposes `Future<String?> getPasswordForDocument(String path)`. If the name/signature differs, update Step 13's call accordingly. Treat Step 16 as depending on Step 2 (apply in order).

## Expected non-matches (not errors)

These cards do not match a pristine anchor by design. They are correctly flagged and should be **sequenced or excluded**, not "repaired":

- **Task 30 & 31 — store refactor + architecture cleanup (PROJECT BRIEF)** — `pdf_viewer_screen.dart` (documents). `anchorStatus = new_file_ok`: intentionally a scoping/senior-review brief with no Locate block, no new code, and no test steps — nothing for a low model to string-match. Ensure the orchestrator does **not** route it to the low-capability model (the card already says "senior review").

- **Task 17 — legacy verify + compare-and-swap** — `encryption_service.dart`. `anchorStatus = depends_on_prior_step`: adds `migrateValue`/`isLegacy` that reference symbols (`_tagV2`, `_decryptXorLegacy`, `_encryptXorLegacy`, v2 `encrypt()`, `legacyKeyHealthy()`) introduced by **Task 15**. Cannot match or compile standalone — **Task 15 must land first**. Senior review.

- **Task 17 — PdfPasswordService side** — `pdf_password_service.dart`. `anchorStatus = depends_on_prior_step`: adds `migrateValuesToV2()` which depends on `migrateValue` from the Task 15/17 EncryptionService work that does not yet exist in the pristine file. Prose-only spec, no Locate block, no lock primitive named. Senior review; sequence after Task 15.

(One additional in-sequence dependency worth noting, though its anchor still matched pristine: **Task 27 Step 16** on export_queue_service.dart only matches *after* Step 2 inserts the `removePasswords` field — apply steps in order.)