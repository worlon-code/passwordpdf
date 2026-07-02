import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../../../models/password_model.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/password_backup_service.dart';
import '../../settings/services/settings_service.dart';

import '../../documents/screens/file_system_browser.dart';
import '../widgets/add_password_dialog.dart';
import '../widgets/restore_conflict_table.dart';
import '../widgets/restore_file_picker.dart';

/// Password manager screen to view and manage saved passwords
class PasswordManagerScreen extends StatefulWidget {
  const PasswordManagerScreen({super.key});

  @override
  State<PasswordManagerScreen> createState() => _PasswordManagerScreenState();
}

class _PasswordManagerScreenState extends State<PasswordManagerScreen> {
  final StorageService _storageService = StorageService();
  final EncryptionService _encryptionService = EncryptionService();

  PasswordBackupService get _backup =>
      PasswordBackupService(_storageService, _encryptionService);

  Future<String?> _promptPassphrase({required bool confirm}) async {
    final p1 = TextEditingController();
    final p2 = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setLocal) => AlertDialog(
                  title: Text(
                    confirm ? 'Set backup passphrase' : 'Enter passphrase',
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: p1,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Passphrase',
                        ),
                      ),
                      if (confirm)
                        TextField(
                          controller: p2,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Confirm passphrase',
                          ),
                        ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        final a = p1.text;
                        if (a.trim().isEmpty) {
                          setLocal(() => error = 'Passphrase required');
                          return;
                        }
                        if (confirm && a != p2.text) {
                          setLocal(() => error = 'Passphrases do not match');
                          return;
                        }
                        Navigator.pop(ctx, a);
                      },
                      child: const Text('OK'),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _onBackup() async {
    final pass = await _promptPassphrase(confirm: true);
    if (pass == null) return;
    try {
      final bytes = await _backup.createBackup(pass);
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Backup ready'),
              content: const Text('Save it to your device, or share it?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'save'),
                  child: const Text('Save to device'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'share'),
                  child: const Text('Share'),
                ),
              ],
            ),
      );
      if (choice == null) return;
      final fileName =
          'passwords-${DateTime.now().millisecondsSinceEpoch}.json';
      if (choice == 'save') {
        final backupDir = Directory(
          p.join(SettingsService().exportPath, 'Backup'),
        );
        if (!await backupDir.exists()) {
          await backupDir.create(recursive: true);
        }
        final outFile = File(p.join(backupDir.path, fileName));
        await outFile.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Saved to ${outFile.path}')));
        }
      } else {
        final tmp = await getTemporaryDirectory();
        final file = File(p.join(tmp.path, fileName));
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles([
          XFile(file.path),
        ], text: 'Password Manager backup');
      }
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Backup failed: $e')));
      }
    }
  }

  Future<void> _onRestore() async {
    if (!await _encryptionService.isKeySet()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Set an encryption key first, then restore your backup.',
            ),
          ),
        );
      }
      return;
    }
    final backupDir = Directory(p.join(SettingsService().exportPath, 'Backup'));
    final initialPath = backupDir.existsSync()
        ? backupDir.path
        : (Directory('/storage/emulated/0/Download').existsSync()
            ? '/storage/emulated/0/Download'
            : null);
    final paths = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FileSystemBrowser(
          initialPath: initialPath,
          allowedExtensions: const ['json'],
          allowMultiple: false,
        ),
      ),
    );
    if (paths == null || paths.isEmpty || !mounted) return;
    final path = paths.first;
    final pass = await _promptPassphrase(confirm: false);
    if (pass == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      final conflicts = await _backup.restoreFromBytes(bytes, pass);
      if (!mounted) return;
      final needReview = <RestoreConflict>[];
      for (final c in conflicts) {
        switch (c.status) {
          case ConflictStatus.fresh:
          case ConflictStatus.sameNameDiffSecret:
            c.resolution = ConflictResolution.keepBoth;
            break;
          case ConflictStatus.sameNameSameSecret:
            c.resolution = ConflictResolution.skip;
            break;
          case ConflictStatus.sameSecretDiffName:
            needReview.add(c);
            break;
        }
      }
      if (needReview.isNotEmpty) {
        final reviewed = await Navigator.of(
          context,
        ).push<List<RestoreConflict>>(
          MaterialPageRoute(
            builder: (_) => RestoreConflictTable(conflicts: needReview),
          ),
        );
        if (reviewed == null) return;
      }
      final n = await _backup.applyRestore(conflicts);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Imported $n password(s)')));
        await _loadPasswords();
      }
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    }
  }

  List<PasswordModel> _passwords = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadPasswords();
  }

  Future<void> _loadPasswords() async {
    setState(() => _isLoading = true);
    try {
      final passwords = await _storageService.getAllPasswords();
      setState(() {
        _passwords = passwords;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Error loading passwords: $e');
    }
  }

  Future<void> _addPassword() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => const AddPasswordDialog(),
    );

    if (result == true) {
      _loadPasswords();
    }
  }

  Future<void> _deletePassword(PasswordModel password) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Delete Password'),
            content: Text(
              'Are you sure you want to delete "${password.keyName}"?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirm == true && password.id != null) {
      try {
        await _storageService.deletePassword(password.id!);
        _loadPasswords();
        _showSuccess('Password deleted');
      } catch (e) {
        _showError('Error deleting password: $e');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  Future<void> _renamePassword(PasswordModel password) async {
    final controller = TextEditingController(text: password.keyName);

    final newName = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Rename Password Key'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'New Key Name',
                hintText: 'e.g., Gmail Account',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed:
                    () => Navigator.pop(dialogContext, controller.text.trim()),
                child: const Text('Rename'),
              ),
            ],
          ),
    );

    // Handle rename after dialog closes
    if (newName != null && newName.isNotEmpty && newName != password.keyName) {
      try {
        // Check if new name already exists
        final exists = await _storageService.passwordKeyExists(newName);
        if (exists) {
          _showError('A password with this key name already exists');
          return;
        }

        await _storageService.renamePassword(password.id!, newName);
        _loadPasswords();
        _showSuccess('Password key renamed');
      } catch (e) {
        _showError('Error renaming password: $e');
      }
    }
  }

  List<PasswordModel> get _filteredPasswords {
    if (_searchQuery.isEmpty) return _passwords;
    return _passwords.where((pwd) {
      return pwd.keyName.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Password Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.backup_outlined),
            tooltip: 'Backup',
            onPressed: _onBackup,
          ),
          IconButton(
            icon: const Icon(Icons.restore_outlined),
            tooltip: 'Restore',
            onPressed: _onRestore,
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: 'Search passwords...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Passwords list
          Expanded(
            child:
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _filteredPasswords.isEmpty
                    ? RefreshIndicator(
                      onRefresh: _loadPasswords,
                      child: LayoutBuilder(
                        builder:
                            (context, constraints) => SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: SizedBox(
                                height: constraints.maxHeight,
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.vpn_key_off,
                                        size: 100,
                                        color: Colors.grey.shade400,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        _searchQuery.isEmpty
                                            ? 'No passwords saved yet'
                                            : 'No passwords found',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge?.copyWith(
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      if (_searchQuery.isEmpty)
                                        Text(
                                          'Tap + to add a password',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium?.copyWith(
                                            color: Colors.grey.shade500,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                      ),
                    )
                    : RefreshIndicator(
                      onRefresh: _loadPasswords,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _filteredPasswords.length,
                        itemBuilder: (context, index) {
                          final password = _filteredPasswords[index];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.vpn_key,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              title: Text(
                                password.keyName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'Created: ${password.createdAt.toString().split(' ')[0]}',
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) async {
                                  if (value == 'rename') {
                                    await _renamePassword(password);
                                  } else if (value == 'delete') {
                                    await _deletePassword(password);
                                  }
                                },
                                itemBuilder:
                                    (context) => [
                                      const PopupMenuItem(
                                        value: 'rename',
                                        child: Row(
                                          children: [
                                            Icon(Icons.edit),
                                            SizedBox(width: 8),
                                            Text('Rename'),
                                          ],
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.delete,
                                              color: Colors.red,
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              'Delete',
                                              style: TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPassword,
        icon: const Icon(Icons.add),
        label: const Text('Add Password'),
      ),
    );
  }
}
