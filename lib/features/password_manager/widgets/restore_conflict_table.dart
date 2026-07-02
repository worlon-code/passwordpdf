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
        return 'Identical (no-op)';
      case ConflictStatus.sameNameDiffSecret:
        return 'Name clash';
      case ConflictStatus.sameSecretDiffName:
        return 'Same value, other name';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Restore'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, widget.conflicts),
            child: const Text('IMPORT', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Backup name')),
              DataColumn(label: Text('Local name')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Action')),
            ],
            rows:
                widget.conflicts.map((c) {
                  return DataRow(
                    cells: [
                      DataCell(Text(c.backupName)),
                      DataCell(Text(c.localName.isEmpty ? '—' : c.localName)),
                      DataCell(Text(_statusLabel(c.status))),
                      DataCell(
                        c.status == ConflictStatus.sameNameSameSecret
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
                                  child: Text('Keep both'),
                                ),
                                DropdownMenuItem(
                                  value: ConflictResolution.rename,
                                  child: Text('Rename'),
                                ),
                              ],
                              onChanged: (v) async {
                                if (v == null) return;
                                if (v == ConflictResolution.rename) {
                                  final name = await _promptRename(
                                    c.backupName,
                                  );
                                  if (name == null) return;
                                  c.renameTo = name;
                                }
                                setState(() => c.resolution = v);
                              },
                            ),
                      ),
                    ],
                  );
                }).toList(),
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
