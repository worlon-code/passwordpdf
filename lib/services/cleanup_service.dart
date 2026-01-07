import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'logging_service.dart';

class CleanupService {
  static final CleanupService _instance = CleanupService._internal();
  factory CleanupService() => _instance;
  CleanupService._internal();

  final LoggingService _log = LoggingService();

  /// Run all cleanup tasks
  Future<void> runCleanup() async {
    _log.info('CleanupService', 'Starting cleanup...');
    await _cleanCacheDir();
    await _cleanFilePickerCache();
    _log.info('CleanupService', 'Cleanup complete');
  }

  /// Clean application cache directory (created by share intents etc)
  Future<void> _cleanCacheDir() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      if (await cacheDir.exists()) {
        final List<FileSystemEntity> files = cacheDir.listSync();
        int deletedCount = 0;
        
        for (final file in files) {
          try {
            // Keep recent files (less than 1 hour old) to avoid breaking active operations
            // But if it's "Share" or "Open With" intent data, it might be here.
            final stat = await file.stat();
            final age = DateTime.now().difference(stat.modified);
            
            if (age.inHours > 1) {
              await file.delete(recursive: true);
              deletedCount++;
            }
          } catch (e) {
            // Ignore single file deletion errors
          }
        }
        _log.info('CleanupService', 'Cleaned cache dir: $deletedCount items deleted');
      }
    } catch (e) {
      _log.error('CleanupService', 'Failed to clean cache dir', e);
    }
  }

  /// Clean file_picker cache (plugin specific)
  Future<void> _cleanFilePickerCache() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final filePickerDir = Directory('${cacheDir.path}/file_picker');
      
      if (await filePickerDir.exists()) {
         _log.info('CleanupService', 'Found file_picker cache, deleting...');
         await filePickerDir.delete(recursive: true);
         _log.info('CleanupService', 'Deleted file_picker cache');
      }
    } catch (e) {
       // It's possible the dir doesn't exist or is locked
       _log.warn('CleanupService', 'Note: Could not clean file_picker cache (may not exist)');
    }
  }
}
