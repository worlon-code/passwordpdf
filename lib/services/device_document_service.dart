import 'dart:io';
import 'dart:isolate';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class DeviceDocumentService {
  
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

  /// Scans the device for documents using a background isolate
  Future<List<FileSystemEntity>> scanDevice() async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      throw Exception('Storage permissions denied');
    }

    // Run heavy scanning in background isolate
    return await Isolate.run(_scanIsolate);
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
      // Use efficient recursive listing
      // Using listSync(recursive: true) can be dangerous on /storage/emulated/0 if exceptions occur midway
      // Iterative approach is safer for generic crawling
      
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
