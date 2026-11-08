import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../../../services/biometric_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';
import '../../documents/widgets/signature_pad_dialog.dart';

/// Screen to view, rename, delete, and add saved encrypted signatures
class SignatureManagerScreen extends StatefulWidget {
  const SignatureManagerScreen({super.key});

  @override
  State<SignatureManagerScreen> createState() => _SignatureManagerScreenState();
}

class _SignatureManagerScreenState extends State<SignatureManagerScreen> {
  final StorageService _storageService = StorageService();
  final EncryptionService _encryptionService = EncryptionService();
  final BiometricService _biometricService = BiometricService();

  List<Map<String, dynamic>> _signatures = [];
  final Map<String, Uint8List> _decryptedThumbnails = {};
  bool _isLoading = true;
  bool _authenticated = false;

  @override
  void initState() {
    super.initState();
    _checkAuthAndLoad();
  }

  Future<void> _checkAuthAndLoad() async {
    final available = await _biometricService.isBiometricAvailable();
    if (available) {
      final ok = await _biometricService.authenticate(
        localizedReason: 'Authenticate to view and manage saved signatures',
      );
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Authentication required to access saved signatures'),
              backgroundColor: Colors.red,
            ),
          );
          Navigator.pop(context);
        }
        return;
      }
    }
    _authenticated = true;
    await _loadSignatures();
  }

  Future<void> _loadSignatures() async {
    setState(() => _isLoading = true);
    try {
      final rows = await _storageService.getAllEncryptedSignatures();
      final thumbs = <String, Uint8List>{};

      for (final row in rows) {
        final id = row['id'] as String;
        final encrypted = row['encrypted_png_bytes'] as String?;
        if (encrypted != null && encrypted.isNotEmpty) {
          try {
            final decBase64 = await _encryptionService.decrypt(encrypted);
            if (decBase64 != null) {
              thumbs[id] = base64Decode(decBase64);
            }
          } catch (_) {}
        }
      }

      if (mounted) {
        setState(() {
          _signatures = rows;
          _decryptedThumbnails.clear();
          _decryptedThumbnails.addAll(thumbs);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading signatures: $e')),
        );
      }
    }
  }

  Future<void> _addNewSignature() async {
    final result = await showDialog<Uint8List>(
      context: context,
      builder: (_) => const SignaturePadDialog(),
    );
    if (result != null) {
      await _loadSignatures();
    }
  }

  Future<void> _renameSignature(Map<String, dynamic> sig) async {
    final id = sig['id'] as String;
    final currentName = sig['name'] as String? ?? 'Signature';
    final controller = TextEditingController(text: currentName);
    String? errorText;

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Rename Signature'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Signature Name',
              errorText: errorText,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (errorText != null) {
                setDialogState(() => errorText = null);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final trimmed = controller.text.trim();
                if (trimmed.isEmpty) {
                  setDialogState(() => errorText = 'Name cannot be empty');
                  return;
                }
                if (trimmed == currentName) {
                  Navigator.pop(ctx, null);
                  return;
                }
                final exists = await _storageService.encryptedSignatureNameExists(
                  trimmed,
                  excludeId: id,
                );
                if (exists) {
                  setDialogState(() => errorText = 'A signature named "$trimmed" already exists');
                  return;
                }
                Navigator.pop(ctx, trimmed);
              },
              child: const Text('Rename'),
            ),
          ],
        ),
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != currentName) {
      await _storageService.renameEncryptedSignature(id, newName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Signature renamed to "$newName"')),
        );
      }
      await _loadSignatures();
    }
  }

  Future<void> _deleteSignature(Map<String, dynamic> sig) async {
    final id = sig['id'] as String;
    final name = sig['name'] as String? ?? 'Signature';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Signature'),
        content: Text('Are you sure you want to permanently delete "$name"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _storageService.deleteEncryptedSignature(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted signature "$name"')),
        );
      }
      await _loadSignatures();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Signature Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Signature',
            onPressed: _addNewSignature,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : !_authenticated
              ? const SizedBox.shrink()
              : _signatures.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.draw_outlined, size: 80, color: Colors.grey.shade400),
                          const SizedBox(height: 16),
                          Text(
                            'No Saved Signatures',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  color: Colors.grey.shade600,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap + to draw and save your signature',
                            style: TextStyle(color: Colors.grey.shade500),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _addNewSignature,
                            icon: const Icon(Icons.add),
                            label: const Text('Create Signature'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _signatures.length,
                      itemBuilder: (context, index) {
                        final sig = _signatures[index];
                        final id = sig['id'] as String;
                        final name = sig['name'] as String? ?? 'Signature';
                        final created = DateTime.fromMillisecondsSinceEpoch(
                          sig['created_at'] as int? ?? 0,
                        );
                        final thumbBytes = _decryptedThumbnails[id];

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                // Thumbnail
                                Container(
                                  width: 100,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.grey.shade300),
                                  ),
                                  child: thumbBytes != null
                                      ? Image.memory(
                                          thumbBytes,
                                          fit: BoxFit.contain,
                                        )
                                      : const Icon(Icons.draw, color: Colors.grey),
                                ),
                                const SizedBox(width: 16),

                                // Info
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Saved: ${created.toLocal().toString().split(' ')[0]}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // Actions
                                PopupMenuButton<String>(
                                  onSelected: (val) {
                                    if (val == 'rename') {
                                      _renameSignature(sig);
                                    } else if (val == 'delete') {
                                      _deleteSignature(sig);
                                    }
                                  },
                                  itemBuilder: (ctx) => [
                                    const PopupMenuItem(
                                      value: 'rename',
                                      child: Row(
                                        children: [
                                          Icon(Icons.edit, size: 20),
                                          SizedBox(width: 8),
                                          Text('Rename'),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Row(
                                        children: [
                                          Icon(Icons.delete, color: Colors.red, size: 20),
                                          SizedBox(width: 8),
                                          Text('Delete', style: TextStyle(color: Colors.red)),
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
    );
  }
}
