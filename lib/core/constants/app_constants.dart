/// Application-wide constants
class AppConstants {
  // App Info
  static const String appName = 'PDF Manager';
  static const String appVersion = '1.0.0';
  
  // Database
  static const String databaseName = 'passwordpdf.db';
  static const int databaseVersion = 3;
  
  // Tables
  static const String passwordsTable = 'passwords';
  static const String recentDocumentsTable = 'recent_documents';
  static const String settingsTable = 'settings';
  static const String exportJobsTable = 'export_jobs';
  static const String logsTable = 'logs';
  static const String filesIndexTable = 'files_index';
  static const String passwordHistoryTable = 'password_history';
  static const String encryptedSignaturesTable = 'encrypted_signatures';
  static const String aiDocumentIndexTable = 'ai_document_index';
  static const String aiDocumentPagesTable = 'ai_document_pages';
  static const String aiDocumentChunksTable = 'ai_document_chunks';
  static const String aiChunkEmbeddingsTable = 'ai_chunk_embeddings';
  static const String aiChunksFtsTable = 'ai_chunks_fts';
  static const String aiInstalledModelsTable = 'ai_installed_models';
  static const String aiChatSessionsTable = 'ai_chat_sessions';
  static const String aiChatMessagesTable = 'ai_chat_messages';
  
  // Encryption
  static const String encryptionKeyName = 'pdf_encryption_key';
  
  // Settings Keys
  static const String settingsThemeMode = 'theme_mode';
  static const String settingsBiometricEnabled = 'biometric_enabled';
  
  // File Extensions
  static const List<String> supportedPdfExtensions = ['pdf'];
  static const List<String> supportedDocExtensions = ['doc', 'docx'];
  static const List<String> supportedExcelExtensions = ['xls', 'xlsx'];
  static const List<String> supportedCsvExtensions = ['csv', 'tsv'];
  
  // UI
  static const double defaultPadding = 16.0;
  static const double defaultRadius = 12.0;
  static const double defaultElevation = 4.0;
  
  // Recent Documents Limit
  static const int maxRecentDocuments = 50;
}
