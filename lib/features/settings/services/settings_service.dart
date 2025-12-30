import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import '../../../services/logging_service.dart';

/// Authentication method options
enum AuthMethod {
  none,
  pinOnly,
  fingerprintOnly,
  both, // fingerprint priority, PIN fallback
}

/// Service for managing app settings
class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  SharedPreferences? _prefs;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );
  final LoggingService _log = LoggingService();
  
  ThemeMode _themeMode = ThemeMode.system;
  AuthMethod _authMethod = AuthMethod.none;
  bool _hasPinSet = false;

  /// Getters
  ThemeMode get themeMode => _themeMode;
  AuthMethod get authMethod => _authMethod;
  bool get hasPinSet => _hasPinSet;
  bool get isDarkMode => _themeMode == ThemeMode.dark;
  bool get biometricEnabled => _authMethod == AuthMethod.fingerprintOnly || _authMethod == AuthMethod.both;
  bool get pinEnabled => _authMethod == AuthMethod.pinOnly || _authMethod == AuthMethod.both;

  /// Initialize settings service
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadSettings();
  }

  /// Load settings from preferences
  Future<void> _loadSettings() async {
    if (_prefs == null) return;

    _log.debug('SettingsService', 'Loading settings...');

    // Load theme mode
    final themeModeString = _prefs!.getString('theme_mode');
    if (themeModeString != null) {
      _themeMode = ThemeMode.values.firstWhere(
        (e) => e.toString() == themeModeString,
        orElse: () => ThemeMode.system,
      );
    }

    // Load auth method
    final authMethodString = _prefs!.getString('auth_method');
    if (authMethodString != null) {
      _authMethod = AuthMethod.values.firstWhere(
        (e) => e.toString() == authMethodString,
        orElse: () => AuthMethod.none,
      );
    }

    // Check if PIN is set
    final pin = await _secureStorage.read(key: 'app_pin');
    _hasPinSet = pin != null && pin.isNotEmpty;

    _log.info('SettingsService', 'Settings loaded: themeMode=$_themeMode, authMethod=$_authMethod, hasPinSet=$_hasPinSet');
    notifyListeners();
  }

  /// Toggle theme mode
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _prefs?.setString('theme_mode', mode.toString());
    notifyListeners();
  }

  /// Toggle dark mode
  Future<void> toggleDarkMode() async {
    if (_themeMode == ThemeMode.dark) {
      await setThemeMode(ThemeMode.light);
    } else {
      await setThemeMode(ThemeMode.dark);
    }
  }

  /// Set authentication method
  Future<void> setAuthMethod(AuthMethod method) async {
    _log.info('SettingsService', 'Setting auth method to: $method');
    _authMethod = method;
    await _prefs?.setString('auth_method', method.toString());
    notifyListeners();
  }

  /// Set biometric authentication enabled/disabled (legacy support)
  Future<void> setBiometricEnabled(bool enabled) async {
    if (enabled) {
      if (_hasPinSet) {
        // If PIN is set, use both
        await setAuthMethod(AuthMethod.both);
      } else {
        await setAuthMethod(AuthMethod.fingerprintOnly);
      }
    } else {
      if (_hasPinSet) {
        await setAuthMethod(AuthMethod.pinOnly);
      } else {
        await setAuthMethod(AuthMethod.none);
      }
    }
  }

  /// Set PIN
  Future<bool> setPin(String pin) async {
    try {
      _log.info('SettingsService', 'Setting new PIN...');
      await _secureStorage.write(key: 'app_pin', value: pin);
      _hasPinSet = true;
      
      // Update auth method
      if (_authMethod == AuthMethod.fingerprintOnly) {
        await setAuthMethod(AuthMethod.both);
      } else if (_authMethod == AuthMethod.none) {
        await setAuthMethod(AuthMethod.pinOnly);
      }
      
      notifyListeners();
      _log.info('SettingsService', 'PIN set successfully');
      return true;
    } catch (e) {
      _log.error('SettingsService', 'Failed to set PIN', e);
      return false;
    }
  }

  /// Verify PIN
  Future<bool> verifyPin(String pin) async {
    try {
      final storedPin = await _secureStorage.read(key: 'app_pin');
      final match = storedPin == pin;
      _log.info('SettingsService', 'PIN verification: ${match ? 'success' : 'failed'}');
      return match;
    } catch (e) {
      _log.error('SettingsService', 'Failed to verify PIN', e);
      return false;
    }
  }

  /// Remove PIN
  Future<bool> removePin() async {
    try {
      _log.info('SettingsService', 'Removing PIN...');
      await _secureStorage.delete(key: 'app_pin');
      _hasPinSet = false;
      
      // Update auth method
      if (_authMethod == AuthMethod.both) {
        await setAuthMethod(AuthMethod.fingerprintOnly);
      } else if (_authMethod == AuthMethod.pinOnly) {
        await setAuthMethod(AuthMethod.none);
      }
      
      notifyListeners();
      _log.info('SettingsService', 'PIN removed successfully');
      return true;
    } catch (e) {
      _log.error('SettingsService', 'Failed to remove PIN', e);
      return false;
    }
  }

  /// Change PIN
  Future<bool> changePin(String oldPin, String newPin) async {
    final verified = await verifyPin(oldPin);
    if (!verified) return false;
    return await setPin(newPin);
  }

  /// Get export path (defaults to Downloads)
  String? get exportPath => _prefs?.getString('export_path');

  /// Set export path
  Future<void> setExportPath(String path) async {
    await _prefs?.setString('export_path', path);
    _log.info('SettingsService', 'Export path set to: $path');
    notifyListeners();
  }

  /// Clear export path (revert to default Downloads)
  Future<void> clearExportPath() async {
    await _prefs?.remove('export_path');
    _log.info('SettingsService', 'Export path cleared, using default');
    notifyListeners();
  }
}
