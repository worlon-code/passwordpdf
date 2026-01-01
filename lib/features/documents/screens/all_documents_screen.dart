import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/material.dart' as material;
import 'package:open_filex/open_filex.dart';
import 'package:passwordpdf_manager/services/device_document_service.dart';
import 'package:passwordpdf_manager/services/document_service.dart';
import 'package:passwordpdf_manager/services/logging_service.dart';
import 'package:passwordpdf_manager/services/export_queue_service.dart';
import 'package:passwordpdf_manager/main.dart';
import 'package:passwordpdf_manager/features/documents/screens/folder_navigation_screen.dart';
import 'package:passwordpdf_manager/features/documents/widgets/duplicate_files_dialog.dart';
import 'package:passwordpdf_manager/features/documents/widgets/conflict_resolution_dialog.dart';
import 'package:passwordpdf_manager/models/conflict_resolution_model.dart';
import 'package:passwordpdf_manager/models/document_item_model.dart';
import 'package:shimmer/shimmer.dart';
import 'package:passwordpdf_manager/features/documents/widgets/folder_selection_dialog.dart';

import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

class AllDocumentsScreen extends StatefulWidget {
  const AllDocumentsScreen({super.key});

  @override
  State<AllDocumentsScreen> createState() => _AllDocumentsScreenState();
}

class _AllDocumentsScreenState extends State<AllDocumentsScreen> {
  final DeviceDocumentService _deviceService = DeviceDocumentService();
  final ScrollController _scrollController = ScrollController();
  final LoggingService _log = LoggingService();
  
  List<FileSystemEntity> _displayedFiles = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String _selectedFilter = 'PDF'; // Default to PDF
  String _errorMessage = '';
  
  // Selection
  final Set<String> _selectedPaths = {};
  bool get _isSelectionMode => _selectedPaths.isNotEmpty;
  
  // Pagination
  static const int _pageSize = 50;
  int _currentOffset = 0;
  bool _hasMore = true;

  // Search
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String? _searchQuery;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _loadDocuments();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
      _searchQuery = '';
      _searchController.clear();
    });
  }

  void _stopSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = null;
      _searchController.clear();
    });
    _loadDocuments();
  }

  void _onSearchChanged(String query) {
    if (_searchDebounce?.isActive ?? false) _searchDebounce!.cancel();
    
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _searchQuery = query;
      });
      _loadDocuments();
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200 && 
        !_isLoadingMore && 
        _hasMore) {
      _loadMoreDocuments();
    }
  }

  Future<void> _loadDocuments() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _displayedFiles = [];
      _currentOffset = 0;
      _hasMore = true;
      _selectedPaths.clear(); 
    });

    try {
      // 1. Scan and cache
      await _deviceService.scanDevice();
      
      // 2. Get first page
      final files = _deviceService.getDocuments(
        offset: 0,
        limit: _pageSize,
        filterType: _selectedFilter,
        searchQuery: _searchQuery,
      );

      if (mounted) {
        setState(() {
          _displayedFiles = files;
          _isLoading = false;
          _hasMore = files.length >= _pageSize;
          _currentOffset = files.length;
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
  
  Future<void> _loadMoreDocuments() async {
    if (_isLoadingMore) return;
    
    setState(() {
      _isLoadingMore = true;
    });

    await Future.delayed(const Duration(milliseconds: 100));

    final moreFiles = _deviceService.getDocuments(
      offset: _currentOffset,
      limit: _pageSize,
      filterType: _selectedFilter,
      searchQuery: _searchQuery,
    );

    if (mounted) {
      setState(() {
        _displayedFiles.addAll(moreFiles);
        _currentOffset += moreFiles.length;
        _hasMore = moreFiles.length >= _pageSize;
        _isLoadingMore = false;
      });
    }
  }

  void _onFilterChanged(String filter) {
    if (_selectedFilter == filter) return;
    
    setState(() {
      _selectedFilter = filter;
      _currentOffset = 0;
      _hasMore = true;
      _displayedFiles = [];
      _isLoading = true;
      _selectedPaths.clear();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
       final files = _deviceService.getDocuments(
          offset: 0,
          limit: _pageSize,
          filterType: _selectedFilter,
          searchQuery: _searchQuery,
       );
       
       if (mounted) {
         setState(() {
           _displayedFiles = files;
           _isLoading = false;
           _hasMore = files.length >= _pageSize;
           _currentOffset = files.length;
         });
       }
    });
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }



  Future<void> _handleFileTap(FileSystemEntity file) async {
    try {
      _log.info('AllDocumentsScreen', '=== _handleFileTap START ===');
      _log.info('AllDocumentsScreen', 'File tapped: ${file.path}');

      // Get docService inside try-catch to handle Provider errors gracefully
      final docService = Provider.of<DocumentService>(context, listen: false);
      
      if (_isSelectionMode) {
        _log.info('AllDocumentsScreen', 'In selection mode, toggling selection');
        _toggleSelection(file.path);
        return;
      }

      final fileName = file.path.split(Platform.pathSeparator).last;
      final isPdf = fileName.toLowerCase().endsWith('.pdf');
      
      _log.info('AllDocumentsScreen', 'fileName: $fileName, isPdf: $isPdf');

      if (isPdf) {
        _log.info('AllDocumentsScreen', 'Calling _importAndOpenSingle...');
        await _importAndOpenSingle(file, docService);
        _log.info('AllDocumentsScreen', '_importAndOpenSingle returned');
      } else {
        _log.info('AllDocumentsScreen', 'Showing bottom sheet for non-PDF...');
        showModalBottomSheet(
          context: context,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (sheetContext) {
            _log.info('AllDocumentsScreen', 'Bottom sheet builder called');
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Tap to open or import'),
                    leading: Icon(_getFileIcon(fileName), color: _getFileColor(fileName), size: 32),
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.open_in_new),
                    title: const Text('Open with System'),
                    onTap: () {
                      _log.info('AllDocumentsScreen', 'Open with System tapped');
                      Navigator.pop(sheetContext);
                      OpenFilex.open(file.path);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.download),
                    title: const Text('Import to App'),
                    onTap: () {
                      _log.info('AllDocumentsScreen', 'Import to App tapped');
                      Navigator.pop(sheetContext);
                      _showImportFolderSelection([file]);
                    },
                  ),
                ],
              ),
            );
          },
        );
        _log.info('AllDocumentsScreen', 'showModalBottomSheet called (async)');
      }
      _log.info('AllDocumentsScreen', '=== _handleFileTap END ===');
    } catch (e, stackTrace) {
      _log.error('AllDocumentsScreen', '_handleFileTap EXCEPTION: $e');
      _log.error('AllDocumentsScreen', 'Stack: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }



  /// Single file import + open (for PDFs)
  Future<void> _importAndOpenSingle(FileSystemEntity file, DocumentService docService) async {
    _log.info('AllDocumentsScreen', '=== _importAndOpenSingle START ===');
    _log.info('AllDocumentsScreen', 'File path: ${file.path}');
    
    final fileName = file.path.split(Platform.pathSeparator).last;
    _log.info('AllDocumentsScreen', 'File name: $fileName');
    
    // Show loader
    _log.info('AllDocumentsScreen', 'Showing loader dialog...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );
    
    try {
      // 1. Check for duplicates
      _log.info('AllDocumentsScreen', 'Checking for duplicates...');
      final duplicates = await docService.checkForDuplicates([file.path]);
      _log.info('AllDocumentsScreen', 'Duplicates found: ${duplicates.length}');
      
      if (duplicates.isNotEmpty) {
        if (mounted && Navigator.canPop(context)) Navigator.pop(context);
        
        if (duplicates.length > 1) {
            // Updated Requirement: Auto-open first + Notify about others
            
            // 1. Notify
            final exportService = Provider.of<ExportQueueService>(context, listen: false);
            PendingFileOpen.duplicateOptions = duplicates;
            
            exportService.showImportNotification(
                'File Exists in Multiple Locations',
                'Found ${duplicates.length} copies of "$fileName". Tap to view all.',
                payload: 'open_duplicates',
            );
            
            // 2. Auto-Open First
            if (mounted && Navigator.canPop(context)) {
               // Close loader if still open (handled above but good to be safe)
            }
             
             // Open existing file directly
            await _openFile(File(duplicates.first.existingFilePath), true);
            return;
        }

        _log.info('AllDocumentsScreen', 'Duplicate found, opening existing file...');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Opening existing copy from ${duplicates.first.locationDisplay}')),
        );
        
        // Open existing file directly
        await _openFile(File(duplicates.first.existingFilePath), true);
        return;
      }
      
      // 2. Import file
      _log.info('AllDocumentsScreen', 'Calling docService.importFile...');
      final result = await docService.importFile(file.path, fileName);
      _log.info('AllDocumentsScreen', 'Import result: success=${result.success}, isDuplicate=${result.isDuplicate}, error=${result.errorMessage}');
      
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      
      if (result.success && result.importItem != null) {
        _log.info('AllDocumentsScreen', 'Imported: $fileName');
        
        // 3. Open the imported file using PendingFileOpen flow
        PendingFileOpen.filePath = result.importItem!.filePath;
        PendingFileOpen.fileName = result.importItem!.name;
        
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainScreen(initialIndex: 1)),
          (route) => false,
        );
      } else if (result.isDuplicate) {
        // Bug Fix: Check for multiple duplicates
        final duplicates = result.duplicates ?? [];
        
        if (duplicates.length > 1) {
          // Show bottom sheet with all locations
          if (!mounted) return;
          showModalBottomSheet(
            context: context,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            builder: (context) => Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'File "${fileName}" already exists',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Found in ${duplicates.length} locations. Select one to open:',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant
                    ),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: duplicates.length,
                      separatorBuilder: (ctx, i) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                         final dup = duplicates[index];
                         return ListTile(
                           leading: const Icon(Icons.folder_open, color: Colors.blue),
                           title: Text(dup.locationDisplay, style: const TextStyle(fontWeight: FontWeight.w500)),
                           trailing: const Icon(Icons.chevron_right),
                           contentPadding: EdgeInsets.zero,
                           onTap: () {
                              Navigator.pop(context); // Close sheet
                              // Navigate
                              DashboardFolderNavigation.pendingFolderId = dup.existingFolderId;
                              navigatorKey.currentState?.pushAndRemoveUntil(
                                MaterialPageRoute(builder: (_) => const MainScreen(initialIndex: 1)),
                                (route) => false,
                              );
                           },
                         );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        } else {
          // Single duplicate - Snackbar (Existing logic)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$fileName already exists in ${result.existingFolderName ?? "library"}'),
              action: SnackBarAction(
                label: 'View',
                onPressed: () {
                  DashboardFolderNavigation.pendingFolderId = result.existingFolderId;
                  navigatorKey.currentState?.pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const MainScreen(initialIndex: 1)),
                    (route) => false,
                  );
                },
              ),
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: ${result.errorMessage ?? "Unknown error"}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e, stackTrace) {
      _log.error('AllDocumentsScreen', 'Import exception: $e');
      _log.error('AllDocumentsScreen', 'Stack trace: $stackTrace');
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
    _log.info('AllDocumentsScreen', '=== _importAndOpenSingle END ===');
  }

  Future<void> _openFile(FileSystemEntity file, bool isPdf) async {
    if (isPdf) {
      PendingFileOpen.filePath = file.path;
      PendingFileOpen.fileName = file.path.split(Platform.pathSeparator).last;
      
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainScreen()),
        (route) => false,
      );
    } else {
      await OpenFilex.open(file.path);
    }
  }

  void _importSelected() {
    _log.info('AllDocumentsScreen', 'Import selected pressed. Counts: ${_selectedPaths.length}');
    if (_selectedPaths.isEmpty) return;

    final files = _selectedPaths.map((path) => File(path)).toList();
    _showImportFolderSelection(files);
  }

  void _showImportFolderSelection(List<FileSystemEntity> files) {
    final docService = Provider.of<DocumentService>(context, listen: false);
    _log.info('AllDocumentsScreen', 'Showing folder selection for ${files.length} files');
    
    showDialog<String?>(
      context: context,
      builder: (dialogContext) => FolderSelectionDialog(
        docService: docService,
        title: 'Import to...',
        subtitle: '${files.length} file(s) selected',
      ),
    ).then((folderId) {
       if (folderId == null) return; // Cancelled
       
       final targetFolderId = folderId == '__ROOT__' ? null : folderId;
       _importFilesWithProgress(files, targetFolderId, docService);
    });
  }

  /// Multi-file import with progress dialog
  /// Multi-file import with progress dialog
  Future<void> _importFilesWithProgress(List<FileSystemEntity> files, String? folderId, DocumentService docService) async {
    _log.info('AllDocumentsScreen', '=== _importFilesWithProgress START ===');
    _log.info('AllDocumentsScreen', 'Files count: ${files.length}, target folder: ${folderId ?? "Root"}');
    
    // 1. Check for Same-Folder Conflicts (Target Collision)
    // These must be resolved first (Rename, Overwrite, Skip)
    _log.info('AllDocumentsScreen', 'Checking for same-folder conflicts...');
    
    final conflictingItems = <ConflictItem>[];
    for (final file in files) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      final existingId = docService.getFileIdInFolder(fileName, folderId);
      
      if (existingId != null) {
        conflictingItems.add(ConflictItem(
          sourceId: file.path,
          name: fileName,
          originalPath: file.path,
          isFolder: false,
        ));
      }
    }
    
    Map<String, ConflictAction> resolutions = {};
    if (conflictingItems.isNotEmpty) {
      _log.info('AllDocumentsScreen', 'Found ${conflictingItems.length} conflicts. Showing resolution dialog...');
      
      final dialogResult = await showDialog<Map<String, ConflictAction>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ConflictResolutionDialog(
          conflicts: conflictingItems,
          onCheckExists: (name) async {
             _log.info('AllDocumentsScreen', 'Checking if "$name" exists in folder "$folderId"');
             final hasConflict = docService.getFileIdInFolder(name, folderId) != null;
             _log.info('AllDocumentsScreen', 'Exist check result: $hasConflict');
             return hasConflict;
          },
        ),
      );
      
      if (dialogResult == null) {
        _log.info('AllDocumentsScreen', 'User cancelled conflict resolution.');
        return; // User cancelled
      }
      resolutions = dialogResult;
    }
    
    // 2. Filter files to process (Remove Skips)
    final filesToProcess = <FileSystemEntity>[];
    final filesToRename = <String, String>{}; // path -> newName
    final filesToOverwrite = <String>{}; // path
    
    for (final file in files) {
      final action = resolutions[file.path];
      
      if (action != null) {
        if (action.type == ConflictActionType.skip) {
          _log.info('AllDocumentsScreen', 'Skipping ${file.path}');
          continue;
        } else if (action.type == ConflictActionType.rename) {
        } else if (action.type == ConflictActionType.rename) {
          // Auto-rename logic: Find next unique suffix (_1, _2, etc.)
          final fileName = file.path.split(Platform.pathSeparator).last;
          final dotIndex = fileName.lastIndexOf('.');
          final namePart = dotIndex != -1 ? fileName.substring(0, dotIndex) : fileName;
          final extPart = dotIndex != -1 ? fileName.substring(dotIndex) : '';
          
          String newName = fileName;
          int counter = 1;
          
          // Check against existing files in folder
          while (docService.getFileIdInFolder(newName, folderId) != null) {
            newName = '${namePart}_$counter$extPart';
            counter++;
          }
          
          filesToRename[file.path] = newName;
          _log.info('AllDocumentsScreen', 'Auto-renaming ${file.path} to $newName');
        } else if (action.type == ConflictActionType.overwrite) {
          filesToOverwrite.add(file.path);
          _log.info('AllDocumentsScreen', 'Will overwrite ${file.path}');
        }
      }
      filesToProcess.add(file);
    }
    
    if (filesToProcess.isEmpty) {
      _log.info('AllDocumentsScreen', 'No files left to process after skips.');
      return;
    }

    // 3. Check for Global Duplicates (excluding those we are explicitly overwriting)
    // We only care about global duplicates if we are NOT overwriting a local file
    // And if we are renaming, we still check if the *new* name exists elsewhere (safeguard)
    _log.info('AllDocumentsScreen', 'Checking for global duplicates in remaining ${filesToProcess.length} files...');
    
    final duplicates = <DuplicateInfo>[];
    final filesToCheckForDupes = filesToProcess.where((f) => !filesToOverwrite.contains(f.path)).toList();
    
    if (filesToCheckForDupes.isNotEmpty) {
      final paths = filesToCheckForDupes.map((f) => f.path).toList();
      duplicates.addAll(await docService.checkForDuplicates(paths));
    }
    
    _log.info('AllDocumentsScreen', 'Global duplicates found: ${duplicates.length}');

    if (duplicates.isNotEmpty) {
      final shouldProceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => DuplicateFilesDialog(duplicates: duplicates),
      );
      
      if (shouldProceed != true) {
        _log.info('AllDocumentsScreen', 'User cancelled at duplicate check.');
        return; // User cancelled
      }
      // If we proceed, we authorize duplicates
    }
    
    final bool forceImport = duplicates.isNotEmpty;
    
    // 4. Show progress dialog
    final total = filesToProcess.length;
    int completed = 0;
    int successCount = 0;
    int failCount = 0;
    
    final progressController = ValueNotifier<double>(0.0);
    final countController = ValueNotifier<String>('0 of $total');
    
    // ignore: use_build_context_synchronously
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Importing Files'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: progressController,
              builder: (context, value, _) => LinearProgressIndicator(value: value),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<String>(
              valueListenable: countController,
              builder: (context, value, _) => Text(value),
            ),
          ],
        ),
      ),
    );
    
    _log.info('AllDocumentsScreen', 'Starting import loop...');
    
    // 5. Import Loop
    for (final file in filesToProcess) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      String targetName = filesToRename[file.path] ?? fileName;
      
      try {
        // Handle Overwrite: Delete existing file first
        if (filesToOverwrite.contains(file.path)) {
           final existingId = docService.getFileIdInFolder(fileName, folderId);
           if (existingId != null) {
             _log.info('AllDocumentsScreen', 'Overwriting: Deleting existing item $existingId');
             await docService.deleteItem(existingId);
           }
        }
        
        // Import
        // Note: importFile logic handles creating NEW file. 
        // If we are overwriting, we just deleted the old one, so it's a new import.
        final result = await docService.importFile(
          file.path, 
          fileName, 
          targetName: targetName,
          allowDuplicate: forceImport
        );
        
        if (result.success && result.importItem != null) {
          successCount++;
          // If we imported into specific folder, move it there
          if (folderId != null) {
             await docService.addFileToFolder(result.importItem!.id, folderId);
          }
        } else {
          failCount++;
          _log.warn('AllDocumentsScreen', 'Failed to import ${file.path}: ${result.errorMessage}');
        }
      } catch (e) {
        failCount++;
        _log.error('AllDocumentsScreen', 'Exception importing ${file.path}', e);
      }
      
      // Update Progress
      completed++;
      progressController.value = completed / total;
      countController.value = '$completed of $total files';
      // Small delay to let UI update
      await Future.delayed(const Duration(milliseconds: 50));
    }
    
    // Close progress dialog
    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    
    _log.info('AllDocumentsScreen', 'Import complete. Success: $successCount, Fail: $failCount');
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported $successCount of $total files${failCount > 0 ? " ($failCount failed)" : ""}'),
          backgroundColor: failCount > 0 ? Colors.orange : Colors.green,
        ),
      );
      
      // Refresh list
      setState(() {
        _isLoading = true;
        _selectedPaths.clear(); 
      });
      _loadDocuments();
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

  IconData _getFileIcon(String name) {
    if (name.toLowerCase().endsWith('.pdf')) return Icons.picture_as_pdf;
    if (name.toLowerCase().contains('.doc')) return Icons.description;
    if (name.toLowerCase().contains('.xls')) return Icons.table_chart;
    return Icons.insert_drive_file;
  }
  
  Color _getFileColor(String name) {
    if (name.toLowerCase().endsWith('.pdf')) return Colors.red;
    if (name.toLowerCase().contains('.doc')) return Colors.blue;
    if (name.toLowerCase().contains('.xls')) return Colors.green;
    return Colors.grey;
  }
  
  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: ListView.builder(
        itemCount: 10,
        itemBuilder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 8,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 40,
                      height: 8,
                      color: Colors.white,
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSortDialog() async {
    final sortOptions = [
      'Date (Newest)',
      'Date (Oldest)',
      'Name (A-Z)',
      'Name (Z-A)',
      'Size (Largest)',
      'Size (Smallest)',
    ];
    
    await showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Sort By'),
        children: sortOptions.map((option) => SimpleDialogOption(
          onPressed: () {
            Navigator.pop(context);
            _applySort(option);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(option),
          ),
        )).toList(),
      ),
    );
  }

  Future<void> _applySort(String sortType) async {
    setState(() {
      _isLoading = true;
      _displayedFiles = [];
      _currentOffset = 0;
      _hasMore = true;
      _selectedPaths.clear();
    });

    try {
      await _deviceService.sortDocuments(sortType);
      
      // Reload first page
       final files = _deviceService.getDocuments(
          offset: 0,
          limit: _pageSize,
          filterType: _selectedFilter,
          searchQuery: _searchQuery,
       );
       
       if (mounted) {
         setState(() {
           _displayedFiles = files;
           _isLoading = false;
           _hasMore = files.length >= _pageSize;
           _currentOffset = files.length;
         });
       }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSelectionMode) {
          setState(() => _selectedPaths.clear());
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search documents...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: _onSearchChanged,
              )
            : (_isSelectionMode 
                ? Text('${_selectedPaths.length} Selected') 
                : const Text('All Documents')),
        leading: _isSearching
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _stopSearch)
            : (_isSelectionMode 
                ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selectedPaths.clear())) 
                : null),
        actions: [
          if (_isSearching)
            IconButton(
              icon: const Icon(Icons.close), 
              onPressed: () {
                 if (_searchController.text.isEmpty) {
                   _stopSearch();
                 } else {
                   _searchController.clear();
                   _onSearchChanged('');
                 }
              }
            ),

          if (!_isSearching && _isSelectionMode)
             IconButton(
               icon: const Icon(Icons.download),
               onPressed: _importSelected,
               tooltip: 'Import Selected',
             ),
             
          if (!_isSearching && !_isSelectionMode) ...[
            IconButton(
               icon: const Icon(Icons.search),
               onPressed: _startSearch,
               tooltip: 'Search',
            ),
            IconButton(
               icon: const Icon(Icons.sort),
               onPressed: _showSortDialog,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                 setState(() => _isLoading = true);
                 _loadDocuments();
              },
              tooltip: 'Refresh',
            ),
          ]
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
                    ? _buildShimmerLoading()
                    : RefreshIndicator(
                        onRefresh: _loadDocuments,
                        child: _displayedFiles.isEmpty
                            ? ListView(
                                children: const [
                                  SizedBox(height: 100),
                                  Center(child: Text('No documents found')),
                                ],
                              )
                            : ListView.builder(
                                controller: _scrollController,
                                itemCount: _displayedFiles.length + (_hasMore ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == _displayedFiles.length) {
                                    return const Padding(
                                      padding: EdgeInsets.all(16.0),
                                      child: Center(child: CircularProgressIndicator()),
                                    );
                                  }
                                  
                                  final file = _displayedFiles[index];
                                  final name = file.path.split('/').last;
                                  final stat = file.statSync();
                                  final date = DateFormat('MMM d, y • H:mm').format(stat.modified);
                                  final size = (stat.size / 1024 / 1024).toStringAsFixed(2);
                                  final isSelected = _selectedPaths.contains(file.path);
                                  
                                  return ListTile(
                                    leading: Stack(
                                      children: [
                                         Icon(_getFileIcon(name), color: _getFileColor(name), size: 32),
                                         if (isSelected)
                                           const Positioned(
                                             bottom: 0,
                                             right: 0,
                                             child: Icon(Icons.check_circle, color: Colors.green, size: 16),
                                           )
                                      ],
                                    ),
                                    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text('$date • $size MB'),
                                    tileColor: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
                                    onTap: () => _handleFileTap(file),
                                    onLongPress: () => _toggleSelection(file.path),
                                    trailing: _isSelectionMode 
                                        ? Checkbox(value: isSelected, onChanged: (v) => _toggleSelection(file.path))
                                        : null,
                                  );
                                },
                              ),
                      ),
          ),
        ],
      ),
      ), // Close Scaffold
    ); // Close PopScope
  }
}


