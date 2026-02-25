
enum ConflictActionType {
  rename,
  overwrite,
  skip,
}

class ConflictAction {
  final ConflictActionType type;
  final String? renameSuffix; // For rename actions

  ConflictAction({required this.type, this.renameSuffix});
}

class ConflictItem {
  final String sourceId;
  final String name;
  final String originalPath;
  final bool isFolder;

  ConflictItem({
    required this.sourceId,
    required this.name,
    required this.originalPath,
    this.isFolder = false,
  });
}
