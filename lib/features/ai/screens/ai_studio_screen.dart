import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:uuid/uuid.dart';

import '../../../models/document_item_model.dart';
import '../../../services/ai/ai_model_manager_service.dart';
import '../../../services/ai/ai_notification_service.dart';
import '../../../services/ai/device_capability_service.dart';
import '../../../services/ai/multi_pdf_rag_service.dart';
import '../../../services/ai/pdf_indexing_coordinator.dart';
import '../../../services/document_service.dart';
import '../../../services/logging_service.dart';
import '../../../services/pdf_password_service.dart';
import '../../../services/storage_service.dart';
import '../../documents/screens/file_system_browser.dart';
import '../../documents/screens/pdf_viewer_screen.dart';
import '../../settings/services/settings_service.dart';
import '../widgets/ai_model_management_dialog.dart';
import '../widgets/ai_sparkle_icon.dart';
import '../widgets/app_library_pdf_picker.dart';
import 'ai_diagnostics_screen.dart';

/// File reference attached to an AI chat session
class AttachedPdfFile {
  final String path;
  final String name;
  final String? docId;
  final String? password;
  final bool isEncrypted;

  const AttachedPdfFile({
    required this.path,
    required this.name,
    this.docId,
    this.password,
    this.isEncrypted = false,
  });

  Map<String, dynamic> toMap() => {
        'path': path,
        'name': name,
        'docId': docId,
        'isEncrypted': isEncrypted,
      };

  factory AttachedPdfFile.fromMap(Map<String, dynamic> map) => AttachedPdfFile(
        path: map['path'] as String,
        name: map['name'] as String,
        docId: map['docId'] as String?,
        isEncrypted: map['isEncrypted'] as bool? ?? false,
      );
}

/// Standalone screen for ChatGPT-style multi-document AI chat and model management
class AiStudioScreen extends StatefulWidget {
  final String? initialFolderId;
  final String? initialFolderName;

  const AiStudioScreen({
    super.key,
    this.initialFolderId,
    this.initialFolderName,
  });

  @override
  State<AiStudioScreen> createState() => _AiStudioScreenState();
}

class _AiStudioScreenState extends State<AiStudioScreen> with WidgetsBindingObserver {
  final StorageService _storage = StorageService();
  final AiModelManagerService _modelManager = AiModelManagerService();
  final MultiPdfRagService _ragService = MultiPdfRagService();
  final PdfIndexingCoordinator _indexer = PdfIndexingCoordinator();
  final PdfPasswordService _passwordService = PdfPasswordService();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // State
  List<Map<String, dynamic>> _sessions = [];
  Map<String, dynamic>? _currentSession;
  List<Map<String, dynamic>> _messages = [];
  List<AttachedPdfFile> _attachedFiles = [];
  bool _isLoadingSessions = true;
  bool _isLoadingMessages = false;
  bool _isResponding = false;
  String? _indexingStatusText;
  bool _isScreenVisible = true;
  bool _showBackgroundNotice = false;
  Timer? _longRunningTimer;

  // Model & Capacity
  Map<String, dynamic>? _activeModel;
  DeviceHardwareProfile? _deviceProfile;
  int _maxAttachedDocs = 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AiNotificationService.onNotificationClicked = _handleNotificationSessionOpen;
    _initializeStudio();
  }

  void _handleNotificationSessionOpen(String sessionId) {
    final matches = _sessions.where((s) => s['id'] == sessionId).toList();
    if (matches.isNotEmpty) {
      _switchToSession(matches.first);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isScreenVisible = (state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longRunningTimer?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeStudio() async {
    await _loadDeviceAndModelProfile();
    await _loadSessions();

    if (widget.initialFolderId != null) {
      await _setupFolderSession(widget.initialFolderId!, widget.initialFolderName ?? 'Folder');
    }
  }

  Future<void> _loadDeviceAndModelProfile() async {
    final profile = await DeviceCapabilityService().profileDevice();
    final active = await _storage.getActiveInstalledModel('llm');

    int maxDocs = 4;
    if (active != null) {
      final paramSize = active['model_id']?.toString() ?? '';
      if (paramSize.contains('0.5b')) {
        maxDocs = 2;
      } else if (paramSize.contains('1.5b')) {
        maxDocs = 4;
      } else if (paramSize.contains('3b')) {
        maxDocs = 8;
      }
    } else {
      switch (profile.recommendedTier) {
        case AiTier.low:
          maxDocs = 2;
          break;
        case AiTier.medium:
          maxDocs = 4;
          break;
        case AiTier.high:
          maxDocs = 8;
          break;
      }
    }

    if (mounted) {
      setState(() {
        _deviceProfile = profile;
        _activeModel = active;
        _maxAttachedDocs = maxDocs;
      });
    }
  }

  Future<void> _loadSessions() async {
    setState(() => _isLoadingSessions = true);
    final sessions = await _storage.getAllAiChatSessions();

    if (mounted) {
      setState(() {
        _sessions = List<Map<String, dynamic>>.from(sessions);
        _isLoadingSessions = false;
      });

      if (_currentSession == null && sessions.isNotEmpty) {
        await _switchToSession(sessions.first);
      } else if (sessions.isEmpty) {
        await _createNewSession();
      }
    }
  }

  Future<void> _setupFolderSession(String folderId, String folderName) async {
    // Check if a session already exists for this folder
    final existing = _sessions.where((s) => s['folder_id'] == folderId).toList();
    if (existing.isNotEmpty) {
      await _switchToSession(existing.first);
      return;
    }

    // Create a new folder-specific chat session
    await _createNewSession(
      title: 'Chat: $folderName',
      folderId: folderId,
    );

    // Pre-attach all PDF files in this folder
    final docService = DocumentService();
    await docService.initialize();
    final folderItems = docService.getFilesInFolder(folderId);
    final pdfFiles = folderItems
        .where((i) => i.isFile && i.sourcePath != null && i.sourcePath!.toLowerCase().endsWith('.pdf'))
        .toList();

    for (final item in pdfFiles) {
      if (_attachedFiles.length >= _maxAttachedDocs) break;
      await _attachDocumentByPath(item.sourcePath!, fileName: item.name);
    }
  }

  Future<void> _createNewSession({String title = 'New Chat', String? folderId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final newSession = {
      'id': const Uuid().v4(),
      'title': title,
      'created_at': now,
      'updated_at': now,
      'attached_doc_ids': jsonEncode([]),
      'folder_id': folderId,
      'has_vault_consent': 0,
    };

    await _storage.insertAiChatSession(newSession);
    final all = await _storage.getAllAiChatSessions();
    setState(() {
      _sessions = List<Map<String, dynamic>>.from(all);
    });
    await _switchToSession(newSession);
  }

  Future<void> _switchToSession(Map<String, dynamic> session) async {
    setState(() {
      _currentSession = session;
      _isLoadingMessages = true;
      _attachedFiles = [];
    });

    // Parse attached docs
    final attachedRaw = session['attached_doc_ids'] as String?;
    if (attachedRaw != null && attachedRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(attachedRaw) as List;
        _attachedFiles = decoded.map((e) {
          if (e is Map) {
            return AttachedPdfFile.fromMap(Map<String, dynamic>.from(e));
          } else if (e is String) {
            return AttachedPdfFile(path: '', name: e, docId: e);
          }
          return null;
        }).whereType<AttachedPdfFile>().toList();
      } catch (_) {}
    }

    // Load messages
    final msgs = await _storage.getAiChatMessagesForSession(session['id'] as String);

    if (mounted) {
      setState(() {
        _messages = List<Map<String, dynamic>>.from(msgs);
        _isLoadingMessages = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _renameCurrentSession() async {
    if (_currentSession == null) return;
    final controller = TextEditingController(text: _currentSession!['title'] as String? ?? '');

    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Chat Title',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final val = controller.text.trim();
              if (val.isNotEmpty) Navigator.pop(ctx, val);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newTitle != null && newTitle.isNotEmpty) {
      final updated = Map<String, dynamic>.from(_currentSession!);
      updated['title'] = newTitle;
      updated['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      await _storage.updateAiChatSession(updated['id'] as String, updated);
      await _loadSessions();
      setState(() => _currentSession = updated);
    }
  }

  Future<void> _deleteSession(String sessionId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Chat'),
        content: const Text('Are you sure you want to delete this chat session and its history?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _storage.deleteAiChatSession(sessionId);
      _sessions.removeWhere((s) => s['id'] == sessionId);
      if (_currentSession?['id'] == sessionId) {
        if (_sessions.isNotEmpty) {
          await _switchToSession(_sessions.first);
        } else {
          await _createNewSession();
        }
      } else {
        setState(() {});
      }
    }
  }

  // ==================== DOCUMENT ATTACHMENT & VAULT CONSENT ====================

  Future<void> _promptAddDocument() async {
    if (_attachedFiles.length >= _maxAttachedDocs) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Maximum $_maxAttachedDocs documents reached for current model. Upgrade in Model Manager to attach more.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final theme = Theme.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Add PDF to AI Chat',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.library_books, color: theme.colorScheme.onPrimaryContainer),
              ),
              title: const Text('From App Library'),
              subtitle: const Text('Organize in App Folders & Sync'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () => Navigator.pop(c, 'library'),
            ),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.phone_android, color: theme.colorScheme.onSecondaryContainer),
              ),
              title: const Text('From Device Storage'),
              subtitle: const Text('Pick a specific folder on device'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () => Navigator.pop(c, 'device'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (choice == 'library') {
      if (mounted) await _pickFromAppLibrary();
    } else if (choice == 'device') {
      if (mounted) await _pickFromDeviceStorage();
    }
  }

  Future<void> _pickFromAppLibrary() async {
    final remainingSlots = _maxAttachedDocs - _attachedFiles.length;
    if (remainingSlots <= 0) return;

    final selected = await showDialog<List<DocumentItem>>(
      context: context,
      builder: (ctx) => AppLibraryPdfPicker(
        alreadyAttachedPaths: _attachedFiles.map((a) => a.path).toSet(),
        maxSelectable: remainingSlots,
      ),
    );

    if (selected != null && selected.isNotEmpty) {
      for (final item in selected) {
        if (item.sourcePath != null) {
          await _attachDocumentByPath(item.sourcePath!, fileName: item.name);
        }
      }
    }
  }

  Future<void> _pickFromDeviceStorage() async {
    final selectedPaths = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => const FileSystemBrowser(
          allowedExtensions: ['pdf'],
          allowMultiple: true,
        ),
      ),
    );

    if (selectedPaths != null && selectedPaths.isNotEmpty) {
      for (final path in selectedPaths) {
        if (_attachedFiles.length >= _maxAttachedDocs) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Document limit of $_maxAttachedDocs reached.')),
            );
          }
          break;
        }
        await _attachDocumentByPath(path);
      }
    }
  }

  Future<void> _attachDocumentByPath(String filePath, {String? fileName}) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File not found: $filePath')),
      );
      return;
    }

    final name = fileName ?? p.basename(filePath);
    if (_attachedFiles.any((a) => a.path == filePath)) return;

    // Check if file is encrypted
    bool isEncrypted = false;
    try {
      final bytes = await file.readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);
      doc.dispose();
    } catch (e) {
      final err = e.toString().toLowerCase();
      if (err.contains('password') || err.contains('encrypt')) {
        isEncrypted = true;
      }
    }

    String? workingPassword;

    if (isEncrypted) {
      workingPassword = await _resolvePasswordForDocument(filePath, name);
      if (workingPassword == null) {
        // User cancelled or no password provided; cannot attach encrypted file without password
        return;
      }
    }

    // Index document in background
    setState(() => _indexingStatusText = 'Indexing $name...');
    String? docId;
    try {
      docId = await _indexer.indexPdfDocument(
        filePath: filePath,
        password: workingPassword,
      );
    } catch (e) {
      // Continue even if extraction had partial warnings
    }

    final attached = AttachedPdfFile(
      path: filePath,
      name: name,
      docId: docId,
      password: workingPassword,
      isEncrypted: isEncrypted,
    );

    setState(() {
      _attachedFiles.add(attached);
      _indexingStatusText = null;
    });

    await _persistAttachedFiles();
  }

  Future<String?> _resolvePasswordForDocument(String filePath, String fileName) async {
    final settings = Provider.of<SettingsService>(context, listen: false);

    // 1. Try directly stored password for this file
    final storedPass = await _passwordService.getPasswordForDocument(filePath);
    if (storedPass != null && storedPass.isNotEmpty) {
      if (await _testPassword(filePath, storedPass)) return storedPass;
    }

    // 2. Check vault consent
    bool hasConsent = settings.aiAutoVaultPasswordAccess || (_currentSession?['has_vault_consent'] == 1);

    if (!hasConsent) {
      // Ask user one-time consent for this chat
      final consent = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.lock, color: Theme.of(ctx).colorScheme.primary),
              const SizedBox(width: 8),
              const Expanded(child: Text('Protected PDF Detected', style: TextStyle(fontSize: 18))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The document "$fileName" is password-protected.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Would you like to grant permission for the offline AI to access passwords stored in your Password Vault to unlock and read this PDF for this chat?',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 8),
              Text(
                '(You can also permanently enable this in Settings > Security > AI Vault Password Access)',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Deny (Enter Manually)'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Allow for This Chat'),
            ),
          ],
        ),
      );

      if (consent == true) {
        hasConsent = true;
        if (_currentSession != null) {
          final updated = Map<String, dynamic>.from(_currentSession!);
          updated['has_vault_consent'] = 1;
          await _storage.updateAiChatSession(updated['id'] as String, updated);
          _currentSession = updated;
        }
      }
    }

    // If consent granted, attempt passwords from vault
    if (hasConsent) {
      final candidates = await _passwordService.getAllUniquePasswords();
      for (final candidate in candidates) {
        if (await _testPassword(filePath, candidate)) {
          await _passwordService.savePasswordForDocument(filePath, candidate);
          return candidate;
        }
      }
    }

    // Fallback: prompt user to enter password manually
    final controller = TextEditingController();
    final manualPass = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Password for $fileName'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'PDF Password',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );

    if (manualPass != null && manualPass.isNotEmpty) {
      if (await _testPassword(filePath, manualPass)) {
        await _passwordService.savePasswordForDocument(filePath, manualPass);
        return manualPass;
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incorrect password for PDF.'), backgroundColor: Colors.red),
          );
        }
      }
    }

    return null;
  }

  Future<bool> _testPassword(String filePath, String password) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final doc = PdfDocument(inputBytes: bytes, password: password);
      doc.dispose();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeAttachedFile(int index) async {
    setState(() {
      _attachedFiles.removeAt(index);
    });
    await _persistAttachedFiles();
  }

  Future<void> _persistAttachedFiles() async {
    if (_currentSession == null) return;
    final updated = Map<String, dynamic>.from(_currentSession!);
    updated['attached_doc_ids'] = jsonEncode(_attachedFiles.map((a) => a.toMap()).toList());
    updated['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await _storage.updateAiChatSession(updated['id'] as String, updated);
    _currentSession = updated;
  }

  // ==================== CHAT INFERENCE & MESSAGING ====================

  Future<void> _sendMessage([String? presetText]) async {
    final text = presetText ?? _inputController.text.trim();
    if (text.isEmpty || _isResponding) return;

    LoggingService().info('AiStudio', 'Initiating send: "$text"');

    if (_currentSession == null) {
      LoggingService().info('AiStudio', 'No current session, creating new session...');
      await _createNewSession();
      if (_currentSession == null) {
        LoggingService().error('AiStudio', 'Session creation failed');
        return;
      }
    }

    _inputController.clear();

    try {
      // 1. If session is titled 'New Chat', auto-rename based on initial query
      if (_currentSession!['title'] == 'New Chat' || _currentSession!['title'] == 'Chat') {
        final autoTitle = text.length > 32 ? '${text.substring(0, 32)}...' : text;
        final updated = Map<String, dynamic>.from(_currentSession!);
        updated['title'] = autoTitle;
        updated['updated_at'] = DateTime.now().millisecondsSinceEpoch;
        await _storage.updateAiChatSession(updated['id'] as String, updated);
        if (mounted) {
          setState(() => _currentSession = updated);
        }
        _loadSessions();
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final sessionId = _currentSession!['id'] as String;
      final sessionTitle = _currentSession!['title'] as String? ?? 'Document Assistant';

      final userMsg = {
        'id': const Uuid().v4(),
        'session_id': sessionId,
        'role': 'user',
        'content': text,
        'citations_json': null,
        'created_at': now,
      };

      if (mounted) {
        setState(() {
          _messages = List<Map<String, dynamic>>.from(_messages)..add(userMsg);
          _isResponding = true;
          _showBackgroundNotice = false;
        });
        _scrollToBottom();
      }

      await _storage.insertAiChatMessage(userMsg);
      LoggingService().info('AiStudio', 'User message persisted [${userMsg['id']}]');

      // Timer for long running notice (> 2.5s)
      _longRunningTimer?.cancel();
      _longRunningTimer = Timer(const Duration(milliseconds: 2500), () {
        if (_isResponding && mounted) {
          setState(() => _showBackgroundNotice = true);
        }
      });

      // 2. Perform RAG across attached documents
      final docIds = _attachedFiles.map((a) => a.docId).whereType<String>().toList();
      LoggingService().info('AiStudio', 'Executing RAG query across ${docIds.length} attached doc(s)');

      final ragResult = await _ragService.answerQuestion(
        question: text,
        targetDocIds: docIds,
      );

      LoggingService().info('AiStudio', 'RAG response received (${ragResult.answer.length} chars, ${ragResult.citations.length} citations)');

      final citationsData = ragResult.citations
          .map((c) => {
                'fileName': c.fileName,
                'filePath': c.filePath,
                'pageNumber': c.pageNumber,
                'snippet': c.snippet,
              })
          .toList();

      final assistantMsg = {
        'id': const Uuid().v4(),
        'session_id': sessionId,
        'role': 'assistant',
        'content': ragResult.answer,
        'citations_json': jsonEncode(citationsData),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      };

      await _storage.insertAiChatMessage(assistantMsg);
      LoggingService().info('AiStudio', 'Assistant message persisted [${assistantMsg['id']}]');

      if (mounted) {
        setState(() {
          _messages = List<Map<String, dynamic>>.from(_messages)..add(assistantMsg);
          _isResponding = false;
          _showBackgroundNotice = false;
        });
        _scrollToBottom();
      }

      // If user navigated away from chat screen, notify via system notification
      if (!_isScreenVisible) {
        LoggingService().info('AiStudio', 'User not on screen; posting background completion notification');
        await AiNotificationService().showAiResponseNotification(
          sessionId: sessionId,
          chatTitle: sessionTitle,
          answerPreview: ragResult.answer,
        );
      }
    } catch (e, stackTrace) {
      LoggingService().error('AiStudio', 'Exception in _sendMessage: $e', e, stackTrace);
      if (mounted) {
        final sessionId = _currentSession?['id'] as String? ?? 'session';
        final errorMsg = {
          'id': const Uuid().v4(),
          'session_id': sessionId,
          'role': 'assistant',
          'content': 'Unable to process query: $e',
          'citations_json': null,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        };
        setState(() {
          _messages = List<Map<String, dynamic>>.from(_messages)..add(errorMsg);
          _isResponding = false;
          _showBackgroundNotice = false;
        });
        _scrollToBottom();
      }
    } finally {
      _longRunningTimer?.cancel();
      if (mounted && _isResponding) {
        setState(() => _isResponding = false);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openCitation(Map<String, dynamic> citation) {
    final filePath = citation['filePath'] as String?;
    final fileName = citation['fileName'] as String? ?? 'Document';
    final pageNum = citation['pageNumber'] as int? ?? 1;

    if (filePath == null || filePath.isEmpty || !File(filePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Document file not found: $fileName')),
      );
      return;
    }

    final match = _attachedFiles.where((a) => a.path == filePath).toList();
    final password = match.isNotEmpty ? match.first.password : null;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PdfViewerScreen(
          filePath: filePath,
          fileName: fileName,
          initialPageNumber: pageNum,
          password: password,
        ),
      ),
    );
  }

  // ==================== UI BUILD ====================

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentTitle = _currentSession?['title'] as String? ?? 'AI Document Assistant';
    final activeModelName = _activeModel?['display_name'] as String? ?? 'No Model Installed';

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.history),
          tooltip: 'Chat History',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: GestureDetector(
          onTap: _renameCurrentSession,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  currentTitle,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.edit_outlined, size: 16, color: colorScheme.primary),
            ],
          ),
        ),
        actions: [
          // Model Manager Pill
          ActionChip(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            avatar: const AiSparkleIcon(size: 14),
            label: Text(
              _activeModel != null ? activeModelName.split(' ').take(2).join(' ') : 'Model',
              style: const TextStyle(fontSize: 11),
            ),
            onPressed: () async {
              await AiModelManagementDialog.show(context);
              await _loadDeviceAndModelProfile();
            },
          ),
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined),
            tooltip: 'AI Logs & Diagnostics',
            visualDensity: VisualDensity.compact,
            onPressed: () => AiDiagnosticsScreen.show(context),
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New Chat',
            visualDensity: VisualDensity.compact,
            onPressed: () => _createNewSession(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      drawer: _buildSessionsDrawer(),
      body: Column(
        children: [
          // Attached Documents Strip
          _buildAttachedDocumentsBar(),

          // Indexing status progress bar
          if (_indexingStatusText != null)
            LinearProgressIndicator(
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),

          // Chat Messages View
          Expanded(
            child: _isLoadingMessages
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: _messages.length + (_isResponding ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _messages.length && _isResponding) {
                            return _buildThinkingBubble();
                          }
                          return _buildMessageItem(_messages[index]);
                        },
                      ),
          ),

          // Bottom Input Bar
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildAttachedDocumentsBar() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Attached Documents (${_attachedFiles.length}/$_maxAttachedDocs)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add PDF', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: _promptAddDocument,
              ),
            ],
          ),
          if (_attachedFiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'No PDFs attached yet. Tap "+ Add PDF" to ask questions across specific documents.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(_attachedFiles.length, (index) {
                  final file = _attachedFiles[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(
                      avatar: Icon(
                        file.isEncrypted ? Icons.lock : Icons.picture_as_pdf,
                        size: 16,
                        color: file.isEncrypted ? Colors.amber.shade800 : Colors.red,
                      ),
                      label: Text(
                        file.name,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: () => _removeAttachedFile(index),
                    ),
                  );
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              child: const AiSparkleIcon(size: 56),
            ),
            const SizedBox(height: 16),
            Text(
              'What would you like to know?',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '100% offline, on-device intelligence. Your documents and passwords never leave your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildPromptChip('Summarize key points'),
                _buildPromptChip('Find important dates & deadlines'),
                _buildPromptChip('Extract terms & agreements'),
                _buildPromptChip('What are the main financial amounts?'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPromptChip(String prompt) {
    return ActionChip(
      label: Text(prompt, style: const TextStyle(fontSize: 12)),
      onPressed: () => _sendMessage(prompt),
    );
  }

  Widget _buildThinkingBubble() {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: AiSparkleIcon(size: 26),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'AI is thinking',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ),
                  if (_showBackgroundNotice) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 14, color: Colors.blue),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Analyzing large document data. If you leave this screen, AI will continue in the background and notify you when ready.',
                              style: TextStyle(fontSize: 11, color: Colors.blue.shade900),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem(Map<String, dynamic> msg) {
    final isUser = msg['role'] == 'user';
    final content = msg['content'] as String? ?? '';
    final citationsRaw = msg['citations_json'] as String?;
    List<Map<String, dynamic>> citations = [];

    if (citationsRaw != null && citationsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(citationsRaw) as List;
        citations = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (_) {}
    }

    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: AiSparkleIcon(size: 26),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isUser ? colorScheme.primary : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    content,
                    style: TextStyle(
                      color: isUser ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),

                  // Citations chips
                  if (citations.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 6),
                    Text(
                      'Document Citations (Tap to jump):',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isUser ? colorScheme.onPrimary : colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: citations.map((c) {
                        final docName = c['fileName'] as String? ?? 'Document';
                        final pageNum = c['pageNumber'] ?? 1;
                        return ActionChip(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(2),
                          avatar: const Icon(Icons.open_in_new, size: 12),
                          label: Text('$docName (p.$pageNum)', style: const TextStyle(fontSize: 11)),
                          onPressed: () => _openCitation(c),
                        );
                      }).toList(),
                    ),
                  ],

                  // Copy action
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.copy,
                          size: 14,
                          color: isUser ? colorScheme.onPrimary.withValues(alpha: 0.7) : Colors.grey[600],
                        ),
                        tooltip: 'Copy Message',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: content));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Message copied to clipboard')),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: InputDecoration(
                  hintText: 'Ask anything about your attached PDFs...',
                  hintStyle: const TextStyle(fontSize: 13),
                  isDense: true,
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.arrow_upward),
              onPressed: _isResponding ? null : () => _sendMessage(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionsDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Chat History', style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New Chat',
                onPressed: () {
                  Navigator.pop(context);
                  _createNewSession();
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoadingSessions
                  ? const Center(child: CircularProgressIndicator())
                  : _sessions.isEmpty
                      ? const Center(child: Text('No saved chats'))
                      : ListView.separated(
                          itemCount: _sessions.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final session = _sessions[index];
                            final isSelected = session['id'] == _currentSession?['id'];
                            final title = session['title'] as String? ?? 'New Chat';
                            final isFolder = session['folder_id'] != null;

                            return ListTile(
                              selected: isSelected,
                              leading: Icon(
                                isFolder ? Icons.folder : Icons.chat_outlined,
                                size: 20,
                              ),
                              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, size: 18),
                                onPressed: () => _deleteSession(session['id'] as String),
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                _switchToSession(session);
                              },
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.memory),
              title: const Text('Manage AI Models'),
              subtitle: Text(
                _activeModel != null ? _activeModel!['display_name'] as String : 'Download Models',
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () async {
                Navigator.pop(context);
                await AiModelManagementDialog.show(context);
                await _loadDeviceAndModelProfile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('AI Logs & Diagnostics'),
              subtitle: const Text('Inspect queries, search tokens & model prompts', style: TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                AiDiagnosticsScreen.show(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
