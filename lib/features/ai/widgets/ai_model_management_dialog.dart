import 'dart:io';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../services/ai/ai_model_manager_service.dart';
import '../../../services/ai/device_capability_service.dart';
import '../../../services/logging_service.dart';
import '../../../services/storage_service.dart';

/// Comprehensive dialog for managing offline AI models, viewing device capability,
/// downloading open-weights GGUF models, deleting, and selecting active models.
/// Enforces a clear 2-step guided workflow:
/// Step 1: Download & Activate Embedding Model (Required for PDF Search & Vector Indexing)
/// Step 2: Download & Activate Chat / Reasoning LLMs (Gemma, Qwen, etc.)
class AiModelManagementDialog extends StatefulWidget {
  const AiModelManagementDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const AiModelManagementDialog(),
    );
  }

  @override
  State<AiModelManagementDialog> createState() => _AiModelManagementDialogState();
}

class _AiModelManagementDialogState extends State<AiModelManagementDialog> {
  final AiModelManagerService _modelManager = AiModelManagerService();
  final DeviceCapabilityService _capabilityService = DeviceCapabilityService();
  final StorageService _storage = StorageService();

  DeviceHardwareProfile? _profile;
  List<Map<String, dynamic>> _installedModels = [];
  String? _activeLlmId;
  String? _activeEmbeddingId;
  bool _isLoading = true;

  String? get _downloadingModelId => _modelManager.downloadingModelId;
  double get _downloadProgress => _modelManager.downloadProgress;
  String get _downloadProgressText => _modelManager.downloadProgressText;

  bool get _hasInstalledEmbedding => _installedModels.any((m) {
        if (m['model_type'] == 'embedding') return true;
        final id = m['model_id'] as String? ?? '';
        return AiModelManagerService.embeddingModels.any((e) => e.id == id);
      });

  bool get _hasActiveEmbedding =>
      _activeEmbeddingId != null && _isInstalled(_activeEmbeddingId!);

  @override
  void initState() {
    super.initState();
    _modelManager.addListener(_onServiceUpdate);
    _loadData();
  }

  @override
  void dispose() {
    _modelManager.removeListener(_onServiceUpdate);
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final profile = await _capabilityService.profileDevice();
    final installed = await _storage.getInstalledModels();
    final activeLlm = await _storage.getActiveInstalledModel('llm');
    final activeEmbedding = await _storage.getActiveInstalledModel('embedding');

    // Auto-activate first installed embedding if none is active
    String? embeddingId = activeEmbedding?['model_id'] as String?;
    if (embeddingId == null) {
      final installedEmbeddings = installed.where((m) {
        final mid = m['model_id'] as String? ?? '';
        final catalogItem =
            AiModelManagerService.catalog.where((c) => c.id == mid).firstOrNull;
        return catalogItem?.isEmbedding ?? (m['model_type'] == 'embedding');
      }).toList();
      if (installedEmbeddings.isNotEmpty) {
        embeddingId = installedEmbeddings.first['model_id'] as String;
        await _modelManager.setActiveModel(embeddingId, modelType: 'embedding');
      }
    }

    if (mounted) {
      setState(() {
        _profile = profile;
        _installedModels = installed;
        _activeLlmId = activeLlm?['model_id'] as String?;
        _activeEmbeddingId = embeddingId;
        _isLoading = false;
      });
    }
  }

  bool _isInstalled(String modelId) {
    return _installedModels.any((m) {
      if (m['model_id'] != modelId) return false;
      final filePath = m['file_path'] as String?;
      if (filePath == null || filePath.isEmpty) return false;
      return File(filePath).existsSync();
    });
  }

  String _getModelDisplayName(String? modelId) {
    if (modelId == null) return 'None';
    final found =
        AiModelManagerService.catalog.where((m) => m.id == modelId).firstOrNull;
    if (found != null) return found.displayName;
    final installed =
        _installedModels.where((m) => m['model_id'] == modelId).firstOrNull;
    return installed?['display_name'] as String? ?? modelId;
  }

  Future<void> _startDownload(ModelCatalogItem item) async {
    // If downloading an LLM and no embedding model is installed, guide the user
    if (item.isLlm && !_hasInstalledEmbedding) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.amber),
              SizedBox(width: 8),
              Expanded(child: Text('Step 1 Recommended First')),
            ],
          ),
          content: Text(
            'To search, read, and ask questions across your PDF documents, an Embedding Model (Step 1) is required.\n\n'
            'We recommend downloading the lightweight BGE Small (35 MB) embedding model first, then downloading your chat model.\n\n'
            'Would you like to download BGE Small first?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'llm_only'),
              child: const Text('Download Chat Model Only'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'embedding_first'),
              child: const Text('Download Embedding First (35 MB)'),
            ),
          ],
        ),
      );

      if (choice == 'cancel' || choice == null) return;
      if (choice == 'embedding_first') {
        final bgeItem = AiModelManagerService.catalog
            .firstWhere((m) => m.id == 'bge-small-en-v1.5');
        await _performDownload(bgeItem);
        return;
      }
    }

    await _performDownload(item);
  }

  Future<void> _performDownload(ModelCatalogItem item) async {
    try {
      await _modelManager.downloadModel(model: item);
      await _modelManager.setActiveModel(item.id, modelType: item.modelType);
      if (mounted) {
        await _loadData();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('${item.displayName} downloaded & activated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e, stack) {
      LoggingService().error(
          'AiModelDialog', 'Download failed for ${item.displayName}: $e', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed or cancelled: $e')),
        );
      }
    }
  }

  void _cancelDownload() {
    _modelManager.cancelDownload();
  }

  Future<void> _activateModel(String modelId, {required String modelType}) async {
    await _modelManager.setActiveModel(modelId, modelType: modelType);
    if (mounted) {
      await _loadData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_getModelDisplayName(modelId)} set as active!'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _deleteModel(String modelId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Model'),
        content: const Text(
          'Are you sure you want to delete this AI model from your device storage? You can re-download it later.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _modelManager.deleteModel(modelId);
        await _loadData();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Model deleted from storage.')),
          );
        }
      } catch (e, stack) {
        LoggingService().error(
            'AiModelDialog', 'Failed to delete model $modelId: $e', e, stack);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Delete failed: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 760),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.smart_toy_outlined,
                        color: colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI Model Manager',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '100% Offline & Private on-device inference',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context, true),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      children: [
                        // Device Capability Card
                        if (_profile != null) ...[
                          _buildDeviceCapabilityCard(_profile!, colorScheme),
                          const SizedBox(height: 16),
                        ],

                        // ================= STEP 1: EMBEDDING MODELS =================
                        _buildSectionHeader(
                          stepNumber: '1',
                          title: 'Embedding Model (Required First)',
                          subtitle:
                              'Converts PDF text into mathematical vectors for instant semantic search. Works with any AI model (Gemma, Qwen, etc.). Download an embedding model first.',
                          colorScheme: colorScheme,
                          badgeColor: Colors.indigo,
                        ),
                        const SizedBox(height: 8),

                        // Step 1 Status Banner
                        _buildEmbeddingStatusBanner(colorScheme),
                        const SizedBox(height: 12),

                        // Embedding Model Cards
                        ...AiModelManagerService.embeddingModels
                            .map((item) => _buildModelCard(item, colorScheme)),

                        const SizedBox(height: 16),
                        const Divider(height: 32),

                        // ================= STEP 2: CHAT & REASONING MODELS =================
                        _buildSectionHeader(
                          stepNumber: '2',
                          title: 'Chat & Reasoning Models (LLMs)',
                          subtitle:
                              'Offline generative language models that read retrieved PDF passages and synthesize answers.',
                          colorScheme: colorScheme,
                          badgeColor: Colors.deepPurple,
                        ),
                        const SizedBox(height: 8),

                        // Step 2 Status Banner
                        _buildLlmStatusBanner(colorScheme),
                        const SizedBox(height: 12),

                        // Chat Model Cards
                        ...AiModelManagerService.llmModels
                            .map((item) => _buildModelCard(item, colorScheme)),
                      ],
                    ),
            ),

            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader({
    required String stepNumber,
    required String title,
    required String subtitle,
    required ColorScheme colorScheme,
    required MaterialColor badgeColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: badgeColor.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: badgeColor.shade300),
              ),
              child: Text(
                'STEP $stepNumber',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: badgeColor.shade800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Colors.grey[700]),
        ),
      ],
    );
  }

  Widget _buildEmbeddingStatusBanner(ColorScheme colorScheme) {
    if (_hasActiveEmbedding) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.green.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Active: ${_getModelDisplayName(_activeEmbeddingId)}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade900),
              ),
            ),
          ],
        ),
      );
    } else if (_hasInstalledEmbedding) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.amber.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: Colors.amber.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Embedding model downloaded. Tap "Set as Active" below.',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade900),
              ),
            ),
          ],
        ),
      );
    } else {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 18, color: Colors.orange.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Please download an embedding model first to enable PDF document search.',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade900),
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildLlmStatusBanner(ColorScheme colorScheme) {
    if (_activeLlmId != null && _isInstalled(_activeLlmId!)) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.green.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Active: ${_getModelDisplayName(_activeLlmId)}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade900),
              ),
            ),
          ],
        ),
      );
    } else {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.tips_and_updates_outlined,
                size: 18, color: Colors.blue.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Select a chat model matching your device RAM. Qwen 1.5B or Gemma 2B recommended.',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue.shade900),
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildDeviceCapabilityCard(
      DeviceHardwareProfile profile, ColorScheme colorScheme) {
    final ramText = '${profile.totalRamGb.toStringAsFixed(1)} GB';
    final archText = profile.cpuArchitecture;
    final tierName = profile.recommendedTier.name.toUpperCase();

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                const Text(
                  'Device Specifications',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Tier: $tierName',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildSpecItem('RAM Available', ramText, Icons.speed),
                ),
                Expanded(
                  child: _buildSpecItem(
                      'Architecture', archText, Icons.developer_board),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.recommend, size: 16, color: Colors.amber[800]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Recommended: ${profile.recommendedModelName}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.amber[900],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpecItem(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey[600]),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(value,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  Widget _buildModelCard(ModelCatalogItem item, ColorScheme colorScheme) {
    final isInstalled = _isInstalled(item.id);
    final isActive = item.isEmbedding
        ? (_activeEmbeddingId == item.id)
        : (_activeLlmId == item.id);
    final isDownloading = _downloadingModelId == item.id;
    final isRecommended = _profile?.recommendedTier == item.minimumTier;

    return Card(
      elevation: isActive ? 2 : 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isActive
              ? colorScheme.primary
              : isRecommended
                  ? Colors.amber.shade400
                  : colorScheme.outlineVariant,
          width: isActive ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title, Type Tag & Badges
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              item.displayName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: item.isEmbedding
                                  ? Colors.indigo.withValues(alpha: 0.12)
                                  : Colors.teal.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.isEmbedding
                                  ? 'VECTOR EMBEDDER'
                                  : item.parameterSize,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                color: item.isEmbedding
                                  ? Colors.indigo.shade800
                                  : Colors.teal.shade800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Size: ~${item.sizeInMb.toStringAsFixed(0)} MB  •  Quant: ${item.quantization}  •  Context: ${item.contextWindow}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                if (isActive)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade400),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle,
                            size: 14, color: Colors.green.shade800),
                        const SizedBox(width: 4),
                        Text(
                          'ACTIVE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.green.shade900,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (isRecommended)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber.shade400),
                    ),
                    child: Text(
                      'RECOMMENDED',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
              ],
            ),

            if (isDownloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _downloadProgress),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_downloadProgressText,
                      style: const TextStyle(fontSize: 12)),
                  TextButton(
                    onPressed: _cancelDownload,
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.red)),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isInstalled) ...[
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: 'Delete Model',
                      onPressed: () => _deleteModel(item.id),
                    ),
                    const SizedBox(width: 8),
                    if (!isActive)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('Set as Active'),
                        onPressed: () => _activateModel(item.id,
                            modelType: item.modelType),
                      ),
                  ] else ...[
                    ElevatedButton.icon(
                      icon: const Icon(Icons.download, size: 16),
                      label: Text(
                          'Download (~${item.sizeInMb.toStringAsFixed(0)} MB)'),
                      onPressed: _downloadingModelId != null
                          ? null
                          : () => _startDownload(item),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
