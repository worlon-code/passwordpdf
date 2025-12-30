import 'package:flutter/material.dart';

class SplitPdfDialog extends StatefulWidget {
  final int pageCount;

  const SplitPdfDialog({
    super.key,
    required this.pageCount,
  });

  @override
  State<SplitPdfDialog> createState() => _SplitPdfDialogState();
}

class _SplitPdfDialogState extends State<SplitPdfDialog> {
  final _formKey = GlobalKey<FormState>();
  String _mode = 'range'; // 'range' or 'specific'
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  final _specificController = TextEditingController();

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _specificController.dispose();
    super.dispose();
  }

  List<int>? _getPages() {
    if (!_formKey.currentState!.validate()) return null;

    if (_mode == 'range') {
      final start = int.parse(_startController.text) - 1;
      final end = int.parse(_endController.text) - 1;
      // Generate list
      return List.generate(end - start + 1, (i) => start + i);
    } else {
      final text = _specificController.text;
      final parts = text.split(',');
      final indices = <int>[];
      for (final part in parts) {
        final p = int.tryParse(part.trim());
        if (p != null) indices.add(p - 1);
      }
      return indices;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Split PDF'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total Pages: ${widget.pageCount}'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _mode,
              decoration: const InputDecoration(labelText: 'Split Mode'),
              items: const [
                DropdownMenuItem(value: 'range', child: Text('Page Range')),
                DropdownMenuItem(value: 'specific', child: Text('Specific Pages')),
              ],
              onChanged: (v) => setState(() => _mode = v!),
            ),
            const SizedBox(height: 16),
            if (_mode == 'range')
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _startController,
                      decoration: const InputDecoration(labelText: 'From Page'),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 1 || n > widget.pageCount) {
                          return 'Invalid';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      controller: _endController,
                      decoration: const InputDecoration(labelText: 'To Page'),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 1 || n > widget.pageCount) {
                          return 'Invalid';
                        }
                        if (int.parse(_startController.text) > n) {
                          return 'Min < Max';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              )
            else
              TextFormField(
                controller: _specificController,
                decoration: const InputDecoration(
                  labelText: 'Pages (comma separated)',
                  hintText: '1, 3, 5',
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Required';
                  return null;
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final pages = _getPages();
            if (pages != null) {
              Navigator.pop(context, pages);
            }
          },
          child: const Text('Split'),
        ),
      ],
    );
  }
}
