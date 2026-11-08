# Local On-Device AI Feature — Audit, Locked Decisions & Implementation Plan

**Project:** PDF Password Manager (`passwordpdf_manager`, package `com.passwordpdf.passwordpdf_manager`)
**Branch:** `experimental_flutter_upgrade`
**Build:** v1.2.10+146 (live)
**Date:** 2026-11-08
**Status:** Audit verified against source. Decisions locked. **No code changes made yet.**
**Scope of this document:** (1) verified audit of the local AI feature, (2) locked product decisions for hiding it, (3) detailed implementation plan, (4) root-cause analysis of the PDF save-flow regression, (5) fix plan for the save flow.

---

## 0. Executive Summary

1. **The local AI is real, complete, and currently visible.** It is a zero-bundled-weights, on-demand GGUF download RAG chat over PDFs, running fully offline via `flutter_llama` (llama.cpp). It is exposed through a bottom-nav tab, folder buttons, a folder context-menu item, and one Settings toggle.
2. **Product decision:** the feature is **Alpha**, not Beta. It must be **hidden from every user, including developers**, while **keeping all code in the repo**. The mechanism chosen is a single compile-time flag (`kAiFeatureEnabled = false`), not deletions.
3. **The PDF save flow is broken by a regression, not by design.** The save button is gated behind `if (widget.isExternal)`, and the only call site that ever passed `isExternal: true` was removed in commit `c5da6e2` (2026-08-30). Since then the save flow is unreachable dead code.
4. **Two load-bearing security gaps remain in the AI code** (placeholder SHA-256 values + no post-download hash verification). They are out of scope for the hide work but must be fixed before the feature is ever re-enabled.
5. **A second regression was found in the same commit:** `deleteOnClose` was also dropped, so temp copies of shared files are never deleted. See §9.4.
6. **The "per-download approval" dialog is dead code** — `AiModelApprovalDialog` is never imported or shown. See §5.3 item 9.

### Locked decisions (from product review)

| # | Question | Decision | Meaning |
|---|---|---|---|
| 1 | Hide mechanism | **B** | Single `const kAiFeatureEnabled = false` flag wrapping every entry point. Code stays; one-line re-enable later. |
| 2 | Hide depth | **B** | UI hidden **and** background auto-indexing stopped **and** AI notification wiring skipped. `flutter_llama` stays in `pubspec.yaml`. |
| 3 | Settings "AI Vault Password Access" toggle | **A** | Remove it from Settings → Security. |
| 4 | Existing AI data on devices | **A** | Leave `ai_*` tables and `ai_models/` untouched. No migration/purge in this change. |
| 5 | PDF save entry point | **B** | Add "Save File" to the PDF overflow menu, mirroring Word/Excel. Keep the AppBar icon for external files only. |
| 6 | "Save to App Library" for library PDFs | **B** | Relabel to **"Save a Copy to App Library"**; keep both options. |
| 7 | Save flow for password-protected PDFs | **A** | Available like any other PDF (the save path operates on the file, not the decrypted buffer). |

---

## 1. AI Feature Location Map (Verified)

### 1.1 Entry points (currently VISIBLE in the UI)

| Location | File:Line | Description |
|---|---|---|
| Bottom nav tab | `lib/main.dart:1164-1174` | `AI` destination at **index 2 of 4** (3rd item), Gemini-style sparkle icon + "BETA" badge |
| IndexedStack child | `lib/main.dart:1137` | `const AiStudioScreen()` |
| Tab-active notifier | `lib/main.dart:1148` (and `869` on resume) | `AiStudioScreen.isAiTabActive.value = (index == 2)` |
| Folder chat button | `lib/features/documents/screens/document_dashboard_screen.dart:2031-2043` | Sparkle `IconButton` in folder AppBar → `AiStudioScreen(initialFolderId: …)` |
| Folder context menu | `lib/features/documents/screens/document_dashboard_screen.dart:2810-2818` + `2871-2878` | "Chat with AI" popup item → `AiStudioScreen` |
| Settings toggle | `lib/features/settings/screens/settings_screen.dart:935-943` | "AI Vault Password Access" switch (Security section) |
| Notification wiring | `lib/main.dart:19, 138-143` | `open_ai_chat:` payload → `MainScreen(initialIndex: 2)` + `AiNotificationService` |
| Silent auto-index | `lib/features/documents/screens/pdf_viewer_screen.dart:581-589` | `PdfIndexingCoordinator().indexPdfDocument(...)` on every PDF open |
| Developer-only AI screens | `lib/features/ai/screens/ai_studio_screen.dart:1078-1079, 1578, 1587` | `AiPromptManagementScreen` + `AiDiagnosticsScreen` — **only reachable from inside `AiStudioScreen`** |

> **Important for "hide even from developer":** there is no separate developer entry point for the AI screens. They are launched exclusively from the AI Studio. Hiding the Studio makes them unreachable automatically; no extra developer gate is needed.

### 1.2 AI screen code

| File | Lines | Role |
|---|---|---|
| `lib/features/ai/screens/ai_studio_screen.dart` | 1,651 | ChatGPT-style multi-doc chat: sessions, attachments, RAG answering, citations, vault password consent |
| `lib/features/ai/screens/ai_diagnostics_screen.dart` | 1,678 | Developer debug view of query logs, FTS/vector matches, model prompts, storage stats |
| `lib/features/ai/screens/ai_prompt_management_screen.dart` | 692 | Master system prompt editing (dev-mode) |
| `lib/features/ai/widgets/ai_model_management_dialog.dart` | 850 | Model catalog, device hardware profiling, SHA-256 download, activate/delete |
| `lib/features/documents/widgets/ai_model_approval_dialog.dart` | 161 | Per-download user approval dialog (zero-bundled-LLM rule). **Corrected path** — it lives under `documents/widgets`, not `ai/widgets`. |
| `lib/features/ai/widgets/ai_sparkle_icon.dart` | 97 | Gemini-style vector sparkle icon |
| `lib/features/ai/widgets/app_library_pdf_picker.dart` | 258 | "Attach from App Library" picker mirroring the folder hierarchy |

### 1.3 AI service code (backend)

| File | Lines | Role |
|---|---|---|
| `lib/services/ai/multi_pdf_rag_service.dart` | 756 | RAG answering: greeting/meta handling, keyword expansion, profile-query header pinning, FTS5 + vector hybrid search, prompt building, LLM fallback → extractive answer, citation resolution |
| `lib/services/ai/local_llm_inference_service.dart` | 199 | `flutter_llama` runtime: model loading (`LlamaConfig` CPU-safe), concurrency lock, caching, 128-token mobile generation |
| `lib/services/ai/pdf_indexing_coordinator.dart` | 369 | Text extraction in visual order, line-join normalization, 500-char whitespace-snapped chunks, deterministic 128-d subword embedding, FTS5 + embedding writes |
| `lib/services/ai/hybrid_search_service.dart` | 192 | Reciprocal Rank Fusion combining FTS5 lexical + cosine-sim vector search |
| `lib/services/ai/ai_model_manager_service.dart` | 339 | Catalog (Qwen 0.5B/1.5B, Gemma 2 2B/4B, EmbeddingGemma 300M, BGE Small 33M), SHA-256 verify, active-model selection, tier mapping |
| `lib/services/ai/device_capability_service.dart` | **113** | Device RAM/CPU profiling, recommended AI tier. *(Original audit said 3,283 — that was a byte count.)* |
| `lib/services/ai/ai_prompt_service.dart` | **266** | Master system prompt storage/versions. *(Original audit said 10,128 — byte count.)* |
| `lib/services/ai/ai_diagnostics_service.dart` | **331** | Query log persistence, storage diagnostics. *(Original audit said 13,136 — byte count.)* |
| `lib/services/ai/ai_diagnostics_export_service.dart` | **372** | Export AI logs to JSON/CSV/Markdown/DOCX. *(Original audit said 13,552 — byte count.)* |
| `lib/services/ai/ai_notification_service.dart` | 93 | Foreground/local notification when AI finishes analyzing |

---

## 2. The Local AI Pipeline (End-to-End Flow)

### Step 1 — Model download (user-consented, offline-after-download)
- Catalog of open-weights GGUF models hosted on Hugging Face (`Qwen/`, `bartowski/`, `unsloth/`, `CompendiumLabs/`).
- **Correction:** `AiModelApprovalDialog` is **dead code** — never imported or shown (`grep -rn "AiModelApprovalDialog" lib/` returns only its own file). Downloads are triggered directly from `ai_model_management_dialog.dart:173` after a "Step 1 Recommended First" info dialog (`127-152`), which is **not** an approval gate. The original audit's "per-download approval" claim is false.
- Downloaded to `<appDir>/ai_models/<model_id>.gguf`.
- `flutter_llama` loads into memory; CPU-only config (`useGpu: false`, `nThreads: 4`, `contextSize: 1536`, `batchSize: 256`).
- Only one inference runs at a time (`_synchronized` mutex, `local_llm_inference_service.dart:186-190`).

### Step 2 — Document indexing (automatic or on attach)
- Triggered automatically when a PDF opens (`pdf_viewer_screen.dart:581-589`).
- Also triggered when a PDF is attached in the AI Studio (`ai_studio_screen.dart:539-556`).
- Extracts text in visual reading order, normalizes lines, chunks at 500 chars (100 overlap, whitespace-bound), prepends filename/title hint on page 1.
- Writes to SQLite tables (see §4).

### Step 3 — Question answering (hybrid search + LLM)
- Greeting/meta detection answered without search.
- Keyword expansion (CGPA/GPA/name/identity patterns; profile-query header pinning).
- Hybrid search: FTS5 lexical OR-matched terms + cosine similarity on subword embeddings → RRF re-rank.
- Prompt construction: evidence chunks (≤3, ≤450 chars) into ChatML / Gemma / default template with master system prompt.
- LLM path: `generateCompletion` (128 tokens, temperature 0.1).
- Extractive fallback when no LLM is active or generation fails (hard-coded resume patterns — see §5.3 item 6).
- Citation resolution: parses `[Doc: X, Page N]`; citations render as clickable pills → jump to page.

### Step 4 — Vault password access (encrypted PDFs)
- `_resolvePasswordForDocument` (`ai_studio_screen.dart:574-693`):
  1. Try stored password for file path.
  2. Try `AI Vault Password Access` setting or per-session `has_vault_consent`.
  3. If no consent → one-time AlertDialog.
  4. If consent → try all `getAllUniquePasswords()` from vault, save on match.
  5. Else manual password entry.

### Step 5 — Folder chat
- `AiStudioScreen` with `initialFolderId` auto-attaches all PDFs in that folder at session start (`ai_studio_screen.dart:177-178, 247`), titled "Chat: <folderName>".

---

## 3. Where "Save to App Library / Device" Lives (PDF Screen)

The user-facing "Save File" action is `_handleSaveFile` in the PDF viewer:

| File | Line | Behavior |
|---|---|---|
| `lib/features/documents/screens/pdf_viewer_screen.dart` | `1304-1352` | `_handleSaveFile` → bottom sheet with two choices |
| — | `1324-1327` | **"Save to App Library"** → `_saveToLibrary` (duplicate check + folder selection + save-as-new-copy) |
| — | `1336-1339` | **"Save to Device Storage"** → `_saveToDevice` (`FileSystemBrowser` folder picker) |
| — | `1354` | `_saveToLibrary` implementation |
| — | `1419` | `_saveToDevice` implementation |

Same "Save File" bottom sheet exists on:
- `word_viewer_screen.dart:222` (`_handleSaveFile`), exposed via AppBar icon `455-470` and overflow menu `479, 517-523`.
- `excel_viewer_screen.dart:226` (`_handleSaveFile`), exposed via AppBar icon `636` and overflow menu `648, 677`.

> **Correction:** the original audit's §3 range `1270-1351` was off; `_handleSaveFile` starts at **1304**.

**Critical finding:** in the PDF viewer the save entry point is wrapped in `if (widget.isExternal)` (`pdf_viewer_screen.dart:326`), and **no call site in `lib/` passes `isExternal: true`**. The save flow is therefore unreachable. See §9 for the full regression history.

---

## 4. Database Schema for AI (SQLite Tables)

Defined in `lib/core/constants/app_constants.dart:20-29`:

```
ai_document_index       // document record (status, pages, size, mod time, index_version)
ai_document_pages       // per-page extracted text
ai_document_chunks      // chunk text, page, index, length, tokens
ai_chunk_embeddings     // chunk_id, doc_id, embedding_blob (float32 BE), dims, embedder
ai_chunks_fts           // FTS5 virtual table for lexical search
ai_installed_models     // model_id, display_name, model_type, file_path, size, sha256, is_active
ai_chat_sessions        // id, title, created/updated, attached_doc_ids (JSON), folder_id, has_vault_consent
ai_chat_messages        // session messages (user/ai, timestamp)
ai_system_prompts       // master prompt text + versions
ai_diagnostic_logs      // full query/post-mortem logs
```

AI tables are separate from the password/document vault tables. Indexed docs store **file paths**, not password bytes.

---

## 5. Verification Against Actual Code vs. Documentation

### 5.1 Confirmed matches with `MASTER_IMPLEMENTATION_REPORT.md`
- ✅ AI tab between Documents and Settings (index 2 of 4 — **3rd** item, not "4th").
- ✅ Chat history + sessions (`ai_chat_sessions` / `ai_chat_messages`).
- ✅ Multi-PDF attachment from App Library or Device Storage.
- ✅ Dynamic doc limits by model tier.
- ✅ One-time vault consent per chat + global `AI Vault Password Access` toggle.
- ✅ Clickable citations jumping to pages.
- ✅ Model manager with hardware profiling, SHA-256 download, activate/delete.
- ✅ Folder AI chatbot ("Chat with Folder" + "Chat with AI").

### 5.2 Settings → Security section (actual location)
- `settings_screen.dart:919-928` — "Screen Protection" (FLAG_SECURE).
- `settings_screen.dart:935-943` — "AI Vault Password Access" switch.
- `settings_screen.dart:1045-1053` — Developer section (hidden until unlocked).

### 5.3 Discrepancies / TODOs found in the code

| # | Location | Finding | Severity |
|---|---|---|---|
| 1 | `ai_model_manager_service.dart:66-139` | All `expectedSha256` catalog values are **placeholders** (`'mock_or_verified_sha256_…'`). Real Hugging Face checksums must be substituted before trusting verification. | High (trust/supply-chain) |
| 2 | `ai_model_manager_service.dart:211-249` | SHA-256 verification **is not performed** after download. The code stores `model.expectedSha256` into `ai_installed_models.sha256_hash` but never hashes the file or compares. The method doc-comment claims "with SHA-256 verification" — it is false. | High |
| 3 | `ai_prompt_service.dart` (266 lines) | Master prompt text needs review for hard-coded instructions. Dev-mode edit screen is gated by `developerModeEnabled`. | Low |
| 4 | `ai_diagnostics_export_service.dart` (372 lines) | DOCX export path uses a `.docx` placeholder filename — check export naming. | Low |
| 5 | `local_llm_inference_service.dart:64-71` | `LlamaConfig` is CPU-only; `contextSize: 1536` is modest for long documents; no eviction policy for low-RAM devices. | Medium |
| 6 | `multi_pdf_rag_service.dart:475-527` | Extractive fallback hard-codes resume-style patterns (CGPA, "Candidate Hint"). General-purpose QA degrades. | Medium |
| 7 | `app_library_pdf_picker.dart:71-87` | Only scans files via `DocumentService` (in-app library); device-scoped PDFs are not visible in the picker. | Low/UX |
| 8 | `ai_studio_screen.dart` chat UI | `_buildInputBar` / `_sendMessage` end (1452+) was **not fully read** in the original audit — treat as unverified, not "assumed functional". | Info |
| 9 | `lib/features/documents/widgets/ai_model_approval_dialog.dart` | **Dead code.** Never imported or shown anywhere. The zero-bundled-LLM "approval before download" flow does not exist; `downloadModel` is called directly from the model dialog. | Medium (trust/UX) |

**Recommendation:** items 1–2 are the only load-bearing security gaps. They are **out of scope** for the hide work but must be fixed before re-enabling the feature.

---

## 6. What Is Currently VISIBLE vs. GATED

### Visible to all users (no gating)
- ✅ AI bottom-nav tab (`main.dart:1164-1174`) with "BETA" badge.
- ✅ Folder "Chat with Folder (AI)" button + "Chat with AI" context menu.
- ✅ App Library PDF picker and Device Storage picker.
- ✅ AI Model Management dialog (from studio header chip + sessions drawer).
- ✅ Vault password consent flow.
- ✅ "AI Vault Password Access" toggle in Settings → Security.

### Gated behind Developer Mode
- ⚠️ Master System Prompt editor — only when `settings.developerModeEnabled`, and only reachable from inside `AiStudioScreen`.
- ⚠️ AI Logs & Diagnostics — same.

### Not visible anywhere
- Raw model files (`<appDir>/ai_models/*.gguf`) and the AI SQLite index are in app-private storage.
- No standalone "AI Settings" page.

---

## 7. Locked Decisions (Product Review)

| # | Decision | Implementation consequence |
|---|---|---|
| 1-B | Compile-time flag `kAiFeatureEnabled = false` | Add one const; wrap every entry point. No deletions of AI code. |
| 2-B | Hide UI + stop auto-indexing + skip notification wiring | Guard `pdf_viewer_screen.dart:581-589` and `main.dart:138-143`. Keep `flutter_llama` dependency. |
| 3-A | Remove "AI Vault Password Access" toggle | Remove/wrap `settings_screen.dart:935-943`. |
| 4-A | Leave existing AI data | No migration, no purge. `ai_*` tables and `ai_models/` remain on upgraded devices. |
| 5-B | Add "Save File" to PDF overflow menu | Mirror Word/Excel; keep AppBar icon for external files. |
| 6-B | Relabel to "Save a Copy to App Library" | String change in `_handleSaveFile`. |
| 7-A | Save flow works for password-protected PDFs | No password gate on save; operates on file path. |

---

## 8. AI Hide — Detailed Implementation Plan

> **No code has been changed. This is the plan to execute after approval.**

### 8.1 Add the flag

Create `lib/core/constants/feature_flags.dart`:

```dart
/// Alpha-stage local AI. Hidden from all users (including developers)
/// until the feature graduates. Flip to true to re-enable the UI.
const bool kAiFeatureEnabled = false;
```

Rationale: one source of truth, tree-shakeable, trivially reversible, and testable.

### 8.2 `lib/main.dart`

| Line | Current | Planned |
|---|---|---|
| `1137` | `const AiStudioScreen(),` | `if (kAiFeatureEnabled) const AiStudioScreen(),` |
| `1148` | `AiStudioScreen.isAiTabActive.value = (index == 2);` | `AiStudioScreen.isAiTabActive.value = kAiFeatureEnabled && (index == 2);` |
| `869` | `AiStudioScreen.isAiTabActive.value = (_currentIndex == 2);` | `AiStudioScreen.isAiTabActive.value = kAiFeatureEnabled && (_currentIndex == 2);` |
| `1164-1174` | AI `NavigationDestination` | Wrap in `if (kAiFeatureEnabled)` |
| `1065-1091` | `_handleAiStudioBack()` back handling | Guard with `if (kAiFeatureEnabled)` so back never targets a non-existent tab |
| `1083-1095` | `switch (_currentIndex)` maps case 2 → `_handleAiStudioBack`, case 3 → `_handleSettingsBack` | **Remap:** case 2 → `_handleSettingsBack`; remove the AI case. `_handleAiStudioBack` returns `false` and can remain as dead code. |
| `19, 138-143` | `open_ai_chat:` notification → `MainScreen(initialIndex: 2)` | Guard the whole branch with `if (kAiFeatureEnabled)`; otherwise index 2 now means Settings |

**Index mapping:** with the AI destination removed, the nav becomes 3 items — All Docs (0), Documents (1), Settings (2). Any code that assumes index 2 = AI must be updated (the notification branch and the back-handler switch above).

**`defaultScreenIndex` is safe:** `SettingsService.setDefaultScreenIndex` clamps to `0..1` (`settings_service.dart:458`), so the AI tab was never a default-screen option. No migration needed.

### 8.3 `lib/features/documents/screens/document_dashboard_screen.dart`

| Line | Planned |
|---|---|
| `2031-2043` | Wrap the folder sparkle `IconButton` in `if (kAiFeatureEnabled)` |
| `2810-2818` | Guard the `chat_ai` handler branch |
| `2871-2878` | Wrap the "Chat with AI" `PopupMenuItem` in `if (kAiFeatureEnabled)` |

### 8.4 `lib/features/settings/screens/settings_screen.dart`

- Remove (or wrap in `if (kAiFeatureEnabled)`) the "AI Vault Password Access" `SwitchListTile` at `935-943`.
- Keep `SettingsService.aiAutoVaultPasswordAccess` in the model (decision 4-A: leave data/settings intact); only the UI is hidden.

### 8.5 Stop background indexing

`lib/features/documents/screens/pdf_viewer_screen.dart:581-589`:

```dart
if (kAiFeatureEnabled) {
  unawaited(
    PdfIndexingCoordinator()
        .indexPdfDocument(filePath: widget.filePath, password: ...)
        .catchError((_) => ''),
  );
}
```

This stops new CPU/battery/DB growth while leaving existing indexes untouched (decision 4-A).

### 8.6 Skip notification wiring

`lib/main.dart:138-143`: guard the `open_ai_chat:` branch. `AiNotificationService` itself stays in the codebase.

### 8.7 Developer-only AI screens

No change required. `AiPromptManagementScreen` and `AiDiagnosticsScreen` are only launched from `AiStudioScreen` (`1078-1079, 1578, 1587`). With the Studio unreachable, they are unreachable too — satisfying "hide even for the developer".

### 8.8 Existing data (decision 4-A)

- Do **not** drop `ai_*` tables.
- Do **not** delete `<appDir>/ai_models/*.gguf`.
- Document as a follow-up: a one-time purge before any public release.
- `storage_service.dart` still creates the `ai_*` tables and indexes unconditionally (`98, 331, 379-381, 595, 610, 626, 742`). This is consistent with 4-A and harmless; no change.

### 8.9 Acceptance criteria

- [ ] Bottom nav shows exactly 3 destinations; no AI tab, no BETA badge.
- [ ] No sparkle button in folder AppBar; no "Chat with AI" menu item.
- [ ] No "AI Vault Password Access" toggle in Settings.
- [ ] Opening a PDF does not write to `ai_*` tables (verify via DB inspection).
- [ ] Tapping an `open_ai_chat:` notification (if one is still pending from an older build) does not crash or open Settings as if it were AI.
- [ ] Developer mode shows no AI screens.
- [ ] `flutter analyze` clean; existing tests updated for the 3-tab layout.

---

## 9. PDF Save Flow Regression — Git History (Detailed)

### 9.1 Timeline

| Commit | Date | Change | Effect on save flow |
|---|---|---|---|
| `cbad38b` | 2026-01-24 | "Release 1.1.1+109: Viewer Enhancements (Save, Share, GoToPage)" | **Introduced** `_handleSaveFile` and an always-visible AppBar save icon (`Icons.save_alt`, tooltip "Save to Folder"). Save worked for every PDF. |
| `cf5af3a` | 2026-01-24 | "Release 1.1.5: Fix Sync, Save Button, and Update Indicator" | Added `final bool isExternal` (default `false`), wrapped the save icon in `if (widget.isExternal)`, added `isExternal: true` at the **dashboard** call site, and replaced the single "Save to Folder" dialog with the two-option bottom sheet ("Save to App Library" / "Save to Device Storage"). Save still worked for dashboard-opened PDFs. |
| `1ab47a6` | 2026-06-30 | "Task 2: resilient library load; Task 5: guard device deletion" | Documentation only: added a runbook caution "Do NOT move the Share button inside the `if (widget.isExternal)` block — that would hide it for All-Docs-opened files." No code change to the save gate. |
| `9bd23aa` | 2026-08-30 | "feat(office-A2): central open router" | Created `office_open_router.dart` (`openDocument`). Its `PdfViewerScreen` push does **not** pass `isExternal`. |
| `c5da6e2` | 2026-08-30 | "feat(office-A5b): route dashboard document taps through office router" | **Regression.** Removed the dashboard's direct `PdfViewerScreen(..., isExternal: true, deleteOnClose: isTemp, ...)` push and replaced it with `openDocument(context, filePath)`. This removed the **only** `isExternal: true` call site **and** the only `deleteOnClose` call site. |
| `45e93bf` | 2026-10-17 | "feat(office): upgrade Word & Excel viewers…" | Updated the router; still no `isExternal`. |
| `7d4cf67` | 2026-10-17 | "fix(excel,word,pdf): …" | No change to the save gate. |
| `8c8926b` | 2026-10-18 | "Inital AI Mode setup" | No change to the save gate. |

### 9.2 Root cause

```dart
// pdf_viewer_screen.dart:326
if (widget.isExternal)
  IconButton(
    icon: const Icon(Icons.save_alt),
    tooltip: 'Save to Folder',
    onPressed: () => _handleSaveFile(context),
  ),
```

- `isExternal` defaults to `false` (`pdf_viewer_screen.dart:48`).
- `grep -rn "isExternal" lib/` returns only the declaration, the default, and the gate — **zero call sites pass `true`**.
- Therefore the save button never renders, and `_handleSaveFile` is unreachable from the PDF viewer.
- Word and Excel viewers are unaffected because they expose `_handleSaveFile` unconditionally in their overflow menus.

### 9.3 Why it was missed

The `isExternal` gate was introduced to distinguish "opened from outside the app" from "opened from the library". When the office router consolidated all open paths (`9bd23aa` → `c5da6e2`), the router did not carry the `isExternal` intent forward. The runbook caution in `1ab47a6` warned about the Share button but not the Save button, so the regression had no test coverage.

### 9.4 Second regression in the same commit: `deleteOnClose` lost

`c5da6e2` also removed `deleteOnClose: isTemp` from the dashboard fallback:

```dart
// before (c5da6e2^)
PdfViewerScreen(
  filePath: filePath,
  fileName: fileName,
  isExternal: true,
  deleteOnClose: isTemp,
)

// after (current)
openDocument(context, filePath);
```

- `openDocument` (`office_open_router.dart:44-52`) has **no** `deleteOnClose` parameter and does not pass one to `PdfViewerScreen`.
- The dashboard still computes `final isTemp = PendingFileOpen.isTemporary;` at `document_dashboard_screen.dart:464` but never uses it.
- `PendingFileOpen.isTemporary = true` is set for files received via the share intent (`main.dart:528`).
- Result: **temp copies created for shared files are never deleted on close** — a storage leak, and a second regression from the same commit.

**Fix:** add an optional `bool deleteOnClose = false` to `openDocument` and forward it to `PdfViewerScreen`; pass `deleteOnClose: isTemp` from the dashboard fallback.

---

## 10. PDF Save Flow Fix Plan (Decision 5-B, 6-B, 7-A)

> **No code has been changed. This is the plan to execute after approval.**

### 10.1 Add "Save File" to the PDF overflow menu

In `pdf_viewer_screen.dart`:

1. Add a handler branch in `onSelected` (around `345-355`):
   ```dart
   else if (value == 'save_file') await _handleSaveFile(context);
   ```
2. Add a `PopupMenuItem` in `itemBuilder` (around `377-380`, next to "File info"):
   ```dart
   const PopupMenuItem(
     value: 'save_file',
     child: Row(children: [Icon(Icons.save_alt), SizedBox(width: 8), Text('Save File')]),
   ),
   ```
3. Keep the AppBar `Icons.save_alt` icon for `isExternal` files (no change to `326-331`).

This mirrors the Word/Excel pattern and makes the flow reachable for every PDF, including library and password-protected files.

### 10.2 Relabel the library option (decision 6-B)

In `_handleSaveFile` (`pdf_viewer_screen.dart:1324`):

```dart
title: const Text('Save a Copy to App Library'),
```

Keep the subtitle ("Organize in App Folders & Sync") and both options.

### 10.3 Password-protected PDFs (decision 7-A)

- `_saveToLibrary` and `_saveToDevice` operate on `widget.filePath`; they do not need the decrypted buffer or `_currentPassword`.
- The saved copy remains encrypted, which is the correct behavior for a password-protected PDF.
- No extra gate is required. (If an "unlocked copy" export is ever wanted, that is a separate feature.)

### 10.4 Acceptance criteria

- [ ] Overflow menu on any PDF shows "Save File".
- [ ] Tapping it opens the bottom sheet with "Save a Copy to App Library" and "Save to Device Storage".
- [ ] "Save a Copy to App Library" runs duplicate check + folder selection and creates a copy.
- [ ] "Save to Device Storage" opens the folder picker and writes the file.
- [ ] Works for library PDFs, external PDFs, and password-protected PDFs.
- [ ] Word/Excel save flows unchanged.

### 10.5 Related fix: restore `deleteOnClose` (from §9.4)

- Add `bool deleteOnClose = false` to `openDocument(BuildContext, String, {bool deleteOnClose = false})`.
- Forward it to `PdfViewerScreen(..., deleteOnClose: deleteOnClose)`.
- In `document_dashboard_screen.dart:472-475`, pass `deleteOnClose: isTemp`.
- Acceptance: a file shared into the app is deleted from the temp dir after the viewer closes.

---

## 11. Test Plan

### 11.1 AI hide
- Widget test: `MainScreen` renders 3 `NavigationDestination`s when `kAiFeatureEnabled == false`.
- Widget test: folder AppBar has no `AiSparkleIcon`; overflow menu has no "Chat with AI".
- Widget test: Settings → Security has no "AI Vault Password Access".
- Unit test: `PdfIndexingCoordinator.indexPdfDocument` is not called on PDF open when the flag is false (inject/mock the coordinator).
- Regression test: `open_ai_chat:` notification payload is ignored when the flag is false.

### 11.2 Save flow
- Widget test: open `PdfViewerScreen`, tap overflow, expect "Save File".
- Widget test: tap "Save File" → expect bottom sheet with both options and the new label.
- Widget test: password-protected PDF still shows the save item.
- Manual QA on device: save to library (new copy), save to device folder, duplicate handling.

### 11.3 Existing suites
- Update `test/local_ai_and_features_test.dart` and `test/ai_and_security_enhancements_test.dart` for the 3-tab layout and hidden AI UI.
- Run `flutter analyze` and `flutter test`.

---

## 12. Risks & Follow-ups

| Risk | Mitigation |
|---|---|
| Nav index shift (AI removed → Settings becomes index 2) | Audit every `initialIndex` / `_currentIndex == 2` use; guard the notification branch. |
| Pending `open_ai_chat:` notifications from older builds | Guard the branch; ignore payload when flag is false. |
| Existing AI data remains on upgraded devices (decision 4-A) | Documented follow-up: one-time purge before public release. |
| `flutter_llama` still bundled (decision 2-B) | Accepted; no APK size change. |
| Tests assume the AI tab exists | Update tests in the same change. |
| SHA-256 gaps (items 1–2 in §5.3) | Out of scope for hide; must fix before re-enabling. |
| Temp-file leak from shared files (§9.4) | Fix `deleteOnClose` in the same change as the save-flow fix. |
| `MASTER_IMPLEMENTATION_REPORT.md` documents the AI tab as a shipped feature | Update it (or add a note) when the hide lands. `AI/02_screens_and_navigation.md` already lists only 3 tabs (Settings = Tab 2), so it becomes consistent with the code after the hide. |

---

## 13. File Tree — Local AI Feature (Corrected Inventory)

```
lib/features/ai/
├── screens/
│   ├── ai_studio_screen.dart                (1,651)  main chat UI
│   ├── ai_diagnostics_screen.dart           (1,678)  dev debug logs
│   └── ai_prompt_management_screen.dart     (692)    master system prompt editor
└── widgets/
    ├── ai_sparkle_icon.dart                  (97)    Gemini sparkle logo
    ├── ai_model_management_dialog.dart     (850)     model catalog/download/activate
    └── app_library_pdf_picker.dart         (258)     folder-hierarchy PDF picker

lib/features/documents/widgets/
└── ai_model_approval_dialog.dart           (161)     UNUSED / dead code  ← corrected path

lib/services/ai/
├── multi_pdf_rag_service.dart              (756)     RAG answering engine
├── local_llm_inference_service.dart        (199)     flutter_llama runtime
├── pdf_indexing_coordinator.dart           (369)     text extraction + embedding + FTS5
├── hybrid_search_service.dart              (192)     RRF fusion (lexical + vector)
├── ai_model_manager_service.dart           (339)     model catalog + download + SHA
├── device_capability_service.dart          (113)     RAM/CPU profiling + tier
├── ai_prompt_service.dart                  (266)     master prompt store
├── ai_diagnostics_service.dart             (331)     query logs + storage stats
├── ai_diagnostics_export_service.dart      (372)     export logs (JSON/CSV/MD/DOCX)
└── ai_notification_service.dart             (93)     AI-finish local notification

lib/features/documents/
├── screens/pdf_viewer_screen.dart          (1304-1352) _handleSaveFile / _saveToLibrary / _saveToDevice
├── screens/word_viewer_screen.dart         (222, 455-470, 479, 517-523) save flow
├── screens/excel_viewer_screen.dart        (226, 636, 648, 677) save flow
├── screens/document_dashboard_screen.dart  (2031) folder "Chat with Folder (AI)" button
                                            (2871) folder "Chat with AI" menu
└── services/office_open_router.dart        (44-52) PDF open path (no isExternal)

lib/core/constants/app_constants.dart       (20-29)    AI SQLite table names
lib/features/settings/screens/settings_screen.dart (935-943) "AI Vault Password Access" toggle
lib/features/settings/screens/settings_screen.dart (1045-1053) Developer section (hidden)
lib/main.dart                               (1137, 1148, 1164-1174) AI tab wiring
lib/main.dart                               (19, 138-143) AI notification wiring
```

---

## 14. Appendix — Verification Evidence

Commands used to verify this document:

```bash
# AI entry points
grep -rn "AiStudioScreen\|AiDiagnosticsScreen\|AiPromptManagementScreen\|AiSparkleIcon" lib/ | grep -v '^lib/features/ai/'

# Save-flow gate and call sites
grep -rn "isExternal" lib/
# -> only pdf_viewer_screen.dart:37, 48, 326 (declaration, default, gate)

# Regression history
git log -S 'isExternal' --oneline -- lib/features/documents/screens/pdf_viewer_screen.dart
# -> cf5af3a (added gate)
git log -S 'isExternal' --oneline -- lib/features/documents/screens/document_dashboard_screen.dart
# -> cf5af3a (added isExternal: true), c5da6e2 (removed it)
git log -S '_handleSaveFile' --oneline -- lib/features/documents/screens/pdf_viewer_screen.dart
# -> cbad38b (introduced)
git log -S 'Save to App Library' --oneline -- lib/features/documents/screens/pdf_viewer_screen.dart
# -> cf5af3a (added two-option sheet)

# SHA-256 gap
grep -rn "sha256\|Sha256\|SHA256" lib/services/ai/
# -> only catalog placeholders + storing expectedSha256; no file hashing

# Backup exclusion
grep -rn "ai_document\|ai_chat\|ai_installed\|ai_chunk" lib/services/docs_settings_backup_service.dart
# -> no matches

# Approval dialog is dead code
grep -rn "AiModelApprovalDialog" lib/
# -> only its own file; no imports

# deleteOnClose regression
grep -rn "deleteOnClose" lib/
# -> only pdf_viewer_screen.dart:38, 49, 130 (declaration, default, usage)
git show c5da6e2 -- lib/features/documents/screens/document_dashboard_screen.dart | grep -n "deleteOnClose"
# -> removed alongside isExternal: true
```

---

*End of document. Audit verified; decisions locked; no code modified. Ready to implement §8 (AI hide) and §10 (save-flow fix) on approval.*
