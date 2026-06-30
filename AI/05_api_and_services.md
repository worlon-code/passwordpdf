# 05 API & Services - PasswordPDF

## Table of Contents
1. [Overview](#overview)
2. [Local Services](#local-services)
3. [Update API](#update-api)
4. [Error Handling Strategy](#error-handling-strategy)
5. [Key Logic Flows](#key-logic-flows)

---

## Overview
PasswordPDF is a **locally focused app** and does not interact with a primary backend API for user data. However, it uses several services for background processing, security, and update checks.

## Local Services

| Service Name | File Path | Methods & Purpose |
|--------------|-----------|-------------------|
| **DocumentService** | `lib/services/document_service.dart` | `addReference()`: Add file path to DB.<br>`syncFolder()`: Scan disk for changes.<br>`createFolder()`: Virtual folder management. |
| **EncryptionService**| `lib/services/encryption_service.dart`| `encrypt()`: XOR encryption for passwords.<br>`isKeySet()`: Check if master key exists. |
| **ExportQueueService**| `lib/services/export_queue_service.dart`| `enqueueExport()`: Start background ZIP task.<br>`showImportNotification()`: Progress alerts. |
| **UpdateService** | `lib/features/update/services/update_service.dart` | `checkForUpdate()`: Check GitHub for new releases.<br>`downloadUpdate()`: Download APK via Dio. |
| **LoggingService** | `lib/services/logging_service.dart` | `info()`, `error()`: Write logs to SQLite with rotation. |
| **PermissionService**| `lib/services/permission_service.dart`| `requestStoragePermission()`: Access device PDFs.<br>`requestBiometricPermission()`: Hardware auth access. |
| **BiometricService** | `lib/services/biometric_service.dart` | `canCheckBiometrics()`: Hardware check.<br>`authenticate()`: Trigger OS biometric prompt. |

## Update API (GitHub)
The app checks for updates by fetching metadata from a release JSON file hosted on GitHub.
- **Base URL**: Configured in `UpdateService` (GitHub Releases).
- **Security**: None (Publicly accessible JSON).
- **Request**: `GET /version.json`
- **Response**: `{ "version": "1.1.0", "build_number": 105, "url": "..." }`

## Error Handling Strategy
- **Service Layer**: Most methods return `Result` objects or throw specific exceptions caught by the UI.
- **Global Catch**: `main.dart` uses `runZonedGuarded` to catch unhandled async errors.
- **Reporting**: Errors are logged to the `logs` table in SQLite via `LoggingService`.

## Key Logic Flows

### DIAGRAM 1: PDF Password Unlock
```mermaid
sequenceDiagram
  participant UI as PdfViewerScreen
  participant DS as DocumentService
  participant PS as PasswordService
  UI->>DS: Open PDF (filePath)
  DS->>UI: Protected (True)
  UI->>PS: Get Saved Passwords
  PS-->>UI: List of [Key, EncryptedVal]
  loop Auto-Unlock
    UI->>UI: Try DecryptedVal
  end
  alt Success
    UI->>UI: Render PDF
  else Fail
    UI->>UI: Show User Password Dialog
  end
```

### DIAGRAM 2: GitHub Update Check Flow
```mermaid
sequenceDiagram
  participant App as Startup / Settings
  participant US as UpdateService
  participant GH as GitHub Server
  participant SYS as OS Installer

  App->>US: checkForUpdate()
  US->>GH: GET /version.json (via Dio)
  GH-->>US: { version, build_number, url }
  US->>US: compare build_number vs package_info_plus
  alt Newer version available
    US-->>App: show update banner
    App->>US: downloadUpdate()
    US->>GH: download APK
    US->>SYS: trigger INSTALL_PACKAGES
  else Already up to date
    US-->>App: no banner shown
  end
```

### DIAGRAM 3: File Import + Duplicate Detection
```mermaid
sequenceDiagram
  participant User as User
  participant FSB as FileSystemBrowser
  participant DS as DocumentService
  participant SQL as SQLite DB

  User->>FSB: select PDF file(s)
  FSB->>DS: addReference(path)
  DS->>SQL: SELECT WHERE path = ? (primary check)
  alt Path match found
    DS-->>FSB: show ConflictResolutionDialog
    FSB-->>User: Skip / Rename / Overwrite
  else No path match
    DS->>SQL: SELECT WHERE size = ? (secondary check)
    alt Size match found
      DS-->>FSB: show ConflictResolutionDialog
    else No match
      DS->>SQL: INSERT into files_index
      DS->>DS: notifyListeners()
      FSB-->>User: Dashboard rebuilds with new file
    end
  end
```
