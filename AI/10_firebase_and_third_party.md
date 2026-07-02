# 10 Firebase & Third Party - PasswordPDF

## Table of Contents
1. [Overview](#overview)
2. [Firebase Services](#firebase-services)
3. [Third-Party SDKs](#third-party-sdk)
4. [Initialization](#initialization)

---

## Overview
PasswordPDF is a **privacy-first application** and does not use any cloud-based backend like Firebase for user data or file storage. All data remains on the user's device.

## Firebase Services
- **⚠️ Not Implemented**: The project does not currently use any Firebase services (Auth, Firestore, Storage, or Analytics).

## Third-Party SDKs

| SDK Name | Purpose | Implementation Class |
|----------|---------|----------------------|
| **pdfrx** | High-performance PDF rendering, search, and interaction. | `SfPdfViewer` (integration) |
| **Syncfusion PDF** | Low-level PDF manipulation (Merge, Split, XOR decryption). | `PdfToolsService` |
| **local_auth** | Hardware-level biometric unlocking. | `BiometricService` |
| **share_plus** | Native "Share" functionality. | `FileActions` UI |
| **dio** | Secure HTTP requests for update checks. | `UpdateService` |
| **shimmer** | UI skeleton loading effects. | `AllDocumentsScreen` |

## Initialization
Services are initialized in `main.dart` or on-demand:
1. **Syncfusion**: Initialized with a community license key (if required).
2. **pdfrx**: Initialized internally by the plugin.
3. **Local Auth**: Checked for availability in `AppEntry` via `BiometricService.canCheckBiometrics()`.
