import 'package:flutter/material.dart';
import '../../../services/document_service.dart';
import '../../../models/document_item_model.dart';


class DocumentSearchDelegate extends SearchDelegate<DocumentItem?> {
  final DocumentService docService;
  final List<DocumentItem> allItems;

  DocumentSearchDelegate(this.docService) : allItems = docService.getAllItems();

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
            FocusScope.of(context).unfocus();
            showSuggestions(context);
          },
        ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildList(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) {
    final results = allItems.where((item) {
      return item.name.toLowerCase().contains(query.toLowerCase());
    }).toList();

    if (results.isEmpty) {
      return Center(
        child: Text(
          query.isEmpty ? 'Search documents...' : 'No results found',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        return ListTile(
          leading: Icon(
            item.isFolder ? Icons.folder : _getFileIcon(item.name),
            color: item.isFolder ? Colors.amber : _getFileColor(item.name),
          ),
          title: Text(item.name),
          subtitle: item.isFolder 
              ? null 
              : Text('${item.createdAt.year}-${item.createdAt.month.toString().padLeft(2, '0')}-${item.createdAt.day.toString().padLeft(2, '0')}'),
          onTap: () => close(context, item),
        );
      },
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'csv':
      case 'tsv':
        return Icons.table_view;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Colors.red;
      case 'doc':
      case 'docx':
        return const Color(0xFF185ABD);
      case 'csv':
      case 'tsv':
        return const Color(0xFF0F9D58);
      case 'xls':
      case 'xlsx':
        return const Color(0xFF107C41);
      default:
        return Colors.grey;
    }
  }
}
