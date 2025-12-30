/// Model class for recently accessed documents
class RecentDocumentModel {
  final int? id;
  final String filePath;
  final String fileName;
  final int fileSize;
  final DateTime lastAccessed;

  RecentDocumentModel({
    this.id,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.lastAccessed,
  });

  /// Convert to Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'file_path': filePath,
      'file_name': fileName,
      'file_size': fileSize,
      'last_accessed': lastAccessed.toIso8601String(),
    };
  }

  /// Create from database Map
  factory RecentDocumentModel.fromMap(Map<String, dynamic> map) {
    return RecentDocumentModel(
      id: map['id'] as int?,
      filePath: map['file_path'] as String,
      fileName: map['file_name'] as String,
      fileSize: map['file_size'] as int,
      lastAccessed: DateTime.parse(map['last_accessed'] as String),
    );
  }

  /// Create a copy with modified fields
  RecentDocumentModel copyWith({
    int? id,
    String? filePath,
    String? fileName,
    int? fileSize,
    DateTime? lastAccessed,
  }) {
    return RecentDocumentModel(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      lastAccessed: lastAccessed ?? this.lastAccessed,
    );
  }
}
