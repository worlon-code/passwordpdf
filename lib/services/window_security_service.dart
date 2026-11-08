import 'dart:io';
import 'package:flutter/services.dart';

/// Service to toggle Android FLAG_SECURE (prevent screenshots, screen recording, and app switcher preview).
class WindowSecurityService {
  static const MethodChannel _channel =
      MethodChannel('com.passwordpdf.passwordpdf_manager/window_security');

  static final WindowSecurityService _instance = WindowSecurityService._internal();
  factory WindowSecurityService() => _instance;
  WindowSecurityService._internal();

  bool _isCurrentlySecure = false;
  bool get isCurrentlySecure => _isCurrentlySecure;

  /// Set secure flag on window
  Future<bool> setSecure(bool secure) async {
    if (!Platform.isAndroid) {
      _isCurrentlySecure = secure;
      return true;
    }

    try {
      final success = await _channel.invokeMethod<bool>('setSecure', {'secure': secure});
      if (success == true) {
        _isCurrentlySecure = secure;
      }
      return success ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Check if secure flag is set
  Future<bool> isSecure() async {
    if (!Platform.isAndroid) return _isCurrentlySecure;

    try {
      final result = await _channel.invokeMethod<bool>('isSecure');
      _isCurrentlySecure = result ?? false;
      return _isCurrentlySecure;
    } catch (_) {
      return false;
    }
  }
}
