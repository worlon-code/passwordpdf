import 'package:flutter/material.dart';
import '../../../main.dart';

/// Simple wrapper to navigate to Dashboard with a specific folder open
class FolderNavigationScreen extends StatelessWidget {
  final String? folderId;

  const FolderNavigationScreen({super.key, this.folderId});

  @override
  Widget build(BuildContext context) {
    // Navigate to MainScreen and immediately push to the folder
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Find dashboard and set folder
      // For simplicity, we pass folder ID via a static variable
      DashboardFolderNavigation.pendingFolderId = folderId;
    });
    
    return const MainScreen();
  }
}

/// Static class to hold pending folder navigation
class DashboardFolderNavigation {
  static String? pendingFolderId;
  
  static void clear() {
    pendingFolderId = null;
  }
}
