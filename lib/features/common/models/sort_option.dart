
enum SortOption {
  name,
  size,
  dateCreated,
  dateModified;

  String get label {
    switch (this) {
      case SortOption.name: return 'Name';
      case SortOption.size: return 'Size';
      case SortOption.dateCreated: return 'Date Created';
      case SortOption.dateModified: return 'Date Modified';
    }
  }
}
