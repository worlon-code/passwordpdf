class UpdateInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;
  final String? sha256;

  UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.releaseNotes,
    this.forceUpdate = false,
    this.sha256,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    // Robust parsing with fallbacks (defensive casts: never blindly cast dynamic)
    final rawSha = json['sha256'];
    final shaStr = (rawSha == null || rawSha.toString().trim().isEmpty)
        ? null
        : rawSha.toString().trim().toLowerCase();
    return UpdateInfo(
      // Support 'latestVersion' legacy key if 'version' is missing or null
      version: (json['version'] ?? json['latestVersion'] ?? '').toString(),
      buildNumber: int.tryParse((json['buildNumber'] ?? 0).toString()) ?? 0,
      downloadUrl: (json['downloadUrl'] ?? '').toString(),
      releaseNotes: (json['releaseNotes'] ?? '').toString(),
      forceUpdate: (json['forceUpdate']?.toString().toLowerCase() == 'true'),
      sha256: shaStr,
    );
  }
}
