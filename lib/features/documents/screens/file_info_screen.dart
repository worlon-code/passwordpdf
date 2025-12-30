import 'package:flutter/material.dart';
import 'dart:io';
import '../../../models/document_item_model.dart';
import 'package:intl/intl.dart';

/// File Information Screen - shows detailed file metadata
class FileInfoScreen extends StatelessWidget {
  final DocumentItem file;

  const FileInfoScreen({
    super.key,
    required this.file,
  });

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDate(DateTime date) {
    return DateFormat('MMM dd, yyyy HH:mm').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final fileExists = file.filePath != null && File(file.filePath!).existsSync();
    final fileSize = fileExists ? File(file.filePath!).lengthSync() : 0;
    final extension = file.name.split('.').last.toUpperCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text('File Information'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File Icon and Name
            Center(
              child: Column(
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: _getFileColor().withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      _getFileIcon(),
                      size: 60,
                      color: _getFileColor(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    file.name,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getFileColor().withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      extension,
                      style: TextStyle(
                        color: _getFileColor(),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // File Details
            _buildInfoCard(
              context,
              'Details',
              [
                _buildInfoRow(context, 'Size', _formatBytes(fileSize)),
                _buildInfoRow(context, 'Type', _getFileType()),
                _buildInfoRow(context, 'Status', fileExists ? 'Available' : 'File Not Found',
                  valueColor: fileExists ? Colors.green : Colors.red),
              ],
            ),

            const SizedBox(height: 16),

            _buildInfoCard(
              context,
              'Dates',
              [
                _buildInfoRow(context, 'Created', _formatDate(file.createdAt)),
                _buildInfoRow(context, 'Modified', _formatDate(file.modifiedAt)),
              ],
            ),

            const SizedBox(height: 16),

            _buildInfoCard(
              context,
              'Location',
              [
                _buildInfoRow(context, 'Path', file.filePath ?? 'Unknown', isPath: true),
              ],
            ),

            const SizedBox(height: 24),

            // Action Buttons
            if (fileExists && file.isPdf)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    // Close info screen and signal to open PDF
                    Navigator.pop(context, 'open');
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open File'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
    bool isPath = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
                color: valueColor,
                fontFamily: isPath ? 'monospace' : null,
              ),
              maxLines: isPath ? 3 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon() {
    if (file.isPdf) return Icons.picture_as_pdf;
    if (file.isDoc) return Icons.description;
    if (file.isExcel) return Icons.table_chart;
    return Icons.insert_drive_file;
  }

  Color _getFileColor() {
    if (file.isPdf) return Colors.red;
    if (file.isDoc) return Colors.blue;
    if (file.isExcel) return Colors.green;
    return Colors.grey;
  }

  String _getFileType() {
    if (file.isPdf) return 'PDF Document';
    if (file.isDoc) return 'Word Document';
    if (file.isExcel) return 'Excel Spreadsheet';
    return 'Document';
  }
}
