import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../../../services/biometric_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/storage_service.dart';

/// Interactive dialog for drawing and exporting smooth signatures
class SignaturePadDialog extends StatefulWidget {
  const SignaturePadDialog({super.key});

  @override
  State<SignaturePadDialog> createState() => _SignaturePadDialogState();
}

class _SignaturePadDialogState extends State<SignaturePadDialog> {
  final List<List<Offset>> _strokes = [];
  final StorageService _storageService = StorageService();
  final EncryptionService _encryptionService = EncryptionService();
  final BiometricService _biometricService = BiometricService();

  List<Map<String, dynamic>> _savedSignatures = [];
  bool _isLoadingSignatures = true;
  bool _saveAsDefault = false;
  final TextEditingController _nameController = TextEditingController(text: 'My Signature');
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadSavedSignatures();
  }

  Future<void> _loadSavedSignatures() async {
    try {
      final rows = await _storageService.getAllEncryptedSignatures();
      if (mounted) {
        setState(() {
          _savedSignatures = rows;
          _isLoadingSignatures = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingSignatures = false);
    }
  }

  Future<void> _useSavedSignature(Map<String, dynamic> row) async {
    // Biometric gate check
    final isSupported = await _biometricService.isBiometricAvailable();
    if (isSupported) {
      final authenticated = await _biometricService.authenticate(
        localizedReason: 'Authenticate to access saved signature',
      );
      if (!authenticated) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Authentication required to use saved signature')),
          );
        }
        return;
      }
    }

    try {
      final encryptedPng = row['encrypted_png_bytes'] as String;
      final decryptedBase64 = await _encryptionService.decrypt(encryptedPng);
      if (decryptedBase64 != null) {
        final bytes = base64Decode(decryptedBase64);
        await _storageService.touchEncryptedSignature(row['id'] as String);
        if (mounted) Navigator.pop(context, bytes);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load saved signature: $e')),
        );
      }
    }
  }

  void _clear() {
    setState(() {
      _strokes.clear();
    });
  }

  Future<Uint8List?> _renderSignaturePng() async {
    if (_strokes.isEmpty) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(400, 200);

    final paint = Paint()
      ..color = Colors.black
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke;

    for (final stroke in _strokes) {
      if (stroke.length < 2) continue;
      final path = Path();
      path.moveTo(stroke.first.dx, stroke.first.dy);
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> _submit() async {
    final pngBytes = await _renderSignaturePng();
    if (pngBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please draw your signature first')),
      );
      return;
    }

    if (_saveAsDefault) {
      final name = _nameController.text.trim();
      if (name.isEmpty) {
        setState(() => _nameError = 'Signature name is required');
        return;
      }

      final exists = await _storageService.encryptedSignatureNameExists(name);
      if (exists) {
        setState(() => _nameError = 'A signature named "$name" already exists');
        return;
      }

      try {
        final b64 = base64Encode(pngBytes);
        final encrypted = await _encryptionService.encrypt(b64);
        if (encrypted != null) {
          await _storageService.insertEncryptedSignature({
            'id': DateTime.now().millisecondsSinceEpoch.toString(),
            'name': name,
            'encrypted_png_bytes': encrypted,
            'created_at': DateTime.now().millisecondsSinceEpoch,
            'last_used_at': DateTime.now().millisecondsSinceEpoch,
          });
        }
      } catch (_) {}
    }

    if (mounted) Navigator.pop(context, pngBytes);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Draw Signature',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear canvas',
                    onPressed: _clear,
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Saved Signatures Bar (if any)
              if (_savedSignatures.isNotEmpty) ...[
                const Text(
                  'Saved Signatures:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: _savedSignatures.map((row) {
                    return ActionChip(
                      avatar: const Icon(Icons.fingerprint, size: 16),
                      label: Text(row['name'] as String? ?? 'Signature'),
                      onPressed: () => _useSavedSignature(row),
                    );
                  }).toList(),
                ),
                const Divider(height: 20),
              ],

              // Drawing Canvas Container
              Container(
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border.all(color: Colors.grey.shade300, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: GestureDetector(
                    onPanStart: (details) {
                      setState(() {
                        _strokes.add([details.localPosition]);
                      });
                    },
                    onPanUpdate: (details) {
                      setState(() {
                        if (_strokes.isNotEmpty) {
                          _strokes.last.add(details.localPosition);
                        }
                      });
                    },
                    child: CustomPaint(
                      painter: _SignaturePainter(strokes: _strokes),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Save encrypted signature for future use'),
                value: _saveAsDefault,
                onChanged: (val) {
                  setState(() => _saveAsDefault = val ?? false);
                },
              ),
              if (_saveAsDefault) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: 'Signature Name',
                    hintText: 'e.g., Official Signature, Personal',
                    errorText: _nameError,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onChanged: (_) {
                    if (_nameError != null) {
                      setState(() => _nameError = null);
                    }
                  },
                ),
              ],

              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _strokes.isEmpty ? null : _submit,
                    child: const Text('Apply Signature'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;

  _SignaturePainter({required this.strokes});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black87
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path();
      path.moveTo(stroke.first.dx, stroke.first.dy);
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}
