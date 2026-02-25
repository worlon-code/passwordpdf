import 'package:flutter/material.dart';

class ReorderPagesDialog extends StatefulWidget {
  final int pageCount;

  const ReorderPagesDialog({
    super.key,
    required this.pageCount,
  });

  @override
  State<ReorderPagesDialog> createState() => _ReorderPagesDialogState();
}

class _ReorderPagesDialogState extends State<ReorderPagesDialog> {
  late List<int> _pageOrder;

  @override
  void initState() {
    super.initState();
    // Initialize with 0, 1, 2...
    _pageOrder = List.generate(widget.pageCount, (index) => index);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reorder Pages'),
      content: SizedBox(
        width: 300,
        height: 400,
        child: Column(
          children: [
            const Text(
              'Drag and drop pages to reorder',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: _pageOrder.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (oldIndex < newIndex) {
                      newIndex -= 1;
                    }
                    final int item = _pageOrder.removeAt(oldIndex);
                    _pageOrder.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) {
                  // Display 1-based page number
                  final pageNum = _pageOrder[index] + 1;
                  return Card(
                    key: ValueKey(_pageOrder[index]), // Key must be unique based on content (original page index)
                    elevation: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Text('$pageNum'),
                        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      ),
                      title: Text('Page $pageNum'),
                      trailing: const Icon(Icons.drag_handle),
                    ),
                  );
                },
              ),
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
          onPressed: () => Navigator.pop(context, _pageOrder),
          child: const Text('Save Order'),
        ),
      ],
    );
  }
}
