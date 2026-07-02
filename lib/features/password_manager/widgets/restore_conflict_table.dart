import 'package:flutter/material.dart';
import '../../../services/password_backup_service.dart';

class RestoreConflictTable extends StatefulWidget {
  const RestoreConflictTable({super.key, required this.conflicts});
  final List<RestoreConflict> conflicts;

  @override
  State<RestoreConflictTable> createState() => _RestoreConflictTableState();
}

class _RestoreConflictTableState extends State<RestoreConflictTable> {
  String _statusLabel(ConflictStatus s) {
    switch (s) {
      case ConflictStatus.fresh:
        return 'New';
      case ConflictStatus.sameNameSameSecret:
        return 'Already saved (identical)';
      case ConflictStatus.sameNameDiffSecret:
        return 'Same name, different password';
      case ConflictStatus.sameSecretDiffName:
        return 'Same password already saved';
    }
  }

  void _setAll(ConflictResolution r) {
    setState(() {
      for (final c in widget.conflicts) {
        if (c.status == ConflictStatus.sameNameSameSecret) continue;
        c.resolution = r;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final importable =
        widget.conflicts
            .where(
              (c) =>
                  c.status != ConflictStatus.sameNameSameSecret &&
                  c.resolution != ConflictResolution.skip,
            )
            .length;
    return Scaffold(
      appBar: AppBar(title: const Text('Review restore')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.conflicts.length} item(s) to review',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: () => _setAll(ConflictResolution.keepBoth),
                  child: const Text('Import all'),
                ),
                TextButton(
                  onPressed: () => _setAll(ConflictResolution.skip),
                  child: const Text('Skip all'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: widget.conflicts.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = widget.conflicts[i];
                final identical = c.status == ConflictStatus.sameNameSameSecret;
                return ListTile(
                  title: Text(
                    c.backupName.isEmpty ? '(unnamed)' : c.backupName,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_statusLabel(c.status)),
                      if (c.localName.isNotEmpty)
                        Text(
                          'Existing: ${c.localName}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      if (c.resolution == ConflictResolution.rename &&
                          c.renameTo != null)
                        Text(
                          'Import as: ${c.renameTo}',
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                  trailing:
                      identical
                          ? const Text('Skipped')
                          : DropdownButton<ConflictResolution>(
                            value: c.resolution,
                            items: const [
                              DropdownMenuItem(
                                value: ConflictResolution.skip,
                                child: Text('Skip'),
                              ),
                              DropdownMenuItem(
                                value: ConflictResolution.keepBoth,
                                child: Text('Import'),
                              ),
                              DropdownMenuItem(
                                value: ConflictResolution.rename,
                                child: Text('Rename'),
                              ),
                            ],
                            onChanged: (v) async {
                              if (v == null) return;
                              if (v == ConflictResolution.rename) {
                                final name = await _promptRename(c.backupName);
                                if (name == null || name.isEmpty) return;
                                c.renameTo = name;
                              }
                              setState(() => c.resolution = v);
                            },
                          ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.download_done),
            label: Text(importable == 0 ? 'Import' : 'Import ($importable)'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => Navigator.pop(context, widget.conflicts),
          ),
        ),
      ),
    );
  }

  Future<String?> _promptRename(String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Rename on import'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'New key name'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }
}
