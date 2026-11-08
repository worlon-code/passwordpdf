import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../services/ai/ai_diagnostics_export_service.dart';
import '../../../services/ai/ai_diagnostics_service.dart';
import '../../documents/screens/pdf_viewer_screen.dart';
import '../../settings/services/settings_service.dart';

/// Screen presenting complete transparent diagnostics of AI queries,
/// stopword filtering, FTS5 matches, vector similarity, prompts sent to LLMs,
/// model execution status, and database storage counts.
class AiDiagnosticsScreen extends StatefulWidget {
  const AiDiagnosticsScreen({super.key});

  static Future<void> show(BuildContext context) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AiDiagnosticsScreen()),
    );
  }

  @override
  State<AiDiagnosticsScreen> createState() => _AiDiagnosticsScreenState();
}

class _AiDiagnosticsScreenState extends State<AiDiagnosticsScreen> {
  final AiDiagnosticsService _diagnostics = AiDiagnosticsService();
  Map<String, dynamic>? _storageStats;
  bool _isLoadingStats = true;

  @override
  void initState() {
    super.initState();
    _diagnostics.addListener(_onDiagnosticsChanged);
    _loadStorageStats();
  }

  @override
  void dispose() {
    _diagnostics.removeListener(_onDiagnosticsChanged);
    super.dispose();
  }

  void _onDiagnosticsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadStorageStats() async {
    setState(() => _isLoadingStats = true);
    try {
      await _diagnostics.ensureInitialized(force: true);
      final stats = await _diagnostics.getStorageDiagnostics().timeout(
        const Duration(seconds: 4),
        onTimeout: () => {
          'total_documents': 0,
          'total_chunks': 0,
          'total_embeddings': 0,
          'installed_models': [],
          'indexed_docs': [],
        },
      );
      if (mounted) {
        setState(() {
          _storageStats = stats;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingStats = false;
        });
      }
    }
  }

  Future<void> _openPdfViewer({
    required BuildContext context,
    required String fileName,
    String? filePath,
    int pageNumber = 1,
  }) async {
    String? resolvedPath = filePath;
    if (resolvedPath == null || resolvedPath.isEmpty || !File(resolvedPath).existsSync()) {
      final docs = await _diagnostics.getDetailedDocuments();
      final match = docs.where((d) =>
        (d['file_name'] as String? ?? '').toLowerCase() == fileName.toLowerCase() ||
        (d['file_path'] as String? ?? '').toLowerCase().endsWith(fileName.toLowerCase())
      ).firstOrNull;
      if (match != null) {
        resolvedPath = match['file_path'] as String?;
      }
    }

    if (resolvedPath != null && resolvedPath.isNotEmpty && File(resolvedPath).existsSync()) {
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PdfViewerScreen(
            filePath: resolvedPath!,
            fileName: fileName,
            initialPageNumber: pageNumber,
          ),
        ),
      );
    } else {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF file not found on device: $fileName')),
      );
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard!'), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _showExportDialog() async {
    final logs = _diagnostics.logs;
    if (logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No AI query logs available to export.')),
      );
      return;
    }

    final selectedFormats = <AiDiagnosticExportFormat>{
      AiDiagnosticExportFormat.pdf,
      AiDiagnosticExportFormat.word,
      AiDiagnosticExportFormat.excel,
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.file_download_outlined, color: Colors.blue),
              SizedBox(width: 8),
              Text('Export Diagnostics', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Export ${logs.length} query execution log(s) and storage diagnostics. Select format(s):',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: selectedFormats.contains(AiDiagnosticExportFormat.pdf),
                title: const Text('PDF Document (.pdf)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Printable executive report with overview & citations', style: TextStyle(fontSize: 11)),
                secondary: const Icon(Icons.picture_as_pdf, color: Colors.red),
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (val) {
                  setDialogState(() {
                    if (val == true) {
                      selectedFormats.add(AiDiagnosticExportFormat.pdf);
                    } else {
                      selectedFormats.remove(AiDiagnosticExportFormat.pdf);
                    }
                  });
                },
              ),
              CheckboxListTile(
                value: selectedFormats.contains(AiDiagnosticExportFormat.word),
                title: const Text('Word Document (.docx)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Full markdown blocks, prompt trees & execution status', style: TextStyle(fontSize: 11)),
                secondary: const Icon(Icons.description, color: Colors.blue),
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (val) {
                  setDialogState(() {
                    if (val == true) {
                      selectedFormats.add(AiDiagnosticExportFormat.word);
                    } else {
                      selectedFormats.remove(AiDiagnosticExportFormat.word);
                    }
                  });
                },
              ),
              CheckboxListTile(
                value: selectedFormats.contains(AiDiagnosticExportFormat.excel),
                title: const Text('Excel Spreadsheet (.xlsx)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Tabular columns for metrics, timings, prompts & matches', style: TextStyle(fontSize: 11)),
                secondary: const Icon(Icons.table_chart, color: Colors.green),
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (val) {
                  setDialogState(() {
                    if (val == true) {
                      selectedFormats.add(AiDiagnosticExportFormat.excel);
                    } else {
                      selectedFormats.remove(AiDiagnosticExportFormat.excel);
                    }
                  });
                },
              ),
              if (selectedFormats.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8.0),
                  child: Text('Select at least one format to proceed.', style: TextStyle(color: Colors.red, fontSize: 12)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Export'),
              onPressed: selectedFormats.isEmpty ? null : () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || selectedFormats.isEmpty) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generating AI diagnostic exports...'), duration: Duration(seconds: 1)),
    );

    final settings = Provider.of<SettingsService>(context, listen: false);
    final exportDir = '${settings.exportPath}/AI_Diagnostics';

    final result = await AiDiagnosticsExportService().exportDiagnostics(
      formats: selectedFormats,
      logs: logs,
      storageStats: _storageStats,
      targetDirectory: exportDir,
    );

    if (!mounted) return;

    if (result.exportedFilePaths.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text('Exports Complete', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Successfully generated ${result.exportedFilePaths.length} diagnostic file(s):'),
              const SizedBox(height: 12),
              ...result.exportedFilePaths.map((path) {
                final fileName = path.split(Platform.pathSeparator).last;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    children: [
                      const Icon(Icons.insert_drive_file, size: 16, color: Colors.blueGrey),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          fileName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.open_in_new, size: 16),
                        tooltip: 'Open',
                        onPressed: () => OpenFilex.open(path),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.share, size: 16),
              label: const Text('Share All'),
              onPressed: () {
                final files = result.exportedFilePaths.map((p) => XFile(p)).toList();
                Share.shareXFiles(files, text: 'PasswordPDF AI Diagnostics Report');
              },
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: ${result.errors.join(", ")}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final logs = _diagnostics.logs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Diagnostics & Logs', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Export Diagnostics (PDF, Word, Excel)',
            onPressed: _showExportDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Storage Stats',
            onPressed: _loadStorageStats,
          ),
          if (logs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear Query Logs',
              onPressed: () {
                _diagnostics.clearLogs();
                setState(() {});
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Database & Storage Summary Card
          _buildStorageOverviewCard(colorScheme),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent AI Queries & Pipelines (${logs.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              if (logs.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('Copy All', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    final buffer = StringBuffer();
                    for (final log in logs) {
                      buffer.writeln('=== Query: ${log.rawQuery} (${log.timestamp}) ===');
                      buffer.writeln('Intent: ${log.detectedIntent}');
                      buffer.writeln('Keywords: ${log.extractedKeywords}');
                      buffer.writeln('Stopwords Removed: ${log.stopwordsRemoved}');
                      buffer.writeln('FTS Query: ${log.ftsQueryString}');
                      buffer.writeln('FTS Matches: ${log.ftsMatchesCount}');
                      buffer.writeln('Vector Matches: ${log.vectorMatchesCount}');
                      buffer.writeln('Model: ${log.activeChatModelName} [Status: ${log.llmExecutionStatus}]');
                      buffer.writeln('Prompt Sent:\n${log.promptSentToLlm}');
                      buffer.writeln('Final Answer:\n${log.finalAnswer}');
                      buffer.writeln('\n----------------------------------------\n');
                    }
                    _copyToClipboard(buffer.toString(), 'All AI Logs');
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),

          if (logs.isEmpty)
            Card(
              elevation: 0,
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                child: Column(
                  children: [
                    Icon(Icons.query_stats, size: 48, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      'No AI queries executed yet',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Send a message in the AI tab (with or without attached PDFs) and every step of the pipeline will appear here in detail.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else
            ...logs.map((log) => _buildLogEntryCard(log, colorScheme)),
        ],
      ),
    );
  }

  Widget _buildStorageOverviewCard(ColorScheme colorScheme) {
    if (_isLoadingStats) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Loading local AI storage stats...', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      );
    }

    final stats = _storageStats ?? {};
    final totalDocs = stats['total_documents'] ?? 0;
    final totalChunks = stats['total_chunks'] ?? 0;
    final totalEmbeddings = stats['total_embeddings'] ?? 0;
    final installedModels = stats['installed_models'] as List<dynamic>? ?? [];
    final activeModel = installedModels.where((m) => m['is_active'] == 1 && m['model_type'] == 'llm').firstOrNull;
    final activeEmbedder = installedModels.where((m) => m['is_active'] == 1 && m['model_type'] == 'embedding').firstOrNull;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                const Text('Local AI Storage & Index Status', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const Spacer(),
                Text('Tap item to inspect', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildClickableStatItem(
                    label: 'Indexed PDFs',
                    value: '$totalDocs',
                    icon: Icons.picture_as_pdf,
                    color: Colors.red,
                    onTap: () => _showIndexedDocumentsSheet(context),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildClickableStatItem(
                    label: 'Text Chunks',
                    value: '$totalChunks',
                    icon: Icons.text_snippet,
                    color: Colors.blue,
                    onTap: () => _showChunksSheet(context),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildClickableStatItem(
                    label: 'Embeddings',
                    value: '$totalEmbeddings',
                    icon: Icons.scatter_plot,
                    color: Colors.purple,
                    onTap: () => _showEmbeddingsSheet(context),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            InkWell(
              onTap: () => _showInstalledModelsSheet(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Active Chat Model: ${activeModel != null ? activeModel['display_name'] : 'None (Using Extractive Synthesis)'}',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colorScheme.primary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Active Embedder: ${activeEmbedder != null ? activeEmbedder['display_name'] : 'Deterministic Subword Vectors (128-dim)'}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClickableStatItem({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 11, color: Colors.grey[700], fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
                Icon(Icons.touch_app_outlined, size: 14, color: color.withValues(alpha: 0.6)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showIndexedDocumentsSheet(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    const Icon(Icons.picture_as_pdf, color: Colors.red),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Indexed PDF Documents', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          Text('Tap any PDF to inspect its stored text chunks', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _diagnostics.getDetailedDocuments(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snapshot.data ?? [];
                    if (docs.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'No PDF documents have been indexed yet.\nAttach a PDF in AI Studio to index it.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final doc = docs[index];
                        final fileName = doc['file_name'] as String? ?? 'Untitled';
                        final pages = doc['total_pages'] ?? 0;
                        final chunkCount = doc['chunk_count'] ?? 0;
                        final charCount = doc['char_count'] ?? 0;
                        final docId = doc['doc_id'] as String;
                        final indexedAt = doc['indexed_at'] != null
                            ? DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(doc['indexed_at']))
                            : 'N/A';

                        return Card(
                          margin: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            onTap: () => _openPdfViewer(
                              context: context,
                              fileName: fileName,
                              filePath: doc['file_path'] as String?,
                            ),
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.picture_as_pdf, color: Colors.red, size: 22),
                            ),
                            title: Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text('$pages page(s)  •  $chunkCount chunk(s)  •  $charCount chars', style: const TextStyle(fontSize: 12)),
                                const SizedBox(height: 2),
                                Text('Indexed: $indexedAt', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove_red_eye_outlined, size: 18, color: Colors.red),
                                  tooltip: 'Preview PDF',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _openPdfViewer(
                                    context: context,
                                    fileName: fileName,
                                    filePath: doc['file_path'] as String?,
                                  ),
                                ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.text_snippet_outlined, size: 14),
                                  label: const Text('Chunks', style: TextStyle(fontSize: 12)),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _showChunksSheet(context, docId: docId, docName: fileName);
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showChunksSheet(BuildContext context, {String? docId, String? docName}) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ChunksInspectorSheet(
        diagnostics: _diagnostics,
        initialDocId: docId,
        initialDocName: docName,
        onCopy: _copyToClipboard,
      ),
    );
  }

  Future<void> _showEmbeddingsSheet(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    const Icon(Icons.scatter_plot, color: Colors.purple),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Vector Embeddings Inspection', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          Text('Float32 cosine vectors stored for hybrid RAG search', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _diagnostics.getDetailedEmbeddings(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final embeddings = snapshot.data ?? [];
                    if (embeddings.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'No vector embeddings stored yet.\nAttach a PDF in AI Studio to generate embeddings.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: embeddings.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = embeddings[index];
                        final fileName = item['file_name'] as String? ?? 'Document';
                        final pageNum = item['page_number'] ?? 1;
                        final chunkIdx = item['chunk_index'] ?? 0;
                        final dim = item['dimensions'] as int? ?? 128;
                        final modelId = item['model_id'] as String? ?? 'subword_128d';
                        final chunkSnippet = item['chunk_text'] as String? ?? '';
                        final blob = item['embedding_blob'] as Uint8List?;

                        List<double> floatValues = [];
                        if (blob != null) {
                          final byteData = ByteData.sublistView(blob);
                          for (int i = 0; i < dim && (i * 4 + 4) <= blob.length; i++) {
                            floatValues.add(byteData.getFloat32(i * 4, Endian.little));
                          }
                        }

                        final previewList = floatValues.take(6).map((v) => (v >= 0 ? '+${v.toStringAsFixed(3)}' : v.toStringAsFixed(3))).toList();
                        final previewStr = '[${previewList.join(', ')}, ... ($dim dims)]';

                        return Card(
                          margin: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.purple.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text('$dim-dim vector', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.purple)),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '$fileName • p.$pageNum #$chunkIdx',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(modelId, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.grey.shade300),
                                  ),
                                  child: SelectableText(
                                    previewStr,
                                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.deepPurple),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Chunk text: ${chunkSnippet.length > 90 ? "${chunkSnippet.substring(0, 87)}..." : chunkSnippet}',
                                  style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey[700]),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton.icon(
                                      icon: const Icon(Icons.copy, size: 14),
                                      label: const Text('Copy Vector JSON', style: TextStyle(fontSize: 11)),
                                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                      onPressed: () {
                                        final jsonStr = jsonEncode(floatValues.map((v) => double.parse(v.toStringAsFixed(5))).toList());
                                        _copyToClipboard(jsonStr, 'Float Vector');
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showInstalledModelsSheet(BuildContext context) async {
    final installed = _storageStats?['installed_models'] as List<dynamic>? ?? [];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    const Icon(Icons.memory, color: Colors.teal),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Installed Local AI Models', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          Text('On-device LLMs & Embedding GGUFs stored in app storage', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: installed.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'No GGUF models downloaded yet.\nAI Studio will use High-Precision Extractive Synthesis.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: installed.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final model = installed[index];
                          final name = model['display_name'] as String? ?? 'Model';
                          final type = model['model_type'] as String? ?? 'llm';
                          final sizeBytes = model['file_size_bytes'] as int? ?? 0;
                          final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
                          final isActive = model['is_active'] == 1;
                          final quant = model['quantization'] as String? ?? 'Q4_K_M';
                          final path = model['file_path'] as String? ?? '';
                          final fileExists = path.isNotEmpty && File(path).existsSync();

                          return Card(
                            margin: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: isActive ? Colors.green : Theme.of(context).colorScheme.outlineVariant,
                                width: isActive ? 1.5 : 1.0,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(type == 'llm' ? Icons.smart_toy : Icons.blur_linear,
                                          color: type == 'llm' ? Colors.blue : Colors.purple, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                      ),
                                      if (isActive)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: Colors.green),
                                          ),
                                          child: const Text('ACTIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green)),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Type: ${type.toUpperCase()}  •  Size: $sizeMb MB  •  Quant: $quant',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(fileExists ? Icons.check_circle : Icons.warning,
                                          size: 12, color: fileExists ? Colors.green : Colors.red),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          fileExists ? 'File exists on disk ($path)' : 'File missing from disk ($path)',
                                          style: TextStyle(fontSize: 10, color: fileExists ? Colors.grey[600] : Colors.red),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogEntryCard(AiDiagnosticLogEntry log, ColorScheme colorScheme) {
    final timeStr = DateFormat('HH:mm:ss').format(log.timestamp);
    final isGreeting = log.detectedIntent == 'greeting';
    final isInProgress = log.detectedIntent == 'in_progress' || log.llmExecutionStatus.startsWith('in_progress');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isInProgress ? Colors.amber.shade700 : colorScheme.outlineVariant,
          width: isInProgress ? 1.5 : 1.0,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isInProgress
                  ? Colors.amber.shade100
                  : (isGreeting ? Colors.green.shade50 : colorScheme.primaryContainer.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: isInProgress
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber),
                  )
                : Icon(
                    isGreeting ? Icons.waving_hand : Icons.chat_bubble_outline,
                    size: 18,
                    color: isGreeting ? Colors.green.shade800 : colorScheme.primary,
                  ),
          ),
          title: Text(
            log.rawQuery,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            isInProgress
                ? '$timeStr  •  ⚡ IN PROGRESS  •  ${log.llmExecutionStatus.replaceFirst('in_progress: ', '')}'
                : '$timeStr  •  Intent: ${log.detectedIntent}  •  ${log.executionTimeMs} ms',
            style: TextStyle(
              fontSize: 11,
              color: isInProgress ? Colors.amber.shade900 : Colors.grey[600],
              fontWeight: isInProgress ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          children: [
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Query Processing Section
                  _buildSectionTitle('1. Query Processing & Tokenization', Icons.filter_alt_outlined),
                  _buildKeyValue('Raw Input', log.rawQuery),
                  _buildKeyValue('Cleaned Keywords', log.extractedKeywords.isEmpty ? '(none)' : log.extractedKeywords.join(', ')),
                  _buildKeyValue('Stopwords Filtered', log.stopwordsRemoved.isEmpty ? '(none)' : log.stopwordsRemoved.join(', ')),
                  _buildKeyValue('FTS5 Query', log.ftsQueryString.isEmpty ? '(none)' : log.ftsQueryString),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(
                          width: 140,
                          child: Text('Attached Docs', style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)),
                        ),
                        Expanded(
                          child: log.attachedDocNames.isEmpty
                              ? const Text('None (Global Knowledge)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500))
                              : Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: log.attachedDocNames.map((name) {
                                    return ActionChip(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                                      avatar: const Icon(Icons.picture_as_pdf, size: 12, color: Colors.red),
                                      label: Text(name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                                      tooltip: 'Tap to preview PDF',
                                      onPressed: () => _openPdfViewer(context: context, fileName: name),
                                    );
                                  }).toList(),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 2. Retrieval Stage Section
                  _buildSectionTitle('2. Hybrid Retrieval Results', Icons.search),
                  _buildKeyValue('FTS5 Keyword Matches', '${log.ftsMatchesCount} chunk(s) found'),
                  if (log.ftsMatches.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: log.ftsMatches.take(3).map((m) {
                          return Text(
                            '• Page ${m['pageNumber']}: "${m['snippet']}"',
                            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                          );
                        }).toList(),
                      ),
                    ),
                  _buildKeyValue('Dense Vector Matches', '${log.vectorMatchesCount} chunk(s) evaluated'),
                  _buildKeyValue('Selected Evidence Chunks', '${log.selectedEvidence.length} chunk(s) passed to LLM'),
                  if (log.selectedEvidence.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: log.selectedEvidence.map((e) {
                          final fName = e['fileName'] as String? ?? 'Document';
                          final pNum = e['pageNumber'] as int? ?? 1;
                          final snip = e['snippet'] as String? ?? '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: InkWell(
                              onTap: () => _openPdfViewer(context: context, fileName: fName, pageNumber: pNum),
                              borderRadius: BorderRadius.circular(4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.picture_as_pdf, size: 12, color: Colors.red),
                                  const SizedBox(width: 4),
                                  Text(
                                    '[$fName - Page $pNum]',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blue),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      ': "$snip"',
                                      style: const TextStyle(fontSize: 11),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  const SizedBox(height: 12),

                  // 3. Prompt Construction Section
                  if (log.promptSentToLlm.isNotEmpty) ...[
                    _buildSectionTitle('3. Prompt Constructed for LLM', Icons.code),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: SelectableText(
                        log.promptSentToLlm,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.copy, size: 14),
                        label: const Text('Copy Prompt', style: TextStyle(fontSize: 11)),
                        onPressed: () => _copyToClipboard(log.promptSentToLlm, 'LLM Prompt'),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // 4. Model Execution Section
                  _buildSectionTitle('4. Model Execution & Native Status', Icons.memory),
                  _buildKeyValue('Active Chat Model', log.activeChatModelName ?? 'None'),
                  _buildKeyValue('Model Path', log.activeChatModelPath ?? 'N/A'),
                  _buildKeyValue('Engine Status', log.llmExecutionStatus),
                  if (log.llmRawResponse != null)
                    _buildKeyValue('Raw LLM Output', log.llmRawResponse!),
                  const SizedBox(height: 12),

                  // 5. Final Answer Delivered
                  _buildSectionTitle('5. Final Answer Presented to User', Icons.check_circle_outline),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: SelectableText(
                      log.finalAnswer,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.blueGrey),
          const SizedBox(width: 6),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey)),
        ],
      ),
    );
  }

  Widget _buildKeyValue(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(key, style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet for searching and inspecting text chunks extracted from PDFs
class _ChunksInspectorSheet extends StatefulWidget {
  final AiDiagnosticsService diagnostics;
  final String? initialDocId;
  final String? initialDocName;
  final void Function(String text, String label) onCopy;

  const _ChunksInspectorSheet({
    required this.diagnostics,
    this.initialDocId,
    this.initialDocName,
    required this.onCopy,
  });

  @override
  State<_ChunksInspectorSheet> createState() => _ChunksInspectorSheetState();
}

class _ChunksInspectorSheetState extends State<_ChunksInspectorSheet> {
  final TextEditingController _searchController = TextEditingController();
  String? _selectedDocId;
  String? _selectedDocName;
  List<Map<String, dynamic>> _chunks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _selectedDocId = widget.initialDocId;
    _selectedDocName = widget.initialDocName;
    _loadChunks();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadChunks() async {
    setState(() => _isLoading = true);
    try {
      final results = await widget.diagnostics.getDetailedChunks(
        docId: _selectedDocId,
        searchFilter: _searchController.text.trim().isNotEmpty ? _searchController.text.trim() : null,
      );
      if (mounted) {
        setState(() {
          _chunks = results;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showFullChunkDialog(Map<String, dynamic> chunk) {
    final fileName = chunk['file_name'] as String? ?? 'Document';
    final pageNum = chunk['page_number'] ?? 1;
    final chunkIdx = chunk['chunk_index'] ?? 0;
    final text = chunk['chunk_text'] as String? ?? '';
    final length = chunk['char_length'] ?? text.length;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.text_snippet, color: Colors.blue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$fileName (p.$pageNum #$chunkIdx)',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Length: $length characters', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 8),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy Chunk Text'),
            onPressed: () {
              widget.onCopy(text, 'Chunk Text');
              Navigator.pop(ctx);
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.text_snippet, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedDocName != null ? 'Chunks for "$_selectedDocName"' : 'Stored Text Chunks',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${_chunks.length} chunk(s) indexed for hybrid lexical & vector search',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (_selectedDocId != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Chip(
                      avatar: const Icon(Icons.filter_alt, size: 14),
                      label: Text('Filtered: $_selectedDocName', style: const TextStyle(fontSize: 11)),
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: () {
                        setState(() {
                          _selectedDocId = null;
                          _selectedDocName = null;
                        });
                        _loadChunks();
                      },
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search chunks by text or keywords...',
                  hintStyle: const TextStyle(fontSize: 13),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _loadChunks();
                          },
                        )
                      : null,
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => _loadChunks(),
                onChanged: (_) {
                  setState(() {});
                  _loadChunks();
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _chunks.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'No text chunks found matching your filter.\nAttach and index PDFs to extract text chunks.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount: _chunks.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final chunk = _chunks[index];
                            final fileName = chunk['file_name'] as String? ?? 'Document';
                            final pageNum = chunk['page_number'] ?? 1;
                            final chunkIdx = chunk['chunk_index'] ?? 0;
                            final text = chunk['chunk_text'] as String? ?? '';
                            final length = chunk['char_length'] ?? text.length;
                            final hasEmbedding = chunk['has_embedding'] == 1;

                            return Card(
                              margin: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                              ),
                              child: InkWell(
                                onTap: () => _showFullChunkDialog(chunk),
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.blue.withValues(alpha: 0.1),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text('Page $pageNum • Chunk #$chunkIdx',
                                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue)),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              fileName,
                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (hasEmbedding)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: Colors.purple.withValues(alpha: 0.1),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: const Text('128d vector', style: TextStyle(fontSize: 9, color: Colors.purple, fontWeight: FontWeight.w600)),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        text.length > 200 ? '${text.substring(0, 197)}...' : text,
                                        style: const TextStyle(fontSize: 12, height: 1.35),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text('$length chars', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                                          Row(
                                            children: [
                                              TextButton.icon(
                                                icon: const Icon(Icons.copy, size: 14),
                                                label: const Text('Copy', style: TextStyle(fontSize: 11)),
                                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                                onPressed: () => widget.onCopy(text, 'Chunk Text'),
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

