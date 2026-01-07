import 'dart:io';
import 'dart:isolate';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/logging_service.dart';
import '../features/common/models/sort_option.dart';

class DeviceDocumentService {
  List<FileSystemEntity> _cachedDocuments = [];
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

  /// Scans the device and populates the cache
  Future<void> scanDevice() async {
    if (_isScanning) return;
    _isScanning = true;
    _log.info('DeviceDocumentService', 'Starting full device scan');

    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        _log.warn('DeviceDocumentService', 'Scanner permission denied');
        throw Exception('Storage permissions denied');
      }

      // Run heavy scanning in background isolate
      final startTime = DateTime.now();
      _cachedDocuments = await Isolate.run(_scanIsolate);
      final duration = DateTime.now().difference(startTime).inMilliseconds;
      
      _log.info('DeviceDocumentService', 'Scan complete. Found ${_cachedDocuments.length} files in ${duration}ms');
    } catch (e) {
      _log.error('DeviceDocumentService', 'Scanning failed', e);
      rethrow;
    } finally {
      _isScanning = false;
    }
  }

  /// Get paginated documents from cache
  /// [offset] - Starting index
  /// [limit] - Number of items to return
  /// [filterType] - 'All', 'PDF', 'Word', 'Excel'
  List<FileSystemEntity> getDocuments({
    int offset = 0,
    int limit = 20,
    String filterType = 'All',
    String? searchQuery,
  }) {
    List<FileSystemEntity> filtered = _applyFilter(_cachedDocuments, filterType, searchQuery);
    
    if (offset >= filtered.length) return [];
    
    final end = (offset + limit < filtered.length) ? offset + limit : filtered.length;
    return filtered.sublist(offset, end);
  }
  /// Sort documents in cache
  Future<void> sortDocuments(SortOption option, {bool ascending = true}) async {
      _log.info('DeviceDocumentService', 'Sorting documents by $option (Asc: $ascending)');
      
      // Capture list reference to pass to isolate (Isolate.run handles sending/copying)
      final docsToSort = List<FileSystemEntity>.from(_cachedDocuments); 
      
      // Run sort in Isolate to avoid UI freeze for large lists
      // IMPORTANT: Use a static method or top-level function to avoid capturing 'this'
      _cachedDocuments = await Isolate.run(() {
         return _sortDocsInternal(docsToSort, option, ascending);
      });
  }

  /// Static helper for sorting to avoid Isolate capture issues
  static List<FileSystemEntity> _sortDocsInternal(List<FileSystemEntity> docs, SortOption option, bool ascending) {
     docs.sort((a, b) {
        try {
          // Cache stats if possible or just read sync (Isolate makes it safe)
          final statA = a.statSync();
          final statB = b.statSync();
          
          int comparison = 0;
          switch (option) {
            case SortOption.name:
               comparison = a.path.split('/').last.toLowerCase().compareTo(b.path.split('/').last.toLowerCase());
               break;
            case SortOption.size:
               comparison = statA.size.compareTo(statB.size);
               break;
            case SortOption.dateCreated:
               comparison = statA.accessed.compareTo(statB.accessed);
               break;
            case SortOption.dateModified:
               comparison = statA.modified.compareTo(statB.modified);
               break;
          }
          
          return ascending ? comparison : -comparison;
        } catch (_) {
          return 0;
        }
      });
      return docs;
  }
// ...

  /// Helper filter
  List<FileSystemEntity> _applyFilter(List<FileSystemEntity> docs, String type, String? searchQuery) {
    return docs.where((file) {
      final name = file.path.split('/').last.toLowerCase();
      
      // Filter by search query
      if (searchQuery != null && searchQuery.isNotEmpty) {
        if (!name.contains(searchQuery.toLowerCase())) {
          return false;
        }
      }

      if (type == 'All') return true;
      if (type == 'PDF') return name.endsWith('.pdf');
      if (type == 'Word') return name.endsWith('.doc') || name.endsWith('.docx');
      if (type == 'Excel') return name.endsWith('.xls') || name.endsWith('.xlsx');
      return true;
    }).toList();
  }

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
