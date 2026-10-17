# PDF Password Manager — RECOMMENDED FEATURES BACKLOG

> **Audience: product owner + senior engineer.** Prioritized enhancements that fit `passwordpdf_manager`'s privacy + offline posture and are shipping in real 2026 competitors (Bitwarden, Proton Pass, 1Password, and modern PDF apps).
>
> Each item lists **what**, **why it matters**, **rough effort** (S = ~1–3 days, M = ~1–2 weeks, L = 2+ weeks), **the Flutter/Android tech to use**, and **security caveats** so nothing here silently regresses the "no cloud, no telemetry, on-device only" contract.
>
> Ordered by **impact-per-effort** for a small team. Everything here is optional; nothing blocks a Play or sideload release.

---

## Top-tier (do these first if any features happen)

### 1. FLAG_SECURE — hide sensitive screens from screenshots + Recents thumbnail  **[S]**
- **What:** Set `WindowManager.LayoutParams.FLAG_SECURE` on the password vault, PDF viewer, backup dialog, and Settings→Backup screens so Android disallows screenshots and blanks the app's thumbnail in Recents.
- **Why:** #1 free security upgrade for a password/PDF app. Prevents accidental cloud-sync of screenshots to Google Photos and stops shoulder-surfing via the Recents peek.
- **Tech:** `package:flutter_windowmanager` (or a tiny platform channel calling `getWindow().addFlags(FLAG_SECURE)`). Toggle per-screen in `initState`, remove in `dispose`.
- **Caveats:** Some accessibility tools use screenshots; make this a **user setting** (default ON), not a hard-lock.
- **Starter card:** add `bool _secureFlagApplied` field; in `initState` call `FlutterWindowManager.addFlags(FLAG_SECURE)`; in `dispose` `clearFlags(FLAG_SECURE)`. Apply to `PdfViewerScreen`, `AddPasswordDialog`, `_promptPassphrase`, and the developer screen. Setting: `Settings → Security → Prevent screenshots on sensitive screens (default ON)`.

### 2. Credential Manager provider (autofill for other apps)  **[L]**
- **What:** Register the app as a **Credential Provider** (Android 14+ Credential Manager) or Autofill Service (Android 8+ fallback) so Chrome, banking apps, etc. can fill saved passwords from this vault — with a biometric prompt each time.
- **Why:** This is the single biggest feature separating "password vault" from "password *manager*". Every real competitor ships it. It's also a huge Play Store discoverability signal (users search "autofill" a lot).
- **Tech:** Android 14+ = `CredentialProviderService` (recommended, future-proof). Android 8+ fallback = `AutofillService`. In Flutter, both require Kotlin/Java native code — no full-Dart plugin exists yet. Expect ~300–500 LOC of native + a small platform channel to look up entries by domain.
- **Caveats:** MUST require biometric on each fill. MUST match by canonical domain (strip subdomain to eTLD+1) — a naive `contains` check leaks passwords across sites. Sources: <https://developer.android.com/identity/sign-in/credential-provider>, <https://developer.android.com/identity/autofill/autofill-services>.
- **Compat note:** works on both sideload and Play flavors — no policy issue.

### 3. TOTP / 2FA codes stored alongside passwords  **[M]**
- **What:** Add an optional TOTP secret to each password entry; display a rotating 6-digit code (30-second window) below the password field; QR scanner for `otpauth://` provisioning URLs; auto-clear code from clipboard after ~30s.
- **Why:** Users don't want to keep a second app for 2FA if they already trust yours. Bitwarden, Proton Pass, 1Password all do this. It's a small feature that increases daily-use stickiness.
- **Tech:** `package:otp` (pub.dev — pure Dart, HOTP/TOTP). QR scanner via `mobile_scanner` or `qr_code_scanner`. Store the seed as another AES-GCM-encrypted field on the password row.
- **Caveats:** Include TOTP seeds in the encrypted portable backup (`.pwdbak` schema). Never log the seed. Some services (Google) recommend keeping 2FA on a separate device — accept that some users won't want this feature. Add a Settings toggle.

### 4. zxcvbn strength meter + offline HIBP-lite breach check  **[M]**
- **What:** On password create/edit, show a live 5-tier zxcvbn strength meter. On save, look up the password in a bundled offline dataset (Bloom filter of the top ~1M HaveIBeenPwned hashes, ~2 MB); warn if seen. **Never phone home** — no k-anonymity API calls.
- **Why:** Modern password managers all show strength + breach status. It's a security-culture upgrade that costs nothing to the user's trust because it's fully offline.
- **Tech:** `package:zxcvbnm` (pub.dev — Dart port of Dropbox's zxcvbn). For HIBP: download the top-N SHA-1 hashes from <https://haveibeenpwned.com/Passwords>, build a Bloom filter (e.g. via `package:dart_bloom_filter`), ship as an asset. Update the asset annually.
- **Caveats:** MUST NOT call any external API. The Bloom filter has a false-positive rate — tune to <1%. Store the built-filter file as an asset, not a network fetch (that'd be a policy issue on Play, per the executable-code-download rule).

### 5. Duress / decoy vault (secondary PIN opens a fake vault)  **[L]**
- **What:** In Settings, opt into a "duress passphrase" — entering it at unlock unlocks a **decoy** vault (indistinguishable from the real one at the file layer). The user shows the decoy to coercion, keeps the real vault secret.
- **Why:** A real security posture upgrade for high-risk users. Some competitors do it (Passwarden), most don't — differentiator.
- **Tech:** Derive a **second** Argon2id key from the duress passphrase; keep a second encrypted DB file (same size as real one — pad to fixed size or grow together to defeat file-size analysis). Constant-time compare between the two keys.
- **Caveats:** HARD to get right — indistinguishability is subtle. Padding must be careful; the second DB must be modified in sync with the primary or its inactivity is a giveaway. **Don't ship v1** — prototype behind a hidden setting for a full release cycle first. Source: <https://www.passwarden.com/help/manuals/how-to-manage-duress-mode>.

---

## Mid-tier (good ROI, no dependencies)

### 6. Camera document scanner (PDF from photos)  **[M]**
- **What:** "Scan document" button → camera → auto-crop edges + straighten → save as multi-page PDF into the encrypted document store.
- **Why:** Common ask; competitors (Google Drive, Adobe Scan) do it well; keeps users in-app for the whole workflow.
- **Tech:** **On GMS devices (has Google Play services):** `google_mlkit_document_scanner` — Google's on-device scanner. Free, works offline after the model downloads once. **Non-GMS (rare):** fall back to a plain camera + `image_cropper` (`package:image_cropper`) with manual four-point selection.
- **Caveats:** Requires `CAMERA` permission — add rationale. The ML Kit model downloads on first use (~5 MB); this is the **ONLY** allowed network fetch even on a "no cloud" app because it's Google's on-device SDK, not our servers — and it's a **one-time** download. Document this clearly in the privacy policy. Source: <https://developers.google.com/ml-kit/vision/doc-scanner/android>.

### 7. Offline OCR — text search inside PDFs  **[M]**
- **What:** Index the text content of every PDF (via OCR for scanned pages, native extraction for text PDFs); "search" bar at the top of the docs screen searches across content, not just filenames.
- **Why:** Massive UX win for anyone with more than ~20 PDFs. This is what makes a "document manager" feel like one.
- **Tech:** For native text extraction: `syncfusion_flutter_pdf` already has `PdfTextExtractor`. For OCR: `flutter_tesseract_ocr` (pub.dev) — bundle `eng.traineddata` (~15 MB) as an asset. Store the extracted text in a SQLite FTS5 table encrypted with the same v2 AES key.
- **Caveats:** FTS5 indexing is CPU-intensive; run in a background isolate. The index CAN reveal the presence of documents even under file-system encryption — treat the SQLite file as sensitive (already covered by our `allowBackup=false`). Add a per-user opt-in; some users may prefer to NOT index. Source: <https://pub.dev/packages/flutter_tesseract_ocr>.

### 8. PDF annotations + image-signature stamp + form filling  **[L]**
- **What:** Enable annotation toolbar (highlight, underline, note); "Draw signature" or "Import signature image" → stamp it on a page; fill fields on interactive PDF forms.
- **Why:** These are the top three features that make people leave for Adobe / Foxit. Ship them and this becomes a real PDF app, not just a viewer.
- **Tech:** `syncfusion_flutter_pdfviewer` supports annotations + form fill out of the box; the existing `syncfusion_flutter_pdf` handles form fields programmatically. Signature: draw on a `SignaturePad` widget → convert to PNG → embed as a stamp annotation. **Save-as-new-copy always** (never overwrite the original — same invariant as the Word/Excel edit runbook).
- **Caveats:** Signatures stored in the encrypted vault (they're PII); require biometric on first insert. Play listing: don't claim "digitally sign PDFs" without qualifying it (that implies cryptographic signing, not a stamp). Source: <https://help.syncfusion.com/document-processing/pdf/pdf-viewer/flutter/form-filling>.

### 9. Categories / tags / favorites (light taxonomy)  **[S]**
- **What:** Optional tags (`work`, `banking`, `personal`) and a "favorite ⭐" flag per password + per document. Filter chips at the top of each list.
- **Why:** Small effort; big organizational win once a user hits ~50 entries.
- **Tech:** Pure schema — add a `tags TEXT` (JSON array) and `is_favorite INTEGER DEFAULT 0` column to the passwords + documents tables (SQLite migrations already handled in `StorageService`). Add `Chip` filter row + a `⭐` toggle button.
- **Caveats:** Tags MUST be encrypted (they're metadata that leaks intent) — treat them as v2-encrypted fields.

### 10. Chrome/Firefox CSV password import  **[S]**
- **What:** "Import from Chrome/Firefox CSV" → file-picker → preview + de-dupe → import. On completion, prompt "securely delete the source file" (overwrite with zeros, then unlink).
- **Why:** Zero-friction onboarding for users switching from a browser's built-in manager. Currently we have no import path — every user has to hand-type.
- **Tech:** `package:csv` for parsing. Auto-detect Chrome format (`name, url, username, password`) vs. Firefox (`url,username,password,httpRealm,formActionOrigin,guid,timeCreated,timeLastUsed,timePasswordChanged`). Encrypt on insert.
- **Caveats:** The CSV contains cleartext passwords. Immediately encrypt on insert; then overwrite the source file before unlinking (Android's default `delete()` doesn't securely wipe). Warn the user if they leave the source file in place.

---

## Lower-tier (polish + long-tail)

### 11. i18n / localization foundation  **[M]**
- **What:** Extract all hardcoded strings to ARB files; ship English + one pilot locale (Spanish or Hindi).
- **Why:** Doubles the addressable Play audience if the pilot lands. Also unblocks per-locale store listings.
- **Tech:** `flutter_localizations` + `intl`. `l10n.yaml` with `generate: true`. Move all `Text('…')` to `AppLocalizations.of(context).…`.
- **Caveats:** ~300+ strings today — expect a chunky refactor. Don't ship a locale that's only 30% translated (worse UX than English-only).
- **Source:** <https://docs.flutter.dev/ui/internationalization>.

### 12. Home-screen "Quick Open" widget for recent PDFs  **[M]**
- **What:** Android widget showing the last 3–5 opened PDFs; tap → opens straight into `PdfViewerScreen`.
- **Why:** Trickle of daily engagement; well-loved feature in file managers.
- **Tech:** Android widgets require native Kotlin. Use `home_widget` (pub.dev) as the Flutter↔widget bridge. Update the widget on every doc open.
- **Caveats:** Widget can't be behind the biometric lock — either always require biometric on tap (annoying) or accept that recent-filenames are visible on the lock screen. Add a Settings toggle "Show recents on home widget (may reveal filenames)".

### 13. Multi-device "sync" via QR-hop encrypted backup  **[M]**
- **What:** On device A: "Send vault to another device" → shows a QR code sequence encoding the encrypted backup blob (chunked, ~200 chars each). Device B: "Receive vault" → camera scans the QR stream → decrypts with passphrase.
- **Why:** Gives users a *sync* story without adding a server (which would break the "no cloud" pitch). Best for one-time onboarding to a new phone.
- **Tech:** `mobile_scanner` for reading; `qr_flutter` for rendering. Chunk the encrypted backup into ~1–2 KB base64 QR frames; add a small sequence header + Reed-Solomon parity to survive missed frames. For large vaults (>5 MB), fall back to Wi-Fi Direct via `flutter_p2p_connection`.
- **Caveats:** QR-hop for large vaults is slow (~30 sec per MB). Encourage users to try Wi-Fi Direct for anything over ~1 MB. Both parties must be physically together — that's the whole point (no MITM surface).

### 14. Per-screen auto-lock timeout heuristics  **[S]**
- **What:** Instead of one global auto-lock, per-screen: password vault locks after 30s inactive; docs list locks after 5 min; PDF viewer never locks while user is scrolling.
- **Why:** Reduces annoyance without reducing security. Every touch on the vault screen resets the timer; a user reading a long PDF isn't kicked out just because the global timer expired.
- **Tech:** `Timer` per screen, reset on `PointerDownEvent` via a `Listener` wrapper.
- **Caveats:** The `PdfViewerScreen` is showing sensitive content — don't allow "never lock" here; cap at ~15 min.

### 15. Password history (last 5 values per entry)  **[S]**
- **What:** When editing a password, remember the previous 5 values (encrypted). "History" view shows dates + last-used.
- **Why:** Recovery from accidental change; some users write down their old password with the new one.
- **Tech:** New SQLite table `password_history(id, password_id, encrypted_value, changed_at)`. Encrypt with v2 AES key. Cap at 5 rows per entry (delete oldest on insert).
- **Caveats:** Each history row is a full password — encrypt properly. Purge history on password delete. Include (or not) in backups — user-configurable.

### 16. Password expiry reminders  **[S]**
- **What:** Per-entry "reminder every N days"; a badge on the entry once expiry hits; optional local notification.
- **Why:** Compliance/security hygiene. Every enterprise pw manager does this.
- **Tech:** Store `expires_at` in the password table. Notifications: `flutter_local_notifications` (already in pubspec). Check once per day at app launch.
- **Caveats:** Notifications on Android 13+ require the (already declared) POST_NOTIFICATIONS permission. Don't show the password in the notification body — just "N passwords are due for rotation".

### 17. FIDO / passkey provider  **[L]**
- **What:** Register the app as a **passkey** provider (WebAuthn credentials stored locally, unlocked with biometric). Sites like GitHub, Google, and Apple support passkeys — this app becomes a passkey vault too.
- **Why:** Passkeys are the direction the whole industry is moving. Bitwarden, 1Password already ship this.
- **Tech:** Android Credential Manager (Android 14+) — same integration as feature #2, plus CBOR encoding for the credential blob. `package:cbor` for encoding. Store the passkey blob in the v2-encrypted vault.
- **Caveats:** Serious crypto — WebAuthn spec compliance matters. Adopt an existing library (`webauthn_dart` if it materializes, else look at native SDKs). Don't hand-roll ES256/EdDSA signing.

---

## Deliberately deferred (has good reasons)

- **Cloud sync** — would break "no cloud" positioning; adds server + backups + user-account complexity. If you ever do it, use **client-side E2E encryption** and be very explicit in the store listing.
- **Sharing individual passwords with a specific person** — social-engineering surface. If someone asks, they can use the passphrase backup export.
- **Password generation with custom rules** — the built-in `Random.secure()` generator already covers 95% of use cases. Advanced rulesets add UI complexity.
- **Cross-app "recently used" hints** — leaks browsing patterns. Even if we render offline, the recency data is sensitive.

## General suggestions (not features per se — orthogonal engineering wins)

- **Add a small test suite for the crypto paths.** The audit lens for this returned garbage; I'd write it by hand. Priority order: (1) `decrypt()` v1/v2 dispatcher, (2) password backup round-trip with wrong passphrase / bad magic / KDF-clamp bounds, (3) `PasswordMigrationService` prove-before-overwrite (make a "poisoned" v1 row and confirm it's skipped, not corrupted), (4) `DocsSettingsBackupService.restoreFromBytes` (magic separation, KDF-clamp, atomicity). Check in golden fixtures (`.pwdbak` + docs backup files) so any envelope regression is caught forever.
- **Off-machine keystore backup NOW.** The current `~/.android/debug.keystore` is a single-point-of-failure — losing that disk bricks every existing sideloaded install forever. Copy it to a password vault + a second physical location this week. (This is separate from the Play upload keystore in `PLAYSTORE-RELEASE-RUNBOOK.md §2`.)
- **`CHANGELOG.md` at the repo root.** `version.json`'s releaseNotes is the only artifact today — a proper changelog helps triage bug reports ("this broke in 1.2.4").
- **GitHub Issues on the repo**, or any lightweight tracker. Real bug reports today have nowhere to live except memory files + these runbooks.
- **"Safe mode" launch flag** (long-press launcher icon → open in a mode that skips auto-lock + auto-open-intent). Saves your bacon if a user's saved state is wedged. Tiny effort.
- **`local.properties.example` template** in the repo — documents the exact `flutter.versionName` / `versionCode` variables so a new dev machine doesn't miss the two-file bump.
- **`aab.md`-style checklist** in the repo pointing at `PLAYSTORE-RELEASE-RUNBOOK.md`'s §8 pre-flight, so it's never skipped on a Play submission.

---

## Sequencing recommendation (my opinion)

If you want a **next-release feature theme**, ship these three together as **1.3.0**:
1. **FLAG_SECURE** (feature 1) — a couple of days, ships free security.
2. **Categories/tags/favorites** (feature 9) — small; a big organizational unlock.
3. **Chrome/Firefox CSV import** (feature 10) — small; hugely lowers onboarding friction.

That's a coherent "organizes better + safer" theme, all small-effort, no crypto risk. Reserve **1.4.0** for **Credential Manager autofill** (feature 2) — that's the L-effort investment worth doing as a headline release.

TOTP-in-vault (feature 3) is a strong candidate for **1.5.0** alongside the Word/Excel viewer runbook milestones.

Doc scanner + OCR (features 6 + 7) go together as a "document manager v2" release, some time after that.
