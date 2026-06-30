import 'package:flutter/material.dart';
import '../models/update_info.dart';
import '../services/update_service.dart';
import 'package:open_filex/open_filex.dart';

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
    return PopScope(
      canPop: !updateInfo.forceUpdate,
      child: AlertDialog(
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
    ),
    );
  }
}

class UpdateProgressDialog extends StatelessWidget {
  final double progress;

  const UpdateProgressDialog({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    return InvocationDialog(progress: progress);
  }
}

class InvocationDialog extends StatelessWidget {
  final double progress;
  const InvocationDialog({super.key, required this.progress});
  
  @override
  Widget build(BuildContext context) {
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

// Global Helper Functions
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
    showDialog(
      context: context,
      barrierDismissible: !info.forceUpdate,
      builder: (ctx) => UpdateAvailableDialog(
        updateInfo: info,
        onUpdate: () => performUpdate(ctx, info),
      ),
    );
}

Future<void> performUpdate(BuildContext context, UpdateInfo info) async {
    final service = UpdateService();
    bool started = false;
    // ignore: unused_local_variable
    double progress = 0;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
           builder: (context, setDialogState) {
              if (!started) {
                  started = true;
                  service.downloadUpdate(info.downloadUrl, (received, total) {
                      if (total != -1) {
                         try {
                           setDialogState(() {
                              progress = received / total;
                           });
                         } catch (e) {
                           // ignore
                         }
                      }
                  }, expectedSha256: info.sha256).then((file) async {
                      if (dialogContext.mounted) Navigator.pop(dialogContext); // Close progress
                      
                      if (file != null) {
                         final result = await service.installUpdate(file);
                         if (result.type != ResultType.done) {
                            if (context.mounted) {
                               ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Install failed: ${result.message}')),
                               );
                            }
                         }
                      } else {
                         if (context.mounted) {
                           ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Download failed')),
                           );
                         }
                      }
                  });
              }
              return UpdateProgressDialog(progress: progress);
           }
        );
      }
    );
}
