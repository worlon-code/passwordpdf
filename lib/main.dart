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
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'dart:io';
import 'services/document_service.dart';
import 'features/documents/screens/pdf_viewer_screen.dart';
import 'features/documents/screens/folder_navigation_screen.dart';
import 'features/documents/screens/all_documents_screen.dart';

/// Static class to hold pending file to open (for Open With flow)
class PendingFileOpen {
  static String? filePath;
  static String? fileName;
  
  static void clear() {
    filePath = null;
    fileName = null;
  }
  
  static bool get hasPending => filePath != null;
}

// App version for tracking
const String appVersion = '0.0.26';

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
    
    if (payload.startsWith('open_folder:')) {
      // Navigate to specific folder in Dashboard
      final folderId = payload.replaceFirst('open_folder:', '');
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => FolderNavigationScreen(folderId: folderId == 'root' ? null : folderId)),
        (route) => false,
      );
    } else {
      // Default: Export Progress
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const ExportProgressScreen()),
      );
    }
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
        // Use dynamic accent color from settings
        final seedColor = settings.accentColor;
        final fontScale = 1.0 + (settings.fontSizeAdjustment / 14.0); // -7 becomes ~0.5
        
        // Create base themes
        final lightTheme = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        );
        
        final darkTheme = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        );
        
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'PDF Password Manager',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: settings.themeMode,
          home: const AppEntry(),
          builder: (context, child) {
            // Apply font scaling via MediaQuery
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(fontScale),
              ),
              child: child!,
            );
          },
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
    
    // Listen for intents while running
    ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedFiles(value);
      }
    }, onError: (err) {
      _log.error('AppEntry', 'Intent stream error', err);
    });

    // Get initial intent (if app was closed)
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedFiles(value);
        // Clear intent so it doesn't re-trigger on reload
        ReceiveSharingIntent.instance.reset(); 
      }
    });
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    
    _log.info('AppEntry', 'Received ${files.length} shared files');
    
    // Show loading dialog
    if (mounted) {
       showDialog(
         context: context,
         barrierDismissible: false,
         builder: (_) => const PopScope(
            canPop: false,
            child: Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Importing file...'),
                    ],
                  ),
                ),
              ),
           ),
         ),
       );
    }
    
    final docService = DocumentService();
    await docService.initialize(); // Ensure _items is loaded for duplicate check
    final exportService = ExportQueueService(); // For notification
    
    int importedCount = 0;
    int skippedCount = 0;
    String? fileToOpenPath;
    String? fileToOpenName;
    String? duplicateFolderName;
    String? duplicateFolderId;
    
    for (final media in files) {
       try {
         final path = media.path;
         final file = File(path);
         if (!await file.exists()) continue;
         
         final filename = path.split('/').last;
         
         final result = await docService.importFile(path, filename);
         
         if (result.success) {
            importedCount++;
            fileToOpenPath = result.importedPath;
            fileToOpenName = filename;
         } else if (result.isDuplicate) {
            skippedCount++;
            duplicateFolderName = result.existingFolderName;
            duplicateFolderId = result.existingFolderId;
            // Use existing file path for opening
            fileToOpenPath = result.importedPath;
            fileToOpenName = filename;
         }
       } catch (e) {
         _log.error('AppEntry', 'Failed to import shared file', e);
       }
    }
    
    // Dismiss loading dialog
    if (mounted && Navigator.of(context).canPop()) {
       Navigator.of(context).pop();
    }
    
    // Always auto-open the file (whether imported or duplicate)
    // Route through Dashboard which has password handling logic
    if (fileToOpenPath != null && _isAuthenticated) {
      final isPdf = fileToOpenPath.toLowerCase().endsWith('.pdf');
      
      if (isPdf) {
         // Show "Opening file..." loader
         if (mounted) {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => const PopScope(
                 canPop: false,
                 child: Center(
                   child: Card(
                     child: Padding(
                       padding: EdgeInsets.all(24),
                       child: Column(
                         mainAxisSize: MainAxisSize.min,
                         children: [
                           CircularProgressIndicator(),
                           SizedBox(height: 16),
                           Text('Opening file...'),
                         ],
                       ),
                     ),
                   ),
                ),
              ),
            );
         }
         
         // Set pending file for Dashboard to open with password handling
         PendingFileOpen.filePath = fileToOpenPath;
         PendingFileOpen.fileName = fileToOpenName ?? 'Document';
         
         // Navigate to MainScreen (Dashboard will detect pending file and dismiss loader)
         navigatorKey.currentState?.pushAndRemoveUntil(
           MaterialPageRoute(builder: (_) => const MainScreen()),
           (route) => false,
         );
      }
    }

    // Show Android notification for duplicates (fire and forget)
    if (skippedCount > 0) {
        final location = duplicateFolderName ?? 'Unorganized Files';
        // Create payload with folder ID for navigation
        final payload = 'open_folder:${duplicateFolderId ?? 'root'}';
        
        // Show Android notification (don't await - let PDF stay open)
        exportService.showImportNotification(
          'File Already Exists',
          'Found in: $location. Tap to view folder.',
          payload: payload,
        );
    }
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
          AllDocumentsScreen(),
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
            icon: Icon(Icons.storage),
            selectedIcon: Icon(Icons.storage_outlined),
            label: 'All Docs',
          ),
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
