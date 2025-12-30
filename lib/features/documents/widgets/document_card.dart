import 'package:flutter/material.dart';
import 'dart:io';
import 'package:intl/intl.dart';

/// Document card widget for displaying PDF files
class DocumentCard extends StatelessWidget {
  final File file;
  final VoidCallback onTap;
  final bool isListView;

  const DocumentCard({
    super.key,
    required this.file,
    required this.onTap,
    this.isListView = false,
  });

  String get _fileName {
    return file.path.split(Platform.pathSeparator).last;
  }

  String get _fileSize {
    final bytes = file.lengthSync();
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get _modifiedDate {
    final modified = file.lastModifiedSync();
    return DateFormat('MMM dd, yyyy').format(modified);
  }

  @override
  Widget build(BuildContext context) {
    if (isListView) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          onTap: onTap,
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.picture_as_pdf,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: Text(
            _fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('$_fileSize • $_modifiedDate'),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              // Show context menu
            },
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail area
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Theme.of(context).colorScheme.primary.withOpacity(0.7),
                      Theme.of(context).colorScheme.secondary.withOpacity(0.7),
                    ],
                  ),
                ),
                child: Icon(
                  Icons.picture_as_pdf,
                  size: 64,
                  color: Colors.white,
                ),
              ),
            ),
            
            // File info
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fileSize,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  Text(
                    _modifiedDate,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
