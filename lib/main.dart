import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'services/cleanup_service.dart';
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
import 'package:path_provider/path_provider.dart';
import 'services/document_service.dart';
import 'features/documents/screens/pdf_viewer_screen.dart';
import 'features/documents/screens/folder_navigation_screen.dart';
import 'features/documents/screens/all_documents_screen.dart';
import 'package:passwordpdf_manager/features/documents/screens/file_system_browser.dart';
import 'models/document_item_model.dart';
import 'features/authentication/widgets/animated_splash_logo.dart';
import 'features/update/services/update_service.dart';
import 'features/update/widgets/whats_new_dialog.dart';
import 'features/update/widgets/update_dialogs.dart';
import 'features/update/models/update_info.dart';
import 'features/password_manager/widgets/encryption_key_setup_dialog.dart'; // Added
import 'package:package_info_plus/package_info_plus.dart';

/// Static class to hold pending file to open (for Open With flow)
class PendingFileOpen {
  static String? filePath;
  static String? fileName;
  static List<DuplicateInfo>? duplicateOptions;
  static bool isTemporary = false;
  
  static void clear() {
    filePath = null;
    fileName = null;
    duplicateOptions = null;
    showDuplicatesSheet = false;
    isTemporary = false;
  }
  
  static void clearOpen() {
    filePath = null;
    fileName = null;
    isTemporary = false;
  }
  
  static void clearDuplicates() {
    duplicateOptions = null;
    showDuplicatesSheet = false;
  }
  
  static bool showDuplicatesSheet = false;
  
  static bool get hasPending => filePath != null;
}



final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    final log = LoggingService();
    log.info('App', '=== PDF Password Manager Starting ===');
    
    // Global Flutter Error Handler (Layout errors, etc)
    FlutterError.onError = (FlutterErrorDetails details) {
      final errorMessage = '''
Uncaught Flutter Error
Exception: ${details.exception}
Library: ${details.library}
Context: ${details.context?.toDescription() ?? 'none'}
''';
      log.error('globalexception', errorMessage, details.exception, details.stack);
      // Optional: Dump to console for dev
      FlutterError.dumpErrorToConsole(details);
    };

    // Run Cleanup in Background
    CleanupService().runCleanup().then((_) {
      log.info('App', 'Startup cleanup finished');
    }).catchError((e) {
      log.error('App', 'Startup cleanup failed', e);
    });
    
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
        
        // Set pending folder ID for Dashboard to pick up
        DashboardFolderNavigation.pendingFolderId = folderId == 'root' ? null : folderId;
        
        // Navigate to MainScreen with Documents tab
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainScreen(initialIndex: 1)), // Switch to Docs Tab
          (route) => false,
        );
      } else if (payload == 'open_duplicates') {
         // Show duplicates sheet on current screen without navigating away
         PendingFileOpen.showDuplicatesSheet = true;
         
         // Get the current context from navigatorKey and show sheet directly
         final ctx = navigatorKey.currentContext;
         if (ctx != null && PendingFileOpen.duplicateOptions != null && PendingFileOpen.duplicateOptions!.length > 1) {
           final duplicates = PendingFileOpen.duplicateOptions!;
           final fileName = PendingFileOpen.fileName ?? 
               (duplicates.isNotEmpty ? duplicates.first.existingName : 'File');
           
           showModalBottomSheet(
             context: ctx,
             isScrollControlled: true,
             shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
             builder: (context) => Container(
               padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
               height: MediaQuery.of(context).size.height * 0.5,
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   Text('File "$fileName" exists in multiple locations', 
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                   const SizedBox(height: 8),
                   Text('Select location to open:', 
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600])),
                   const SizedBox(height: 16),
                   Expanded(
                     child: ListView.separated(
                       itemCount: duplicates.length,
                       separatorBuilder: (_,__) => const Divider(),
                       itemBuilder: (context, index) {
                          final dup = duplicates[index];
                          return ListTile(
                            leading: const Icon(Icons.folder_open, color: Colors.blue),
                            title: Text(dup.locationDisplay, style: const TextStyle(fontWeight: FontWeight.w500)),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                               Navigator.pop(context);
                               PendingFileOpen.clearDuplicates();
                               
                               // Set pending folder for Dashboard to navigate to
                               DashboardFolderNavigation.pendingFolderId = dup.existingFolderId;
                               
                               // Navigate to MainScreen with Documents tab (index 1)
                               navigatorKey.currentState?.pushAndRemoveUntil(
                                 MaterialPageRoute(
                                   builder: (_) => const MainScreen(initialIndex: 1), // Check documents tab
                                 ),
                                 (route) => false,
                               );
                            },
                          );
                       },
                     ),
                   ),
                 ],
               ),
             ),
           );
         }
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
          ChangeNotifierProvider.value(value: exportService), // Added for Notifications
          Provider<EncryptionService>.value(value: EncryptionService()),
          Provider<DocumentService>.value(value: DocumentService()),
          Provider<UpdateService>(create: (_) => UpdateService()), // Add UpdateService
        ],
        child: const MyApp(),
      ),
    );
  }, (error, stack) {
    // Global Async Error Handler
    final log = LoggingService();
    final errorMessage = '''
Uncaught Async Error
Error Type: ${error.runtimeType}
Error: $error
''';
    log.error('globalexception', errorMessage, error, stack);
  });
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

  // Timestamp until which a single backgrounding is exempt from auto-lock
  // (e.g. the OS file/directory picker briefly pauses the app). Expires fast
  // so it can never permanently suppress the lock screen.
  static DateTime? pauseExemptUntil;

  // Duration of the picker exemption window.
  static const Duration pauseExemptionWindow = Duration(seconds: 30);

  /// Mark the next backgrounding (within [pauseExemptionWindow]) as exempt
  /// from auto-lock timeout tracking. Call immediately before launching a
  /// system picker / share sheet.
  static void exemptNextPause() {
    pauseExemptUntil = DateTime.now().add(pauseExemptionWindow);
  }

  // Track when the app went into background (Static to allow forcing timeout from other screens)
  static DateTime? backgroundTime;

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> with WidgetsBindingObserver {
  final LoggingService _log = LoggingService();
  final PermissionService _permissionService = PermissionService();
  
  // GlobalKey to preserve MainScreen state across lock/unlock
  final GlobalKey _mainScreenKey = GlobalKey();

  bool _isAuthenticated = false;
  bool _isLoading = true;
  bool _isProcessingIntent = false;
  // Deduplication tracking: last intent path successfully consumed
  String? _lastConsumedIntentPath;
  int _selectedIndex = 0; // Added for default screen index

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Determine screen based on settings
    final settings = Provider.of<SettingsService>(context, listen: false);
    _selectedIndex = settings.defaultScreenIndex;
    
    // Check for startup intents (Cold Start)
    _checkInitialIntents();
    
    // Perform other startup checks
    // Initialize app (Settings, Auth, Permissions)
    _initialize();
    
    // Listen for intents while running
    ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      _log.info('AppEntry', 'getMediaStream fired with ${value.length} files');
      if (value.isNotEmpty) {
        _handleSharedFiles(value);
      }
    }, onError: (err) {
      _log.error('AppEntry', 'Intent stream error', err);
    });
  }

  Future<void> _checkInitialIntents() async {
    try {
      final sharedFiles = await ReceiveSharingIntent.instance.getInitialMedia();
      if (sharedFiles.isNotEmpty) {
        final file = sharedFiles.first;
        if (file.path != null) {
           PendingFileOpen.filePath = file.path;
           _lastConsumedIntentPath = file.path;
           // Fix for "Zombie Intent": Clear it so it doesn't reappear on resume
           ReceiveSharingIntent.instance.reset();
        }
      }
    } catch (e) {
      LoggingService().error('App', 'Error checking initial intents', e);
    } finally {
      _log.info('AppEntry', 'Initial intent check complete - last consumed: $_lastConsumedIntentPath');
    }
  }

  Future<void> _performStartupChecks() async {
     // NOTE: We do not delay encryption setup here because we want to allow the UI to load first.
     // However, we can perform non-blocking checks or just rely on MainScreen's checks.
     // The original design had checks here, but we moved them to MainScreen for better context access.
     // But since we call it in initState, we'll keep a minimal version or empty if MainScreen handles it.
     // Actually, looking at previous steps, we moved logic to MainScreen. 
     // So we can make this empty or just remove the call in initState if it's redundant.
     // But to fix the build error without extensive refactoring, we define it.
     
     // Wait for layout
     await Future.delayed(Duration.zero);
  }



  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    if (_isProcessingIntent) {
      _log.info('AppEntry', 'Already processing intent, skipping');
      return;
    }
    
    _isProcessingIntent = true;
    // Consume the native launch intent immediately so it cannot be re-read by
    // getInitialMedia() on a later resume (root cause of "Open With" reopening
    // the previous document).
    if (files.isNotEmpty && files.first.path != null) {
      _lastConsumedIntentPath = files.first.path;
    }
    ReceiveSharingIntent.instance.reset();
    _log.info('AppEntry', 'Received ${files.length} shared files');
    
    // Get exportService as singleton (context.read fails when app resumes from background)
    final exportService = ExportQueueService();
    
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
    
    try {
    final docService = DocumentService();
    await docService.initialize(); // Ensure _items is loaded for duplicate check
    _log.info('AppEntry', 'DocumentService initialized, starting file loop');
    
    int importedCount = 0;
    int skippedCount = 0;
    String? fileToOpenPath;
    String? fileToOpenName;
    String? fileToOpenMimeType;
    String? duplicateFolderName;
    String? duplicateFolderId;
    
    for (final media in files) {
       try {
         final path = media.path;
         final mimeType = media.mimeType; // Get MIME type from shared intent
         final file = File(path);
         _log.info('AppEntry', 'Processing file: $path (mimeType: $mimeType)');
         
         if (!await file.exists()) {
           _log.info('AppEntry', 'File does not exist: $path');
           continue;
         }
         
         // Get filename and ensure it has .pdf extension for PDF MIME types
         var filename = path.split('/').last;
         final isPdfByMime = mimeType?.toLowerCase().contains('pdf') ?? false;
         if (isPdfByMime && !filename.toLowerCase().endsWith('.pdf')) {
            filename = '$filename.pdf';
            _log.info('AppEntry', 'Added .pdf extension: $filename');
         }
         
         // Check for duplicates (Path or Size match)
         // preventing "Open With" from permanently adding files
         final duplicates = await docService.checkForDuplicates([path]);
         
         if (duplicates.isNotEmpty) {
             final existingItem = duplicates.first;
             _log.info('AppEntry', 'File already exists in library (ID: ${existingItem.existingFilePath})'); // duplicate info stores path not ID directly
             
             // Trigger Duplicate Notification Flow
             skippedCount++; 
             
             // Find parent folder details
             duplicateFolderName = existingItem.existingFolderName;
             duplicateFolderId = existingItem.existingFolderId;

             // Populate duplicates for sheet
             PendingFileOpen.duplicateOptions = duplicates;

             // Treat as "Imported" but use existing item info
             importedCount++;
             fileToOpenPath = existingItem.existingFilePath;
             // duplicate info stores existing name
             fileToOpenName = existingItem.existingName;
             continue; 
         }
         
         // Not in library? Open temporary (DO NOT IMPORT)
         _log.info('AppEntry', 'File not in library - Opening as TEMPORARY (No Import): $filename');
         
         // Fix for Gmail/Content URIs: Verify file accessibility
         // Sometimes shared files are in restricted cache dirs. Copy to our temp dir to be safe.
         String finalPath = path;
         if (path.startsWith('content://') || !await file.exists()) {
             _log.info('AppEntry', 'File is content URI or inaccessible, attempting resolution: $path');
             try {
                // For content:// URIs, receive_sharing_intent should have cached the file
                // But if it didn't, we'll try to copy it ourselves
                final tempDir = await getTemporaryDirectory();
                final safePath = '${tempDir.path}/$filename';
                final safeFile = File(safePath);
                
                // If original file exists despite content:// prefix (cached by intent handler), copy it
                if (await file.exists()) {
                   await file.copy(safePath);
                   finalPath = safePath;
                   _log.info('AppEntry', 'Copied to local temp: $safePath');
                } else {
                   _log.error('AppEntry', 'File does not exist and cannot be copied: $path');
                   // Skip this file - can't open what doesn't exist
                   continue;
                }
             } catch(e) {
                _log.error('AppEntry', 'Temp copy failed', e);
                continue;
             }
         }
         
         fileToOpenPath = finalPath;
         fileToOpenName = filename;
         fileToOpenMimeType = mimeType;
         PendingFileOpen.isTemporary = true; 
         importedCount++; 
         continue;

       } catch (e) {
         _log.error('AppEntry', 'Failed to process shared file', e);
       }
    }
    
    // Dismiss loading dialog
    if (mounted && Navigator.of(context).canPop()) {
       Navigator.of(context).pop();
    }
    
    // Always set pending file for later opening (even if not authenticated yet)
    // Dashboard will check PendingFileOpen after authentication completes
    if (fileToOpenPath != null) {
      // Check both extension AND MIME type for PDF detection (Gmail may lack extension)
      final isPdf = fileToOpenPath.toLowerCase().endsWith('.pdf') || 
                    (fileToOpenMimeType?.toLowerCase().contains('pdf') ?? false);
      
      if (isPdf) {
         // Set pending file for MainScreen/Dashboard to open with password handling
         PendingFileOpen.filePath = fileToOpenPath;
         PendingFileOpen.fileName = fileToOpenName ?? 'Document';
         
         _log.info('AppEntry', 'PendingFileOpen set: ${PendingFileOpen.fileName}');
         
         // Only navigate if already authenticated (hot path)
         // Cold start with auth: User will see lock screen first, Dashboard opens pending file after auth
         if (_isAuthenticated) {
            _log.info('AppEntry', 'Already authenticated - navigating to MainScreen now');
            navigatorKey.currentState?.pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const MainScreen(initialIndex: 1)),
              (route) => false,
            );
         } else {
            _log.info('AppEntry', 'Not yet authenticated - file will open after auth via Dashboard');
         }
      }
    } else {
       _log.info('AppEntry', 'No file to open: Path=$fileToOpenPath');
    }

    _log.info('AppEntry', 'Post-loop: importedCount=$importedCount, skippedCount=$skippedCount');
    
    // Show Android notification for duplicates (fire and forget)
    if (skippedCount > 0) {
        _log.info('AppEntry', 'Duplicate detected - skippedCount=$skippedCount, showing notification');
        
        // Show snackbar for duplicate detection (wrapped in try-catch)
        try {
          if (mounted) {
             ScaffoldMessenger.of(context).showSnackBar(
               SnackBar(
                 content: Text('Opening from existing location: ${duplicateFolderName ?? 'Unorganized Files'}'),
                 duration: const Duration(seconds: 3),
               ),
             );
          }
        } catch (e) {
          _log.error('AppEntry', 'Failed to show snackbar', e);
        }
        
        final location = duplicateFolderName ?? 'Unorganized Files';
        // Create payload with folder ID for navigation
        final payload = 'open_folder:${duplicateFolderId ?? 'root'}';
        
        // Show Android notification (don't await - let PDF stay open)
        // If we are opening a single file immediately, SnackBar is sufficient.
        // Only show system notification if we have multiple files or we aren't auto-opening.
        bool shouldShowNotification = true;
        if (files.length == 1 && fileToOpenPath != null) {
             shouldShowNotification = false;
        }

        if (shouldShowNotification) {
            if (PendingFileOpen.duplicateOptions != null && PendingFileOpen.duplicateOptions!.length > 1) {
                 _log.info('AppEntry', 'Showing multi-location notification');
                 exportService.showImportNotification(
                    'File Already Exists',
                    'Found in ${PendingFileOpen.duplicateOptions!.length} locations. Tap to select.',
                    payload: 'open_duplicates',
                 );
            } else {
                 _log.info('AppEntry', 'Showing single-location notification');
                 exportService.showImportNotification(
                    'File Already Exists',
                    'Found in: $location. Tap to view folder.',
                    payload: payload,
                 );
            }
        }
    }
    } finally {
      // ALWAYS reset flag to allow future intents
      _isProcessingIntent = false;
      _log.info('AppEntry', 'Intent processing complete (finally block)');
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
    
    // Initialize Update Service (Load Red Dot state)
    final updateService = Provider.of<UpdateService>(context, listen: false);
    await updateService.initialize();

    // Auto-Check for Updates (if enabled)
    if (settings.autoCheckUpdates) {
       // Run in background, don't await blocking UI
       updateService.checkForUpdate().then((info) {
          if (info != null && mounted) {
             showUpdateDialog(context, info);
          }
       });
    }
    
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final exemptUntil = AppEntry.pauseExemptUntil;
      if (exemptUntil != null && DateTime.now().isBefore(exemptUntil)) {
         _log.info('AppEntry', 'App paused but within picker exemption window - Skipping timeout tracking');
         AppEntry.pauseExemptUntil = null; // One-shot: consume the exemption
         return;
      }
      AppEntry.pauseExemptUntil = null; // Expired/unused exemption never lingers

      AppEntry.backgroundTime = DateTime.now();
      _log.info('AppEntry', 'App paused - tracking background time: ${AppEntry.backgroundTime}');
    }

    if (state == AppLifecycleState.resumed) {
       _log.info('AppEntry', 'App resumed');
       
       if (AppEntry.backgroundTime != null) {
         final diff = DateTime.now().difference(AppEntry.backgroundTime!);
         _log.info('AppEntry', 'Background duration: ${diff.inSeconds} seconds');
         
         // Auto-lock only after user-configured timeout (default 10m).
         // Compare in seconds against timeout*60 so sub-minute timeouts work
         // and integer-minute truncation can never skip the lock.
         final settings = Provider.of<SettingsService>(context, listen: false);
         final timeoutMinutes = settings.autoLockTimeout;
         
         if (diff.inSeconds >= timeoutMinutes * 60) {
            // Only lock if security is enabled AND we are currently authenticated
            if ((settings.biometricEnabled || settings.pinEnabled) && _isAuthenticated) {
               _log.info('AppEntry', 'Timeout (>$timeoutMinutes m) - Pushing Lock Screen Route');
               
               Navigator.of(context).push(
                 PageRouteBuilder(
                   opaque: false, 
                   pageBuilder: (_, __, ___) => PopScope(
                     canPop: false, 
                     child: BiometricLockScreen(
                       isOverlay: true, 
                       onAuthenticated: () {
                         _log.info('AppEntry', 'Re-authentication successful - Popping lock screen');
                         Navigator.of(context).pop(); 
                       },
                     ),
                   ),
                   transitionsBuilder: (_, animation, __, child) {
                     return FadeTransition(opacity: animation, child: child);
                   },
                 ),
               );
            }
          } else {
             _log.info('AppEntry', 'Timeout not reached (<$timeoutMinutes m) - access granted');
          }
         
         AppEntry.backgroundTime = null; // Reset
       }

       if (!_isProcessingIntent) {
         _log.info('AppEntry', 'Checking for pending intents');
         _checkForPendingIntent();
       }
    }
  }
  
  Future<void> _checkForPendingIntent() async {
    try {
      final media = await ReceiveSharingIntent.instance.getInitialMedia();
      if (media.isEmpty) return;
      if (media.first.path == _lastConsumedIntentPath) {
        ReceiveSharingIntent.instance.reset();
        return;
      }
      _handleSharedFiles(media);
      ReceiveSharingIntent.instance.reset();
    } catch (e) {
      _log.error('AppEntry', 'Error checking pending intent', e);
    }
  }

  void _onAuthenticated() {
    _log.info('AppEntry', 'User authenticated successfully (Initial)');
    setState(() {
      _isAuthenticated = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    _log.debug('AppEntry', 'build() called - isLoading=$_isLoading, isAuthenticated=$_isAuthenticated');
    
    if (_isLoading) {
      final colorScheme = Theme.of(context).colorScheme;
      return Scaffold(
        body: Container(
           decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.primary,
                colorScheme.secondary,
                colorScheme.tertiary,
              ],
            ),
          ),
          child: Center(
            child: AnimatedSplashLogo(
              animateText: true, 
              onAnimationComplete: () {
                // Optional delay
              },
            ),
          ),
        ),
      );
    }

    // Initial Authentication Block
    if (!_isAuthenticated) {
      _log.info('AppEntry', 'Showing Initial BiometricLockScreen');
      return BiometricLockScreen(
        onAuthenticated: _onAuthenticated,
      );
    }

    // Main App Content
    // Once we are authenticated, this widget stays in the tree.
    // Subsequent locks are handled by Pushing routes on top of this.
    return const MainScreen();
  }
}

/// Main screen with bottom navigation
class MainScreen extends StatefulWidget {
  final int initialIndex;
  const MainScreen({super.key, this.initialIndex = 0});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late int _currentIndex;
  final GlobalKey<AllDocumentsScreenState> _allDocsKey = GlobalKey();
  final GlobalKey<DocumentDashboardScreenState> _dashboardKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    
    // Use widget.initialIndex if explicitly set, otherwise use settings default
    if (widget.initialIndex != 0) {
      _currentIndex = widget.initialIndex;
    } else {
      // Get default screen from settings
      final settings = SettingsService();
      _currentIndex = settings.defaultScreenIndex;
    }
    
    // Check if we have a pending folder navigation
    // This ensures we switch to the correct tab even if MainScreen is rebuilt
    if (DashboardFolderNavigation.pendingFolderId != null) {
      _currentIndex = 1; // Documents Tab
    }
    
    // Check for pending duplicate resolution
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (PendingFileOpen.showDuplicatesSheet && PendingFileOpen.duplicateOptions != null && PendingFileOpen.duplicateOptions!.length > 1) {
         _showDuplicateSelectionSheet();
         PendingFileOpen.clearDuplicates(); // Only clear duplicates, leave file open if any
      }
    });




    // Run Startup Checks (Encryption -> What's New -> Updates)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _performStartupChecks();
    });
  }

  Future<void> _performStartupChecks() async {
    final encryptionService = EncryptionService();
    // 1. Enforce Encryption Setup FIRST
    final hasKey = await encryptionService.isKeySet();
    if (!hasKey) {
       if (!mounted) return;
       // Force setup (barrierDismissible: false is handled in the dialog widget)
       final success = await showEncryptionKeySetupDialog(context, force: true);
       if (!success) {
         // Should not happen if forced, but if it does, maybe prompt again or exit?
         // For now, if they somehow bypassed it, we just return (blocking other features effectively)
         return; 
       }
    }

    final updateService = UpdateService();
    // 2. Cleanup old APKs
    await updateService.cleanupUpdateFile();
    
    // 3. Check for "What's New" (Current > LastViewed)
    // We prioritize showing what changed in the *current* version before telling them to update again.
    if (!mounted) return;
    
    final settings = Provider.of<SettingsService>(context, listen: false);
    final packageInfo = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
    
    bool showedWhatsNew = false;

    if (currentBuild > settings.lastViewedBuildNumber) {
      UpdateInfo? info = await updateService.getLatestReleaseInfo();
      // Only show if we can fetch notes.
      if (info != null && info.buildNumber >= currentBuild) {
        if (!mounted) return;
        showedWhatsNew = true;
        await showDialog(
          context: context,
          barrierDismissible: false, // Make them read it
          builder: (context) => WhatsNewDialog(
            updateInfo: info,
            onDismiss: () => Navigator.pop(context),
          ),
        );
      }
      // Update check seen
      await settings.setLastViewedBuildNumber(currentBuild);
    }

    if (!mounted) return;

    // 4. Check for Pending Updates (Remote > Current)
    // Only check if we didn't just show "What's New" (avoid double dialog fatigue), 
    // OR if we really want to be aggressive. User requested "next will be update one".
    // So we proceed.
    
    final updateInfo = await updateService.checkForUpdate();
    if (updateInfo != null) {
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: !updateInfo.forceUpdate,
        builder: (ctx) => UpdateAvailableDialog(
           updateInfo: updateInfo,
           onUpdate: () => performUpdate(ctx, updateInfo),
        )
      );
    }
  }

  void _showDuplicateSelectionSheet() {
    final duplicates = PendingFileOpen.duplicateOptions!;
    // Get filename from first duplicate if PendingFileOpen.fileName is null
    final fileName = PendingFileOpen.fileName ?? 
        (duplicates.isNotEmpty ? duplicates.first.existingName : 'File');
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        height: MediaQuery.of(context).size.height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('File "$fileName" exists in multiple locations', 
               style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Select location to open:', 
               style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.separated(
                itemCount: duplicates.length,
                separatorBuilder: (_,__) => const Divider(),
                itemBuilder: (context, index) {
                   final dup = duplicates[index];
                   return ListTile(
                     leading: const Icon(Icons.folder_open, color: Colors.blue),
                     title: Text(dup.locationDisplay, style: const TextStyle(fontWeight: FontWeight.w500)),
                     trailing: const Icon(Icons.chevron_right),
                     onTap: () {
                        Navigator.pop(context);
                        PendingFileOpen.duplicateOptions = null; // Clear
                        
                        // Set pending folder ID
                        DashboardFolderNavigation.pendingFolderId = dup.existingFolderId == 'root' ? null : dup.existingFolderId;
                        
                        // Reset to MainScreen with Documents tab
                        navigatorKey.currentState?.pushAndRemoveUntil(
                          MaterialPageRoute(
                            builder: (_) => const MainScreen(initialIndex: 1),
                          ),
                          (route) => false,
                        );
                     },
                   );
                },
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
       // Clear if dismissed without selection?
       // PendingFileOpen.duplicateOptions = null; 
    });
  }
  

  /// Back handler for All Documents screen
  Future<bool> _handleAllDocsBack() async {
    final state = _allDocsKey.currentState;
    if (state == null) return false;
    
    if (state.isSelectionMode) {
      state.clearSelection();
      return true;
    }
    
    if (state.isFolderView && state.currentFolderPath != '/storage/emulated/0') {
      state.navigateUp();
      return true;
    }
    
    return false;
  }
  
  /// Back handler for Document Dashboard screen  
  Future<bool> _handleDashboardBack() async {
    final state = _dashboardKey.currentState;
    if (state == null) return false;
    
    if (state.selectedFileIds.isNotEmpty) {
      state.clearSelection();
      return true;
    }
    
    if (state.currentFolderId != null) {
      state.navigateUp();
      return true;
    }
    
    return false;
  }
  
  /// Back handler for Settings screen
  Future<bool> _handleSettingsBack() async {
    return false;
  }
  
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        
        // Delegate to active screen's back handler
        bool handled = false;
        switch (_currentIndex) {
          case 0:
            handled = await _handleAllDocsBack();
            break;
          case 1:
            handled = await _handleDashboardBack();
            break;
          case 2:
            handled = await _handleSettingsBack();
            break;
        }
        
        // If not handled by screen, show Exit dialog
        if (!handled) {
          final shouldExit = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Exit App'),
              content: const Text('Do you want to close the application?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Leave'),
                ),
              ],
            ),
          );
          
          if (shouldExit == true) {
            AppEntry.backgroundTime = DateTime(2000);
            AppEntry.exemptNextPause();
            SystemNavigator.pop();
          }
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            AllDocumentsScreen(key: _allDocsKey),
            DocumentDashboardScreen(key: _dashboardKey),
            const SettingsScreen(),
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
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),  // Close Scaffold
    );  // Close PopScope
  }
}
