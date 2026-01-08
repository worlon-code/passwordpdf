import 'package:flutter/material.dart';
import '../../../models/document_item_model.dart';
import '../../../services/document_service.dart';

class RemovedFilesScreen extends StatefulWidget {
  final DocumentService docService;
  final String? folderId;

  const RemovedFilesScreen({
    super.key, 
    required this.docService,
    this.folderId,
  });

  @override
  State<RemovedFilesScreen> createState() => _RemovedFilesScreenState();
}

class _RemovedFilesScreenState extends State<RemovedFilesScreen> {
  List<DocumentItem> _missingFiles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMissingFiles();
  }

  Future<void> _loadMissingFiles() async {
    setState(() => _isLoading = true);
    final allItems = widget.docService.getAllItems();
    final missing = allItems.where((item) => 
      item.missingOnDevice && 
      (widget.folderId == null || item.parentId == widget.folderId)
    ).toList();
    
    setState(() {
      _missingFiles = missing;
      _isLoading = false;
    });
  }

  Future<void> _deleteFile(String id) async {
    await widget.docService.deleteItem(id);
    _loadMissingFiles();
  }

  Future<void> _deleteAll() async {
    final isScoped = widget.folderId != null;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isScoped ? 'Clear Folder Missing?' : 'Clear All Missing?'),
        content: Text(
          isScoped 
            ? 'Permanently remove missing file entries from THIS folder?'
            : 'Permanently remove ALL missing file entries from the entire app?'
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true), 
            child: Text(isScoped ? 'Clear Folder' : 'Clear All', style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      for (final file in _missingFiles) {
        await widget.docService.deleteItem(file.id);
      }
      _loadMissingFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.folderId != null ? 'Removed Files (Folder)' : 'Removed Files (Global)';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_missingFiles.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: widget.folderId != null ? 'Clear Folder' : 'Clear All',
              onPressed: _deleteAll,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _missingFiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
                      const SizedBox(height: 16),
                      Text(
                        widget.folderId != null ? 'No missing files in this folder' : 'No missing files found',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _missingFiles.length,
                  itemBuilder: (context, index) {
                    final file = _missingFiles[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.red,
                          child: Icon(Icons.delete_forever, color: Colors.white),
                        ),
                        title: Text(file.name, style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey)),
                        subtitle: Text(file.sourcePath ?? 'Unknown path', style: const TextStyle(fontSize: 12)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => _deleteFile(file.id),
                          tooltip: 'Remove entry',
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
