import 'dart:io';
import 'dart:ui';
import 'package:docx_creator/docx_creator.dart' hide PdfDocument;
import 'package:excel_plus/excel_plus.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../logging_service.dart';
import 'ai_diagnostics_service.dart';

/// Formats available for exporting AI Diagnostics
enum AiDiagnosticExportFormat {
  pdf,
  word,
  excel,
}

/// Result of multi-format export operation
class AiDiagnosticExportResult {
  final List<String> exportedFilePaths;
  final List<String> errors;

  const AiDiagnosticExportResult({
    required this.exportedFilePaths,
    required this.errors,
  });

  bool get isSuccess => exportedFilePaths.isNotEmpty && errors.isEmpty;
  bool get hasPartialSuccess => exportedFilePaths.isNotEmpty && errors.isNotEmpty;
}

/// Service that exports transparent AI pipeline diagnostics to PDF, Word (.docx), and Excel (.xlsx)
class AiDiagnosticsExportService {
  static final AiDiagnosticsExportService _instance = AiDiagnosticsExportService._internal();
  factory AiDiagnosticsExportService() => _instance;
  AiDiagnosticsExportService._internal();

  /// Resolve a safe directory to save exports
  Future<Directory> _getExportDirectory({String? customDir}) async {
    if (customDir != null && customDir.trim().isNotEmpty) {
      final dir = Directory(customDir.trim());
      if (!dir.existsSync()) {
        try {
          await dir.create(recursive: true);
          return dir;
        } catch (_) {}
      } else {
        return dir;
      }
    }

    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final target = Directory('${appDocDir.path}/AI_Diagnostics');
      if (!target.existsSync()) {
        await target.create(recursive: true);
      }
      return target;
    } catch (_) {
      final temp = await getTemporaryDirectory();
      return temp;
    }
  }

  /// Export diagnostics to one or more selected formats
  Future<AiDiagnosticExportResult> exportDiagnostics({
    required Set<AiDiagnosticExportFormat> formats,
    required List<AiDiagnosticLogEntry> logs,
    Map<String, dynamic>? storageStats,
    String? targetDirectory,
  }) async {
    final exportedPaths = <String>[];
    final errors = <String>[];

    if (formats.isEmpty) {
      return const AiDiagnosticExportResult(exportedFilePaths: [], errors: ['No format selected']);
    }

    final outDir = await _getExportDirectory(customDir: targetDirectory);
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

    for (final format in formats) {
      try {
        switch (format) {
          case AiDiagnosticExportFormat.pdf:
            final pdfPath = '${outDir.path}/ai_diagnostics_$timestamp.pdf';
            final bytes = await generatePdfBytes(logs: logs, storageStats: storageStats);
            await File(pdfPath).writeAsBytes(bytes);
            exportedPaths.add(pdfPath);
            break;

          case AiDiagnosticExportFormat.word:
            final docxPath = '${outDir.path}/ai_diagnostics_$timestamp.docx';
            final bytes = await generateWordBytes(logs: logs, storageStats: storageStats);
            await File(docxPath).writeAsBytes(bytes);
            exportedPaths.add(docxPath);
            break;

          case AiDiagnosticExportFormat.excel:
            final xlsxPath = '${outDir.path}/ai_diagnostics_$timestamp.xlsx';
            final bytes = await generateExcelBytes(logs: logs, storageStats: storageStats);
            await File(xlsxPath).writeAsBytes(bytes);
            exportedPaths.add(xlsxPath);
            break;
        }
      } catch (e, stack) {
        LoggingService().error('AiDiagnosticsExport', 'Failed export for format $format: $e', e, stack);
        errors.add('Failed to export ${format.name.toUpperCase()}: $e');
      }
    }

    return AiDiagnosticExportResult(
      exportedFilePaths: exportedPaths,
      errors: errors,
    );
  }

  // ==================== 1. PDF GENERATION ====================

  Future<List<int>> generatePdfBytes({
    required List<AiDiagnosticLogEntry> logs,
    Map<String, dynamic>? storageStats,
  }) async {
    final pdf = PdfDocument();
    pdf.pageSettings.margins.all = 30;

    final fontTitle = PdfStandardFont(PdfFontFamily.helvetica, 18, style: PdfFontStyle.bold);
    final fontHeader = PdfStandardFont(PdfFontFamily.helvetica, 13, style: PdfFontStyle.bold);
    final fontSubHeader = PdfStandardFont(PdfFontFamily.helvetica, 11, style: PdfFontStyle.bold);
    final fontBody = PdfStandardFont(PdfFontFamily.helvetica, 9);
    final fontBodyBold = PdfStandardFont(PdfFontFamily.helvetica, 9, style: PdfFontStyle.bold);

    var page = pdf.pages.add();
    var graphics = page.graphics;
    double y = 10;

    // Header
    graphics.drawString('PasswordPDF - AI Diagnostics & Pipeline Report', fontTitle, bounds: Rect.fromLTWH(0, y, 500, 24));
    y += 28;
    graphics.drawString('Generated on: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}', fontBody, bounds: Rect.fromLTWH(0, y, 500, 14));
    y += 16;
    graphics.drawString('Total Queries Logged: ${logs.length}', fontBodyBold, bounds: Rect.fromLTWH(0, y, 500, 14));
    y += 20;

    // Section 1: Storage Overview Table
    if (storageStats != null) {
      graphics.drawString('System & Storage Diagnostics', fontHeader, bounds: Rect.fromLTWH(0, y, 500, 18));
      y += 20;

      final grid = PdfGrid();
      grid.columns.add(count: 2);
      grid.headers.add(1);
      final headerRow = grid.headers[0];
      headerRow.cells[0].value = 'Storage / Diagnostic Metric';
      headerRow.cells[1].value = 'Value';

      final totalDocs = storageStats['total_indexed_documents'] ?? storageStats['total_documents'] ?? '0';
      final totalChunks = storageStats['total_text_chunks'] ?? storageStats['total_chunks'] ?? '0';
      final totalEmbeddings = storageStats['total_vector_embeddings'] ?? storageStats['total_embeddings'] ?? '0';
      final modelsCount = (storageStats['installed_models'] as List?)?.length ?? 0;

      grid.rows.add().cells[0].value = 'Total Indexed Documents';
      grid.rows[0].cells[1].value = '$totalDocs';

      final row2 = grid.rows.add();
      row2.cells[0].value = 'Total Extracted Text Chunks';
      row2.cells[1].value = '$totalChunks';

      final row3 = grid.rows.add();
      row3.cells[0].value = 'Total Vector Embeddings';
      row3.cells[1].value = '$totalEmbeddings';

      final row4 = grid.rows.add();
      row4.cells[0].value = 'Offline Models Installed';
      row4.cells[1].value = '$modelsCount model(s)';

      grid.style.cellPadding = PdfPaddings(left: 6, top: 4, right: 6, bottom: 4);
      final gridResult = grid.draw(page: page, bounds: Rect.fromLTWH(0, y, 500, 0));
      y = (gridResult?.bounds.bottom ?? y) + 20;
    }

    // Section 2: Recent Query Executions
    if (y > 650) {
      page = pdf.pages.add();
      graphics = page.graphics;
      y = 10;
    }

    graphics.drawString('Detailed Query Diagnostic Traces', fontHeader, bounds: Rect.fromLTWH(0, y, 500, 18));
    y += 22;

    for (int i = 0; i < logs.length; i++) {
      final log = logs[i];

      if (y > 680) {
        page = pdf.pages.add();
        graphics = page.graphics;
        y = 10;
      }

      graphics.drawString('Query #${i + 1}: "${log.rawQuery}"', fontSubHeader, bounds: Rect.fromLTWH(0, y, 500, 18));
      y += 18;
      graphics.drawString('Keywords: ${log.extractedKeywords.join(", ")} | FTS: ${log.ftsQueryString}', fontBody, bounds: Rect.fromLTWH(0, y, 500, 14));
      y += 14;
      graphics.drawString('FTS Matches: ${log.ftsMatchesCount} | Vector Matches: ${log.vectorMatchesCount} | Attached Docs: ${log.attachedDocNames.join(", ")}', fontBody, bounds: Rect.fromLTWH(0, y, 500, 14));
      y += 14;

      final cleanAnswer = log.finalAnswer.replaceAll('\n', ' ');
      final displayAnswer = cleanAnswer.length > 180 ? '${cleanAnswer.substring(0, 177)}...' : cleanAnswer;
      graphics.drawString('Answer: $displayAnswer', fontBodyBold, bounds: Rect.fromLTWH(0, y, 500, 24));
      y += 28;
    }

    final bytes = await pdf.save();
    pdf.dispose();
    return bytes;
  }

  // ==================== 2. WORD (.docx) GENERATION ====================

  Future<List<int>> generateWordBytes({
    required List<AiDiagnosticLogEntry> logs,
    Map<String, dynamic>? storageStats,
  }) async {
    final doc = docx()
      ..h1('PasswordPDF - AI Diagnostics & Pipeline Report')
      ..p('Generated: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}')
      ..p('Total Logged Queries: ${logs.length}');

    if (storageStats != null) {
      final totalDocs = storageStats['total_indexed_documents'] ?? storageStats['total_documents'] ?? '0';
      final totalChunks = storageStats['total_text_chunks'] ?? storageStats['total_chunks'] ?? '0';
      final totalEmbeddings = storageStats['total_vector_embeddings'] ?? storageStats['total_embeddings'] ?? '0';
      final modelsCount = (storageStats['installed_models'] as List?)?.length ?? 0;

      doc
        ..h2('System & Storage Overview')
        ..bullet([
          'Total Indexed Documents: $totalDocs',
          'Total Extracted Text Chunks: $totalChunks',
          'Total Vector Embeddings: $totalEmbeddings',
          'Installed Offline AI Models: $modelsCount',
        ]);
    }

    doc.h2('Detailed Query Pipelines & Execution Traces');

    for (int i = 0; i < logs.length; i++) {
      final log = logs[i];
      doc
        ..h3('Query #${i + 1}: ${log.rawQuery}')
        ..bullet([
          'Timestamp: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(log.timestamp)}',
          'Detected Intent: ${log.detectedIntent}',
          'Extracted Keywords: ${log.extractedKeywords.join(", ")}',
          'Filtered Stopwords: ${log.stopwordsRemoved.join(", ")}',
          'FTS5 Query: ${log.ftsQueryString}',
          'Attached Documents: ${log.attachedDocNames.join(", ")}',
          'FTS Matches: ${log.ftsMatchesCount}  |  Dense Vector Matches: ${log.vectorMatchesCount}',
          'Active Model: ${log.activeChatModelName ?? "None"}',
          'Execution Status: ${log.llmExecutionStatus} (${log.executionTimeMs} ms)',
        ])
        ..p('Final Answer Delivered: ${log.finalAnswer.trim().isEmpty ? "(Empty response)" : log.finalAnswer.trim()}');

      if (log.promptSentToLlm.isNotEmpty) {
        doc
          ..p('Prompt Sent to Model:')
          ..code(log.promptSentToLlm);
      }
    }

    final builtDoc = doc.build();
    final bytes = await DocxExporter().exportToBytes(builtDoc);
    return bytes;
  }

  // ==================== 3. EXCEL (.xlsx) GENERATION ====================

  Future<List<int>> generateExcelBytes({
    required List<AiDiagnosticLogEntry> logs,
    Map<String, dynamic>? storageStats,
  }) async {
    final excel = Excel.createExcel();
    final sheet = excel['AI Queries'];

    final headers = [
      '#',
      'Timestamp',
      'User Query',
      'Intent',
      'Content Keywords',
      'Stopwords Filtered',
      'FTS Query',
      'Attached Docs',
      'FTS Matches',
      'Vector Matches',
      'Active Model',
      'Model Status',
      'Latency (ms)',
      'Final Answer',
      'Prompt Sent',
    ];

    for (int col = 0; col < headers.length; col++) {
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0),
        TextCellValue(headers[col]),
      );
    }

    // Rows
    for (int r = 0; r < logs.length; r++) {
      final log = logs[r];
      final rowIdx = r + 1;

      final values = [
        '${r + 1}',
        DateFormat('yyyy-MM-dd HH:mm:ss').format(log.timestamp),
        log.rawQuery,
        log.detectedIntent,
        log.extractedKeywords.join(', '),
        log.stopwordsRemoved.join(', '),
        log.ftsQueryString,
        log.attachedDocNames.join(', '),
        log.ftsMatchesCount.toString(),
        log.vectorMatchesCount.toString(),
        log.activeChatModelName ?? 'None',
        log.llmExecutionStatus,
        log.executionTimeMs.toString(),
        log.finalAnswer,
        log.promptSentToLlm,
      ];

      for (int c = 0; c < values.length; c++) {
        sheet.updateCell(
          CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIdx),
          TextCellValue(values[c]),
        );
      }
    }

    // Add Storage Summary Sheet
    if (storageStats != null) {
      final summarySheet = excel['Storage Overview'];
      final totalDocs = storageStats['total_indexed_documents'] ?? storageStats['total_documents'] ?? '0';
      final totalChunks = storageStats['total_text_chunks'] ?? storageStats['total_chunks'] ?? '0';
      final totalEmbeddings = storageStats['total_vector_embeddings'] ?? storageStats['total_embeddings'] ?? '0';
      final modelsCount = ((storageStats['installed_models'] as List?)?.length ?? 0).toString();

      final summaryRows = [
        ['Metric', 'Value'],
        ['Total Indexed Documents', '$totalDocs'],
        ['Total Text Chunks', '$totalChunks'],
        ['Total Embeddings', '$totalEmbeddings'],
        ['Installed Models Count', modelsCount],
      ];

      for (int r = 0; r < summaryRows.length; r++) {
        for (int c = 0; c < summaryRows[r].length; c++) {
          summarySheet.updateCell(
            CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
            TextCellValue(summaryRows[r][c]),
          );
        }
      }
    }

    final bytes = excel.save();
    return bytes ?? <int>[];
  }
}
