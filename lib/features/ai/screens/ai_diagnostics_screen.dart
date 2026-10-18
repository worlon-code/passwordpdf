import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../services/ai/ai_diagnostics_service.dart';

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
    _loadStorageStats();
  }

  Future<void> _loadStorageStats() async {
    setState(() => _isLoadingStats = true);
    final stats = await _diagnostics.getStorageDiagnostics();
    if (mounted) {
      setState(() {
        _storageStats = stats;
        _isLoadingStats = false;
      });
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard!'), duration: const Duration(seconds: 2)),
    );
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
          child: Center(child: CircularProgressIndicator()),
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
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _buildStatItem('Indexed PDFs', '$totalDocs', Icons.picture_as_pdf)),
                Expanded(child: _buildStatItem('Text Chunks', '$totalChunks', Icons.text_snippet)),
                Expanded(child: _buildStatItem('Embeddings', '$totalEmbeddings', Icons.scatter_plot)),
              ],
            ),
            const Divider(height: 20),
            Text(
              'Active Chat Model: ${activeModel != null ? activeModel['display_name'] : 'None (Using Extractive Synthesis)'}',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colorScheme.primary),
            ),
            const SizedBox(height: 4),
            Text(
              'Active Embedder: ${activeEmbedder != null ? activeEmbedder['display_name'] : 'Deterministic Subword Vectors (128-dim)'}',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: Colors.grey[600]),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildLogEntryCard(AiDiagnosticLogEntry log, ColorScheme colorScheme) {
    final timeStr = DateFormat('HH:mm:ss').format(log.timestamp);
    final isGreeting = log.detectedIntent == 'greeting';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isGreeting ? Colors.green.shade50 : colorScheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
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
            '$timeStr  •  Intent: ${log.detectedIntent}  •  ${log.executionTimeMs} ms',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
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
                  _buildKeyValue('Attached Docs', log.attachedDocNames.isEmpty ? 'None (Global Knowledge)' : log.attachedDocNames.join(', ')),
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
                          return Text(
                            '• [${e['fileName']} - Page ${e['pageNumber']}]: "${e['snippet']}"',
                            style: const TextStyle(fontSize: 11),
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
