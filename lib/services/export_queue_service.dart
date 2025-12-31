import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'logging_service.dart';
import 'storage_service.dart';

/// Status of an export job
enum ExportStatus { queued, inProgress, completed, error }

/// Model for an export job
class ExportJob {
  final String id;
  final String name;
  ExportStatus status;
  final DateTime createdAt;
  DateTime? completedAt;
  String? outputPath;
  String? errorMessage;
  final List<ExportItem> items;
  final String? zipPassword;
  final String? exportDir;
  int progress;
  int processedItems;
  int totalItems;

  ExportJob({
    required this.id,
    required this.name,
    required this.items,
    this.exportDir,
    this.zipPassword,
    this.status = ExportStatus.queued,
    this.progress = 0,
    this.processedItems = 0,
    this.totalItems = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
  
  String get statusText {
    switch (status) {
      case ExportStatus.queued:
        return 'Queued';
      case ExportStatus.inProgress:
        if (progress >= 100) {
          return 'Finalizing ZIP...';
        }
        return 'Processing $progress%';
      case ExportStatus.completed:
        return 'Completed';
      case ExportStatus.error:
        return 'Error';
    }
  }
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'status': status.name,
      'created_at': createdAt.millisecondsSinceEpoch,
      'completed_at': completedAt?.millisecondsSinceEpoch,
      'output_path': outputPath,
      'error_message': errorMessage,
      'items': items.map((i) => i.toJson()).toList(),
      'export_dir': exportDir,
      'zip_password': zipPassword,
      'progress': progress,
      'processed_items': processedItems,
      'total_items': totalItems,
    };
  }

  factory ExportJob.fromJson(Map<String, dynamic> json) {
    return ExportJob(
      id: json['id'],
      name: json['name'],
      items: (json['items'] as List).map((i) => ExportItem.fromJson(i)).toList(),
      exportDir: json['export_dir'],
      zipPassword: json['zip_password'],
      status: ExportStatus.values.firstWhere((e) => e.name == json['status']),
      progress: json['progress'] ?? 0,
      processedItems: json['processed_items'] ?? 0,
      totalItems: json['total_items'] ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['created_at']),
    )..completedAt = json['completed_at'] != null 
        ? DateTime.fromMillisecondsSinceEpoch(json['completed_at']) 
        : null
     ..outputPath = json['output_path']
     ..errorMessage = json['error_message'];
  }
}

/// Model for an export item (file or folder)
class ExportItem {
  final String itemId;
  final String? filePath;
  final String name;
  final bool isFolder;
  final List<ExportItem> children; // For folders

  ExportItem({
    required this.itemId,
    required this.name,
    this.filePath,
    this.isFolder = false,
    this.children = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'item_id': itemId,
      'name': name,
      'file_path': filePath,
      'is_folder': isFolder,
      'children': children.map((c) => c.toJson()).toList(),
    };
  }

  factory ExportItem.fromJson(Map<String, dynamic> json) {
    return ExportItem(
      itemId: json['item_id'],
      name: json['name'],
      filePath: json['file_path'],
      isFolder: json['is_folder'] ?? false,
      children: json['children'] != null
          ? (json['children'] as List).map((i) => ExportItem.fromJson(i)).toList()
          : [],
    );
  }
}

// Moved import to top

/// Service for managing export queue with background processing
class ExportQueueService {
  static final ExportQueueService _instance = ExportQueueService._internal();
  factory ExportQueueService() => _instance;
  ExportQueueService._internal();

  final LoggingService _log = LoggingService();
  final List<ExportJob> _jobs = [];
  Timer? _workerTimer;
  static const int maxConcurrent = 2;
  static const Duration checkInterval = Duration(minutes: 2);
  
  // Notifications
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _notificationsInitialized = false;
  
  // Callback for UI updates
  void Function()? onJobsUpdated;

  /// Get all jobs
  List<ExportJob> get jobs => List.unmodifiable(_jobs);

  /// Get jobs by status
  List<ExportJob> getJobsByStatus(ExportStatus status) {
    return _jobs.where((j) => j.status == status).toList();
  }
  
  /// Get counts by status
  Map<ExportStatus, int> get statusCounts {
    return {
      for (var status in ExportStatus.values)
        status: _jobs.where((j) => j.status == status).length,
    };
  }
  
  /// Get in-progress count
  int get inProgressCount => _jobs.where((j) => j.status == ExportStatus.inProgress).length;

  /// Start the background worker
  void startWorker() {
    if (_workerTimer != null) return;
    _workerTimer = Timer.periodic(checkInterval, (_) => _processQueue());
    _log.info('ExportQueueService', 'Worker started');
  }

  /// Stop the background worker
  void stopWorker() {
    _workerTimer?.cancel();
    _workerTimer = null;
    _log.info('ExportQueueService', 'Worker stopped');
  }

  final StorageService _storage = StorageService();

  /// Initialize service and load history
  Future<void> init() async {
    await _initNotifications();
    try {
      final jobMaps = await _storage.getAllExportJobs();
      _jobs.clear();
      for (final map in jobMaps) {
        try {
          // Convert DB map to Model map (handle items_json)
          final modelMap = Map<String, dynamic>.from(map);
          if (modelMap['items_json'] != null) {
            modelMap['items'] = jsonDecode(modelMap['items_json'] as String);
          }
           
          final job = ExportJob.fromJson(modelMap);
          
          // Reset status if it was stuck in progress
          if (job.status == ExportStatus.inProgress || job.status == ExportStatus.queued) {
             job.status = ExportStatus.error;
             job.errorMessage = 'Interrupted by app restart';
             job.completedAt = DateTime.now();
          }
          
          _jobs.add(job);
        } catch (e) {
          _log.error('ExportQueueService', 'Failed to load job', e);
        }
      }
      onJobsUpdated?.call();
      _log.info('ExportQueueService', 'Loaded ${_jobs.length} jobs from history');
    } catch (e) {
      _log.error('ExportQueueService', 'Failed to init history', e);
    }
  }
  
  // Stream for notification taps
  final _notificationTapController = StreamController<String>.broadcast();
  Stream<String> get onNotificationTap => _notificationTapController.stream;

  Future<void> _initNotifications() async {
    if (_notificationsInitialized) return;
    
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (details) {
         if (details.payload != null) {
           _notificationTapController.add(details.payload!);
         } else {
           _notificationTapController.add('');
         }
      },
    );
    _notificationsInitialized = true;
    _log.info('ExportQueueService', 'Notifications initialized');
  }
  
  Future<void> _showNotification(int id, String title, String body, {int? progress, int? maxProgress, String? payload}) async {
    if (!_notificationsInitialized) return;
    
    final androidDetails = AndroidNotificationDetails(
      'export_channel',
      'Export Service',
      channelDescription: 'Notifications for background exports',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: progress != null,
      maxProgress: maxProgress ?? 100,
      progress: progress ?? 0,
      onlyAlertOnce: progress != null, // Don't buzz for progress updates
    );
    
    final details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(id, title, body, details, payload: payload ?? 'export_progress');
  }

  /// Add a new export job to queue
  Future<String> addJob(String name, List<ExportItem> items, {String? exportDir, String? zipPassword}) async {
    // Cap history at 100 jobs
    if (_jobs.length >= 100) {
      // Remove oldest (completed/error) first, or just oldest
      final oldest = _jobs.firstWhere(
        (j) => j.status == ExportStatus.completed || j.status == ExportStatus.error, 
        orElse: () => _jobs.first
      );
      await removeJob(oldest.id);
    }
    
    // Count total files for progress tracking
    int countItems(List<ExportItem> items) {
      int count = 0;
      for (final item in items) {
        if (item.isFolder) {
          count += countItems(item.children);
        } else {
          count++;
        }
      }
      return count;
    }
    
    final total = countItems(items);
    
    final job = ExportJob(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      items: items,
      exportDir: exportDir,
      zipPassword: zipPassword,
      totalItems: total,
    );
    _jobs.add(job);
    _persistJob(job); // Save initial state
    
    _log.info('ExportQueueService', 'Job added: ${job.name} with $total files');
    onJobsUpdated?.call();
    
    // Immediately try to process
    _processQueue();
    
    return job.id;
  }

  /// Process the queue
  void _processQueue() {
    final inProgress = _jobs.where((j) => j.status == ExportStatus.inProgress).length;
    
    if (inProgress >= maxConcurrent) {
      _log.debug('ExportQueueService', 'Max concurrent exports reached ($inProgress)');
      return;
    }
    
    final queued = _jobs.where((j) => j.status == ExportStatus.queued).toList();
    
    if (queued.isEmpty) return;
    
    // Process next queued jobs up to max concurrent
    final toProcess = queued.take(maxConcurrent - inProgress);
    for (final job in toProcess) {
      _processJob(job);
    }
  }

  /// Process a single job
  Future<void> _processJob(ExportJob job) async {
    job.status = ExportStatus.inProgress;
    job.processedItems = 0;
    _persistJob(job); // Update status
    onJobsUpdated?.call();
    _log.info('ExportQueueService', 'Processing job: ${job.name}');
    
    // Notification ID: use last 4 chars of ID as int (hash)
    final notificationId = job.id.hashCode;
    await _showNotification(notificationId, 'Export Started', 'Exporting ${job.name}...');

    try {
      final archive = Archive();

      // Add all items to archive with progress tracking
      await _addItemsToArchive(archive, job.items, '', job, notificationId);

      if (archive.files.isEmpty) {
        throw Exception('No files to export');
      }

      await _showNotification(notificationId, 'Exporting ${job.name}', 'Compressing...', progress: 99, maxProgress: 100);

      // Encode ZIP in isolate
      // Pass both archive and password
      final zipData = await compute(_encodeArchive, {'archive': archive, 'password': job.zipPassword});
      if (zipData == null) throw Exception('Failed to encode ZIP');

      // Determine save path
      String savePath;
      if (job.exportDir != null) {
        final dir = Directory(job.exportDir!);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        final fileName = '${job.name.replaceAll(RegExp(r'[^\w]'), '_')}_${job.id}.zip';
        savePath = '${dir.path}/$fileName';
      } else {
        // Fallback to app directory
        savePath = '${Directory.systemTemp.path}/${job.name}_${job.id}.zip';
      }

      // Save file
      final file = File(savePath);
      await file.writeAsBytes(zipData);

      job.outputPath = file.path;
      job.status = ExportStatus.completed;
      job.completedAt = DateTime.now();
      job.progress = 100;
      _log.info('ExportQueueService', 'Job completed: ${job.name} -> ${file.path}');
      
      await _showNotification(notificationId, 'Export Complete', '${job.name} saved successfully.');
      
    } catch (e, stack) {
      job.status = ExportStatus.error;
      job.errorMessage = e.toString();
      job.completedAt = DateTime.now();
      _log.error('ExportQueueService', 'Job failed: ${job.name}', e, stack);
      
      await _showNotification(notificationId, 'Export Failed', 'Error: ${job.name}');
    }

    _persistJob(job); // Final update
    onJobsUpdated?.call();
    
    // Process next in queue
    _processQueue();
  }

  /// Add items to archive with progress tracking
  Future<void> _addItemsToArchive(Archive archive, List<ExportItem> items, String pathPrefix, ExportJob job, int notificationId) async {
    for (final item in items) {
      final archivePath = pathPrefix.isEmpty ? item.name : '$pathPrefix/${item.name}';

      if (item.isFolder) {
        // Add children recursively
        await _addItemsToArchive(archive, item.children, archivePath, job, notificationId);
      } else if (item.filePath != null) {
        final file = File(item.filePath!);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
          
          // Update progress
          job.processedItems++;
          if (job.totalItems > 0) {
            job.progress = ((job.processedItems / job.totalItems) * 100).round();
            
            // Throttle notifications (every 5 items or 10%)
            if (job.processedItems % 5 == 0 || job.progress % 10 == 0) {
               await _showNotification(
                 notificationId, 
                 'Exporting ${job.name}', 
                 '${job.progress}% complete', 
                 progress: job.progress, 
                 maxProgress: 100
               );
            }
          }
          onJobsUpdated?.call();
          
          // Yield to allow UI updates
          await Future.delayed(Duration.zero);
        }
      }
    }
  }

  /// Persist job to database
  Future<void> _persistJob(ExportJob job) async {
    try {
      final json = job.toJson();
      // Handle items serialization for DB
      if (json['items'] != null) {
        json['items_json'] = jsonEncode(json['items']);
        json.remove('items');
      }
      await _storage.saveExportJob(job.id, json);
    } catch (e) {
      _log.error('ExportQueueService', 'Persist error', e);
    }
  }

  /// Clear completed/error jobs
  Future<void> clearFinished() async {
    final toRemove = _jobs.where((j) => j.status == ExportStatus.completed || j.status == ExportStatus.error).toList();
    _jobs.removeWhere((j) => j.status == ExportStatus.completed || j.status == ExportStatus.error);
    
    // Remove from DB
    await _storage.deleteFinishedExportJobs();
    
    // Cancel notifications for removed jobs
    for (final job in toRemove) {
      await _notificationsPlugin.cancel(job.id.hashCode);
    }
    
    onJobsUpdated?.call();
  }
  
  /// Remove a specific job
  Future<void> removeJob(String jobId) async {
    _jobs.removeWhere((j) => j.id == jobId);
    await _storage.deleteExportJob(jobId);
    await _notificationsPlugin.cancel(jobId.hashCode);
    onJobsUpdated?.call();
  }
}

/// Isolate function to encode archive
// Accepts Map with 'archive' and optional 'password'
List<int>? _encodeArchive(Map<String, dynamic> params) {
  try {
    final archive = params['archive'] as Archive;
    final password = params['password'] as String?;
    
    final encoder = ZipEncoder(password: password);
    return encoder.encode(archive);
  } catch (e) {
    return null;
  }
}
