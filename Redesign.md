# All Docs Screen Complete Redesign
> Custom File Picker + Folder Sync + New Badges + Material 3 Expressive UI

## Overview

| Feature | Description |
|---------|-------------|
| **Custom File Picker** | Replace system file_picker with in-app browser for PDF/Doc/Excel selection |
| **Folder Import** | Select folders containing documents, tracked for sync |
| **Folder Sync** | On refresh, auto-detect added/removed/modified files |
| **"New" Badge** | Visual indicator for recently added files |
| **Removed Files List** | Show what was removed in last sync |
| **Permanent Delete** | Two-stage confirmation for irreversible file deletion from device |
| **Material 3 Expressive** | Android's new expressive UI with dynamic colors, rounded shapes |

---

## Flutter File Manager Packages (pub.dev)

| Package | Purpose | Relevance |
|---------|---------|-----------|
| `file_manager` | Full file/folder management widget | ⭐ High - Could replace custom build |
| `file_tree_view` | Foldable tree structure display | ⭐ High - For folder hierarchy |
| `flutter_treeview` | Hierarchical data tree widget | Medium - General tree view |
| `open_file_manager` | Open device file manager | Low - Not needed |
| `file_picker` | Native file selection dialog | ✅ Already using |
| `path_provider` | Get system paths | ✅ Already using |
| `mime_type` | Detect file MIME types | Medium - For file icons |

## Your App Context

| File Type | Action |
|-----------|--------|
| **PDF** | Open in **your PDF Viewer** (in-app) |
| **DOC/Excel** | Open via system "Open With" |
| **Video/Audio** | Not needed |

## Reference Features

### From FileX
- ✅ Recent Files section
- ✅ Search Files with results
- ✅ Sort Files (name, date, size)
- ✅ Show/Hide Hidden files
- ✅ Copy/Move Files (clipboard)
- ✅ Delete/Rename Files
- ✅ Dark Mode support

### From FileManagerApp  
- ✅ File browsing hierarchy
- ✅ Quick search functionality
- ✅ File properties/metadata view
- ✅ Customizable view options (List/Grid)
- ✅ Cross-platform compatible

---

## Phase 1: Performance Fixes (Critical) 🟢 DONE

### 1.1 Remove Rescan on Folder Navigation
- ✅ Removed `scanDevice()` from `_loadDocuments` (unless forced).
- ✅ Only queries database on folder navigation.

### 1.2 Optimize Folder Filter Query
- ✅ Added `has_pdf`, `has_doc`, `has_excel` columns to `files_index`.
- ✅ Implemented recursive flag calculation during scan.
- ✅ Replaced slow `EXISTS` subquery with fast `has_xxx = 1` check.

---

### 1.3 Fix State Loss on Navigation 🟢 DONE
- ✅ Replaced `pushAndRemoveUntil` with `Navigator.push` when opening PDFs.
- ✅ Preserves `AllDocumentsScreen` state (scroll position, folder depth) when returning from viewer.
- ✅ Fixed app restart behavior on file open.

## Phase 2: Custom File Browser 🟡 PLANNED

### Replace "Add Files" Flow
```
Current: FAB → file_picker (system) → Import
New:     FAB → Custom Browser → Multi-select → Import
```

### Custom Browser Widget
```dart
class CustomFileBrowser extends StatefulWidget {
  final List<String> allowedExtensions; // ['pdf', 'doc', 'docx', 'xls', 'xlsx']
  final bool allowMultiple;
  final bool allowFolders;
  final Function(List<String> selectedPaths) onConfirm;
}
```

### UI Layout
```
┌────────────────────────────────┐
│ Select Files            ✕ Close│
├────────────────────────────────┤
│ 📁 /storage/emulated/0         │
│ ◀ Back                         │
├────────────────────────────────┤
│ ☐ 📁 Download            ▶     │
│ ☐ 📁 Documents           ▶     │
│ ☑ 📄 report.pdf                │
│ ☑ 📄 data.xlsx                 │
│ ☐ 📄 notes.docx                │
├────────────────────────────────┤
│ [2 selected]      [✓ Confirm]  │
└────────────────────────────────┘
```

---

## Phase 3: Folder Import with Tracking

### New Database Table: `tracked_folders`
```sql
CREATE TABLE tracked_folders (
  id INTEGER PRIMARY KEY,
  folder_path TEXT UNIQUE,
  imported_at INTEGER,
  last_synced INTEGER,
  file_count INTEGER
);
```

### Folder Import Flow
```
1. User selects folder in browser
2. Scan folder for PDF/Doc/Excel
3. Add to tracked_folders table
4. Import all found files with folder_id reference
```

---

## Phase 4: Folder Sync on Refresh

### Sync Logic
```dart
Future<SyncResult> syncTrackedFolders() async {
  for (folder in trackedFolders) {
    final currentFiles = await scanFolder(folder.path);
    final storedFiles = await getStoredFiles(folder.id);
    
    // Diff
    final added = currentFiles.difference(storedFiles);
    final removed = storedFiles.difference(currentFiles);
    
    // Mark new files
    for (file in added) {
      await addFile(file, isNew: true);
    }
    
    // Track removed
    await trackRemovedFiles(removed);
  }
}
```

### SyncResult Model
```dart
class SyncResult {
  final List<String> addedFiles;
  final List<String> removedFiles;
  final List<String> modifiedFiles;
  final DateTime syncTime;
}
```

---

## Phase 5: "New" Badge for Files

### Using Flutter's Built-in Badge Widget
```dart
Widget _buildFileItem(DocumentItem file) {
  return ListTile(
    leading: Badge(
      isLabelVisible: file.isNew,
      label: Text('NEW'),
      backgroundColor: Colors.green,
      child: Icon(Icons.picture_as_pdf),
    ),
    title: Text(file.name),
  );
}
```

### Database Update
```sql
ALTER TABLE documents ADD COLUMN is_new INTEGER DEFAULT 0;
ALTER TABLE documents ADD COLUMN added_at INTEGER;
```

### Clear "New" Status
- Clear when file is opened
- Clear after 7 days
- Clear manually via "Mark as Read"

---

## Phase 6: Permanent File Deletion

### Documents Screen
Add checkbox option when deleting from Documents:
```
┌──────────────────────────────────┐
│ Delete File?                     │
├──────────────────────────────────┤
│ ☐ Also delete from device        │
│   (Cannot be recovered)          │
│                                  │
│ [Cancel]  [Delete from App Only] │
└──────────────────────────────────┘
```

### All Docs Screen - Two-Stage Confirmation
**Stage 1: Warning Dialog**
```dart
showDialog(
  context: context,
  builder: (_) => AlertDialog(
    icon: Icon(Icons.warning, color: Colors.orange),
    title: Text('Delete from Device?'),
    content: Text('This will permanently remove the file from your device storage.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
      TextButton(
        style: TextButton.styleFrom(foregroundColor: Colors.red),
        onPressed: _showFinalConfirmation,
        child: Text('Continue'),
      ),
    ],
  ),
);
```

**Stage 2: Final Confirmation**
```dart
showDialog(
  context: context,
  builder: (_) => AlertDialog(
    icon: Icon(Icons.delete_forever, color: Colors.red),
    title: Text('Confirm Permanent Deletion'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('The file will be deleted and CANNOT be recovered.', 
          style: TextStyle(fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(fileName),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
      ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
        onPressed: _deleteFileFromDevice,
        child: Text('Delete Permanently'),
      ),
    ],
  ),
);
```

### Delete Implementation
```dart
Future<void> _deleteFileFromDevice(String filePath) async {
  try {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
      // Remove from database
      await _storage.deleteDocument(documentId);
      // Show success message
      _showSnackbar('File permanently deleted');
    }
  } catch (e) {
    _showSnackbar('Failed to delete file: $e');
  }
}
```

---

## Phase 7: Material 3 Expressive UI

### Design Principles
- **Dynamic Color**: Use user's wallpaper colors
- **Rounded Shapes**: Large corner radius (28dp)
- **Expressive Typography**: Variable fonts with high contrast
- **Bold Elevation**: Strong shadows and depth
- **Vibrant Surfaces**: Colored containers instead of white

### Theme Configuration
```dart
ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: Brightness.light,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  ),
  cardTheme: CardTheme(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(28),
    ),
    elevation: 2,
  ),
  floatingActionButtonTheme: FloatingActionButtonThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(28),
    ),
    extendedSizeConstraints: BoxConstraints(minHeight: 56),
  ),
)
```

### Updated File Item Card
```dart
Card(
  color: Theme.of(context).colorScheme.primaryContainer,
  child: ListTile(
    leading: Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(Icons.picture_as_pdf, 
        color: Theme.of(context).colorScheme.onPrimary),
    ),
    title: Text(
      fileName,
      style: Theme.of(context).textTheme.titleMedium,
    ),
  ),
)
```

### Color Palette System

**Settings Screen - Color Picker**
```
Settings > Appearance > Color Palette
┌──────────────────────────────────┐
│ Choose Color Palette             │
├──────────────────────────────────┤
│ ● Blue (Default)                 │
│ ○ Purple                         │
│ ○ Green                          │
│ ○ Orange                         │
│ ○ Red                            │
│ ○ Pink                           │
│ ○ Teal                           │
│ ○ Yellow                         │
│ ○ Indigo                         │
│ ○ Brown                          │
└──────────────────────────────────┘
```

**10 Android-Style Color Palettes**
```dart
class AppColorPalettes {
  static const Map<String, Color> palettes = {
    'blue': Color(0xFF1976D2),      // Material Blue
    'purple': Color(0xFF9C27B0),    // Material Purple
    'green': Color(0xFF4CAF50),     // Material Green
    'orange': Color(0xFFFF9800),    // Material Orange
    'red': Color(0xFFF44336),       // Material Red
    'pink': Color(0xFFE91E63),      // Material Pink
    'teal': Color(0xFF009688),      // Material Teal
    'yellow': Color(0xFFFFC107),    // Material Amber
    'indigo': Color(0xFF3F51B5),    // Material Indigo
    'brown': Color(0xFF795548),     // Material Brown
  };
}
```

**Theme Service**
```dart
class ThemeService extends ChangeNotifier {
  String _selectedPalette = 'blue';
  
  ThemeData getTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColorPalettes.palettes[_selectedPalette]!,
        brightness: Brightness.light,
        dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
      ),
      // ... rest of theme config
    );
  }
  
  Future<void> setPalette(String paletteName) async {
    _selectedPalette = paletteName;
    await _prefs.setString('color_palette', paletteName);
    notifyListeners();
  }
}
```

**Apply Palette App-Wide**
```dart
MaterialApp(
  theme: Provider.of<ThemeService>(context).getTheme(),
  // ...
)
```

---

## File Changes Summary

| File | Change |
|------|--------|
| `lib/widgets/custom_file_browser.dart` | **NEW** - Custom picker widget |
| `lib/services/folder_sync_service.dart` | **NEW** - Sync logic |
| `lib/services/theme_service.dart` | **NEW** - Color palette management |
| `lib/services/storage_service.dart` | **MODIFY** - Add new tables |
| `lib/models/document_item_model.dart` | **MODIFY** - Add `isNew`, `addedAt` |
| `lib/features/documents/screens/all_documents_screen.dart` | **MODIFY** - Integrate browser |
| `lib/features/documents/screens/document_dashboard_screen.dart` | **MODIFY** - Replace Add Files, Material 3 UI |
| `lib/features/settings/screens/settings_screen.dart` | **MODIFY** - Add color palette picker |
| `lib/main.dart` | **MODIFY** - Integrate ThemeService provider |

---

## Priority Order

| # | Task | Effort |
|---|------|--------|
| 1 | Fix performance (remove rescan) | Low |
| 2 | Build Custom File Browser widget | High |
| 3 | Implement Folder Import tracking | Medium |
| 4 | Add "New" badge system | Low |
| 5 | Build Folder Sync service | High |
| 6 | Permanent delete with two-stage confirm | Low |
| 7 | Material 3 Expressive UI theme | Medium |
| 8 | Removed files tracking UI | Medium |

---

## Development Process

### After Each Phase:
1. Build debug APK (`flutter build apk --debug`)
2. Install on device (`adb install`)
3. Request user verification
4. Collect feedback
5. Make adjustments if needed
6. Commit changes
7. Move to next phase

### Git Workflow

**Branch**: `feature/all-docs-redesign`
**Commit Pattern**: `feat(phase-X): description`

Example commits:
- `feat(phase-1): fix performance by removing folder rescan`
- `feat(phase-2): add custom file browser widget`
- `feat(phase-3): implement folder import tracking`
