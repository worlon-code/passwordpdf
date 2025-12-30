import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../services/logging_service.dart';
import '../../settings/services/settings_service.dart';
import '../../../services/document_service.dart';
import '../../../services/pdf_password_service.dart';
import '../../../models/document_item_model.dart';
import 'pdf_viewer_screen.dart';
import 'file_info_screen.dart';
import '../widgets/password_selection_dialog.dart';
import '../../common/utils/file_conflict_resolver.dart';

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
  String _filterType = 'All'; // All, PDF, DOC, Excel

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
                  
                  // Copy the original file with new name
                  try {
                    final originalFile = File(file.path!);
                    final directory = originalFile.parent;
                    final newFilePath = '${directory.path}/$newName';
                    
                    // Copy file to new path
                    await originalFile.copy(newFilePath);
                    
                    // Add the copied file (not the original)
                    await _docService.addFile(newFilePath, folderId: folderId);
                    addedCount++;
                    _log.info('DocumentDashboard', 'Copied file $fileName to $newName');
                  } catch (e) {
                    _log.error('DocumentDashboard', 'Failed to copy file', e);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to copy file: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                  continue;
                }
              }
            } else {
              // Check for duplicates in unorganized files (main screen)
              final unorganizedFiles = _docService.getUnorganizedFiles();
              final duplicate = unorganizedFiles.where((f) => f.name == fileName).firstOrNull;
              
              if (duplicate != null) {
                // Show duplicate dialog
                final action = await _showDuplicateDialog(fileName);
                
                if (action == null || action == 'discard') {
                  continue; // Skip this file
                } else if (action == 'rename') {
                  final newName = await _getNewFileName(fileName);
                  if (newName == null || newName.isEmpty) {
                    continue;
                  }
                  
                  // Copy the original file with new name
                  try {
                    final originalFile = File(file.path!);
                    final directory = originalFile.parent;
                    final newFilePath = '${directory.path}/$newName';
                    await originalFile.copy(newFilePath);
                    await _docService.addFile(newFilePath);
                    addedCount++;
                  } catch (e) {
                    _log.error('DocumentDashboard', 'Failed to copy file', e);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to copy file: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
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
      
      // Create archive
      final archive = Archive();
      
      // Recursive function to add folder contents
      void addFolderToArchive(String folderId, String pathPrefix) {
        // Add files in this folder
        final files = _docService.getFilesInFolder(folderId);
        for (final fileItem in files) {
          if (fileItem.filePath != null) {
            final file = File(fileItem.filePath!);
            if (file.existsSync()) {
              final bytes = file.readAsBytesSync();
              final archivePath = pathPrefix.isEmpty 
                  ? fileItem.name 
                  : '$pathPrefix/${fileItem.name}';
              final archiveFile = ArchiveFile(
                archivePath,
                bytes.length,
                bytes,
              );
              archive.addFile(archiveFile);
            }
          }
        }
        
        // Recursively add subfolders
        final subfolders = _docService.getSubfolders(folderId);
        for (final subfolder in subfolders) {
          final subPath = pathPrefix.isEmpty
              ? subfolder.name
              : '$pathPrefix/${subfolder.name}';
          addFolderToArchive(subfolder.id, subPath);
        }
      }
      
      // Start recursive export from root folder
      addFolderToArchive(folder.id, '');
      
      if (archive.files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Folder is empty')),
          );
        }
        return;
      }

      // Encode to ZIP
      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) {
        throw Exception('Failed to create ZIP');
      }

      // Save to configured export path
      final settings = context.read<SettingsService>();
      final exportPath = settings.exportPath;
      
      if (exportPath == null) {
        throw Exception('Export path not configured');
      }
      
      final downloadsDir = Directory(exportPath);
      if (!downloadsDir.existsSync()) {
        try {
          downloadsDir.createSync(recursive: true);
        } catch (e) {
             throw Exception('Could not access export directory: $exportPath');
        }
      }

      // Create unique filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipFileName = '${folder.name}_$timestamp.zip';
      
      final defaultPath = '${downloadsDir.path}/$zipFileName';

      final savePath = await FileConflictResolver.resolve(
        context: context,
        filePath: defaultPath,
      );

      if (savePath == null) return;
      
      final outputFile = File(savePath);
      
      await outputFile.writeAsBytes(zipData);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported ${archive.files.length} file(s) to .../${outputFile.path.split(Platform.pathSeparator).last}'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
            ),
          ),
        );
      }
      _log.info('DocumentDashboard', 'Exported folder: ${folder.name} (${archive.files.length} files) to ${outputFile.path}');
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

    final allFolders = _docService.getFolders();
    if (allFolders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No folders available. Create a folder first.')),
      );
      return;
    }

    final result = await showDialog<String>(
      context: context,
      builder: (context) => _MoveDialogWithTree(
        docService: _docService,
        fileCount: _selectedFileIds.length,
      ),
    );

    if (result != null) {
      try {
        // Check for duplicates before moving
        final destinationFiles = _docService.getFilesInFolder(result);
        final filesToMove = _selectedFileIds.map((id) => 
          _docService.getAllItems().firstWhere((item) => item.id == id)
        ).toList();
        
        final Map<String, String> renamedFiles = {}; // original id -> new name
        
        for (final file in filesToMove) {
          final duplicate = destinationFiles.where((f) => f.name == file.name).firstOrNull;
          
          if (duplicate != null) {
            // Show duplicate dialog
            final action = await _showDuplicateDialog(file.name);
            
            if (action == null || action == 'discard') {
              // Skip this file - remove from selection
              _selectedFileIds.remove(file.id);
              continue;
            } else if (action == 'rename') {
              // Get new name
              final newName = await _getNewFileName(file.name);
              if (newName == null || newName.isEmpty) {
                // User cancelled - skip this file
                _selectedFileIds.remove(file.id);
                continue;
              }
              renamedFiles[file.id] = newName;
            }
          }
        }
        
        // Rename files that need renaming
        for (final entry in renamedFiles.entries) {
          await _docService.renameItem(entry.key, entry.value);
        }
        
        // Now move all remaining files
        if (_selectedFileIds.isNotEmpty) {
          await _docService.moveFilesToFolder(_selectedFileIds.toList(), result);
        }
        
        setState(() {
          _selectedFileIds.clear();
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Moved ${filesToMove.length - (filesToMove.length - _selectedFileIds.length)} file(s)')),
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

  /// Smart PDF open - checks stored password, tries without, then shows dialog
  Future<void> _openPdfWithSmartPassword(String filePath, String fileName) async {
    final pdfService = PdfPasswordService();
    
    // 1. Check for stored password
    final storedPassword = await pdfService.getPasswordForDocument(filePath);
    if (storedPassword != null) {
      // Use stored password
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

    // 2. Try opening without password first
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PdfViewerScreen(
            filePath: filePath,
            fileName: fileName,
            password: '',
            onPasswordRequired: () async {
              // 3. PDF needs password - show dialog
              Navigator.pop(context);
              await _showPasswordDialogAndOpen(filePath, fileName);
            },
            onSuccess: () {
              // Save empty password (no password needed)
              pdfService.saveDocumentPassword(filePath, '');
            },
          ),
        ),
      );
    }
  }

  Future<void> _showPasswordDialogAndOpen(String filePath, String fileName) async {
    final pdfService = PdfPasswordService();
    
    final password = await showDialog<String>(
      context: context,
      builder: (context) => const PasswordSelectionDialog(),
    );
    
    if (password != null && mounted) {
      // Don't save password yet - wait for successful load
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PdfViewerScreen(
            filePath: filePath,
            fileName: fileName,
            password: password,
            onSuccess: () {
              // Only save password after successful load
              pdfService.saveDocumentPassword(filePath, password);
            },
            onPasswordRequired: () async {
              // Wrong password - go back and show dialog again
              Navigator.pop(context);
              await _showPasswordDialogAndOpen(filePath, fileName);
            },
          ),
        ),
      );
    }
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
          title: Text(_currentFolderId == null ? 'Documents' : _getFolderName()),
          leading: _currentFolderId != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _navigateUp,
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
                  icon: const Icon(Icons.folder_zip),
                  onPressed: () {
                    final folder = _docService.getAllItems().firstWhere(
                          (item) => item.id == _currentFolderId,
                        );
                    _exportFolderAsZip(folder);
                  },
                  tooltip: 'Export as ZIP',
                ),
               IconButton(
                  icon: const Icon(Icons.create_new_folder),
                  onPressed: _importFolder,
                  tooltip: 'Import Folder',
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

  /// Build filter bar with file type chips
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
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(type),
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
                      await _openPdfWithSmartPassword(file.filePath!, file.name);
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
            _toggleFileSelection(file.id);
          } else if (file.isPdf) {
            // Smart PDF password handling - checks stored, tries without, shows dialog if needed
            await _openPdfWithSmartPassword(file.filePath!, file.name);
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
}

// Stateful tree widget for move dialog
class _MoveDialogWithTree extends StatefulWidget {
  final DocumentService docService;
  final int fileCount;
  
  const _MoveDialogWithTree({
    required this.docService,
    required this.fileCount,
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
    
    return folders.expand((folder) {
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
