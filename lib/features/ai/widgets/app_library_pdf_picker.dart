import 'package:flutter/material.dart';
import '../../../models/document_item_model.dart';
import '../../../services/document_service.dart';

/// Interactive picker that mirrors the App Library folder hierarchy for attaching PDFs to AI Chat
class AppLibraryPdfPicker extends StatefulWidget {
  final Set<String> alreadyAttachedPaths;
  final int maxSelectable;

  const AppLibraryPdfPicker({
    super.key,
    required this.alreadyAttachedPaths,
    this.maxSelectable = 4,
  });

  @override
  State<AppLibraryPdfPicker> createState() => _AppLibraryPdfPickerState();
}

class _AppLibraryPdfPickerState extends State<AppLibraryPdfPicker> {
  final DocumentService _docService = DocumentService();
  bool _isLoading = true;

  // Folder navigation stack: null represents root
  final List<String?> _folderStack = [null];
  final Map<String, DocumentItem> _selectedItems = {};

  String? get _currentFolderId => _folderStack.last;

  @override
  void initState() {
    super.initState();
    _loadService();
  }

  Future<void> _loadService() async {
    await _docService.initialize();
    if (mounted) setState(() => _isLoading = false);
  }

  String _getBreadcrumbTitle() {
    if (_currentFolderId == null) return 'App Library (Root)';
    final folder = _docService.getFolders().where((f) => f.id == _currentFolderId).firstOrNull;
    return folder?.name ?? 'Folder';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return const Dialog(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading App Folders...'),
            ],
          ),
        ),
      );
    }

    // Get subfolders and pdf files in current level
    final List<DocumentItem> subfolders;
    final List<DocumentItem> pdfFiles;

    if (_currentFolderId == null) {
      subfolders = _docService.getRootFolders()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      pdfFiles = _docService
          .getUnorganizedFiles()
          .where((i) => i.isFile && i.sourcePath != null && i.sourcePath!.toLowerCase().endsWith('.pdf'))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else {
      subfolders = _docService.getSubfolders(_currentFolderId!)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      pdfFiles = _docService
          .getFilesInFolder(_currentFolderId!)
          .where((i) => i.isFile && i.sourcePath != null && i.sourcePath!.toLowerCase().endsWith('.pdf'))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.maxFinite,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.library_books, size: 20, color: colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Attach from App Library',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        Text(
                          _getBreadcrumbTitle(),
                          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Navigation bar if inside a subfolder
            if (_folderStack.length > 1)
              ListTile(
                dense: true,
                leading: const Icon(Icons.arrow_upward, size: 18),
                title: const Text('Back to parent folder', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                tileColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                onTap: () {
                  setState(() => _folderStack.removeLast());
                },
              ),

            // Folder & File List
            Expanded(
              child: (subfolders.isEmpty && pdfFiles.isEmpty)
                  ? Center(
                      child: Text(
                        'No PDF files or folders in this location.',
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        // Subfolders section
                        if (subfolders.isNotEmpty) ...[
                          ...subfolders.map((folder) {
                            final count = _docService.getFilesInFolder(folder.id).length;
                            return ListTile(
                              leading: const Icon(Icons.folder, color: Colors.amber, size: 28),
                              title: Text(folder.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text('$count item(s)', style: const TextStyle(fontSize: 11)),
                              trailing: const Icon(Icons.chevron_right, size: 18),
                              onTap: () {
                                setState(() => _folderStack.add(folder.id));
                              },
                            );
                          }),
                          if (pdfFiles.isNotEmpty) const Divider(height: 1),
                        ],

                        // PDF Files section
                        ...pdfFiles.map((doc) {
                          final isAlreadyAttached = widget.alreadyAttachedPaths.contains(doc.sourcePath);
                          final isSelected = _selectedItems.containsKey(doc.id);

                          final sizeText = doc.size > 0
                              ? '${(doc.size / (1024 * 1024)).toStringAsFixed(1)} MB'
                              : 'PDF Document';

                          return CheckboxListTile(
                            secondary: const Icon(Icons.picture_as_pdf, color: Colors.red, size: 26),
                            title: Text(doc.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                            subtitle: Text(
                              isAlreadyAttached ? 'Already in chat' : sizeText,
                              style: TextStyle(fontSize: 11, color: isAlreadyAttached ? Colors.green : Colors.grey[600]),
                            ),
                            value: isSelected,
                            enabled: !isAlreadyAttached,
                            onChanged: isAlreadyAttached
                                ? null
                                : (checked) {
                                    setState(() {
                                      if (checked == true) {
                                        if (_selectedItems.length >= widget.maxSelectable) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Maximum ${widget.maxSelectable} documents can be selected.')),
                                          );
                                          return;
                                        }
                                        _selectedItems[doc.id] = doc;
                                      } else {
                                        _selectedItems.remove(doc.id);
                                      }
                                    });
                                  },
                          );
                        }),
                      ],
                    ),
            ),

            const Divider(height: 1),

            // Actions
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Selected: ${_selectedItems.length}/${widget.maxSelectable}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _selectedItems.isEmpty
                            ? null
                            : () => Navigator.pop(context, _selectedItems.values.toList()),
                        child: Text('Add Selected (${_selectedItems.length})'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
