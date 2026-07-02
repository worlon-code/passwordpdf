import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../settings/services/settings_service.dart';

class RestoreFilePicker extends StatefulWidget {
  const RestoreFilePicker({super.key});
  @override
  State<RestoreFilePicker> createState() => _RestoreFilePickerState();
}

class _RestoreFilePickerState extends State<RestoreFilePicker> {
  static const String _root = '/storage/emulated/0';
  late Directory _dir;

  @override
  void initState() {
    super.initState();
    final backup = Directory(p.join(SettingsService().exportPath, 'Backup'));
    _dir = backup.existsSync() ? backup : Directory(_root);
  }

  List<FileSystemEntity> _entries() {
    try {
      final list = _dir.listSync();
      final dirs =
          list.whereType<Directory>().toList()..sort(
            (a, b) => p
                .basename(a.path)
                .toLowerCase()
                .compareTo(p.basename(b.path).toLowerCase()),
          );
      final jsons =
          list
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.json'))
              .toList()
            ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
            );
      return [...dirs, ...jsons];
    } catch (_) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final canUp = _dir.path != _root && _dir.path.startsWith(_root);
    return Scaffold(
      appBar: AppBar(title: const Text('Choose backup (.json)')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.black12,
            child: Text(
              _dir.path.replaceFirst(_root, 'Internal storage'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (canUp)
                  ListTile(
                    leading: const Icon(Icons.arrow_upward),
                    title: const Text('..'),
                    onTap: () => setState(() => _dir = _dir.parent),
                  ),
                for (final e in entries)
                  if (e is Directory)
                    ListTile(
                      leading: const Icon(Icons.folder),
                      title: Text(p.basename(e.path)),
                      onTap: () => setState(() => _dir = e as Directory),
                    )
                  else
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(p.basename(e.path)),
                      subtitle: Text('\${(e as File).statSync().size} B'),
                      onTap: () => Navigator.pop(context, e.path),
                    ),
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No folders or .json files here.',
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
