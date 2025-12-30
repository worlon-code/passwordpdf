import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/biometric_service.dart';
import '../../../services/logging_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../settings/services/settings_service.dart';

/// Lock screen that handles both fingerprint and PIN authentication
class BiometricLockScreen extends StatefulWidget {
  final VoidCallback onAuthenticated;

  const BiometricLockScreen({
    super.key,
    required this.onAuthenticated,
  });

  @override
  State<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends State<BiometricLockScreen> {
  final BiometricService _biometricService = BiometricService();
  final LoggingService _log = LoggingService();
  bool _isAuthenticating = false;
  String _message = '';
  bool _showPinEntry = false;
  String _enteredPin = '';
  bool _pinError = false;
  int _pinAttempts = 0;

  @override
  void initState() {
    super.initState();
    _log.info('LockScreen', 'Lock screen initialized');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startAuthentication();
    });
  }

  void _startAuthentication() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    _log.info('LockScreen', 'Starting auth. Method: ${settings.authMethod}, bioEnabled: ${settings.biometricEnabled}, pinEnabled: ${settings.pinEnabled}');
    
    // Priority: Fingerprint > PIN
    if (settings.biometricEnabled) {
      // Fingerprint is enabled, try it first
      _log.info('LockScreen', 'Fingerprint enabled - starting fingerprint auth');
      _authenticateWithFingerprint();
    } else if (settings.pinEnabled) {
      // Only PIN is enabled, show PIN entry directly
      _log.info('LockScreen', 'Only PIN enabled - showing PIN entry');
      setState(() {
        _showPinEntry = true;
        _message = 'Enter your PIN';
      });
    } else {
      // No auth enabled (shouldn't happen since we check before showing this screen)
      _log.warn('LockScreen', 'No auth method enabled - this should not happen');
      widget.onAuthenticated();
    }
  }

  Future<void> _authenticateWithFingerprint() async {
    if (_isAuthenticating) return;

    setState(() {
      _isAuthenticating = true;
      _message = 'Authenticating...';
      _showPinEntry = false;
    });

    _log.info('LockScreen', 'Starting fingerprint authentication...');

    try {
      final authenticated = await _biometricService.authenticate(
        localizedReason: 'Authenticate to access PDF Password Manager',
      );

      if (authenticated) {
        _log.info('LockScreen', 'Fingerprint authentication successful');
        widget.onAuthenticated();
      } else {
        _log.warn('LockScreen', 'Fingerprint failed');
        final settings = Provider.of<SettingsService>(context, listen: false);
        
        setState(() {
          _isAuthenticating = false;
          if (settings.hasPinSet) {
            _showPinEntry = true;
            _message = 'Fingerprint failed. Enter PIN instead';
          } else {
            _message = 'Authentication failed. Tap to try again';
          }
        });
      }
    } catch (e, stack) {
      _log.error('LockScreen', 'Fingerprint error', e, stack);
      final settings = Provider.of<SettingsService>(context, listen: false);
      
      setState(() {
        _isAuthenticating = false;
        if (settings.hasPinSet) {
          _showPinEntry = true;
          _message = 'Error. Use PIN instead';
        } else {
          _message = 'Error: ${e.toString()}';
        }
      });
    }
  }

  void _onPinKeyPressed(String key) {
    if (_enteredPin.length < 4) {
      setState(() {
        _enteredPin += key;
        _pinError = false;
      });

      if (_enteredPin.length == 4) {
        _verifyPin();
      }
    }
  }

  void _onPinBackspace() {
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
        _pinError = false;
      });
    }
  }

  Future<void> _verifyPin() async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    _log.info('LockScreen', 'Verifying PIN...');
    final verified = await settings.verifyPin(_enteredPin);
    
    if (verified) {
      _log.info('LockScreen', 'PIN verified successfully');
      widget.onAuthenticated();
    } else {
      _pinAttempts++;
      _log.warn('LockScreen', 'Wrong PIN. Attempts: $_pinAttempts');
      
      setState(() {
        _pinError = true;
        _enteredPin = '';
        _message = _pinAttempts >= 5 
            ? 'Too many attempts. Try again later'
            : 'Wrong PIN. ${5 - _pinAttempts} attempts left';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppTheme.primaryLight,
              AppTheme.secondaryLight,
              AppTheme.accentLight,
            ],
          ),
        ),
        child: SafeArea(
          child: _showPinEntry ? _buildPinEntry() : _buildFingerprintAuth(),
        ),
      ),
    );
  }

  Widget _buildFingerprintAuth() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // App Logo
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_outline, size: 80, color: Colors.white),
          ),
          
          const SizedBox(height: 40),
          
          const Text(
            'PDF Password Manager',
            style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
          ),
          
          const SizedBox(height: 60),
          
          // Fingerprint button
          GestureDetector(
            onTap: _isAuthenticating ? null : _authenticateWithFingerprint,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.5), width: 2),
              ),
              child: _isAuthenticating
                  ? const CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(Colors.white))
                  : const Icon(Icons.fingerprint, size: 60, color: Colors.white),
            ),
          ),
          
          const SizedBox(height: 24),
          
          Text(
            _message.isEmpty ? 'Tap to authenticate' : _message,
            style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 16),
            textAlign: TextAlign.center,
          ),
          
          const SizedBox(height: 32),
          
          // PIN option button
          if (settings.hasPinSet)
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _showPinEntry = true;
                _message = 'Enter your PIN';
              }),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              icon: const Icon(Icons.pin),
              label: const Text('Use PIN'),
            ),
        ],
      ),
    );
  }

  Widget _buildPinEntry() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    return Column(
      children: [
        const SizedBox(height: 60),
        
        // Lock icon
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.lock, size: 48, color: Colors.white),
        ),
        
        const SizedBox(height: 24),
        
        const Text(
          'Enter PIN',
          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
        ),
        
        const SizedBox(height: 8),
        
        Text(
          _message,
          style: TextStyle(
            color: _pinError ? Colors.red.shade200 : Colors.white.withOpacity(0.8),
            fontSize: 14,
          ),
        ),
        
        const SizedBox(height: 32),
        
        // PIN dots
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(4, (index) {
            final filled = index < _enteredPin.length;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? Colors.white : Colors.transparent,
                border: Border.all(
                  color: _pinError ? Colors.red.shade200 : Colors.white,
                  width: 2,
                ),
              ),
            );
          }),
        ),
        
        const Spacer(),
        
        // Numpad
        _buildNumpad(),
        
        const SizedBox(height: 16),
        
        // Fingerprint option (only if fingerprint is enabled)
        if (settings.biometricEnabled)
          TextButton.icon(
            onPressed: () => setState(() {
              _showPinEntry = false;
              _enteredPin = '';
              _authenticateWithFingerprint();
            }),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.fingerprint),
            label: const Text('Use Fingerprint'),
          ),
        
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildNumpad() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        children: [
          for (final row in [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['', '0', 'back']])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: row.map((key) {
                  if (key.isEmpty) return const SizedBox(width: 72, height: 72);
                  
                  if (key == 'back') {
                    return _buildKeyButton(
                      child: const Icon(Icons.backspace_outlined, color: Colors.white),
                      onPressed: _onPinBackspace,
                    );
                  }
                  
                  return _buildKeyButton(
                    child: Text(key, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                    onPressed: () => _onPinKeyPressed(key),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildKeyButton({required Widget child, required VoidCallback onPressed}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(36),
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}
