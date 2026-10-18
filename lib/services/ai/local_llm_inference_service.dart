import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../logging_service.dart';
import '../storage_service.dart';

/// Service managing on-device LLM inference, native Platform Channels,
/// strict concurrency locking (one query at a time), and thermal mitigation.
class LocalLlmInferenceService {
  static final LocalLlmInferenceService _instance = LocalLlmInferenceService._internal();
  factory LocalLlmInferenceService() => _instance;
  LocalLlmInferenceService._internal();

  static const MethodChannel _channel = MethodChannel('com.passwordpdf.passwordpdf_manager/ai_engine');
  final StorageService _storage = StorageService();

  // Strict Concurrency Lock: Prevents GPU/NPU resource contention
  Completer<void>? _activeLock;

  // Thermal Guard: Capped output length prevents CPU/GPU overheating
  static const int defaultMaxTokens = 256;
  static const double defaultTemperature = 0.2;

  /// Check whether an active model is downloaded and ready on disk
  Future<Map<String, dynamic>?> getActiveModelInfo() async {
    final active = await _storage.getActiveInstalledModel('llm');
    if (active == null) return null;

    final path = active['file_path'] as String?;
    if (path == null || !File(path).existsSync()) return null;

    return active;
  }

  /// Run inference with concurrency serialization and thermal protection
  Future<String?> generateCompletion({
    required String prompt,
    int maxTokens = defaultMaxTokens,
    double temperature = defaultTemperature,
  }) async {
    return _synchronized(() async {
      final active = await getActiveModelInfo();
      if (active == null) {
        LoggingService().info('LlmInference', 'No active downloaded model found on disk');
        return null;
      }

      final modelPath = active['file_path'] as String;
      final modelId = active['model_id'] as String;
      final displayName = active['display_name'] as String? ?? modelId;

      LoggingService().info('LlmInference', 'Dispatching inference to [$displayName] (${File(modelPath).lengthSync() ~/ (1024 * 1024)} MB)');

      try {
        final result = await _channel.invokeMethod<String>('generate', {
          'modelPath': modelPath,
          'prompt': prompt,
          'maxTokens': maxTokens,
          'temperature': temperature,
        });

        if (result != null && result.trim().isNotEmpty) {
          LoggingService().info('LlmInference', 'Native inference succeeded (${result.length} chars)');
          return result.trim();
        }
      } on MissingPluginException {
        LoggingService().warn('LlmInference', 'Native AI platform channel not registered on this platform');
      } catch (e, stack) {
        LoggingService().error('LlmInference', 'Native inference error: $e', e, stack);
      }

      return null;
    });
  }

  /// Mutual exclusion lock ensuring only ONE inference request executes at any time
  Future<T> _synchronized<T>(Future<T> Function() action) async {
    while (_activeLock != null) {
      await _activeLock!.future;
    }
    _activeLock = Completer<void>();
    try {
      return await action();
    } finally {
      final lock = _activeLock;
      _activeLock = null;
      lock?.complete();
    }
  }
}
