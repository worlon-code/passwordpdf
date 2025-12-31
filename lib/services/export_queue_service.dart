import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'logging_service.dart';

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
  final String? exportDir; // Configured export directory
  int progress; // 0-100
  int processedItems;
  int totalItems;

  ExportJob({
    required this.id,
    required this.name,
    required this.items,
    this.exportDir,
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
        return 'In Progress ($progress%)';
      case ExportStatus.completed:
        return 'Completed';
      case ExportStatus.error:
        return 'Error';
    }
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
}

/// Service for managing export queue with background processing
class ExportQueueService {
  static final ExportQueueService _instance = ExportQueueService._internal();
  factory ExportQueueService() => _instance;
  ExportQueueService._internal();

  final LoggingService _log = LoggingService();
  final List<ExportJob> _jobs = [];
  Timer? _workerTimer;
  static const int maxConcurrent = 2;
  static const Duration checkInterval = Duration(seconds: 30);
  
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

  /// Add a new export job to queue
  String addJob(String name, List<ExportItem> items, {String? exportDir}) {
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
      totalItems: total,
    );
    _jobs.add(job);
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
    onJobsUpdated?.call();
    _log.info('ExportQueueService', 'Processing job: ${job.name}');

    try {
      final archive = Archive();

      // Add all items to archive with progress tracking
      await _addItemsToArchive(archive, job.items, '', job);

      if (archive.files.isEmpty) {
        throw Exception('No files to export');
      }

      // Encode ZIP in isolate
      final zipData = await compute(_encodeArchive, archive);
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
    } catch (e, stack) {
      job.status = ExportStatus.error;
      job.errorMessage = e.toString();
      job.completedAt = DateTime.now();
      _log.error('ExportQueueService', 'Job failed: ${job.name}', e, stack);
    }

    onJobsUpdated?.call();
    
    // Process next in queue
    _processQueue();
  }

  /// Add items to archive with progress tracking
  Future<void> _addItemsToArchive(Archive archive, List<ExportItem> items, String pathPrefix, ExportJob job) async {
    for (final item in items) {
      final archivePath = pathPrefix.isEmpty ? item.name : '$pathPrefix/${item.name}';

      if (item.isFolder) {
        // Add children recursively
        await _addItemsToArchive(archive, item.children, archivePath, job);
      } else if (item.filePath != null) {
        final file = File(item.filePath!);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
          
          // Update progress
          job.processedItems++;
          if (job.totalItems > 0) {
            job.progress = ((job.processedItems / job.totalItems) * 100).round();
          }
          onJobsUpdated?.call();
          
          // Yield to allow UI updates
          await Future.delayed(Duration.zero);
        }
      }
    }
  }

  /// Clear completed/error jobs
  void clearFinished() {
    _jobs.removeWhere((j) => j.status == ExportStatus.completed || j.status == ExportStatus.error);
    onJobsUpdated?.call();
  }
  
  /// Remove a specific job
  void removeJob(String jobId) {
    _jobs.removeWhere((j) => j.id == jobId);
    onJobsUpdated?.call();
  }
}

/// Isolate function to encode archive
List<int>? _encodeArchive(Archive archive) {
  try {
    return ZipEncoder().encode(archive);
  } catch (e) {
    return null;
  }
}
