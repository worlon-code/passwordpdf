/// Model for document item (file or folder)
class DocumentItem {
  final String id;
  final String name;
  final DocumentItemType type;
  final String? filePath; // Only for files
  final String? parentId; // Parent folder ID for nested structure
  final List<String> fileIds; // Only for folders - contains file IDs
  final int size; // File size in bytes (0 for folders or legacy)
  final DateTime createdAt;
  final DateTime modifiedAt;

  DocumentItem({
    required this.id,
    required this.name,
    required this.type,
    this.filePath,
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
      filePath: filePath,
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
      'filePath': filePath,
      'parentId': parentId,
      'fileIds': fileIds,
      'size': size,
      'createdAt': createdAt.toIso8601String(),
      'modifiedAt': modifiedAt.toIso8601String(),
    };
  }

  factory DocumentItem.fromJson(Map<String, dynamic> json) {
    return DocumentItem(
      id: json['id'] as String,
      name: json['name'] as String,
      type: DocumentItemType.values.firstWhere(
        (e) => e.toString() == json['type'],
      ),
      filePath: json['filePath'] as String?,
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
    if (isFile && filePath != null) {
      final parts = filePath!.split('.');
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
