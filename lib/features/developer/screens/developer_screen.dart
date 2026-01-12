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
// import 'package:excel/excel.dart'; // BLOCKED: Conflicts with pdfrx v2
import '../../settings/services/settings_service.dart';
import '../../../services/encryption_service.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart'; // For compute
import '../utils/json_parser.dart'; // Helper for isolate

/// Developer Screen with password protection and generic DB viewer
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final EncryptionService _encryptionService = EncryptionService();
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  Future<void> _manageEncryptionKey() async {
    final isSet = await _encryptionService.isKeySet();
    
    if (isSet) {
      // View Key
      final key = await _encryptionService.getEncryptionKey('Portal123!'); // Developer password verified
      if (key != null && mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.key, color: Colors.amber),
                SizedBox(width: 8),
                Text('Encryption Key'),
              ],
            ),
            content: SelectableText(
              key,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } else {
      // Set Key
      final controller = TextEditingController();
      final generatedKey = _encryptionService.generateRandomKey(24);
      controller.text = generatedKey;

      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.key, color: Colors.amber),
              SizedBox(width: 8),
              Text('Set Encryption Key'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This key will be used to encrypt all your stored passwords.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: 'Encryption Key',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Generate new key',
                    onPressed: () {
                      controller.text = _encryptionService.generateRandomKey(24);
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Set Key'),
            ),
          ],
        ),
      );

      if (result == true && controller.text.isNotEmpty) {
        final success = await _encryptionService.setEncryptionKey(controller.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(success ? 'Encryption key set' : 'Failed to set key'),
              backgroundColor: success ? Colors.green : Colors.red,
            ),
          );
        }
      }
    }
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
            icon: const Icon(Icons.key),
            tooltip: 'Encryption Key',
            onPressed: _manageEncryptionKey,
          ),
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
  Map<String, int> _logCounts = {};
  String _selectedFilter = 'All';
  final List<String> _filters = ['All', 'Info', 'Warn', 'Error'];
  
  // New: Sort and Tag Filter
  bool _sortDescending = true; // Latest first by default
  String _tagFilter = 'All';
  List<String> _availableTags = ['All'];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final allLogs = await _log.getAllLogs();
    if (!mounted) return;
    
    // Extract unique tags
    final tags = <String>{'All'};
    for (final log in allLogs) {
      tags.add(log.tag);
    }
    
    // Calculate counts
    final counts = <String, int>{
      'All': allLogs.length,
      'Info': 0,
      'Warn': 0,
      'Error': 0,
    };
    
    for (final log in allLogs) {
      final level = log.level;
      if (level.toUpperCase().contains('INFO')) counts['Info'] = (counts['Info'] ?? 0) + 1;
      else if (level.toUpperCase().contains('WARN')) counts['Warn'] = (counts['Warn'] ?? 0) + 1;
      else if (level.toUpperCase().contains('ERROR')) counts['Error'] = (counts['Error'] ?? 0) + 1;
    }
    
    // Apply filters
    var filtered = allLogs.toList();
    
    // Level filter
    if (_selectedFilter != 'All') {
      filtered = filtered.where((l) => l.level.toLowerCase().contains(_selectedFilter.toLowerCase())).toList();
    }
    
    // Tag filter
    if (_tagFilter != 'All') {
      filtered = filtered.where((l) => l.tag == _tagFilter).toList();
    }
    
    // Sort by timestamp
    if (_sortDescending) {
      filtered.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } else {
      filtered.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }
    
    setState(() {
      _logCounts = counts;
      _logs = filtered;
      _availableTags = tags.toList()..sort();
    });
  }

  Future<void> _showLogSettings() async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final controller = TextEditingController(text: settings.maxLogCount.toString());
    
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Max Log Retention (1000 - 50000)'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                suffixText: 'entries',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final val = int.tryParse(controller.text);
              if (val != null) {
                await settings.setMaxLogCount(val);
                if (mounted) {
                   ScaffoldMessenger.of(context).showSnackBar(
                     SnackBar(content: Text('Max logs set to ${settings.maxLogCount}')),
                   );
                   Navigator.pop(context);
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
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
                  child: FilterChip(
                    label: Text('${filter} (${_logCounts[filter] ?? 0})', style: TextStyle(
                      fontSize: 12,
                      color: _selectedFilter == filter 
                          ? Colors.white 
                          : Theme.of(context).colorScheme.onSurface,
                    )),
                    selected: _selectedFilter == filter,
                    selectedColor: Theme.of(context).primaryColor,
                    checkmarkColor: Colors.white,
                    onSelected: (selected) {
                      setState(() => _selectedFilter = filter); // Always select, no toggle off to null in this UI
                      _loadLogs();
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              // Tag filter dropdown
              DropdownButton<String>(
                value: _tagFilter,
                isDense: true,
                underline: const SizedBox(),
                icon: const Icon(Icons.arrow_drop_down, size: 16),
                style: Theme.of(context).textTheme.bodySmall,
                items: _availableTags.map((tag) => DropdownMenuItem(
                  value: tag,
                  child: Text(tag.length > 15 ? '${tag.substring(0, 15)}...' : tag, 
                    style: const TextStyle(fontSize: 11)),
                )).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _tagFilter = value);
                    _loadLogs();
                  }
                },
              ),
              const Spacer(),
              Text('${_logs.length} entries', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Sort toggle
              IconButton(
                icon: Icon(_sortDescending ? Icons.arrow_downward : Icons.arrow_upward, size: 18),
                tooltip: _sortDescending ? 'Latest First' : 'Oldest First',
                onPressed: () {
                  setState(() => _sortDescending = !_sortDescending);
                  _loadLogs();
                },
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'Log Settings',
                onPressed: _showLogSettings,
              ),
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
              final log = _logs[_logs.length - 1 - index]; // Reverse order (latest first)
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ExpansionTile(
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
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('Level: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              Text(log.level.toUpperCase(), style: const TextStyle(fontSize: 11)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Text('Tag: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              Expanded(child: Text(log.tag, style: const TextStyle(fontSize: 11))),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Text('Time: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                              Text(log.timestamp.toString(), style: const TextStyle(fontSize: 11)),
                            ],
                          ),
                          const Divider(),
                          const Text('Full Message:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                          const SizedBox(height: 4),
                          SelectableText(
                            log.message,
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),
                  ],
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

  int _currentPage = 0;
  final int _itemsPerPage = 10; // Reducing to 10 for safer mobile performance

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
    
    setState(() {
      _isLoading = true;
      _tableData = []; // Clear data to force UI to show loader and drop old complex layout
    });
    
    // Force a frame render to show the loader
    await Future.delayed(Duration.zero);
    
    // Artificial small delay to ensures the spinner has time to spin safely before heavy logic
    await Future.delayed(const Duration(milliseconds: 50));

    List<Map<String, dynamic>> data = [];

    try {
      if (_selectedTable!.startsWith('JSON: ')) {
        // JSON tables don't support SQL pagination easily, load all then slice
        final key = _selectedTable!.replaceAll('JSON: ', '');
        final prefs = await SharedPreferences.getInstance();
        final jsonStr = prefs.getString(key);
        if (jsonStr != null) {
          // Use compute to parse JSON in background isolate to prevent UI freeze
          final allData = await compute(parseJsonTableData, jsonStr);
          // Manual pagination
          final start = _currentPage * _itemsPerPage;
          if (start < allData.length) {
            final end = (start + _itemsPerPage < allData.length) ? start + _itemsPerPage : allData.length;
            data = allData.sublist(start, end);
          }
        }
      } else {
        // SQL Pagination
        data = await _storage.getTableData(
          _selectedTable!, 
          limit: _itemsPerPage, 
          offset: _currentPage * _itemsPerPage
        );
      }
    } catch (e) {
      data = [{'error': 'Load failed: $e'}];
    }

    if (mounted) {
      setState(() {
        _tableData = List.from(data); 
        _isLoading = false;
      });
    }
  }

  // ... (Keep existing _editRecord, _deleteRecord, _exportDatabase methods same as before)
  // To avoid massive diff, reusing existing methods but I need to include them in Replace Content
  // Actually, I'll just rewrite the widget build and `_itemsPerPage` and `_loadTableData` logic. 
  // Wait, I need to include the helper methods or the tool will delete them if strictly replacing.
  // I will use `replace_file_content` for the entire class block to update the logic and Widget Build.
  
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
    
    final limitController = TextEditingController(text: '50000');
    bool unlimited = false;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Export Database'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RadioListTile<bool>(
                  title: const Text('All Records'),
                  value: true,
                  groupValue: unlimited,
                  onChanged: (v) => setState(() => unlimited = v!),
                ),
                RadioListTile<bool>(
                  title: const Text('Limit Records'),
                  value: false,
                  groupValue: unlimited,
                  onChanged: (v) => setState(() => unlimited = v!),
                ),
                if (!unlimited)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: TextField(
                      controller: limitController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        suffixText: 'rows per table',
                        helperText: 'Max limit recommended: 50,000',
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context, {
                  'proceed': true,
                  'unlimited': unlimited,
                  'limit': limitController.text,
                }), 
                child: const Text('Export'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null || result['proceed'] != true) return;
    
    final isUnlimited = result['unlimited'] == true;
    final limitVal = int.tryParse(result['limit']) ?? 50000;
    final finalLimit = isUnlimited ? -1 : limitVal;

    // Pass limit via a special metadata item
    final configItem = ExportItem(
      itemId: 'config_limit', 
      name: finalLimit.toString(),
      isFolder: false,
    );

    await _exportQueue.addJob(
      'Database Export',
      [configItem], 
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
                    setState(() {
                      _selectedTable = v;
                      _currentPage = 0; // Reset page on table switch
                    });
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
        
        // Paginator
        if (_tables.isNotEmpty && !_isLoading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('Page ${_currentPage + 1}'),
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _currentPage > 0 
                      ? () {
                          setState(() => _currentPage--);
                          _loadTableData();
                        } 
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  // If we have full page, assume more exists
                  onPressed: _tableData.length == _itemsPerPage
                      ? () {
                          setState(() => _currentPage++);
                          _loadTableData();
                        }
                      : null,
                ),
              ],
            ),
          ),
        
        Expanded(
          child: _isLoading 
            ? const Center(child: CircularProgressIndicator()) 
            : RefreshIndicator(
            onRefresh: _loadTableData,
            child: _tableData.isEmpty
                ? Center(child: Text('No data', style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color)))
                : SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowColor: MaterialStateProperty.resolveWith((states) => Theme.of(context).cardColor),
                        dataRowColor: MaterialStateProperty.all(Theme.of(context).cardColor),
                        columnSpacing: 20,
                        // FIXED WIDTH OPTIMIZATION:
                        // Using fixed width columns significantly improves render performance by avoiding 
                        // multiple layout passes to calculate intrinsic width of massive content.
                         columns: [
                           ..._tableData.first.keys.map((k) => DataColumn(
                             label: SizedBox(
                               width: 150, 
                               child: Text(k, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).textTheme.titleSmall?.color))
                             )
                           )),
                           if (!_selectedTable!.startsWith('JSON: '))
                              const DataColumn(label: Text('Actions')),
                        ],
                        rows: _tableData.map((row) {
                          return DataRow(
                            cells: [
                              ...row.values.map((v) => DataCell(
                                SizedBox(
                                  width: 150,
                                  child: Text(
                                    (v?.toString() ?? '').length > 100 
                                        ? '${(v?.toString() ?? '').substring(0, 100)}...' 
                                        : (v?.toString() ?? ''), 
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
                                  ),
                                ),
                              )),
                              if (!_selectedTable!.startsWith('JSON: '))
                                DataCell(Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit, size: 18),
                                      onPressed: () => _editRecord(row),
                                      color: Theme.of(context).iconTheme.color,
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
