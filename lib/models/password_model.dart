/// Model class for stored passwords
class PasswordModel {
  final int? id;
  final String keyName; // User-friendly name for the password
  final String encryptedValue; // Encrypted password
  final DateTime createdAt;

  PasswordModel({
    this.id,
    required this.keyName,
    required this.encryptedValue,
    required this.createdAt,
  });

  /// Convert to Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'key_name': keyName,
      'encrypted_value': encryptedValue,
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Create from database Map
  factory PasswordModel.fromMap(Map<String, dynamic> map) {
    return PasswordModel(
      id: map['id'] as int?,
      keyName: map['key_name'] as String,
      encryptedValue: map['encrypted_value'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// Create a copy with modified fields
  PasswordModel copyWith({
    int? id,
    String? keyName,
    String? encryptedValue,
    DateTime? createdAt,
  }) {
    return PasswordModel(
      id: id ?? this.id,
      keyName: keyName ?? this.keyName,
      encryptedValue: encryptedValue ?? this.encryptedValue,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
