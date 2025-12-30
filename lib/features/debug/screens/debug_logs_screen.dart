import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../../services/logging_service.dart';

/// Debug Logs screen for viewing app logs
class DebugLogsScreen extends StatefulWidget {
  const DebugLogsScreen({super.key});

  @override
  State<DebugLogsScreen> createState() => _DebugLogsScreenState();
}

class _DebugLogsScreenState extends State<DebugLogsScreen> {
  final LoggingService _loggingService = LoggingService();
  String _filterLevel = 'ALL';
  String _searchQuery = '';

  List<LogEntry> get _filteredLogs {
    var logs = _loggingService.logs;
    
    if (_filterLevel != 'ALL') {
      logs = logs.where((log) => log.level == _filterLevel).toList();
    }
    
    if (_searchQuery.isNotEmpty) {
      logs = logs.where((log) =>
        log.message.toLowerCase().contains(_searchQuery.toLowerCase()) ||
        log.tag.toLowerCase().contains(_searchQuery.toLowerCase())
      ).toList();
    }
    
    return logs;
  }

  Color _getLevelColor(String level) {
    switch (level) {
      case 'ERROR':
        return Colors.red;
      case 'WARN':
        return Colors.orange;
      case 'INFO':
        return Colors.blue;
      case 'DEBUG':
        return Colors.grey;
      default:
        return Colors.black;
    }
  }

  IconData _getLevelIcon(String level) {
    switch (level) {
      case 'ERROR':
        return Icons.error;
      case 'WARN':
        return Icons.warning;
      case 'INFO':
        return Icons.info;
      case 'DEBUG':
        return Icons.bug_report;
      default:
        return Icons.circle;
    }
  }

  /// Export logs to file and share
  Future<void> _exportLogs() async {
    try {
      final logs = _loggingService.logs;
      if (logs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No logs to export')),
        );
        return;
      }

      // Format logs as text
      final buffer = StringBuffer();
      buffer.writeln('=== PDF Manager Debug Logs ===');
      buffer.writeln('Exported: ${DateTime.now().toIso8601String()}');
      buffer.writeln('Total Entries: ${logs.length}');
      buffer.writeln('');
      buffer.writeln('--- Logs ---');
      buffer.writeln('');

      for (final log in logs) {
        buffer.writeln('[${log.timestamp.toIso8601String()}] [${log.level}] ${log.tag}');
        buffer.writeln(log.message);
        if (log.stackTrace != null) {
          buffer.writeln('Stack Trace:');
          buffer.writeln(log.stackTrace);
        }
        buffer.writeln('---');
      }

      // Get temp directory and save file
      final tempDir = await getTemporaryDirectory();
      final fileName = 'debug_logs_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.txt';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(buffer.toString());

      // Share the file
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'PDF Manager Debug Logs',
        text: 'Debug logs exported from PDF Manager app',
      );

      _loggingService.info('DebugLogsScreen', 'Logs exported: $fileName');
    } catch (e) {
      _loggingService.error('DebugLogsScreen', 'Failed to export logs', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export logs: $e')),
        );
      }
    }
  }

  /// Copy all logs to clipboard
  Future<void> _copyLogs() async {
    try {
      final logs = _loggingService.logs;
      if (logs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No logs to copy')),
        );
        return;
      }

      final buffer = StringBuffer();
      for (final log in logs) {
        buffer.writeln('[${log.level}] ${log.tag}: ${log.message}');
        if (log.stackTrace != null) {
          buffer.writeln(log.stackTrace);
        }
      }

      // Share as text (clipboard not always available)
      await Share.share(buffer.toString(), subject: 'PDF Manager Logs');
      
      _loggingService.info('DebugLogsScreen', 'Logs copied/shared');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = _filteredLogs;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _exportLogs,
            tooltip: 'Export Logs',
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyLogs,
            tooltip: 'Copy Logs',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') {
                _loggingService.clearLogs();
                setState(() {});
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Clear All Logs'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter bar
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceVariant,
            child: Column(
              children: [
                // Search
                TextField(
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Search logs...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                const SizedBox(height: 8),
                // Level filter chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final level in ['ALL', 'ERROR', 'WARN', 'INFO', 'DEBUG'])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(level),
                            selected: _filterLevel == level,
                            onSelected: (selected) {
                              setState(() {
                                _filterLevel = level;
                              });
                            },
                            selectedColor: level == 'ALL' 
                                ? Theme.of(context).colorScheme.primaryContainer
                                : _getLevelColor(level).withOpacity(0.3),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Stats bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatChip('Total', _loggingService.logs.length, Colors.grey),
                _buildStatChip('Errors', _loggingService.getLogsByLevel('ERROR').length, Colors.red),
                _buildStatChip('Warnings', _loggingService.getLogsByLevel('WARN').length, Colors.orange),
              ],
            ),
          ),
          
          const Divider(height: 1),
          
          // Logs list
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No logs yet',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final log = logs[index];
                      return _buildLogItem(log);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogItem(LogEntry log) {
    final timeFormat = DateFormat('HH:mm:ss.SSS');
    final dateFormat = DateFormat('MMM dd');
    
    return ExpansionTile(
      leading: Icon(
        _getLevelIcon(log.level),
        color: _getLevelColor(log.level),
        size: 20,
      ),
      title: Text(
        log.message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        '${log.tag} • ${timeFormat.format(log.timestamp)}',
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey.shade600,
        ),
      ),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDetailRow('Level', log.level),
              _buildDetailRow('Tag', log.tag),
              _buildDetailRow('Date', dateFormat.format(log.timestamp)),
              _buildDetailRow('Time', timeFormat.format(log.timestamp)),
              const SizedBox(height: 8),
              const Text(
                'Message:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  log.message,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              if (log.stackTrace != null) ...[
                const SizedBox(height: 8),
                const Text(
                  'Stack Trace:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    log.stackTrace!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.red,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
