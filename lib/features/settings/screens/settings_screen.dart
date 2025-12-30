import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../services/settings_service.dart';
import '../../../services/biometric_service.dart';
import '../../../services/logging_service.dart';
import '../../../services/encryption_service.dart';
import '../../debug/screens/debug_logs_screen.dart';
import '../../authentication/screens/pin_entry_screen.dart';
import '../widgets/developer_password_dialog.dart';

/// Settings screen
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final BiometricService _biometricService = BiometricService();
  final LoggingService _log = LoggingService();
  final EncryptionService _encryptionService = EncryptionService();
  bool _biometricSupported = false;
  bool _encryptionKeySet = false;

  @override
  void initState() {
    super.initState();
    _log.info('SettingsScreen', 'Screen initialized');
    _checkBiometricSupport();
    _checkEncryptionKey();
  }

  Future<void> _checkBiometricSupport() async {
    final supported = await _biometricService.isDeviceSupported();
    setState(() {
      _biometricSupported = supported;
    });
  }

  Future<void> _checkEncryptionKey() async {
    final isSet = await _encryptionService.isKeySet();
    setState(() {
      _encryptionKeySet = isSet;
    });
  }

  void _setupPin(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PinEntryScreen(
          isSetupMode: true,
          onAuthenticated: () {
            Navigator.pop(context);
            setState(() {});
          },
        ),
      ),
    );
  }

  Future<void> _removePin(SettingsService settings) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove PIN'),
        content: const Text('Are you sure you want to remove your PIN?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await settings.removePin();
      setState(() {});
    }
  }

  Future<void> _setupEncryptionKey() async {
    final controller = TextEditingController();
    final generatedKey = _encryptionService.generateRandomKey(24);
    controller.text = generatedKey;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.key, color: Colors.amber),
            SizedBox(width: 8),
            Text('Set Encryption Key'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This key will be used to encrypt all your stored passwords. '
              'You can enter your own key or use the generated one.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              '⚠️ WARNING: This cannot be changed later!',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Encryption Key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Generate new key',
                  onPressed: () {
                    controller.text = _encryptionService.generateRandomKey(24);
                  },
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Set Key'),
          ),
        ],
      ),
    );

    if (result == true && controller.text.isNotEmpty) {
      final success = await _encryptionService.setEncryptionKey(controller.text);
      if (success) {
        setState(() {
          _encryptionKeySet = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Encryption key set successfully')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to set encryption key'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _viewEncryptionKey() async {
    final authorized = await showDeveloperPasswordDialog(
      context,
      title: 'View Encryption Key',
      description: 'Enter developer password to view the encryption key',
    );

    if (authorized) {
      final key = await _encryptionService.getEncryptionKey('Portal123!');
      if (key != null && mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.key, color: Colors.amber),
                SizedBox(width: 8),
                Text('Encryption Key'),
              ],
            ),
            content: SelectableText(
              key,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _openDebugLogs() async {
    final authorized = await showDeveloperPasswordDialog(
      context,
      title: 'Debug Logs Access',
      description: 'Enter developer password to access debug logs',
    );

    if (authorized && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => const DebugLogsScreen(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Appearance Section
          _buildSectionHeader('Appearance'),
          Card(
            child: Consumer<SettingsService>(
              builder: (context, settings, child) {
                return SwitchListTile(
                  title: const Text('Dark Mode'),
                  subtitle: Text(
                    settings.isDarkMode ? 'Dark theme enabled' : 'Light theme enabled',
                  ),
                  secondary: Icon(
                    settings.isDarkMode ? Icons.dark_mode : Icons.light_mode,
                  ),
                  value: settings.isDarkMode,
                  onChanged: (value) {
                    settings.toggleDarkMode();
                  },
                );
              },
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Security Section
          _buildSectionHeader('Security'),
          Card(
            child: Column(
              children: [
                // Fingerprint option
                Consumer<SettingsService>(
                  builder: (context, settings, child) {
                    return SwitchListTile(
                      title: const Text('Fingerprint Authentication'),
                      subtitle: Text(
                        _biometricSupported
                            ? settings.biometricEnabled ? 'Enabled' : 'Disabled'
                            : 'Not supported',
                      ),
                      secondary: const Icon(Icons.fingerprint),
                      value: settings.biometricEnabled,
                      onChanged: _biometricSupported
                          ? (value) async {
                              if (value) {
                                final authenticated = await _biometricService.authenticate(
                                  localizedReason: 'Authenticate to enable fingerprint lock',
                                );
                                if (authenticated) {
                                  settings.setBiometricEnabled(true);
                                }
                              } else {
                                settings.setBiometricEnabled(false);
                              }
                            }
                          : null,
                    );
                  },
                ),
                
                const Divider(height: 1),
                
                // PIN option
                Consumer<SettingsService>(
                  builder: (context, settings, child) {
                    return ListTile(
                      leading: const Icon(Icons.pin),
                      title: const Text('PIN Lock'),
                      subtitle: Text(settings.hasPinSet ? 'PIN is set' : 'No PIN set'),
                      trailing: settings.hasPinSet
                          ? TextButton(
                              onPressed: () => _removePin(settings),
                              child: const Text('Remove'),
                            )
                          : ElevatedButton(
                              onPressed: () => _setupPin(context),
                              child: const Text('Set PIN'),
                            ),
                    );
                  },
                ),
                
                const Divider(height: 1),
                
                // Current auth method
                Consumer<SettingsService>(
                  builder: (context, settings, child) {
                    String authText;
                    switch (settings.authMethod) {
                      case AuthMethod.none:
                        authText = 'No protection';
                        break;
                      case AuthMethod.pinOnly:
                        authText = 'PIN only';
                        break;
                      case AuthMethod.fingerprintOnly:
                        authText = 'Fingerprint only';
                        break;
                      case AuthMethod.both:
                        authText = 'Fingerprint + PIN backup';
                        break;
                    }
                    return ListTile(
                      leading: const Icon(Icons.security),
                      title: const Text('Current Protection'),
                      subtitle: Text(authText),
                    );
                  },
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Encryption Section
          _buildSectionHeader('Encryption'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.key,
                    color: _encryptionKeySet ? Colors.green : Colors.orange,
                  ),
                  title: const Text('Encryption Key'),
                  subtitle: Text(
                    _encryptionKeySet ? 'Key is set' : 'No key set - tap to configure',
                  ),
                  trailing: _encryptionKeySet
                      ? IconButton(
                          icon: const Icon(Icons.visibility),
                          tooltip: 'View key (requires password)',
                          onPressed: _viewEncryptionKey,
                        )
                      : ElevatedButton(
                          onPressed: _setupEncryptionKey,
                          child: const Text('Set Key'),
                        ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Developer Section
          _buildSectionHeader('Developer'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bug_report),
                  title: const Text('Debug Logs'),
                  subtitle: Text('${_log.logs.length} entries (password protected)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openDebugLogs,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('Refresh Status'),
                  onTap: () {
                    _checkBiometricSupport();
                    _checkEncryptionKey();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Status refreshed')),
                    );
                  },
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // About Section
          _buildSectionHeader('About'),
          Card(
            child: Column(
              children: const [
                ListTile(
                  leading: Icon(Icons.info),
                  title: Text('App Version'),
                  subtitle: Text('0.0.7'),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.description),
                  title: Text('PDF Password Manager'),
                  subtitle: Text('Secure PDF & Password Management'),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Security Info
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.security,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Secure & Private',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Your data is encrypted and stored locally. Nothing is sent to external servers.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

