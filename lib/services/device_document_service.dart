import 'dart:io';
import 'dart:isolate';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:passwordpdf_manager/services/logging_service.dart';

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
  Future<void> sortDocuments(String sortType) async {
      _log.info('DeviceDocumentService', 'Sorting documents by $sortType');
      // Run sort in Isolate to avoid UI freeze for large lists
      _cachedDocuments = await Isolate.run(() {
         // ... (keep isolate logic)
         try {
             final List<FileSystemEntity> docs = List.from(_cachedDocuments); // Copy for isolation
             // ... same sort logic ...
          } catch(e) {
             return _cachedDocuments; // Fallback? No, isolate needs to return value
          }
           final List<FileSystemEntity> docs = List.from(_cachedDocuments); // Copy for isolation
           docs.sort((a, b) {
            try {
              final statA = a.statSync();
              final statB = b.statSync();
              
              switch (sortType) {
                case 'Date (Oldest)':
                   return statA.modified.compareTo(statB.modified);
                case 'Name (A-Z)':
                   return a.path.split('/').last.toLowerCase().compareTo(b.path.split('/').last.toLowerCase());
                case 'Name (Z-A)':
                   return b.path.split('/').last.toLowerCase().compareTo(a.path.split('/').last.toLowerCase());
                case 'Size (Largest)':
                   return statB.size.compareTo(statA.size);
                case 'Size (Smallest)':
                   return statA.size.compareTo(statB.size);
                case 'Date (Newest)':
                default:
                   return statB.modified.compareTo(statA.modified);
              }
            } catch (_) {
              return 0;
            }
          });
          return docs;
      }, debugName: 'sortIsolate');
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
    };

    try {
      final List<Directory> stack = [root];
      
      while (stack.isNotEmpty) {
        final current = stack.removeLast();
        
        try {
          final entities = current.listSync(recursive: false, followLinks: false);
          
          for (final entity in entities) {
            final name = entity.path.split('/').last;

            // Skip hidden items/ignored folders
            if (name.startsWith('.') || ignoredDirs.contains(name)) continue;

             if (entity is Directory) {
               stack.add(entity);
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
    } catch (e) {
      // General failure
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
