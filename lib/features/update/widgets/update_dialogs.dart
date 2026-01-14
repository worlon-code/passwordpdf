import 'package:flutter/material.dart';
import '../models/update_info.dart';

class UpdateAvailableDialog extends StatelessWidget {
  final UpdateInfo updateInfo;
  final VoidCallback onUpdate;

  const UpdateAvailableDialog({
    super.key,
    required this.updateInfo,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update, color: Colors.blue),
          const SizedBox(width: 8),
          const Text('Update Available'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version ${updateInfo.version} (Build ${updateInfo.buildNumber}) is ready to install.', 
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            const Text('What\'s New:', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(updateInfo.releaseNotes.isEmpty 
                  ? 'Performance improvements and bug fixes.' 
                  : updateInfo.releaseNotes),
            ),
          ],
        ),
      ),
      actions: [
        if (!updateInfo.forceUpdate)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
        StatefulBuilder(
          builder: (context, setState) {
             return ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                onUpdate();
              },
              child: const Text('Download & Install'),
            );
          }
        ),
      ],
    );
  }
}

class UpdateProgressDialog extends StatelessWidget {
  final double progress;

  const UpdateProgressDialog({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    return InvocationDialog(progress: progress); // Internal helper
  }
}

// Separate stateful widget to handle progress updates cleanly if we used a stream
// But since we are passing progress, we likely rebuild the dialog or use StateSetter
class InvocationDialog extends StatelessWidget {
  final double progress;
  const InvocationDialog({super.key, required this.progress});
  
  @override
  Widget build(BuildContext context) {
    // PopScope prevents back button during download
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Downloading... ${(progress * 100).toInt()}%',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress, minHeight: 8),
          ],
        ),
      ),
    );
  }
}
