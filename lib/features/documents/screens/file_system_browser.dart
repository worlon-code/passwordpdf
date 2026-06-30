import 'dart:io'; 
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:passwordpdf_manager/services/device_document_service.dart';

class FileSystemBrowser extends StatefulWidget {
  final String? initialPath;
  final List<String> allowedExtensions;
  final bool allowMultiple;
  final bool allowFolderSelection;
  final Function(List<String> paths)? onSelectionChanged;

  const FileSystemBrowser({
    Key? key,
    this.initialPath,
    this.allowedExtensions = const ['pdf', 'doc', 'docx', 'xls', 'xlsx'],
    this.allowMultiple = true,
    this.allowFolderSelection = false,
    this.onSelectionChanged,
  }) : super(key: key);

  @override
  State<FileSystemBrowser> createState() => _FileSystemBrowserState();
}

class _FileSystemBrowserState extends State<FileSystemBrowser> {
  late Directory _currentDir;
  List<FileSystemEntity> _files = [];
  List<FileSystemEntity> _filteredFiles = [];
  final Set<String> _selectedPaths = {};
  bool _isLoading = false;
  String? _errorMessage;
  String _deviceName = 'Internal Storage';
  
  final DeviceDocumentService _docService = DeviceDocumentService();
  
  // UI State
  bool _showHidden = false;
  String _sortBy = 'name'; // name, date, size
  bool _sortAsc = true;
  bool _isGridMode = true; // Default to Grid
  final Set<String> _activeFilters = {}; 

  // Virtual Mode State
  bool _isVirtualMode = false;
  String _virtualTitle = '';

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // "Open from" Categories (Drawer)
  final List<Map<String, dynamic>> _categories = [
    {'name': 'Recent', 'icon': Icons.schedule, 'path': 'recent'}, // Virtual
    {'name': 'Documents', 'icon': Icons.description, 'path': 'all_docs'}, // Virtual
    {'name': 'Downloads', 'icon': Icons.download, 'path': '/storage/emulated/0/Download'},
    {'name': 'Internal Storage', 'icon': Icons.smartphone, 'path': '/storage/emulated/0'},
  ];

  @override
  void initState() {
    super.initState();
    _currentDir = Directory(widget.initialPath ?? '/storage/emulated/0');
    _getDeviceName();
    _loadDirectory();
  }

  Future<void> _getDeviceName() async {
    final plugin = DeviceInfoPlugin();
    if (Platform.isAndroid) {
       final android = await plugin.androidInfo;
       if (mounted) {
         setState(() {
           _deviceName = '${android.brand} ${android.model}';
         });
       }
    }
  }

  Future<void> _loadDirectory() async {
    if (_isVirtualMode) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (!await _checkPermission()) return;
      
      final List<FileSystemEntity> entities = [];
      await for (final entity in _currentDir.list(followLinks: false)) {
         if (!_showHidden && path.basename(entity.path).startsWith('.')) continue;
         entities.add(entity);
      }
      
      _files = entities;
      _applyFiltersAndSort();
      
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
       if (mounted) setState(() {
           _isLoading = false;
           _errorMessage = 'Access denied or error: $e';
       });
    }
  }
  
  Future<void> _loadVirtualView(String type) async {
      setState(() {
          _isLoading = true;
          _errorMessage = null;
          _isVirtualMode = true;
          _files.clear();
      });
      
      try {
          // Sync DB first to ensure freshness
          await _docService.syncAndIndex();
          
          List<FileSystemEntity> results = [];
          
          if (type == 'recent') {
              // Recent: Flat list, sorted by date modified desc
              _virtualTitle = 'Recent Files';
              results = await _docService.getDocuments(
                  flatList: true,
                  limit: 100,
                  filterType: 'All'
              );
              // Force Date Sort Descending initially
              _sortBy = 'date';
              _sortAsc = false; 
          } else if (type == 'all_docs') {
              // All Documents: Flat list containing all indexed docs
              _virtualTitle = 'All Documents';
               results = await _docService.getDocuments(
                  flatList: true, 
                  limit: 1000,
                  filterType: 'All'
              );
              _sortBy = 'name';
              _sortAsc = true;
          }
          
          _files = results;
          _applyFiltersAndSort();
          
      } catch (e) {
          _errorMessage = 'Failed to load documents: $e';
      } finally {
          if (mounted) setState(() => _isLoading = false);
      }
  }

  void _applyFiltersAndSort() {
      // Create a copy to avoid modifying original list in place incorrectly
      var processed = List<FileSystemEntity>.from(_files);
      
      // Filter Chips (AND Logic)
      if (_activeFilters.contains('large')) {
          processed = processed.where((e) {
              if (e is! File) return false;
              try {
                  return e.statSync().size > (10 * 1024 * 1024); // > 10MB
              } catch (_) { return false; }
          }).toList();
      }
      
      if (_activeFilters.contains('week')) {
          final now = DateTime.now();
          final weekAgo = now.subtract(const Duration(days: 7));
          processed = processed.where((e) {
              try {
                  return e.statSync().modified.isAfter(weekAgo);
              } catch (_) { return false; }
          }).toList();
      }

      // Extension Filter
      processed = processed.where((e) {
        if (e is Directory) return true;
        if (e is File) {
           final ext = e.path.split('.').last.toLowerCase();
           return widget.allowedExtensions.contains(ext);
        }
        return false;
      }).toList();

      // Sort
      processed.sort((a, b) {
          final aIsDir = a is Directory;
          final bIsDir = b is Directory;
          if (aIsDir && !bIsDir) return -1;
          if (!aIsDir && bIsDir) return 1;
          
          int cmp;
          switch (_sortBy) {
              case 'date':
                  final aTime = a.statSync().modified;
                  final bTime = b.statSync().modified;
                  cmp = aTime.compareTo(bTime);
                  break;
              case 'size':
                  if (a is File && b is File) {
                      cmp = a.statSync().size.compareTo(b.statSync().size);
                  } else {
                      cmp = a.path.toLowerCase().compareTo(b.path.toLowerCase());
                  }
                  break;
              case 'name': 
              default:
                  cmp = a.path.toLowerCase().compareTo(b.path.toLowerCase());
          }
          return _sortAsc ? cmp : -cmp;
      });
      
      setState(() {
          _filteredFiles = processed;
      });
  }

  @override
  Widget build(BuildContext context) {
    // Is Root if physical root OR virtual mode
    final isRoot = _isVirtualMode || _currentDir.path == '/storage/emulated/0';
    final theme = Theme.of(context);
    
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: theme.scaffoldBackgroundColor, // Use Theme
        drawer: _buildDrawer(),
        appBar: AppBar(
          backgroundColor: theme.scaffoldBackgroundColor, // Use Theme
          elevation: 0,
          leading: IconButton(
             icon: Icon(isRoot && !_isVirtualMode ? Icons.menu : Icons.arrow_back),
             onPressed: (isRoot && !_isVirtualMode) ? () => _scaffoldKey.currentState?.openDrawer() : _isVirtualMode ? () => _openDirectory(Directory('/storage/emulated/0')) : _navigateUp,
          ),
          title: Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
                 Text(_isVirtualMode ? _virtualTitle : (isRoot ? _deviceName : path.basename(_currentDir.path)), style: theme.textTheme.titleLarge?.copyWith(fontSize: 18)),
                 if (!isRoot && !_isVirtualMode) 
                    Text(_currentDir.path, style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, overflow: TextOverflow.ellipsis)),
             ],
          ),
          actions: [
             IconButton(
                 icon: Icon(_isGridMode ? Icons.view_list : Icons.grid_view),
                 tooltip: _isGridMode ? 'Switch to List' : 'Switch to Grid',
                 onPressed: () => setState(() => _isGridMode = !_isGridMode),
             ),
             IconButton(icon: const Icon(Icons.search), onPressed: () {}),
             PopupMenuButton<String>(
                 icon: const Icon(Icons.more_vert),
                 color: theme.cardColor,
                 onSelected: (value) {
                     if (value == 'select_all') {
                         final all = _filteredFiles.whereType<File>().map((e) => e.path).toList();
                         setState(() => _selectedPaths.addAll(all));
                         widget.onSelectionChanged?.call(_selectedPaths.toList());
                     } else if (value == 'hidden') {
                         setState(() => _showHidden = !_showHidden);
                         if (!_isVirtualMode) _loadDirectory(); 
                     } else if (value.startsWith('sort_')) {
                         setState(() {
                             final newSort = value.split('_')[1];
                             if (_sortBy == newSort) _sortAsc = !_sortAsc;
                             else { _sortBy = newSort; _sortAsc = true; }
                             _applyFiltersAndSort();
                         });
                     }
                 },
                 itemBuilder: (context) => [
                     const PopupMenuItem(value: 'sort_name', child: Text('Sort by Name')),
                     const PopupMenuItem(value: 'sort_date', child: Text('Sort by Date')),
                     const PopupMenuItem(value: 'sort_size', child: Text('Sort by Size')),
                     const PopupMenuDivider(),
                     const PopupMenuItem(value: 'select_all', child: Text('Select all')),
                     PopupMenuItem(value: 'hidden', child: Text(_showHidden ? 'Hide hidden files' : 'Show hidden files')),
                 ],
             )
          ],
        ),
        body: Column(
          children: [
              // Filter Chips (Always Visible)
              Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                          _buildFilterChip('Large files (10MB+)', 'large'),
                          const SizedBox(width: 8),
                          _buildFilterChip('This week', 'week'),
                      ],
                  ),
              ),

              Expanded(
                child: _isLoading 
                  ? const Center(child: CircularProgressIndicator())
                  : _errorMessage != null 
                     ? Center(child: Text(_errorMessage!, style: TextStyle(color: theme.colorScheme.error)))
                     : _buildContent(),
              ),

              if (widget.allowFolderSelection && !_isVirtualMode && _currentDir.path != '/storage/emulated/0')
                 Container(
                     width: double.infinity,
                     padding: const EdgeInsets.all(16),
                     decoration: BoxDecoration(
                         color: theme.appBarTheme.backgroundColor,
                         boxShadow: [
                             BoxShadow(
                                 color: Colors.black.withOpacity(0.1),
                                 blurRadius: 4,
                                 offset: const Offset(0, -2),
                             )
                         ]
                     ),
                     child: SafeArea(
                        child: ElevatedButton(
                           onPressed: () {
                               Navigator.pop(context, [_currentDir.path]);
                           },
                           style: ElevatedButton.styleFrom(
                               backgroundColor: theme.colorScheme.primary, // Force Primary Color (Blue/Dark)
                               foregroundColor: theme.colorScheme.onPrimary,
                               minimumSize: const Size(double.infinity, 50),
                               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                               textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.0)
                           ),
                           child: Text('USE THIS FOLDER (${path.basename(_currentDir.path)})'),
                        ),
                     ),
                 ),

              if (_selectedPaths.isNotEmpty && !widget.allowFolderSelection)
                 Container(
                     padding: const EdgeInsets.all(16),
                     color: theme.colorScheme.secondaryContainer,
                     child: SafeArea(
                       child: Row(
                           mainAxisAlignment: MainAxisAlignment.spaceBetween,
                           children: [
                               Text('${_selectedPaths.length} selected', style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
                               ElevatedButton.icon(
                                   onPressed: () {
                                       Navigator.pop(context, _selectedPaths.toList());
                                   },
                                   icon: const Icon(Icons.check),
                                   label: const Text('Import'),
                               )
                           ],
                       ),
                     ),
                 )
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer() {
      final theme = Theme.of(context);
      return Drawer(
          backgroundColor: theme.scaffoldBackgroundColor,
          child: SafeArea(
            child: Column(
                children: [
                    Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text('Open from', style: theme.textTheme.headlineSmall),
                    ),
                    Expanded(
                        child: ListView.builder(
                            itemCount: _categories.length,
                            itemBuilder: (context, index) {
                                 final cat = _categories[index];
                                 return ListTile(
                                     leading: Icon(cat['icon'], color: theme.colorScheme.onSurfaceVariant),
                                     title: Text(cat['name'], style: theme.textTheme.bodyLarge),
                                     onTap: () => _openCategory(cat['path']),
                                     selected: _isVirtualMode && _virtualTitle == (cat['name'] == 'Documents' ? 'All Documents' : 'Recent Files'),
                                     selectedTileColor: theme.colorScheme.secondaryContainer,
                                 );
                            },
                        ),
                    ),
                ],
            ),
          ),
      );
  }

  Widget _buildFilterChip(String label, String id) {
      final theme = Theme.of(context);
      final isSelected = _activeFilters.contains(id);
      return FilterChip(
          label: Text(label),
          selected: isSelected,
          onSelected: (v) {
              setState(() {
                  if (v) _activeFilters.add(id);
                  else _activeFilters.remove(id);
              });
              _applyFiltersAndSort();
          },
          backgroundColor: theme.canvasColor,
          selectedColor: theme.colorScheme.secondaryContainer,
          labelStyle: TextStyle(color: isSelected ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurface),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: isSelected ? Colors.transparent : theme.dividerColor)
          ),
      );
  }
  
  Widget _buildContent() {
      if (_filteredFiles.isEmpty) {
          return const Center(child: Text('No files found', style: TextStyle(color: Colors.grey)));
      }

      if (_isGridMode) {
          // Grid View: Show BOTH Folders and Files in single grid
          // Folders first (handled by sort)
          return GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 1.0, // Square Tiles for Grid
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
              ),
              itemCount: _filteredFiles.length,
              itemBuilder: (context, index) => _buildGridItem(_filteredFiles[index]),
          );
      } else {
          // List View: Standard List
          return ListView.builder(
              itemCount: _filteredFiles.length,
              itemBuilder: (context, index) {
                  final entity = _filteredFiles[index];
                  if (entity is Directory) return _buildListFolder(entity);
                  return _buildFileTile(entity as File);
              },
          );
      }
  }

  Widget _buildGridItem(FileSystemEntity entity) {
      final name = path.basename(entity.path);
      final isDir = entity is Directory;
      final theme = Theme.of(context);
      final isSelected = !isDir && _selectedPaths.contains(entity.path);

      return InkWell(
           onTap: () => isDir ? _openDirectory(entity as Directory) : _toggleSelection(entity.path),
           onLongPress: () => isDir ? null : _toggleSelection(entity.path),
           child: Container(
               decoration: BoxDecoration(
                   color: isSelected ? theme.colorScheme.primaryContainer : theme.cardColor,
                   border: Border.all(color: isSelected ? theme.colorScheme.primary : theme.dividerColor),
                   borderRadius: BorderRadius.circular(12),
               ),
               padding: const EdgeInsets.all(12),
               child: Column(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                       Icon(
                           isDir ? Icons.folder : _getFileIcon(name), 
                           color: isDir ? Colors.amber : theme.colorScheme.primary, 
                           size: 48
                       ),
                       const SizedBox(height: 12),
                       Text(
                           name, 
                           style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500), 
                           textAlign: TextAlign.center,
                           maxLines: 2,
                           overflow: TextOverflow.ellipsis
                       ),
                       if (isSelected) 
                          const Align(
                              alignment: Alignment.topRight,
                              child: Icon(Icons.check_circle, size: 16),
                          )
                   ],
               ),
           ),
      );
  }

  Widget _buildListFolder(Directory dir) {
      final name = path.basename(dir.path);
      return ListTile(
          leading: const Icon(Icons.folder, color: Colors.amber),
          title: Text(name),
          onTap: () => _openDirectory(dir),
      );
  }

  Widget _buildFileTile(File file) {
      final name = path.basename(file.path);
      final isSelected = _selectedPaths.contains(file.path);
      return ListTile(
           leading: Icon(_getFileIcon(name), color: Theme.of(context).colorScheme.primary),
           title: Text(name),
           subtitle: FutureBuilder<FileStat>(
               future: file.stat(),
               builder: (c, s) => s.hasData 
                   ? Text('${(s.data!.size/1024/1024).toStringAsFixed(2)} MB') 
                   : const SizedBox(),
           ),
           trailing: Checkbox(value: isSelected, onChanged: (v) => _toggleSelection(file.path)),
           onTap: () => _toggleSelection(file.path),
           selected: isSelected,
      );
  }

  Future<bool> _checkPermission() async {
     if (await Permission.storage.isGranted || await Permission.manageExternalStorage.isGranted) return true;
     final status = await Permission.manageExternalStorage.request();
     if (status.isGranted) return true;
     if (await Permission.storage.request().isGranted) return true;
     setState(() {
       _isLoading = false;
       _errorMessage = 'Storage permission required.';
     });
     return false;
  }

  Future<bool> _onWillPop() async {
    if (_isVirtualMode) {
        // Exit virtual mode -> Go to Root
        _openDirectory(Directory('/storage/emulated/0'));
        return false;
    }
    
    final isRoot = _currentDir.path == '/storage/emulated/0';
    if (!isRoot) {
        _navigateUp();
        return false; // Don't pop
    }
    return true; // Pop app/tab
  }

  void _navigateUp() {
    final parent = _currentDir.parent;
    if (parent.path == _currentDir.path) return;
    if (_currentDir.path == '/storage/emulated/0') return;
    _currentDir = parent;
    _loadDirectory();
  }

  void _openDirectory(Directory d) {
    setState(() => _isVirtualMode = false);
    _currentDir = d;
    _loadDirectory();
  }
  
  void _openCategory(String path) {
      Navigator.pop(context); // Close Drawer
      
      if (path == 'recent' || path == 'all_docs') {
          _loadVirtualView(path);
      } else {
          final dir = Directory(path);
          if (dir.existsSync()) {
              _openDirectory(dir);
          } else {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Folder not found: $path')));
          }
      }
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        if (!widget.allowMultiple) _selectedPaths.clear();
        _selectedPaths.add(path);
      }
    });
    widget.onSelectionChanged?.call(_selectedPaths.toList());
  }

  IconData _getFileIcon(String fileName) {
      final ext = fileName.split('.').last.toLowerCase();
      switch (ext) {
          case 'pdf': return Icons.picture_as_pdf;
          case 'doc': 
          case 'docx': return Icons.description;
          case 'xls': 
          case 'xlsx': return Icons.table_chart;
          case 'txt': return Icons.text_snippet;
          case 'jpg':
          case 'jpeg':
          case 'png': return Icons.image;
          default: return Icons.insert_drive_file;
      }
  }
}