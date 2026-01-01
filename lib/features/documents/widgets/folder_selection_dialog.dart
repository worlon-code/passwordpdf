import 'package:flutter/material.dart';
import '../../../services/document_service.dart';
import '../../../models/document_item_model.dart'; // Ensure this is imported

class FolderSelectionDialog extends StatefulWidget {
  final DocumentService docService;
  final String title;
  final String subtitle;
  final Set<String> excludedFolderIds; // Folders to hide (e.g. self when moving)

  const FolderSelectionDialog({
    super.key,
    required this.docService,
    this.title = 'Select Folder',
    this.subtitle = 'Select destination',
    this.excludedFolderIds = const {},
  });

  @override
  State<FolderSelectionDialog> createState() => _FolderSelectionDialogState();
}

class _FolderSelectionDialogState extends State<FolderSelectionDialog> {
  final Set<String> _expandedFolders = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.create_new_folder_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title),
                Text(
                  widget.subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      content: Container(
        width: double.maxFinite,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Root Option
             ListTile(
              leading: const Icon(Icons.home, color: Colors.orange),
              title: const Text('Root (No Folder)', style: TextStyle(fontWeight: FontWeight.bold)),
              onTap: () => Navigator.of(context).pop('__ROOT__'), // Return __ROOT__ for Root
            ),
            const Divider(),
            
            // Folder Tree
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _buildFolderTree(null, 0),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Create New Folder Button
        TextButton.icon(
          onPressed: _showCreateFolderDialog,
          icon: const Icon(Icons.add),
          label: const Text('New Folder'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(), // Cancel returns nothing (null? No, dialog returns nothing)
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Future<void> _showCreateFolderDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Folder Name'),
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      try {
        // Create in Root
        await widget.docService.createFolder(name);
        setState(() {}); // Refresh tree
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Folder "$name" created')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(content: Text('Error creating folder: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  List<Widget> _buildFolderTree(String? parentId, int depth) {
    final folders = parentId == null
        ? widget.docService.getRootFolders()
        : widget.docService.getSubfolders(parentId);
    
    // Filter excluded
    final filteredFolders = folders.where((f) => !widget.excludedFolderIds.contains(f.id)).toList();
    
    if (filteredFolders.isEmpty && parentId != null && depth > 0) {
       // Only if expanded leaf?
       return [];
    }

    return filteredFolders.expand((folder) {
      final hasChildren = widget.docService.getSubfolders(folder.id).isNotEmpty;
      final isExpanded = _expandedFolders.contains(folder.id);
      
      return [
        ListTile(
          contentPadding: EdgeInsets.only(left: 16.0 + (depth * 24.0), right: 16),
          leading: hasChildren
              ? IconButton(
                  icon: Icon(isExpanded ? Icons.expand_more : Icons.chevron_right),
                  onPressed: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedFolders.remove(folder.id);
                      } else {
                        _expandedFolders.add(folder.id);
                      }
                    });
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
              : const SizedBox(width: 24),
          title: Row(
            children: [
              Icon(Icons.folder, 
                color: depth == 0 ? Colors.blue : Colors.blue.withOpacity(0.7),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(folder.name)),
            ],
          ),
          onTap: () => Navigator.of(context).pop(folder.id),
        ),
        if (hasChildren && isExpanded)
          ..._buildFolderTree(folder.id, depth + 1),
      ];
    }).toList();
  }
}
