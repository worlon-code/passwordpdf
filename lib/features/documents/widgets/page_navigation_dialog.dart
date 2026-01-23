import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PageNavigationDialog extends StatefulWidget {
  final int totalPages;
  final int currentPage;

  const PageNavigationDialog({
    super.key,
    required this.totalPages,
    required this.currentPage,
  });

  @override
  State<PageNavigationDialog> createState() => _PageNavigationDialogState();
}

class _PageNavigationDialogState extends State<PageNavigationDialog> {
  late int _selectedPage;
  late TextEditingController _textController;
  bool _isValid = true;

  @override
  void initState() {
    super.initState();
    _selectedPage = widget.currentPage;
    _textController = TextEditingController(text: _selectedPage.toString());
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _updateFromText(String value) {
    final page = int.tryParse(value);
    setState(() {
      if (page != null && page >= 1 && page <= widget.totalPages) {
        _selectedPage = page;
        _isValid = true;
      } else {
        _isValid = false;
      }
    });
  }

  void _updateFromSlider(double value) {
    final page = value.round();
    setState(() {
      _selectedPage = page;
      _textController.text = page.toString();
      _isValid = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Go to Page'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Page '),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _textController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    isDense: true,
                    errorText: _isValid ? null : '',
                    errorStyle: const TextStyle(height: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onChanged: _updateFromText,
                ),
              ),
              Text(' of ${widget.totalPages}'),
            ],
          ),
          const SizedBox(height: 20),
          Slider(
            value: _selectedPage.toDouble(),
            min: 1,
            max: widget.totalPages.toDouble(),
            divisions: widget.totalPages > 1 ? widget.totalPages - 1 : 1,
            label: _selectedPage.toString(),
            onChanged: widget.totalPages > 1 ? _updateFromSlider : null,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isValid
              ? () => Navigator.of(context).pop(_selectedPage)
              : null,
          child: const Text('Go'),
        ),
      ],
    );
  }
}
