import 'package:flutter/material.dart';
import 'package:passwordpdf_manager/models/document_item_model.dart';
import 'package:passwordpdf_manager/services/document_service.dart';
import 'package:passwordpdf_manager/features/documents/screens/folder_navigation_screen.dart';
import 'package:passwordpdf_manager/main.dart';

/// Screen to display all occurrences (locations) of a file
/// Shows all folder paths where files with the same content exist
class FileOccurrencesScreen extends StatefulWidget {
  final String fileName;
  final int fileSize;
  final String? contentHash;
  
  const FileOccurrencesScreen({
    super.key,
    required this.fileName,
    required this.fileSize,
    this.contentHash,
  });

  @override
  State<FileOccurrencesScreen> createState() => _FileOccurrencesScreenState();
}

class _FileOccurrencesScreenState extends State<FileOccurrencesScreen> {
  final DocumentService _docService = DocumentService();
  List<DocumentItem> _occurrences = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadOccurrences();
  }

  Future<void> _loadOccurrences() async {
    setState(() => _isLoading = true);
    
    await _docService.initialize();
    
    // Find all files with same name and size (content match)
    final allFiles = _docService.getAllItems().where((item) => !item.isFolder).toList();
    
    final matches = allFiles.where((file) {
      // Match by size only (to find renamed copies)
      return file.size == widget.fileSize && file.size > 0;
    }).toList();
    
    setState(() {
      _occurrences = matches;
      _isLoading = false;
    });
  }

  DocumentItem? _findFolder(String fileId) {
    // Find which folder contains this file ID
    try {
      final folders = _docService.getFolders();
      return folders.firstWhere((folder) => folder.fileIds.contains(fileId));
    } catch (_) {
      return null;
    }
  }

  String _getFolderPath(DocumentItem file) {
    final folder = _findFolder(file.id);
    return folder?.name ?? 'Unorganized Files';
  }

  void _navigateToFolder(DocumentItem file) {
    Navigator.pop(context); // Close this screen
    
    final folder = _findFolder(file.id);
    
    // Set pending folder for Dashboard to navigate to
    DashboardFolderNavigation.pendingFolderId = folder?.id;
    
    // Navigate to MainScreen with Documents tab (index 1)
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const MainScreen(initialIndex: 1),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Occurrences'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _occurrences.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.folder_off, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'No occurrences found',
                        style: TextStyle(color: Colors.grey[600], fontSize: 16),
                      ),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Row(
                        children: [
                          Icon(Icons.description, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.fileName,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Found in ${_occurrences.length} location${_occurrences.length != 1 ? 's' : ''}',
                                  style: TextStyle(color: Colors.grey[600], fontSize: 14),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // Occurrences list
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _occurrences.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final file = _occurrences[index];
                          final folderName = _getFolderPath(file);
                          
                          return ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.folder, color: Colors.blue),
                            ),
                            title: Text(
                              folderName,
                              style: const TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: Text(
                              'Modified: ${_formatDate(file.modifiedAt)}',
                              style: TextStyle(color: Colors.grey[600], fontSize: 12),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _navigateToFolder(file),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
  
  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    
    if (diff.inDays == 0) {
      return 'Today';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
