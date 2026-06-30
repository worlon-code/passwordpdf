# 12 Permissions - PasswordPDF

## Table of Contents
1. [Permission Strategy](#permission-strategy)
2. [Required Permissions](#required-permissions)
3. [Android Manifest](#android-manifest)
4. [Denial Handling](#denial-handling)

---

## Permission Strategy
Permissions are requested **on-demand** or during the initial setup flow via the `PermissionService`.

## Required Permissions

| Permission | Purpose | Requested When |
|------------|---------|----------------|
| **Storage (Read/Write)** | Accessing device PDFs and saving ZIP exports. | Initial startup or first Import action. |
| **Biometrics** | Unlocking the app with Fingerprint/FaceID. | Initial startup if enabled. |
| **Manage External Storage**| Comprehensive file browsing in "All Documents".| Android 11+ for full system scan. |
| **Install Packages** | In-app updates (installing downloaded APKs). | When user clicks "Install Update". |
| **Notifications** | Showing background export progress. | Initial startup. |

## Android Manifest
Core permissions defined in `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.USE_BIOMETRIC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.INSTALL_PACKAGES" />
```

## Denial Handling
Handled in `lib/services/permission_service.dart`:
- **Graceful Failure**: If storage permission is denied, the "All Documents" screen shows an "Access Denied" state with a button to "Open Settings".
- **Biometric Fallback**: If biometric permission is denied or revoked, the app automatically fails over to **PIN Authentication**.
