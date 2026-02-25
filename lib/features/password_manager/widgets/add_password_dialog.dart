import 'package:flutter/material.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';
import '../../../models/password_model.dart';
import 'encryption_key_setup_dialog.dart';

/// Dialog for adding a new password with enhanced validation
class AddPasswordDialog extends StatefulWidget {
  const AddPasswordDialog({super.key});

  @override
  State<AddPasswordDialog> createState() => _AddPasswordDialogState();
}

class _AddPasswordDialogState extends State<AddPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _keyNameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final StorageService _storageService = StorageService();
  final EncryptionService _encryptionService = EncryptionService();
  
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;
  String? _keyNameError; // For real-time key name validation

  @override
  void initState() {
    super.initState();
    _keyNameController.addListener(_validateKeyName);
  }

  Future<void> _validateKeyName() async {
    final keyName = _keyNameController.text.trim();
    if (keyName.isEmpty) {
      setState(() => _keyNameError = null);
      return;
    }
    
    final exists = await _storageService.passwordKeyExists(keyName);
    setState(() {
      _keyNameError = exists ? 'Key name already exists' : null;
    });
  }

  Future<void> _savePassword() async {
    if (!_formKey.currentState!.validate()) return;
    if (_keyNameError != null) return; // Don't save if key name exists

    setState(() => _isLoading = true);

    try {
      // Check if encryption key is set first
      final hasKey = await _encryptionService.isKeySet();
      if (!hasKey) {
        final keySet = await showEncryptionKeySetupDialog(context);
        if (!keySet) {
          setState(() => _isLoading = false);
          return;
        }
      }

      // Check if password value already exists
      final allPasswords = await _storageService.getAllPasswords();
      for (final pwd in allPasswords) {
        final decrypted = await _encryptionService.decrypt(pwd.encryptedValue);
        if (decrypted == _passwordController.text) {
          // Password already exists - show popup
          setState(() => _isLoading = false);
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Password Exists'),
                ],
              ),
              content: Text(
                'This password already exists under the key name:\n\n"${pwd.keyName}"',
                style: const TextStyle(fontSize: 16),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
          return;
        }
      }

      // Encrypt password
      final encryptedPassword = await _encryptionService.encrypt(_passwordController.text);
      
      if (encryptedPassword == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Encryption failed. Please set encryption key first.')),
        );
        setState(() => _isLoading = false);
        return;
      }

      // Save to database
      final passwordModel = PasswordModel(
        keyName: _keyNameController.text.trim(),
        encryptedValue: encryptedPassword,
        createdAt: DateTime.now(),
      );

      await _storageService.insertPassword(passwordModel);
      
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving password: $e')),
      );
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Add New Password',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                
                // Key Name with real-time validation
                TextFormField(
                  controller: _keyNameController,
                  decoration: InputDecoration(
                    labelText: 'Key Name',
                    hintText: 'e.g., Work Documents',
                    prefixIcon: const Icon(Icons.label),
                    errorText: _keyNameError,
                    errorStyle: const TextStyle(color: Colors.red),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a key name';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                
                // Password
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock),
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
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a password';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                
                // Confirm Password
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirmPassword,
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirmPassword ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword = !_obscureConfirmPassword;
                        });
                      },
                    ),
                  ),
                  validator: (value) {
                    if (value != _passwordController.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                
                // Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isLoading ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: (_isLoading || _keyNameError != null) ? null : _savePassword,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _keyNameController.removeListener(_validateKeyName);
    _keyNameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}
