import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../settings/services/settings_service.dart';
import '../../../services/logging_service.dart';
import '../../../core/theme/app_theme.dart';

/// PIN entry screen for PIN authentication
class PinEntryScreen extends StatefulWidget {
  final VoidCallback onAuthenticated;
  final bool isSetupMode;

  const PinEntryScreen({
    super.key,
    required this.onAuthenticated,
    this.isSetupMode = false,
  });

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  final LoggingService _log = LoggingService();
  String _enteredPin = '';
  String _confirmPin = '';
  bool _isConfirming = false;
  String _message = 'Enter your PIN';
  bool _hasError = false;
  int _attempts = 0;
  static const int _maxAttempts = 5;

  void _onKeyPressed(String key) {
    if (_enteredPin.length < 6) {
      setState(() {
        _enteredPin += key;
        _hasError = false;
      });

      if (_enteredPin.length == 4) {
        // Auto-submit when 4 digits entered
        _submitPin();
      }
    }
  }

  void _onBackspace() {
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
        _hasError = false;
      });
    }
  }

  Future<void> _submitPin() async {
    if (_enteredPin.length < 4) return;

    final settings = Provider.of<SettingsService>(context, listen: false);

    if (widget.isSetupMode) {
      // Setup mode - require confirmation
      if (!_isConfirming) {
        _confirmPin = _enteredPin;
        setState(() {
          _enteredPin = '';
          _isConfirming = true;
          _message = 'Confirm your PIN';
        });
      } else {
        // Confirming
        if (_enteredPin == _confirmPin) {
          // PINs match - save
          _log.info('PinEntryScreen', 'Setting new PIN...');
          final success = await settings.setPin(_enteredPin);
          
          if (success) {
            _log.info('PinEntryScreen', 'PIN set successfully');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('PIN set successfully')),
              );
            }
            widget.onAuthenticated();
          } else {
            setState(() {
              _hasError = true;
              _message = 'Failed to set PIN. Try again';
              _enteredPin = '';
              _confirmPin = '';
              _isConfirming = false;
            });
          }
        } else {
          // PINs don't match
          _log.warn('PinEntryScreen', 'PINs do not match');
          setState(() {
            _hasError = true;
            _message = 'PINs do not match. Try again';
            _enteredPin = '';
            _confirmPin = '';
            _isConfirming = false;
          });
        }
      }
    } else {
      // Verify mode
      _log.info('PinEntryScreen', 'Verifying PIN...');
      final verified = await settings.verifyPin(_enteredPin);
      
      if (verified) {
        _log.info('PinEntryScreen', 'PIN verified successfully');
        widget.onAuthenticated();
      } else {
        _attempts++;
        _log.warn('PinEntryScreen', 'Wrong PIN. Attempts: $_attempts/$_maxAttempts');
        
        setState(() {
          _hasError = true;
          _enteredPin = '';
          
          if (_attempts >= _maxAttempts) {
            _message = 'Too many wrong attempts. Please wait.';
          } else {
            _message = 'Wrong PIN. ${_maxAttempts - _attempts} attempts left';
          }
        });
      }
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
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Back button for verify mode (not setup)
              if (!widget.isSetupMode)
                Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                )
              else
                const SizedBox(height: 48),
              
              const SizedBox(height: 40),
              
              // Lock icon
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.pin,
                  size: 48,
                  color: Colors.white,
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Title
              Text(
                widget.isSetupMode ? 'Set Up PIN' : 'Enter PIN',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              
              const SizedBox(height: 8),
              
              // Message
              Text(
                _message,
                style: TextStyle(
                  color: _hasError ? Colors.red.shade200 : Colors.white.withOpacity(0.8),
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
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
                      color: filled 
                          ? Colors.white 
                          : Colors.transparent,
                      border: Border.all(
                        color: _hasError ? Colors.red.shade200 : Colors.white,
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),
              
              const Spacer(),
              
              // Numpad
              _buildNumpad(),
              
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNumpad() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        children: [
          for (final row in [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['', '0', 'back'],
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: row.map((key) {
                  if (key.isEmpty) {
                    return const SizedBox(width: 72, height: 72);
                  }
                  
                  if (key == 'back') {
                    return _buildKeyButton(
                      child: const Icon(Icons.backspace_outlined, color: Colors.white),
                      onPressed: _onBackspace,
                    );
                  }
                  
                  return _buildKeyButton(
                    child: Text(
                      key,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () => _onKeyPressed(key),
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
            border: Border.all(
              color: Colors.white.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}
