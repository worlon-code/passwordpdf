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

  /// Import a file (Copy to App Storage + DB)
  /// Returns an ImportResult with path (if imported) or existing location info
  Future<ImportResult> importFile(String sourcePath, String sourceName, {String? targetName, bool allowDuplicate = false}) async {
    try {
      final file = File(sourcePath);
      if (!await file.exists()) return ImportResult.error('Source file not found');

      final srcLen = await file.length();
      final duplicates = <DuplicateInfo>[];

      // 1. Check ALL existing files in app (including folders) for duplicate
      if (!allowDuplicate) {
        for (final item in _items) {
          if (!item.isFile || item.filePath == null) continue;
          
          // Check by Content (Size)
          final existingFile = File(item.filePath!);
          if (await existingFile.exists()) {
             final existingLen = await existingFile.length();
             if (srcLen == existingLen) {
                 // Found exact duplicate in app
                 String? folderPath = _getFolderPathForItem(item.id);
                 duplicates.add(DuplicateInfo(
                    sourcePath: sourcePath,
                    fileName: sourceName,
                    existingFolderName: folderPath,
                    existingFolderId: _getFolderIdForItem(item.id),
                    existingFilePath: item.filePath!,
                    existingName: item.name,
                 ));
              }
            }
          }
        
        if (duplicates.isNotEmpty) {
           final first = duplicates.first;
           _log.info('DocumentService', 'File already exists: $sourceName in ${duplicates.length} locations');
           return ImportResult.duplicate(first.existingFilePath, first.existingFolderName, first.existingFolderId, duplicates: duplicates);
        }
      }

      // 2. Get App Documents Directory
      final appDir = await getApplicationDocumentsDirectory();
      final documentsDir = Directory('${appDir.path}/documents');
      if (!documentsDir.existsSync()) {
        documentsDir.createSync(recursive: true);
      }

      // 3. Generate Unique Name (Safe Copy) if collision on filesystem
      String fileName = targetName ?? sourceName;
      String newPath = '${documentsDir.path}/$fileName';
      
      int copyCount = 0;
      while (File(newPath).existsSync()) {
        copyCount++;
        final parts = sourceName.split('.');
        if (parts.length > 1) {
           final ext = parts.last;
           final name = parts.sublist(0, parts.length - 1).join('.');
           fileName = '${name}_$copyCount.$ext';
        } else {
           fileName = '${sourceName}_$copyCount';
        }
        newPath = '${documentsDir.path}/$fileName';
      }

      // 4. Copy File
      await file.copy(newPath);
      
      // 5. Add to DB (Unorganized)
      final newItem = await addFile(newPath, customName: fileName);
      
      _log.info('DocumentService', 'Imported file: $sourceName as $fileName');
      return ImportResult.success(newPath, newItem);
    } catch (e) {
      _log.error('DocumentService', 'Import failed', e);
      return ImportResult.error(e.toString());
    }
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
      // Check against ALL files in _items
      for (final item in _items) {
        if (!item.isFile || item.filePath == null) continue;
        
        // Remove name check - check content only (Size)
        final existingFile = File(item.filePath!);
        if (await existingFile.exists()) {
          final existingSize = await existingFile.length();
          if (fileSize == existingSize) {
            // Found duplicate (content match by size)
            duplicates.add(DuplicateInfo(
              sourcePath: path,
              fileName: fileName,
              existingFolderName: _getFolderPathForItem(item.id),
              existingFolderId: _getFolderIdForItem(item.id),
              existingFilePath: item.filePath!,
              existingName: item.name,
            ));
          }
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
  Future<DocumentItem> addFile(String filePath, {String? folderId, String? customName}) async {
    final fileName = customName ?? filePath.split(RegExp(r'[/\\]')).last;
    final file = DocumentItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: fileName,
      type: DocumentItemType.file,
      filePath: filePath,
    );
    
    _items.add(file);
    
    // Add to folder if specified
    if (folderId != null) {
      await addFileToFolder(file.id, folderId);
    }
    
    await _saveDocuments();
    _log.info('DocumentService', 'Added file: $fileName');
    
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
  Future<void> moveFolderToFolder(String folderId, String newParentId) async {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex == -1) {
      throw Exception('Folder not found');
    }
    
    final folder = _items[folderIndex];
    if (!folder.isFolder) {
      throw Exception('Item is not a folder');
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
  Future<void> moveFolderToRoot(String folderId) async {
    final folderIndex = _items.indexWhere((item) => item.id == folderId);
    if (folderIndex == -1) {
      throw Exception('Folder not found');
    }
    
    final folder = _items[folderIndex];
    _items[folderIndex] = folder.copyWith(clearParentId: true);
    
    await _saveDocuments();
    _log.info('DocumentService', 'Moved folder ${folder.name} to root');
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

  /// Rename item
  Future<void> renameItem(String itemId, String newName) async {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index != -1) {
      _items[index] = _items[index].copyWith(name: newName);
      await _saveDocuments();
      _log.info('DocumentService', 'Renamed item to: $newName');
    }
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
