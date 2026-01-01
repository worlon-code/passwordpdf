import 'package:flutter/material.dart';
import 'dart:io';
import '../../../models/document_item_model.dart';
import 'package:intl/intl.dart';
import '../../../services/pdf_tools_service.dart';
import '../../../services/document_service.dart';
import 'file_occurrences_screen.dart';

/// File Information Screen - shows detailed file metadata
class FileInfoScreen extends StatefulWidget {
  final DocumentItem file;

  const FileInfoScreen({
    super.key,
    required this.file,
  });

  @override
  State<FileInfoScreen> createState() => _FileInfoScreenState();
}

class _FileInfoScreenState extends State<FileInfoScreen> {
  bool? _isProtected;
  bool _isLoadingProtection = false;
  int _occurrencesCount = 0;
  bool _isLoadingOccurrences = true;

  @override
  void initState() {
    super.initState();
    _checkProtection();
    _loadOccurrences();
  }

  Future<void> _checkProtection() async {
    if (widget.file.isPdf && widget.file.filePath != null) {
      if (mounted) setState(() => _isLoadingProtection = true);
      final isProtected = await PdfToolsService().isProtected(widget.file.filePath!);
      if (mounted) {
        setState(() {
          _isProtected = isProtected;
          _isLoadingProtection = false;
        });
      }
    }
  }

  Future<void> _loadOccurrences() async {
    final docService = DocumentService();
    await docService.initialize();
    
    // Find all files with same name and size (content match)
    final allFiles = docService.getAllItems().where((item) => !item.isFolder).toList();
    final file = widget.file;
    
    final matches = allFiles.where((f) {
      return f.size == file.size && f.size > 0 && // Ensure size > 0
             f.id != file.id; // Exclude self
    }).toList();
    
    if (mounted) {
      setState(() {
        _occurrencesCount = matches.length + 1; // Include current file
        _isLoadingOccurrences = false;
      });
    }
  }

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
    final file = widget.file;
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
                if (file.isPdf && fileExists)
                  _buildInfoRow(
                    context, 
                    'Security', 
                    _isLoadingProtection 
                        ? 'Checking...' 
                        : (_isProtected == true ? 'Password Protected' : 'No Password'),
                    valueColor: _isProtected == true ? Colors.orange : Colors.green,
                  ),
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

            const SizedBox(height: 16),

            // Occurrences Card
            _buildOccurrencesCard(context, fileSize),

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

  Widget _buildOccurrencesCard(BuildContext context, int fileSize) {
    final file = widget.file;
    
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _occurrencesCount > 1 ? () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FileOccurrencesScreen(
                fileName: file.name,
                fileSize: fileSize,
              ),
            ),
          );
        } : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.copy_all, color: Colors.orange),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Occurrences',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isLoadingOccurrences 
                          ? 'Checking...'
                          : _occurrencesCount > 1
                              ? 'Found in $_occurrencesCount locations'
                              : 'Only in this location',
                      style: TextStyle(
                        color: _occurrencesCount > 1 ? Colors.orange : Colors.grey[600],
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              if (_occurrencesCount > 1)
                const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
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
    if (widget.file.isPdf) return Icons.picture_as_pdf;
    if (widget.file.isDoc) return Icons.description;
    if (widget.file.isExcel) return Icons.table_chart;
    return Icons.insert_drive_file;
  }

  Color _getFileColor() {
    if (widget.file.isPdf) return Colors.red;
    if (widget.file.isDoc) return Colors.blue;
    if (widget.file.isExcel) return Colors.green;
    return Colors.grey;
  }

  String _getFileType() {
    if (widget.file.isPdf) return 'PDF Document';
    if (widget.file.isDoc) return 'Word Document';
    if (widget.file.isExcel) return 'Excel Spreadsheet';
    return 'Document';
  }
}
