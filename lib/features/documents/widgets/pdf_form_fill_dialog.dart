import 'package:flutter/material.dart';
import '../../../services/pdf_annotation_and_form_service.dart';

/// Dialog for filling interactive AcroForm fields
class PdfFormFillDialog extends StatefulWidget {
  final List<FormFieldInfo> fields;

  const PdfFormFillDialog({super.key, required this.fields});

  @override
  State<PdfFormFillDialog> createState() => _PdfFormFillDialogState();
}

class _PdfFormFillDialogState extends State<PdfFormFillDialog> {
  final Map<String, dynamic> _values = {};
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      if (field.type == 'text') {
        final initial = field.currentValue?.toString() ?? '';
        _controllers[field.name] = TextEditingController(text: initial);
        _values[field.name] = initial;
      } else if (field.type == 'checkbox') {
        _values[field.name] = field.currentValue == true;
      } else if (field.type == 'combobox' || field.type == 'radio') {
        _values[field.name] = field.currentValue?.toString();
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    for (final entry in _controllers.entries) {
      _values[entry.key] = entry.value.text;
    }
    Navigator.pop(context, _values);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Fill Form Fields',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: widget.fields.map((field) {
                    if (field.type == 'text') {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TextField(
                          controller: _controllers[field.name],
                          decoration: InputDecoration(
                            labelText: field.name,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      );
                    } else if (field.type == 'checkbox') {
                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(field.name),
                        value: _values[field.name] == true,
                        onChanged: (val) {
                          setState(() {
                            _values[field.name] = val ?? false;
                          });
                        },
                      );
                    } else if (field.type == 'combobox' || field.type == 'radio') {
                      final items = field.options.isNotEmpty
                          ? field.options
                          : [field.currentValue?.toString() ?? 'Default'];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: DropdownButtonFormField<String>(
                          value: items.contains(_values[field.name])
                              ? _values[field.name]
                              : (items.isNotEmpty ? items.first : null),
                          decoration: InputDecoration(
                            labelText: field.name,
                            border: const OutlineInputBorder(),
                          ),
                          items: items.map((opt) {
                            return DropdownMenuItem(value: opt, child: Text(opt));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _values[field.name] = val;
                            });
                          },
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  }).toList(),
                ),
              ),
            ),
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
                  onPressed: _submit,
                  child: const Text('Apply & Save Copy'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
