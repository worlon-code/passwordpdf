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
  final bool isImportedFile; // True if file manually added to synced folder
  final bool isNew; // For "NEW" badge
  final bool missingOnDevice; // For "Removed" files
  final DateTime? addedAt;
  final DateTime? lastSynced;

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
    this.isImportedFile = false,
    this.isNew = false,
    this.missingOnDevice = false,
    this.addedAt,
    this.lastSynced,
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
    bool? isImportedFile,
    bool? isNew,
    bool? missingOnDevice,
    DateTime? addedAt,
    DateTime? lastSynced,
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
      isImportedFile: isImportedFile ?? this.isImportedFile,
      isNew: isNew ?? this.isNew,
      missingOnDevice: missingOnDevice ?? this.missingOnDevice,
      addedAt: addedAt ?? this.addedAt,
      lastSynced: lastSynced ?? this.lastSynced,
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
      'isImportedFile': isImportedFile,
      'isNew': isNew,
      'missingOnDevice': missingOnDevice,
      'addedAt': addedAt?.toIso8601String(),
      'lastSynced': lastSynced?.toIso8601String(),
    };
  }

  factory DocumentItem.fromJson(Map<String, dynamic> json) {
    final path = json['sourcePath'] as String? ?? json['filePath'] as String?;
    
    DocumentItemType itemType = DocumentItemType.file;
    final rawType = json['type']?.toString().toLowerCase();
    if (rawType != null) {
      if (rawType.contains('folder')) {
        itemType = DocumentItemType.folder;
      } else {
        itemType = DocumentItemType.file;
      }
    }

    DateTime parseDate(dynamic val) {
      if (val is String) {
        return DateTime.tryParse(val) ?? DateTime.now();
      } else if (val is int) {
        return DateTime.fromMillisecondsSinceEpoch(val);
      }
      return DateTime.now();
    }

    DateTime? parseNullableDate(dynamic val) {
      if (val == null) return null;
      if (val is String) {
        return DateTime.tryParse(val);
      } else if (val is int) {
        return DateTime.fromMillisecondsSinceEpoch(val);
      }
      return null;
    }
    
    return DocumentItem(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? 'Untitled',
      type: itemType,
      sourcePath: path,
      parentId: json['parentId'] as String?,
      fileIds: (json['fileIds'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      size: (json['size'] is num) ? (json['size'] as num).toInt() : 0,
      createdAt: parseDate(json['createdAt']),
      modifiedAt: parseDate(json['modifiedAt']),
      isImported: json['isImported'] as bool? ?? false,
      isImportedFile: json['isImportedFile'] as bool? ?? false,
      isNew: json['isNew'] as bool? ?? false,
      missingOnDevice: json['missingOnDevice'] as bool? ?? false,
      addedAt: parseNullableDate(json['addedAt']),
      lastSynced: parseNullableDate(json['lastSynced']),
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
