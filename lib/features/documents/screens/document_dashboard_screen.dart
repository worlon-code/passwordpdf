import 'package:flutter/material.dart';
import 'package:passwordpdf_manager/features/documents/screens/document_search_delegate.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import '../../../services/logging_service.dart';
import '../../settings/services/settings_service.dart';
import '../../../services/document_service.dart';
import '../../../services/pdf_password_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/export_queue_service.dart';
import '../../../models/document_item_model.dart';
import '../../../models/password_model.dart';
import '../../../services/storage_service.dart';
import '../../../services/pdf_tools_service.dart';
import 'pdf_viewer_screen.dart';
import 'file_info_screen.dart';
import 'export_progress_screen.dart';
import '../widgets/password_selection_dialog.dart';
import '../../common/utils/file_conflict_resolver.dart';
import '../widgets/conflict_resolution_dialog.dart';
import '../../../models/conflict_resolution_model.dart';

/// Document Dashboard screen with folder management
class DocumentDashboardScreen extends StatefulWidget {
  const DocumentDashboardScreen({super.key});

  @override
  State<DocumentDashboardScreen> createState() => _DocumentDashboardScreenState();
}

class _DocumentDashboardScreenState extends State<DocumentDashboardScreen> {
  final LoggingService _log = LoggingService();
  final DocumentService _docService = DocumentService();
  final ExportQueueService _exportQueue = ExportQueueService();
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _currentFolderId; // null = show all folders
  final Set<String> _selectedFileIds = {};
  String _filterType = 'All'; // All, PDF, DOC, Excel
  
  bool get _isExporting => _exportQueue.jobs.any((j) => j.status == ExportStatus.inProgress);

  @override
  void initState() {
    super.initState();
    _exportQueue.onJobsUpdated = () {
      if (mounted) setState(() {});
    };
    _exportQueue.init(); // Load history
    _exportQueue.startWorker();
    _initialize();
  }
  
  @override
  void dispose() {
    _exportQueue.stopWorker();
    super.dispose();
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
      // Check mandatory settings
      if (mounted) _checkDownloadLocation();
    }
  }

  Future<void> _checkDownloadLocation() async {
    final settings = context.read<SettingsService>();
    if (settings.exportPath == null) {
      await Future.delayed(Duration.zero); // Ensure build complete
      if (!mounted) return;
      
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Setup Required'),
          content: const Text(
            'Please select a location where exported PDF files (unlocked, merged, etc.) will be saved.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Select Folder'),
            ),
          ],
        ),
      );

      if (!mounted) return;
      
      String? dir;
      while (dir == null) {
        dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Select Download Location',
        );
        
        if (dir == null) {
          if (!mounted) return;
          // Show retry dialog
          final retry = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('Location Required'),
              content: const Text('You must select a download location to continue.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false), // Exit/Cancel? No, mandatory.
                  child: const Text('Retry'), // Actually just closes logic loop
                ),
              ],
            ),
          );
          // Loop continues...
        }
      }
      
      await settings.setExportPath(dir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download location set to: $dir')),
        );
      }
      
      // Now check encryption key setup
      await _checkEncryptionKey();
    }
  }

  /// Check and prompt for encryption key setup (first-time only)
  Future<void> _checkEncryptionKey() async {
    final encryptionService = EncryptionService();
    final keyIsSet = await encryptionService.isKeySet();
    
    if (!keyIsSet) {
      if (!mounted) return;
      
      // Generate a default key
      String suggestedKey = encryptionService.generateRandomKey();
      final controller = TextEditingController(text: suggestedKey);
      
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Encryption Key Setup'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Set up your encryption key for secure password storage.'),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: 'Encryption Key',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Generate new key',
                      onPressed: () {
                        setState(() {
                          controller.text = encryptionService.generateRandomKey();
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Save this key securely! You cannot recover it later.',
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () async {
                  if (controller.text.isNotEmpty) {
                    await encryptionService.setEncryptionKey(controller.text);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                child: const Text('Save Key'),
              ),
            ],
          ),
        ),
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Encryption key set successfully!')),
        );
      }
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
        // 1. Identify Conflicts
        List<DocumentItem> existingFiles;
        if (folderId != null) {
          existingFiles = _docService.getFilesInFolder(folderId);
        } else {
          existingFiles = _docService.getUnorganizedFiles();
        }

        final conflictingItems = <ConflictItem>[];
        final validFiles = <PlatformFile>[];
        
        for (final file in result.files) {
          if (file.path == null) continue;
          
          final fileName = file.path!.split(RegExp(r'[/\\]')).last;
          final duplicate = existingFiles.where((f) => f.name.toLowerCase() == fileName.toLowerCase()).firstOrNull;
          
          if (duplicate != null) {
            conflictingItems.add(ConflictItem(
              sourceId: file.path!, // Use path as sourceId for import
              name: fileName,
              originalPath: file.path!,
              isFolder: false,
            ));
          }
          validFiles.add(file);
        }

        // 2. Resolve Conflicts
        final Map<String, ConflictAction> resolutions = {};
        if (conflictingItems.isNotEmpty) {
          final dialogResult = await showDialog<Map<String, ConflictAction>>(
            context: context,
            barrierDismissible: false,
            builder: (context) => ConflictResolutionDialog(conflicts: conflictingItems),
          );

          if (dialogResult == null) {
             // User cancelled entire operation
             return; 
          }
          resolutions.addAll(dialogResult);
        }

        // 3. Process Files
        int addedCount = 0;
        int skippedCount = 0;

        for (final file in validFiles) {
          if (file.path == null) continue;
          final filePath = file.path!;
          
          // Check resolution
          if (resolutions.containsKey(filePath)) {
            final action = resolutions[filePath]!;
            
            if (action.type == ConflictActionType.skip) {
              skippedCount++;
              continue;
            } else if (action.type == ConflictActionType.overwrite) {
               // Find and delete existing
               final fileName = filePath.split(RegExp(r'[/\\]')).last;
               final destFile = existingFiles.firstWhere((f) => f.name.toLowerCase() == fileName.toLowerCase());
               await _docService.deleteItem(destFile.id);
               
               // Then add normal
               await _docService.addFile(filePath, folderId: folderId);
               addedCount++;
            } else if (action.type == ConflictActionType.rename) {
               // Rename Source Logic
               final fileName = filePath.split(RegExp(r'[/\\]')).last;
               final parts = fileName.split('.');
               final ext = parts.length > 1 ? parts.last : '';
               final nameWithoutExt = parts.length > 1 
                  ? parts.sublist(0, parts.length - 1).join('.') 
                  : fileName;
              
               final suffix = action.renameSuffix ?? '_copy';
               final newName = ext.isNotEmpty ? '$nameWithoutExt$suffix.$ext' : '$nameWithoutExt$suffix';
               
               // Create temp copy with new name
               try {
                 final originalFile = File(filePath);
                 final directory = originalFile.parent;
                 final newFilePath = '${directory.path}/$newName';
                 
                 // Copy file to new path in cache/temp
                 await originalFile.copy(newFilePath);
                 
                 // Import the NEW file
                 await _docService.addFile(newFilePath, folderId: folderId);
                 addedCount++;
               } catch (e) {
                 _log.error('DocumentDashboard', 'Failed to rename import', e);
               }
            }
          } else {
            // No conflict, just add
            await _docService.addFile(filePath, folderId: folderId);
            addedCount++;
          }
        }
        
        setState(() {});
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added $addedCount file(s)${skippedCount > 0 ? ', skipped $skippedCount' : ''}')),
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

  /// Import entire folder with recursive structure
  Future<void> _importFolder() async {
    // Pick directory
    final dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Folder to Import',
    );
    
    if (dirPath == null) return;
    
    final sourceDir = Directory(dirPath);
    if (!sourceDir.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected folder does not exist'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    final folderName = sourceDir.path.split(Platform.pathSeparator).last;
    
    // Check if folder name already exists in current location
    final existingFolders = _currentFolderId != null 
        ? _docService.getSubfolders(_currentFolderId!)
        : _docService.getRootFolders();
    String finalFolderName = folderName;
    
    if (existingFolders.any((f) => f.name.toLowerCase() == folderName.toLowerCase())) {
      // Prompt for rename
      final newName = await _showFolderConflictDialog(folderName);
      if (newName == null) return; // Cancelled
      finalFolderName = newName;
    }

    // Show progress dialog
    int totalFiles = 0;
    int processedFiles = 0;
    
    // Count files first
    await for (final entity in sourceDir.list(recursive: true)) {
      if (entity is File) {
        final ext = entity.path.split('.').last.toLowerCase();
        if (['pdf', 'doc', 'docx', 'xls', 'xlsx'].contains(ext)) {
          totalFiles++;
        }
      }
    }

    if (totalFiles == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No supported files found in folder')),
        );
      }
      return;
    }

    // Show progress dialog
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Importing Folder'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: totalFiles > 0 ? processedFiles / totalFiles : 0),
                const SizedBox(height: 16),
                Text('Importing $processedFiles / $totalFiles files...'),
              ],
            ),
          );
        },
      ),
    );

    try {
      // Create root folder in current location
      final rootFolder = await _docService.createFolder(
        finalFolderName,
        parentId: _currentFolderId,
      );
      
      // Map of source path -> app folder ID
      final folderMap = <String, String>{sourceDir.path: rootFolder.id};
      
      // Process recursively
      await for (final entity in sourceDir.list(recursive: true)) {
        if (entity is Directory) {
          // Create corresponding folder
          final parentPath = entity.parent.path;
          final parentId = folderMap[parentPath];
          
          if (parentId != null) {
            final subName = entity.path.split(Platform.pathSeparator).last;
            final newFolder = await _docService.createFolder(subName, parentId: parentId);
            folderMap[entity.path] = newFolder.id;
          }
        } else if (entity is File) {
          final ext = entity.path.split('.').last.toLowerCase();
          if (['pdf', 'doc', 'docx', 'xls', 'xlsx'].contains(ext)) {
            final parentPath = entity.parent.path;
            final parentId = folderMap[parentPath];
            
            await _docService.addFile(entity.path, folderId: parentId);
            processedFiles++;
            
            // Update progress (rebuild dialog)
            if (mounted) {
              (context as Element).markNeedsBuild();
            }
          }
        }
      }

      // Close progress dialog
      if (mounted) {
        Navigator.pop(context);
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported $processedFiles files into "$finalFolderName"'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _log.error('DocumentDashboard', 'Folder import error', e);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Show dialog for folder name conflict
  Future<String?> _showFolderConflictDialog(String originalName) async {
    final controller = TextEditingController(text: '${originalName}_imported');
    
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Folder Already Exists'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A folder named "$originalName" already exists.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'New folder name',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Rename & Import'),
          ),
        ],
      ),
    );
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

  // Helper to build ExportItems from folder
  List<ExportItem> _buildExportItemsFromFolder(String folderId) {
    final List<ExportItem> items = [];
    
    // Add files in this folder
    final files = _docService.getFilesInFolder(folderId);
    for (final file in files) {
      if (file.filePath != null) {
        items.add(ExportItem(
          itemId: file.id,
          name: file.name,
          filePath: file.filePath,
          isFolder: false,
        ));
      }
    }
    
    // Process subfolders
    final subfolders = _docService.getSubfolders(folderId);
    for (final folder in subfolders) {
      items.add(ExportItem(
        itemId: folder.id,
        name: folder.name,
        isFolder: true,
        children: _buildExportItemsFromFolder(folder.id),
      ));
    }
    
    return items;
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
    String? password;
    bool encrypt = false;
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Export "${folder.name}"?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Do you want to export this folder as a ZIP file?'),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: encrypt,
                        onChanged: (val) => setState(() => encrypt = val ?? false),
                      ),
                      const Text('Protect with Password'),
                    ],
                  ),
                  if (encrypt)
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'ZIP Password',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      obscureText: true,
                      onChanged: (val) => password = val,
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  onPressed: () => Navigator.pop(context, true),
                  label: const Text('Export'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirm != true) return;

    // Use password only if encrypt checked
    final zipPassword = encrypt ? password : null;

    // Check configuration
    final settings = context.read<SettingsService>();
    final exportPath = settings.exportPath;
    
    if (exportPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export path not configured. Please check settings.')),
        );
      }
      return;
    }

    try {
      // Build export items
      final items = _buildExportItemsFromFolder(folder.id);
      
      if (items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Folder is empty')),
          );
        }
        return;
      }

      // Add to queue
      _exportQueue.addJob(folder.name, items, exportDir: exportPath, zipPassword: zipPassword);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Export started in background'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ExportProgressScreen(),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      _log.error('DocumentDashboard', 'Queue error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start export: $e')),
        );
      }
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

    final allFolders = _docService.getFolders();
    if (allFolders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No folders available. Create a folder first.')),
      );
      return;
    }

    // 1. Select Destination
    final destinationId = await showDialog<String>(
      context: context,
      builder: (context) => _MoveDialogWithTree(
        docService: _docService,
        fileCount: _selectedFileIds.length,
        excludedFolderIds: _selectedFileIds.where((id) {
          final item = _docService.getAllItems().firstWhere(
            (e) => e.id == id, 
            orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.file)
          );
          return item.isFolder;
        }).toSet(),
      ),
    );

    if (destinationId == null) return; // Cancelled

    try {
      // 2. Pre-calculate Conflicts
      List<DocumentItem> destinationFiles = [];
      if (destinationId != '__ROOT__') {
        destinationFiles = _docService.getFilesInFolder(destinationId);
      } else {
        destinationFiles = _docService.getUnorganizedFiles();
      }

      final filesToMove = _selectedFileIds.map((id) => 
        _docService.getAllItems().firstWhere((item) => item.id == id)
      ).toList();
      
      final conflictingItems = <ConflictItem>[];
      final Map<String, ConflictAction> resolutions = {};

      for (final file in filesToMove) {
        // Skip folders for name conflict check for now (or implement if needed)
        if (file.isFolder) continue; 

        final duplicate = destinationFiles.where((f) => f.name.toLowerCase() == file.name.toLowerCase()).firstOrNull;
        if (duplicate != null) {
          conflictingItems.add(ConflictItem(
            sourceId: file.id,
            name: file.name,
            originalPath: file.filePath ?? '',
            isFolder: false,
          ));
        }
      }

      // 3. Resolve Conflicts (if any)
      if (conflictingItems.isNotEmpty) {
        final result = await showDialog<Map<String, ConflictAction>>(
          context: context,
          barrierDismissible: false,
          builder: (context) => ConflictResolutionDialog(conflicts: conflictingItems),
        );

        if (result == null) return; // User cancelled operation
        resolutions.addAll(result);
      }

      // 4. Execute Moves
      int movedCount = 0;
      int skippedCount = 0;

      for (final file in filesToMove) {
        // Check if skipped
        if (resolutions.containsKey(file.id)) {
          final action = resolutions[file.id]!;
          if (action.type == ConflictActionType.skip) {
            skippedCount++;
            continue;
          }
        }

        // Apply Resolution first
        String currentFileId = file.id;
        
        if (resolutions.containsKey(file.id)) {
          final action = resolutions[file.id]!;
          
          if (action.type == ConflictActionType.rename) {
            // Rename Source
            final parts = file.name.split('.');
            final ext = parts.length > 1 ? parts.last : '';
            final nameWithoutExt = parts.length > 1 
                ? parts.sublist(0, parts.length - 1).join('.') 
                : file.name;
            
            final suffix = action.renameSuffix ?? '_copy';
            final newName = ext.isNotEmpty ? '$nameWithoutExt$suffix.$ext' : '$nameWithoutExt$suffix';
            
            await _docService.renameItem(file.id, newName);
            // currentFileId remains same, but name changed in DB
          } else if (action.type == ConflictActionType.overwrite) {
             // Delete Destination File
             final destFile = destinationFiles.firstWhere((f) => f.name.toLowerCase() == file.name.toLowerCase());
             await _docService.deleteItem(destFile.id); // This deletes the destination entry
          }
        }

        // Perform Move
        if (file.isFolder) {
           if (destinationId == '__ROOT__') {
             await _docService.moveFolderToRoot(currentFileId);
           } else {
             await _docService.moveFolderToFolder(currentFileId, destinationId);
           }
        } else {
           if (destinationId == '__ROOT__') {
             await _docService.moveFilesToRoot([currentFileId]);
           } else {
             await _docService.moveFilesToFolder([currentFileId], destinationId);
           }
        }
        movedCount++;
      }
      
      setState(() {
        _selectedFileIds.clear();
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved $movedCount item(s)${skippedCount > 0 ? ', skipped $skippedCount' : ''}'),
          ),
        );
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error moving files: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _shareSelectedFiles() async {
    if (_selectedFileIds.isEmpty) return;

    // Double check: if any folder is selected, abort (button should be disabled anyway)
    final allItems = _docService.getAllItems();
    final hasFolders = _selectedFileIds.any((id) {
       final item = allItems.firstWhere((e) => e.id == id, orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.file));
       return item.isFolder;
    });
    
    if (hasFolders) {
       ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('Folders cannot be shared directly. Please use "Export" to zip them first.')),
       );
       return;
    }

    try {
      final filesToShare = <XFile>[];
      for (final id in _selectedFileIds) {
        final item = allItems.firstWhere((e) => e.id == id, orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.file));
        if (item.filePath != null) {
          // Verify file exists
          final file = File(item.filePath!);
          if (await file.exists()) {
             filesToShare.add(XFile(item.filePath!));
          }
        }
      }

      if (filesToShare.isNotEmpty) {
        await Share.shareXFiles(filesToShare, text: 'Shared from Password Manager');
        // Clear selection after sharing
        setState(() {
          _selectedFileIds.clear();
        });
      } else {
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('No shareable files selected')),
           );
        }
      }
    } catch (e) {
      _log.error('DocumentDashboard', 'Share error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e'), backgroundColor: Colors.red),
        );
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

  Future<void> _openDocument(DocumentItem item) async {
    if (!item.isPdf) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot open this file type')),
        );
      }
      return;
    }
    
    final filePath = item.filePath; // Use actual file path, not ID
    if (filePath == null) {
       if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File path is missing')),
        );
      }
      return;
    }
    
    final fileName = item.name;
    
    // Check existence explicitly
    final file = File(filePath);
    if (!file.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File not found: $filePath'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    final pdfService = PdfPasswordService();
    final tools = PdfToolsService();
    
    // 1. Check if specific password stored (Association)
    final storedPassword = await pdfService.getPasswordForDocument(filePath);
    if (storedPassword != null) {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PdfViewerScreen(
              filePath: filePath,
              fileName: fileName,
              password: storedPassword,
            ),
          ),
        );
      }
      return;
    }

    // 2. Check if file is actually protected
    // Display loading
    if (!mounted) return;
    
    // Track if dialog is open
    bool dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );
    
    try {
      _log.debug('SmartOpen', 'Checking protection for $filePath');
      final isProtected = await tools.isProtected(filePath);
      _log.debug('SmartOpen', 'File protected: $isProtected');
      
      if (!isProtected) {
        if (dialogOpen) {
          Navigator.pop(context); // Close loading
          dialogOpen = false;
        }
        
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PdfViewerScreen(
                filePath: filePath,
                fileName: fileName,
                password: '',
                onSuccess: () => pdfService.saveDocumentPassword(filePath, ''),
              ),
            ),
          );
        }
        return;
      }
      
      // 3. Try saved passwords
      _log.debug('SmartOpen', 'Fetching saved passwords');
      final storage = StorageService();
      final passwords = await storage.getAllPasswords();
      final encryption = context.read<EncryptionService>();
      
      _log.debug('SmartOpen', 'Found ${passwords.length} saved passwords');
      
      String? foundPassword;
      String? foundKeyName;
      
      for (final p in passwords) {
        final decrypted = await encryption.decrypt(p.encryptedValue);
        if (decrypted != null) {
          _log.debug('SmartOpen', 'Trying password: ${p.keyName}');
          if (await tools.verifyPassword(filePath, decrypted)) {
            _log.debug('SmartOpen', 'Password matched!');
            foundPassword = decrypted;
            foundKeyName = p.keyName;
            break;
          }
        }
      }
      
      if (dialogOpen) {
        Navigator.pop(context); // Close loading
        dialogOpen = false;
      }
      
      if (foundPassword != null) {
        // Success! Save association and open
        await pdfService.saveDocumentPassword(filePath, foundPassword);
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(content: Text('Unlocked with saved password: ${foundKeyName ?? "Unknown"}'), backgroundColor: Colors.green),
           );
           Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PdfViewerScreen(
                filePath: filePath,
                fileName: fileName,
                password: foundPassword,
              ),
            ),
          );
        }
        return;
      }
      
    } catch (e, stack) {
      _log.error('SmartOpen', 'Error opening document: $e', e, stack);
      if (dialogOpen && mounted) {
        Navigator.pop(context);
        dialogOpen = false;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening file: $e'), backgroundColor: Colors.red),
        );
      }
      return; 
    }
    
    // Ensure dialog close if not closed above
    if (dialogOpen && mounted) {
      Navigator.pop(context);
      dialogOpen = false;
    }
    
    // 4. Fallback to manual input with "Add to list" option
    if (mounted) {
      await _showSmartPasswordDialogAndOpen(filePath, fileName);
    }
  }

  Future<void> _showSmartPasswordDialogAndOpen(String filePath, String fileName) async {
    final tools = PdfToolsService();
    final pdfService = PdfPasswordService();
    final storage = StorageService();
    final encryption = context.read<EncryptionService>();
    
    String password = '';
    bool saveToList = false;
    String saveName = fileName;
    String? errorMessage;
    
    bool obscurePassword = true;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Password Required'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('This file is encrypted. Please enter the password.'),
                    const SizedBox(height: 16),
                    TextField(
                      autofocus: true,
                      obscureText: obscurePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        errorText: errorMessage,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(obscurePassword ? Icons.visibility : Icons.visibility_off),
                          onPressed: () {
                            setState(() {
                              obscurePassword = !obscurePassword;
                            });
                          },
                        ),
                      ),
                      onChanged: (val) {
                        password = val;
                        if (errorMessage != null) setState(() => errorMessage = null);
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Checkbox(
                          value: saveToList,
                          onChanged: (val) => setState(() => saveToList = val ?? false),
                        ),
                        const Expanded(child: Text('Add to My Passwords list?')),
                      ],
                    ),
                    if (saveToList)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: TextField(
                          controller: TextEditingController(text: saveName),
                          decoration: const InputDecoration(
                            labelText: 'Password Name (e.g. Bank Statement)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (val) => saveName = val,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (password.isEmpty) return;
                    
                    // Verify logic
                    final isValid = await tools.verifyPassword(filePath, password);
                    if (!isValid) {
                      setState(() => errorMessage = 'Incorrect password');
                      return;
                    }
                    
                    // Valid! Handle saving to list if requested
                    if (saveToList && saveName.isNotEmpty) {
                       // Check duplicates
                       if (await storage.passwordKeyExists(saveName)) {
                         setState(() => errorMessage = 'Name "$saveName" already exists');
                         return;
                       }
                       
                       // Encrypt and save to list
                       final encrypted = await encryption.encrypt(password);
                       if (encrypted != null) {
                         final newPassword = PasswordModel(
                           keyName: saveName,
                           encryptedValue: encrypted,
                           createdAt: DateTime.now(),
                         );
                         await storage.insertPassword(newPassword);
                       }
                    }
                    
                    Navigator.pop(context, true);
                  },
                  child: const Text('Open'),
                ),
              ],
            );
          },
        );
      },
    ).then((result) async {
      if (result == true) {
        // Password was valid (checked in dialog)
        await pdfService.saveDocumentPassword(filePath, password);
        
        if (mounted) {
           Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PdfViewerScreen(
                filePath: filePath,
                fileName: fileName,
                password: password,
              ),
            ),
          );
        }
      }
    });
  }

  void _navigateUp() {
    if (_currentFolderId != null) {
      final currentFolder = _docService.getAllItems().firstWhere(
        (item) => item.id == _currentFolderId,
        orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.folder),
      );
      
      setState(() {
        _currentFolderId = currentFolder.parentId;
        _selectedFileIds.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentFolderId == null && _selectedFileIds.isEmpty,
      onPopInvoked: (didPop) {
        if (!didPop) {
          // If in move/selection mode, clear selection first
          if (_selectedFileIds.isNotEmpty) {
            setState(() {
              _selectedFileIds.clear();
            });
          } 
          // If inside a folder (and not in selection mode), go back to parent
          else if (_currentFolderId != null) {
            _navigateUp();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selectedFileIds.isNotEmpty 
              ? '${_selectedFileIds.length} Selected'
              : (_currentFolderId == null ? 'Documents' : _getFolderName())),
          leading: _selectedFileIds.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _selectedFileIds.clear();
                    });
                  },
                )
              : (_currentFolderId != null
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _navigateUp,
                    )
                  : null),
          actions: [
            if (_selectedFileIds.isNotEmpty) ...[
               IconButton(
                 icon: const Icon(Icons.share),
                 onPressed: _selectedFileIds.any((id) {
                     final item = _docService.getAllItems().firstWhere(
                       (e) => e.id == id, 
                       orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.file)
                     );
                     return item.isFolder;
                   }) ? null : _shareSelectedFiles,
                 tooltip: 'Share (Files only)',
               ),
               IconButton(
                 icon: Badge(
                    label: Text('${_selectedFileIds.length}'),
                    child: const Icon(Icons.drive_file_move),
                  ),
                 onPressed: _moveSelectedFiles,
                 tooltip: 'Move files',
               ),
               IconButton(
                 icon: const Icon(Icons.delete),
                 onPressed: _deleteSelectedItems,
                 tooltip: 'Delete selected',
               ),
               IconButton(
                   icon: const Icon(Icons.archive),
                   onPressed: _exportSelectedItems,
                   tooltip: 'Export selected as ZIP',
               ),
               IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _selectedFileIds.clear()),
                  tooltip: 'Clear selection',
               ),
            ] else ...[
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () async {
                  final result = await showSearch(
                    context: context,
                    delegate: DocumentSearchDelegate(_docService),
                  );
                  if (result != null) {
                    if (result.isFolder) {
                      setState(() => _currentFolderId = result.id);
                    } else {
                      // It's a file
                      if (result.filePath != null) {
                        _openDocument(result);
                      }
                    }
                  }
                },
                tooltip: 'Search',
              ),
              if (_currentFolderId != null)
                IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () {
                    final folder = _docService.getAllItems().firstWhere(
                          (item) => item.id == _currentFolderId,
                        );
                    _exportFolderAsZip(folder);
                  },
                  tooltip: 'Export as ZIP',
                ),
              // Export progress button (always visible)
              IconButton(
                icon: Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(_isExporting ? Icons.sync : Icons.list_alt),
                    if (_exportQueue.inProgressCount > 0)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${_exportQueue.inProgressCount}',
                            style: const TextStyle(color: Colors.white, fontSize: 10),
                          ),
                        ),
                      ),
                  ],
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ExportProgressScreen(),
                    ),
                  );
                },
                tooltip: 'Export Progress',
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'create_folder') {
                    _createFolder();
                  } else if (value == 'import_folder') {
                    _importFolder();
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
                  const PopupMenuItem(
                    value: 'import_folder',
                    child: Row(
                      children: [
                        Icon(Icons.drive_folder_upload),
                        SizedBox(width: 8),
                        Text('Import Folder'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
          bottom: _isExporting 
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(4), 
                  child: LinearProgressIndicator(),
                ) 
              : null,
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _isInitialized
            ? AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return FadeTransition(opacity: animation, child: child);
                },
                child: KeyedSubtree(
                  key: ValueKey(_currentFolderId ?? 'root'),
                  child: _buildContent(),
                ),
              )
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
      var folders = _docService.getRootFolders();
      var unorganizedFiles = _docService.getUnorganizedFiles();
      
      // Apply file type filter
      folders = _applyFolderFilter(folders);
      unorganizedFiles = _applyFileFilter(unorganizedFiles);

      if (folders.isEmpty && unorganizedFiles.isEmpty && _filterType == 'All') {
        return _buildEmptyState();
      }

      return Column(
        children: [
          // Filter bar
          _buildFilterBar(),
          // Content
          Expanded(
            child: ListView(
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
                ] else if (_filterType != 'All') ...[
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('No $_filterType files found'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    } else {
      // Show folder contents (subfolders + files)
      var subfolders = _docService.getSubfolders(_currentFolderId!);
      var files = _docService.getFilesInFolder(_currentFolderId!);
      
      // Apply filters
      subfolders = _applyFolderFilter(subfolders);
      files = _applyFileFilter(files);
      
      if (subfolders.isEmpty && files.isEmpty) {
        return Column(
          children: [
            _buildFilterBar(),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.folder_open,
                      size: 80,
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                    ),
                    const SizedBox(height: 16),
                    Text(_filterType == 'All' ? 'Folder is empty' : 'No $_filterType files found'),
                    const SizedBox(height: 8),
                    if (_filterType == 'All')
                      const Text('Use the button below to add files or create folders'),
                  ],
                ),
              ),
            ),
          ],
        );
      }

      return Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...subfolders.map((folder) => _buildFolderCard(folder)),
                ...files.map((file) => _buildFileCard(file)),
              ],
            ),
          ),
        ],
      );
    }
  }

  /// Build filter bar with file type chips showing counts
  Widget _buildFilterBar() {
    final filters = ['All', 'PDF', 'DOC', 'Excel'];
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: filters.map((type) {
            final isSelected = _filterType == type;
            final counts = _getFilterCounts(type);
            final label = '$type (${counts['files']}f, ${counts['folders']}d)';
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(label),
                selected: isSelected,
                onSelected: (selected) {
                  setState(() => _filterType = type);
                },
                selectedColor: Theme.of(context).colorScheme.primaryContainer,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// Get file and folder counts for a given filter type
  Map<String, int> _getFilterCounts(String filterType) {
    List<DocumentItem> files;
    List<DocumentItem> folders;
    
    if (_currentFolderId == null) {
      files = _docService.getUnorganizedFiles();
      folders = _docService.getRootFolders();
    } else {
      files = _docService.getFilesInFolder(_currentFolderId!);
      folders = _docService.getSubfolders(_currentFolderId!);
    }
    
    // Apply filter
    final oldFilter = _filterType;
    _filterType = filterType;
    final filteredFiles = _applyFileFilter(files);
    final filteredFolders = _applyFolderFilter(folders);
    _filterType = oldFilter;
    
    return {
      'files': filteredFiles.length,
      'folders': filteredFolders.length,
    };
  }

  /// Apply file type filter to list of files
  List<DocumentItem> _applyFileFilter(List<DocumentItem> files) {
    if (_filterType == 'All') return files;
    
    return files.where((file) {
      final ext = file.name.toLowerCase();
      switch (_filterType) {
        case 'PDF':
          return ext.endsWith('.pdf');
        case 'DOC':
          return ext.endsWith('.doc') || ext.endsWith('.docx');
        case 'Excel':
          return ext.endsWith('.xls') || ext.endsWith('.xlsx');
        default:
          return true;
      }
    }).toList();
  }

  /// Check if a folder contains files matching the current filter (recursively)
  bool _folderContainsMatchingFiles(String folderId) {
    if (_filterType == 'All') return true;
    
    // Check direct files
    final files = _docService.getFilesInFolder(folderId);
    final matchingFiles = _applyFileFilter(files);
    if (matchingFiles.isNotEmpty) return true;
    
    // Check subfolders recursively
    final subfolders = _docService.getSubfolders(folderId);
    for (final subfolder in subfolders) {
      if (_folderContainsMatchingFiles(subfolder.id)) return true;
    }
    
    return false;
  }

  /// Filter folders to only show those containing matching files
  List<DocumentItem> _applyFolderFilter(List<DocumentItem> folders) {
    if (_filterType == 'All') return folders;
    return folders.where((folder) => _folderContainsMatchingFiles(folder.id)).toList();
  }

  /// Build subtitle showing file and folder counts
  String _buildFolderSubtitle(String folderId) {
    final allFiles = _docService.getFilesInFolder(folderId);
    final fileCount = _applyFileFilter(allFiles).length;
    final subfolderCount = _docService.getSubfolders(folderId).length;
    
    final filePart = '$fileCount ${fileCount == 1 ? 'file' : 'files'}';
    final folderPart = '$subfolderCount ${subfolderCount == 1 ? 'folder' : 'folders'}';
    
    return '$filePart, $folderPart';
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
    // Calculate file count based on filter
    final allFiles = _docService.getFilesInFolder(folder.id);
    final fileCount = _applyFileFilter(allFiles).length;
    
    final isSelected = _selectedFileIds.contains(folder.id);
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isSelected ? Colors.blue.withOpacity(0.1) : null,
      child: InkWell(
        onLongPress: () {
          setState(() {
            if (isSelected) {
              _selectedFileIds.remove(folder.id);
            } else {
              _selectedFileIds.add(folder.id);
            }
          });
        },
        onTap: () {
          if (_selectedFileIds.isNotEmpty) {
            setState(() {
              if (isSelected) {
                _selectedFileIds.remove(folder.id);
              } else {
                _selectedFileIds.add(folder.id);
              }
            });
          } else {
            // Check if folder contains any items before opening? 
            // No, always allow opening folder
            setState(() {
              _currentFolderId = folder.id;
              _selectedFileIds.clear(); // Clear selection just in case
            });
          }
        },
        child: ListTile(
          leading: Stack(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.folder, color: Colors.blue, size: 28),
              ),
              if (isSelected)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check, size: 12, color: Colors.white),
                  ),
                ),
            ],
          ),
        title: Text(folder.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(_buildFolderSubtitle(folder.id)),
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
                  Icon(Icons.folder_zip, color: Colors.grey),
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
        onTap: () {
            if (_selectedFileIds.isNotEmpty) {
              setState(() {
                if (isSelected) {
                  _selectedFileIds.remove(folder.id);
                } else {
                  _selectedFileIds.add(folder.id);
                }
              });
            } else {
              setState(() => _currentFolderId = folder.id);
            }
          },
        ),
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
        trailing: isSelected
            ? IconButton(
                icon: const Icon(Icons.check_circle),
                color: Theme.of(context).colorScheme.primary,
                onPressed: () => _toggleFileSelection(file.id),
              )
            : PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) async {
                  if (value == 'info') {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => FileInfoScreen(file: file),
                      ),
                    );
                    if (result == 'open' && file.isPdf && mounted) {
                      // Smart PDF password handling
                      await _openDocument(file);
                    }
                  } else if (value == 'select') {
                    _toggleFileSelection(file.id);
                  } else if (value == 'rename') {
                    await _renameItem(file);
                  } else if (value == 'delete') {
                    await _docService.deleteItem(file.id);
                    setState(() {});
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'info',
                    child: Row(
                      children: [
                        Icon(Icons.info_outline),
                        SizedBox(width: 8),
                        Text('File Info'),
                      ],
                    ),
                  ),
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
              ),
        onTap: () async {
          if (_selectedFileIds.isNotEmpty) {
            // In selection/move mode - toggle selection
            setState(() {
              if (isSelected) {
                _selectedFileIds.remove(file.id);
              } else {
                _selectedFileIds.add(file.id);
              }
            });
          } else if (file.isPdf) {
            // Smart PDF password handling
            await _openDocument(file);
          }
          // For non-PDF files when not in move mode - do nothing on tap
        },
        onLongPress: () {
          // Long-press enters move mode by selecting this file
          setState(() {
            _selectedFileIds.add(file.id);
          });
          // Show snackbar to indicate move mode
          if (_selectedFileIds.length == 1) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Tap more files to select, then tap Move icon'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
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


  Future<void> _deleteSelectedItems() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Selected Items?'),
        content: Text('Are you sure you want to delete ${_selectedFileIds.length} items? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    for (final id in _selectedFileIds) {
      await _docService.deleteItem(id);
    }
    
    setState(() {
      _selectedFileIds.clear();
    });
  }

  Future<void> _exportSelectedItems() async {
    String? password;
    bool encrypt = false;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Export Selected Items'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Export ${_selectedFileIds.length} items as a ZIP file?'),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: encrypt,
                        onChanged: (val) => setState(() => encrypt = val ?? false),
                      ),
                      const Text('Protect with Password'),
                    ],
                  ),
                  if (encrypt)
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'ZIP Password',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      obscureText: true,
                      onChanged: (val) => password = val,
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.archive),
                  onPressed: () => Navigator.pop(context, true),
                  label: const Text('Export'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirm != true) return;

    // Use password only if encrypt checked
    final zipPassword = encrypt ? password : null;

    // Check configuration
    final settings = context.read<SettingsService>();
    final exportPath = settings.exportPath;
    
    if (exportPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export path not configured. Please check settings.')),
        );
      }
      return;
    }

    // Copy selected IDs before clearing selection
    final idsToExport = Set<String>.from(_selectedFileIds);

    setState(() {
      _selectedFileIds.clear(); // Clear selection immediately so user can continue working
    });
    
    try {
      final List<ExportItem> exportItems = [];
      final allItems = _docService.getAllItems();
      
      for (final id in idsToExport) {
        try {
          final item = allItems.firstWhere((e) => e.id == id);
          
          if (item.isFolder) {
            exportItems.add(ExportItem(
              itemId: item.id,
              name: item.name,
              isFolder: true,
              children: _buildExportItemsFromFolder(item.id),
            ));
          } else if (item.filePath != null) {
            exportItems.add(ExportItem(
              itemId: item.id,
              name: item.name,
              filePath: item.filePath,
              isFolder: false,
            ));
          }
        } catch (e) {
          // Item might not exist, skip
        }
      }

      if (exportItems.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No valid items to export')),
          );
        }
        return;
      }

      // Add to queue
      _exportQueue.addJob('Bulk Export', exportItems, exportDir: exportPath, zipPassword: zipPassword);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Export started in background'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ExportProgressScreen(),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      _log.error('DocumentDashboard', 'Queue error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start export: $e')),
        );
      }
    }
  }


}

// Stateful tree widget for move dialog
class _MoveDialogWithTree extends StatefulWidget {
  final DocumentService docService;
  final int fileCount;
  final Set<String> excludedFolderIds;
  
  const _MoveDialogWithTree({
    required this.docService,
    required this.fileCount,
    this.excludedFolderIds = const {},
  });

  @override
  State<_MoveDialogWithTree> createState() => _MoveDialogWithTreeState();
}

class _MoveDialogWithTreeState extends State<_MoveDialogWithTree> {
  final Set<String> _expandedFolders = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.drive_file_move,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Move Files'),
                Text(
                  '${widget.fileCount} file(s) selected',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      content: Container(
        width: double.maxFinite,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Select destination folder',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Root option
            ListTile(
              leading: const Icon(Icons.home, color: Colors.orange),
              title: const Text('Root (No Folder)', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Move to main screen'),
              onTap: () => Navigator.pop(context, '__ROOT__'),
            ),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _buildFolderTree(null, 0),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  List<Widget> _buildFolderTree(String? parentId, int depth) {
    final folders = parentId == null
        ? widget.docService.getRootFolders()
        : widget.docService.getSubfolders(parentId);
    
    // Filter out excluded folders (selected folders being moved)
    final filteredFolders = folders.where((f) => !widget.excludedFolderIds.contains(f.id)).toList();
    
    return filteredFolders.expand((folder) {
      final hasChildren = widget.docService.getSubfolders(folder.id).isNotEmpty;
      final isExpanded = _expandedFolders.contains(folder.id);
      
      return [
        ListTile(
          contentPadding: EdgeInsets.only(left: 16.0 + (depth * 24.0)),
          leading: hasChildren
              ? IconButton(
                  icon: Icon(isExpanded ? Icons.expand_more : Icons.chevron_right),
                  onPressed: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedFolders.remove(folder.id);
                      } else {
                        _expandedFolders.add(folder.id);
                      }
                    });
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
              : const SizedBox(width: 24),
          title: Row(
            children: [
              Icon(Icons.folder, 
                color: depth == 0 ? Colors.blue : Colors.blue.withOpacity(0.7),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(folder.name)),
            ],
          ),
          onTap: () => Navigator.pop(context, folder.id),
        ),
        if (hasChildren && isExpanded)
          ..._buildFolderTree(folder.id, depth + 1),
      ];
    }).toList();
  }
}
