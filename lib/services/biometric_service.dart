import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:flutter/services.dart';
import 'logging_service.dart';

/// Service for biometric authentication with detailed logging
class BiometricService {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  final LocalAuthentication _localAuth = LocalAuthentication();
  final LoggingService _log = LoggingService();
  static const String _tag = 'BiometricService';

  /// Check if biometric authentication is available on device (Hardware exists)
  Future<bool> isBiometricAvailable() async {
    try {
      _log.debug(_tag, 'Checking if biometrics hardware exists...');
      final isSupported = await _localAuth.isDeviceSupported();
      _log.info(_tag, 'isDeviceSupported: $isSupported');
      return isSupported;
    } on PlatformException catch (e) {
      _log.error(_tag, 'Error checking biometric availability', e, StackTrace.current);
      return false;
    }
  }

  /// Get list of available biometric types (Enrolled ones)
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      _log.debug(_tag, 'Getting enrolled biometrics...');
      final biometrics = await _localAuth.getAvailableBiometrics();
      _log.info(_tag, 'Enrolled biometrics: ${biometrics.map((b) => b.name).join(', ')}');
      return biometrics;
    } on PlatformException catch (e) {
      _log.error(_tag, 'Error getting available biometrics', e, StackTrace.current);
      return <BiometricType>[];
    }
  }

  /// Authenticate user with biometrics
  Future<bool> authenticate({
    String localizedReason = 'Please authenticate to access the app',
  }) async {
    try {
      _log.info(_tag, 'Starting authentication...');
      
      // First check if hardware exists
      final isSupported = await _localAuth.isDeviceSupported();
      if (!isSupported) {
        _log.error(_tag, 'Biometric hardware not supported on this device');
        return false;
      }
      
      _log.debug(_tag, 'Calling authenticate with sensitiveTransaction=false for Face Unlock');
      
      final authenticated = await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          sensitiveTransaction: false, // CRITICAL: Allows Face Unlock (Weak/Class 2) on Android
          useErrorDialogs: true,
        ),
      );
      
      _log.info(_tag, 'Authentication result: $authenticated');
      return authenticated;
    } on PlatformException catch (e) {
      _log.error(
        _tag, 
        'PlatformException during authentication: code=${e.code}, message=${e.message}, details=${e.details}',
        e,
        StackTrace.current,
      );
      return false;
    } catch (e, stackTrace) {
      _log.error(_tag, 'Unexpected error during authentication', e, stackTrace);
      return false;
    }
  }

  /// Stop authentication
  Future<void> stopAuthentication() async {
    try {
      await _localAuth.stopAuthentication();
    } catch (_) {}
  }

  /// Check if device supports biometric authentication (Main check for Settings toggle)
  Future<bool> isDeviceSupported() async {
    try {
      // Just check if the device HAS the hardware. 
      // Enrollment check can happen during the actual toggle/auth flow.
      final isSupported = await _localAuth.isDeviceSupported();
      _log.info(_tag, 'isDeviceSupported (Settings Check): $isSupported');
      return isSupported;
    } catch (e) {
      _log.error(_tag, 'Error checking device support', e);
      return false;
    }
  }
  
  /// Get detailed status for debugging
  Future<Map<String, dynamic>> getDetailedStatus() async {
    _log.info(_tag, 'Getting detailed biometric status...');
    
    final status = <String, dynamic>{};
    
    try {
      status['canCheckBiometrics'] = await _localAuth.canCheckBiometrics;
    } catch (e) {
      status['canCheckBiometrics'] = 'Error: $e';
    }
    
    try {
      status['isDeviceSupported'] = await _localAuth.isDeviceSupported();
    } catch (e) {
      status['isDeviceSupported'] = 'Error: $e';
    }
    
    try {
      final biometrics = await _localAuth.getAvailableBiometrics();
      status['availableBiometrics'] = biometrics.map((b) => b.name).toList();
      status['biometricsCount'] = biometrics.length;
    } catch (e) {
      status['availableBiometrics'] = 'Error: $e';
    }
    
    _log.info(_tag, 'Detailed status: $status');
    return status;
  }

  /// Helper to get a human-readable label for available biometrics
  Future<String> getBiometricLabel() async {
    final types = await getAvailableBiometrics();
    if (types.contains(BiometricType.face)) return 'Face Unlock';
    if (types.contains(BiometricType.fingerprint)) return 'Fingerprint Unlock';
    if (types.contains(BiometricType.iris)) return 'Iris Unlock';
    
    // If no specific type enrolled but hardware is supported
    if (await isDeviceSupported()) {
      return 'Biometric Unlock';
    }
    
    return 'Biometric Unlock';
  }

  /// Helper to get an appropriate icon for available biometrics
  Future<dynamic> getBiometricIcon() async {
    final types = await getAvailableBiometrics();
    
    if (types.contains(BiometricType.face)) return 'face';
    if (types.contains(BiometricType.fingerprint)) return 'fingerprint';
    if (types.contains(BiometricType.iris)) return 'remove_red_eye';
    
    // Default security icon if hardware is there but not enrolled
    if (await isDeviceSupported()) {
      return 'security';
    }
    
    return 'fingerprint';
  }
}
