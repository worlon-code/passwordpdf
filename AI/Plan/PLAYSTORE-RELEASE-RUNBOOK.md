# PDF Password Manager — PLAY STORE RELEASE RUNBOOK

> **Audience: a senior engineer + the person who owns the Play Console account.** This is NOT the fix-agent runbook. Play requires human judgement calls (developer-account entity, policy declaration text, demo video) that a low-capability agent cannot make. It also contains work the agent can execute (build flavors, manifest changes, signing wiring) — those are called out as **AGENT-SAFE** cards.
>
> Baseline: the app is currently **sideloaded** (1.2.6+125), **debug-signed** with the workstation's Android debug key, ships a **self-updater**, holds **MANAGE_EXTERNAL_STORAGE**, and is fully offline (no telemetry). All research below is verified against 2026 Google Play policy sources.

---

## 0. Read this first — the hard truths (2026)

1. **The current APK cannot be uploaded to Play as-is.** Two absolute blockers: (a) it's signed with the workstation's Android debug keystore — Play will reject it; (b) it ships a self-updater (REQUEST_INSTALL_PACKAGES + APK download + install-via-VIEW-intent) — Play policy forbids this in both the **REQUEST_INSTALL_PACKAGES** and **Device and Network Abuse** rules. The self-updater must be **compiled out** of the Play build, not just hidden at runtime — static analysis of the APK will catch a hidden version.
   - Sources: <https://support.google.com/googleplay/android-developer/answer/12085295>, <https://support.google.com/googleplay/android-developer/answer/16559646>.
2. **MANAGE_EXTERNAL_STORAGE will be a fight.** Play only approves it for a narrow set (file managers, backup/restore, anti-virus, **document management**, on-device search, disk/folder encryption, device migration). The **password-vault** framing does NOT justify All-Files-Access — Google will point at SAF. The **document-manager** framing (auto-scan for existing PDFs across the device) does justify it, but the listing, screenshots, and in-app prompt all have to lead with that story.
   - Source: <https://support.google.com/googleplay/android-developer/answer/10467955>.
3. **Existing sideloaded users cannot in-place-upgrade to the Play build.** The APK signature will change (debug → real release key). Every sideloaded user will get "app not installed" and must **export their backup → uninstall the sideload → install from Play → restore backup.** Plan the migration message + verify the backup export/restore path across install boundaries before the switchover.
4. **Play only accepts AABs** (Android App Bundle) for new apps, not APKs. Flutter target is `flutter build appbundle` (keep `flutter build apk` for sideload).
5. **Play uses "Play App Signing":** you upload with an **upload key**; Play holds the actual **signing key**. Choose "Google-managed signing key" when enrolling — nothing to preserve on the signing side because we're starting fresh.
6. **Personal Play account = 12 testers × 14 days closed-testing gate** before you can promote to production. Organization (Deloitte D-U-N-S) accounts skip this gate. This choice dominates the timeline — settle it first.
   - Source: <https://support.google.com/googleplay/android-developer/answer/14151465>.
7. **First-app review: 7–14 days.** Established accounts clear faster. Don't announce a launch date until the first internal-track build has passed once.

## 1. Two-flavor build strategy (foundational — do this before anything else)

We cannot ship the same APK to Play and sideload. Introduce **Android product flavors** so the sideload flavor keeps the self-updater + MANAGE_EXTERNAL_STORAGE self-service, and the Play flavor strips both out.

**Change (agent-safe): `android/app/build.gradle` — add inside `android { … }`:**
```groovy
android {
    // … existing config …
    flavorDimensions "distribution"
    productFlavors {
        sideload {
            dimension "distribution"
            // Current arm64-only + self-updater lives here (default).
        }
        play {
            dimension "distribution"
            // Play-safe: no updater, no APK-install permission.
            manifestPlaceholders = [enableUpdater: 'false']
        }
    }
}
```

**Two manifests:** create `android/app/src/play/AndroidManifest.xml` that OMITS:
- `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>`
- `<uses-permission android:name="android.permission.INTERNET"/>` (only needed for the updater — remove if truly unused after this refactor)

Everything else stays in the shared `main/AndroidManifest.xml`. Play's manifest merger will union the two.

**Compile-time flavor gate in Dart:** the Play flavor must not even *contain* the updater bytecode.
- Move `lib/features/update/**` into `lib/features/update/` (keep) and reference it ONLY from a per-flavor entry point.
- Create `lib/main_sideload.dart` and `lib/main_play.dart` — each imports the shared `main.dart` runtime and either wires `UpdateService()` in (sideload) or leaves it out (play).
- Build with `flutter build appbundle --flavor play -t lib/main_play.dart --release` for Play; `flutter build apk --flavor sideload -t lib/main_sideload.dart --release` for sideload.

**Verification (mandatory before Play submission):**
```
unzip -l app-play-release.aab | grep -iE "update_service|updater"        # MUST be empty
aapt2 dump permissions app-play-release.aab | grep -iE "INSTALL_PACKAGES|INTERNET"   # MUST be empty
```

**Commit:** `build: add play + sideload product flavors (self-updater compiled out of play flavor)`.

## 2. Real signing key + Play App Signing enrollment

**Prerequisites:**
- Decide the account entity (Deloitte org D-U-N-S vs. personal Gmail). Settle with Deloitte legal + IT if org. **This blocks everything else.**
- Register the developer account ($25 one-time), pass identity verification (Deloitte org → D-U-N-S; personal → ID).

**Generate a real upload keystore** (do this on the machine, back it up off-machine immediately):
```
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 4096 -validity 10000 -alias upload
```
- Store in a password vault (1Password / Bitwarden). ALSO store `keystore-password`, `key-password`, `alias`.
- Off-machine backup MANDATORY — if this file is lost after enrollment, the upload cert must be reset (contact Play support; is disruptive).

**Wire into Gradle (agent-safe):** create `android/key.properties` (already in `.gitignore` per Phase 0 of PENDING-AGENT-RUNBOOK):
```properties
storePassword=<from vault>
keyPassword=<from vault>
keyAlias=upload
storeFile=<absolute path to upload-keystore.jks>
```

Edit `android/app/build.gradle`:
```groovy
def keystorePropertiesFile = rootProject.file("key.properties")
def keystoreProperties = new Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        release {
            storeFile file(keystoreProperties['storeFile'])
            storePassword keystoreProperties['storePassword']
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.release   // was signingConfigs.debug
            minifyEnabled false
            shrinkResources false
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
}
```

**Play App Signing enrollment:** in Play Console → Setup → App integrity → App signing, choose **"Use a key generated by Google"**. Upload your upload cert (extract via `keytool -export -alias upload -keystore upload-keystore.jks -file upload_certificate.pem`). Google holds the actual signing key from now on.

**Sources:** <https://support.google.com/googleplay/android-developer/answer/9842756>, <https://developer.android.com/studio/publish/app-signing>.

## 3. AAB build + 16 KB page-size alignment

**Build command** (Play): `flutter build appbundle --flavor play -t lib/main_play.dart --release --obfuscate --split-debug-info=build/symbols`.

Keep `abiFilters 'arm64-v8a'` — the AAB per-device delivery will still ship arm64-only bytes to arm64 devices; combined with our target audience (modern devices), 32-bit is a defensible drop.

**16 KB page-size alignment** (new in 2026, mandatory for Android 15+ 64-bit devices from Nov 1 2025): every native `.so` in the AAB must be 16 KB-aligned. Our transitive natives come from `pdfrx`, `syncfusion_flutter_pdf`, `sqflite`, `flutter_secure_storage`, `local_auth`. Steps:
1. Set `android.ndkVersion` to NDK r28+ (in `android/app/build.gradle`).
2. Upgrade the five plugins to their latest versions (each has done 16 KB-alignment work in 2025).
3. Verify: extract the AAB (`unzip app-release.aab`), then `readelf -lW base/lib/arm64-v8a/*.so | grep LOAD` — every LOAD `Align` value must be `0x4000` (16 KB).
4. If Play Console's pre-launch report warns about alignment, fix or drop the offending plugin BEFORE publishing.

**Source:** <https://developer.android.com/guide/practices/page-sizes>.

## 4. Android 16 behavior compliance (targetSdk 36)

`targetSdk = 36` triggers three mandatory behaviors:
1. **Predictive back:** Flutter 3.35+ ships `OnBackInvokedCallback` support — confirm current FVM Flutter version is ≥ 3.35. Test back navigation across every screen.
2. **Edge-to-edge display:** opt-out is removed. In `main.dart` after `WidgetsFlutterBinding.ensureInitialized()`, add:
   ```dart
   SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
   ```
   Then audit every `Scaffold` — wrap body content in `SafeArea` where the status/nav bars would clip; test PDF viewer + password list on an Android 16 emulator.
3. **16 KB pages** (covered in §3).

**Source:** <https://developer.android.com/about/versions/16/behavior-changes-16>.

## 5. Manifest hardening for Play (agent-safe cards)

### Card 5.1 — Restrict SEND/SEND_MULTIPLE intent-filters
Current manifest accepts `mimeType="*/*"` for share-in. Play reviewers flag "broad sharesheet claims" — narrow to what we handle.

**File `android/app/src/main/AndroidManifest.xml`** — replace the two `<data android:mimeType="*/*"/>` intent-filters with per-MIME variants: `application/pdf`, `application/msword`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document`, `application/vnd.ms-excel`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, `image/*`. (Match the shared-single filter that already exists — copy those `<data>` children.)

Commit: `chore(play): narrow SEND/SEND_MULTIPLE intent-filters (drop mimeType=*/*)`.

### Card 5.2 — Confirm READ_MEDIA_IMAGES removal (already covered by Phase 1 of the fix-agent runbook)
If Phase 1 hasn't run yet, run it. The Play flavor must not declare this permission.

### Card 5.3 — Play-flavor overlay for MANAGE_EXTERNAL_STORAGE
Keep it in `main/` for now (needed for the doc-manager story). If Google rejects the declaration, roll to a SAF-only build (see §11 Contingency).

## 6. Policy assets you need before submitting

These are **not code**. Prepare them in parallel with §1–§5.

### 6.1 Privacy policy (HARD BLOCKER — no submission without it)
Write `PRIVACY.md` and host it at a stable HTTPS URL (GitHub Pages is fine). Contents:
- Fully offline; no telemetry; no analytics; no third-party SDKs.
- Passwords stored locally, encrypted with AES-256-GCM using a device-bound key held in the Android hardware Keystore.
- Documents stay on the device; the app never uploads.
- User data deletion: "clear app data in Settings" or uninstall.
- Contact email for privacy inquiries.

Enter that URL in Play Console → Store presence → Main store listing → Privacy policy AND link it from the app's Settings → About.

**Source:** <https://support.google.com/googleplay/android-developer/answer/9859455>.

### 6.2 Data Safety declaration
Because the app is fully offline (after the self-updater is stripped), the correct answers are:
- **Data collected:** No.
- **Data shared:** No.
- **Security practices:** "Data is encrypted in transit" — mark NOT APPLICABLE (nothing transmits). "You can request that your data be deleted" — describe the in-app data-reset feature (or "delete the app").

Sources: <https://support.google.com/googleplay/android-developer/answer/10787469>.

⚠️ Google's *own* definition: "Collect" = transmit data off the device. On-device processing/encryption is NOT collection. But the form is **still mandatory** — an empty submission is rejected.

### 6.3 MANAGE_EXTERNAL_STORAGE Permissions Declaration
Play Console → App content → Permissions declaration. Draft text (Deloitte legal should review before submission if org account):
```
PDF Manager is a document-management app that scans the user's device for
PDF, Word, and Excel files so the user can view, organize, secure, and back
them up in one place. This on-device scan requires All-Files Access because:

- Scoped Storage / SAF requires the user to pick each file individually. This
  cannot enumerate an entire device's document collection, which is the app's
  primary purpose.
- MediaStore does not index Office documents.
- The app does not access media (photos, video) — it filters strictly to
  document MIME types (.pdf, .doc, .docx, .xls, .xlsx) and displays a plain
  in-app rationale before requesting the permission.

The permission is used only on-device. Nothing is transmitted. Users can
revoke it in Android Settings at any time.
```

Attach a **30–90 second demo video** on YouTube (unlisted): show launching the app → seeing the "All-Files Access" rationale dialog → granting → the scan surfacing the user's existing PDFs → tapping one to open. This is the single most important artifact for approval.

**Source:** <https://support.google.com/googleplay/android-developer/answer/10467955>.

### 6.4 Store listing
- **Category:** Productivity (NOT Finance — Finance triggers extra scrutiny for financial data claims we don't make).
- **Title:** something like "PDF Manager — Password & Document Vault".
- **Short description (30 chars):** "Offline PDF + password vault."
- **Full description:** lead with "**Document manager first**" — on-device PDF/Word/Excel finder, then password/backup features. This framing supports the MANAGE_EXTERNAL_STORAGE justification.
- **Screenshots:** 8 phone + 4 tablet, on-device with realistic (dummy) data. Show the scan, the doc list, opening a PDF, adding a password entry, backup+restore.
- **Feature graphic:** 1024×500, brand-consistent.
- **Icon:** 512×512.
- **Content rating (IARC questionnaire):** should return "Everyone".

**Source:** <https://support.google.com/googleplay/android-developer/answer/9866151>.

### 6.5 Migration notice for existing sideloaded users
Because the Play signature won't match the sideload signature, existing users can't in-place-upgrade. Ship a final sideload release BEFORE launching on Play that shows a one-time dialog:
```
"We're launching on Google Play. To keep receiving updates:
   1. Password Manager → Backup → Save your backup.
   2. Documents & Settings → Backup → Save (optional).
   3. Uninstall this app.
   4. Install PDF Manager from Google Play: <link>.
   5. Restore both backups.
Your passwords never leave this device during the migration."
```
Confirm the backup/restore flow works end-to-end across an uninstall+reinstall before shipping this notice.

## 7. Release-track ladder (do NOT skip)

1. **Internal Testing** (immediate; up to 100 testers by email): 3–5 people from the team. Verify install, biometric unlock, MANAGE_EXTERNAL_STORAGE grant, scan, saved-password unlock, backup/restore on real devices.
2. **Closed Testing** (required 14-day / 12-tester gate for **personal** accounts; org accounts skip it): open a closed track, invite ≥ 12 testers, keep them active for 14 consecutive days.
3. **Open Testing** (optional): public beta URL.
4. **Production** (7–14 day review for first submission).

**Sources:** <https://support.google.com/googleplay/android-developer/answer/9859348>, <https://support.google.com/googleplay/android-developer/answer/14151465>.

**versionCode**: current is 125. Bumping normally (+1 per release) is fine — the Play ceiling is 2,100,000,000.

## 8. Pre-flight checklist (agent-safe run before every Play upload)

```
git pull origin experimental_flutter_upgrade
flutter clean && flutter pub get
flutter build appbundle --flavor play -t lib/main_play.dart --release --obfuscate --split-debug-info=build/symbols

# 1. AAB size + ABI sanity
ls -lh build/app/outputs/bundle/playRelease/*.aab
unzip -l build/app/outputs/bundle/playRelease/app-play-release.aab | grep -c "lib/arm64-v8a"
unzip -l build/app/outputs/bundle/playRelease/app-play-release.aab | grep -c "lib/armeabi\|lib/x86"    # MUST be 0

# 2. Updater compiled out
unzip -p build/app/outputs/bundle/playRelease/app-play-release.aab | strings | grep -iE "update_service|version.json|passwordpdf-releases"    # MUST be empty

# 3. Manifest permissions
aapt2 dump permissions build/app/outputs/bundle/playRelease/app-play-release.aab | grep -iE "REQUEST_INSTALL_PACKAGES|READ_MEDIA_IMAGES"    # MUST be empty
aapt2 dump permissions build/app/outputs/bundle/playRelease/app-play-release.aab | grep MANAGE_EXTERNAL_STORAGE    # present (with declaration)

# 4. 16 KB alignment on native libs
mkdir -p /tmp/aab_check && unzip -o build/app/outputs/bundle/playRelease/app-play-release.aab -d /tmp/aab_check
for so in /tmp/aab_check/base/lib/arm64-v8a/*.so; do
  echo "== $so =="; readelf -lW "$so" | grep LOAD
done
# All Align values must be 0x4000.

# 5. Signature check
jarsigner -verify -verbose -certs build/app/outputs/bundle/playRelease/app-play-release.aab | grep -i "CN=Android Debug"    # MUST be empty (would mean debug-signed)
```

If ANY of the "MUST be empty" checks are non-empty, STOP — do not upload.

## 9. What NOT to do (traps I want to name explicitly)

- ❌ Do not ship the self-updater in a "hidden behind a flag" state in the Play AAB. Static analysis catches it. Kill it at compile time via the flavor.
- ❌ Do not switch to a "provide your own signing key" enrollment. Google-managed is safer for us.
- ❌ Do not add Play Integrity API for v1 — it's optional and there's no server-side check to protect. Add later if we ever add a network feature.
- ❌ Do not add `BIND_ACCESSIBILITY_SERVICE` for autofill. Use **Credential Manager Provider** (Android 14+) — see `RECOMMENDED-FEATURES.md`.
- ❌ Do not host the privacy policy at a URL that requires login (Google Docs). GitHub Pages / any static HTTPS is fine.
- ❌ Do not target Finance as your Play category — Productivity avoids extra scrutiny you don't need.
- ❌ Do not promise "cloud backup" / "sync" in the store listing until it actually exists.

## 10. Optional post-launch: MASA security badge

If you want a visible "independent security review" badge on the listing, budget ~$3–8k and 4–6 weeks for a **Mobile App Security Assessment (MASA)** engagement (App Defense Alliance program). Do this AFTER launch, not as a blocker. Prep: run OWASP MASTG L1 self-check first.

**Source:** <https://appdefensealliance.dev/masa>.

## 11. Contingency plan: MANAGE_EXTERNAL_STORAGE rejected

If Google rejects the declaration despite the doc-manager framing, keep a **SAF-only Play flavor** as fallback. Ready-check:
- Replace the device scanner (`lib/services/device_document_service.dart`) with a "pick your document folder" onboarding using `Intent.ACTION_OPEN_DOCUMENT_TREE`. Persist the granted tree URI via `takePersistableUriPermission`.
- The rest of the app (password manager, backup, PDF viewer) works unchanged over `content://` URIs.
- Docs surface via `DocumentFile.fromTreeUri(...).listFiles()` — no all-files access needed.

This is a real re-architecture (~1–2 weeks). Have it drafted as a design doc before submission so if the declaration is rejected we can turn around in days, not months.

## 12. Timeline reference

Assuming a **Deloitte organization account** (no 12-tester gate):
- **Week 1:** account provisioning + code changes (§1–§5) + privacy policy + declaration draft.
- **Week 2:** internal-testing build uploaded; team validates on real devices.
- **Week 3:** submit to production; expect 7–14 day review.
- **Week 4:** LIVE.

**Personal account** adds ~14 days for closed testing (§7).

## 13. Sources (verified 2026)

- <https://support.google.com/googleplay/android-developer/answer/12085295> — REQUEST_INSTALL_PACKAGES policy (self-updater ban).
- <https://support.google.com/googleplay/android-developer/answer/16559646> — Device and Network Abuse (executable-code download ban).
- <https://support.google.com/googleplay/android-developer/answer/10467955> — MANAGE_EXTERNAL_STORAGE / All-Files Access declaration criteria.
- <https://support.google.com/googleplay/android-developer/answer/10787469> — Data Safety form.
- <https://support.google.com/googleplay/android-developer/answer/14151465> — 12 testers × 14 days closed-testing gate (personal accounts).
- <https://support.google.com/googleplay/android-developer/answer/9842756> — Play App Signing.
- <https://support.google.com/googleplay/android-developer/answer/9859348> — Release tracks (internal → closed → open → production).
- <https://support.google.com/googleplay/android-developer/answer/9859455> — Privacy policy requirement.
- <https://support.google.com/googleplay/android-developer/answer/9866151> — Store listing assets.
- <https://developer.android.com/google/play/requirements/target-sdk> — target SDK requirements (API 35 now, API 36 by Aug 2026).
- <https://developer.android.com/about/versions/16/behavior-changes-16> — Android 16 mandatory behaviors.
- <https://developer.android.com/guide/practices/page-sizes> — 16 KB page-size alignment.
- <https://developer.android.com/studio/publish/app-signing> — signing key generation.
- <https://developer.android.com/guide/app-bundle> — AAB format.
- <https://appdefensealliance.dev/masa> — MASA badge (optional).
