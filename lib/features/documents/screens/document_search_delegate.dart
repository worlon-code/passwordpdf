import 'package:flutter/material.dart';
import '../../../models/document_item_model.dart';
import '../../../services/ai/hybrid_search_service.dart';
import '../../../services/ai/multi_pdf_rag_service.dart';
import '../../../services/document_service.dart';
import 'pdf_viewer_screen.dart';

/// Upgraded search delegate providing Filename, Full-Text, and Offline RAG tabs
class DocumentSearchDelegate extends SearchDelegate<DocumentItem?> {
  final DocumentService docService;
  final List<DocumentItem> allItems;
  final HybridSearchService _hybridSearch = HybridSearchService();
  final MultiPdfRagService _ragService = MultiPdfRagService();

  DocumentSearchDelegate(this.docService) : allItems = docService.getAllItems();

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
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
    return _buildTabs(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    return _buildTabs(context);
  }

  Widget _buildTabs(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Container(
            color: Theme.of(context).colorScheme.surface,
            child: const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.title, size: 20), text: 'Filenames'),
                Tab(icon: Icon(Icons.find_in_page, size: 20), text: 'Full-Text'),
                Tab(icon: Icon(Icons.psychology, size: 20), text: 'Ask AI'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildFilenamesTab(context),
                _buildFullTextTab(context),
                _buildAskAiTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==================== TAB 1: FILENAMES ====================
  Widget _buildFilenamesTab(BuildContext context) {
    final results = allItems.where((item) {
      return item.name.toLowerCase().contains(query.toLowerCase());
    }).toList();

    if (results.isEmpty) {
      return Center(
        child: Text(
          query.isEmpty ? 'Type to search file names...' : 'No files found',
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
              : Text(
                  '${item.createdAt.year}-${item.createdAt.month.toString().padLeft(2, '0')}-${item.createdAt.day.toString().padLeft(2, '0')}',
                ),
          onTap: () => close(context, item),
        );
      },
    );
  }

  // ==================== TAB 2: FULL-TEXT SEARCH ====================
  Widget _buildFullTextTab(BuildContext context) {
    if (query.trim().isEmpty) {
      return const Center(
        child: Text('Type a keyword to search text inside all indexed PDFs...'),
      );
    }

    return FutureBuilder<List<SearchResultItem>>(
      future: _hybridSearch.search(query: query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const Center(
            child: Text(
              'No full-text matches in indexed documents.\nOpen your PDFs to ensure they are indexed.',
              textAlign: TextAlign.center,
            ),
          );
        }

        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
                title: Text(
                  item.fileName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Page ${item.pageNumber}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(
                      item.chunkText,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                onTap: () {
                  if (item.filePath.isNotEmpty) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PdfViewerScreen(
                          filePath: item.filePath,
                          fileName: item.fileName,
                          initialPageNumber: item.pageNumber,
                        ),
                      ),
                    );
                  }
                },
              ),
            );
          },
        );
      },
    );
  }

  // ==================== TAB 3: ASK AI (RAG) ====================
  Widget _buildAskAiTab(BuildContext context) {
    if (query.trim().isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Ask a question about your documents\n(e.g. "What is the policy renewal date?")',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return FutureBuilder<RagAnswerResult>(
      future: _ragService.answerQuestion(question: query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Analyzing document evidence...'),
              ],
            ),
          );
        }

        final result = snapshot.data;
        if (result == null || result.citations.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                result?.answer ?? 'No answers found in documents.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.psychology, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            'Answer',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        result.answer,
                        style: const TextStyle(fontSize: 14, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Document Evidence & Citations:',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...result.citations.map((cite) {
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
                    title: Text(cite.fileName),
                    subtitle: Text('Page ${cite.pageNumber}: "${cite.snippet}"'),
                    trailing: const Icon(Icons.open_in_new, size: 16),
                    onTap: () {
                      if (cite.filePath.isNotEmpty) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PdfViewerScreen(
                              filePath: cite.filePath,
                              fileName: cite.fileName,
                              initialPageNumber: cite.pageNumber,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                );
              }),
            ],
          ),
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
        return Colors.blue;
      case 'csv':
      case 'tsv':
        return Colors.teal;
      case 'xls':
      case 'xlsx':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }
}
