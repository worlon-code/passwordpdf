import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../../../services/logging_service.dart';
import '../models/update_info.dart';

class UpdateService {
  final _log = LoggingService();
  // Raw GitHub User Content URL
  static const String _versionUrl = 'https://raw.githubusercontent.com/worlon-code/passwordpdf-releases/main/version.json';
  
  // Notifier for UI (Red Dot)
  final ValueNotifier<bool> updateAvailableNotifier = ValueNotifier<bool>(false);

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Check if we already have the latest version to clear stale flag
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      
      // If we are initialized and have an update flag, let's double check it against current build if possible
      // But since we don't have remote info here easily without fetching, 
      // we'll rely on checkForUpdate being called at startup.
      // However, to be safe, if we just updated, the flag might be stale.
    } catch (_) {}

    final hasUpdate = prefs.getBool('update_available') ?? false;
    updateAvailableNotifier.value = hasUpdate;
  }

  Future<void> _clearUpdateFlag() async {
    final prefs = await SharedPreferences.getInstance();
    updateAvailableNotifier.value = false;
    await prefs.setBool('update_available', false);
  }

  Future<UpdateInfo?> checkForUpdate({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    
    final packageInfo = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

    // Weekly Check Logic
    if (!force) {
      final lastCheckStr = prefs.getString('last_update_check_time');
      if (lastCheckStr != null) {
        final lastCheck = DateTime.tryParse(lastCheckStr);
        if (lastCheck != null) {
          final now = DateTime.now();
          final difference = now.difference(lastCheck).inDays;
          if (difference < 7) {
            _log.info('UpdateService', 'Skipping auto-check (Last check: $difference days ago)');
            
            // Check if flag is stale (we might have updated since last check)
            // But we don't know the remote build number without fetching.
            // However, if the user JUST updated, they are on a higher build than before.
            
            final hasUpdate = prefs.getBool('update_available') ?? false;
            updateAvailableNotifier.value = hasUpdate;
            return null;
          }
        }
      }
    }

    final info = await getLatestReleaseInfo();
    if (info == null) {
      _log.info('UpdateService', 'No remote info found or fetch failed');
      return null;
    }

    try {
      _log.info('UpdateService', 'Check: Current Build: $currentBuild, Remote Build: ${info.buildNumber}');

      // Update last check time
      await prefs.setString('last_update_check_time', DateTime.now().toIso8601String());

      if (info.buildNumber > currentBuild) {
        updateAvailableNotifier.value = true; // Trigger Red Dot
        await prefs.setBool('update_available', true);
        return info;
      } else {
        // No update available (or we are on the latest)
        await _clearUpdateFlag();
      }
    } catch (e, stack) {
      _log.error('UpdateService', 'Update check failed', e, stack);
    }
    return null;
  }

  Future<UpdateInfo?> getLatestReleaseInfo() async {
    try {
      final dio = Dio();
      // Add cache breaking parameter
      _log.info('UpdateService', 'Fetching latest release info from GitHub...');
      final response = await dio.get('$_versionUrl?t=${DateTime.now().millisecondsSinceEpoch}');

      if (response.statusCode == 200) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        return UpdateInfo.fromJson(data);
      } else {
        _log.error('UpdateService', 'Server returned error: ${response.statusCode}', null);
      }
    } catch (e, stack) {
      _log.error('UpdateService', 'Failed to get release info', e, stack);
    }
    return null;
  }

  /// Host that release artifacts must be served from. The download URL host
  /// must equal this (or be a subdomain of it); cross-origin URLs are rejected.
  static const String _releaseHost = 'github.com';

  bool _isAllowedHost(String host) {
    final h = host.toLowerCase();
    return h == _releaseHost || h.endsWith('.$_releaseHost');
  }

  Future<File?> downloadUpdate(
    String url,
    Function(int, int) onProgress, {
    String? expectedSha256,
  }) async {
    try {
      // SECURITY: only allow downloads from the trusted release host. Reject
      // anything pointing elsewhere before we ever make a request.
      final parsed = Uri.tryParse(url);
      if (parsed == null || !parsed.isAbsolute || !parsed.isScheme('https') || !_isAllowedHost(parsed.host)) {
        _log.error('UpdateService', 'Refusing download: untrusted or non-https URL host ($url)', null);
        return null;
      }

      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();

      final fileName = 'update_${DateTime.now().millisecondsSinceEpoch}.apk';
      final savePath = '${dir.path}/$fileName';

      _log.info('UpdateService', 'Starting download from: $url');
      _log.info('UpdateService', 'Saving to: $savePath');

      final dio = Dio();
      final response = await dio.download(
        url,
        savePath,
        onReceiveProgress: onProgress,
        options: Options(
          headers: {
            'User-Agent': 'Mozilla/5.0 (Android; Mobile; rv:100.0) Gecko/100.0 Firefox/100.0',
            'Accept': '*/*',
          },
          // SECURITY: do NOT follow redirects. A redirect could bounce the
          // download to an attacker-controlled host that bypasses the host check.
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      _log.info('UpdateService', 'Download Response Status: ${response.statusCode}');
      _log.info('UpdateService', 'Response Headers: ${response.headers.map}');

      if (response.statusCode != 200) {
        _log.error('UpdateService', 'Download failed: Server returned ${response.statusCode}', null);
        return null;
      }

      final file = File(savePath);
      if (await file.exists()) {
        final bytes = await file.length();
        _log.info('UpdateService', 'Downloaded file size: $bytes bytes');

        if (bytes < 1000) {
           _log.error('UpdateService', 'Downloaded file is unexpectedly small ($bytes bytes)', null);
           return null;
        }

        // Verify APK magic number (ZIP format: PK...)
        final raf = await file.open();
        final head = await raf.read(2);
        await raf.close();

        if (head.length < 2 || head[0] != 0x50 || head[1] != 0x4B) {
           _log.error('UpdateService', 'Downloaded file is not a valid APK/ZIP (Magic: ${head.toList()})', null);
           await file.delete().catchError((_) => file);
           return null;
        }

        // SECURITY: verify the SHA-256 supplied by the manifest, if present.
        // (When the server always emits sha256, a follow-up task should make a
        //  missing checksum a hard failure.)
        if (expectedSha256 != null && expectedSha256.isNotEmpty) {
          final fileBytes = await file.readAsBytes();
          final actual = sha256.convert(fileBytes).toString().toLowerCase();
          if (actual != expectedSha256.toLowerCase()) {
            _log.error('UpdateService',
                'APK checksum mismatch. expected=$expectedSha256 actual=$actual', null);
            await file.delete().catchError((_) => file);
            return null;
          }
          _log.info('UpdateService', 'APK checksum verified OK');
        } else {
          _log.info('UpdateService', 'No expected sha256 supplied; skipping checksum verification');
        }

        return file;
      }
      return null;
    } catch (e, stack) {
      _log.error('UpdateService', 'Download exception', e, stack);
      return null;
    }
  }

  Future<OpenResult> installUpdate(File file) async {
    if (await file.exists()) {
       _log.info('UpdateService', 'Initiating installation for: ${file.path}');
       final result = await OpenFilex.open(file.path);
       _log.info('UpdateService', 'Install Trigger Result: ${result.type}, Message: ${result.message}');
       return result;
    }
    _log.error('UpdateService', 'Installation failed: File not found at ${file.path}', null);
    return OpenResult(type: ResultType.fileNotFound, message: 'File not found');
  }

  Future<void> cleanupUpdateFile() async {
    try {
      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();

      // Downloads are named 'update_<timestamp>.apk' (see downloadUpdate), so
      // delete every matching leftover, not a single literal 'update.apk'.
      int deleted = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last
              : '';
          if (name.startsWith('update_') && name.endsWith('.apk')) {
            try {
              await entity.delete();
              deleted++;
            } catch (e, stack) {
              _log.error('UpdateService', 'Failed to delete stale update file: ${entity.path}', e, stack);
            }
          }
        }
      }
      if (deleted > 0) {
        _log.info('UpdateService', 'Cleaned up $deleted stale update file(s)');
      }
    } catch (e, stack) {
      _log.error('UpdateService', 'Cleanup failed', e, stack);
    }
  }
}
