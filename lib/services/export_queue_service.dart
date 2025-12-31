import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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

  ExportJob({
    required this.id,
    required this.name,
    required this.items,
    this.status = ExportStatus.queued,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
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
  String addJob(String name, List<ExportItem> items) {
    final job = ExportJob(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      items: items,
    );
    _jobs.add(job);
    _log.info('ExportQueueService', 'Job added: ${job.name} with ${items.length} items');
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
    onJobsUpdated?.call();
    _log.info('ExportQueueService', 'Processing job: ${job.name}');

    try {
      final archive = Archive();

      // Add all items to archive
      for (final item in job.items) {
        await _addItemToArchive(archive, item, '');
      }

      if (archive.files.isEmpty) {
        throw Exception('No files to export');
      }

      // Encode ZIP in isolate
      final zipData = await compute(_encodeArchive, archive);
      if (zipData == null) throw Exception('Failed to encode ZIP');

      // Save file
      final dir = await getApplicationDocumentsDirectory();
      final fileName = '${job.name.replaceAll(RegExp(r'[^\w]'), '_')}_${job.id}.zip';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(zipData);

      job.outputPath = file.path;
      job.status = ExportStatus.completed;
      job.completedAt = DateTime.now();
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

  /// Add item to archive recursively
  Future<void> _addItemToArchive(Archive archive, ExportItem item, String pathPrefix) async {
    final archivePath = pathPrefix.isEmpty ? item.name : '$pathPrefix/${item.name}';

    if (item.isFolder) {
      // Add children recursively
      for (final child in item.children) {
        await _addItemToArchive(archive, child, archivePath);
      }
    } else if (item.filePath != null) {
      final file = File(item.filePath!);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
      }
    }
  }

  /// Clear completed/error jobs
  void clearFinished() {
    _jobs.removeWhere((j) => j.status == ExportStatus.completed || j.status == ExportStatus.error);
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
