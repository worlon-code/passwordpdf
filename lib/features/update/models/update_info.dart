class UpdateInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;

  UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.releaseNotes,
    this.forceUpdate = false,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    // Robust parsing with fallbacks
    return UpdateInfo(
      // Support 'latestVersion' legacy key if 'version' is missing or null
      version: (json['version'] ?? json['latestVersion'] ?? '') as String,
      buildNumber: (json['buildNumber'] ?? 0) as int,
      downloadUrl: (json['downloadUrl'] ?? '') as String,
      releaseNotes: (json['releaseNotes'] ?? '') as String,
      forceUpdate: (json['forceUpdate'] ?? false) as bool,
    );
  }
}
