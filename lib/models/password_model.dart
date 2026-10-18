/// Model class for stored passwords
class PasswordModel {
  final int? id;
  final String keyName; // User-friendly name for the password
  final String encryptedValue; // Encrypted password
  final DateTime createdAt;
  final List<String> tags;
  final bool isFavorite;
  final String? encryptedTags;

  PasswordModel({
    this.id,
    required this.keyName,
    required this.encryptedValue,
    required this.createdAt,
    this.tags = const [],
    this.isFavorite = false,
    this.encryptedTags,
  });

  /// Convert to Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'key_name': keyName,
      'encrypted_value': encryptedValue,
      'created_at': createdAt.toIso8601String(),
      'is_favorite': isFavorite ? 1 : 0,
      'encrypted_tags': encryptedTags,
    };
  }

  /// Create from database Map
  factory PasswordModel.fromMap(Map<String, dynamic> map, {List<String>? decryptedTags}) {
    return PasswordModel(
      id: map['id'] as int?,
      keyName: map['key_name'] as String,
      encryptedValue: map['encrypted_value'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      isFavorite: (map['is_favorite'] as int? ?? 0) == 1,
      encryptedTags: map['encrypted_tags'] as String?,
      tags: decryptedTags ?? const [],
    );
  }

  /// Create a copy with modified fields
  PasswordModel copyWith({
    int? id,
    String? keyName,
    String? encryptedValue,
    DateTime? createdAt,
    List<String>? tags,
    bool? isFavorite,
    String? encryptedTags,
  }) {
    return PasswordModel(
      id: id ?? this.id,
      keyName: keyName ?? this.keyName,
      encryptedValue: encryptedValue ?? this.encryptedValue,
      createdAt: createdAt ?? this.createdAt,
      tags: tags ?? this.tags,
      isFavorite: isFavorite ?? this.isFavorite,
      encryptedTags: encryptedTags ?? this.encryptedTags,
    );
  }
}
