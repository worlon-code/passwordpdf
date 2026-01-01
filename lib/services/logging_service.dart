import 'package:flutter/foundation.dart';
import 'storage_service.dart';

/// Log entry model
class LogEntry {
  final DateTime timestamp;
  final String level; // INFO, WARN, ERROR, DEBUG
  final String tag;
  final String message;
  final String? stackTrace;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.stackTrace,
  });

  Map<String, dynamic> toMap() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'level': level,
      'tag': tag,
      'message': message,
      'stack_trace': stackTrace,
    };
  }

  factory LogEntry.fromMap(Map<String, dynamic> map) {
    return LogEntry(
      timestamp: DateTime.parse(map['timestamp']),
      level: map['level'],
      tag: map['tag'],
      message: map['message'],
      stackTrace: map['stack_trace'],
    );
  }
}

/// In-app logging service for debug purposes
class LoggingService {
  static final LoggingService _instance = LoggingService._internal();
  factory LoggingService() => _instance;
  LoggingService._internal();

  final StorageService _storage = StorageService();
  final List<LogEntry> _logs = [];
  final int _maxLogs = 500;

  List<LogEntry> get logs => List.unmodifiable(_logs);

  void _addLog(String level, String tag, String message, [String? stackTrace]) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      stackTrace: stackTrace,
    );
    
    _logs.insert(0, entry); // Add at beginning for newest first
    
    // Keep max logs limit
    if (_logs.length > _maxLogs) {
      _logs.removeLast();
    }
    
    // Also print to debug console
    debugPrint('[$level] $tag: $message');
    if (stackTrace != null) {
      debugPrint(stackTrace);
    }
    
    // Persist async
    _storage.insertLog(entry.toMap());
  }

  void info(String tag, String message) {
    _addLog('INFO', tag, message);
  }

  void warn(String tag, String message) {
    _addLog('WARN', tag, message);
  }

  void error(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    String? stack;
    if (error != null) {
      stack = 'Error: $error';
      if (stackTrace != null) {
        stack += '\n$stackTrace';
      }
    }
    _addLog('ERROR', tag, message, stack);
  }

  void debug(String tag, String message) {
    _addLog('DEBUG', tag, message);
  }

  Future<void> clearLogs() async {
    _logs.clear();
    await _storage.clearLogs();
  }
  
  Future<List<LogEntry>> getAllLogs() async {
    final maps = await _storage.getLogs(limit: 8000);
    return maps.map((m) => LogEntry.fromMap(m)).toList();
  }

  List<LogEntry> getLogsByLevel(String level) {
    return _logs.where((log) => log.level == level).toList();
  }

  List<LogEntry> getLogsByTag(String tag) {
    return _logs.where((log) => log.tag == tag).toList();
  }
}
