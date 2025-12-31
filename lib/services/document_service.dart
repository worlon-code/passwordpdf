import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/document_item_model.dart';
import './logging_service.dart';

/// Service for managing document folders and files
class DocumentService {
  static final DocumentService _instance = DocumentService._internal();
  factory DocumentService() => _instance;
  DocumentService._internal();

  final LoggingService _log = LoggingService();
  SharedPreferences? _prefs;
  
  static const String _documentsKey = 'documents_items';
  final List<DocumentItem> _items = [];

  /// Initialize service
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadDocuments();
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
      for (final subfolder in subfolders) {
        await deleteItem(subfolder.id);
      }
      
      _log.info('DocumentService', 'Cascade deleted folder contents: ${item.name}');
    }
    
    // Now delete the item itself
    _items.removeWhere((i) => i.id == itemId);
    
    // Clean up any references in parent folders
    for (final folder in getFolders()) {
      if (folder.fileIds.contains(itemId)) {
        final index = _items.indexWhere((i) => i.id == folder.id);
        if (index != -1) {
          final newFileIds = folder.fileIds.where((id) => id != itemId).toList();
          _items[index] = folder.copyWith(fileIds: newFileIds);
        }
      }
    }
    
    await _saveDocuments();
    _log.info('DocumentService', 'Deleted item: ${item.name}');
  }

  /// Rename item
  Future<void> renameItem(String itemId, String newName) async {
    final index = _items.indexWhere((item) => item.id == itemId);
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
