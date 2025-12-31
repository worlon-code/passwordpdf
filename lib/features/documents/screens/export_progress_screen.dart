import 'package:flutter/material.dart';
import '../../../services/export_queue_service.dart';

/// Screen showing export queue progress with filters
class ExportProgressScreen extends StatefulWidget {
  const ExportProgressScreen({super.key});

  @override
  State<ExportProgressScreen> createState() => _ExportProgressScreenState();
}

class _ExportProgressScreenState extends State<ExportProgressScreen> {
  final ExportQueueService _exportQueue = ExportQueueService();
  ExportStatus? _filterStatus; // null = all

  @override
  void initState() {
    super.initState();
    _exportQueue.onJobsUpdated = () {
      if (mounted) setState(() {});
    };
  }

  List<ExportJob> get _filteredJobs {
    if (_filterStatus == null) return _exportQueue.jobs;
    return _exportQueue.getJobsByStatus(_filterStatus!);
  }

  @override
  Widget build(BuildContext context) {
    final counts = _exportQueue.statusCounts;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Export Progress'),
        actions: [
          if (_exportQueue.jobs.any((j) => 
            j.status == ExportStatus.completed || j.status == ExportStatus.error))
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear finished',
              onPressed: () {
                _exportQueue.clearFinished();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // Filter bubbles
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _buildFilterChip('All', null, _exportQueue.jobs.length),
                _buildFilterChip('Queued', ExportStatus.queued, counts[ExportStatus.queued] ?? 0),
                _buildFilterChip('In Progress', ExportStatus.inProgress, counts[ExportStatus.inProgress] ?? 0),
                _buildFilterChip('Completed', ExportStatus.completed, counts[ExportStatus.completed] ?? 0),
                _buildFilterChip('Error', ExportStatus.error, counts[ExportStatus.error] ?? 0),
              ],
            ),
          ),
          const Divider(height: 1),
          
          // Job list
          Expanded(
            child: _filteredJobs.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    itemCount: _filteredJobs.length,
                    itemBuilder: (context, index) {
                      return _buildJobCard(_filteredJobs[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, ExportStatus? status, int count) {
    final isSelected = _filterStatus == status;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text('$label ($count)'),
        selected: isSelected,
        onSelected: (selected) {
          setState(() {
            _filterStatus = selected ? status : null;
          });
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.archive_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            _filterStatus == null 
                ? 'No exports yet' 
                : 'No ${_filterStatus!.name} exports',
            style: TextStyle(color: Colors.grey[600], fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Export folders from the dashboard',
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildJobCard(ExportJob job) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _getStatusIcon(job.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    job.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (job.status == ExportStatus.completed || job.status == ExportStatus.error)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => _exportQueue.removeJob(job.id),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            
            // Progress bar
            LinearProgressIndicator(
              value: job.progress / 100,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(
                _getStatusColor(job.status),
              ),
            ),
            const SizedBox(height: 4),
            
            // Status row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  job.statusText,
                  style: TextStyle(
                    color: _getStatusColor(job.status),
                    fontSize: 12,
                  ),
                ),
                if (job.totalItems > 0)
                  Text(
                    '${job.processedItems}/${job.totalItems} files',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
              ],
            ),
            
            // Error message
            if (job.status == ExportStatus.error && job.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    job.errorMessage!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              ),
              
            // Output path
            if (job.status == ExportStatus.completed && job.outputPath != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Saved to: ${job.outputPath!.split('/').last}',
                  style: TextStyle(color: Colors.green[700], fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Icon _getStatusIcon(ExportStatus status) {
    switch (status) {
      case ExportStatus.queued:
        return const Icon(Icons.schedule, color: Colors.orange);
      case ExportStatus.inProgress:
        return const Icon(Icons.sync, color: Colors.blue);
      case ExportStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case ExportStatus.error:
        return const Icon(Icons.error, color: Colors.red);
    }
  }

  Color _getStatusColor(ExportStatus status) {
    switch (status) {
      case ExportStatus.queued:
        return Colors.orange;
      case ExportStatus.inProgress:
        return Colors.blue;
      case ExportStatus.completed:
        return Colors.green;
      case ExportStatus.error:
        return Colors.red;
    }
  }
}
