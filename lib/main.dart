import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'features/settings/services/settings_service.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/documents/screens/document_dashboard_screen.dart';
import 'features/password_manager/screens/password_manager_screen.dart';
import 'features/authentication/screens/biometric_lock_screen.dart';
import 'services/logging_service.dart';
import 'services/permission_service.dart';
import 'services/encryption_service.dart';

import 'features/documents/screens/export_progress_screen.dart';
import 'services/export_queue_service.dart';

// App version for tracking
const String appVersion = '0.0.24';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final log = LoggingService();
  log.info('App', '=== PDF Password Manager v$appVersion Starting ===');
  
  // Initialize settings service
  final settingsService = SettingsService();
  await settingsService.initialize();
  
  // Setup Notification Listener
  final exportService = ExportQueueService();
  // Ensure init is called so notification plugin is ready
  await exportService.init();
  
  exportService.onNotificationTap.listen((payload) {
    log.info('App', 'Notification tapped: $payload');
    navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const ExportProgressScreen()),
    );
  });
  
  log.info('App', 'Settings loaded:');
  log.info('App', '  - AuthMethod: ${settingsService.authMethod}');
  log.info('App', '  - biometricEnabled: ${settingsService.biometricEnabled}');
  log.info('App', '  - pinEnabled: ${settingsService.pinEnabled}');
  log.info('App', '  - hasPinSet: ${settingsService.hasPinSet}');
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        Provider<EncryptionService>.value(value: EncryptionService()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'PDF Password Manager',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: settings.themeMode,
          home: const AppEntry(),
        );
      },
    );
  }
}

/// Entry point that handles authentication and navigation
class AppEntry extends StatefulWidget {
  const AppEntry({super.key});

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  final LoggingService _log = LoggingService();
  final PermissionService _permissionService = PermissionService();
  bool _isAuthenticated = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    _log.info('AppEntry', '=== Checking authentication requirement ===');
    _log.info('AppEntry', 'authMethod: ${settings.authMethod}');
    _log.info('AppEntry', 'biometricEnabled: ${settings.biometricEnabled}');
    _log.info('AppEntry', 'pinEnabled: ${settings.pinEnabled}');
    _log.info('AppEntry', 'hasPinSet: ${settings.hasPinSet}');
    
    // Request permissions
    await _permissionService.requestAllPermissions();
    
    // Determine if authentication is needed
    // Auth is needed if: biometric enabled OR pin enabled
    final needsAuth = settings.biometricEnabled || settings.pinEnabled;
    
    _log.info('AppEntry', 'needsAuth calculated: $needsAuth');
    
    if (!needsAuth) {
      _log.info('AppEntry', 'No authentication required - skipping lock screen');
      setState(() {
        _isAuthenticated = true;
        _isLoading = false;
      });
    } else {
      _log.info('AppEntry', 'Authentication IS required - showing lock screen');
      setState(() {
        _isLoading = false;
        _isAuthenticated = false;  // Ensure we show lock screen
      });
    }
  }


  @override
  void dispose() {
    super.dispose();
  }

  void _onAuthenticated() {
    _log.info('AppEntry', 'User authenticated successfully');
    setState(() {
      _isAuthenticated = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    _log.debug('AppEntry', 'build() called - isLoading=$_isLoading, isAuthenticated=$_isAuthenticated');
    
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading v$appVersion...'),
            ],
          ),
        ),
      );
    }

    if (!_isAuthenticated) {
      _log.info('AppEntry', 'Showing BiometricLockScreen');
      return BiometricLockScreen(
        onAuthenticated: _onAuthenticated,
      );
    }

    _log.info('AppEntry', 'Showing MainScreen with Dashboard');
    return const MainScreen();
  }
}

/// Main screen with bottom navigation
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          DocumentDashboardScreen(),
          PasswordManagerScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Documents',
          ),
          NavigationDestination(
            icon: Icon(Icons.vpn_key_outlined),
            selectedIcon: Icon(Icons.vpn_key),
            label: 'Passwords',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
