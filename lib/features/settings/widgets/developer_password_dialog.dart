import 'package:flutter/material.dart';
import '../../../services/encryption_service.dart';

/// Widget to prompt for developer password
class DeveloperPasswordDialog extends StatefulWidget {
  final String title;
  final String description;
  
  const DeveloperPasswordDialog({
    super.key,
    this.title = 'Developer Access',
    this.description = 'Enter developer password to continue',
  });

  @override
  State<DeveloperPasswordDialog> createState() => _DeveloperPasswordDialogState();
}

class _DeveloperPasswordDialogState extends State<DeveloperPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  final EncryptionService _encryptionService = EncryptionService();
  bool _obscurePassword = true;
  String? _errorMessage;

  void _submit() {
    final password = _passwordController.text;
    
    if (_encryptionService.verifyDeveloperPassword(password)) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _errorMessage = 'Invalid password';
      });
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.lock, color: Colors.orange),
          const SizedBox(width: 8),
          Text(widget.title),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.description),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              errorText: _errorMessage,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () {
                  setState(() {
                    _obscurePassword = !_obscurePassword;
                  });
                },
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Verify'),
        ),
      ],
    );
  }
}

/// Show developer password dialog
Future<bool> showDeveloperPasswordDialog(BuildContext context, {
  String title = 'Developer Access',
  String description = 'Enter developer password to continue',
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => DeveloperPasswordDialog(
      title: title,
      description: description,
    ),
  );
  
  return result ?? false;
}
