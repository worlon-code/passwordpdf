import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../models/update_info.dart';

class UpdateService {
  // Raw GitHub User Content URL
  static const String _versionUrl = 'https://raw.githubusercontent.com/worlon-code/passwordpdf-releases/main/version.json';
  
  // Notifier for UI (Red Dot)
  final ValueNotifier<bool> updateAvailableNotifier = ValueNotifier<bool>(false);

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final hasUpdate = prefs.getBool('update_available') ?? false;
    updateAvailableNotifier.value = hasUpdate;
  }

  Future<UpdateInfo?> checkForUpdate({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Weekly Check Logic
    if (!force) {
      final lastCheckStr = prefs.getString('last_update_check_time');
      if (lastCheckStr != null) {
        final lastCheck = DateTime.tryParse(lastCheckStr);
        if (lastCheck != null) {
          final now = DateTime.now();
          final difference = now.difference(lastCheck).inDays;
          if (difference < 7) {
            print('UpdateService: Skipping auto-check (Last check: $difference days ago)');
            
            // Still check red dot status from prefs to keep UI consistent
            final hasUpdate = prefs.getBool('update_available') ?? false;
            updateAvailableNotifier.value = hasUpdate;
            return null;
          }
        }
      }
    }

    final info = await getLatestReleaseInfo();
    if (info == null) return null;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      print('UpdateService Check: Current Build: $currentBuild, Remote Build: ${info.buildNumber}');

      // Update last check time
      await prefs.setString('last_update_check_time', DateTime.now().toIso8601String());

      if (info.buildNumber > currentBuild) {
        updateAvailableNotifier.value = true; // Trigger Red Dot
        await prefs.setBool('update_available', true);
        return info;
      } else {
        // No update available (or we are on the latest)
        if (updateAvailableNotifier.value) {
           updateAvailableNotifier.value = false;
           await prefs.setBool('update_available', false);
        }
      }
    } catch (e) {
      print('Update check failed: $e');
    }
    return null;
  }

  Future<UpdateInfo?> getLatestReleaseInfo() async {
    try {
      final dio = Dio();
      // Add cache breaking parameter
      final response = await dio.get('$_versionUrl?t=${DateTime.now().millisecondsSinceEpoch}');

      if (response.statusCode == 200) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        return UpdateInfo.fromJson(data);
      }
    } catch (e) {
      print('Failed to get release info: $e');
    }
    return null;
  }

  Future<File?> downloadUpdate(String url, Function(int, int) onProgress) async {
    try {
      // Use getExternalCacheDirectories for better compatibility with Package Installer
      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();
      
      final fileName = 'update.apk';
      final savePath = '${dir.path}/$fileName';

      // Delete existing
      final file = File(savePath);
      if (await file.exists()) {
        await file.delete();
      }

      final dio = Dio();
      await dio.download(url, savePath, onReceiveProgress: onProgress);

      return File(savePath);
    } catch (e) {
      print('Download failed: $e');
      return null;
    }
  }

  Future<OpenResult> installUpdate(File file) async {
    if (await file.exists()) {
       return await OpenFilex.open(file.path);
    }
    return OpenResult(type: ResultType.fileNotFound, message: 'File not found');
  }

  Future<void> cleanupUpdateFile() async {
    try {
      final dirs = await getExternalCacheDirectories();
      final dir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getTemporaryDirectory();
      final file = File('${dir.path}/update.apk');
      
      if (await file.exists()) {
        await file.delete();
        print('UpdateService: Cleaned up install file');
      }
    } catch (e) {
      print('UpdateService: Cleanup failed: $e');
    }
  }
}
