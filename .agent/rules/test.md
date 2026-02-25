---
trigger: always_on
---

# Agent Rules
## Build Logging and Output
- **Rule**: Any build process (specifically **Flutter build** or Gradle build) MUST have its output saved to a log file use utf 8 format for saving the text.
- **Filename Format**: `build_<timestamp>.txt` (e.g., `build_20240101_120000.t`).
- **Target Directory**: `D:\Repos\passwordpdf\logs`
  > **Note**: If `D:\Repos\passwordpdf\logs` is not accessible in the current workspace, use the `logs/` directory in the project root.
## Workflow
- When asked to build, log them to a file in logs folder with filename build_<timestamp>.txt

# Release Workflow & Rules

This document outlines the strict process for building and releasing updates for PasswordPDF.

## 1. Versioning (CRITICAL)

Before building, you **MUST** update the version in **TWO** locations to avoid version code mismatches.

### A. `pubspec.yaml`
Update the `version` field:
```yaml
version: 1.0.1+105  # format: <major>.<minor>.<patch>+<build_number>
```

### B. `android/local.properties` (Manual Override)
Gradle often fails to pick up the `pubspec.yaml` change immediately. Manually edit `android/local.properties`:
```properties
flutter.versionName=1.0.1
flutter.versionCode=105
```
*Failure to do this will result in an APK with the old version code, causing update loops.*

---

## 2. Build Process

### Debug Build
Required for testing and verification.
1. Open Terminal.
2. Navigate to `android` folder: `cd android`
3. Run Build: `gradlew.bat assembleDebug`
4. **Output Location**:  
   `d:\Repos\passwordpdf\android\app\build\outputs\apk\debug\app-debug.apk`

### Release Build
Required for deployment.
1. Open Terminal.
2. Navigate to `android` folder: `cd android`
3. Run Build: `gradlew.bat assembleRelease`
4. **Output Location**:  
   `d:\Repos\passwordpdf\android\app\build\outputs\apk\release\app-release.apk`
   *(Note: Do not look in `build/app/outputs/flutter-apk`, look in `android/app/build/...`)*

---

## 3. Deployment Workflow

When a "Release" is requested:

1. **Target Repo**: Go to `D:\Repos\passwordpdf-releases`.
2. **Follow Rules**: Read `D:\Repos\passwordpdf-releases\release_rules.md`.
   - **Rule**: Keep only the **latest 3 versions**. Delete older ones.
3. **Create Directory**: Create a new folder for the version (e.g., `releases/v1.0.1`).
4. **Copy Artifact**: Copy the `app-release.apk` from the build output to this new folder.
5. **Update JSON**: Edit `version.json` in the releases repo to point to the new version and URL.
6. **Push**: Commit and push changes to `passwordpdf-releases`.

---

## Quick Checklist
- [ ] Bump `pubspec.yaml`
- [ ] **Bump `android/local.properties`** (Manual)
- [ ] Build Release APK
- [ ] Deploy to Releases Repo
- [ ] Cleanup old versions (Max 3)
- [ ] Push Code
