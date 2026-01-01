import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../../../services/logging_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/export_queue_service.dart';
import '../../documents/screens/export_progress_screen.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:excel/excel.dart';
import '../../settings/services/settings_service.dart';

/// Developer Screen with password protection and generic DB viewer
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Developer Tools'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.bug_report), text: 'Logs'),
            Tab(icon: Icon(Icons.category), text: 'Database'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _DebugLogsTab(),
          _DatabaseTab(),
        ],
      ),
    );
  }
}

/// Debug Logs Tab with Pull-to-Refresh
class _DebugLogsTab extends StatefulWidget {
  const _DebugLogsTab();

  @override
  State<_DebugLogsTab> createState() => _DebugLogsTabState();
}

class _DebugLogsTabState extends State<_DebugLogsTab> {
  final LoggingService _log = LoggingService();
  List<LogEntry> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    // Simulate delay for pull-to-refresh feel
    await Future.delayed(const Duration(milliseconds: 500));
    setState(() => _logs = _log.logs);
  }

  Future<void> _exportLogs() async {
    try {
      final buffer = StringBuffer();
      for (final log in _logs) {
        buffer.writeln('[${log.timestamp}] [${log.level.toUpperCase()}] ${log.tag}: ${log.message}');
      }
      
      final settings = Provider.of<SettingsService>(context, listen: false);
      String basePath;
      if (settings.exportPath != null) {
        basePath = settings.exportPath!;
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        basePath = appDir.path;
      }

      final devDir = Directory('$basePath/Developer');
      if (!await devDir.exists()) {
        await devDir.create(recursive: true);
      }
      
      final file = File('${devDir.path}/logs_export_${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(buffer.toString());
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logs exported to: ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Text('${_logs.length} entries', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: 'Export Logs',
                onPressed: _exportLogs,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Clear Logs',
                onPressed: () {
                  _log.clearLogs();
                  _loadLogs();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadLogs,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final log = _logs[_logs.length - 1 - index]; // Reverse order
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      log.level == 'error' ? Icons.error : 
                      log.level == 'warn' ? Icons.warning : Icons.info,
                      color: log.level == 'error' ? Colors.red :
                             log.level == 'warn' ? Colors.orange : Colors.blue,
                      size: 20,
                    ),
                    title: Text(
                      log.message,
                      style: const TextStyle(fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${log.tag} • ${log.timestamp.toString().substring(0, 19)}',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Generic Database Viewer Tab
class _DatabaseTab extends StatefulWidget {
  const _DatabaseTab();

  @override
  State<_DatabaseTab> createState() => _DatabaseTabState();
}

class _DatabaseTabState extends State<_DatabaseTab> {
  final StorageService _storage = StorageService();
  final ExportQueueService _exportQueue = ExportQueueService();
  
  List<String> _tables = [];
  String? _selectedTable;
  List<Map<String, dynamic>> _tableData = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  Future<void> _loadTables() async {
    final tables = await _storage.getTables();
    setState(() {
      _tables = tables;
      if (_tables.isNotEmpty && _selectedTable == null) {
        _selectedTable = _tables.first;
        _loadTableData();
      }
    });
  }

  Future<void> _loadTableData() async {
    if (_selectedTable == null) return;
    setState(() => _isLoading = true);
    
    // Simulate network delay for effect if desired, or just load
    await Future.delayed(const Duration(milliseconds: 300));
    final data = await _storage.getTableData(_selectedTable!);
    
    setState(() {
      _tableData = List.from(data); // Mutable copy
      _isLoading = false;
    });
  }

  Future<void> _editRecord(Map<String, dynamic> record) async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    // Check for encryption key record - Cannot edit AT ALL
    if (record.values.any((v) => v == 'encryption_key')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot modify Encryption Key!'),
          backgroundColor: settings.accentColor,
        ),
      );
      return;
    }

    final id = record['id'];
    if (id == null) return;

    // Create controllers
    final controllers = <String, TextEditingController>{};
    record.forEach((key, value) {
      if (key != 'id') {
        controllers[key] = TextEditingController(text: value.toString());
      }
    });

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Record (ID: $id)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: controllers.entries.map((e) {
              final isEncryptedValue = e.key == 'encrypted_value';
              
              return Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: e.value,
                        decoration: InputDecoration(
                          labelText: e.key,
                          border: const OutlineInputBorder(),
                          filled: isEncryptedValue,
                        ),
                        readOnly: isEncryptedValue,
                        maxLines: isEncryptedValue ? 3 : 1,
                      ),
                    ),
                    if (isEncryptedValue)
                      IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: e.value.text));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Copied to clipboard')),
                          );
                        },
                      ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true), 
            child: const Text('Update'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final newData = <String, dynamic>{};
      controllers.forEach((key, controller) {
        // Skip encrypted_value update as it's read-only
        if (key != 'encrypted_value') {
          newData[key] = controller.text;
        }
      });

      if (newData.isNotEmpty) {
        await _storage.updateRecord(_selectedTable!, 'id', id, newData);
        _loadTableData();
      }
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
     // Check for encryption key
    if (record.values.any((v) => v == 'encryption_key')) {
      final settings = Provider.of<SettingsService>(context, listen: false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot delete Encryption Key!'),
          backgroundColor: settings.accentColor,
        ),
      );
      return;
    }

    final id = record['id'];
    if (id == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Record'),
        content: Text('Delete record ID $id?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirm == true) {
      await _storage.deleteRecord(_selectedTable!, 'id', id);
      _loadTableData();
    }
  }

  Future<void> _exportDatabase() async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    // Add job to queue
    await _exportQueue.addJob(
      'Database Export',
      [], // No items needed for this job type
      exportDir: settings.exportPath,
      type: ExportType.excel,
    );
    
    if (mounted) {
       // Navigate to Export Dashboard to show queue
       Navigator.push(
         context,
         MaterialPageRoute(
           builder: (context) => const ExportProgressScreen(),
         ),
       );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_tables.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              // Table Selector
              Expanded(
                child: DropdownButton<String>(
                  value: _selectedTable,
                  isExpanded: true,
                  hint: const Text('Select Table'),
                  onChanged: (v) {
                    setState(() => _selectedTable = v);
                    _loadTableData();
                  },
                  items: _tables.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                ),
              ),
              const SizedBox(width: 8),
              if (_isLoading)
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              else
                IconButton(icon: const Icon(Icons.refresh), onPressed: _loadTableData),
              
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: 'Export Database to Excel',
                onPressed: _exportDatabase,
              ),
            ],
          ),
        ),
        
        // Data View
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadTableData,
            child: _tableData.isEmpty
                ? const Center(child: Text('No data'))
                : SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowColor: MaterialStateProperty.all(Colors.grey.shade200),
                        columns: [
                           ..._tableData.first.keys.map((k) => DataColumn(label: Text(k))),
                           const DataColumn(label: Text('Actions')),
                        ],
                        rows: _tableData.map((row) {
                          return DataRow(
                            cells: [
                              ...row.values.map((v) => DataCell(
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 200),
                                  child: Text(v?.toString() ?? '', overflow: TextOverflow.ellipsis),
                                ),
                              )),
                              DataCell(Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 18),
                                    onPressed: () => _editRecord(row),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, size: 18),
                                    color: Colors.red,
                                    onPressed: () => _deleteRecord(row),
                                  ),
                                ],
                              )),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
