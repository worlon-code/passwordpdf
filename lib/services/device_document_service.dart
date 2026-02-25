import 'dart:io';
import 'dart:isolate';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';
import '../services/logging_service.dart';
import '../services/storage_service.dart';
import '../core/constants/app_constants.dart';
import '../features/common/models/sort_option.dart';

class DeviceDocumentService {
  final StorageService _storage = StorageService();
  bool _isScanning = false;
  final LoggingService _log = LoggingService();

  /// Request necessary permissions to scan storage
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 30) {
        // Android 11+
        final status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          final result = await Permission.manageExternalStorage.request();
          return result.isGranted;
        }
        return true;
      } else {
        // Android 10 and below
        final status = await Permission.storage.status;
        if (!status.isGranted) {
          final result = await Permission.storage.request();
          return result.isGranted;
        }
        return true;
      }
    }
    return false;
  }

  SortOption _currentSortOption = SortOption.dateModified;
  bool _currentSortAscending = false;

  /// Scans the device and syncs with local database
  Future<void> syncAndIndex() async {
    if (_isScanning) return;
    _isScanning = true;
    _log.info('DeviceDocumentService', 'Starting DB Sync & Index');

    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        _log.warn('DeviceDocumentService', 'Scanner permission denied');
        throw Exception('Storage permissions denied');
      }

      // 1. Scan filesystem (Isolate)
      final startTime = DateTime.now();
      final scannedFiles = await Isolate.run(_scanIsolate);
      final scanDuration = DateTime.now().difference(startTime).inMilliseconds;
      _log.info('DeviceDocumentService', 'FS Scan complete. Found ${scannedFiles.length} files in ${scanDuration}ms');

      // 2. Sync to DB (Mark and Sweep)
      await _syncToDatabase(scannedFiles);
      
    } catch (e) {
      _log.error('DeviceDocumentService', 'Sync failed', e);
      rethrow;
    } finally {
      _isScanning = false;
    }
  }

  /// Wrapper for compatibility
  Future<void> scanDevice() async => syncAndIndex();

  Future<void> _syncToDatabase(List<FileSystemEntity> files) async {
      final db = await _storage.database;
      final syncTime = DateTime.now().millisecondsSinceEpoch;
      
      _log.info('DeviceDocumentService', 'Batch inserting/updating ${files.length} records...');
      
      // 1. Pre-calculate folder content flags
      final Set<String> pdfFolders = {};
      final Set<String> docFolders = {};
      final Set<String> excelFolders = {};
      
      void markParents(String path, Set<String> set) {
        try {
          // Start from parent of the file
          var parentPath = Directory(path).parent.path;
          
          // Propagate up until root
          while (parentPath.length >= '/storage/emulated/0'.length && parentPath.startsWith('/storage/emulated/0')) {
             if (set.contains(parentPath)) break; // optimization: already marked this branch
             set.add(parentPath);
             parentPath = Directory(parentPath).parent.path;
          }
        } catch (_) {}
      }

      for (final file in files) {
        if (file is File) {
          final ext = file.path.split('.').last.toLowerCase();
          if (ext == 'pdf') {
             markParents(file.path, pdfFolders);
          } else if (['doc', 'docx'].contains(ext)) {
             markParents(file.path, docFolders);
          } else if (['xls', 'xlsx'].contains(ext)) {
             markParents(file.path, excelFolders);
          }
        }
      }
      
      // Track folders we've already ensured in this batch to avoid duplicates in the batch command list
      final Set<String> processedParents = {};

      // Pre-fetch existing file stats to optimize updates
      final Map<String, int> existingFiles = {}; // path -> modified_at
      try {
         final existingRows = await db.query(
            AppConstants.filesIndexTable, 
            columns: ['path', 'modified_at']
         );
         for (final row in existingRows) {
            existingFiles[row['path'] as String] = row['modified_at'] as int;
         }
      } catch (_) {}

      await db.transaction((txn) async {
         final batch = txn.batch();
         
         for (final file in files) {
            try {
              final stat = file.statSync(); 
              // ... (rest of vars)
              final name = file.path.split('/').last;
              
              String ext = '';
              String parent = file.parent.path;
              int isFolder = 0;
              
              if (file is Directory) {
                 isFolder = 1;
              } else {
                 ext = name.split('.').last.toLowerCase();
              }
              
              // Get flags
              int hasPdf = pdfFolders.contains(file.path) ? 1 : 0;
              int hasDoc = docFolders.contains(file.path) ? 1 : 0;
              int hasExcel = excelFolders.contains(file.path) ? 1 : 0;

              // Check if file is modified or new
              final lastMod = existingFiles[file.path];
              final currentMod = stat.modified.millisecondsSinceEpoch;
              // final isModified = lastMod == null || lastMod != currentMod; // Unused without Trigrams

              batch.insert(
                AppConstants.filesIndexTable,
                {
                  'path': file.path,
                  'name': name,
                  'extension': ext,
                  'parent_path': parent,
                  'size': stat.size,
                  'created_at': stat.changed.millisecondsSinceEpoch,
                  'modified_at': currentMod,
                  'last_scanned': syncTime,
                  'is_folder': isFolder,
                  'has_pdf': hasPdf,
                  'has_doc': hasDoc,
                  'has_excel': hasExcel
                },
                conflictAlgorithm: ConflictAlgorithm.replace
              );

              // Phase 1.10: Trigrams REMOVED (In-Memory Search used instead)
              // No extra table inserts needed here.
              
              // RECURSIVE FOLDER ASSURANCE
              String currentParentPath = file.parent.path;
              while (currentParentPath.length > '/storage/emulated/0'.length && currentParentPath.startsWith('/storage/emulated/0')) {
                  if (processedParents.contains(currentParentPath)) {
                       currentParentPath = Directory(currentParentPath).parent.path;
                       continue;
                  }
                  
                  final parentName = currentParentPath.split('/').last;
                  final grandParentPath = Directory(currentParentPath).parent.path;
                  
                  int pHasPdf = pdfFolders.contains(currentParentPath) ? 1 : 0;
                  int pHasDoc = docFolders.contains(currentParentPath) ? 1 : 0;
                  int pHasExcel = excelFolders.contains(currentParentPath) ? 1 : 0;
                  
                  batch.insert(
                    AppConstants.filesIndexTable,
                    {
                      'path': currentParentPath,
                      'name': parentName,
                      'extension': '',
                      'parent_path': grandParentPath,
                      'size': 0,
                      'created_at': syncTime, 
                      'modified_at': syncTime,
                      'last_scanned': syncTime,
                      'is_folder': 1,
                      'has_pdf': pHasPdf,
                      'has_doc': pHasDoc,
                      'has_excel': pHasExcel
                    },
                    conflictAlgorithm: ConflictAlgorithm.ignore 
                  );
                  processedParents.add(currentParentPath);
                  
                  currentParentPath = grandParentPath;
              }

            } catch (e) {
               // Skip file if stat fails
            }
         }
         
         await batch.commit(noResult: true);
         
         // Sweep: Delete old records
         final deleted = await txn.delete(
            AppConstants.filesIndexTable, 
            where: 'last_scanned < ?', 
            whereArgs: [syncTime]
         );
         _log.info('DeviceDocumentService', 'Sync complete. Removed $deleted stale records.');
      });
      
      // Update Cache for In-Memory Search
      await _refreshSearchCache();
  }

  // --- In-Memory Search Logic ---
  List<String> _cachedPaths = [];
  
  Future<void> _refreshSearchCache() async {
    final db = await _storage.database;
    final results = await db.query(
      AppConstants.filesIndexTable,
      columns: ['path'],
      where: 'is_folder = 0' // Only search files
    );
    _cachedPaths = results.map((e) => e['path'] as String).toList();
    _log.info('DeviceDocumentService', 'Search cache refreshed: ${_cachedPaths.length} items');
  }

  /// Get documents from DB (with In-Memory Search Support)
  Future<List<FileSystemEntity>> getDocuments({
    int offset = 0,
    int limit = 50,
    String filterType = 'All',
    String? searchQuery,
    String? parentPath, 
    bool flatList = false,
  }) async {
      final db = await _storage.database;
      
      String whereClause = '1=1';
      List<dynamic> args = [];
      
      // Filter by Parent Path (Only if NOT flatList)
      if (!flatList && parentPath != null) {
         whereClause += ' AND parent_path = ?';
         args.add(parentPath);
      } else if (flatList) {
         whereClause += ' AND is_folder = 0';
      }
      
      // Search Logic (In-Memory Filter)
      if (searchQuery != null && searchQuery.isNotEmpty) {
          if (_cachedPaths.isEmpty) {
             await _refreshSearchCache();
          }
          
          final queryLower = searchQuery.toLowerCase();
          
          // Filter in Memory (Fast!)
          final matchingPaths = _cachedPaths.where((path) {
             final name = path.split('/').last.toLowerCase();
             return name.contains(queryLower);
          }).take(100).toList(); // Limit to 100 matches to keep SQL fast
          
          if (matchingPaths.isEmpty) {
             return []; // No matches
          }
          
          // Construct IN clause
          final placeholders = List.filled(matchingPaths.length, '?').join(',');
          whereClause += ' AND path IN ($placeholders)';
          args.addAll(matchingPaths);
      }

      
      // Filter Type Logic
      if (filterType != 'All') {
          final extMap = {
             'PDF': ['pdf'],
             'Word': ['doc', 'docx'],
             'Excel': ['xls', 'xlsx']
          };
          
          if (extMap.containsKey(filterType)) {
             final extensions = extMap[filterType]!;
             final placeholders = List.filled(extensions.length, '?').join(',');
             
             if (flatList) {
                // List Mode: Simple extension filter
                whereClause += ' AND extension IN ($placeholders)';
                args.addAll(extensions);
             } else {
                // Folder Mode: "Smart Filter" using pre-computed flags (Fast O(1))
                // Show files that match extension
                // OR Folders that recursively contain matching files (checked via has_xxx flags)
                
                String folderFlag = '0=1'; // default false
                if (filterType == 'PDF') folderFlag = 'has_pdf = 1';
                else if (filterType == 'Word') folderFlag = 'has_doc = 1';
                else if (filterType == 'Excel') folderFlag = 'has_excel = 1';
                
                whereClause += ''' AND (
                    (is_folder = 0 AND extension IN ($placeholders))
                    OR
                    (is_folder = 1 AND $folderFlag)
                )''';
                
                // Add args for the file extension check
                args.addAll(extensions);
             }
          }
      }
      
      // Sort Order
      String orderBy = 'modified_at DESC';
      switch (_currentSortOption) {
          case SortOption.name:
             orderBy = 'name ${_currentSortAscending ? "ASC" : "DESC"}';
             break;
          case SortOption.size:
             orderBy = 'size ${_currentSortAscending ? "ASC" : "DESC"}';
             break;
          case SortOption.dateCreated:
             orderBy = 'created_at ${_currentSortAscending ? "ASC" : "DESC"}';
             break;
          case SortOption.dateModified:
             orderBy = 'modified_at ${_currentSortAscending ? "ASC" : "DESC"}';
             break;
      }
      
      // Always prioritize folders on top
      orderBy = 'is_folder DESC, $orderBy';
      
      final List<Map<String, dynamic>> maps = await db.query(
         AppConstants.filesIndexTable,
         where: whereClause,
         whereArgs: args,
         orderBy: orderBy,
         limit: limit,
         offset: offset
      );
      
      // Convert back to FileSystemEntity
      return maps.map((m) {
         final path = m['path'] as String;
         final isFolder = (m['is_folder'] as int) == 1;
         return isFolder ? Directory(path) : File(path);
      }).toList();
  }

  /// Update sort options
  Future<void> sortDocuments(SortOption option, {bool ascending = true}) async {
      _currentSortOption = option;
      _currentSortAscending = ascending;
      // No need to resort memory, next getDocuments call will handle it
  }

  // _applyFilter and _sortDocsInternal removed as logic is now in SQL

  /// Isolate entry point
  static Future<List<FileSystemEntity>> _scanIsolate() async {
    final List<FileSystemEntity> documents = [];
    final root = Directory('/storage/emulated/0'); // Standard Android root

    if (!root.existsSync()) return [];

    final allowedExtensions = {'.pdf', '.doc', '.docx', '.xls', '.xlsx'};
    final ignoredDirs = {
      'Android', // Restricted access, usually
      '.', // Hidden files
      'cache',
      'thumb',
      'backups',
      'backup'
    };
    
    // Explicitly scan these if they exist, to handle scoped storage quirks
    final priorityDirs = [
      Directory('${root.path}/Download'),
      Directory('${root.path}/Documents'),
      Directory('${root.path}/DCIM'),
      Directory('${root.path}/Pictures'),
      Directory('${root.path}/WhatsApp/Media/WhatsApp Documents'),
      Directory('${root.path}/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents'),
      Directory('${root.path}/Telegram/Telegram Documents'),
    ];

    final Set<String> visitedPaths = {};
    final List<Directory> stack = [];

    // Add root
    stack.add(root);

    // Add priority dirs (in case root listing fails to include them due to permissions)
    for (final dir in priorityDirs) {
      if (dir.existsSync()) {
        stack.add(dir);
        // CRITICAL: Add priority dirs themselves to the index so they appear in root view
        // But only if they are not the root itself
        if (dir.path != root.path) {
             documents.add(dir);
        }
      }
    }

    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      
      if (visitedPaths.contains(current.path)) continue;
      visitedPaths.add(current.path);
      
      try {
        final entities = current.listSync(recursive: false, followLinks: false);
        
        for (final entity in entities) {
          final name = entity.path.split('/').last;

          // Skip hidden items/ignored folders
          if (name.startsWith('.') || ignoredDirs.contains(name)) continue;

             if (entity is Directory) {
               // Don't re-add if already visited (though stack check handles processing)
               if (!visitedPaths.contains(entity.path)) {
                 stack.add(entity);
                 documents.add(entity); // Index directory for Folder View
               }
             } else if (entity is File) {
             final ext = name.toLowerCase().split('.').last;
             if (allowedExtensions.contains('.$ext')) {
               documents.add(entity);
             }
           }
        }
      } catch (e) {
        // Access denied to specific folder, skip
        continue;
      }
    }
    
    // Default sort: Newest first
    documents.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return 0;
      }
    });

    return documents;
  }


}
