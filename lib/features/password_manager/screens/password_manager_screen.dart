import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../../../models/password_model.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/password_backup_service.dart';
import '../../../services/biometric_service.dart';
import '../../settings/services/settings_service.dart';

import '../../documents/screens/file_system_browser.dart';
import '../widgets/add_password_dialog.dart';
import '../widgets/restore_conflict_table.dart';

/// Password manager screen to view and manage saved passwords
class PasswordManagerScreen extends StatefulWidget {
  const PasswordManagerScreen({super.key});

  @override
  State<PasswordManagerScreen> createState() => _PasswordManagerScreenState();
}

class _PasswordManagerScreenState extends State<PasswordManagerScreen> {
  final StorageService _storageService = StorageService();
  final EncryptionService _encryptionService = EncryptionService();
  final BiometricService _biometricService = BiometricService();

  Future<bool> _authenticateForSensitiveAction({
    String reason = 'Authenticate to access password',
  }) async {
    final available = await _biometricService.isBiometricAvailable();
    if (available) {
      final ok = await _biometricService.authenticate(localizedReason: reason);
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Authentication required to reveal or copy password'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return false;
      }
    }
    return true;
  }

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
    // No legacy-key gate here: restore must work on a fresh install / after a
    // Keystore wipe (there may be no legacy key). Readiness is enforced inside
    // applyRestore via adoptCurrentV2KeyAsHealthy(), which throws FormatException
    // (caught below) if the device key is unusable.
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
  String? _selectedTagFilter;
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadPasswords();
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadPasswords() async {
    setState(() => _isLoading = true);
    try {
      final rawPasswords = await _storageService.getAllPasswords();
      final decryptedList = <PasswordModel>[];
      for (final p in rawPasswords) {
        List<String> tags = p.tags;
        if (p.encryptedTags != null && p.encryptedTags!.isNotEmpty) {
          try {
            final dec = await _encryptionService.decrypt(p.encryptedTags!);
            if (dec != null && dec.isNotEmpty) {
              tags = dec
                  .split(',')
                  .map((t) => t.trim())
                  .where((t) => t.isNotEmpty)
                  .toList();
            }
          } catch (_) {}
        }
        decryptedList.add(p.copyWith(tags: tags));
      }
      setState(() {
        _passwords = decryptedList;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Error loading passwords: $e');
    }
  }

  Set<String> get _allTags {
    final tags = <String>{};
    for (final p in _passwords) {
      tags.addAll(p.tags);
    }
    return tags;
  }

  Future<void> _toggleFavorite(PasswordModel password) async {
    try {
      final updated = password.copyWith(isFavorite: !password.isFavorite);
      await _storageService.updatePassword(updated);
      await _loadPasswords();
    } catch (e) {
      _showError('Failed to update favorite: $e');
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
    var list = _passwords;
    if (_selectedTagFilter == 'favorites') {
      list = list.where((p) => p.isFavorite).toList();
    } else if (_selectedTagFilter != null && _selectedTagFilter!.isNotEmpty) {
      list = list.where((p) => p.tags.contains(_selectedTagFilter)).toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((pwd) {
        final matchesName = pwd.keyName.toLowerCase().contains(q);
        final matchesTag = pwd.tags.any((t) => t.toLowerCase().contains(q));
        return matchesName || matchesTag;
      }).toList();
    }
    return list;
  }

  Future<void> _showPasswordDetails(PasswordModel initialPassword) async {
    PasswordModel password = initialPassword;
    bool obscure = true;
    String? plainText;
    List<Map<String, dynamic>>? history;
    bool loadingHistory = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          password.keyName,
                          style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          password.isFavorite ? Icons.star : Icons.star_border,
                          color: password.isFavorite ? Colors.amber : null,
                        ),
                        tooltip: 'Toggle Favorite',
                        onPressed: () async {
                          await _toggleFavorite(password);
                          final updated = _passwords.firstWhere(
                            (p) => p.id == password.id,
                            orElse: () => password,
                          );
                          setModalState(() {
                            password = updated;
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Password display box
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            obscure
                                ? '••••••••••••'
                                : (plainText ?? 'Failed to decrypt'),
                            style: TextStyle(
                              fontFamily: obscure ? null : 'monospace',
                              fontSize: 16,
                              letterSpacing: obscure ? 2 : 0,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                          onPressed: () async {
                            if (obscure) {
                              final auth = await _authenticateForSensitiveAction(
                                reason: 'Authenticate to reveal password',
                              );
                              if (!auth) return;

                              if (plainText == null) {
                                final dec = await _encryptionService.decrypt(password.encryptedValue);
                                setModalState(() {
                                  plainText = dec;
                                  obscure = false;
                                });
                              } else {
                                setModalState(() => obscure = false);
                              }
                            } else {
                              setModalState(() => obscure = true);
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: 'Copy Password',
                          onPressed: () async {
                            final auth = await _authenticateForSensitiveAction(
                              reason: 'Authenticate to copy password',
                            );
                            if (!auth) return;

                            final secret = plainText ??
                                await _encryptionService.decrypt(password.encryptedValue);
                            if (secret != null && secret.isNotEmpty) {
                              await Clipboard.setData(ClipboardData(text: secret));
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Password copied to clipboard')),
                                );
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Tags
                  Text(
                    'Tags',
                    style: Theme.of(ctx).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 6),
                  if (password.tags.isEmpty)
                    Text(
                      'No tags assigned',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: password.tags.map((t) => Chip(
                        label: Text(t, style: const TextStyle(fontSize: 12)),
                        padding: EdgeInsets.zero,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )).toList(),
                    ),
                  const SizedBox(height: 20),
                  // Password History Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Password History (Last 5)',
                        style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.history, size: 18),
                        label: Text(history == null ? 'Show' : 'Hide'),
                        onPressed: () async {
                          if (history == null) {
                            setModalState(() => loadingHistory = true);
                            final hist = await _storageService.getPasswordHistory(password.id!);
                            setModalState(() {
                              history = hist;
                              loadingHistory = false;
                            });
                          } else {
                            setModalState(() => history = null);
                          }
                        },
                      ),
                    ],
                  ),
                  if (loadingHistory)
                    const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
                  if (history != null) ...[
                    if (history!.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No previous password versions recorded.',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                        ),
                      )
                    else
                      ...history!.map((entry) {
                        final changedAt = DateTime.fromMillisecondsSinceEpoch(entry['changed_at'] as int);
                        final encVal = entry['encrypted_value'] as String;
                        return Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Changed: ${changedAt.toLocal().toString().split('.')[0]}',
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                  ),
                                  const SizedBox(height: 2),
                                  const Text('••••••••', style: TextStyle(letterSpacing: 2, fontSize: 12)),
                                ],
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 18),
                                    tooltip: 'Copy Old Password',
                                    onPressed: () async {
                                      final auth = await _authenticateForSensitiveAction(
                                        reason: 'Authenticate to copy historical password',
                                      );
                                      if (!auth) return;

                                      final dec = await _encryptionService.decrypt(encVal);
                                      if (dec != null) {
                                        await Clipboard.setData(ClipboardData(text: dec));
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('Old password copied')),
                                          );
                                        }
                                      }
                                    },
                                  ),
                                  OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(horizontal: 10),
                                    ),
                                    onPressed: () async {
                                      final confirm = await showDialog<bool>(
                                        context: context,
                                        builder: (c) => AlertDialog(
                                          title: const Text('Restore Password'),
                                          content: const Text(
                                              'Restore this previous password as the current password?'),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(c, false),
                                              child: const Text('Cancel'),
                                            ),
                                            ElevatedButton(
                                              onPressed: () => Navigator.pop(c, true),
                                              child: const Text('Restore'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirm == true) {
                                        await _storageService.updatePassword(
                                          password.copyWith(encryptedValue: encVal),
                                        );
                                        await _loadPasswords();
                                        if (mounted) {
                                          Navigator.pop(ctx);
                                          _showSuccess('Previous password restored');
                                        }
                                      }
                                    },
                                    child: const Text('Restore', style: TextStyle(fontSize: 12)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Password Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => _searchFocusNode.requestFocus(),
          ),
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
              focusNode: _searchFocusNode,
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

          // Filter Chips (All, Favorites, and Tags)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: _selectedTagFilter == null,
                    onSelected: (_) {
                      setState(() => _selectedTagFilter = null);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    avatar: const Icon(Icons.star, size: 16, color: Colors.amber),
                    label: const Text('Favorites'),
                    selected: _selectedTagFilter == 'favorites',
                    onSelected: (_) {
                      setState(() {
                        _selectedTagFilter =
                            _selectedTagFilter == 'favorites' ? null : 'favorites';
                      });
                    },
                  ),
                ),
                ..._allTags.map((tag) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(tag),
                    selected: _selectedTagFilter == tag,
                    onSelected: (_) {
                      setState(() {
                        _selectedTagFilter =
                            _selectedTagFilter == tag ? null : tag;
                      });
                    },
                  ),
                )),
              ],
            ),
          ),
          const SizedBox(height: 8),

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
                              onTap: () => _showPasswordDetails(password),
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
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
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Created: ${password.createdAt.toString().split(' ')[0]}',
                                  ),
                                  if (password.tags.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Wrap(
                                        spacing: 4,
                                        runSpacing: 2,
                                        children: password.tags.take(3).map((t) => Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(t, style: const TextStyle(fontSize: 10)),
                                        )).toList(),
                                      ),
                                    ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      password.isFavorite ? Icons.star : Icons.star_border,
                                      color: password.isFavorite ? Colors.amber : null,
                                    ),
                                    tooltip: password.isFavorite ? 'Unmark Favorite' : 'Mark Favorite',
                                    onPressed: () => _toggleFavorite(password),
                                  ),
                                  PopupMenuButton<String>(
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
