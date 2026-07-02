# PDF Password Manager — Ordered Fix & Feature Roadmap

> The execution order for everything in `pdf-password-manager-observed-bugs-and-requests.md` (identified issues) **plus** the 5 owner-requested items (1 bug + 4 features).
> Sequenced for a **LIVE app with real users and many saved passwords** — so order is driven by *harm being done now*, *dependencies*, and *data-safety*, not just severity.
> Planning only — no code is changed by this document.

---

## Ordering rules (why this sequence)

1. **Stop active harm first.** Bugs that *currently* lose user data, crash/brick the app, or expose a remote exploit come before everything else.
2. **Safe & additive before destructive.** Ship changes that can't hurt existing data first; anything that re-writes stored data (the crypto migration) is phased with *verify-before-overwrite*.
3. **Respect dependencies.** Some fixes must precede others (e.g. read-both crypto before any AES write; a portable backup before the migration sweep; PDF-tools fidelity before the "remove password on export" feature).
4. **Big refactors last.** The architectural rewrites (collapsing the two stores) are highest-risk and subsume several smaller bugs — don't micro-patch what the refactor replaces.
5. **Hygiene is a continuous track.** Code smells, `mounted` guards, dead code, and deprecated APIs get cleaned up *as each file is touched*, not as a separate big-bang.

**Effort key:** S = small (hours), M = medium (1–3 days), L = large (multi-day/refactor).

---

## Master sequence at a glance

| # | Item | Type | Effort | Depends on |
|---|---|---|---|---|
| 1 | Harden self-update (sign + checksum + TLS pin) | 🔴 Security (RCE) | M | — |
| 2 | Stop library-blanking on one bad record | 🟠 Data-loss | S | — |
| 3 | Stop device-scan wiping curated metadata | 🟠 Data-loss | M | — |
| 4 | Overwrite-import: temp-then-swap | 🟠 Data-loss | S | — |
| 5 | Guard `deleteFromDevice` (don't delete originals) | 🟠 Data-loss | S | — |
| 6 | `IF NOT EXISTS` on migration DDL (un-brick DB) | 🟡 Crash | S | — |
| 7 | Cycle check before folder move | 🟡 Crash | S | — |
| 8 | `firstWhere` → add `orElse` (several sites) | 🟡 Crash | S | — |
| 9 | `substring`/stuck-loading guards (try/finally) | 🟡 Crash | S | — |
| 10 | **Bug 1 — "Open With" stale document** | 🔴 Bug (reported) | S | — |
| 11 | **Feature 3 — Share icon in All-Docs viewer** | 🟢 Feature | S | — |
| 12 | **Feature 4 — File info in 3-dots menu** | 🟢 Feature | S | — |
| 13 | Small correctness batch (No-Password, APK cleanup, empty-zip-pw, folder-count cache) | 🔵 Correctness | S | — |
| 14 | Begin hygiene track (`mounted` guards, UI-thread I/O) | 🟡 Stability | M (incremental) | — |
| 15 | Crypto 2a — read-both dispatcher + AES write + key-health token | 🔴 Security | M | — |
| 16 | **Feature 5 — Password Backup/Restore (passphrase)** + backup-exclusion rules | 🟢 Feature + Security | M–L | 15 |
| 17 | Crypto 2c — lazy migrate-on-read (legacy-side verify + CAS) | 🔴 Security | M | 15, 16 |
| 18 | Crypto 2d — background sweep (staged, key-health-gated) | 🔴 Security | M | 16, 17 |
| 19 | Crypto 2e — PIN salted-hash + real lockout, dev-gate hash, hide raw key, zip-pw | 🔴 Security | M | 15 |
| 20 | Biometric: `biometricOnly: true` | 🔴 Security | S | — |
| 21 | Auto-lock: compare seconds + drop `ignoreNextPause` one-shot | 🔴 Security | S | — |
| 22 | Re-auth before opening a protected document | 🟠 Security | S | 19 |
| 23 | SQL-identifier whitelist in generic DB helpers | 🟠 Security | S | — |
| 24 | Redact PII/secrets from logs | 🟠 Security | S | — |
| 25 | Scope storage perms / drop `MANAGE_EXTERNAL_STORAGE` | 🟠 Security | M | — |
| 26 | PDF-tools fidelity: page-import (no flatten) + try/finally dispose + `isProtected` fix | 🟠 Data-loss/Crash | M | — |
| 27 | **Feature 2 — "Remove password from PDFs" on ZIP export** | 🟢 Feature | M | 26, 15 |
| 28 | Delete dead duplicate `PdfViewerScreen` stub | ⚪ Arch/Smell | S | — |
| 29 | Collapse triplicated `_performUpdate` | ⚪ Arch | S | 1 |
| 30 | **Refactor: collapse the two stores onto SQLite** (subsumes parent-model, ID-collision, size-dedup) | ⚪ Arch | L | most prior |
| 31 | Remaining arch cleanup (AppConstants, global statics, Provider/UpdateService, dup search, trigram) | ⚪ Arch | M | 30 |
| ∞ | Continuous hygiene (dispose controllers, dead code, deprecated APIs, correctness long-tail) | 🔵/⚪ | ongoing | — |

---

## Phase 0 — Stop the bleeding (ship first, safe & additive)

These are actively hurting users *now* and are localized, low-risk fixes. None require a data migration.

**1. Harden the self-update path** — 🔴 RCE — `update_service.dart:15,157-170`
Add a manifest-supplied SHA-256 + signing-cert check before install, TLS certificate pinning, and a download-host allow-list (block cross-origin redirects). *Why first:* it's the only remotely-exploitable issue, and shipping it sooner means the hardened updater propagates to clients before any future malicious manifest could be served. Additive — touches no user data.

**2. Stop the library being blanked by one bad record** — 🟠 Data-loss — `document_service.dart:901-903`
Decode the JSON *before* `clear()`, and wrap per-record parsing in try/catch so one corrupt entry can't null the whole library (which then gets saved back as `[]`). Tiny change, prevents catastrophic loss.

**3. Stop the device scan wiping curated metadata** — 🟠 Data-loss — `device_document_service.dart:163-176,228-232`
Use `COALESCE`/targeted `UPDATE` instead of `ConflictAlgorithm.replace`, and scope the mark-and-sweep to `is_imported = 0`, so `is_new` / `is_imported` / `added_at` / `missing_on_device` survive a scan. Today imports and "NEW" badges are destroyed on *every* sync.

**4. Overwrite-import → temp-then-swap** — 🟠 Data-loss — `all_documents_screen.dart:758-769`
Import to a temp path and atomically swap; never delete the original before the replacement is confirmed written.

**5. Guard `deleteFromDevice`** — 🟠 Data-loss — `document_service.dart:838,854`
Confirm caller intent before this deletes the user's *original* source file (zero-copy means it points at real user files).

**6. `IF NOT EXISTS` on migration DDL** — 🟡 Crash — `storage_service.dart:156,195,209-223`
Prevents a partially-migrated DB from aborting the upgrade and **bricking all DB access**. One-line-per-statement, huge blast-radius reduction.

**7. Cycle check before folder move** — 🟡 Crash — `document_service.dart:708,742,844`
Reject moving a folder into its own descendant → stops infinite recursion / stack overflow.

**8. `firstWhere` → `orElse`/`firstOrNull`** — 🟡 Crash — `document_dashboard_screen.dart:1390,1463`, `document_service.dart:450`, `export_queue_service.dart:96`
Prevents `StateError` aborting whole operations when an item is deleted/changed concurrently.

**9. `substring` + stuck-loading guards** — 🟡 Crash — `document_dashboard_screen.dart:251,3267`, `all_documents_screen.dart:216`
Guard `parts.length>1`; wrap loops in try/finally so `_isLoading`/`_isLoadingMore` can't stick (spinner-forever).

**10. Bug 1 — "Open With" reopens the previous document** — 🔴 Reported bug — `main.dart:703-715,654-700`
Add a one-shot `_initialIntentConsumed` guard so the resume handler stops re-reading the stale launch intent via `getInitialMedia()`; the stream is authoritative for hot intents. Reset native media immediately on consume. *High visibility, isolated to `main.dart`.*

---

## Phase 1 — Quick wins (features + small correctness)

Low effort, high visibility, no data risk.

**11. Feature 3 — Share icon in the All-Docs-opened viewer** — 🟢 — `all_documents_screen.dart`, `pdf_viewer_screen.dart`
Surface the viewer's existing share action (or pass the enabling flag) so files opened from All Docs can be shared like "Open With" files.

**12. Feature 4 — "File info" in the PDF 3-dots menu** — 🟢 — `pdf_viewer_screen.dart`, `file_info_screen.dart`
Add a `PopupMenuItem` that opens the existing `FileInfoScreen`; handle the external-open case where no `DocumentItem` exists (construct one from `File` stat).

**13. Small correctness batch** — 🔵 — various
- "No Password" choice should open with empty password, not cancel the viewer (`pdf_viewer_screen.dart:170,177`).
- `cleanupUpdateFile` should glob `update_*.apk`, not the never-written `update.apk` (`update_service.dart:196`).
- Treat empty-but-checked ZIP password as no-password (`document_dashboard_screen.dart:1289`).
- Invalidate `_folderCountCache` on mutate + key it by filter (`document_dashboard_screen.dart:343,2386,2599`).

**14. Begin the hygiene track** — 🟡 — systemic
Start adding `if (!mounted) return;` after awaits and moving `statSync`/`lengthSync`/`existsSync` off the UI thread, file-by-file as you touch them. (Runs continuously through all later phases.)

---

## Phase 2 — The crypto migration (phased; the big security track)

> This is the bundled "AES-GCM + salted PIN/dev-gate + hide raw key" fix. For a live app it **must** be phased with *verify-before-overwrite*; the steps below are the data-safe order. See the migration playbook for the full design + the data-loss safeguards. **The single inviolable rule: never delete a legacy value until its AES replacement is proven to decrypt back to the exact original (verified on the legacy XOR side).**

**15. 2a — Read-both + AES write + key-health token** — 🔴 — `encryption_service.dart:100-136`
Tag stored values (`v2:` = AES-GCM; untagged = legacy XOR); `decrypt()` routes by tag so existing passwords work **day one**. New writes emit AES. Generate the AES key once at single-threaded startup (Keystore-backed `aes_key_v2`, leaving the old `encryption_key` read-only). Store a key-health check-token. *Purely additive — ship and let it saturate before any writes flip behavior.*

**16. Feature 5 — Password Backup/Restore (passphrase) + backup-exclusion rules** — 🟢+🔴 — `password_manager_screen.dart`, new `PasswordBackupService`, `AndroidManifest.xml`
Argon2id-passphrase-wrapped export/import (so a backup is *portable* and survives a wiped Keystore), with the no-secret duplicate table (backup-name vs local-name, never the value). Add `dataExtractionRules`/`fullBackupContent` to exclude the encrypted blob from Auto Backup. **Must ship before the sweep (step 18)** — otherwise a fully-migrated user who changes device loses everything.

**17. 2c — Lazy migrate-on-read** — 🔴 — `add_password_dialog.dart:66-95`, `document_dashboard_screen.dart:1766-1785`, `pdf_password_service.dart:79-84`
On each successful decrypt, re-encrypt to AES and write back — but only after a **legacy-side round-trip proof** (`xorEncrypt(decrypt(x)) == x`) and via compare-and-swap (`UPDATE … WHERE encrypted_value = <old>`). Migrate the prefs map *through* `PdfPasswordService`'s in-memory map (single writer), never raw prefs.

**18. 2d — Background sweep** — 🔴 — new `migration_service.dart`, after `main.dart:820-833`
One-time, idempotent, resumable, key-health-gated sweep of both stores for values the user never opens. Staged 1%→10%→50%→100%. Completion flag set only when fully drained.

**19. 2e — PIN + dev-gate + raw-key + zip-password** — 🔴 — `settings_service.dart:209,231-232`, `encryption_service.dart:20,57,74`, `developer_screen.dart:36-65`, `export_queue_service.dart:76`
- PIN: salted PBKDF2/Argon2 hash, rehash **lazily on next correct unlock** (plaintext in hand, verified), constant-time compare, namespaced `pin:v2:` tag — verify before discarding plaintext.
- Dev gate: replace `Portal123!` with a salted hash (or compile the dev screen out of release via `--dart-define`).
- Stop displaying the raw key (show "configured ✓").
- ZIP password: stop persisting plaintext — keep in memory / AES it if the queue must survive restart; null after use.

---

## Phase 3 — Remaining security hardening (mostly independent, medium)

**20.** Biometric: set `biometricOnly: true` so the device credential can't bypass the app PIN — `biometric_service.dart:62`.
**21.** Auto-lock: compare `inSeconds >= timeout*60` and drop the global `ignoreNextPause` one-shot (scope the picker exemption with an expiry) — `main.dart:644-650,665`.
**22.** Require re-auth before opening a protected document / recent-docs deep link (depends on the real PIN from step 19).
**23.** SQL-identifier whitelist inside `getTableData/updateRecord/deleteRecord` — `storage_service.dart:515-527`.
**24.** Redact PII/secrets (PIN lifecycle, paths) from the `logs` table — `settings_service.dart`, `logging_service.dart`.
**25.** Scope storage permissions / drop `MANAGE_EXTERNAL_STORAGE` (Play-policy sensitive) — `permission_service.dart:23`.

---

## Phase 4 — PDF-tools fidelity, then the export feature

**26. PDF-tools hardening** — 🟠 — `pdf_tools_service.dart:20-217,289-307`
Switch from `createTemplate`/`drawPdfTemplate` (which silently flattens forms/annotations/signatures/bookmarks) to page-import; wrap every op in try/finally to dispose `PdfDocument` (native-handle leak); fix the 2 KB `isProtected` sniff with a Syncfusion fallback. *Do this before Feature 2 so exported decrypted PDFs aren't degraded.*

**27. Feature 2 — "Remove password from PDFs" on ZIP export** — 🟢 — `export_queue_service.dart`, dashboard export dialog
Checkbox threads a `removePasswords` flag → for each protected PDF, fetch stored password (`getPasswordForDocument`, now dual-read), `removePassword` to a **temp** file on the main side (decryption must happen *before* the `compute` isolate hop), add the temp bytes to the archive, clean up; originals stay protected. Skip + report PDFs with no stored password.

---

## Phase 5 — Architectural refactors (largest, deliberately last)

**28.** Delete the dead duplicate `PdfViewerScreen` stub (`features/pdf_tools/screens/pdf_viewer_screen.dart`) — importing it silently breaks PDFs.
**29.** Collapse the triplicated `_performUpdate` (update_dialogs / main / settings) into one implementation.
**30. Collapse the two persistence stores onto SQLite** — the big one. Move the library off the `shared_preferences` JSON blob into transactional SQLite. This **subsumes** several earlier bugs: the dual `parentId`/`fileIds` model, `millisecondsSinceEpoch` ID collisions, whole-blob last-writer-wins races, and lets you add content-hash dedup (replacing size-only). Do it after the app is otherwise stable.
**31.** Remaining cleanup: fix `AppConstants` drift, reduce the global-statics router, make `UpdateService` a real singleton (red-dot desync), unify the two search implementations, resolve the trigram create/drop divergence.

---

## Continuous track — hygiene (alongside every phase)

- **Dispose** `TextEditingController`s and the export notification `StreamController` (`document_dashboard_screen.dart:1901`, `developer_screen.dart:68,267,641,754`, `export_queue_service.dart:238`).
- **Remove dead code**: `existingFiles` prefetch, dead `initialize()`, the deliberation comment block, side-effecting getter, dead `AppTheme`/`AppBottomNavBar`/`AppLogo`, dead `recent_documents`, orphaned `debug_logs_screen.dart`.
- **Deprecated APIs**: `withOpacity`, `WillPopScope`, `onPopInvoked`, `MaterialStateProperty`, `surfaceVariant`.
- **Correctness long-tail** (fold in when touching the file): search `.take(100)` before paging, stale `_cachedPaths`, hardcoded `/storage/emulated/0`, log ordering by TEXT timestamp, dev-tools `idColumn='id'` wrong for `files_index`, double-reverse log sort, level-icon mismatch, search request-id race, two-path password-key mismatch.

---

## Critical-path callouts (don't violate these)

- **Self-update (1) early** — so the verified updater is in the field before anything else.
- **Crypto: read-both (15) → backup (16) → lazy (17) → sweep (18).** Never enable AES *writes* until read-capable binaries are saturated; never run the sweep before the passphrase backup exists.
- **Verify on the legacy side before overwriting** — AES round-tripping its own output proves nothing; XOR has no integrity, so a wrong-key decrypt yields *valid-looking garbage*.
- **Key-health gate** — if the Keystore key is missing/wrong (device restore, `allowBackup`), halt migration and route to passphrase restore; never let a bad key drive a write.
- **PDF-tools fidelity (26) before export-remove-password (27).**
- **Don't micro-patch (30)'s territory** — the parent-model/ID-collision/dedup bugs are fixed *by* the store refactor; patch them only if (30) is deferred.

---

### Source
Derived from `pdf-password-manager-observed-bugs-and-requests.md` (master issues + the 5 requests) and `CODEBASE_DEEP_DIVE.md`. Identification & planning only — no application code changed.
