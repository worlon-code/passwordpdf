import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../services/ai/ai_model_manager_service.dart';
import '../../../services/ai/device_capability_service.dart';

/// Modal dialog requiring explicit user approval before downloading any offline AI model
class AiModelApprovalDialog extends StatefulWidget {
  final ModelCatalogItem model;

  const AiModelApprovalDialog({super.key, required this.model});

  static Future<bool> show(BuildContext context, ModelCatalogItem model) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AiModelApprovalDialog(model: model),
    );
    return result ?? false;
  }

  @override
  State<AiModelApprovalDialog> createState() => _AiModelApprovalDialogState();
}

class _AiModelApprovalDialogState extends State<AiModelApprovalDialog> {
  final AiModelManagerService _manager = AiModelManagerService();
  final DeviceCapabilityService _capabilityService = DeviceCapabilityService();

  DeviceHardwareProfile? _profile;
  bool _isDownloading = false;
  double _progress = 0.0;
  String _progressText = '';
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final p = await _capabilityService.profileDevice();
    if (mounted) setState(() => _profile = p);
  }

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _progressText = 'Starting download...';
      _cancelToken = CancelToken();
    });

    try {
      await _manager.downloadModel(
        model: widget.model,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() {
              _progress = received / total;
              final recMb = (received / (1024 * 1024)).toStringAsFixed(1);
              final totMb = (total / (1024 * 1024)).toStringAsFixed(1);
              _progressText = '$recMb MB / $totMb MB (${(_progress * 100).toInt()}%)';
            });
          }
        },
      );

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _isDownloading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed or cancelled: $e')),
        );
      }
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('User cancelled');
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.smart_toy_outlined, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Expanded(child: Text('Offline AI Model Setup', style: TextStyle(fontSize: 18))),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Zero-Bundled LLM Privacy Rule: Models are never pre-packaged in the application. To enable offline document question-answering, download this validated open-weights model directly to your device storage.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Model: ${model.displayName}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('Parameters: ${model.parameterSize} (${model.quantization})'),
                  Text('Download Size: ~${model.sizeInMb.toStringAsFixed(1)} MB'),
                  Text('Context Window: ${model.contextWindow} tokens'),
                  if (_profile != null) ...[
                    const Divider(height: 16),
                    Text('Device RAM: ${_profile!.totalRamGb.toStringAsFixed(1)} GB'),
                    Text('Architecture: ${_profile!.cpuArchitecture}'),
                  ],
                ],
              ),
            ),
            if (_isDownloading) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 6),
              Center(child: Text(_progressText, style: const TextStyle(fontSize: 12))),
            ],
          ],
        ),
      ),
      actions: [
        if (_isDownloading)
          TextButton(
            onPressed: _cancelDownload,
            child: const Text('Cancel Download'),
          )
        else ...[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: _startDownload,
            icon: const Icon(Icons.download),
            label: const Text('Download & Enable'),
          ),
        ],
      ],
    );
  }
}
