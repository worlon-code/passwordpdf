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
import 'dart:convert';

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

  void _openExportQueue() {
     Navigator.push(
       context,
       MaterialPageRoute(
         builder: (context) => const ExportProgressScreen(showDeveloper: true),
       ),
     );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Developer Tools'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'Export Queue',
            onPressed: _openExportQueue,
          ),
        ],
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
  final ExportQueueService _exportQueue = ExportQueueService();
  List<LogEntry> _logs = [];
  String _selectedFilter = 'All';
  final List<String> _filters = ['All', 'Info', 'Warn', 'Error'];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    // await Future.delayed(const Duration(milliseconds: 500)); // Remove delay, DB is async
    final allLogs = await _log.getAllLogs();
    if (!mounted) return;
    
    setState(() {
      if (_selectedFilter == 'All') {
        _logs = allLogs;
      } else {
        _logs = allLogs.where((l) => l.level.toLowerCase() == _selectedFilter.toLowerCase()).toList();
      }
    });
  }

  Future<void> _exportLogs() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);

      // Add to queue (No temp file needed anymore, service handles generic log export)
      await _exportQueue.addJob(
        'Logs Export',
        [], // No items needed for generic logs export
        exportDir: '${settings.exportPath}/Developer',
        type: ExportType.logs,
        isDeveloper: true,
      );
      
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           const SnackBar(content: Text('Logs Excel export queued')),
         );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export init failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _filters.map((filter) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(filter, style: TextStyle(
                      fontSize: 12,
                      color: _selectedFilter == filter ? Colors.white : Colors.black87,
                    )),
                    selected: _selectedFilter == filter,
                    selectedColor: Theme.of(context).primaryColor,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedFilter = filter);
                        _loadLogs();
                      }
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
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
    
    // Add virtual tables for JSON data (SharedPrefs)
    final prefs = await SharedPreferences.getInstance();
    // Check specific keys we know of
    if (prefs.containsKey('documents_items')) {
      tables.add('JSON: documents_items');
    }
    
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
    
    List<Map<String, dynamic>> data = [];
    
    if (_selectedTable!.startsWith('JSON: ')) {
      // Load JSON data
      final key = _selectedTable!.replaceAll('JSON: ', '');
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(key);
      if (jsonStr != null) {
        try {
          final decoded = jsonDecode(jsonStr);
          if (decoded is List) {
            data = List<Map<String, dynamic>>.from(decoded.map((e) => Map<String, dynamic>.from(e)));
          } else if (decoded is Map) {
             data = [Map<String, dynamic>.from(decoded)];
          }
        } catch (e) {
          data = [{'error': 'Failed to parse JSON: $e'}];
        }
      }
    } else {
      // Load SQL data
      data = await _storage.getTableData(_selectedTable!);
    }
    
    setState(() {
      _tableData = List.from(data); 
      _isLoading = false;
    });
  }

  Future<void> _editRecord(Map<String, dynamic> record) async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    // Check for encryption key record
    if (record.values.any((v) => v == 'encryption_key')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot modify Encryption Key!'),
          backgroundColor: settings.accentColor,
        ),
      );
      return;
    }
    
    // JSON tables read-only for now (safer)
    if (_selectedTable!.startsWith('JSON: ')) {
      ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('JSON tables are read-only in this view')),
      );
      return;
    }

    final id = record['id'];
    if (id == null) return;

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
                             const SnackBar(content: Text('Copied')),
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
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Update')),
        ],
      ),
    );

    if (confirm == true) {
      final newData = <String, dynamic>{};
      controllers.forEach((key, controller) {
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

    if (_selectedTable!.startsWith('JSON: ')) {
      ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('JSON tables are read-only in this view')),
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
    
    await _exportQueue.addJob(
      'Database Export',
      [], 
      exportDir: '${settings.exportPath}/Developer',
      type: ExportType.excel,
      isDeveloper: true,
    );
     
    if (mounted) {
       Navigator.push(
         context,
         MaterialPageRoute(
           builder: (context) => const ExportProgressScreen(showDeveloper: true),
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
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
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
                tooltip: 'Export Database',
                onPressed: _exportDatabase,
              ),
            ],
          ),
        ),
        
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
                           if (!_selectedTable!.startsWith('JSON: '))
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
                              if (!_selectedTable!.startsWith('JSON: '))
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
