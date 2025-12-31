import 'package:flutter/material.dart';
import '../../../models/conflict_resolution_model.dart';

class ConflictResolutionDialog extends StatefulWidget {
  final List<ConflictItem> conflicts;

  const ConflictResolutionDialog({
    super.key,
    required this.conflicts,
  });

  @override
  State<ConflictResolutionDialog> createState() => _ConflictResolutionDialogState();
}

class _ConflictResolutionDialogState extends State<ConflictResolutionDialog> {
  late List<ConflictItem> _remainingItems;
  final Map<String, ConflictAction> _resolutions = {};
  final Set<String> _selectedIds = {};
  ConflictActionType _selectedAction = ConflictActionType.skip;

  @override
  void initState() {
    super.initState();
    _remainingItems = List.from(widget.conflicts);
    // Select all by default for easier bulk actions
    _selectedIds.addAll(_remainingItems.map((e) => e.sourceId));
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selectedIds.length == _remainingItems.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.clear();
        _selectedIds.addAll(_remainingItems.map((e) => e.sourceId));
      }
    });
  }

  Future<void> _applySelectedAction() async {
    if (_selectedIds.isEmpty) return;

    String? suffix;
    if (_selectedAction == ConflictActionType.rename) {
      // Ask for suffix
      final controller = TextEditingController(text: '_copy');
      final result = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Bulk Rename'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter text to append to filename:'),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Suffix',
                  hintText: 'e.g., _copy',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 4),
              Text(
                'Example: file.pdf -> file${controller.text}.pdf',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Apply'),
            ),
          ],
        ),
      );

      if (result == null) return;
      suffix = result;
    }

    setState(() {
      final action = ConflictAction(type: _selectedAction, renameSuffix: suffix);
      
      // Apply to selected
      for (final id in _selectedIds) {
        _resolutions[id] = action;
        _remainingItems.removeWhere((item) => item.sourceId == id);
      }
      
      _selectedIds.clear();
      
      // Auto-select remaining if any
      if (_remainingItems.isNotEmpty) {
        _selectedIds.addAll(_remainingItems.map((e) => e.sourceId));
      }
    });

    // If done, close
    if (_remainingItems.isEmpty) {
      if (mounted) {
        Navigator.pop(context, _resolutions);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return PopScope(
      canPop: false, // Prevent accidental back
      onPopInvoked: (didPop) async {
        if (didPop) return;
        // Allow manual cancel if user wants to abort
        final shouldClose = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Cancel resolution?'),
            content: const Text('Unresolved items will be skipped.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Stay'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Cancel Operations'),
              ),
            ],
          ),
        );
        
        if (shouldClose == true && mounted) {
           Navigator.pop(context, null);
        }
      },
      child: Dialog(
        child: Container(
          constraints: const BoxConstraints(maxHeight: 600, maxWidth: 500),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)), // Dialog default radius is 28
                ),
                child: Row(
                  children: [
                     Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onPrimaryContainer),
                     const SizedBox(width: 12),
                     Expanded(
                       child: Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Text(
                             'File Conflict Resolution',
                             style: theme.textTheme.titleMedium?.copyWith(
                               color: theme.colorScheme.onPrimaryContainer,
                               fontWeight: FontWeight.bold,
                             ),
                           ),
                           Text(
                             '${_remainingItems.length} items left',
                             style: theme.textTheme.bodySmall?.copyWith(
                               color: theme.colorScheme.onPrimaryContainer,
                             ),
                           ),
                         ],
                       ),
                     ),
                     IconButton(
                       icon: Icon(Icons.close, color: theme.colorScheme.onPrimaryContainer),
                       onPressed: () async {
                          final shouldClose = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Cancel resolution?'),
                              content: const Text('Unresolved items will be skipped.'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context, false),
                                  child: const Text('Stay'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Cancel Operations'),
                                ),
                              ],
                            ),
                          );
                          
                          if (shouldClose == true && mounted) {
                             Navigator.pop(context, null);
                          }
                       },
                     ),
                  ],
                ),
              ),
              
              const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('The following files already exist in the destination. Select items and choose an action.'),
              ),
              
              const Divider(height: 1),
              
              // Select All (Keep at top for lists)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: Row(
                  children: [
                    Checkbox(
                      value: _remainingItems.isNotEmpty && _selectedIds.length == _remainingItems.length,
                      onChanged: (_) => _toggleAll(),
                    ),
                    Text('${_selectedIds.length} Selected'),
                  ],
                ),
              ),

              const Divider(height: 1),

              // List
              Expanded(
                child: ListView.builder(
                  itemCount: _remainingItems.length,
                  itemBuilder: (context, index) {
                    final item = _remainingItems[index];
                    final isSelected = _selectedIds.contains(item.sourceId);
                    return ListTile(
                      leading: Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleSelection(item.sourceId),
                      ),
                      title: Text(item.name),
                      subtitle: Text(item.isFolder ? 'Folder' : 'File'),
                      onTap: () => _toggleSelection(item.sourceId),
                    );
                  },
                ),
              ),
              
              const Divider(height: 1),
              
              // Actions Bar (Bottom)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Action Dropdown
                    Expanded(
                      child: DropdownButtonFormField<ConflictActionType>(
                        value: _selectedAction,
                        decoration: const InputDecoration(
                          labelText: 'Action',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: ConflictActionType.skip,
                            child: Text('Skip'),
                          ),
                          DropdownMenuItem(
                            value: ConflictActionType.rename,
                            child: Text('Rename'),
                          ),
                          DropdownMenuItem(
                            value: ConflictActionType.overwrite,
                            child: Text('Overwrite'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _selectedAction = value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    FilledButton(
                      onPressed: _selectedIds.isEmpty ? null : _applySelectedAction,
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
