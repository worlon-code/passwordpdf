import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../models/update_info.dart';

class UpdateService {
  // Raw GitHub User Content URL
  static const String _versionUrl = 'https://raw.githubusercontent.com/worlon-code/passwordpdf-releases/main/version.json';

  Future<UpdateInfo?> checkForUpdate() async {
    final info = await getLatestReleaseInfo();
    if (info == null) return null;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      print('UpdateService Check: Current Build: $currentBuild, Remote Build: ${info.buildNumber}');

      if (info.buildNumber > currentBuild) {
        return info;
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
