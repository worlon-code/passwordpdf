# Password PDF Manager

A secure Flutter application for managing PDF files and passwords with advanced folder organization and encryption.

## Version 1.0.0-beta.3 - Enhanced PDF Experience!

### 🚀 New Features

#### PDF Viewer Enhancements
- **Page Number Indicator**: Stylish "X/Y" indicator at the bottom-right of pages (Samsung Notes style).
- **Screenshot Branding**: Screenshots taken within the app are automatically named with `_PDF Manager` suffix (Android only).
- **Standard Scrollbar**: Restored native-feeling scrollbar for better navigation.
- **Search Experience**: Improved search bar with dedicated search button and smarter keyboard handling.

#### Bug Fixes & Improvements
- **Page Orientation Fix**: Fixed issue where pages shifted or resized after split/merge/reorder operations.
- **Merge Tool**: Updated to use custom file browser for reliable single-file selection.
- **Large PDF Handling**: Added `largeHeap` support to prevent crashes with large, high-resolution documents.
- **Search Navigation**: Back button in search mode now correctly closes search instead of the document.

### Previous Versions

#### Version 1.0.0-beta.2 - Performance & Folder Optimization!

### 🚀 New Features

#### All Docs Optimization (v0.0.28)
- **Database Caching**: File index is now stored in SQLite for instant load times.
- **Smart Folder View**: Toggle between Flat List (files only) and Hierarchical Folder browsing.
- **Recursive Folder Indexing**: All parent folders are automatically indexed, ensuring complete hierarchy.
- **Smart Filtering**: In Folder View, filters (PDF, Word, Excel) only show folders that *contain* matching files.
- **Consistent UI**: Folder icons now match Dashboard styling (Blue with rounded background).

#### Zero Copy Architecture (v0.0.28)
- **No File Duplication**: Files are referenced by their original path, saving significant storage space.
- **Missing File Detection**: Visual indicators and removal prompts for files moved/deleted externally.
- **Automatic Cache Cleanup**: Temporary files from "Add Files" and "Open With" are cleaned on app start.

#### Sync & Badges (v0.0.28)
- **Time-Based Pull-to-Refresh**:
  - **Short Pull**: Quick refresh of UI from database.
  - **Hold > 1.5s**: Triggers full file system sync for all folders.
- **Sync Indicators**: Custom overlay shows when sync is ready to trigger.
- **New Badges**: "NEW" badges for freshly discovered files and folders.
- **Missing File Tracking**: Visual indicators for files removed from device.
- **Global Removed Files**: Dedicated screen to manage missing files.

#### Stability Improvements (v0.0.28)
- **Global Error Handler**: Uncaught exceptions are now logged via `LoggingService`.
- **"Open With" Cold Start Fix**: Files shared via "Open With" now open reliably on cold start.
- **RAM Optimization**: PDF pre-checks use header inspection instead of full file load.

### Previous Versions

#### Version 1.0.0-beta.1 - First Beta Release!

#### Version 0.0.27 - All Docs Screen & Enhanced Open With

### 🚀 New Features

#### All Docs Screen (v0.0.27)
- **Device File Browser**: Browse all documents on your device (not just app-managed files)
- **Quick Filters**: Filter by PDF, Word, Excel file types
- **Multi-Select Import**: Select multiple files and import to any folder
- **Single-Tap Open**: Tap to open files directly, or auto-navigate to existing location if already imported

#### Enhanced "Open With" (v0.0.27)
- **Reliable Background Handling**: Fixed issue where "Open With" only worked first time when app was in background
- **Duplicate Detection**: Shows Android notification when opened file already exists in library
- **Location Selection Popup**: Tap notification to see all locations and choose which to open
- **Stay on Current Screen**: Notification popup appears on whatever tab you're currently on

#### Advanced Conflict Resolution (v0.0.25)
- **Batch Processing**: Handle multiple file conflicts at once when importing or maneuvering files.
- **Interactive Dialog**: Select specific files to Rename, Overwrite, or Skip.
- **Custom Renaming**: Apply custom suffixes to renamed files in bulk (e.g., `_v2`, `_copy`).
- **Safety First**: "Overwrite" is an explicit action, preventing accidental data loss.

#### Smart Notifications (v0.0.25)
- **Interactive Alerts**: Tap on "Exporting..." notifications to instantly open the active `ExportQueueScreen`.
- **Progress Tracking**: Real-time progress updates in the notification shade.

#### Developer Tools (v0.0.26)
- **Database Viewer**: View, Edit, and Delete database records directly within the app.
- **Excel Export**: Export database tables to Excel (.xlsx) for analysis.
- **Performance**: Optimized viewer for large datasets with pagination and efficient rendering.
- **Security**: Protected by a secure portal password.

#### Smart Password Learning (v0.0.24)
- **Auto-Unlock**: Automatically tries saved passwords when opening protected PDFs.
- **Smart Dialog**: Falls back to password prompt if auto-unlock fails, with option to save the password.
- **Save to List**: Easily add new passwords to your secure "My Passwords" list directly from the opening dialog.
- **Key Name Notification**: Visual feedback telling you exactly which saved password key successfully unlocked the file.
- **Password Visibility**: Toggle visibility int he password dialog to ensure you type correctly.

#### Export Queue Service (v0.0.24)
- **Background Processing**: Large export jobs (ZIPs) run in the background, keeping the UI responsive.
- **Queue Management**: Monitor status, progress, and history of all exports in a dedicated dashboard.
- **Persistence**: Export jobs survive app restarts and continue until completion.
- **ZIP Encryption**: Secure your exported ZIP files with a custom password.

#### Document Dashboard Filter (v0.0.24)
- **File Type Filters**: Filter by All, PDF, DOC, Excel.
- **Smart Folder View**: Folders are filtered to only show those containing matching files (recursively).
- **In-Folder Filtering**: Filter bar persists inside folders, applying filters to subfolders and files.
- **Filtered Counts**: Folder cards display the count of files matching the active filter.

#### Enhanced Folder Import (v0.0.24)
- **Context-Aware Import**: Imports folders directly into the current viewing directory (not always root).
- **Import Progress**: Recursive import with progress dialog for large folders.
- **Conflict Resolution**: Smart prompts when folder names conflict in the specific import location.

#### Folder Management Improvements (v0.0.24)
- **Cascade Delete**: Deleting a folder now properly deletes all its contents (files and subfolders).
- **Hierarchical Navigation**: Android back button and UI back arrow now navigate up one level in the folder structure.
- **Improved Icons**: Distinct icons for "Import Folder" (Create New) and "Export to Zip" (Folder Zip).

#### Download Location Management (v0.0.23)
- **Centralized Exports**: All saved files (Unlocked PDFs, Merged/Split Files, Zipped Folders, Debug Logs) now go to a single, user-defined location.
- **Mandatory Setup**: Enforced on first launch (post-auth) to ensure you always know where your files are going.
- **Settings**: Change the location anytime in `Settings > Downloads`.

#### PDF Manipulation Suite (v0.0.22)
- **Split PDF**: Extract specific pages or ranges.
- **Merge PDF**: Combine with external files (smart password handling).
- **Reorder Pages**: Drag-and-drop page sorting.
- **Remove Password**: Decrypts the current file (using session password) and saves a copy.

#### Smart PDF Security (v0.0.20-21)
- **Status Indicator**: File Info screen now shows if a PDF is "Password Protected".
- **Smart Detection**: Skips password dialog for non-protected files.
- **Auto-Fill**: Remembers successful passwords for seamless access.

#### Password Manager
- **Refresh Fix**: Pull-to-refresh works on empty lists.

### v0.0.27
- **All Docs Screen**: New device file browser with filtering and multi-select import.
- **Enhanced Open With**: Reliable background intent handling, duplicate notifications with location selection.
- **Auto-Rename**: Automatic incrementing suffixes (`_1`, `_2`) for conflict resolution.

### v0.0.26
- **Developer Tools**: New suite of tools for database management and debugging.
- **Performance**: Optimized database viewer and large text rendering.
- **Export Enhancements**: Support for unlimited database exports in background.

### v0.0.25
- **Advanced Conflict Resolution**: New UI for handling file conflicts with Retry, Rename, Skip options.
- **Batch Import**: Conflict resolution now applies gracefully to bulk file imports.
- **Smart Notifications**: Tap on export notifications to view progress.
- **UI Polish**: Improved dialog layouts and feedback.

### v0.0.24
#### Password Manager Improvements
- **Rename Password Keys**: Tap ••• menu on any password to rename
- **Pull-to-Refresh**: Swipe down on password list to refresh
- **Real-time Key Validation**: Shows red error when key name exists, disables save
- **Duplicate Password Detection**: Shows popup with existing key if password already saved
- **PDF Password Integration**: Password dialog appears when opening PDFs

#### Validation Enhancements
- Key name duplicate check in Add Password dialog (real-time)
- Key name duplicate check in PDF Password Save (with button disable)
- Password value duplicate check (shows existing key name in popup)

### 🐛 Bug Fixes
- Fixed rename dialog crash on cancel (removed improper controller.dispose)
- Fixed PDF password dialog appearing for all PDFs

### Previous Release: v0.0.15 - Password Management Integration

#### Password Manager
- **New "Passwords" Tab**: Dedicated password management screen in bottom navigation
- **Encrypted Storage**: All password values encrypted with XOR encryption
- **Search & Filter**: Quickly find passwords by key name
- **Add/Delete**: Easy password management with confirmation dialogs
- **PDF Integration**: Password selection dialog when opening password-protected PDFs

#### Advanced File Operations
- **Duplicate Detection**: Automatic duplicate file detection when:
  - Adding files to folders
  - Moving files between folders
- **Smart Rename Dialog**: Option to rename or skip duplicate files
- **Expandable Move Dialog**: Tree view showing only root folders initially, click to expand subfolders

#### Export & Backup
- **Recursive ZIP Export**: Export entire folder structure including all subfolders
- **Preserved Directory Structure**: Maintains folder hierarchy in exported ZIP files
- **File Count Display**: Shows total files exported (e.g., "Exported 25 file(s) to Downloads/...")

#### Navigation & UX
- **Android Back Button**: Properly navigates through folder hierarchy instead of closing app
- **PopScope Implementation**: Uses modern Flutter navigation API
- **Clean Empty States**: Simple, clear messages without redundant buttons
- **Context-Aware UI**: Different behavior based on current location (root vs inside folder)

### 🔧 Technical Improvements

#### Model Updates
- Added `parentId` field to `DocumentItem` model for nested structure
- Updated `copyWith`, `toJson`, and `fromJson` methods

#### Service Layer
- `DocumentService.createFolder()`: Now accepts optional `parentId` parameter
- `getRootFolders()`: Retrieves only top-level folders
- `getSubfolders(String folderId)`: Gets folders within a specific parent
- Duplicate name validation scoped to parent folder

#### UI Components
- Custom `_MoveDialogWithTree` widget with expandable/collapsible folders
- Stateful tree management for folder expansion state
- Indented hierarchy display (24px per depth level)

### 🐛 Bug Fixes

1. **Android Back Button** (v0.0.7-0.0.9)
   - Fixed: App closing when pressing back inside folders
   - Solution: Implemented `PopScope` with `canPop` and `onPopInvoked`

2. **Duplicate File Dialog** (v0.0.7)
   - Fixed: Files still added when canceling duplicate dialog
   - Solution: Proper null checking and action handling

3. **Export Ignoring Subfolders** (v0.0.9)
   - Fixed: Only exported files in main folder
   - Solution: Recursive `addFolderToArchive()` function

4. **Move Dialog Showing All Folders** (v0.0.9)
   - Fixed: Flat list showing all folders including nested ones
   - Solution: Expandable tree view with on-demand subfolder loading

### 🎨 UI/UX Enhancements

- Removed redundant "Subfolders" and "Files" section headers
- Simplified empty folder state to single message
- Added visual indicators for expandable folders (chevron icons)
- Color-coded folder depth (lighter blue for deeper levels)
- Improved folder and file count displays

### 📋 Version History

- **v0.0.28**: All Docs Optimization, Zero Copy, Smart Folder Views, RAM Optimization.
- **v0.0.27**: All Docs screen, Enhanced Open With, Auto-rename conflict resolution.
- **v0.0.26**: Developer tools, Database viewer optimizations, Generic Excel export.
- **v0.0.25**: Advanced conflict resolution, Smart notifications.
- **v0.0.24**: Password learning, Export queue, Smart filters.
- **v0.0.9**: Expandable move dialog, recursive export, move duplicate checking
- **v0.0.8**: PopScope for Android back, improved empty folder UI, hierarchical display fixes
- **v0.0.7**: Nested folder support, duplicate detection, folder name validation
- **v0.0.6**: Initial nested folder model implementation
- **v0.0.1-0.0.5**: Core features, authentication, document management

### 🔐 Security Features

- **Encryption**: AES encryption for stored passwords
- **Authentication**: 
  - Fingerprint/Biometric support
  - PIN lock option
  - Developer password for sensitive operations
- **Local Storage**: All data stored locally, no external servers

### 📱 Installation

1. Download APK from releases
2. Enable "Install from Unknown Sources" on Android
3. Install the APK
4. Grant required permissions

### 🚀 Usage

#### Creating Nested Folders
1. Tap 3-dot menu → "New Folder"
2. Enter folder name (validation prevents duplicates)
3. Open the folder
4. Create another folder inside → Creates nested structure

#### Moving Files
1. Select files by tapping or long-pressing
2. Tap move icon in toolbar
3. See root folders listed
4. Tap chevron (▶️) to expand and see subfolders
5. Tap folder name to select destination

#### Exporting Folders
1. Open folder or tap folder card's menu
2. Select "Export as ZIP"
3. Includes all subfolders and files
4. Check Downloads folder for ZIP file

#### Handling Duplicates & Conflicts
- When adding or moving files results in naming conflicts:
  - A **Batch Resolution Dialog** appears listing all conflicting files.
  - Select files you want to resolve.
  - Choose an action from the dropdown:
    - **Rename**: Appends a suffix (default `_copy`) to selected files.
    - **Overwrite**: Replaces the destination files with the new ones.
    - **Skip**: Ignores the selected files.
  - Click **OK** to apply. The dialog repeats until all conflicts are resolved.

### 🛠️ Development

**Framework**: Flutter 3.5.3  
**Language**: Dart 3.5.3  
**Platform**: Android (SDK 35)

**Key Dependencies**:
- `file_picker`: File selection
- `archive`: ZIP creation
- `local_auth`: Biometric authentication
- `shared_preferences`: Local data storage
- `provider`: State management
- `path_provider`: File system access

### 📝 Git Workflow

- **Main Branch**: `main`
- **Release Branches**: `release/v0.0.X`
- **Tags**: Version tags (e.g., `v0.0.9`)
- Each release built on top of previous release branch

### 🤝 Contributing

This is a private project. For issues or feature requests, please contact the development team.

### 📄 License

Proprietary - All rights reserved

---

**Repository**: https://github.com/worlon-code/passwordpdf  
**Current Version**: 1.0.0-beta.2 (Build 28)  
**Last Updated**: January 8, 2026
