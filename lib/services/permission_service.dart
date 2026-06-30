import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'logging_service.dart';

/// Service for handling app permissions
class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  final LoggingService _log = LoggingService();
  static const String _tag = 'PermissionService';

  /// Request all necessary permissions at app startup
  Future<Map<Permission, PermissionStatus>> requestAllPermissions() async {
    _log.info(_tag, 'Requesting all necessary permissions...');
    
    final permissions = <Permission>[];
    
    if (Platform.isAndroid) {
      permissions.addAll([
        Permission.storage,
        Permission.manageExternalStorage,
        Permission.notification,
      ]);
    } else if (Platform.isIOS) {
      permissions.addAll([
        Permission.notification,
      ]);
    }
    
    final statuses = <Permission, PermissionStatus>{};
    
    for (final permission in permissions) {
      final status = await _requestPermission(permission);
      statuses[permission] = status;
    }
    
    _log.info(_tag, 'Permission request complete. Results: $statuses');
    return statuses;
  }

  /// Request a single permission
  Future<PermissionStatus> _requestPermission(Permission permission) async {
    _log.debug(_tag, 'Checking permission: ${permission.toString()}');
    
    final status = await permission.status;
    _log.debug(_tag, 'Current status: $status');
    
    if (status.isDenied || status.isRestricted) {
      _log.info(_tag, 'Requesting permission: ${permission.toString()}');
      final newStatus = await permission.request();
      _log.info(_tag, 'Permission ${permission.toString()} result: $newStatus');
      return newStatus;
    }
    
    if (status.isPermanentlyDenied) {
      _log.warn(_tag, 'Permission ${permission.toString()} permanently denied - user needs to enable in settings');
    }
    
    return status;
  }

  /// Check if all necessary permissions are granted
  Future<bool> areAllPermissionsGranted() async {
    _log.debug(_tag, 'Checking if all permissions are granted...');
    
    if (Platform.isIOS) {
      // iOS apps have sandboxed file access by default
      return true;
    }
    
    final storage = await Permission.storage.isGranted;
    _log.debug(_tag, 'Storage permission: $storage');
    
    // For Android 11+, check manage external storage
    final manageStorage = await Permission.manageExternalStorage.isGranted;
    _log.debug(_tag, 'Manage external storage permission: $manageStorage');
    
    return storage || manageStorage;
  }

  /// Open app settings for manually granting permissions
  Future<bool> openSettings() async {
    _log.info(_tag, 'Opening app settings...');
    return await openAppSettings();
  }

  /// Get detailed permission status
  Future<Map<String, String>> getPermissionStatus() async {
    _log.debug(_tag, 'Getting detailed permission status...');
    
    final status = <String, String>{};
    
    status['storage'] = (await Permission.storage.status).toString();
    status['manageExternalStorage'] = (await Permission.manageExternalStorage.status).toString();
    
    _log.info(_tag, 'Permission status: $status');
    return status;
  }
}
