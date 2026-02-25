import '../../../models/recent_document_model.dart';
import '../../../services/storage_service.dart';
import 'dart:io';

/// Service for managing recent documents
class RecentService {
  final StorageService _storageService = StorageService();

  /// Add document to recent list
  Future<void> addRecentDocument(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return;

      final fileName = file.path.split(Platform.pathSeparator).last;
      final fileSize = await file.length();

      final document = RecentDocumentModel(
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        lastAccessed: DateTime.now(),
      );

      await _storageService.insertOrUpdateRecentDocument(document);
    } catch (e) {
      print('Error adding recent document: $e');
    }
  }

  /// Get all recent documents
  Future<List<RecentDocumentModel>> getRecentDocuments() async {
    try {
      final documents = await _storageService.getRecentDocuments();
      
      // Filter out documents that no longer exist
      final existingDocuments = <RecentDocumentModel>[];
      for (final doc in documents) {
        final file = File(doc.filePath);
        if (await file.exists()) {
          existingDocuments.add(doc);
        } else {
          // Remove from database if file doesn't exist
          if (doc.id != null) {
            await _storageService.deleteRecentDocument(doc.id!);
          }
        }
      }
      
      return existingDocuments;
    } catch (e) {
      print('Error getting recent documents: $e');
      return [];
    }
  }

  /// Remove document from recent list
  Future<void> removeRecentDocument(int id) async {
    try {
      await _storageService.deleteRecentDocument(id);
    } catch (e) {
      print('Error removing recent document: $e');
    }
  }

  /// Clear all recent documents
  Future<void> clearRecentDocuments() async {
    try {
      await _storageService.clearRecentDocuments();
    } catch (e) {
      print('Error clearing recent documents: $e');
    }
  }
}
