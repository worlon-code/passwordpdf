import 'package:flutter/material.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';
import '../../../models/password_model.dart';

/// Dialog for selecting or entering PDF password
class PasswordSelectionDialog extends StatefulWidget {
  const PasswordSelectionDialog({super.key});

  @override
  State<PasswordSelectionDialog> createState() => _PasswordSelectionDialogState();
}

class _PasswordSelectionDialogState extends State<PasswordSelectionDialog> {
  final StorageService _storageService = StorageService();
  final EncryptionService _encryptionService = EncryptionService();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _keyNameController = TextEditingController();
  
  List<PasswordModel> _savedPasswords = [];
  bool _isLoading = true;
  bool _showNewPasswordInput = false;
  bool _saveNewPassword = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _loadPasswords();
  }

  Future<void> _loadPasswords() async {
    try {
      final passwords = await _storageService.getAllPasswords();
      setState(() {
        _savedPasswords = passwords;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _useSelectedPassword(PasswordModel password) async {
    try {
      final decryptedPassword = _encryptionService.decrypt(password.encryptedValue);
      Navigator.of(context).pop(decryptedPassword);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _useNewPassword() async {
    final password = _passwordController.text.trim();
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a password')),
      );
      return;
    }

    // Save password if requested
    if (_saveNewPassword) {
      final keyName = _keyNameController.text.trim();
      if (keyName.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a key name')),
        );
        return;
      }

      // Check if key name already exists
      final exists = await _storageService.passwordKeyExists(keyName);
      if (exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Key name already exists')),
        );
        return;
      }

      // Save encrypted password
      try {
        final encryptedPassword = _encryptionService.encrypt(password);
        final passwordModel = PasswordModel(
          keyName: keyName,
          encryptedValue: encryptedPassword,
          createdAt: DateTime.now(),
        );
        await _storageService.insertPassword(passwordModel);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving password: $e')),
        );
      }
    }

    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 600),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Select Password',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            
            // Saved passwords list
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (_savedPasswords.isNotEmpty && !_showNewPasswordInput) ...[
              Text(
                'Saved Passwords:',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _savedPasswords.length,
                  itemBuilder: (context, index) {
                    final password = _savedPasswords[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.vpn_key),
                        title: Text(password.keyName),
                        subtitle: Text(
                          'Created: ${password.createdAt.toString().split(' ')[0]}',
                        ),
                        onTap: () => _useSelectedPassword(password),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
            ],
            
            // New password option
            if (!_showNewPasswordInput)
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _showNewPasswordInput = true;
                  });
                },
                icon: const Icon(Icons.add),
                label: const Text('Enter New Password'),
              )
            else ...[
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
              ),
              const SizedBox(height: 16),
              
              // Save password option
              CheckboxListTile(
                value: _saveNewPassword,
                onChanged: (value) {
                  setState(() {
                    _saveNewPassword = value ?? false;
                  });
                },
                title: const Text('Save this password'),
                dense: true,
              ),
              
              if (_saveNewPassword) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _keyNameController,
                  decoration: InputDecoration(
                    labelText: 'Key Name (label)',
                    hintText: 'e.g., Work Documents',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
              
              const SizedBox(height: 16),
              
              // Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _showNewPasswordInput = false;
                        _passwordController.clear();
                        _keyNameController.clear();
                        _saveNewPassword = false;
                      });
                    },
                    child: const Text('Back'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _useNewPassword,
                    child: const Text('Use Password'),
                  ),
                ],
              ),
            ],
            
            if (!_showNewPasswordInput)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(''); // Empty password (no password)
                },
                child: const Text('No Password'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _keyNameController.dispose();
    super.dispose();
  }
}
