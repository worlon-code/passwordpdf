# Password PDF Manager

A secure Flutter application for managing PDF files and passwords with advanced folder organization and encryption.

## Version 0.0.24 - Dashboard & Folder Enhancements

### 🚀 New Features

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

#### Handling Duplicates
- When adding/moving files with existing names:
  - Dialog shows: "Skip This File" or "Rename & Add"
  - Choose to skip or provide new name
  - Original file preserved

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
**Current Version**: 0.0.24 (Build 24)  
**Last Updated**: December 31, 2024
