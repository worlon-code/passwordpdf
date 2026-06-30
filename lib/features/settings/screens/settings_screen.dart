import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
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
import '../widgets/color_picker_dialog.dart';
import '../../developer/screens/developer_screen.dart';
import '../../password_manager/screens/password_manager_screen.dart';
import '../../../main.dart';
import '../../update/services/update_service.dart';
import '../../update/models/update_info.dart';
import '../../update/widgets/update_dialogs.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
  String _biometricLabel = 'Biometric Authentication';
  String _biometricShortLabel = 'Biometric';
  IconData _biometricIcon = Icons.fingerprint;
  int _versionTapCount = 0;
  String _appVersion = '';
  String _buildNumber = '';


  @override
  void initState() {
    super.initState();
    _log.info('SettingsScreen', 'Screen initialized');
    _checkBiometricSupport();
    _loadAppVersion();
  }
  
  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = info.version;
        _buildNumber = info.buildNumber;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh encryption key status when screen is revisited
    _checkBiometricSupport();
  }

  Future<void> _checkBiometricSupport() async {
    final supported = await _biometricService.isDeviceSupported();
    final label = await _biometricService.getBiometricLabel();
    final shortLabel = label.replaceAll(' Unlock', '');
    final iconStr = await _biometricService.getBiometricIcon();
    
    IconData icon = Icons.fingerprint;
    if (iconStr == 'face') icon = Icons.face;
    if (iconStr == 'remove_red_eye') icon = Icons.visibility;

    if (mounted) {
      setState(() {
        _biometricSupported = supported;
        _biometricLabel = label;
        _biometricShortLabel = shortLabel;
        _biometricIcon = icon;
      });
    }
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
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red[400], 
              foregroundColor: Colors.white,
            ),
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



  Future<void> _openDebugLogs() async {
    final authorized = await showDeveloperPasswordDialog(
      context,
      title: 'Developer Access',
      description: 'Enter developer password to access developer tools',
    );

    if (authorized && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => const DeveloperScreen(),
        ),
      );
    }
  }
  
  Future<void> _showDeveloperPasswordDialog(SettingsService settings) async {
    final controller = TextEditingController();
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable Developer Mode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter developer password to unlock developer tools.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Developer Password',
                border: OutlineInputBorder(),
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
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    
    if (result == true) {
      if (controller.text == 'Portal123!') {
        await settings.enableDeveloperMode();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Developer mode enabled!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Incorrect password'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _showColorPicker(BuildContext context, SettingsService settings) {
    final colors = [
      const Color(0xFF6750A4), // Purple (default)
      const Color(0xFF0061A4), // Blue
      const Color(0xFF006E1C), // Green
      const Color(0xFFC00011), // Red
      const Color(0xFFB23B00), // Orange
      const Color(0xFF006874), // Teal
      const Color(0xFF4A5568), // Gray
      const Color(0xFF805AD5), // Violet
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Accent Color'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ...colors.map((color) => GestureDetector(
                  onTap: () {
                    settings.setAccentColor(color);
                    Navigator.pop(context);
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: settings.accentColor == color 
                          ? Border.all(color: Colors.white, width: 3)
                          : null,
                      boxShadow: settings.accentColor == color 
                          ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 8)]
                          : null,
                    ),
                    child: settings.accentColor == color 
                        ? const Icon(Icons.check, color: Colors.white)
                        : null,
                  ),
                )),
                // More button for advanced picker
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    _showAdvancedColorPicker(context, settings);
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                    child: const Icon(Icons.add, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showAdvancedColorPicker(BuildContext context, SettingsService settings) {
    showDialog(
      context: context,
      builder: (context) => ColorPickerDialog(settings: settings),
    );
  }

  void _showHexColorInput(BuildContext context, SettingsService settings) {
    final controller = TextEditingController(
      text: settings.accentColor.value.toRadixString(16).substring(2).toUpperCase(),
    );
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Hex Color'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                prefixText: '#',
                hintText: '6750A4',
                labelText: 'Hex Color Code',
                border: OutlineInputBorder(),
              ),
              maxLength: 6,
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 16),
            StatefulBuilder(
              builder: (context, setState) {
                Color? previewColor;
                try {
                  if (controller.text.length == 6) {
                    previewColor = Color(int.parse('FF${controller.text}', radix: 16));
                  }
                } catch (_) {}
                
                return Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: previewColor ?? Colors.grey.shade300,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                  child: previewColor == null 
                      ? const Icon(Icons.help_outline, color: Colors.grey)
                      : null,
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final hex = controller.text.replaceAll('#', '');
                if (hex.length == 6) {
                  final color = Color(int.parse('FF$hex', radix: 16));
                  settings.setAccentColor(color);
                  Navigator.pop(context);
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invalid hex color')),
                );
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
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
                return Column(
                  children: [
                    // Theme Dropdown
                    ListTile(
                      leading: const Icon(Icons.brightness_6),
                      title: const Text('Theme'),
                      trailing: DropdownButton<ThemeMode>(
                        value: settings.themeMode,
                        underline: const SizedBox(),
                        onChanged: (mode) {
                          if (mode != null) settings.setThemeMode(mode);
                        },
                        items: const [
                          DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                          DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                          DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // Accent Color Picker
                    ListTile(
                      leading: const Icon(Icons.palette),
                      title: const Text('Accent Color'),
                      trailing: GestureDetector(
                        onTap: () => _showColorPicker(context, settings),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: settings.accentColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    // Font Size Slider
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.text_fields, size: 20),
                              const SizedBox(width: 16),
                              const Text('Font Size'),
                              const Spacer(),
                              Text('${settings.fontSizeAdjustment}px', 
                                style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackShape: const RoundedRectSliderTrackShape(),
                              tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
                              activeTickMarkColor: Theme.of(context).colorScheme.primary,
                              inactiveTickMarkColor: Colors.grey,
                            ),
                            child: Slider(
                              min: -7,
                              max: 0,
                              divisions: 7,
                              value: settings.fontSizeAdjustment.toDouble(),
                              onChanged: (val) => settings.setFontSizeAdjustment(val.toInt()),
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Smaller', style: Theme.of(context).textTheme.bodySmall),
                              Text('Default', style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // Default Screen
                    ListTile(
                      leading: const Icon(Icons.home),
                      title: const Text('Default Screen'),
                      trailing: DropdownButton<int>(
                        value: settings.defaultScreenIndex,
                        underline: const SizedBox(),
                        onChanged: (index) {
                          if (index != null) settings.setDefaultScreenIndex(index);
                        },
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('All Docs')),
                          DropdownMenuItem(value: 1, child: Text('Documents')),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          
          const SizedBox(height: 24),

          // Downloads Section
          _buildSectionHeader('Downloads'),
          Card(
            child: Consumer<SettingsService>(
              builder: (context, settings, child) {
                final path = settings.exportPath;
                return ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('Download Location'),
                  subtitle: Text(path),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    AppEntry.ignoreNextPause = true; // Prevent auto-lock
                    final dir = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Select Download Location',
                    );
                    if (dir != null) {
                      await settings.setExportPath(dir);
                    }
                  },
                );
              },
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Passwords Section
          _buildSectionHeader('Passwords'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.password),
              title: const Text('Password Manager'),
              subtitle: const Text('Manage saved PDF passwords'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PasswordManagerScreen()),
              ),
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Security Section
          _buildSectionHeader('Security'),
          Card(
            child: Column(
              children: [
                // Biometric option
                Consumer<SettingsService>(
                  builder: (context, settings, child) {
                    return SwitchListTile(
                      title: Text(_biometricLabel),
                      subtitle: Text(
                        _biometricSupported
                            ? settings.biometricEnabled ? 'Enabled' : 'Disabled'
                            : 'Not supported',
                      ),
                      secondary: Icon(_biometricIcon),
                      value: settings.biometricEnabled,
                      onChanged: _biometricSupported
                          ? (value) async {
                              if (value) {
                                final authenticated = await _biometricService.authenticate(
                                  localizedReason: 'Authenticate to enable $_biometricShortLabel access',
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
                        authText = '$_biometricShortLabel only';
                        break;
                      case AuthMethod.both:
                        authText = '$_biometricShortLabel + PIN backup';
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
          
          // Auto-Lock Timer (Only visible if auth is enabled)
          Consumer<SettingsService>(
            builder: (context, settings, child) {
               if (!settings.biometricEnabled && !settings.hasPinSet) return const SizedBox.shrink();
               
               return Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   _buildSectionHeader('Auto-Lock'),
                   Card(
                     child: ListTile(
                       leading: const Icon(Icons.timer),
                       title: const Text('Auto-Lock Timer'),
                       subtitle: Text('${settings.autoLockTimeout} minutes'),
                       trailing: const Icon(Icons.chevron_right),
                       onTap: () {
                         showDialog(
                           context: context,
                           builder: (context) => AlertDialog(
                             title: const Text('Auto-Lock Timeout'),
                             content: StatefulBuilder(
                               builder: (context, setDialogState) {
                                 return Column(
                                   mainAxisSize: MainAxisSize.min,
                                   children: [
                                     Text('${settings.autoLockTimeout} minutes', 
                                       style: Theme.of(context).textTheme.headlineMedium),
                                     const SizedBox(height: 16),
                                     Slider(
                                       value: settings.autoLockTimeout.toDouble(),
                                       min: 3,
                                       max: 30,
                                       divisions: 27, // 1 minute steps
                                       label: '${settings.autoLockTimeout} min',
                                       onChanged: (val) {
                                         setDialogState(() {
                                            settings.setAutoLockTimeout(val.toInt());
                                         });
                                       },
                                     ),
                                     Row(
                                       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                       children: [
                                         Text('3 min', style: Theme.of(context).textTheme.bodySmall),
                                         Text('30 min', style: Theme.of(context).textTheme.bodySmall),
                                       ],
                                     ),
                                   ],
                                 );
                               },
                             ),
                             actions: [
                               TextButton(
                                 onPressed: () => Navigator.pop(context),
                                 child: const Text('Done'),
                               ),
                             ],
                           ),
                         );
                       },
                     ),
                   ),
                   const SizedBox(height: 24),
                 ],
               );
            },
          ),
          
          const SizedBox(height: 24),
          
          // Developer Section (Hidden until unlocked)
          Consumer<SettingsService>(
            builder: (context, settings, child) {
               if (!settings.developerModeEnabled) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('Developer'),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.build_circle),
                          title: const Text('Developer Tools'),
                          subtitle: const Text('Logs, Database & Export'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const DeveloperScreen()),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            },
          ),
          
          // About Section
          _buildSectionHeader('About'),
          Card(
            child: Column(
              children: [
                Consumer<SettingsService>(
                  builder: (context, settings, child) {
                    return ListTile(
                      leading: const Icon(Icons.info),
                      title: const Text('App Version'),
                      subtitle: Text(settings.developerModeEnabled 
                          ? '$_appVersion+$_buildNumber (Dev)' 
                          : '$_appVersion'),
                      onTap: () {
                        if (settings.developerModeEnabled) return;
                        
                        setState(() => _versionTapCount++);
                        
                        if (_versionTapCount >= 5) {
                          _versionTapCount = 0;
                          _showDeveloperPasswordDialog(settings);
                        } else if (_versionTapCount >= 3) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${5 - _versionTapCount} taps to unlock developer mode'),
                              duration: const Duration(milliseconds: 800),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
                const Divider(height: 1),
                // Auto-Update Toggle
                const Divider(height: 1),
                Consumer<SettingsService>(
                  builder: (context, settings, child) {
                    return SwitchListTile(
                      title: const Text('Check for updates on startup'),
                      subtitle: const Text('Automatically check using GitHub Releases'),
                      secondary: const Icon(Icons.update),
                      value: settings.autoCheckUpdates,
                      onChanged: (value) => settings.setAutoCheckUpdates(value),
                    );
                  },
                ),
                const Divider(height: 1),
                
                // Manual Check Tile with Red Dot
                ListTile(
                  leading: const Icon(Icons.system_update),
                  title: Row(
                    children: [
                      const Text('Check for Updates'),
                      const SizedBox(width: 8),
                      // Red Dot Indicator
                      ValueListenableBuilder<bool>(
                        valueListenable: Provider.of<UpdateService>(context, listen: false).updateAvailableNotifier,
                        builder: (context, hasUpdate, child) {
                          if (!hasUpdate) return const SizedBox.shrink();
                          return Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  onTap: () => _checkForUpdates(context),
                  trailing: const Icon(Icons.chevron_right),
                ),
                const Divider(height: 1),
                const ListTile(
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
      ),  // Close ListView
    );  // Close Scaffold
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

  Future<void> _checkForUpdates(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Checking for updates...')),
    );

    final service = UpdateService();
    final info = await service.checkForUpdate(force: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (info != null) {
      showDialog(
        context: context,
        barrierDismissible: !info.forceUpdate,
        builder: (ctx) => UpdateAvailableDialog(
          updateInfo: info,
          onUpdate: () => _performUpdate(ctx, service, info),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('App is up to date based on Public Release Channel')),
      );
    }
  }

  Future<void> _performUpdate(BuildContext context, UpdateService service, UpdateInfo info) async {
    bool started = false;
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
                         setDialogState(() {
                            progress = received / total;
                         });
                      }
                  }, expectedSha256: info.sha256).then((file) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext); // Close progress
                      
                      if (file != null) {
                         service.installUpdate(file);
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
}

