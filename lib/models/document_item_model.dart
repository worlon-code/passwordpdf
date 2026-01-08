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
  final bool isImported; // True if created via Folder Import (Restricted Move/Sync Managed)

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
    this.isImported = false,
  })  : fileIds = fileIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        modifiedAt = modifiedAt ?? DateTime.now();

  bool get isFolder => type == DocumentItemType.folder;
  bool get isFile => type == DocumentItemType.file;

  DocumentItem copyWith({
    String? name,
    String? sourcePath,
    String? parentId,
    bool clearParentId = false,
    List<String>? fileIds,
    int? size,
    DateTime? modifiedAt,
    bool? isImported,
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
      isImported: isImported ?? this.isImported,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.toString(),
      'sourcePath': sourcePath, 
      'filePath': sourcePath, 
      'parentId': parentId,
      'fileIds': fileIds,
      'size': size,
      'createdAt': createdAt.toIso8601String(),
      'modifiedAt': modifiedAt.toIso8601String(),
      'isImported': isImported,
    };
  }

  factory DocumentItem.fromJson(Map<String, dynamic> json) {
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
      isImported: json['isImported'] as bool? ?? false,
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
