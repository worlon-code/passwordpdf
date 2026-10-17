# PDF Password Manager — WORD & EXCEL VIEW/EDIT RUNBOOK (in-app Office)

> **Audience: a senior engineer (NOT a low/auto model).** This adds in-app **viewing and editing of Word (.docx) and Excel (.xlsx)** to `passwordpdf_manager`, replacing today's "hand the file to an external app" behaviour. Editing writes back to real user files, so treat it like the crypto work: **apply ONE card per prompt, verify (`fvm flutter analyze` + unit test), and device-test on real documents before moving on.** Companion to `SENIOR-RUNBOOK.md` (crypto/PDF/export/refactor) and `AGENT-RUNBOOK.md` (done).
>
> **Third-party APIs:** the `Change` blocks give concrete, copy-pasteable code, but every **third-party** package call (excel_plus, pluto_grid, docx_file_viewer, docx_creator) is marked `// VERIFY API` — confirm the exact signature against the pinned version's pub.dev example before committing. The app's OWN code (routing, screens, save/verify services) is given in full.

## How to execute this runbook (implementing model — follow EXACTLY)
1. Work on branch `experimental_flutter_upgrade`; `git pull` before starting.
2. Do **exactly ONE card per commit, in listed order.** Never skip, batch, or reorder cards.
3. For each card, in this order: (a) open the `File(s)`; (b) find the `Locate` text **verbatim** in the file; (c) apply the `Change` exactly — for a NEW file, create it with the full contents shown; for an edit, replace only the `Locate` text; (d) run the card's `Test`; (e) `fvm flutter analyze <file>` must report **no errors**; (f) `git commit` with the card id (e.g. `feat(office-A3): excel viewer`); (g) STOP and report the diff before the next card.
4. **`// VERIFY API`** marks a third-party package call. If analyze/build says the symbol or signature is wrong, open that package's pub.dev **example for the pinned version**, fix ONLY that call to match, and keep the surrounding logic. Do not invent APIs.
5. Hard rules you may never break: never overwrite a user's original file (invariant 2); never add a network/cloud/server path (invariant 1); never modify the updater's `OpenFilex` calls in `update_service.dart` / `update_dialogs.dart`.
6. Do not build a release or deploy unless a card explicitly says so. Releases go through `release_build.ps1` only (arm64-only APK).
7. If a `Locate` anchor doesn't match verbatim (the branch moved), STOP and report — do not guess an edit location.

---

## 0. Where the app is today (verified against the branch)
- **PDF** opens **in-app** via `pdfrx` + `syncfusion_flutter_pdf` — `PdfViewerScreen` (`lib/features/documents/screens/pdf_viewer_screen.dart`), a `StatefulWidget` taking `filePath` + `fileName`, pushed via `Navigator.push(MaterialPageRoute(...))`.
- **Word/Excel do NOT open in-app.** They are handed to an external app via **`open_filex`**. The single load-bearing anchor is `_openFile()` in `lib/features/documents/screens/all_documents_screen.dart` (~`:554`):
```dart
  Future<void> _openFile(FileSystemEntity file, bool isPdf) async {
    if (isPdf) {
      // Retrieve stored password before opening
      final passwordService = PdfPasswordService();
      final storedPassword = await passwordService.getPasswordForDocument(file.path);

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PdfViewerScreen(
            filePath: file.path,
            fileName: file.path.split(Platform.pathSeparator).last,
            password: storedPassword,
          ),
        ),
      );
    } else {
      await OpenFilex.open(file.path);   // <-- Word/Excel/everything-else go here today
    }
  }
```
Other `OpenFilex` sites: `all_documents_screen.dart:341` ("Open with System" menu — an *explicit* user choice, KEEP it as-is), and `document_dashboard_screen.dart` document-tap handlers (VERIFY + apply the same routing in Step A5b). The **updater** `OpenFilex` calls (`update_service.dart`, `update_dialogs.dart`) install the APK — **do NOT touch them.**
- Scan already indexes doc/docx/xls/xlsx (`lib/services/device_document_service.dart:398`), and `DocumentItem` classifies them (`lib/models/document_item_model.dart:140-141` — `isDoc`, `isExcel`, `isPdf`).

**So the feature = route `.docx`/`.xlsx` to new in-app viewer/editor screens instead of `OpenFilex`; keep `OpenFilex` for legacy `.doc`/`.xls`, oversized files, and as an always-available escape hatch.**

## 1. Conventions & environment
- **Branch:** `experimental_flutter_upgrade` (dev; prod = `main`). Line hints approximate — VERIFY each Locate anchor before editing.
- **Toolchain:** Flutter/Dart via FVM (`fvm flutter …`).
- **Debug build/test:** `cd android; cmd /c ".\gradlew.bat assembleDebug"`; install newest `app-debug.apk` via `adb install -r -d`.
- **Release build:** through `release_build.ps1` ONLY — it passes `-Ptarget-platform=android-arm64` (arm64-only ~47 MB APK). **Never** cut a release via raw `gradlew assembleRelease` / `flutter build apk` (regresses to a 90 MB fat APK).
- **Release:** bump `pubspec.yaml` **and** `android/local.properties` (versionName+Code); copy `app-release.apk` → `passwordpdf-releases/releases/vX.Y.Z/`, update `version.json` (+ `sha256`, keep latest 3), push, curl-verify.
- **Package `com.passwordpdf.passwordpdf_manager`**; `MANAGE_EXTERNAL_STORAGE` (mandatory — files live on device storage).

## 2. Decision: chosen approach (offline, all-Dart, license-clean)
Full research (2026) → **Rejected options** appendix (§7). Summary:

| Need | Chosen (primary) | Fallback |
|------|------------------|----------|
| **Excel view** | `excel_plus` (parse) → read-only `pluto_grid` | `excel` (MIT, lossier) |
| **Excel edit** | editable `pluto_grid` → write via `excel_plus` (**save-as-copy**) | — |
| **Word view** | `docx_file_viewer` (pure Flutter `DocxView`) | bundled `docx-preview.js` in an **offline** `flutter_inappwebview`; `mammoth.js` for text-only |
| **Word edit** | `docx_creator` (**pilot-gated**, save-as-copy) | defer → view-only + `open_filex` |
| **Word → PDF** | `docx_creator` `DocxReader`→`PdfExporter` (pure Dart, offline, no native) | webview print-to-PDF (docx-preview.js + `flutter_inappwebview`) |
| **Legacy `.doc`/`.xls`** | `open_filex` handoff (no OSS Dart reader) | — |

**Why not the obvious choices** (verified, primary sources):
- **Syncfusion Flutter Office = NOT VIABLE.** No Flutter Word/DocIO package exists; `syncfusion_flutter_xlsio` is **create/write-only** (cannot open an existing workbook — off-roadmap per Syncfusion forums); `XlsIORenderer`/`DocIORenderer` (Office→PDF) are **.NET/Xamarin-only** so "render→PDF→pdfrx" is impossible on Flutter; and the Community License fails for a Deloitte-owned app (needs <$1M rev / ≤5 devs / ≤10 employees). Keep Syncfusion ONLY for existing PDF use.
- **Cloud/server = rejected (offline+privacy).** OnlyOffice Docs & Collabora Online SDK are WebView-on-a-**server** (on-device hosting impractical; OnlyOffice CE is **AGPLv3**). Google/MS viewers **upload** the private file.
- **WebView JS editors = rejected.** Univer needs its **server** for xlsx I/O; x-spreadsheet & Luckysheet **deprecated**; Handsontable free tier is **non-commercial only**.
- **Collabora Office native (LibreOfficeKit) =** only full-fidelity *offline* engine, but fork-the-app + +100s MB + no Flutter embedding → **heavyweight fallback only**.

## 3. Non-negotiable invariants (obey ALL)
1. **Offline / on-device only.** No user document bytes leave the device. No cloud viewer/converter/server.
2. **Save-as-copy, never overwrite the original.** Edits write to a NEW file; overwrite the source only after (a) explicit user confirm AND (b) the round-trip verify (#3) passes.
3. **Verify the round-trip before trusting a save.** Re-open the just-written file with the same engine; confirm edited cells/paragraphs read back equal. Silent fidelity loss must never report success.
4. **Lossy by design — tell the user.** OSS engines drop charts/images/pivots/conditional-format/macros/complex tables on re-save. Show a one-time "editing may not preserve every element; original kept" notice; log detectable drops.
5. **`.docx`/`.xlsx` only in-app.** Legacy binary `.doc`/`.xls` → `open_filex`. Detect by extension; never feed `.doc` to the docx engine.
6. **License-clean.** Only MIT/Apache/BSD. NO Syncfusion Office, NO Handsontable, NO AGPL.
7. **Big-file safety.** Parse off the UI isolate (`compute`); cap in-app size (≈25 MB) → offer `open_filex` instead of freezing.
8. **Keep the escape hatch.** A visible "Open with another app" (`open_filex`) on every Office file.

## 4. Order of work
1. **Part A** — in-app **VIEWERS** (read-only). Independently shippable; do first, soak it.
2. **Part B** — **Excel editing** (grid → `excel_plus`, save-as-copy + verify).
3. **Part C** — **Word editing** (`docx_creator`, PILOT-GATED, save-as-copy + verify).
4. **Part D** — integration, guardrails, legacy handoff, write permissions.
5. **Part E** — **Word → PDF conversion** (pure Dart, offline). Independent + low-risk (reads the .docx, writes a NEW .pdf — never overwrites the source). Implement anytime after Part A; ships with **1.3.0**.

> Every card below is **Senior-review: apply ONE card per prompt, verify, device-test on REAL documents.**

---

## Part A — In-app viewers (read-only, do first)

### Step A1 — Add dependencies (license-clean)
- File(s): `pubspec.yaml`.
- Locate — the existing dependency area (any block is fine; put a new labelled block):
```yaml
  pdfrx: ^2.2.20
  syncfusion_flutter_pdf: ^32.1.22
  open_filex: ^4.3.2
```
- Change — add:
```yaml
  # Office (Word/Excel) view + edit — MIT/Apache/BSD, fully offline. VERIFY latest majors on pub.dev.
  excel_plus: ^1.0.0         # .xlsx parse+write; reuses untouched parts on save (safer round-trip)
  pluto_grid: ^8.0.0         # native editable grid UI (MIT)
  docx_file_viewer: ^1.0.2   # pure-Flutter .docx viewer widget `DocxView` (Apache-2.0)
  docx_creator: ^1.2.7       # .docx read (DocxReader) + PDF export (PdfExporter) + edit; pure Dart (MIT)
  # Word-view / Word->PDF fallback only (add if the pure-Dart fidelity is insufficient — see A4/E3):
  # flutter_inappwebview: ^6.0.0
```
- Why / safeguards: `open_filex`, `pdfrx`, `syncfusion_flutter_pdf` STAY. Do NOT add `syncfusion_flutter_xlsio`/Handsontable/any server SDK. Pin exact majors so a transitive bump can't change the engine.
- Test: `fvm flutter pub get`; `fvm flutter pub deps | grep -E "excel_plus|pluto_grid|docx_file_viewer"` = single versions each; `cd android; cmd /c ".\gradlew.bat assembleDebug"` builds. No device test.
- WARNING: inert card — wire nothing here.

---

### Step A2 — Central open router (single source of truth)
- File(s): NEW `lib/features/documents/services/office_open_router.dart`.
- Goal: one function that decides, by extension + size, how a document opens; and one that performs the navigation. Every open call site (A5) delegates here.
- Change — full file:
```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../../../services/pdf_password_service.dart';
import '../screens/pdf_viewer_screen.dart';
import '../screens/excel_viewer_screen.dart';
import '../screens/word_viewer_screen.dart';

enum OfficeOpenTarget { pdfInApp, wordInApp, excelInApp, externalHandoff }

/// Max size we render in-app; larger => external app (invariant 7).
const int kMaxInAppOfficeBytes = 25 * 1024 * 1024;

OfficeOpenTarget routeForPath(String path, {int? sizeBytes}) {
  if (sizeBytes != null && sizeBytes > kMaxInAppOfficeBytes) {
    return OfficeOpenTarget.externalHandoff;
  }
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'pdf':
      return OfficeOpenTarget.pdfInApp;
    case 'docx':
      return OfficeOpenTarget.wordInApp;
    case 'xlsx':
      return OfficeOpenTarget.excelInApp;
    case 'doc': // legacy binary — no OSS Dart reader (invariant 5)
    case 'xls':
    default:
      return OfficeOpenTarget.externalHandoff;
  }
}

/// Open a document via the right in-app screen, or hand off to an external app.
Future<void> openDocument(BuildContext context, String filePath) async {
  final fileName = filePath.split(Platform.pathSeparator).last;
  int? size;
  try {
    size = await File(filePath).length();
  } catch (_) {}

  switch (routeForPath(filePath, sizeBytes: size)) {
    case OfficeOpenTarget.pdfInApp:
      final stored = await PdfPasswordService().getPasswordForDocument(filePath);
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(
            filePath: filePath, fileName: fileName, password: stored),
      ));
      break;
    case OfficeOpenTarget.excelInApp:
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ExcelViewerScreen(filePath: filePath, fileName: fileName),
      ));
      break;
    case OfficeOpenTarget.wordInApp:
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WordViewerScreen(filePath: filePath, fileName: fileName),
      ));
      break;
    case OfficeOpenTarget.externalHandoff:
      await OpenFilex.open(filePath);
      break;
  }
}
```
- Why / safeguards: extension-based routing keeps `.doc`/`.xls` OUT of the docx/xlsx engines and enforces the size cap. PDF path preserves the existing stored-password behaviour. All navigation in one place → every call site behaves identically.
- Test: unit test `routeForPath` for pdf/docx/xlsx/doc/xls/unknown/oversized. (`openDocument` compiles only after A3/A4 exist — add those imports then.)

---

### Step A3 — Excel viewer screen (read-only)
- File(s): NEW `lib/features/documents/screens/excel_viewer_screen.dart`.
- Goal: parse `.xlsx` off the UI isolate; show each sheet in a read-only `pluto_grid` (tab per sheet); appbar "Open with another app".
- Change — full file (mark `// VERIFY API` = confirm against excel_plus / pluto_grid pinned versions):
```dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:excel_plus/excel_plus.dart'; // VERIFY import path

/// Plain, isolate-safe representation of a parsed workbook.
class _SheetData {
  final String name;
  final List<List<String>> rows; // stringified cell values
  _SheetData(this.name, this.rows);
}

/// Runs in a background isolate via compute() — pure, no Flutter refs.
List<_SheetData> _parseXlsx(Uint8List bytes) {
  final excel = Excel.decodeBytes(bytes); // VERIFY API
  final out = <_SheetData>[];
  for (final name in excel.tables.keys) { // VERIFY API
    final sheet = excel[name]!; // VERIFY API
    final rows = <List<String>>[];
    for (final row in sheet.rows) { // VERIFY API
      rows.add(row.map((c) => c?.value?.toString() ?? '').toList()); // VERIFY API
    }
    out.add(_SheetData(name, rows));
  }
  return out;
}

class ExcelViewerScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  const ExcelViewerScreen({super.key, required this.filePath, required this.fileName});

  @override
  State<ExcelViewerScreen> createState() => _ExcelViewerScreenState();
}

class _ExcelViewerScreenState extends State<ExcelViewerScreen> {
  bool _loading = true;
  String? _error;
  List<_SheetData> _sheets = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final sheets = await compute(_parseXlsx, bytes); // off UI isolate (invariant 7)
      if (!mounted) return;
      setState(() { _sheets = sheets; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  int _maxCols(_SheetData s) =>
      s.rows.fold(0, (m, r) => r.length > m ? r.length : m);

  @override
  Widget build(BuildContext context) {
    final tabs = _sheets;
    return DefaultTabController(
      length: tabs.isEmpty ? 1 : tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Open with another app',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => OpenFilex.open(widget.filePath), // invariant 8
            ),
          ],
          bottom: (tabs.length > 1)
              ? TabBar(isScrollable: true, tabs: [for (final s in tabs) Tab(text: s.name)])
              : null,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorFallback(path: widget.filePath, error: _error!)
                : TabBarView(children: [for (final s in tabs) _grid(s)]),
      ),
    );
  }

  Widget _grid(_SheetData s) {
    final cols = _maxCols(s);
    final columns = [
      for (var c = 0; c < cols; c++)
        PlutoColumn(
          title: _colLabel(c), field: 'c$c',
          type: PlutoColumnType.text(), readOnly: true, // read-only in Part A
        ),
    ];
    final rows = [
      for (final r in s.rows)
        PlutoRow(cells: {
          for (var c = 0; c < cols; c++)
            'c$c': PlutoCell(value: c < r.length ? r[c] : ''),
        }),
    ];
    return PlutoGrid(columns: columns, rows: rows); // VERIFY API
  }

  static String _colLabel(int i) {
    var n = i; final sb = StringBuffer();
    do { sb.write(String.fromCharCode(65 + n % 26)); n = n ~/ 26 - 1; } while (n >= 0);
    return sb.toString().split('').reversed.join();
  }
}

class _ErrorFallback extends StatelessWidget {
  final String path; final String error;
  const _ErrorFallback({required this.path, required this.error});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, size: 48),
      const SizedBox(height: 12),
      const Text("Couldn't open this file in-app."),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: () => OpenFilex.open(path),
        icon: const Icon(Icons.open_in_new), label: const Text('Open with another app')),
    ]),
  );
}
```
- Why / safeguards: `compute` keeps big sheets off the main isolate (invariant 7). Read-only (`readOnly: true`) — no writes in Part A. Parse failure → graceful `open_filex` fallback (invariant 8). `.toString()` on cell values sidesteps engine-specific `CellValue` subtypes for viewing (typed handling comes in Part B).
- Test: device — open real `.xlsx` (small, large, merged cells, formulas, multi-sheet). Values/sheets correct, no ANR, "Open externally" works, corrupt file → fallback. Compare to a real Office app.
- WARNING: read-only path (`readAsBytes`, no writes). If a workbook has charts/images the grid won't show them — that's expected for the view; note it to the user in A/D polish.

---

### Step A4 — Word viewer screen (read-only)
- File(s): NEW `lib/features/documents/screens/word_viewer_screen.dart`.
- Change — full file (`DocxView` per docx_file_viewer; `// VERIFY API`):
```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart'; // VERIFY import path

class WordViewerScreen extends StatelessWidget {
  final String filePath;
  final String fileName;
  const WordViewerScreen({super.key, required this.filePath, required this.fileName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Open with another app',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => OpenFilex.open(filePath), // invariant 8
          ),
        ],
      ),
      body: _DocxBody(filePath: filePath),
    );
  }
}

class _DocxBody extends StatelessWidget {
  final String filePath;
  const _DocxBody({required this.filePath});
  @override
  Widget build(BuildContext context) {
    try {
      // VERIFY API: DocxView.file(File) + DocxViewConfig(...) per pinned version.
      return DocxView.file(
        File(filePath),
        config: const DocxViewConfig(enableZoom: true, enableSelection: true),
      );
    } catch (e) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => OpenFilex.open(filePath),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open with another app'),
        ),
      );
    }
  }
}
```
- Why / safeguards: pure-Flutter viewer → offline, no webview/asset bundling. `docx_file_viewer` fidelity is **unverified** — pilot on 10–20 real docs. If complex layouts (tables/images/headers) break, switch THIS card to the **fallback**: bundle `docx-preview.min.js` + `jszip.min.js` as offline assets, render in `flutter_inappwebview` with **JS-to-native + network DISABLED**; or `mammoth.js` for text-centric docs.
- Test: device — text-heavy, tables, images, headers/footers `.docx`. Judge fidelity vs a real Office app; choose primary vs fallback here.
- WARNING: read-only. `.doc` never reaches this screen (router sends it to `open_filex`).

---

### Step A5a — Route `_openFile` through the router
- File(s): `lib/features/documents/screens/all_documents_screen.dart` (~`:554`).
- Locate (verbatim):
```dart
  Future<void> _openFile(FileSystemEntity file, bool isPdf) async {
    if (isPdf) {
      // Retrieve stored password before opening
      final passwordService = PdfPasswordService();
      final storedPassword = await passwordService.getPasswordForDocument(file.path);

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PdfViewerScreen(
            filePath: file.path,
            fileName: file.path.split(Platform.pathSeparator).last,
            password: storedPassword,
          ),
        ),
      );
    } else {
      await OpenFilex.open(file.path);
    }
  }
```
- Change — delegate to the router (add `import '../services/office_open_router.dart';`):
```dart
  Future<void> _openFile(FileSystemEntity file, bool isPdf) async {
    // Route by extension/size: PDF + docx + xlsx open in-app; .doc/.xls/oversized
    // hand off to an external app. (isPdf kept for callers; router re-derives type.)
    if (!mounted) return;
    await openDocument(context, file.path);
  }
```
- Why / safeguards: the router reproduces the exact PDF stored-password path, so PDF behaviour is unchanged; docx/xlsx now open in-app; everything else still hands off. Single code path.
- Test: device — from All Documents tap `.pdf` (unchanged), `.docx`, `.xlsx`, `.doc`, `.xls` → correct target each. PDF regression check (stored password still auto-fills).
- WARNING: leave the explicit "Open with System" menu item (`:341`) as-is — it's a deliberate user choice.

### Step A5b — Route the dashboard's document-tap the same way
- File(s): `lib/features/documents/screens/document_dashboard_screen.dart` (VERIFY the doc-tap/open handler — search for `OpenFilex`, `PdfViewerScreen`, or the item `onTap`).
- Change — replace the direct open/`OpenFilex` with `openDocument(context, path)` (import the router).
- Test: device — open docx/xlsx/pdf/doc from the dashboard and recents.
- WARNING: do NOT alter the updater's `OpenFilex` calls (`update_service.dart`, `update_dialogs.dart`).

> **Ship gate:** Part A is view-only and independently releasable. Cut a test build, device-test all formats, then a release (via `release_build.ps1`), and let it soak before Part B/C touch writes.

---

## Part B — Excel editing (save-as-copy)

### Step B1 — Editable grid + dirty tracking
- File(s): `excel_viewer_screen.dart` (promote to editor, or clone to `excel_editor_screen.dart`).
- Change (key deltas):
  - Columns: `readOnly: false`.
  - Track edits: add `final Map<String, String> _dirty = {}; // "sheet!r,c" -> newValue`.
  - Grid: `onChanged: (e) { _dirty['${sheet.name}!${e.rowIdx},${e.column.field}'] = e.value?.toString() ?? ''; setState(() {}); }` `// VERIFY PlutoGridOnChangedEvent fields`.
  - AppBar: a **Save a copy** `IconButton` (`Icons.save_outlined`), enabled only when `_dirty.isNotEmpty`. No autosave.
- Why / safeguards: explicit save only (never silently write over a user file). Dirty map limits the write to changed cells → helps `excel_plus` preserve untouched parts.
- Test: device — edit values across sheets; Save disabled when clean, enabled when dirty.

### Step B2 — Write-back service (save-as-copy + round-trip verify)
- File(s): NEW `lib/services/excel_edit_service.dart`.
- Change — full file:
```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:excel_plus/excel_plus.dart'; // VERIFY API
import 'package:path/path.dart' as p;
import '../features/settings/services/settings_service.dart';

class ExcelSaveResult {
  final String savedPath;    // the NEW copy
  final bool verified;       // re-open round-trip matched
  final List<String> notes;  // anything we detected as dropped
  ExcelSaveResult(this.savedPath, this.verified, this.notes);
}

class ExcelEditService {
  /// Apply dirty cells to [sourcePath] and write a COPY (never overwrite).
  /// [dirty] key = "sheetName!rowIdx,colField(cN)".
  Future<ExcelSaveResult> saveCopyWithEdits(
      String sourcePath, Map<String, String> dirty) async {
    final bytes = await File(sourcePath).readAsBytes();
    final excel = Excel.decodeBytes(bytes); // VERIFY API

    dirty.forEach((k, v) {
      final bang = k.indexOf('!');
      final sheet = k.substring(0, bang);
      final rc = k.substring(bang + 1).split(',');
      final row = int.parse(rc[0]);
      final col = int.parse(rc[1].substring(1)); // strip leading 'c'
      excel[sheet]!.updateCell( // VERIFY API
        CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
        TextCellValue(v), // NOTE: viewer stringifies; typed round-trip is a later refinement
      );
    });

    final out = excel.save(); // VERIFY API (List<int>?)
    if (out == null) throw StateError('excel.save() returned null');

    final dir = SettingsService().exportPath;
    final base = p.basenameWithoutExtension(sourcePath);
    final copyPath = _uniquePath(p.join(dir, '$base (edited).xlsx'));
    await File(copyPath).writeAsBytes(out, flush: true);

    // Invariant 3: verify the copy round-trips the edits before reporting success.
    final verified = await _verify(copyPath, dirty);
    return ExcelSaveResult(copyPath, verified, const []);
  }

  Future<bool> _verify(String copyPath, Map<String, String> dirty) async {
    try {
      final re = Excel.decodeBytes(await File(copyPath).readAsBytes());
      for (final entry in dirty.entries) {
        final bang = entry.key.indexOf('!');
        final sheet = entry.key.substring(0, bang);
        final rc = entry.key.substring(bang + 1).split(',');
        final row = int.parse(rc[0]);
        final col = int.parse(rc[1].substring(1));
        final cell = re[sheet]!.cell( // VERIFY API
            CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
        if ((cell.value?.toString() ?? '') != entry.value) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  String _uniquePath(String path) {
    if (!File(path).existsSync()) return path;
    final dir = p.dirname(path);
    final name = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    var i = 2;
    while (File(p.join(dir, '$name ($i)$ext')).existsSync()) i++;
    return p.join(dir, '$name ($i)$ext');
  }
}
```
- Wire in the editor's Save action: call `saveCopyWithEdits`, then:
  - `verified == true` → snackbar "Saved a copy: `<name>`" + offer "Replace original" (which copies over the source only after a confirm dialog).
  - `verified == false` → **loud** warning "Saved a copy but couldn't verify it — the original is untouched." Do NOT offer replace-original.
- Why / safeguards: invariants 2 + 3. The copy lands in `<exportPath>` (= `Download/PDF Manager`, same place as backups, so the scan indexes it). Verify catches silent loss.
- Test: device — open→edit one cell→Save copy→open the COPY in a real Office app: edit landed, rest of the workbook survived. Diff copy vs original for unexpected drops (charts/images/styles).
- WARNING: THE risk card. Test on real workbooks (formulas, merges, styles). If verify fails, keep the copy, warn, never replace-original.

### Step B3 — Fidelity guardrails + notice
- File(s): editor screen + `excel_edit_service.dart`.
- Change: detect unsupported content where the engine exposes it (charts/images/pivots); show the one-time "editing may drop X; original kept" notice (invariant 4); log drops.
- Test: workbook WITH a chart → edit a cell → save copy → notice fired, original intact.

---

## Part C — Word editing (PILOT-GATED, save-as-copy)

> **Gate the whole Part on C1.** `docx_creator` round-trip fidelity is unverified. If the pilot fails, Word stays **view-only** (Part A) + `open_filex` for editing — a fully acceptable outcome.

### Step C1 — Round-trip fidelity PILOT (go/no-go)
- File(s): `test/word_roundtrip_pilot_test.dart` + a manual device run.
- Steps: with `docx_creator`, load 10–20 representative real `.docx`, modify a paragraph, re-export, DIFF vs original (open both in a real Office app + structural compare). Record results in this runbook.
- Decision: **GO** only if text edits round-trip without mangling tables/images/headers on representative docs; else **NO-GO → stop; Word = view-only.**
- WARNING: this is a research gate, not a feature. Don't build UI on `docx_creator` until it passes.

### Step C2 — Word editor + save-as-copy + verify (only if C1 = GO)
- File(s): NEW `lib/features/documents/screens/word_editor_screen.dart` + NEW `lib/services/word_edit_service.dart`.
- Change — mirror the Excel edit pattern: load via `docx_creator` (`// VERIFY API`: load/parse existing `.docx` → mutate paragraph text → export bytes), write `<name> (edited).docx` to `<exportPath>`, then **re-open + verify** the edited text before success; save-as-copy only; same notice discipline. Keep the edit scope narrow (text/paragraph edits that C1 proved reliable — not full WYSIWYG). `open_xml` is a second-opinion engine if `docx_creator` disappoints.
- Test: device — edit text → Save copy → reopen the COPY in Office; edit + surrounding content survive.
- WARNING: never overwrite the original until verify passes + user confirms. `.doc` never enters this path (invariant 5).

---

## Part D — Integration, guardrails, legacy handoff

### Step D1 — Consolidate all open/edit entry points
- Goal: every document surface (All Documents, dashboard, recents, search, share-intent open) routes through `openDocument()` (A2); a visible "Open with another app" on Office files everywhere.
- Test: exercise each surface with docx/xlsx/doc/xls/pdf.

### Step D2 — Write location + permissions for saved copies
- Goal: copies land in `<exportPath>` (`Download/PDF Manager`), writable under `MANAGE_EXTERNAL_STORAGE`/SAF, and get indexed by the scan. On write failure → fall back to app-private dir + Share.
- Test: save a copy → appears in the documents list + device file manager.

### Step D3 — Large-file + error handling
- Goal: enforce the 25 MB cap (A2) with a friendly "too large — open externally?" path; graceful parse-failure → `open_filex`; never crash on malformed input.
- Test: a huge/malformed `.xlsx` and `.docx` → clean fallback, no ANR/crash.

---

## Part E — Word → PDF conversion (pure Dart, offline)

> Scope: a **"Convert to PDF"** action on `.docx` that produces a real `.pdf` on device and opens it in the existing `PdfViewerScreen`. Pure Dart via `docx_creator` (`DocxReader` → `PdfExporter`) — **NO webview, NO cloud, NO native code.** Depends on Part A (deps in A1, the Word viewer in A4). `.doc` is not supported → `open_filex`. Fidelity is good for text/tables/lists/PNG images but **not pixel-perfect** (multi-column layout is imperfect) — a convenience export, not a print renderer. Reads the source and writes a NEW file → cannot harm the original, so this is low-risk.

### Step E1 — Word→PDF service (pure Dart)
- File(s): NEW `lib/services/word_to_pdf_service.dart`.
- Goal: read a `.docx`, export a `.pdf` into `<exportPath>` (`Download/PDF Manager`), return the new path.
- Change — create the file with EXACTLY this content:
```dart
import 'dart:io';
import 'package:docx_creator/docx_creator.dart'; // VERIFY API (DocxReader, PdfExporter)
import 'package:path/path.dart' as p;
import '../features/settings/services/settings_service.dart';

/// Convert a Word .docx to PDF fully on-device (pure Dart, no webview/cloud/native).
class WordToPdfService {
  /// Reads [docxPath], writes a .pdf under <exportPath>, returns the PDF path.
  /// Only .docx is supported (invariant 5). Throws on failure; caller shows the error.
  Future<String> convertDocxToPdf(String docxPath) async {
    final ext = docxPath.toLowerCase().split('.').last;
    if (ext != 'docx') {
      throw ArgumentError(
          'Only .docx can be converted here (got .$ext). Use "Open with another app" for .doc.');
    }

    // 1) Load the Word document (pure Dart).
    final doc = await DocxReader.load(docxPath); // VERIFY API (alt: DocxReader.loadFromBytes(bytes))

    // 2) Pick a unique output path under the user's export folder.
    final dir = SettingsService().exportPath;
    await Directory(dir).create(recursive: true);
    final base = p.basenameWithoutExtension(docxPath);
    final outPath = _uniquePath(p.join(dir, '$base.pdf'));

    // 3) Export to PDF (pure Dart, no native deps).
    await PdfExporter().exportToFile(doc, outPath); // VERIFY API (alt: exportToBytes(doc) then File(outPath).writeAsBytes(...))
    return outPath;
  }

  String _uniquePath(String path) {
    if (!File(path).existsSync()) return path;
    final dir = p.dirname(path);
    final name = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    var i = 2;
    while (File(p.join(dir, '$name ($i)$ext')).existsSync()) i++;
    return p.join(dir, '$name ($i)$ext');
  }
}
```
- Why / safeguards: pure Dart → offline, no webview/assets/native. Output goes to `<exportPath>` so the scan indexes it and it's shareable. Reads source only; never overwrites it. `.doc` guarded out (invariant 5).
- Test: unit — call `convertDocxToPdf` on a sample `.docx` asset; assert the returned path exists and is > 0 bytes. Device test is in E2.
- WARNING: `PdfExporter`/`DocxReader` are from a solo-maintained package — if a `// VERIFY API` line won't compile, open `pub.dev/packages/docx_creator` (pinned version) example and match the exact names (the fallbacks in comments are the likely alternates).

### Step E2 — "Convert to PDF" action in the Word viewer
- File(s): `lib/features/documents/screens/word_viewer_screen.dart` (from Step A4).
- Locate (verbatim — the `actions:` list from A4):
```dart
        actions: [
          IconButton(
            tooltip: 'Open with another app',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => OpenFilex.open(filePath), // invariant 8
          ),
        ],
```
- Change — add the Convert action before it:
```dart
        actions: [
          IconButton(
            tooltip: 'Convert to PDF',
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: () => _convertToPdf(context),
          ),
          IconButton(
            tooltip: 'Open with another app',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => OpenFilex.open(filePath), // invariant 8
          ),
        ],
```
- Change — add these imports at the top of the file:
```dart
import '../../../services/word_to_pdf_service.dart';
import 'pdf_viewer_screen.dart';
```
- Change — add this method to the `WordViewerScreen` class (it is a `StatelessWidget`; capture `messenger`/`navigator` BEFORE the `await` so no `context`-after-async issue):
```dart
  Future<void> _convertToPdf(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Converting to PDF…')));
    try {
      final pdfPath = await WordToPdfService().convertDocxToPdf(filePath);
      final name = pdfPath.split(Platform.pathSeparator).last;
      messenger.showSnackBar(SnackBar(content: Text('Saved: $name')));
      navigator.push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(filePath: pdfPath, fileName: name),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Convert failed: $e')));
    }
  }
```
- Why / safeguards: reuses the existing `pdfrx` viewer for the result; the PDF lands in `<exportPath>` (indexed + shareable). `Platform` is already imported via `dart:io` in A4.
- Test: device — open a `.docx` → tap **Convert to PDF** → a PDF opens in the viewer and matches the source reasonably; the `.pdf` appears in the documents list. Try a `.docx` with a table + PNG image → check fidelity. Confirm a `.doc` never shows this screen (router hands it off), so the action can't hit a `.doc`.
- WARNING: fidelity is approximate (multi-column imperfect, no OCR of scanned images). Keep "Open with another app" for pixel-perfect needs.

### Step E3 (OPTIONAL) — higher-fidelity fallback (webview print-to-PDF)
- Only if E1's fidelity is inadequate for your users. Approach: render `.docx`→HTML with bundled `docx-preview.min.js` + `jszip.min.js` (offline assets) inside a `flutter_inappwebview` (JS-to-native + network DISABLED), then export the page to PDF via the controller's PDF/print API (`// VERIFY API`: `createPdf()` / `printCurrentPage()` on the pinned version) — or feed the produced HTML to `printing`'s `Printing.convertHtml(...)`. Heavier (webview + bundled JS assets); prefer the pure-Dart E1 unless fidelity forces it. Keep it fully offline (no CDN).
- Test: device — convert a layout-heavy `.docx`; compare fidelity vs E1; only adopt if clearly better.

---

## 7. Rejected options (research 2026 — recorded so nobody re-litigates)
- **Syncfusion Flutter Office** — no Word/DocIO package; `syncfusion_flutter_xlsio` create/write-only (can't open existing); no Flutter `XlsIORenderer`/`DocIORenderer` (Office→PDF is .NET-only); Community License fails for a Deloitte-owned app. Keep only for PDF / generating new .xlsx.
- **WebView JS spreadsheet editors** — Univer needs its server for xlsx I/O (breaks offline); x-spreadsheet & Luckysheet deprecated; Handsontable free tier non-commercial only.
- **OnlyOffice Docs / Collabora Online SDK / CODE** — WebView-on-a-server; on-device hosting impractical; OnlyOffice CE is AGPLv3. Reject on offline + license.
- **Google Docs Viewer / Drive, Microsoft Office app** — upload the private file off-device / cloud-bound. Reject on privacy. Acceptable only as optional `open_filex` targets, never the private in-app path.
- **Collabora Office native (LibreOfficeKit)** — only full-fidelity *offline* editor, but fork-the-app + +100s MB + no Flutter/AAR embedding → heavyweight fallback only.
- **`.doc` / `.xls` (legacy binary)** — no OSS Dart reader/writer → `open_filex` handoff only.

## 8. Package fidelity caveats (test, don't assume)
- `excel_plus` / `excel` — `.xlsx` only; drop charts/images/pivots/conditional-format on re-save (`excel_plus` reuses untouched parts byte-for-byte → prefer it). Prototype open→edit-one-cell→save→diff on real files first.
- `docx_file_viewer` / `docx_creator` — new, solo-maintained; fidelity claims **unverified** → pilot before trusting (C1 for editing).
- `docx_creator` **`PdfExporter`** (Word→PDF, Part E) — pure Dart, no native deps; handles text/headings/bold/italic/underline/strike/colors/alignment/lists/tables/PNG images/page sizes, but multi-column positioning is imperfect and there is no OCR for scanned images. Good enough for a convenience "convert to PDF"; keep `open_filex` for pixel-perfect output.
- Everything here runs on-device/offline. Keep `open_filex` as the labelled non-private fallback.

## 9. Suggested version milestones
- **1.3.0** — Part A (in-app Word/Excel viewers) **+ Part E (Word→PDF convert)** — both read-only/no-overwrite, ship together.
- **1.4.0** — Part B (Excel editing, save-as-copy).
- **1.5.0** — Part C (Word editing) **iff** the C1 pilot passes; else Word stays view-only + convert-to-PDF.
