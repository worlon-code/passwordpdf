import 'dart:io';
import 'package:flutter/material.dart';
import 'package:docx_creator/docx_creator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/word_edit_service.dart';

class WordEditorScreen extends StatefulWidget {
  final String filePath;
  final String fileName;
  const WordEditorScreen({super.key, required this.filePath, required this.fileName});

  @override
  State<WordEditorScreen> createState() => _WordEditorScreenState();
}

class _WordEditorScreenState extends State<WordEditorScreen> {
  bool _loading = true;
  String? _error;
  final List<TextEditingController> _controllers = [];
  final Map<int, String> _originalTexts = {};
  final Map<int, String> _dirty = {};

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDocument() async {
    try {
      final doc = await DocxReader.load(widget.filePath);
      int pIndex = 0;
      for (final element in doc.elements) {
        if (element is DocxParagraph) {
          final text = element.children
              .whereType<DocxText>()
              .map((t) => t.content)
              .join();
          final controller = TextEditingController(text: text);
          final index = pIndex;
          _originalTexts[index] = text;
          controller.addListener(() {
            final current = controller.text;
            if (current != _originalTexts[index]) {
              _dirty[index] = current;
              _checkEditingNotice();
            } else {
              _dirty.remove(index);
            }
            setState(() {});
          });
          _controllers.add(controller);
          pIndex++;
        }
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '';
        _loading = false;
      });
    }
  }

  Future<void> _checkEditingNotice() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool('word_editing_notice_shown') ?? false;
    if (!shown && mounted) {
      await prefs.setBool('word_editing_notice_shown', true);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.info_outline, size: 36),
          title: const Text('Word Document Editing'),
          content: const Text(
            'In-app editing creates a safe copy and preserves paragraph text. Complex styling, headers, and drawings may not be retained. Your original file remains untouched.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _saveCopy() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Saving copy with edits…')));
    try {
      final result = await WordEditService().saveCopyWithEdits(
        widget.filePath,
        _dirty,
      );
      final savedName = result.savedPath.split(Platform.pathSeparator).last;
      if (result.verified) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved a copy: $savedName'),
            action: SnackBarAction(
              label: 'Replace Original',
              onPressed: () => _confirmReplaceOriginal(result.savedPath),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        setState(() {
          _dirty.clear();
          for (var i = 0; i < _controllers.length; i++) {
            _originalTexts[i] = _controllers[i].text;
          }
        });
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved a copy ($savedName) but verification failed. Original is untouched.'),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _confirmReplaceOriginal(String copyPath) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace Original File?'),
        content: const Text(
          'This will overwrite your original file with the edited copy. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Replace'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await File(copyPath).copy(widget.filePath);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Original file updated successfully')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Replace failed: '), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Save a copy',
            icon: const Icon(Icons.save_outlined),
            onPressed: _dirty.isNotEmpty ? _saveCopy : null,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error loading document: $_error'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _controllers.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: _controllers[index],
                        maxLines: null,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          labelText: 'Paragraph ${index + 1}',
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
