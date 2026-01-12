# Upgrade Plan: Flutter & Ecosystem

This plan outlines the steps to upgrade your environment to support the latest `pdfrx` features while respecting your version preferences.

## 🎯 Objectives
1.  **Flutter SDK**: Upgrade to **Stable 3.27.x** (Latest Stable).
2.  **Packages**: Upgrade `pdfrx` to `^2.2.x` and resolve dependencies.
3.  **Android SDK**: Maintain/Verify **Compile SDK 35** (Android 15), avoiding SDK 36 (Beta/Preview).

---

## 🏗️ Step 1: Upgrade Flutter SDK

Since your global version is 3.24.3, we need to upgrade it to the latest stable release to ensure ecosystem compatibility.

**Run these commands in your terminal:**
```powershell
flutter channel stable
flutter upgrade
```
*Expected Result:* This will take you to Flutter ~3.27.x.

**Verify Version:**
```powershell
flutter --version
```

---

## 📦 Step 2: Upgrade Packages

Update `pubspec.yaml` to use the latest versions of key libraries.

### [pubspec.yaml](file:///d:/Repos/passwordpdf/pubspec.yaml) Changes

**Key Upgrades:**
- `pdfrx`: `^0.4.0` → `^2.2.20`
- `flutter_local_notifications`: `^18.0.1` → `^18.0.1` (Verify constraints)
- `permission_handler`: `^11.3.1` → `^11.4.0`

**Command to run:**
```powershell
flutter pub upgrade --major-versions
```

*(Note: If you encounter conflicts, manually set `pdfrx: ^2.2.20` and run `flutter pub get`)*

---

## 📱 Step 3: Android Configuration Verification

Your `android/app/build.gradle` is already well-configured!

- **compileSdk**: `35` ✅ (Correct, using Android 15 stable)
- **minSdk**: `23` ✅
- **targetSdk**: `flutter.targetSdkVersion` (Defaults to 35 on newer Flutter versions)

**Action:** No manual changes needed in `build.gradle` unless build fails.

---

## 🛠️ Step 4: Code Migration

Upgrading `pdfrx` from `1.x` to `2.x` will likely require code changes in `PdfViewerScreen`.

**Anticipated Changes:**
- `PdfViewer.file(...)` API might slightly change.
- `PdfViewerParams` structure updates.
- **Good News**: Version 2.x supports the `failedPageBuilder` and `loadingBuilder` you wanted!

---

## 🚀 Execution Summary

1.  **Upgrade Flutter**: `flutter upgrade`
2.  **Upgrade Packages**: `flutter pub upgrade --major-versions`
3.  **Fix Code**: Adapt `pdf_viewer_screen.dart` to new APIs.
4.  **Build**: `flutter build apk --debug`

---

**Do you want me to proceed with Step 1 (Upgrade Flutter) and Step 2?**
