import 'package:flutter/material.dart';
import 'dart:io';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';
import '../../../services/export_queue_service.dart';
import 'package:passwordpdf_manager/features/common/models/sort_option.dart';
import 'package:passwordpdf_manager/features/common/widgets/sort_bottom_sheet.dart';

/// Screen showing export queue progress with filters
class ExportProgressScreen extends StatefulWidget {
  final bool showDeveloper;
  const ExportProgressScreen({super.key, this.showDeveloper = false});

  @override
  State<ExportProgressScreen> createState() => _ExportProgressScreenState();
}

class _ExportProgressScreenState extends State<ExportProgressScreen> {
  final ExportQueueService _exportQueue = ExportQueueService();
  ExportStatus? _filterStatus; // null = all
  final Set<String> _selectedJobIds = {};
  
  // Sorting State
  SortOption _sortOption = SortOption.dateCreated;
  bool _sortAscending = false; // Default newest first

  @override
  void initState() {
    super.initState();
    _exportQueue.addListener(_updateUI);
  }

  @override
  void dispose() {
    _exportQueue.removeListener(_updateUI);
    super.dispose();
  }

  void _updateUI() {
    if (mounted) setState(() {});
  }

  List<ExportJob> get _filteredJobs {
    final jobs = _exportQueue.jobs.where((j) => j.isDeveloper == widget.showDeveloper).toList();
    
    // Filter
    final filtered = _filterStatus == null 
        ? jobs 
        : jobs.where((j) => j.status == _filterStatus).toList();

    // Sort
    filtered.sort((a, b) {
      int comparison = 0;
      switch (_sortOption) {
        case SortOption.name:
          comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortOption.size:
          // Estimate size or use 0 if not available (ExportJob might not have size always)
          comparison = 0; 
          break;
        case SortOption.dateCreated:
           comparison = a.createdAt.compareTo(b.createdAt);
           break;
        case SortOption.dateModified:
           // Use completedAt if available, else created timestamp
           final timeA = a.completedAt ?? a.createdAt;
           final timeB = b.completedAt ?? b.createdAt;
           comparison = timeA.compareTo(timeB);
           break;
      }
      return _sortAscending ? comparison : -comparison;
    });

    return filtered;
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedJobIds.contains(id)) {
        _selectedJobIds.remove(id);
      } else {
        _selectedJobIds.add(id);
      }
    });
  }

  Future<void> _shareSelectedJobs() async {
    final allJobs = _exportQueue.jobs.where((j) => j.isDeveloper == widget.showDeveloper);
    final jobs = allJobs.where((j) => _selectedJobIds.contains(j.id));
    final filesToShare = <XFile>[];
    final missingFiles = <String>[];
    
    for (final job in jobs) {
      if (job.status == ExportStatus.completed && job.outputPath != null) {
        final file = File(job.outputPath!);
        if (await file.exists()) {
           filesToShare.add(XFile(job.outputPath!));
        } else {
           missingFiles.add(job.name);
        }
      }
    }

    if (missingFiles.isNotEmpty) {
      if (mounted) {
         showDialog(
           context: context,
           builder: (context) => AlertDialog(
             title: const Text('Files Missing'),
             content: Text('The following export files are no longer on the device:\n\n${missingFiles.join('\n')}'),
             actions: [
               TextButton(
                 onPressed: () => Navigator.pop(context),
                 child: const Text('OK'),
               )
             ],
           ),
         );
      }
      // If we have some valid files, ask to continue? Or just stop?
      // For now, let's stop to be safe and clear confusion.
      return; 
    }

    if (filesToShare.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No valid export files found to share')),
      );
      return;
    }

    try {
      await Share.shareXFiles(filesToShare, text: 'Attached exports');
      setState(() => _selectedJobIds.clear());
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }

  void _deleteSelectedJobs() {
    for (final id in _selectedJobIds) {
      _exportQueue.removeJob(id);
    }
    setState(() => _selectedJobIds.clear());
  }

  @override
  Widget build(BuildContext context) {
    final counts = _exportQueue.getStatusCounts(showDeveloper: widget.showDeveloper);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedJobIds.isEmpty 
            ? 'Export Progress' 
            : '${_selectedJobIds.length} Selected'),
        leading: _selectedJobIds.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _selectedJobIds.clear()),
              )
            : null,
        actions: [
          if (_selectedJobIds.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Share',
              onPressed: _shareSelectedJobs,
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              tooltip: 'Delete',
              onPressed: _deleteSelectedJobs,
            ),
          ] else if (_exportQueue.jobs.any((j) => 
            j.status == ExportStatus.completed || j.status == ExportStatus.error)) ...[
             IconButton(
               icon: const Icon(Icons.sort),
               onPressed: () {
                 showModalBottomSheet(
                    context: context,
                    builder: (context) => SortBottomSheet(
                      currentOption: _sortOption,
                      isAscending: _sortAscending,
                      onSortChanged: (option, ascending) {
                        setState(() {
                          _sortOption = option;
                          _sortAscending = ascending;
                        });
                      },
                    ),
                  );
               },
             ),
             IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear finished',
              onPressed: () {
                _exportQueue.clearFinished(isDeveloper: widget.showDeveloper);
              },
            ),
          ],
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
                _buildFilterChip('All', null, _exportQueue.jobs.where((j) => j.isDeveloper == widget.showDeveloper).length),
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
    final isSelected = _selectedJobIds.contains(job.id);
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: isSelected ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected 
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: () {
          if (_selectedJobIds.isNotEmpty) {
            _toggleSelection(job.id);
          } else if (job.status == ExportStatus.completed && job.outputPath != null) {
             // Open/Share file logic or just show info
             // For now, let's strictly follow "single click selects" ONLY in multi-select mode.
             // Outside mode, maybe open file?
             // User said "press only enter to multi select mode".
             // So tap outside might be "Open".
             Share.shareXFiles([XFile(job.outputPath!)]);
          }
        },
        onLongPress: () {
          // Always enter selection mode
          _toggleSelection(job.id);
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (_selectedJobIds.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        color: isSelected ? theme.colorScheme.primary : Colors.grey,
                      ),
                    ),
                  _getStatusIcon(job.status),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      job.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_selectedJobIds.isEmpty && (job.status == ExportStatus.completed || job.status == ExportStatus.error))
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
