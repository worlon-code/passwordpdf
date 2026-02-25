import 'package:flutter/material.dart';
import '../../../services/encryption_service.dart';

/// Dialog for setting up encryption key (one-time setup)
Future<bool> showEncryptionKeySetupDialog(BuildContext context, {bool force = false}) async {

  final encryptionService = EncryptionService();
  // Pre-fill with a random strong key by default
  final keyController = TextEditingController(text: encryptionService.generateRandomKey());
  bool obscureKey = false; // Show it by default so they can see the generated key
  
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: !force, // disallow dismiss if forced
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        return PopScope(
          canPop: !force, // Prevent back button if forced
          child: AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.vpn_key, color: Colors.amber),
              SizedBox(width: 12),
              Text('Setup Encryption Key'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This is a one-time setup. Your encryption key will be used to secure all password values.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: keyController,
                obscureText: obscureKey,
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
                             keyController.text = encryptionService.generateRandomKey();
                             // Make visible when generating
                             obscureKey = false;
                          });
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          obscureKey ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setState(() {
                            obscureKey = !obscureKey;
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
          actions: [
            if (!force)
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
            ElevatedButton(
              onPressed: () async {
                final key = keyController.text.trim();
                if (key.isEmpty || key.length < 6) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Key must be at least 6 characters')),
                  );
                  return;
                }
                
                final success = await encryptionService.setEncryptionKey(key);
                if (success) {
                  Navigator.pop(context, true);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Failed to set encryption key')),
                  );
                }
              },
              child: const Text('Set Key'),
            ),
          ],
        ),
        );
      },
    ),
  );
  
  keyController.dispose();
  return result ?? false;
}
