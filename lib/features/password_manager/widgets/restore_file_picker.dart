import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../settings/services/settings_service.dart';

/// In-app browser that lists .json password backups (no system file picker).
/// Returns the selected file's path via Navigator.pop.
class RestoreFilePicker extends StatelessWidget {
  const RestoreFilePicker({super.key});

  List<File> _findBackups() {
    final files = <File>[];
    final seen = <String>{};
    final dirs = [
      Directory(p.join(SettingsService().exportPath, 'Backup')),
      Directory('/storage/emulated/0/Download'),
    ];
    for (final d in dirs) {
      try {
        if (d.existsSync()) {
          for (final e in d.listSync()) {
            if (e is File &&
                e.path.toLowerCase().endsWith('.json') &&
                seen.add(e.path)) {
              files.add(e);
            }
          }
        }
      } catch (_) {
        // ignore unreadable dirs
      }
    }
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    return files;
  }

  @override
  Widget build(BuildContext context) {
    final files = _findBackups();
    return Scaffold(
      appBar: AppBar(title: const Text('Choose backup (.json)')),
      body:
          files.isEmpty
              ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No .json backups found in Download/PDF Manager/Backup or Download.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
              : ListView.separated(
                itemCount: files.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final f = files[i];
                  final stat = f.statSync();
                  return ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(p.basename(f.path)),
                    subtitle: Text(
                      '${stat.modified.toString().split('.').first}  -  ${stat.size} B',
                    ),
                    onTap: () => Navigator.pop(context, f.path),
                  );
                },
              ),
    );
  }
}
