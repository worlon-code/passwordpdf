import 'package:flutter/material.dart';
import '../../../services/document_service.dart';
import '../screens/folder_navigation_screen.dart';
import '../../../main.dart';

/// Dialog showing files that already exist in other folders
class DuplicateFilesDialog extends StatelessWidget {
  final List<DuplicateInfo> duplicates;

  const DuplicateFilesDialog({super.key, required this.duplicates});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Text('Files Already Exist'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The following files were found in your library:',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: duplicates.length,
                itemBuilder: (context, index) {
                  final dup = duplicates[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.insert_drive_file),
                      title: Text(dup.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        'In: ${dup.locationDisplay}',
                        style: TextStyle(color: Theme.of(context).colorScheme.primary),
                      ),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () {
                        // Navigate to folder
                        Navigator.of(context).pop(); // Close dialog
                        DashboardFolderNavigation.pendingFolderId = dup.existingFolderId;
                        navigatorKey.currentState?.pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const MainScreen()),
                          (route) => false,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Import Anyway'),
        ),
      ],
    );
  }
}
