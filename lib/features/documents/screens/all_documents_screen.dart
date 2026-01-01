import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:passwordpdf_manager/services/device_document_service.dart';
import 'package:passwordpdf_manager/services/document_service.dart';

import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

class AllDocumentsScreen extends StatefulWidget {
  const AllDocumentsScreen({super.key});

  @override
  State<AllDocumentsScreen> createState() => _AllDocumentsScreenState();
}

class _AllDocumentsScreenState extends State<AllDocumentsScreen> {
  final DeviceDocumentService _deviceService = DeviceDocumentService();
  
  List<FileSystemEntity> _allFiles = [];
  List<FileSystemEntity> _filteredFiles = [];
  bool _isLoading = true;
  String _selectedFilter = 'All'; // All, PDF, Word, Excel
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadDocuments();
  }

  Future<void> _loadDocuments() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final files = await _deviceService.scanDevice();
      if (mounted) {
        setState(() {
          _allFiles = files;
          _applyFilter();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _applyFilter() {
    setState(() {
      if (_selectedFilter == 'All') {
        _filteredFiles = List.from(_allFiles);
      } else {
        final extMap = {
          'PDF': ['.pdf'],
          'Word': ['.doc', '.docx'],
          'Excel': ['.xls', '.xlsx'],
        };
        final allowed = extMap[_selectedFilter] ?? [];
        _filteredFiles = _allFiles.where((f) {
          final ext = '.${f.path.split('.').last.toLowerCase()}';
          return allowed.contains(ext);
        }).toList();
      }
    });
  }

  void _onFilterChanged(String filter) {
    setState(() {
      _selectedFilter = filter;
      _applyFilter();
    });
  }

  Future<void> _openFile(FileSystemEntity file) async {
    await OpenFilex.open(file.path);
  }

  Future<void> _importFile(FileSystemEntity file) async {
    final docService = Provider.of<DocumentService>(context, listen: false);
    final fileName = file.path.split(Platform.pathSeparator).last;
    
    // Show generic loader
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );
    
    try {
      final result = await docService.importFile(file.path, fileName);
      
      // Close loader
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      
      if (result.success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported "$fileName" successfully')),
          );
        }
      } else if (result.isDuplicate) {
        if (mounted) {
          await _handleImportConflict(file.path, fileName, docService);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Import failed: ${result.errorMessage}')),
          );
        }
      }
    } catch (e) {
      // Close loader if open
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
         );
      }
    }
  }

  Future<void> _handleImportConflict(String filePath, String fileName, DocumentService docService) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('File Already Exists'),
        content: Text('A file named "$fileName" already exists in the app.\n\nWhat would you like to do?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'rename'),
            child: const Text('Rename'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, 'overwrite'),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );

    if (action == 'rename') {
      await _renameAndImport(filePath, fileName, docService);
    } else if (action == 'overwrite') {
      await _overwriteAndImport(filePath, fileName, docService);
    }
  }

  Future<void> _renameAndImport(String filePath, String originalName, DocumentService docService) async {
    // Simple rename: append _copy
    final parts = originalName.split('.');
    String newName;
    if (parts.length > 1) {
      final ext = parts.last;
      final name = parts.sublist(0, parts.length - 1).join('.');
      newName = '${name}_copy.$ext';
    } else {
      newName = '${originalName}_copy';
    }

    final controller = TextEditingController(text: newName);
    final userArray = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename File'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'New Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Import')),
        ],
      ),
    );
    
    if (userArray != null && userArray.isNotEmpty) {
      final res = await docService.importFile(filePath, userArray);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(res.success ? 'Imported as "$userArray"' : 'Import failed: ${res.errorMessage}')),
        );
      }
    }
  }

  Future<void> _overwriteAndImport(String filePath, String fileName, DocumentService docService) async {
    // Find existing item to delete
    try {
      final items = docService.getAllItems();
      final existing = items.firstWhere((i) => i.isFile && i.name.toLowerCase() == fileName.toLowerCase());
      
      await docService.deleteItem(existing.id);
      
      // Look for any other duplicates just in case? No, assuming 1
      
      // Now import
      final res = await docService.importFile(filePath, fileName);
       if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(res.success ? 'Overwritten "$fileName"' : 'Import failed: ${res.errorMessage}')),
        );
      }
    } catch (e) {
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to overwrite: $e')),
         );
      }
    }
  }


  Widget _buildFilterChip(String label) {
    final isSelected = _selectedFilter == label;
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => _onFilterChanged(label),
        checkmarkColor: isSelected ? Colors.white : null,
        labelStyle: TextStyle(
          color: isSelected ? Colors.white : Theme.of(context).colorScheme.onSurface,
        ),
        selectedColor: Theme.of(context).primaryColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Documents'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDocuments,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Bar
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                _buildFilterChip('All'),
                _buildFilterChip('PDF'),
                _buildFilterChip('Word'),
                _buildFilterChip('Excel'),
              ],
            ),
          ),
          // Content
          Expanded(
            child: _errorMessage.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_errorMessage, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadDocuments,
                          child: const Text('Grant Permission / Retry'),
                        ),
                      ],
                    ),
                  )
                : _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _loadDocuments,
                        child: _filteredFiles.isEmpty
                            ? ListView(
                                children: const [
                                  SizedBox(height: 100),
                                  Center(child: Text('No documents found')),
                                ],
                              )
                            : ListView.builder(
                                itemCount: _filteredFiles.length,
                                itemBuilder: (context, index) {
                                  final file = _filteredFiles[index];
                                  final name = file.path.split('/').last;
                                  final stat = file.statSync();
                                  final date = DateFormat('MMM d, y • H:mm').format(stat.modified);
                                  final size = (stat.size / 1024 / 1024).toStringAsFixed(2);
                                  
                                  IconData icon = Icons.insert_drive_file;
                                  Color iconColor = Colors.grey;
                                  if (name.endsWith('.pdf')) {
                                    icon = Icons.picture_as_pdf;
                                    iconColor = Colors.red;
                                  } else if (name.contains('.doc')) {
                                    icon = Icons.description;
                                    iconColor = Colors.blue;
                                  } else if (name.contains('.xls')) {
                                    icon = Icons.table_chart;
                                    iconColor = Colors.green;
                                  }

                                  return ListTile(
                                    leading: Icon(icon, color: iconColor, size: 32),
                                    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text('$date • $size MB'),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.download),
                                      onPressed: () => _importFile(file),
                                      tooltip: 'Import to App',
                                    ),
                                    onTap: () => _openFile(file),
                                  );
                                },
                              ),
                      ),
          ),
        ],
      ),
    );
  }
}
