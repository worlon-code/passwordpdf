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
  
  ThemeMode _themeMode = ThemeMode.light;
  AuthMethod _authMethod = AuthMethod.none;
  bool _hasPinSet = false;
  Color _accentColor = const Color(0xFF6750A4); // Default Material 3 primary
  int _fontSizeAdjustment = -4; // -7 to 0, default -4
  int _maxLogCount = 8000;
  bool _developerModeEnabled = false;
  int _defaultScreenIndex = 0; // 0 = All Docs, 1 = Documents
  int _autoLockTimeout = 10; // Default 10 minutes
  int _lastViewedBuildNumber = 0; // For What's New dialog

  /// Getters
  ThemeMode get themeMode => _themeMode;
  AuthMethod get authMethod => _authMethod;
  bool get hasPinSet => _hasPinSet;
  bool get isDarkMode => _themeMode == ThemeMode.dark;
  bool get biometricEnabled => _authMethod == AuthMethod.fingerprintOnly || _authMethod == AuthMethod.both;
  bool get pinEnabled => _authMethod == AuthMethod.pinOnly || _authMethod == AuthMethod.both;
  Color get accentColor => _accentColor;
  int get fontSizeAdjustment => _fontSizeAdjustment;
  int get maxLogCount => _maxLogCount;
  bool get developerModeEnabled => _developerModeEnabled;
  int get defaultScreenIndex => _defaultScreenIndex;
  int get autoLockTimeout => _autoLockTimeout;
  int get lastViewedBuildNumber => _lastViewedBuildNumber;

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

    // Load accent color
    final accentColorInt = _prefs!.getInt('accent_color');
    if (accentColorInt != null) {
      _accentColor = Color(accentColorInt);
    }

    // Load font size adjustment
    final fontAdj = _prefs!.getInt('font_size_adjustment');
    if (fontAdj != null) {
      _fontSizeAdjustment = fontAdj.clamp(-7, 0);
    }

    // Load max log count
    final maxLog = _prefs!.getInt('max_log_count');
    if (maxLog != null) {
      _maxLogCount = maxLog.clamp(1000, 50000);
    }
    _log.setMaxLogLimit(_maxLogCount);

    // Check if PIN is set
    final pin = await _secureStorage.read(key: 'app_pin');
    _hasPinSet = pin != null && pin.isNotEmpty;
    
    // Load developer mode
    _developerModeEnabled = _prefs!.getBool('developer_mode_enabled') ?? false;
    
    // Load default screen index (0 = All Docs, 1 = Documents)
    _defaultScreenIndex = _prefs!.getInt('default_screen_index') ?? 0;

    // Load auto-lock timeout
    final timeout = _prefs!.getInt('auto_lock_timeout');
    if (timeout != null) {
      _autoLockTimeout = timeout.clamp(3, 30);
    }

    // Load last viewed build number
    _lastViewedBuildNumber = _prefs!.getInt('last_viewed_build_number') ?? 0;

    _log.info('SettingsService', 'Settings loaded: themeMode=$_themeMode, authMethod=$_authMethod, hasPinSet=$_hasPinSet, developerMode=$_developerModeEnabled, defaultScreen=$_defaultScreenIndex, autoLockTimeout=$_autoLockTimeout');
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

  /// Set accent color
  Future<void> setAccentColor(Color color) async {
    _accentColor = color;
    await _prefs?.setInt('accent_color', color.value);
    notifyListeners();
  }

  /// Set font size adjustment (-7 to 0)
  Future<void> setFontSizeAdjustment(int adjustment) async {
    _fontSizeAdjustment = adjustment.clamp(-7, 0);
    await _prefs?.setInt('font_size_adjustment', _fontSizeAdjustment);
    notifyListeners();
  }

  /// Set max log count (1000 to 50000)
  Future<void> setMaxLogCount(int count) async {
    _maxLogCount = count.clamp(1000, 50000);
    await _prefs?.setInt('max_log_count', _maxLogCount);
    _log.setMaxLogLimit(_maxLogCount);
    notifyListeners();
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

  /// Get export path (defaults to Downloads/PDF Manager)
  String get exportPath => _prefs?.getString('export_path') ?? '/storage/emulated/0/Download/PDF Manager';

  /// Set export path
  Future<void> setExportPath(String path) async {
    await _prefs?.setString('export_path', path);
    _log.info('SettingsService', 'Export path set to: $path');
    notifyListeners();
  }

  /// Enable Developer Mode (one-time unlock)
  Future<void> enableDeveloperMode() async {
    _developerModeEnabled = true;
    await _prefs?.setBool('developer_mode_enabled', true);
    _log.info('SettingsService', 'Developer mode enabled');
    notifyListeners();
  }

  /// Set default screen index (0 = All Docs, 1 = Documents)
  Future<void> setDefaultScreenIndex(int index) async {
    _defaultScreenIndex = index.clamp(0, 1);
    await _prefs?.setInt('default_screen_index', _defaultScreenIndex);
    _log.info('SettingsService', 'Default screen set to: ${_defaultScreenIndex == 0 ? 'All Docs' : 'Documents'}');
    notifyListeners();
  }

  /// Set auto-lock timeout (3 to 30 minutes)
  Future<void> setAutoLockTimeout(int minutes) async {
    _autoLockTimeout = minutes.clamp(3, 30);
    await _prefs?.setInt('auto_lock_timeout', _autoLockTimeout);
    _log.info('SettingsService', 'Auto-lock timeout set to: $_autoLockTimeout minutes');
    notifyListeners();
  }

  /// Set last viewed build number (to suppress What's New for this version)
  Future<void> setLastViewedBuildNumber(int buildNumber) async {
    _lastViewedBuildNumber = buildNumber;
    await _prefs?.setInt('last_viewed_build_number', _lastViewedBuildNumber);
    // No notify needed strictly, but good practice
    notifyListeners();
  }

}
