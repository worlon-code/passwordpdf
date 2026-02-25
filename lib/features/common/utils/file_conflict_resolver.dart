import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

class FileConflictResolver {
  static Future<String?> resolve({
    required BuildContext context,
    required String filePath,
  }) async {
    var currentPath = filePath;
    
    // Loop until we find a non-existing path or user resolves conflict
    while (await File(currentPath).exists()) {
      if (!context.mounted) return null;

      final filename = path.basename(currentPath);
      final result = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('File Already Exists'),
          content: Text('The file "$filename" already exists in the destination folder.\n\nWhat would you like to do?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'rename'),
              child: const Text('Rename'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, 'overwrite'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );

      if (result == 'cancel' || result == null) {
        return null;
      } else if (result == 'overwrite') {
        return currentPath;
      } else if (result == 'rename') {
        if (!context.mounted) return null;
        
        final newName = await showDialog<String>(
          context: context,
          builder: (context) {
            final controller = TextEditingController(text: filename);
            return AlertDialog(
              title: const Text('Rename File'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'New Filename'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, controller.text),
                  child: const Text('Rename'),
                ),
              ],
            );
          },
        );

        if (newName != null && newName.isNotEmpty) {
          final dir = path.dirname(currentPath);
          currentPath = path.join(dir, newName);
          // Loop continues to check if NEW name also exists
        } else {
          return null; // Cancelled rename
        }
      }
    }

    return currentPath;
  }
}
