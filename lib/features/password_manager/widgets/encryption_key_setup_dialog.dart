import 'package:flutter/material.dart';
import '../../../services/encryption_service.dart';

/// Dialog for setting up encryption key (one-time setup)
Future<bool> showEncryptionKeySetupDialog(BuildContext context, {bool force = false}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: !force,
    builder: (context) => _EncryptionKeySetupDialog(force: force),
  );
  return result ?? false;
}

class _EncryptionKeySetupDialog extends StatefulWidget {
  final bool force;
  const _EncryptionKeySetupDialog({required this.force});

  @override
  State<_EncryptionKeySetupDialog> createState() => _EncryptionKeySetupDialogState();
}

class _EncryptionKeySetupDialogState extends State<_EncryptionKeySetupDialog> {
  final _encryptionService = EncryptionService();
  late final TextEditingController _keyController;
  bool _obscureKey = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: _encryptionService.generateRandomKey());
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.force,
      child: AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.vpn_key, color: Colors.amber),
            SizedBox(width: 12),
            Expanded(child: Text('Setup Encryption Key')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This is a one-time setup. Your encryption key will be used to secure all password values.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _keyController,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: 'Encryption Key',
                  hintText: 'Enter a strong key',
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Generate Random Key',
                        onPressed: () {
                          setState(() {
                            _keyController.text = _encryptionService.generateRandomKey();
                            _obscureKey = false;
                          });
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          _obscureKey ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureKey = !_obscureKey;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '⚠️ Remember this key! You cannot recover it if lost.',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ],
          ),
        ),
        actions: [
          if (!widget.force)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
          ElevatedButton(
            onPressed: _isLoading
                ? null
                : () async {
                    final key = _keyController.text.trim();
                    final messenger = ScaffoldMessenger.of(context);
                    final navigator = Navigator.of(context);
                    if (key.isEmpty || key.length < 6) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Key must be at least 6 characters')),
                      );
                      return;
                    }

                    setState(() => _isLoading = true);
                    final success = await _encryptionService.setEncryptionKey(key);
                    if (!mounted) return;
                    setState(() => _isLoading = false);

                    if (success) {
                      navigator.pop(true);
                    } else {
                      _keyController.clear();
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Failed to set encryption key')),
                      );
                    }
                  },
            child: _isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Set Key'),
          ),
        ],
      ),
    );
  }
}
