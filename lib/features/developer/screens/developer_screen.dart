import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/logging_service.dart';
import '../../../services/document_service.dart';
import '../../../services/storage_service.dart';
import '../../../models/document_item_model.dart';
import '../../../models/password_model.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Developer Screen with password protection
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final LoggingService _log = LoggingService();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
            Tab(icon: Icon(Icons.table_chart), text: 'Documents'),
            Tab(icon: Icon(Icons.key), text: 'Passwords'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _DebugLogsTab(),
          _DocumentsTableTab(),
          _PasswordsTableTab(),
        ],
      ),
    );
  }
}

/// Debug Logs Tab
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

  void _loadLogs() {
    setState(() => _logs = _log.logs);
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
                icon: const Icon(Icons.refresh),
                onPressed: _loadLogs,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  _log.clearLogs();
                  _loadLogs();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
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
      ],
    );
  }
}

/// Documents Table Tab
class _DocumentsTableTab extends StatefulWidget {
  const _DocumentsTableTab();

  @override
  State<_DocumentsTableTab> createState() => _DocumentsTableTabState();
}

class _DocumentsTableTabState extends State<_DocumentsTableTab> {
  final DocumentService _docService = DocumentService();
  List<DocumentItem> _items = [];
  int _limit = 50;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    await _docService.initialize();
    final all = _docService.getAllItems();
    setState(() {
      _items = _limit == -1 ? all : all.take(_limit).toList();
    });
  }

  Future<void> _exportToExcel() async {
    try {
      // Create CSV content
      final buffer = StringBuffer();
      buffer.writeln('ID,Name,Type,FilePath,CreatedAt');
      
      for (final item in _items) {
        buffer.writeln('"${item.id}","${item.name}","${item.type}","${item.filePath ?? ''}","${item.createdAt}"');
      }
      
      // Save to Developer folder
      final appDir = await getApplicationDocumentsDirectory();
      final devDir = Directory('${appDir.path}/Developer');
      if (!await devDir.exists()) {
        await devDir.create(recursive: true);
      }
      
      final file = File('${devDir.path}/documents_export_${DateTime.now().millisecondsSinceEpoch}.csv');
      await file.writeAsString(buffer.toString());
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to: ${file.path}')),
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

  Future<void> _deleteItem(DocumentItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Item'),
        content: Text('Are you sure you want to delete "${item.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    
    if (confirm == true) {
      await _docService.deleteItem(item.id);
      _loadItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              DropdownButton<int>(
                value: _limit,
                onChanged: (v) {
                  setState(() => _limit = v ?? 50);
                  _loadItems();
                },
                items: const [
                  DropdownMenuItem(value: 50, child: Text('50')),
                  DropdownMenuItem(value: 100, child: Text('100')),
                  DropdownMenuItem(value: 200, child: Text('200')),
                  DropdownMenuItem(value: 500, child: Text('500')),
                  DropdownMenuItem(value: -1, child: Text('All')),
                ],
              ),
              const SizedBox(width: 8),
              Text('${_items.length} items', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _loadItems),
              IconButton(icon: const Icon(Icons.download), onPressed: _exportToExcel),
            ],
          ),
        ),
        // Table
        Expanded(
          child: ListView.builder(
            itemCount: _items.length,
            itemBuilder: (context, index) {
              final item = _items[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ListTile(
                  dense: true,
                  leading: Icon(item.isFolder ? Icons.folder : Icons.insert_drive_file),
                  title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(item.id, style: const TextStyle(fontSize: 10)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deleteItem(item),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Passwords Table Tab
class _PasswordsTableTab extends StatefulWidget {
  const _PasswordsTableTab();

  @override
  State<_PasswordsTableTab> createState() => _PasswordsTableTabState();
}

class _PasswordsTableTabState extends State<_PasswordsTableTab> {
  final StorageService _storage = StorageService();
  List<PasswordModel> _passwords = [];
  int _limit = 50;

  @override
  void initState() {
    super.initState();
    _loadPasswords();
  }

  Future<void> _loadPasswords() async {
    final all = await _storage.getAllPasswords();
    setState(() {
      _passwords = _limit == -1 ? all : all.take(_limit).toList();
    });
  }

  Future<void> _exportToExcel() async {
    try {
      final buffer = StringBuffer();
      buffer.writeln('ID,KeyName,EncryptedValue');
      
      for (final p in _passwords) {
        buffer.writeln('"${p.id}","${p.keyName}","${p.encryptedValue}"');
      }
      
      final appDir = await getApplicationDocumentsDirectory();
      final devDir = Directory('${appDir.path}/Developer');
      if (!await devDir.exists()) {
        await devDir.create(recursive: true);
      }
      
      final file = File('${devDir.path}/passwords_export_${DateTime.now().millisecondsSinceEpoch}.csv');
      await file.writeAsString(buffer.toString());
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to: ${file.path}')),
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

  Future<void> _deletePassword(PasswordModel entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Password'),
        content: Text('Are you sure you want to delete "${entry.keyName}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    
    if (confirm == true && entry.id != null) {
      await _storage.deletePassword(entry.id!);
      _loadPasswords();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              DropdownButton<int>(
                value: _limit,
                onChanged: (v) {
                  setState(() => _limit = v ?? 50);
                  _loadPasswords();
                },
                items: const [
                  DropdownMenuItem(value: 50, child: Text('50')),
                  DropdownMenuItem(value: 100, child: Text('100')),
                  DropdownMenuItem(value: 200, child: Text('200')),
                  DropdownMenuItem(value: 500, child: Text('500')),
                  DropdownMenuItem(value: -1, child: Text('All')),
                ],
              ),
              const SizedBox(width: 8),
              Text('${_passwords.length} entries', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _loadPasswords),
              IconButton(icon: const Icon(Icons.download), onPressed: _exportToExcel),
            ],
          ),
        ),
        // Info banner
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.amber.shade100,
          child: const Row(
            children: [
              Icon(Icons.info_outline, size: 16),
              SizedBox(width: 8),
              Expanded(child: Text('Encryption key cannot be modified from this screen', style: TextStyle(fontSize: 12))),
            ],
          ),
        ),
        // Table
        Expanded(
          child: ListView.builder(
            itemCount: _passwords.length,
            itemBuilder: (context, index) {
              final p = _passwords[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.key),
                  title: Text(p.keyName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('ID: ${p.id ?? 'N/A'}', style: const TextStyle(fontSize: 10)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deletePassword(p),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
