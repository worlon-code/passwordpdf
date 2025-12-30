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
  String? _keyNameError; // For real-time key name validation

  @override
  void initState() {
    super.initState();
    _loadPasswords();
    _keyNameController.addListener(_validateKeyName);
  }

  Future<void> _validateKeyName() async {
    if (!_saveNewPassword) return; // Only validate when saving
    final keyName = _keyNameController.text.trim();
    if (keyName.isEmpty) {
      setState(() => _keyNameError = null);
      return;
    }
    
    final exists = await _storageService.passwordKeyExists(keyName);
    if (mounted) {
      setState(() {
        _keyNameError = exists ? 'Key name already exists' : null;
      });
    }
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
      final decryptedPassword = await _encryptionService.decrypt(password.encryptedValue);
      if (decryptedPassword == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to decrypt password')),
        );
        return;
      }
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

      // Check if password value already exists
      final allPasswords = await _storageService.getAllPasswords();
      for (final pwd in allPasswords) {
        final decrypted = await _encryptionService.decrypt(pwd.encryptedValue);
        if (decrypted == password) {
          // Password already exists - show popup
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Password Exists'),
                ],
              ),
              content: Text(
                'This password already exists under key:\n\n"${pwd.keyName}"',
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
          return;
        }
      }

      // Save encrypted password
      try {
        final encryptedPassword = await _encryptionService.encrypt(password);
        if (encryptedPassword == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to encrypt password')),
          );
          return;
        }
        
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
                    errorText: _keyNameError,
                    errorStyle: const TextStyle(color: Colors.red),
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
                    onPressed: (_saveNewPassword && _keyNameError != null) ? null : _useNewPassword,
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
    _keyNameController.removeListener(_validateKeyName);
    _passwordController.dispose();
    _keyNameController.dispose();
    super.dispose();
  }
}
