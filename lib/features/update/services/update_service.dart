import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
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

  Future<File?> downloadUpdate(String url, Function(int, int) onProgress) async {
    try {
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
          followRedirects: true,
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
           return null;
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
      final file = File('${dir.path}/update.apk');
      
      if (await file.exists()) {
        await file.delete();
        _log.info('UpdateService', 'Cleaned up install file');
      }
    } catch (e, stack) {
      _log.error('UpdateService', 'Cleanup failed', e, stack);
    }
  }
}
