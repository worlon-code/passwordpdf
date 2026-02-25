import 'package:flutter/material.dart';
import '../../../services/document_service.dart';
import '../screens/folder_navigation_screen.dart';
import '../../../main.dart';

/// Dialog showing files that already exist in other folders
class DuplicateFilesDialog extends StatelessWidget {
  final List<DuplicateInfo> duplicates;

  const DuplicateFilesDialog({super.key, required this.duplicates});

  Map<String, List<DuplicateInfo>> get _groupedDuplicates {
    final map = <String, List<DuplicateInfo>>{};
    for (final dup in duplicates) {
      if (!map.containsKey(dup.fileName)) {
        map[dup.fileName] = [];
      }
      map[dup.fileName]!.add(dup);
    }
    return map;
  }

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
                itemCount: _groupedDuplicates.length,
                itemBuilder: (context, index) {
                  final fileName = _groupedDuplicates.keys.elementAt(index);
                  final dupes = _groupedDuplicates[fileName]!;
                  
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.insert_drive_file),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(fileName, 
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                  maxLines: 1, overflow: TextOverflow.ellipsis
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('Found in:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ...dupes.map((dup) => InkWell(
                            onTap: () {
                                Navigator.of(context).pop(); // Close dialog
                                DashboardFolderNavigation.pendingFolderId = dup.existingFolderId;
                                navigatorKey.currentState?.pushAndRemoveUntil(
                                  MaterialPageRoute(builder: (_) => const MainScreen(initialIndex: 1)),
                                  (route) => false,
                                );
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
                              child: Row(
                                children: [
                                  Icon(Icons.folder_open, size: 16, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          dup.locationDisplay,
                                          style: TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline),
                                        ),
                                        if (dup.existingName != fileName)
                                          Text(
                                            dup.existingName,
                                            style: const TextStyle(fontSize: 10, color: Colors.grey),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.grey),
                                ],
                              ),
                            ),
                          )),
                        ],
                      ),
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
