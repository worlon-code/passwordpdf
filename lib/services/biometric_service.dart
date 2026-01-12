import 'package:local_auth/local_auth.dart';
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

  /// Check if biometric authentication is available on device
  Future<bool> isBiometricAvailable() async {
    try {
      _log.debug(_tag, 'Checking if biometrics can be checked...');
      final canCheck = await _localAuth.canCheckBiometrics;
      _log.info(_tag, 'canCheckBiometrics: $canCheck');
      
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      _log.info(_tag, 'isDeviceSupported: $isDeviceSupported');
      
      return canCheck && isDeviceSupported;
    } on PlatformException catch (e) {
      _log.error(_tag, 'Error checking biometric availability', e, StackTrace.current);
      return false;
    }
  }

  /// Get list of available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      _log.debug(_tag, 'Getting available biometrics...');
      final biometrics = await _localAuth.getAvailableBiometrics();
      _log.info(_tag, 'Available biometrics: ${biometrics.map((b) => b.name).join(', ')}');
      
      if (biometrics.isEmpty) {
        _log.warn(_tag, 'No biometrics enrolled on device');
      }
      
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
      _log.debug(_tag, 'Reason: $localizedReason');
      
      // First check if available
      final isAvailable = await isBiometricAvailable();
      if (!isAvailable) {
        _log.error(_tag, 'Biometric not available on device');
        return false;
      }
      
      // Check enrolled biometrics
      final biometrics = await getAvailableBiometrics();
      if (biometrics.isEmpty) {
        _log.error(_tag, 'No biometrics enrolled - user needs to set up fingerprint in device settings');
        return false;
      }
      
      _log.debug(_tag, 'Calling authenticate with stickyAuth=true, biometricOnly=false');
      
      final authenticated = await _localAuth.authenticate(
        localizedReason: localizedReason,
        // options: const AuthenticationOptions(
        //   stickyAuth: true,
        //   biometricOnly: false,
        //   useErrorDialogs: true,
        //   sensitiveTransaction: true,
        // ),
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
      _log.debug(_tag, 'Stopping authentication...');
      await _localAuth.stopAuthentication();
      _log.info(_tag, 'Authentication stopped');
    } catch (e, stackTrace) {
      _log.error(_tag, 'Error stopping authentication', e, stackTrace);
    }
  }

  /// Check if device supports biometric authentication and has enrolled biometrics
  Future<bool> isDeviceSupported() async {
    try {
      _log.debug(_tag, 'Checking full device support...');
      
      final isAvailable = await isBiometricAvailable();
      if (!isAvailable) {
        _log.warn(_tag, 'Device does not support biometrics or cannot check');
        return false;
      }

      final availableBiometrics = await getAvailableBiometrics();
      final hasEnrolled = availableBiometrics.isNotEmpty;
      
      _log.info(_tag, 'Device supported: $hasEnrolled (has ${availableBiometrics.length} enrolled)');
      return hasEnrolled;
    } catch (e, stackTrace) {
      _log.error(_tag, 'Error checking device support', e, stackTrace);
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
}
