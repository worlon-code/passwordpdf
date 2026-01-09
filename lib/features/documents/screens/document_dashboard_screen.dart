import 'package:flutter/material.dart';
import 'dart:async';
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
import 'removed_files_screen.dart';
import '../../../services/storage_service.dart';
import '../../../services/pdf_tools_service.dart';
import 'pdf_viewer_screen.dart';
import 'file_info_screen.dart';
import 'export_progress_screen.dart';
import '../widgets/password_selection_dialog.dart';
import '../../common/utils/file_conflict_resolver.dart';
import '../widgets/conflict_resolution_dialog.dart';
import '../../../models/conflict_resolution_model.dart';
import 'folder_navigation_screen.dart';
import '../widgets/duplicate_files_dialog.dart';
import '../../documents/widgets/folder_selection_dialog.dart';
import '../../../main.dart' show PendingFileOpen;
import 'package:passwordpdf_manager/features/common/models/sort_option.dart';
import 'package:passwordpdf_manager/features/common/widgets/sort_bottom_sheet.dart';
import 'package:passwordpdf_manager/features/documents/screens/file_system_browser.dart';




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
  Set<String> _foldersWithNewContent = {}; // Cache for folder badges
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _currentFolderId; // null = show all folders
  final Set<String> _selectedFileIds = {};
  String _filterType = 'All'; // All, PDF, DOC, Excel
  SortOption _sortOption = SortOption.dateModified;
  bool _sortAscending = false; // Default: Newest first (Descending)
  DateTime? _pullStartTime; // For time-based sync detection
  bool _showPullIndicator = false; // Show pull overlay
  bool _isHoldingForSync = false; // Track if holding long enough for sync
  Timer? _holdTimer; // Timer for hold detection
  
  bool get _isExporting => _exportQueue.jobs.any((j) => j.status == ExportStatus.inProgress);
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _exportQueue.addListener(_updateUI);
    _exportQueue.init(); // Load history
    _exportQueue.startWorker();
    _initialize().then((_) => _startAutoSync());
  }

  void _startAutoSync() {
    // Initial Sync
    _docService.syncAllFolders().then((_) async {
        await _docService.initialize(); // Reload from DB
        _updateFolderBadges();
        if (mounted) setState(() {}); 
    });
    
    // Periodic Sync (10 min = 600 sec)
    _syncTimer = Timer.periodic(const Duration(minutes: 10), (timer) {
        if (mounted) {
            _docService.syncAllFolders().then((_) async {
                 await _docService.initialize(); // Reload from DB
                 _updateFolderBadges();
                 if (mounted) setState(() {});
                 ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Auto-Sync Completed'), duration: Duration(seconds: 1)));
            });
        }
    });
  }
  
  /// Manual sync triggered by long pull or menu button
  Future<void> _syncWithReload({bool isPullToRefresh = false}) async {
    if (!isPullToRefresh) {
        ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync Started...'), duration: Duration(seconds: 1)),
        );
        setState(() => _isLoading = true);
    }
    
    try {
        await _docService.syncAllFolders();
        await _docService.initialize(); // Reload from DB
        _updateFolderBadges();
        
        if (mounted) {
            setState(() {
              if (!isPullToRefresh) _isLoading = false;
              // Trigger rebuild to update badges
            });
            
            if (!isPullToRefresh) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Sync Completed'), duration: Duration(seconds: 1)),
                );
            }
        }
    } catch (e) {
        if (mounted && !isPullToRefresh) {
             setState(() => _isLoading = false);
        }
        rethrow;
    }
  }
  
  @override
  void dispose() {
    _syncTimer?.cancel();
    _exportQueue.removeListener(_updateUI);
    _exportQueue.stopWorker();
    super.dispose();
  }

  void _updateUI() {
    _updateFolderBadges();
    if (mounted) setState(() {});
  }

  void _updateFolderBadges() {
    final allItems = _docService.getAllItems();
    final newItems = allItems.where((i) => i.isNew).toList();
    final foldersWithNew = <String>{};
    final itemMap = {for (var i in allItems) i.id: i};

    for (var item in newItems) {
      // Mark all ancestors as having new content
      var parentId = item.parentId;
      while (parentId != null) {
         if (foldersWithNew.contains(parentId)) break; // Optimization
         foldersWithNew.add(parentId);
         parentId = itemMap[parentId]?.parentId;
      }
    }
    _foldersWithNewContent = foldersWithNew;
  }

  Future<void> _importFiles(List<String> paths) async {
    setState(() => _isLoading = true);
    
    int successCount = 0;
    
    for (final path in paths) {
      if (!mounted) break;
      final fileName = path.split(Platform.pathSeparator).last;
      
      // 1. Try Zero-Copy Import (Check for Global Duplicates)
      var result = await _docService.addReference(path, fileName, allowDuplicate: false, folderId: _currentFolderId, isNew: false);
      
      if (result.isDuplicate) {
        // Found duplicate(s) in library
        if (!mounted) break;
        
        // Show Duplicate Dialog
        final shouldImportAnyway = await showDialog<bool>(
            context: context,
            builder: (context) => DuplicateFilesDialog(duplicates: result.duplicates ?? []),
        );
        
        if (shouldImportAnyway != true) {
            continue; // User skipped
        }
        
        // User chose Import Anyway
        // 2. Check for Name Collision in CURRENT folder (to avoid visual confusion)
        final existingId = _docService.getFileIdInFolder(fileName, _currentFolderId);
        
        if (existingId != null) {
            // Name conflict! Show Resolution Dialog
            if (!mounted) break;
            
            final conflict = ConflictItem(
                sourceId: path, // Use path as temp ID
                name: fileName,
                originalPath: path,
                isFolder: false,
            );
            
            final resolutions = await showDialog<Map<String, ConflictAction>>(
                context: context,
                builder: (context) => ConflictResolutionDialog(conflicts: [conflict]),
            );
            
            if (resolutions == null || !resolutions.containsKey(path)) {
                continue; // Cancelled or skipped
            }
            
            final action = resolutions[path]!;
            
            // Handle Action
            switch (action.type) {
                case ConflictActionType.skip:
                    continue;
                    
                case ConflictActionType.rename:
                     // Auto-rename: Append number
                     String newName = fileName;
                     int i = 1;
                     while (_docService.getFileIdInFolder(newName, _currentFolderId) != null) {
                         final ext = newName.split('.').last;
                         final nameNoExt = newName.substring(0, newName.length - ext.length - 1);
                         newName = '${nameNoExt}_$i.$ext';
                         i++;
                     }
                     // Import with new name
                     await _docService.addReference(path, newName, allowDuplicate: true, folderId: _currentFolderId, isNew: false);
                     successCount++;
                     break;
                     
                case ConflictActionType.overwrite:
                     // Overwrite: Delete existing item from DB, then add new ref
                     await _docService.deleteItem(existingId); 
                     await _docService.addReference(path, fileName, allowDuplicate: true, folderId: _currentFolderId, isNew: false);
                     successCount++;
                     break;
            }
            
        } else {
             // No name collision, just add (allowDuplicate=true because we already passed the global check)
             await _docService.addReference(path, fileName, allowDuplicate: true, folderId: _currentFolderId, isNew: false);
             successCount++;
        }
        
      } else if (result.success) {
        successCount++;
      } else {
        // Error
        _log.error('Dashboard', 'Import failed: ${result.errorMessage}');
      }
    }

    // Refresh UI
    _updateFolderBadges();
    setState(() => _isLoading = false); // This triggers rebuild, _buildContent will fetch new service state
    
    if (mounted) {
       if (successCount > 0) {
         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $successCount files')));
       }
    }
  }

  void _openFileBrowser() async {
    final selectedPaths = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => const FileSystemBrowser(
          allowMultiple: true,
          allowedExtensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx'],
        ),
      ),
    );

    if (selectedPaths != null && selectedPaths.isNotEmpty) {
      _importFiles(selectedPaths);
    }
  }
  
  Future<String?> _showRenameExistingDialog(String currentName) async {
    final controller = TextEditingController(text: '${currentName}_1');
    return showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
            title: const Text('Rename Existing Folder'),
            content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                    Text('The folder "$currentName" already exists in your library.'),
                    const SizedBox(height: 8),
                    const Text('To import the new folder with the same name, please rename the EXISTING folder first.'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                            labelText: 'New Name for Existing Folder',
                            border: OutlineInputBorder(),
                        ),
                        autofocus: true,
                    )
                ]
            ),
            actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                ElevatedButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Rename')),
            ]
        )
    );
  }

  Future<void> _initialize({bool showLoading = true}) async {
    if (showLoading) setState(() => _isLoading = true);
    try {
      await _docService.initialize();
      _log.info('DocumentDashboard', 'Service initialized');
    } catch (e) {
      _log.error('DocumentDashboard', 'Initialization error', e);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isInitialized = true;
          _updateFolderBadges();
        });
        
        // Check for pending folder navigation (from notification tap)
        if (DashboardFolderNavigation.pendingFolderId != null) {
          final folderId = DashboardFolderNavigation.pendingFolderId;
          DashboardFolderNavigation.clear();
          setState(() {
            _currentFolderId = folderId;
          });
        }
        
        // [ZERO COPY] Check for pending file open (from All Docs add)
        if (PendingFileOpen.hasPending) {
          final filePath = PendingFileOpen.filePath!;
          final fileName = PendingFileOpen.fileName ?? filePath.split(RegExp(r'[/\\]')).last;
          final isTemp = PendingFileOpen.isTemporary;
          PendingFileOpen.clearOpen();
          
          // Find or create the DocumentItem for this file
          final fileId = _docService.findFileIdByPath(filePath);
          if (fileId != null) {
            final item = _docService.getAllItems().firstWhere((i) => i.id == fileId);
            _openDocument(item);
          } else {
            // Fallback: open directly via viewer
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PdfViewerScreen(
                  filePath: filePath,
                  fileName: fileName,
                  deleteOnClose: isTemp,
                ),
              ),
            );
          }
        }
        
        // Check mandatory settings
        _checkDownloadLocation();
      }
    }
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
          } else if (item.sourcePath != null) {
            exportItems.add(ExportItem(
              itemId: item.id,
              name: item.name,
              filePath: item.sourcePath,
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

  Future<void> _checkDownloadLocation() async {
    // Auto-create PDF Manager folder in Downloads if it doesn't exist
    final defaultPath = '/storage/emulated/0/Download/PDF Manager';
    final dir = Directory(defaultPath);
    
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
        _log.info('Dashboard', 'Created PDF Manager folder at: $defaultPath');
      } catch (e) {
        _log.error('Dashboard', 'Failed to create PDF Manager folder', e);
      }
    }
    
    // Now check encryption key setup
    await _checkEncryptionKey();
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
                
                final normalizedName = value.trim().toLowerCase();
                final nameExists = existingFolders.any((f) => f.name.toLowerCase() == normalizedName);
                
                setState(() {
                  if (value.trim().isEmpty) {
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
                onPressed: errorText == null && controller.text.trim().isNotEmpty
                    ? () => Navigator.pop(context, true)
                    : null,
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    if (result == true && controller.text.trim().isNotEmpty) {
      try {
        await _docService.createFolder(
          controller.text.trim(),
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
        // 0. Cross-folder duplicate check (name + size)
        final filePaths = result.files.where((f) => f.path != null).map((f) => f.path!).toList();
        final crossFolderDuplicates = await _docService.checkForDuplicates(filePaths);
        
        if (crossFolderDuplicates.isNotEmpty) {
          // Show dialog with duplicates found in other folders
          final shouldProceed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => DuplicateFilesDialog(duplicates: crossFolderDuplicates),
          );
          
          if (shouldProceed != true) {
            return; // User cancelled or tapped a file to navigate
          }
        }
        
        // 1. Identify Same-Folder Conflicts (for rename/skip/overwrite)
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
               // Auto-Rename Logic: Find next unique suffix (_1, _2, etc.)
               final fileName = filePath.split(RegExp(r'[/\\]')).last;
               final parts = fileName.split('.');
               final ext = parts.length > 1 ? parts.last : '';
               final nameWithoutExt = parts.length > 1 
                  ? parts.sublist(0, parts.length - 1).join('.') 
                  : fileName;
              
               // Find unique name
               String newName = fileName;
               int counter = 1;
               while (existingFiles.any((f) => f.name.toLowerCase() == newName.toLowerCase())) {
                 newName = ext.isNotEmpty ? '${nameWithoutExt}_$counter.$ext' : '${nameWithoutExt}_$counter';
                 counter++;
               }
               
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

  /// Import entire folder with smart logic (custom picker)
  Future<void> _importFolder() async {
    // 1. Use Custom Folder Picker
    final result = await Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
            builder: (context) => const FileSystemBrowser(
                 allowFolderSelection: true,
                 allowMultiple: false,
                 initialPath: '/storage/emulated/0',
            ),
        ),
    );
    
    if (result == null || result.isEmpty) return;
    
    final dirPath = result.first;
    final sourceDir = Directory(dirPath);
    
    if (!sourceDir.existsSync()) {
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Selected folder does not exist')));
      }
      return;
    }

    final folderName = sourceDir.path.split(Platform.pathSeparator).last;
    
    // 2. Check if ALREADY IMPORTED (Sync Check)
    final existingImportedFolder = _docService.getFolderBySourcePath(dirPath);
    if (existingImportedFolder != null) {
        if (mounted) {
            showDialog(
                context: context,
                builder: (context) => AlertDialog(
                    title: const Text('Folder Already Synced'),
                    content: Text(
                        'The folder "$folderName" is already imported in your library.\n\n'
                        'Please use the Sync feature inside the existing folder to update files.'
                    ),
                    actions: [
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
                    ],
                )
            );
        }
        return;
    }

    // 3. Check for "Downloads" special case
    // We only restrict if the folder is strictly named "Download" (system folder).
    // Subfolders inside Download (like QuickShare) will pass as false here, enabling recursive import.
    final isDownloadFolder = folderName.toLowerCase() == 'download';
    
    if (isDownloadFolder) {
        // Show Warning for Downloads (Flat Import)
        final proceed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                title: const Text('Import Download Folder?'),
                content: const Text(
                    'The Downloads folder is usually very large.\n\n'
                    'To keep your library clean, we will ONLY import files from the root of "Downloads". '
                    'Subfolders inside Downloads will be skipped.\n\n'
                    'Do you want to proceed?'
                ),
                actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import Files')),
                ],
            )
        );
        
        if (proceed != true) return;
        
        // Flat Import for Downloads
        await _performImport(sourceDir, folderName, recursive: false);
        
    } else {
        // Normal Folder (Recursive)
        // Check for Name Conflict Logic is handled in _performImport
        
        final proceed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                title: Text('Import "$folderName"?'),
                content: const Text(
                    'This will import all files and subfolders from this location.\n\n'
                    'A new folder will be created in your library mirroring this structure.'
                ),
                actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import Folder')),
                ],
            )
        );
        
        if (proceed != true) return;
        
        // Recursive Import
        await _performImport(sourceDir, folderName, recursive: true);
    }
  }

  Future<void> _performImport(Directory sourceDir, String folderName, {required bool recursive}) async {
    // Check for Name Conflicts (Smart Resolution)
    final existingFolders = _currentFolderId != null 
        ? _docService.getSubfolders(_currentFolderId!)
        : _docService.getRootFolders();
    
    final conflicts = existingFolders.where((f) => f.name.toLowerCase() == folderName.toLowerCase()).toList();
    
    if (conflicts.isNotEmpty) {
        // Conflict Detected!
        // Requirement: Rename the EXISTING folder(s) to free up the name for the new import.
        
        if (conflicts.length == 1) {
             // Single Conflict: Prompt user to rename manual folder
             final existing = conflicts.first;
             final newName = await _showRenameExistingDialog(existing.name);
             if (newName == null) return; // Abort import
             
             // Rename the existing folder
             await _docService.renameItem(existing.id, newName);
             
        } else {
             // Multiple Conflicts: Auto-rename prompt
             final proceed = await showDialog<bool>(
                 context: context,
                 builder: (context) => AlertDialog(
                     title: const Text('Multiple Conflicts Found'),
                     content: Text('Multiple folders named "${folderName}" already exist.\n\nAutomtically rename existing folders to "${folderName}_1", "${folderName}_2", etc. to proceed?'),
                     actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Auto Rename')),
                     ]
                 )
             );
             
             if (proceed != true) return;
             
             // Auto-rename all conflicts
             int i = 1;
             for (final f in conflicts) {
                 String targetName = '${folderName}_$i';
                 // Ensure targetName is unique
                 while (existingFolders.any((e) => e.name.toLowerCase() == targetName.toLowerCase())) {
                     i++;
                     targetName = '${folderName}_$i';
                 }
                 await _docService.renameItem(f.id, targetName);
                 i++;
             }
        }
    }
    
    String finalFolderName = folderName;

    // Show Progress
    final progressNotifier = ValueNotifier<Map<String, int>>({'processed': 0, 'total': 0});
    
    // Count files (estimate)
    int totalFiles = 0;
    try {
        await for (final entity in sourceDir.list(recursive: recursive, followLinks: false)) {
             if (entity is File) {
                 final ext = entity.path.split('.').last.toLowerCase();
                 if (['pdf', 'doc', 'docx', 'xls', 'xlsx'].contains(ext)) totalFiles++;
             }
        }
    } catch (e) {
        _log.error('Dashboard', 'Error counting files', e);
    }
    
    if (totalFiles == 0) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No supported files found')));
        return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Importing "$finalFolderName"'),
        content: ValueListenableBuilder<Map<String, int>>(
          valueListenable: progressNotifier,
          builder: (context, value, child) {
            final processed = value['processed']!;
            final total = value['total'] == 0 ? totalFiles : value['total']!; // Use pre-count if available
            final progress = total > 0 ? processed / total : null;
            
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 16),
                Text('Importing $processed / $total files...'),
              ],
            );
          },
        ),
      ),
    );

    int processedFiles = 0;
    
    try {
        // Create Root Folder (with sourcePath for Sync!)
        // Note: createFolder doesn't support sourcePath param yet, we might need to update it or update item after creation.
        // DocumentService.createFolder returns DocumentItem.
        
        var rootFolder = await _docService.createFolder(
           finalFolderName,
           parentId: _currentFolderId,
        );
        
        // Update root folder with sourcePath (Manual update via service private access workaround or update API)
        // Since we can't easily change service signature right now, we can update the item in memory and save.
        // Actually, let's check DocumentService.createFolder.
        // It likely doesn't have sourcePath. We should add it or use updateItem? 
        // Let's assume we can update it later. Wait, we need it.
        // Quick Hack: Modify local item and call _saveDocuments() logic? No, too risky.
        // Better: We will rely on "Zero Copy" where files have sourcePath. 
        // But for "Sync" feature, we need *Folder* to have sourcePath.
        // I will add a method `_docService.updateFolderSourcePath(id, path)` or just handle it if possible.
        // For now, let's just proceed with import logic. If I can't save sourcePath, Phase 3 (Sync) will fail.
        // Actually, I can use `_docService.updateItem` if exposed? No.
        
        // Let's instantiate a modified item and inject it? No.
        // Let's modify DocumentService.createFolder later?
        // Okay, I will try to call `_docService.updateItem(rootFolder.copyWith(sourcePath: sourceDir.path))` if it exists.
        // If not, I'll add `updateItem` to DocumentService in next step.
        
        // Map: Source Dir Path -> App Folder ID
        final folderMap = <String, String>{sourceDir.path: rootFolder.id};
        
        await for (final entity in sourceDir.list(recursive: recursive, followLinks: false)) {
            if (entity is Directory && recursive) {
                // Create subfolder
                final parentPath = entity.parent.path;
                final parentId = folderMap[parentPath];
                
                if (parentId != null) {
                    final subName = entity.path.split(Platform.pathSeparator).last;
                    final newFolder = await _docService.createFolder(subName, parentId: parentId);
                    folderMap[entity.path] = newFolder.id;
                    // Ideally set sourcePath for subfolders too? Maybe overkill, valid for Root is enough usually.
                }
            } else if (entity is File) {
               final ext = entity.path.split('.').last.toLowerCase();
               if (['pdf', 'doc', 'docx', 'xls', 'xlsx'].contains(ext)) {
                   final parentPath = entity.parent.path;
                   final parentId = folderMap[parentPath] ?? rootFolder.id; // Fallback to root for Flat Import
                   
                   await _docService.addFile(entity.path, folderId: parentId);
                   processedFiles++;
                   progressNotifier.value = {'processed': processedFiles, 'total': totalFiles};
               }
            }
        }
        
        // [CRITICAL] Update Source Path for Root Folder (for Sync)
        await _docService.updateFolderSourcePath(rootFolder.id, sourceDir.path);
        
        if (mounted) {
            Navigator.pop(context);
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $processedFiles files')));
        }
        
    } catch (e) {
        _log.error('Dashboard', 'Import Error', e);
        if (mounted) {
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
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
      if (file.sourcePath != null) {
        items.add(ExportItem(
          itemId: file.id,
          name: file.name,
          filePath: file.sourcePath,
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

    // 1. Select Destination
    final destinationId = await showDialog<String?>(
      context: context,
      builder: (context) => FolderSelectionDialog(
        docService: _docService,
        title: 'Move Files',
        subtitle: '${_selectedFileIds.length} file(s) selected',
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
            originalPath: file.sourcePath ?? '',
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
            // Auto-Rename: Find next unique suffix (_1, _2, etc.)
            final parts = file.name.split('.');
            final ext = parts.length > 1 ? parts.last : '';
            final nameWithoutExt = parts.length > 1 
                ? parts.sublist(0, parts.length - 1).join('.') 
                : file.name;
            
            // Find unique name in destination
            String newName = file.name;
            int counter = 1;
            while (destinationFiles.any((f) => f.name.toLowerCase() == newName.toLowerCase())) {
              newName = ext.isNotEmpty ? '${nameWithoutExt}_$counter.$ext' : '${nameWithoutExt}_$counter';
              counter++;
            }
            
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
           bool moved = false;
           String folderIdToMove = currentFileId;
           
           while (!moved) {
             try {
               if (destinationId == '__ROOT__') {
                 await _docService.moveFolderToRoot(folderIdToMove);
               } else {
                 await _docService.moveFolderToFolder(folderIdToMove, destinationId);
               }
               moved = true;
             } catch (e) {
               if (e.toString().contains('Cannot move:')) {
                 // Show rename dialog
                 final currentFolder = _docService.getAllItems().firstWhere((i) => i.id == folderIdToMove);
                 final newName = await showDialog<String>(
                   context: context,
                   builder: (context) {
                     final controller = TextEditingController(text: currentFolder.name);
                     return AlertDialog(
                       title: const Text('Rename to Move'),
                       content: Column(
                         mainAxisSize: MainAxisSize.min,
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Text(
                             'A folder named "${currentFolder.name}" already exists at the destination.',
                             style: TextStyle(color: Colors.grey[600]),
                           ),
                           const SizedBox(height: 16),
                           TextField(
                             controller: controller,
                             autofocus: true,
                             decoration: const InputDecoration(
                               labelText: 'New folder name',
                               border: OutlineInputBorder(),
                             ),
                             onSubmitted: (val) => Navigator.pop(context, val),
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
                           child: const Text('Rename & Move'),
                         ),
                       ],
                     );
                   },
                 );
                 
                 if (newName == null || newName.trim().isEmpty) {
                   // User cancelled - skip this folder
                   skippedCount++;
                   break;
                 }
                 
                 // Rename the folder and retry move
                 await _docService.renameItem(folderIdToMove, newName.trim());
               } else {
                 rethrow; // Some other error
               }
             }
           }
           if (moved) movedCount++;
        } else {
           if (destinationId == '__ROOT__') {
             await _docService.moveFilesToRoot([currentFileId]);
           } else {
             await _docService.moveFilesToFolder([currentFileId], destinationId);
           }
           movedCount++;
        }
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
        if (item.sourcePath != null) {
          // Verify file exists
          final file = File(item.sourcePath!);
          if (await file.exists()) {
             filesToShare.add(XFile(item.sourcePath!));
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
    
    final filePath = item.sourcePath; // Use actual file path, not ID
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

  void _navigateUp() async {
    if (_currentFolderId != null) {
      // Clear badges when leaving folder
      await _docService.clearFolderBadges(_currentFolderId!);
      _updateFolderBadges(); // Refresh the badge cache
      
      setState(() {
        _selectedFileIds.clear(); // Clear selection when navigating
        // Logic to find parent
        final currentFolder = _docService.getAllItems().firstWhere(
          (item) => item.id == _currentFolderId,
          orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.folder),
        );
        _currentFolderId = currentFolder.parentId;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentFolderId == null,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _navigateUp();
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
                      if (result.sourcePath != null) {
                        _openDocument(result);
                      }
                    }
                  }
                },
                tooltip: 'Search',
              ),
              IconButton(
                icon: const Icon(Icons.sort),
                onPressed: _showSortOptions,
                tooltip: 'Sort items',
              ),
              /* Download icon removed as requested (redundant with multi-select)
              if (_currentFolderId != null)
                IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () { ... },
                  tooltip: 'Export as ZIP',
                ),
              */
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
                  } else if (value == 'removed_files') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => RemovedFilesScreen(
                          docService: _docService,
                          folderId: _currentFolderId,
                        ),
                      ),
                    ).then((_) => setState(() {}));
                  } else if (value == 'sync_now') {
                    _syncWithReload();
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
                  const PopupMenuItem(
                    value: 'removed_files',
                    child: Row(
                      children: [
                        Icon(Icons.delete_sweep),
                        SizedBox(width: 8),
                        Text('Removed Files'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'sync_now',
                    child: Row(
                      children: [
                        Icon(Icons.sync),
                        SizedBox(width: 8),
                        Text('Sync All Folders'),
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
        body: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is OverscrollNotification && notification.overscroll < 0) {
                  // Pull started - start timer if not already tracking
                  if (_pullStartTime == null) {
                    _pullStartTime = DateTime.now();
                    _holdTimer?.cancel();
                    // Start timer to show sync indicator after 1.5s of holding
                    _holdTimer = Timer(const Duration(milliseconds: 1500), () {
                      if (mounted && _pullStartTime != null) {
                        setState(() {
                          _isHoldingForSync = true;
                          _showPullIndicator = true;
                        });
                      }
                    });
                  }
                } else if (notification is ScrollEndNotification) {
                  // Pull ended - hide visual indicator, then reset state after delay
                  // (delay allows onRefresh to capture values before reset)
                  _holdTimer?.cancel();
                  Future.delayed(const Duration(milliseconds: 200), () {
                    if (mounted) {
                      _pullStartTime = null;
                      _isHoldingForSync = false;
                      setState(() => _showPullIndicator = false);
                    }
                  });
                } else if (notification is ScrollUpdateNotification && notification.scrollDelta != null && notification.scrollDelta! > 0) {
                  // Scrolling down - reset all state
                  _pullStartTime = null;
                  _holdTimer?.cancel();
                  _isHoldingForSync = false; // Always reset
                  if (_showPullIndicator) {
                    setState(() => _showPullIndicator = false);
                  }
                }
                return false;
              },
              child: RefreshIndicator(
                onRefresh: () async {
                  // Check if held for > 1.5 seconds using actual time
                  bool shouldSync = _isHoldingForSync;
                  if (!shouldSync && _pullStartTime != null) {
                    // Fallback: Check elapsed time directly in case timer hasn't fired
                    final elapsed = DateTime.now().difference(_pullStartTime!);
                    shouldSync = elapsed.inMilliseconds >= 1500;
                  }
                  
                  _pullStartTime = null;
                  _holdTimer?.cancel();
                  setState(() {
                    _showPullIndicator = false;
                    _isHoldingForSync = false;
                  });
                  
                  if (shouldSync) {
                    await _syncWithReload(isPullToRefresh: true);
                  } else {
                    await _initialize();
                  }
                },
                child: _isLoading
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
              ),
            ),
            // Hold Indicator Overlay (shows after 1.5s hold)
            if (_showPullIndicator && _isHoldingForSync)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.sync,
                        size: 28,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Release to sync all folders',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _openFileBrowser,
          icon: const Icon(Icons.add),
          label: const Text('Add Files'),
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

  /// Sort items based on current selection
  List<DocumentItem> _sortItems(List<DocumentItem> items) {
    items.sort((a, b) {
      int comparison = 0;
      switch (_sortOption) {
        case SortOption.name:
          comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortOption.size:
          comparison = a.size.compareTo(b.size);
          break;
        case SortOption.dateCreated:
          comparison = a.createdAt.compareTo(b.createdAt);
          break;
        case SortOption.dateModified:
          comparison = a.modifiedAt.compareTo(b.modifiedAt);
          break;
      }
      return _sortAscending ? comparison : -comparison;
    });
    return items;
  }

  /// Show sort options bottom sheet
  void _showSortOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SortBottomSheet(
        currentOption: _sortOption,
        isAscending: _sortAscending,
        onSortChanged: (option, ascending) {
          setState(() {
            _sortOption = option;
            _sortAscending = ascending;
          });
        },
      ),
    );
  }



  Widget _buildContent() {
    if (_currentFolderId == null) {
      // Show root folders view
      var folders = _docService.getRootFolders();
      var unorganizedFiles = _docService.getUnorganizedFiles();
      
      // Apply file type filter
      folders = _applyFolderFilter(folders);
      unorganizedFiles = _applyFileFilter(unorganizedFiles);
      
      // Apply sorting
      folders = _sortItems(List.from(folders));
      unorganizedFiles = _sortItems(List.from(unorganizedFiles));

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
                  ] else if (_filterType != 'All' && folders.isEmpty) ...[
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
      
      // Apply sorting
      subfolders = _sortItems(List.from(subfolders));
      files = _sortItems(List.from(files));
      
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
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: constraints.maxHeight,
          child: Center(
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
    ),
          ),
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
        title: Row(
            children: [
                Flexible(child: Text(folder.name, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                if (folder.isImported) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.sync, size: 16, color: Theme.of(context).colorScheme.primary),
                ],
                if (_foldersWithNewContent.contains(folder.id)) ...[
                    const SizedBox(width: 8),
                     Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('NEW', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                    ),
                ],
            ],
        ),
        subtitle: Text(_buildFolderSubtitle(folder.id)),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            if (value == 'rename') {
              if (folder.isImported) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot rename imported/synced folders')));
                  return;
              }
              await _renameItem(folder);
            } else if (value == 'export') {
              await _exportFolderAsZip(folder);
            } else if (value == 'delete') {
              if (folder.isImported) {
                  final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                          title: const Text('Delete Synced Folder?'),
                          content: const Text(
                              'This folder is imported from your device.\n'
                              'Deleting it will remove it from the app and stop future syncs.\n\n'
                              'Original files on your device will NOT be deleted.'
                          ),
                          actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                                  onPressed: () => Navigator.pop(context, true), 
                                  child: const Text('Delete')
                              ),
                          ]
                      )
                  );
                  if (confirm != true) return;
              }
              await _docService.deleteItem(folder.id);
              setState(() {});
            } else if (value == 'sync') {
                 ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Syncing...')));
                 final success = await _docService.syncFolder(folder.id);
                 await _docService.initialize(); // Reload from DB
                 _updateFolderBadges(); // Refresh badge cache
                 setState(() {});
                 if (mounted) {
                   ScaffoldMessenger.of(context).showSnackBar(
                     SnackBar(
                       content: Text(success ? 'Sync Completed' : 'Sync Failed - check logs'),
                       backgroundColor: success ? null : Colors.red,
                     ),
                   );
                 }
            }
          },
          itemBuilder: (context) => [
            if (folder.isImported)
                const PopupMenuItem(
                  value: 'sync',
                  child: Row(
                    children: [
                      Icon(Icons.sync, color: Colors.blue),
                      SizedBox(width: 8),
                      Text('Sync Now'),
                    ],
                  ),
                ),
            if (!folder.isImported)
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
      ),
    ),
  );
  }

  Widget _buildFileCard(DocumentItem file) {
    final isSelected = _selectedFileIds.contains(file.id);
    final fileSizeKb = (file.size / 1024).toStringAsFixed(1);
    final isMissing = file.missingOnDevice;

    return Opacity(
      opacity: isMissing ? 0.6 : 1.0,
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: isSelected 
            ? Theme.of(context).colorScheme.primaryContainer 
            : (isMissing ? Colors.red.withOpacity(0.05) : null),
        child: InkWell(
          onLongPress: () {
            _toggleFileSelection(file.id);
          },
          onTap: () {
            if (_selectedFileIds.isNotEmpty) {
              _toggleFileSelection(file.id);
            } else {
              if (isMissing) {
                 ScaffoldMessenger.of(context).showSnackBar(
                   const SnackBar(
                     content: Text('File is missing. Leave folder to remove permanently.'),
                     backgroundColor: Colors.red
                   ),
                 );
              } else {
                 _openDocument(file);
              }
            }
          },
          child: ListTile(
            leading: Stack(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isMissing 
                        ? Colors.red.withOpacity(0.1) 
                        : _getFileColor(file).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: isMissing
                        ? const Icon(Icons.delete_forever, color: Colors.red, size: 28)
                        : Icon(
                            _getFileIcon(file),
                            color: _getFileColor(file),
                          ),
                  ),
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
                if (file.isNew && !isMissing)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('NEW', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
            title: Text(
              file.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isMissing ? Colors.grey : null,
                decoration: isMissing ? TextDecoration.lineThrough : null,
              ),
            ),
            subtitle: Text(
              isMissing ? 'Missing from device' : '$fileSizeKb KB',
              style: TextStyle(
                color: isMissing ? Colors.red : null,
              ),
            ),
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
                        if (result == 'open' && file.isPdf && mounted && !isMissing) {
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
                        const PopupMenuItem(value: 'info', child: Row(children: [Icon(Icons.info_outline), SizedBox(width: 8), Text('File Info')])),
                        const PopupMenuItem(value: 'select', child: Row(children: [Icon(Icons.check_circle_outline), SizedBox(width: 8), Text('Select')])),
                        if (!isMissing) const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit), SizedBox(width: 8), Text('Rename')])),
                        const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete, color: Colors.red), SizedBox(width: 8), Text('Delete')])),
                    ],
                ),
          ),
        ),
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
