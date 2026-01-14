import 'package:flutter/material.dart';
import '../models/update_info.dart';

class WhatsNewDialog extends StatelessWidget {
  final UpdateInfo updateInfo;
  final VoidCallback onDismiss;

  const WhatsNewDialog({
    super.key,
    required this.updateInfo,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Column(
        children: [
          const Icon(Icons.celebration, size: 48, color: Colors.amber),
          const SizedBox(height: 16),
          Text('Updated to v${updateInfo.version}'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'What\'s New:',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(updateInfo.releaseNotes),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: onDismiss,
          child: const Text('Awesome!'),
        ),
      ],
    );
  }
}
