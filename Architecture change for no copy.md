# Zero Copy Architecture - Implementation Plan

## Overview
Transition from copying files to app storage ("import") to referencing original device files ("Zero Copy").

### Current State
- Files copied to `cache/file_picker` or `app_flutter` (inside `com.passwordpdf.passwordpdf_manager/`).
- Passwords keyed by app storage path.

### Target State
- **No file copies.** App stores only a reference (original path).
- Operations (unlock, merge, split) create temp copy → process → save to Downloads → **delete temp**.

---

## Core Principles

| Principle | Description |
|-----------|-------------|
| Reference Only | "All Docs" stores original path. **No copy.** |
| Copy-on-Operation | Temp copy only for PDF modifications. **Deleted immediately after.** |
| Output to Downloads | All processed files go to user-selected folder. |

> [!IMPORTANT]
> **Android Platform Limitation**: "Add Files" (file_picker) and "Open With" (intents) CANNOT access original paths due to Scoped Storage (Android 10+). These flows use cached copies. **For Zero Copy, use "All Docs" screen.**

---

## Bug Fix: Open With Cold Start

> [!IMPORTANT]
> **Bug**: When app is closed, "Open With" launches the app but doesn't open the file. Works fine if app is already running.

**Root Cause**: On cold start, `MainActivity` may not be fully initialized when the intent is received, causing the pending file to be missed.

**Fix**: Ensure `PendingFileOpen` is checked after full app initialization in `main.dart` or the first screen's `initState`. Persist intent data if necessary.

---

## Affected Components

| Component | Current | Zero Copy |
|-----------|---------|-----------|
| `DocumentService.importFile` | Copies file | **Removed**. Use `addReference()` |
| `DocumentItem.filePath` | App storage path | `sourcePath` (original path) |
| `PdfPasswordService` key | App path | Original path (or content hash) |
| `PdfViewerScreen` | Load from app storage | Load from `sourcePath` |
| `PdfToolsService` | Operate on app file | Temp → Process → Downloads → Delete temp |
| "Open With" flow | Copies to cache | **Reference only** |
| "All Docs" open | Import then open | **Reference then open** |

---

## Implementation Phases

### Phase 1: Model & Service Refactor
- [x] Rename `DocumentItem.filePath` → `sourcePath`.
- [x] Remove `DocumentService.importFile()`. Add `addReference(String originalPath)`.
- [ ] Add `cleanupTempFiles()` utility.

### Phase 2: Password Service
- [x] Change key strategy: Use original path with filename fallback.
- [x] Migrate existing password mappings (automatic on lookup).

### Phase 3: Viewer & Tools
- [ ] `PdfViewerScreen`: Load from `sourcePath`.
- [ ] `PdfToolsService`: Temp → Process → Downloads → Delete temp.
- [ ] "Saved to Downloads" snackbar.

### Phase 4: UI & Flows
- [ ] "All Docs": Tap = `addReference()` + open viewer.
- [ ] "Open With": Reference only, no copy.
- [x] Dashboard: Handle "File Not Found".
- [x] **Fix Open With cold start bug.**

### Phase 5: Migration
- [ ] Prompt: "Keep copies" vs "Switch to Zero Copy".
- [ ] Clear old storage folders.

---

## Risks

> [!CAUTION]
> **File Moved/Deleted**: Detect missing files, offer "Relocate" or remove.
                                
> [!WARNING]
> **Password Migration**: Re-key existing passwords from old paths.

> [!IMPORTANT]
> **Permissions**: Requires `MANAGE_EXTERNAL_STORAGE`.

---

## Verification Checklist
- [ ] Add from All Docs: No copy, path stored.
- [ ] Open With (cold start): File opens correctly.
- [ ] Open With (app running): File opens correctly.
- [ ] Split PDF: Output in Downloads, no temp remaining.
- [ ] Password: Unlock works with original path.
