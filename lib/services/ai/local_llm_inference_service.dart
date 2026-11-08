import 'dart:async';
import 'dart:io';
import 'package:flutter_llama/flutter_llama.dart';

import '../logging_service.dart';
import '../storage_service.dart';

/// Structured result of local LLM inference
class LlmInferenceResult {
  final String? text;
  final String status; // 'executed', 'no_active_model_on_disk', 'model_load_failed', 'native_returned_empty', 'llm_error: ...'
  final int executionTimeMs;

  const LlmInferenceResult({
    this.text,
    required this.status,
    this.executionTimeMs = 0,
  });

  bool get isSuccess => text != null && text!.trim().isNotEmpty;
}

/// Service managing on-device LLM inference via flutter_llama (llama.cpp GGUF runtime),
/// model caching, concurrency mutex, and mobile parameters.
class LocalLlmInferenceService {
  static final LocalLlmInferenceService _instance = LocalLlmInferenceService._internal();
  factory LocalLlmInferenceService() => _instance;
  LocalLlmInferenceService._internal();

  final StorageService _storage = StorageService();

  // Strict Concurrency Lock: Prevents GPU/NPU resource contention
  Completer<void>? _activeLock;

  // Cached Loaded Model Path in memory to prevent reloading ~1GB weights on each question
  String? _loadedModelPath;

  // Mobile Safe Parameters: 128 tokens generates complete factual answers on mobile CPU
  static const int defaultMaxTokens = 128;
  static const double defaultTemperature = 0.1;

  /// Check whether an active model is downloaded and ready on disk
  Future<Map<String, dynamic>?> getActiveModelInfo() async {
    final active = await _storage.getActiveInstalledModel('llm');
    if (active == null) return null;

    final path = active['file_path'] as String?;
    if (path == null || !File(path).existsSync()) return null;

    final size = File(path).lengthSync();
    if (size < 10 * 1024 * 1024) return null; // must be a real GGUF file (>10MB)

    return active;
  }

  /// Ensure model is loaded in memory
  Future<bool> ensureModelLoaded(String modelPath) async {
    if (_loadedModelPath == modelPath && FlutterLlama.instance.isModelLoaded) {
      return true;
    }

    try {
      LoggingService().info('LlmInference', 'Loading GGUF model into memory: $modelPath');
      final config = LlamaConfig(
        modelPath: modelPath,
        nThreads: 4,
        contextSize: 1536,
        batchSize: 256,
        useGpu: false, // Safe CPU execution with ARM NEON: prevents Mali/Adreno driver crashes
        verbose: false,
      );

      final loaded = await FlutterLlama.instance.loadModel(config);

      if (loaded) {
        _loadedModelPath = modelPath;
        LoggingService().info('LlmInference', 'GGUF model loaded successfully into runtime engine');
        return true;
      } else {
        LoggingService().warn('LlmInference', 'FlutterLlama loadModel returned false: $modelPath');
        return false;
      }
    } catch (e, stack) {
      LoggingService().error('LlmInference', 'Error initializing GGUF runtime engine: $e', e, stack);
      return false;
    }
  }

  /// Unload cached model to free device RAM
  Future<void> unloadModel() async {
    try {
      if (FlutterLlama.instance.isModelLoaded) {
        await FlutterLlama.instance.unloadModel();
      }
    } catch (_) {}
    _loadedModelPath = null;
  }

  /// Run inference with concurrency serialization, model caching, and stop sequences
  Future<LlmInferenceResult> generateCompletion({
    required String prompt,
    int maxTokens = defaultMaxTokens,
    double temperature = defaultTemperature,
  }) async {
    final sw = Stopwatch()..start();
    return _synchronized(() async {
      final active = await getActiveModelInfo();
      if (active == null) {
        LoggingService().info('LlmInference', 'No active downloaded model found on disk');
        return LlmInferenceResult(
          text: null,
          status: 'no_active_model_on_disk',
          executionTimeMs: sw.elapsedMilliseconds,
        );
      }

      final modelPath = active['file_path'] as String;
      final modelId = active['model_id'] as String;
      final displayName = active['display_name'] as String? ?? modelId;

      LoggingService().info(
        'LlmInference',
        'Executing GGUF inference on [$displayName] (${File(modelPath).lengthSync() ~/ (1024 * 1024)} MB)',
      );

      final isReady = await ensureModelLoaded(modelPath);
      if (!isReady) {
        LoggingService().warn('LlmInference', 'Model could not be loaded into GGUF runtime engine');
        return LlmInferenceResult(
          text: null,
          status: 'model_load_failed',
          executionTimeMs: sw.elapsedMilliseconds,
        );
      }

      try {
        final stopSequences = [
          '<|im_end|>',
          '<|endoftext|>',
          '<end_of_turn>',
          '<eos>',
          '\nUser Question:',
          '</document_evidence>',
        ];

        final params = GenerationParams(
          prompt: prompt,
          maxTokens: maxTokens,
          temperature: temperature,
          topP: 0.9,
          stopSequences: stopSequences,
        );

        final response = await FlutterLlama.instance.generate(params);
        final generatedText = response.text.trim();

        if (generatedText.isNotEmpty) {
          LoggingService().info(
            'LlmInference',
            'GGUF generation completed successfully (${generatedText.length} chars in ${sw.elapsedMilliseconds}ms)',
          );
          return LlmInferenceResult(
            text: generatedText,
            status: 'executed',
            executionTimeMs: sw.elapsedMilliseconds,
          );
        } else {
          return LlmInferenceResult(
            text: null,
            status: 'native_returned_empty',
            executionTimeMs: sw.elapsedMilliseconds,
          );
        }
      } catch (e, stack) {
        LoggingService().error('LlmInference', 'GGUF generation runtime error: $e', e, stack);
        return LlmInferenceResult(
          text: null,
          status: 'llm_error: $e',
          executionTimeMs: sw.elapsedMilliseconds,
        );
      }
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
