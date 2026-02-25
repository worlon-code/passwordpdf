# Zero Copy - Alternative Approach

## Goal
Enable Zero Copy for "Add Files" and graceful cache handling for "Open With".

---

## Option 1: Custom File Browser for "Add Files"

**Replace system file picker with All Docs-style browser.**

### Why
- System `file_picker` copies files to cache (Android Scoped Storage limitation)
- All Docs already has `MANAGE_EXTERNAL_STORAGE` and scans device directly
- Reusing All Docs logic gives original file paths

### Changes

#### 1. Create File Selection Mode in All Docs
- [ ] Add `selectionMode` parameter to `AllDocumentsScreen`
- [ ] When `selectionMode = true`:
  - Show checkboxes on files
  - Add "Select" FAB instead of "Add"
  - Return selected files to caller

#### 2. Replace "Add Files" Button
- [ ] `DocumentDashboardScreen._pickFiles()` → Open `AllDocumentsScreen(selectionMode: true)`
- [ ] On return, use original paths directly (Zero Copy)

#### 3. Remove file_picker Dependency (Optional)
- [ ] Remove picker calls from Dashboard
- [ ] Keep for PDF merge (single file selection in viewer)

---

## Option 3: Cache Auto-Delete for "Open With"

**Clean up cached files after viewing.**

### Why
- Android intents ALWAYS copy files to cache (unavoidable)
- Can't get original path from intent
- Auto-delete prevents cache bloat

### Changes

#### 1. Track Intent Cache Files
- [ ] In `MainActivity.kt` / intent handler, save cache path to `PendingFileOpen`

#### 2. Delete After Viewing
- [ ] In `PdfViewerScreen.dispose()` or `onPop`:
  - Check if file is in `cache/` directory
  - If yes, delete the file

#### 3. Periodic Cache Cleanup
- [ ] Add `cleanupCache()` utility
- [ ] Call on app start to delete old cache files (>24 hours)

---

## Implementation Order

| Phase | Task | Priority |
|-------|------|----------|
| 1 | Add selection mode to All Docs | High |
| 2 | Replace "Add Files" with All Docs picker | High |
| 3 | Auto-delete Open With cache files | Medium |
| 4 | Periodic cache cleanup utility | Low |

---

## Expected Result

| Flow | Before | After |
|------|--------|-------|
| Add Files | Cache path | ✅ Original path (Zero Copy) |
| Open With | Cache path | Cache path (auto-deleted) |
| All Docs | Original path | ✅ Original path |
