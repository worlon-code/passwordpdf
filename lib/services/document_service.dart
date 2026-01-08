import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import '../models/document_item_model.dart';
import './logging_service.dart';

/// Result of a file import operation
class ImportResult {
  final bool success;
  final bool isDuplicate;
  final String? importedPath;
  final DocumentItem? importItem; // Added
  final String? existingFolderName;
  final String? existingFolderId;
  final String? errorMessage;
  final List<DuplicateInfo>? duplicates;

  ImportResult._({
    required this.success,
    this.isDuplicate = false,
    this.importedPath,
    this.importItem,
    this.existingFolderName,
    this.existingFolderId,
    this.errorMessage,
    this.duplicates,
  });

  factory ImportResult.success(String path, DocumentItem item) => ImportResult._(success: true, importedPath: path, importItem: item);
  factory ImportResult.duplicate(String path, String? folderName, String? folderId, {List<DuplicateInfo>? duplicates}) => 
      ImportResult._(success: false, isDuplicate: true, importedPath: path, existingFolderName: folderName, existingFolderId: folderId, duplicates: duplicates);
  factory ImportResult.error(String message) => ImportResult._(success: false, errorMessage: message);
}

/// Information about a duplicate file found in the app
class DuplicateInfo {
  final String sourcePath;
  final String fileName;
  final String? existingFolderName; // null = Unorganized
  final String? existingFolderId;
  final String existingFilePath; // Added for direct opening
  final String existingName;

  DuplicateInfo({
    required this.sourcePath,
    required this.fileName,
    this.existingFolderName,
    this.existingFolderId,
    required this.existingFilePath,
    required this.existingName,
  });
  
  String get locationDisplay => existingFolderName ?? 'Unorganized Files';
}

/// Service for managing document folders and files
class DocumentService {
  static final DocumentService _instance = DocumentService._internal();
  factory DocumentService() => _instance;
  DocumentService._internal();

  final LoggingService _log = LoggingService();
  SharedPreferences? _prefs;
  
  static const String _documentsKey = 'documents_items';
  final List<DocumentItem> _items = [];

  // Need path provider to persist copies
  // We assume main.dart/UI passes us valid paths, but we need to import: 
  // 'package:path_provider/path_provider.dart';
  // and 'dart:io';

  /// Initialize service
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadDocuments();
  }

  /// [ZERO COPY] Add a reference to a file without copying it
  /// Stores the original device path directly. No file copy is made.
  /// Returns an ImportResult with the item (if added) or duplicate info
  Future<ImportResult> addReference(String originalPath, String fileName, {bool allowDuplicate = false, String? folderId}) async {
    try {
      final file = File(originalPath);
      if (!await file.exists()) return ImportResult.error('File not found at path');

      final srcLen = await file.length();
      final duplicates = <DuplicateInfo>[];

      // 1. Check for duplicates by path or content size
      if (!allowDuplicate) {
        for (final item in _items) {
          if (!item.isFile || item.sourcePath == null) continue;
          
          // Check exact path match first
          if (item.sourcePath == originalPath) {
            return ImportResult.duplicate(item.sourcePath!, _getFolderPathForItem(item.id), _getFolderIdForItem(item.id), duplicates: [
              DuplicateInfo(
                sourcePath: originalPath,
                fileName: fileName,
                existingFolderName: _getFolderPathForItem(item.id),
                existingFolderId: _getFolderIdForItem(item.id),
                existingFilePath: item.sourcePath!,
                existingName: item.name,
              )
            ]);
          }
          
          // Check by content size (same file, different path)
          final existingFile = File(item.sourcePath!);
          if (await existingFile.exists()) {
            final existingLen = await existingFile.length();
            if (srcLen == existingLen) {
              duplicates.add(DuplicateInfo(
                sourcePath: originalPath,
                fileName: fileName,
                existingFolderName: _getFolderPathForItem(item.id),
                existingFolderId: _getFolderIdForItem(item.id),
                existingFilePath: item.sourcePath!,
                existingName: item.name,
              ));
            }
          }
        }
        
        if (duplicates.isNotEmpty) {
          final first = duplicates.first;
          _log.info('DocumentService', 'File already referenced: $fileName in ${duplicates.length} locations');
          return ImportResult.duplicate(first.existingFilePath, first.existingFolderName, first.existingFolderId, duplicates: duplicates);
        }
      }

      // 2. Get file stats for metadata
      final stat = await file.stat();
      
      // 3. Add reference to DB (store ORIGINAL path, no copy)
      final newItem = await addFile(
        originalPath,  // Store original path, NOT a copy
        customName: fileName,
        createdAt: stat.accessed,
        modifiedAt: stat.modified,
        folderId: folderId,
      );
      
      _log.info('DocumentService', '[ZERO COPY] Added reference: $fileName -> $originalPath');
      return ImportResult.success(originalPath, newItem);
    } catch (e) {
      _log.error('DocumentService', 'Add reference failed', e);
      return ImportResult.error(e.toString());
    }
  }

  /// Sync all imported folders
  Future<void> syncAllFolders() async {
    _log.info('DocumentService', 'Starting Auto-Sync...');
    final folders = _items.where((i) => i.isFolder && i.isImported && i.sourcePath != null).toList();
    for (final folder in folders) {
        await syncFolder(folder.id);
    }
    _log.info('DocumentService', 'Auto-Sync Completed');
  }

  /// Sync specific folder with its source path
  /// Returns true if sync successful, false if failed
  Future<bool> syncFolder(String folderId) async {
    final folderIndex = _items.indexWhere((i) => i.id == folderId);
    if (folderIndex == -1) {
      _log.error('DocumentService', 'Sync failed: Folder not found with ID $folderId');
      return false;
    }
    final folder = _items[folderIndex];
    
    if (folder.sourcePath == null) {
      _log.error('DocumentService', 'Sync failed: Folder ${folder.name} has no sourcePath');
      return false;
    }
    
    final dir = Directory(folder.sourcePath!);
    if (!await dir.exists()) {
      _log.error('DocumentService', 'Sync failed: Source directory not found: ${folder.sourcePath}');
      return false; // Source folder deleted?
    }
    
    _log.info('DocumentService', 'Syncing folder: ${folder.name}');
    
    try {
        final entities = await dir.list(recursive: false, followLinks: false).toList();
        
        // 1. Sync Files/Folders from Disk to App
        // Special case: Download folder should only sync files, not subfolders
        final isDownloadFolder = folder.name.toLowerCase() == 'download';
        
        _log.info('DocumentService', 'Sync: Processing ${entities.length} entities in ${folder.name} (isDownload: $isDownloadFolder)');
        
        for (final entity in entities) {
            final name = entity.path.split(Platform.pathSeparator).last;
            
            // Skip subdirectories for Download folder
            if (isDownloadFolder && entity is Directory) {
                _log.info('DocumentService', '[Sync] Step: SKIP - Subfolder in Download: $name');
                continue;
            }
            
            // Check if already in App globally
            final existingIndex = _items.indexWhere((i) => i.sourcePath == entity.path);
            
            _log.info('DocumentService', '[Sync] Step: CHECK - $name -> existingIndex: $existingIndex');
            
            if (existingIndex != -1) {
                // Item exists in App
                final existingItem = _items[existingIndex];
                
                _log.info('DocumentService', '[Sync] Step: FOUND - ${existingItem.name} in parentId=${existingItem.parentId}, expected=$folderId');
                
                // Enforce Structure: If it belongs to this imported folder, ensure it's inside it
                if (existingItem.parentId != folderId) {
                    _log.info('DocumentService', '[Sync] Step: MOVE - Moving ${existingItem.name} back to ${folder.name}');
                    try {
                        if (existingItem.isFolder) {
                            await moveFolderToFolder(existingItem.id, folderId);
                        } else {
                            await moveFilesToFolder([existingItem.id], folderId);
                        }
                        _log.info('DocumentService', '[Sync] Step: MOVE_DONE - ${existingItem.name}');
                    } catch (moveError, moveStack) {
                        _log.error('DocumentService', '[Sync] Step: MOVE_FAILED - ${existingItem.name}: $moveError\n$moveStack', moveError);
                        rethrow;
                    }
                }
                
                // Recursion for Subfolders (but not for Download folder)
                if (!isDownloadFolder && existingItem.isFolder && existingItem.isImported) {
                    _log.info('DocumentService', '[Sync] Step: RECURSE - Into subfolder ${existingItem.name}');
                    await syncFolder(existingItem.id);
                }
                
            } else {
                // New Item found on Disk -> Import it
                _log.info('DocumentService', '[Sync] Step: NEW - $name (isDir: ${entity is Directory})');
                
                if (entity is Directory) {
                     // Check if folder with this name already exists in the parent (by name, not sourcePath)
                     _log.info('DocumentService', '[Sync] Step: CHECK_FOLDER_BY_NAME - $name in parent $folderId');
                     final existingByName = _items.where((i) => 
                         i.isFolder && 
                         i.parentId == folderId && 
                         i.name == name
                     ).toList();
                     
                     DocumentItem targetFolder;
                     
                     if (existingByName.isNotEmpty) {
                         // Folder exists by name but without matching sourcePath - use it
                         targetFolder = existingByName.first;
                         _log.info('DocumentService', '[Sync] Step: FOLDER_EXISTS_BY_NAME - $name (id=${targetFolder.id}), updating sourcePath');
                     } else {
                         // Create new folder
                         _log.info('DocumentService', '[Sync] Step: CREATE_FOLDER_START - $name');
                         try {
                             targetFolder = await createFolder(name, parentId: folderId);
                             _log.info('DocumentService', '[Sync] Step: CREATE_FOLDER_DONE - $name with id=${targetFolder.id}');
                         } catch (createError, createStack) {
                             _log.error('DocumentService', '[Sync] Step: CREATE_FOLDER_FAILED - $name: $createError\n$createStack', createError);
                             rethrow;
                         }
                     }
                     
                     // Set/Update Source Path & Imported flag
                     _log.info('DocumentService', '[Sync] Step: SET_SOURCE_PATH_START - ${targetFolder.id} -> ${entity.path}');
                     try {
                         await updateFolderSourcePath(targetFolder.id, entity.path);
                         _log.info('DocumentService', '[Sync] Step: SET_SOURCE_PATH_DONE - ${targetFolder.id}');
                     } catch (pathError, pathStack) {
                         _log.error('DocumentService', '[Sync] Step: SET_SOURCE_PATH_FAILED - ${targetFolder.id}: $pathError\n$pathStack', pathError);
                         rethrow;
                     }
                     
                     // Recurse
                     _log.info('DocumentService', '[Sync] Step: RECURSE_NEW - Into subfolder $name');
                     await syncFolder(targetFolder.id);
                } else if (entity is File) {
                     // Check extension
                     final ext = name.split('.').last.toLowerCase();
                     if (['pdf', 'doc', 'docx', 'xls', 'xlsx'].contains(ext)) {
                         _log.info('DocumentService', '[Sync] Step: ADD_FILE_START - $name to folder $folderId');
                         try {
                             final result = await addReference(entity.path, name, folderId: folderId, allowDuplicate: true);
                             _log.info('DocumentService', '[Sync] Step: ADD_FILE_DONE - $name: success=${result.success}, error=${result.errorMessage}');
                         } catch (fileError, fileStack) {
                             _log.error('DocumentService', '[Sync] Step: ADD_FILE_FAILED - $name: $fileError\n$fileStack', fileError);
                             rethrow;
                         }
                     } else {
                         _log.info('DocumentService', '[Sync] Step: SKIP_EXT - $name (unsupported: $ext)');
                     }
                }
            }
        }
        
        // 2. Handle Deleted Files? - Skipped for safety
        _log.info('DocumentService', '[Sync] Step: COMPLETE - All entities processed for ${folder.name}');
        
    } catch (e, stackTrace) {
        _log.error('DocumentService', '[Sync] FAILED for ${folder.name}: $e\nStack trace:\n$stackTrace', e);
        return false;
    }
    
    _log.info('DocumentService', '[Sync] SUCCESS - ${folder.name}');
    return true;
  }

  /// @deprecated Use addReference instead for Zero Copy architecture
  /// Import a file (Copy to App Storage + DB) - LEGACY
  Future<ImportResult> importFile(String sourcePath, String sourceName, {String? targetName, bool allowDuplicate = false}) async {
    // Redirect to Zero Copy addReference
    _log.info('DocumentService', '[LEGACY] importFile called, redirecting to addReference');
    return addReference(sourcePath, targetName ?? sourceName, allowDuplicate: allowDuplicate);
  }

  /// Get folder path string for an item
  String? _getFolderPathForItem(String itemId) {
    // Find which folder contains this file
    for (final folder in getFolders()) {
      if (folder.fileIds.contains(itemId)) {
        return folder.name;
      }
    }
    return null; // Unorganized
  }

  /// Get folder ID for an item
  String? _getFolderIdForItem(String itemId) {
    for (final folder in getFolders()) {
      if (folder.fileIds.contains(itemId)) {
        return folder.id;
      }
    }
    return null;
  }

  /// Check for duplicates across ALL folders (for Add Files feature)
  Future<List<DuplicateInfo>> checkForDuplicates(List<String> filePaths) async {
    final duplicates = <DuplicateInfo>[];
    
    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      
      final fileName = path.split(RegExp(r'[/\\]')).last;
      final fileSize = await file.length();
      
      // Check against ALL files in _items
      for (final item in _items) {
        if (!item.isFile || item.sourcePath == null) continue;
        
        // Optimize: Use cached size if available
        int existingSize = item.size;
        
        if (existingSize == 0) {
           // Fallback for legacy items (no size in DB)
           final existingFile = File(item.sourcePath!);
           if (await existingFile.exists()) {
             existingSize = await existingFile.length();
           } else {
             continue; // File not found on disk, skip
           }
        }
        
        if (fileSize == existingSize) {
            // Found duplicate (content match by size)
            duplicates.add(DuplicateInfo(
              sourcePath: path,
              fileName: fileName,
              existingFolderName: _getFolderPathForItem(item.id),
              existingFolderId: _getFolderIdForItem(item.id),
              existingFilePath: item.sourcePath!,
              existingName: item.name,
            ));
        }
      }
    }
    
    return duplicates;
  }

  /// Get all items
  List<DocumentItem> getAllItems() => List.unmodifiable(_items);

  /// Get all folders
  List<DocumentItem> getFolders() {
    return _items.where((item) => item.isFolder).toList();
  }

  /// Get root-level folders (no parent)
  List<DocumentItem> getRootFolders() {
    return _items.where((item) => item.isFolder && item.parentId == null).toList();
  }

  /// Get subfolders of a folder
  List<DocumentItem> getSubfolders(String folderId) {
    return _items.where((item) => item.isFolder && item.parentId == folderId).toList();
  }

  /// Get files in a folder
  List<DocumentItem> getFilesInFolder(String folderId) {
    final folder = _items.firstWhere(
      (item) => item.id == folderId,
      orElse: () => throw Exception('Folder not found'),
    );
    
    return _items
        .where((item) => item.isFile && folder.fileIds.contains(item.id))
        .toList();
  }

  // Helper to check collision in specific folder (for overwrite/skip logic)
  String? getFileIdInFolder(String fileName, String? folderId) {
    for (final item in _items) {
      if (!item.isFile) continue;
      // Check parent folder matching
      final itemFolderId = _getFolderIdForItem(item.id);
      if (itemFolderId == folderId && item.name.toLowerCase() == fileName.toLowerCase()) {
        return item.id;
      }
    }
    return null;
  }
  
  /// Find file ID by absolute path
  String? findFileIdByPath(String path) {
    try {
      final item = _items.firstWhere((item) => item.sourcePath == path);
      return item.id;
    } catch (_) {
      return null;
    }
  }

  /// Find folder by source path
  DocumentItem? getFolderBySourcePath(String sourcePath) {
    try {
      return _items.firstWhere((item) => item.isFolder && item.sourcePath == sourcePath);
    } catch (_) {
      return null;
    }
  }

  /// Get files not in any folder
  List<DocumentItem> getUnorganizedFiles() {
    final filesInFolders = <String>{};
    for (final folder in getFolders()) {
      filesInFolders.addAll(folder.fileIds);
    }
    
    return _items
        .where((item) => item.isFile && !filesInFolders.contains(item.id))
        .toList();
  }

  /// Create a folder
  Future<DocumentItem> createFolder(String name, {String? parentId}) async {
    // Check for duplicate folder name
    final exists = _items.any((item) => 
      item.isFolder && 
      item.parentId == parentId && 
      item.name.toLowerCase() == name.toLowerCase()
    );

    if (exists) {
      throw Exception('Folder "$name" already exists');
    }

    final folder = DocumentItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      type: DocumentItemType.folder,
      parentId: parentId,
    );
    
    _items.add(folder);
    await _saveDocuments();
    _log.info('DocumentService', 'Created folder: $name${parentId != null ? ' in folder $parentId' : ''}');
    
    return folder;
  }

  /// Add file
  Future<DocumentItem> addFile(String filePath, {String? folderId, String? customName, DateTime? createdAt, DateTime? modifiedAt}) async {
    final fileName = customName ?? filePath.split(RegExp(r'[/\\]')).last;
    final fileObj = File(filePath);
    final size = fileObj.existsSync() ? await fileObj.length() : 0;
    
    // Default to current time if not provided
    // BUT for imported files, we want to respect the original file's dates if possible
    final now = DateTime.now();
    
    final file = DocumentItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: fileName,
      type: DocumentItemType.file,
      sourcePath: filePath,
      size: size,
      createdAt: createdAt ?? now,
      modifiedAt: modifiedAt ?? now,
    );
    
    _items.add(file);
    
    // Add to folder if specified
    if (folderId != null) {
      await addFileToFolder(file.id, folderId);
    }
    
    await _saveDocuments();
    _log.info('DocumentService', 'Added file: $fileName (size: $size)');
    
    return file;
  }

  /// Add file to folder
  Future<void> addFileToFolder(String fileId, String folderId) async {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex == -1) {
      throw Exception('Folder not found');
    }
    
    final folder = _items[folderIndex];
    if (!folder.fileIds.contains(fileId)) {
      _items[folderIndex] = folder.copyWith(
        fileIds: [...folder.fileIds, fileId],
      );
      await _saveDocuments();
      _log.info('DocumentService', 'Added file to folder');
    }
  }

  /// Remove file from folder
  Future<void> removeFileFromFolder(String fileId, String folderId) async {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex == -1) {
      throw Exception('Folder not found');
    }
    
    final folder = _items[folderIndex];
    final newFileIds = folder.fileIds.where((id) => id != fileId).toList();
    _items[folderIndex] = folder.copyWith(fileIds: newFileIds);
    
    await _saveDocuments();
    _log.info('DocumentService', 'Removed file from folder');
  }

  /// Move files to folder
  Future<void> moveFilesToFolder(List<String> fileIds, String folderId) async {
    // Remove from other folders first
    for (final folder in getFolders()) {
      final newFileIds = folder.fileIds
          .where((id) => !fileIds.contains(id))
          .toList();
      if (newFileIds.length != folder.fileIds.length) {
        final index = _items.indexWhere((item) => item.id == folder.id);
        _items[index] = folder.copyWith(fileIds: newFileIds);
      }
    }
    
    // Add to new folder
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex != -1) {
      final folder = _items[folderIndex];
      final existingIds = Set<String>.from(folder.fileIds);
      existingIds.addAll(fileIds);
      _items[folderIndex] = folder.copyWith(fileIds: existingIds.toList());
    }
    
    await _saveDocuments();
    _log.info('DocumentService', 'Moved ${fileIds.length} files to folder');
  }

  /// Move a folder to another folder (updates parentId)
  /// Throws exception if name conflict with imported folder at destination
  Future<void> moveFolderToFolder(String folderId, String newParentId) async {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex == -1) {
      throw Exception('Folder not found');
    }
    
    final folder = _items[folderIndex];
    if (!folder.isFolder) {
      throw Exception('Item is not a folder');
    }
    
    // Check for name conflict at destination
    final conflictingFolder = _items.where((item) =>
        item.isFolder &&
        item.parentId == newParentId &&
        item.name == folder.name &&
        item.id != folderId
    ).toList();
    
    if (conflictingFolder.isNotEmpty) {
        final existing = conflictingFolder.first;
        if (existing.isImported) {
            // Imported folder has priority - cannot move here with same name
            throw Exception('Cannot move: An imported folder "${folder.name}" already exists at this location. Please rename your folder first.');
        } else if (folder.isImported) {
            // Moving imported folder to location with manual folder - manual should be renamed
            throw Exception('Cannot move: A folder "${folder.name}" already exists at this location. Please rename the existing folder first.');
        } else {
            // Both are manual - just prevent duplicate
            throw Exception('Cannot move: A folder "${folder.name}" already exists at this location.');
        }
    }
    
    // Update the parentId
    _items[folderIndex] = folder.copyWith(parentId: newParentId);
    
    await _saveDocuments();
    _log.info('DocumentService', 'Moved folder ${folder.name} to folder $newParentId');
  }

  /// Move files to root (remove from all folders)
  Future<void> moveFilesToRoot(List<String> fileIds) async {
    // Remove from all folders
    for (final folder in getFolders()) {
      final newFileIds = folder.fileIds
          .where((id) => !fileIds.contains(id))
          .toList();
      if (newFileIds.length != folder.fileIds.length) {
        final index = _items.indexWhere((item) => item.id == folder.id);
        _items[index] = folder.copyWith(fileIds: newFileIds);
      }
    }
    
    await _saveDocuments();
    _log.info('DocumentService', 'Moved ${fileIds.length} files to root');
  }

  /// Move a folder to root (set parentId to null)
  /// Throws exception if name conflict with imported folder at root
  Future<void> moveFolderToRoot(String folderId) async {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex == -1) {
      throw Exception('Folder not found');
    }
    
    final folder = _items[folderIndex];
    
    // Check for name conflict at root (parentId = null)
    final conflictingFolder = _items.where((item) =>
        item.isFolder &&
        item.parentId == null &&
        item.name == folder.name &&
        item.id != folderId
    ).toList();
    
    if (conflictingFolder.isNotEmpty) {
        final existing = conflictingFolder.first;
        if (existing.isImported) {
            throw Exception('Cannot move: An imported folder "${folder.name}" already exists at root. Please rename your folder first.');
        } else if (folder.isImported) {
            throw Exception('Cannot move: A folder "${folder.name}" already exists at root. Please rename the existing folder first.');
        } else {
            throw Exception('Cannot move: A folder "${folder.name}" already exists at root.');
        }
    }
    
    _items[folderIndex] = folder.copyWith(clearParentId: true);
    
    await _saveDocuments();
    _log.info('DocumentService', 'Moved folder ${folder.name} to root');
  }

  /// Rename item
  Future<void> renameItem(String itemId, String newName) async {
    final index = _items.indexWhere((item) => item.id == itemId);
    if (index == -1) return;
    
    _items[index] = _items[index].copyWith(name: newName);
    await _saveDocuments();
    _log.info('DocumentService', 'Renamed item $itemId to $newName');
  }

  /// Update folder source path (for Sync)
  Future<void> updateFolderSourcePath(String folderId, String sourcePath) async {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex == -1) return;
    
    final folder = _items[folderIndex];
    if (!folder.isFolder) return;
    
    _items[folderIndex] = folder.copyWith(sourcePath: sourcePath, isImported: true);
    await _saveDocuments();
    _log.info('DocumentService', 'Updated folder source path: $sourcePath (isImported=true)');
  }

  /// Delete item (recursively deletes folder contents)
  Future<void> deleteItem(String itemId) async {
    final item = _items.firstWhere(
      (i) => i.id == itemId,
      orElse: () => DocumentItem(id: '', name: '', type: DocumentItemType.file),
    );
    
    if (item.id.isEmpty) return;
    
    // If it's a folder, recursively delete all contents first
    if (item.isFolder) {
      // Delete all files in this folder
      final filesInFolder = getFilesInFolder(itemId);
      for (final file in filesInFolder) {
        _items.removeWhere((i) => i.id == file.id);
      }
      
      // Recursively delete subfolders
      final subfolders = getSubfolders(itemId);
      for (final sub in subfolders) {
        await deleteItem(sub.id);
      }
      
      _log.info('DocumentService', 'Cascade deleted folder contents: ${item.name}');
    }
    
    // Remove the item itself
    _items.removeWhere((i) => i.id == itemId);
    
    // If it was a file, remove its ID from any folder containing it
    if (item.isFile) {
      for (int i = 0; i < _items.length; i++) {
        if (_items[i].isFolder && _items[i].fileIds.contains(itemId)) {
          final newIds = _items[i].fileIds.where((id) => id != itemId).toList();
          _items[i] = _items[i].copyWith(fileIds: newIds);
        }
      }
    }
    
    await _saveDocuments();
    _log.info('DocumentService', 'Deleted item: ${item.name}');
  }



  /// Load documents from storage
  Future<void> _loadDocuments() async {
    try {
      final String? jsonString = _prefs?.getString(_documentsKey);
      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        _items.clear();
        _items.addAll(
          jsonList.map((json) => DocumentItem.fromJson(json)).toList(),
        );
        _log.info('DocumentService', 'Loaded ${_items.length} items');
      }
    } catch (e) {
      _log.error('DocumentService', 'Failed to load documents', e);
    }
  }

  /// Save documents to storage
  Future<void> _saveDocuments() async {
    try {
      final jsonList = _items.map((item) => item.toJson()).toList();
      final jsonString = json.encode(jsonList);
      await _prefs?.setString(_documentsKey, jsonString);
      _log.debug('DocumentService', 'Saved ${_items.length} items');
    } catch (e) {
      _log.error('DocumentService', 'Failed to save documents', e);
    }
  }

  /// Clear all documents
  Future<void> clearAll() async {
    _items.clear();
    await _prefs?.remove(_documentsKey);
    _log.info('DocumentService', 'Cleared all documents');
  }
}
