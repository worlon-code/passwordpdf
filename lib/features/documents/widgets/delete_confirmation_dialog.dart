import 'dart:async';
import 'package:flutter/material.dart';

class DeleteConfirmationDialog extends StatefulWidget {
  final int count;
  final bool isPermanent;
  final VoidCallback onConfirm;

  const DeleteConfirmationDialog({
    super.key,
    required this.count,
    required this.isPermanent,
    required this.onConfirm,
  });

  @override
  State<DeleteConfirmationDialog> createState() => _DeleteConfirmationDialogState();
}

class _DeleteConfirmationDialogState extends State<DeleteConfirmationDialog> {
  int _stage = 1;
  bool _canDelete = false;
  Timer? _timer;
  int _countdown = 1200; // milliseconds

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startStage2Timer() {
    setState(() {
      _stage = 2;
      _canDelete = false;
    });

    _timer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _canDelete = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == 1) {
      return AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
        title: const Text('Delete Permanently?'),
        content: Text(
          'Do you want to delete ${widget.count} file(s) permanently?\n\nThis cannot be undone.',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: _startStage2Timer,
            child: const Text('Delete'),
          ),
        ],
      );
    } else {
      return AlertDialog(
        icon: const Icon(Icons.delete_forever, color: Colors.red, size: 48),
        title: const Text('Final Confirmation'),
        content: const Text(
          'Are you absolutely sure?\n\nThese files will be removed from your device storage and CANNOT be recovered.',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: _canDelete 
              ? () {
                  widget.onConfirm();
                  Navigator.of(context).pop(true);
                }
              : null,
            child: Text(_canDelete ? 'Delete Forever' : 'Wait...'),
          ),
        ],
      );
    }
  }
}
