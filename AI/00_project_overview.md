# 00 Project Overview - PasswordPDF

## Table of Contents
1. [App Name & Purpose](#app-name--purpose)
2. [Target Users](#target-users)
3. [Tech Stack](#tech-stack)
4. [Third-Party Packages](#third-party-packages)
5. [Folder Structure](#folder-structure)
6. [Build Flavors & Environments](#build-flavors--environments)

---

## App Name & Purpose
- **App Name**: PasswordPDF (Package: `passwordpdf_manager`)
- **Purpose**: A secure, privacy-first offline Flutter application for managing PDF files and passwords. It provides tools for splitting, merging, and reordering PDF pages, alongside a robust virtual folder system.
- **Key Philosophy**: **Zero Copy Architecture** — files are never duplicated; the app only stores absolute path references in its local SQLite database to save storage space.

## Target Users
- **Professionals**: Legal, medical, or financial experts handling sensitive PDF documents.
- **Sensitive Document Handlers**: Users requiring high-security vaults for PDF passwords.
- **Advanced Mobile Users**: Individuals who need desktop-class PDF organization on a mobile device.

## Tech Stack
| Component | Technology | Version |
|-----------|------------|---------|
| **Framework** | Flutter | v3.38.6 |
| **Language** | Dart | v3.10.7 |
| **State Management**| Provider (ChangeNotifier) | ^6.1.1 |
| **Database** | sqflite (SQLite) | ^2.3.0 |
| **Key-Value Store** | SharedPreferences | ^2.3.2 |
| **Secure Storage** | FlutterSecureStorage | ^10.0.0 |
| **PDF Rendering** | pdfrx | ^2.2.20 |
| **PDF Manipulation**| Syncfusion Flutter PDF | ^32.1.22 |
| **Auth** | local_auth | 2.3.0 |

## Third-Party Packages
| Package | Version | Exact Usage in App |
|---------|---------|--------------------|
| `provider` | ^6.1.1 | Global state for Settings, Documents, and Exports. |
| `sqflite` | ^2.3.0 | Core persistent storage for file indexing and logs. |
| `shared_preferences` | ^2.3.2 | Storing non-sensitive UI and app configuration. |
| `flutter_secure_storage`| ^10.0.0 | Encrypted storage for the master app PIN. |
| `local_auth` | 2.3.0 | Biometric authentication gate (Fingerprint/FaceID). |
| `pdfrx` | ^2.2.20 | High-performance PDF display and text search. |
| `syncfusion_flutter_pdf`| ^32.1.22 | Low-level PDF logic (split, merge, page rotation). |
| `path_provider` | ^2.1.4 | Finding internal and external storage directories. |
| `file_picker` | ^10.3.8 | Native OS file selection for imports. |
| `flutter_local_notifications`| ^19.5.0 | Background export progress and success alerts. |
| `receive_sharing_intent`| ^1.8.1 | Handling PDFs shared "to" the app from other apps. |
| `dio` | ^5.7.0 | HTTP client for checking GitHub updates. |
| `package_info_plus` | ^8.1.0 | Fetching version/build number for update checks. |
| `share_plus` | ^10.0.0 | Exporting/Sharing PDFs back to other apps. |
| `shimmer` | ^3.0.0 | Skeleton loading effect in the All Documents scanner. |
| `intl` | ^0.20.2 | Date and currency formatting. |
| `permission_handler` | ^12.0.1 | Orchestrating storage and biometric permissions. |
| `open_filex` | ^4.3.2 | Opening exported ZIPs in external file managers. |

## Folder Structure
```text
/lib
  /core
    /constants       - Global strings, database table names, and keys.
    /navigation      - Global navigator key and routing utilities.
    /theme           - Material 3 theme data and color schemes.
    /widgets         - Reusable buttons, cards, and input fields.
  /features
    /authentication  - BiometricLockScreen, PinEntryScreen, and Auth widgets.
    /documents       - AllDocumentsScreen, DocumentDashboardScreen, FileInfoScreen.
    /password_manager- PasswordManagerScreen and vault logic.
    /settings        - SettingsScreen, Theme picker, and App configuration.
    /update          - Update checks, release notes, and APK downloader.
    /pdf_tools       - Split, Merge, and Reorder tool logic/UI.
    /recent_documents- History tracking (RecentDocumentsScreen).
  /models            - Data entities: DocumentItem, PasswordModel, RecentDocumentModel.
  /services          - Core logic: DocumentService, StorageService, ExportQueueService.
  main.dart          - The Root of the app, service injection, and entry logic.
/assets
  /images            - Illustrative SVG/PNG assets for empty states.
  /branding          - App icons and animated splash logo assets.
/android             - Gradle, Manifest, and native Android configuration.
/ios                 - Podfile, Info.plist, and native iOS configuration.
```

## Build Flavors & Environments
- **Debug**: Standard development mode with hot reload and verbose logging.
- **Release**: Optimized production build. Uses obfuscation (`--obfuscate`) to protect intellectual property.
- **Update Channel**: The app checks a specific GitHub repository URL (via `UpdateService`) for new `version.json` metadata and releases.
- **Environment**: 100% Offline by design. No cloud analytics or data collection.
