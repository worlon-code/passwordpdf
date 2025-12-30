import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import '../../../services/logging_service.dart';
import '../../../services/document_service.dart';
import '../../../models/document_item_model.dart';

/// Document Dashboard screen with folder management
class DocumentDashboardScreen extends StatefulWidget {
  const DocumentDashboardScreen({super.key});

  @override
  State<DocumentDashboardScreen> createState() => _DocumentDashboardScreenState();
}

class _DocumentDashboardScreenState extends State<DocumentDashboardScreen> {
  final LoggingService _log = LoggingService();
  final DocumentService _docService = DocumentService();
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _currentFolderId; // null = show all folders
  final Set<String> _selectedFileIds = {};

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() => _isLoading = true);
    try {
      await _docService.initialize();
      _log.info('DocumentDashboard', 'Service initialized');
    } catch (e) {
      _log.error('DocumentDashboard', 'Initialization error', e);
    } finally {
      setState(() {
        _isLoading = false;
        _isInitialized = true;
      });
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    String? errorText;
    
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // Prevent accidental dismissal
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(_currentFolderId == null ? 'Create Folder' : 'Create Subfolder'),
            content: TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Folder Name',
                hintText: 'Enter folder name',
                errorText: errorText,
              ),
              autofocus: true,
              onChanged: (value) {
                // Check if name exists
                final existingFolders = _currentFolderId == null
                    ? _docService.getRootFolders()
                    : _docService.getSubfolders(_currentFolderId!);
                
                final nameExists = existingFolders.any((f) => f.name.toLowerCase() == value.toLowerCase());
                
                setState(() {
                  if (value.isEmpty) {
                    errorText = 'Name cannot be empty';
                  } else if (nameExists) {
                    errorText = 'A folder with this name already exists';
                  } else {
                    errorText = null;
                  }
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: errorText == null && controller.text.isNotEmpty
                    ? () => Navigator.pop(context, true)
                    : null,
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    if (result == true && controller.text.isNotEmpty) {
      try {
        await _docService.createFolder(
          controller.text,
          parentId: _currentFolderId, // Will be null for root, or current folder ID
        );
        setState(() {});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Folder "${controller.text}" created')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _pickFiles({String? folderId}) async {
    try {
      setState(() => _isLoading = true);
      
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        int addedCount = 0;
        
        for (final file in result.files) {
          if (file.path != null) {
            final fileName = file.path!.split(RegExp(r'[/\\]')).last;
            
            // Check if adding to a folder
            if (folderId != null) {
              final filesInFolder = _docService.getFilesInFolder(folderId);
              final duplicate = filesInFolder.where((f) => f.name == fileName).firstOrNull;
              
              if (duplicate != null) {
                // Show duplicate dialog
                final action = await _showDuplicateDialog(fileName);
                
                // If user cancelled (null) or chose discard, skip this file
                if (action == null || action == 'discard') {
                  continue; // Skip this file
                } else if (action == 'rename') {
                  // Get new name
                  final newName = await _getNewFileName(fileName);
                  if (newName == null || newName.isEmpty) {
                    continue; // User cancelled rename
                  }
                  // Add with new name
                  await _docService.addFile(file.path!, folderId: folderId, customName: newName);
                  addedCount++;
                  continue;
                }
              }
            }
            
            await _docService.addFile(file.path!, folderId: folderId);
            addedCount++;
          }
        }
        
        setState(() {});
        
        if (mounted && addedCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added $addedCount file(s)')),
          );
        }
      }
    } catch (e) {
      _log.error('DocumentDashboard', 'Error picking files', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<String?> _showDuplicateDialog(String fileName) async {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('File Already Exists'),
        content: Text('A file named "$fileName" already exists in this folder.\n\nWhat would you like to do?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Skip This File'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'rename'),
            child: const Text('Rename & Add'),
          ),
        ],
      ),
    );
  }

  Future<String?> _getNewFileName(String originalName) async {
    final parts = originalName.split('.');
    final ext = parts.length > 1 ? parts.last : '';
    final nameWithoutExt = parts.length > 1 
        ? parts.sublist(0, parts.length - 1).join('.') 
        : originalName;
    
    final controller = TextEditingController(text: '$nameWithoutExt (1)');
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename File'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'New File Name',
                hintText: 'Enter new name (without extension)',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            if (ext.isNotEmpty)
              Text(
                'Extension: .$ext',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (result == true && controller.text.isNotEmpty) {
      return ext.isNotEmpty ? '${controller.text}.$ext' : controller.text;
    }
    return null;
  }

  Future<void> _exportFolderAsZip(DocumentItem folder) async {
    try {
      setState(() => _isLoading = true);
      
      // Get files in folder
      final files = _docService.getFilesInFolder(folder.id);
      
      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Folder is empty')),
          );
        }
        return;
      }

      // Create archive
      final archive = Archive();
      
      for (final fileItem in files) {
        if (fileItem.filePath != null) {
          final file = File(fileItem.filePath!);
          if (file.existsSync()) {
            final bytes = file.readAsBytesSync();
            final archiveFile = ArchiveFile(
              fileItem.name,
              bytes.length,
              bytes,
            );
            archive.addFile(archiveFile);
          }
        }
      }

      // Encode to ZIP
      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) {
        throw Exception('Failed to create ZIP');
      }

      // Save to Downloads directory
      Directory? downloadsDir;
      if (Platform.isAndroid) {
        downloadsDir = Directory('/storage/emulated/0/Download');
        if (!downloadsDir.existsSync()) {
          downloadsDir = await getExternalStorageDirectory();
        }
      } else {
        downloadsDir = await getDownloadsDirectory();
      }

      if (downloadsDir == null) {
        throw Exception('Could not access Downloads directory');
      }

      // Create unique filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipFileName = '${folder.name}_$timestamp.zip';
      final outputFile = File('${downloadsDir.path}/$zipFileName');
      
      await outputFile.writeAsBytes(zipData);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported to Downloads/$zipFileName'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
            ),
          ),
        );
      }
      _log.info('DocumentDashboard', 'Exported folder: ${folder.name} to ${outputFile.path}');
    } catch (e, stack) {
      _log.error('DocumentDashboard', 'Export error', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _toggleFileSelection(String fileId) {
    setState(() {
      if (_selectedFileIds.contains(fileId)) {
        _selectedFileIds.remove(fileId);
      } else {
        _selectedFileIds.add(fileId);
      }
    });
  }

  Future<void> _moveSelectedFiles() async {
    if (_selectedFileIds.isEmpty) return;

    final folders = _docService.getFolders();
    if (folders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No folders available. Create a folder first.')),
      );
      return;
    }

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move ${_selectedFileIds.length} file(s) to...'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: folders.map((folder) {
            return ListTile(
              leading: const Icon(Icons.folder),
              title: Text(folder.name),
              onTap: () => Navigator.pop(context, folder.id),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        await _docService.moveFilesToFolder(_selectedFileIds.toList(), result);
        setState(() {
          _selectedFileIds.clear();
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Files moved successfully')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _renameItem(DocumentItem item) async {
    final controller = TextEditingController(text: item.name);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Rename ${item.isFolder ? 'Folder' : 'File'}'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: item.isFolder ? 'Folder Name' : 'File Name',
            hintText: 'Enter new name',
          ),
          autofocus: true,
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (result == true && controller.text.isNotEmpty && controller.text != item.name) {
      try {
        await _docService.renameItem(item.id, controller.text);
        setState(() {});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Renamed to "${controller.text}"')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // If inside a folder, go back to parent instead of exiting app
        if (_currentFolderId != null) {
          setState(() {
            _currentFolderId = null;
            _selectedFileIds.clear();
          });
          return false; // Don't exit app
        }
        return true; // Allow exit app
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_currentFolderId == null ? 'Documents' : _getFolderName()),
          leading: _currentFolderId != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() {
                    _currentFolderId = null;
                    _selectedFileIds.clear();
                  }),
                )
              : null,
          actions: [
            if (_selectedFileIds.isNotEmpty) ...[
              IconButton(
                icon: Badge(
                  label: Text('${_selectedFileIds.length}'),
                  child: const Icon(Icons.drive_file_move),
                ),
                onPressed: _moveSelectedFiles,
                tooltip: 'Move files',
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _selectedFileIds.clear()),
                tooltip: 'Clear selection',
              ),
            ] else ...[
              if (_currentFolderId != null)
                IconButton(
                  icon: const Icon(Icons.file_upload),
                  onPressed: () {
                    final folder = _docService.getAllItems().firstWhere(
                          (item) => item.id == _currentFolderId,
                        );
                    _exportFolderAsZip(folder);
                  },
                  tooltip: 'Export as ZIP',
                ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'create_folder') {
                    _createFolder();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'create_folder',
                    child: Row(
                      children: [
                        Icon(Icons.create_new_folder),
                        SizedBox(width: 8),
                        Text('New Folder'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _isInitialized
                ? _buildContent()
                : const Center(child: Text('Initializing...')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _pickFiles(folderId: _currentFolderId),
          icon: const Icon(Icons.add),
          label: Text(_currentFolderId == null ? 'Add Files' : 'Add Files Here'),
        ),
      ),
    );
  }

  String _getFolderName() {
    final folder = _docService.getAllItems().firstWhere(
      (item) => item.id == _currentFolderId,
      orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.folder),
    );
    return folder.name;
  }

  Widget _buildContent() {
    if (_currentFolderId == null) {
      // Show root folders view
      final folders = _docService.getRootFolders();
      final unorganizedFiles = _docService.getUnorganizedFiles();

      if (folders.isEmpty && unorganizedFiles.isEmpty) {
        return _buildEmptyState();
      }

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (folders.isNotEmpty) ...[
            Text(
              'Folders',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...folders.map((folder) => _buildFolderCard(folder)),
            const SizedBox(height: 24),
          ],
          if (unorganizedFiles.isNotEmpty) ...[
            Text(
              'Unorganized Files',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...unorganizedFiles.map((file) => _buildFileCard(file)),
          ],
        ],
      );
    } else {
      // Show folder contents (subfolders + files)
      final subfolders = _docService.getSubfolders(_currentFolderId!);
      final files = _docService.getFilesInFolder(_currentFolderId!);
      
      if (subfolders.isEmpty && files.isEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.folder_open,
                size: 80,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
              ),
              const SizedBox(height: 16),
              const Text('Folder is empty'),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _createFolder,
                    icon: const Icon(Icons.create_new_folder),
                    label: const Text('New Folder'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () => _pickFiles(folderId: _currentFolderId),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Files'),
                  ),
                ],
              ),
            ],
          ),
        );
      }

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (subfolders.isNotEmpty) ...[
            Text(
              'Subfolders',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...subfolders.map((folder) => _buildFolderCard(folder)),
            const SizedBox(height: 24),
          ],
          if (files.isNotEmpty) ...[
            Text(
              'Files',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...files.map((file) => _buildFileCard(file)),
          ],
        ],
      );
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 120,
            color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
          ),
          const SizedBox(height: 24),
          Text(
            'No Documents Yet',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text('Create folders and add documents'),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _createFolder,
            icon: const Icon(Icons.create_new_folder),
            label: const Text('Create Your First Folder'),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderCard(DocumentItem folder) {
    final fileCount = _docService.getFilesInFolder(folder.id).length;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.folder, color: Colors.blue, size: 28),
        ),
        title: Text(folder.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('$fileCount ${fileCount == 1 ? 'file' : 'files'}'),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            if (value == 'rename') {
              await _renameItem(folder);
            } else if (value == 'export') {
              await _exportFolderAsZip(folder);
            } else if (value == 'delete') {
              await _docService.deleteItem(folder.id);
              setState(() {});
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'rename',
              child: Row(
                children: [
                  Icon(Icons.edit),
                  SizedBox(width: 8),
                  Text('Rename'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'export',
              child: Row(
                children: [
                  Icon(Icons.file_upload),
                  SizedBox(width: 8),
                  Text('Export as ZIP'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
        onTap: () => setState(() => _currentFolderId = folder.id),
      ),
    );
  }

  Widget _buildFileCard(DocumentItem file) {
    final isSelected = _selectedFileIds.contains(file.id);
    final fileExists = file.filePath != null && File(file.filePath!).existsSync();
    final fileSize = fileExists ? File(file.filePath!).lengthSync() : 0;
    final fileSizeKb = (fileSize / 1024).toStringAsFixed(1);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isSelected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: _getFileColor(file).withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(_getFileIcon(file), color: _getFileColor(file)),
        ),
        title: Text(
          file.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(fileExists ? '$fileSizeKb KB' : 'File not found'),
        trailing: IconButton(
          icon: Icon(isSelected ? Icons.check_circle : Icons.more_vert),
          color: isSelected ? Theme.of(context).colorScheme.primary : null,
          onPressed: () {
            final items = [
              if (!isSelected)
                const PopupMenuItem(
                  value: 'select',
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline),
                      SizedBox(width: 8),
                      Text('Select'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Delete', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ];

            if (isSelected) {
              _toggleFileSelection(file.id);
            } else {
              showMenu(
                context: context,
                position: const RelativeRect.fromLTRB(100, 100, 0, 0),
                items: [
                  const PopupMenuItem(
                    value: 'select',
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline),
                        SizedBox(width: 8),
                        Text('Select'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit),
                        SizedBox(width: 8),
                        Text('Rename'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Delete', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ).then((value) async {
                if (value == 'select') {
                  _toggleFileSelection(file.id);
                } else if (value == 'rename') {
                  await _renameItem(file);
                } else if (value == 'delete') {
                  await _docService.deleteItem(file.id);
                  setState(() {});
                }
              });
            }
          },
        ),
        onTap: () => _toggleFileSelection(file.id),
        onLongPress: () => _toggleFileSelection(file.id),
      ),
    );
  }

  IconData _getFileIcon(DocumentItem file) {
    if (file.isPdf) return Icons.picture_as_pdf;
    if (file.isDoc) return Icons.description;
    if (file.isExcel) return Icons.table_chart;
    return Icons.insert_drive_file;
  }

  Color _getFileColor(DocumentItem file) {
    if (file.isPdf) return Colors.red;
    if (file.isDoc) return Colors.blue;
    if (file.isExcel) return Colors.green;
    return Colors.grey;
  }
}
