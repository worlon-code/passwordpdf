import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../services/ai/ai_prompt_service.dart';

/// Screen allowing users to inspect, edit, save new versions, and roll back
/// the Master System Prompt used for on-device LLM inference and grounded RAG responses.
class AiPromptManagementScreen extends StatefulWidget {
  const AiPromptManagementScreen({super.key});

  static Future<void> show(BuildContext context) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AiPromptManagementScreen()),
    );
  }

  @override
  State<AiPromptManagementScreen> createState() => _AiPromptManagementScreenState();
}

class _AiPromptManagementScreenState extends State<AiPromptManagementScreen>
    with SingleTickerProviderStateMixin {
  final AiPromptService _promptService = AiPromptService();

  late TabController _tabController;
  final TextEditingController _promptTextController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  List<AiPromptVersion> _versions = [];
  AiPromptVersion? _activeVersion;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadVersions();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _promptTextController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadVersions() async {
    setState(() => _isLoading = true);
    try {
      final all = await _promptService.getAllPromptVersions();
      final active = await _promptService.getActivePromptVersion();

      if (mounted) {
        setState(() {
          _versions = all;
          _activeVersion = active ?? (all.isNotEmpty ? all.first : null);
          _isLoading = false;
        });

        if (_activeVersion != null && _promptTextController.text.isEmpty) {
          _promptTextController.text = _activeVersion!.promptText;
          _titleController.text = 'Master Prompt v${_versions.length + 1}';
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading prompt versions: $e')),
        );
      }
    }
  }

  Future<void> _saveNewVersion() async {
    final text = _promptTextController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prompt text cannot be empty')),
      );
      return;
    }

    final title = _titleController.text.trim().isEmpty
        ? 'Custom Master Prompt v${_versions.length + 1}'
        : _titleController.text.trim();
    final description = _descriptionController.text.trim().isEmpty
        ? null
        : _descriptionController.text.trim();

    setState(() => _isSaving = true);
    try {
      final created = await _promptService.createNewVersion(
        title: title,
        promptText: text,
        description: description,
      );

      await _loadVersions();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved & Activated Master Prompt v${created.version}'),
            backgroundColor: Colors.green[700],
          ),
        );
        _descriptionController.clear();
        _titleController.text = 'Master Prompt v${_versions.length + 1}';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save new version: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _rollbackToVersion(AiPromptVersion version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rollback to Version ${version.version}?'),
        content: Text(
          'This will immediately activate "${version.title}" as the master prompt for all future AI document queries.\n\nAll existing versions will remain saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Rollback'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _promptService.rollbackToVersion(version.version);
      await _loadVersions();

      _promptTextController.text = version.promptText;
      _titleController.text = 'Master Prompt v${_versions.length + 1}';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Active prompt rolled back to v${version.version}'),
            backgroundColor: Colors.green[700],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to roll back: $e')),
        );
      }
    }
  }

  Future<void> _resetToFactoryDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to Factory Default?'),
        content: const Text(
          'This will create a new active version based on the original factory master prompt (with strict anti-hallucination rules and candidate extraction principles).\n\nYour existing versions will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset to Default'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final restored = await _promptService.resetToFactoryDefault();
      await _loadVersions();
      _promptTextController.text = restored.promptText;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restored Factory Default as v${restored.version}'),
            backgroundColor: Colors.green[700],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error resetting to default: $e')),
        );
      }
    }
  }

  Future<void> _deleteVersion(AiPromptVersion version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Version v${version.version}?'),
        content: Text('Are you sure you want to permanently delete "${version.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _promptService.deleteVersion(version.version);
      await _loadVersions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted version v${version.version}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _showPromptDetailsDialog(AiPromptVersion version) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Expanded(
              child: Text(
                'v${version.version}: ${version.title}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            if (version.isActive)
              const Chip(
                label: Text('ACTIVE', style: TextStyle(fontSize: 10, color: Colors.white)),
                backgroundColor: Colors.green,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (version.description != null && version.description!.isNotEmpty) ...[
                  Text(
                    'Notes: ${version.description!}',
                    style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey[700], fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  'Created: ${DateFormat.yMMMd().add_jm().format(version.createdAt)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
                  ),
                  child: SelectableText(
                    version.promptText,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy Prompt'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: version.promptText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Prompt copied to clipboard')),
              );
            },
          ),
          if (!version.isActive)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _rollbackToVersion(version);
              },
              child: const Text('Rollback to this Version'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Master System Prompt'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Reset to Factory Default',
            onPressed: _resetToFactoryDefault,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _loadVersions,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: const Icon(Icons.edit_note),
              text: _activeVersion != null ? 'Editor (v${_activeVersion!.version} Active)' : 'Editor',
            ),
            Tab(
              icon: const Icon(Icons.history),
              text: 'History (${_versions.length})',
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildEditorTab(colorScheme),
                _buildHistoryTab(colorScheme),
              ],
            ),
    );
  }

  Widget _buildEditorTab(ColorScheme colorScheme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Active Version Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.verified, color: colorScheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Active in Model: v${_activeVersion?.version ?? 1} - ${_activeVersion?.title ?? 'Default'}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Injected into every local LLM grounded prompt across attached documents.',
                        style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Action helper chips
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionChip(
                avatar: const Icon(Icons.copy, size: 14),
                label: const Text('Copy Prompt', style: TextStyle(fontSize: 11)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _promptTextController.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Prompt text copied to clipboard')),
                  );
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.restart_alt, size: 14),
                label: const Text('Reload Active', style: TextStyle(fontSize: 11)),
                onPressed: () {
                  if (_activeVersion != null) {
                    setState(() {
                      _promptTextController.text = _activeVersion!.promptText;
                    });
                  }
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.history, size: 14),
                label: const Text('View All Versions', style: TextStyle(fontSize: 11)),
                onPressed: () => _tabController.animateTo(1),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Version Metadata Inputs
          Text(
            'Save as New Version',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            decoration: InputDecoration(
              labelText: 'Version Title',
              hintText: 'e.g., Strict Resume QA & Formatting v2',
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descriptionController,
            decoration: InputDecoration(
              labelText: 'Notes / Change Description (Optional)',
              hintText: 'e.g., Emphasized bolding candidate name and CGPA extraction',
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 16),

          // Master Prompt Text Area
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'System Prompt Content',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary,
                ),
              ),
              Text(
                '${_promptTextController.text.length} chars',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _promptTextController,
            maxLines: 18,
            minLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              hintText: 'Enter Master System Prompt instructions for the AI...',
            ),
          ),
          const SizedBox(height: 16),

          // Save Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save_as),
              label: Text(
                _isSaving ? 'Saving New Version...' : 'Save & Activate as New Version',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              onPressed: _isSaving ? null : _saveNewVersion,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildHistoryTab(ColorScheme colorScheme) {
    if (_versions.isEmpty) {
      return const Center(child: Text('No prompt versions found.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _versions.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final version = _versions[index];
        final isActive = version.isActive;

        return Card(
          elevation: isActive ? 2 : 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isActive ? colorScheme.primary : colorScheme.outlineVariant,
              width: isActive ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isActive ? colorScheme.primary : colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'v${version.version}',
                        style: TextStyle(
                          color: isActive ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            version.title,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            DateFormat.yMMMd().add_jm().format(version.createdAt),
                            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    if (isActive)
                      Chip(
                        label: const Text('ACTIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                        backgroundColor: Colors.green[700],
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                  ],
                ),
                if (version.description != null && version.description!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    version.description!,
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic),
                  ),
                ],
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    version.promptText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.black87),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.visibility_outlined, size: 16),
                      label: const Text('Preview', style: TextStyle(fontSize: 12)),
                      onPressed: () => _showPromptDetailsDialog(version),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Load into Editor', style: TextStyle(fontSize: 12)),
                      onPressed: () {
                        setState(() {
                          _promptTextController.text = version.promptText;
                          _titleController.text = '${version.title} (Draft)';
                        });
                        _tabController.animateTo(0);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Loaded v${version.version} into editor')),
                        );
                      },
                    ),
                    if (!isActive) ...[
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.replay, size: 16),
                        label: const Text('Rollback', style: TextStyle(fontSize: 12)),
                        onPressed: () => _rollbackToVersion(version),
                      ),
                      if (_versions.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                          tooltip: 'Delete Version',
                          onPressed: () => _deleteVersion(version),
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
