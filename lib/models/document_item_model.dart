/// Model for document item (file or folder)
class DocumentItem {
  final String id;
  final String name;
  final DocumentItemType type;
  final String? sourcePath; // Original device path (Zero Copy: no app storage copy)
  final String? parentId; // Parent folder ID for nested structure
  final List<String> fileIds; // Only for folders - contains file IDs
  final int size; // File size in bytes (0 for folders or legacy)
  final DateTime createdAt;
  final DateTime modifiedAt;

  DocumentItem({
    required this.id,
    required this.name,
    required this.type,
    this.sourcePath,
    this.parentId,
    List<String>? fileIds,
    this.size = 0,
    DateTime? createdAt,
    DateTime? modifiedAt,
  })  : fileIds = fileIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        modifiedAt = modifiedAt ?? DateTime.now();

  bool get isFolder => type == DocumentItemType.folder;
  bool get isFile => type == DocumentItemType.file;

  DocumentItem copyWith({
    String? name,
    String? sourcePath,
    String? parentId,
    bool clearParentId = false, // Set to true to explicitly set parentId to null
    List<String>? fileIds,
    int? size,
    DateTime? modifiedAt,
  }) {
    return DocumentItem(
      id: id,
      name: name ?? this.name,
      type: type,
      sourcePath: sourcePath ?? this.sourcePath,
      parentId: clearParentId ? null : (parentId ?? this.parentId),
      fileIds: fileIds ?? this.fileIds,
      size: size ?? this.size,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.toString(),
      'sourcePath': sourcePath, // Changed from 'filePath'
      'filePath': sourcePath, // Keep for backward compat (migration)
      'parentId': parentId,
      'fileIds': fileIds,
      'size': size,
      'createdAt': createdAt.toIso8601String(),
      'modifiedAt': modifiedAt.toIso8601String(),
    };
  }

  factory DocumentItem.fromJson(Map<String, dynamic> json) {
    // Support both old 'filePath' and new 'sourcePath' keys
    final path = json['sourcePath'] as String? ?? json['filePath'] as String?;
    
    return DocumentItem(
      id: json['id'] as String,
      name: json['name'] as String,
      type: DocumentItemType.values.firstWhere(
        (e) => e.toString() == json['type'],
      ),
      sourcePath: path,
      parentId: json['parentId'] as String?,
      fileIds: (json['fileIds'] as List<dynamic>?)?.cast<String>() ?? [],
      size: json['size'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      modifiedAt: DateTime.parse(json['modifiedAt'] as String),
    );
  }
}

enum DocumentItemType {
  folder,
  file,
}

/// Helper to get file extension
extension DocumentItemExtension on DocumentItem {
  String? get fileExtension {
    if (isFile && sourcePath != null) {
      final parts = sourcePath!.split('.');
      if (parts.length > 1) {
        return parts.last.toLowerCase();
      }
    }
    return null;
  }

  bool get isPdf => fileExtension == 'pdf';
  bool get isDoc => fileExtension == 'doc' || fileExtension == 'docx';
  bool get isExcel => fileExtension == 'xls' || fileExtension == 'xlsx';
}
