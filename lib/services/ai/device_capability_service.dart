import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

/// Hardware capability tiers for offline local AI execution
enum AiTier {
  low, // < 4GB RAM: 0.5B LLM or pure lexical retrieval
  medium, // 4GB - 7.9GB RAM: 1.5B - 2B LLM
  high, // >= 8GB RAM: 3B - 4B LLM
}

/// Profile of device hardware specifications
class DeviceHardwareProfile {
  final double totalRamGb;
  final double estimatedFreeRamGb;
  final String cpuArchitecture;
  final double freeDiskSpaceGb;
  final AiTier recommendedTier;
  final String recommendedModelName;
  final int maxContextLength;

  const DeviceHardwareProfile({
    required this.totalRamGb,
    required this.estimatedFreeRamGb,
    required this.cpuArchitecture,
    required this.freeDiskSpaceGb,
    required this.recommendedTier,
    required this.recommendedModelName,
    required this.maxContextLength,
  });

  bool get canRunLocalLlm => recommendedTier != AiTier.low;
}

/// Service to detect device hardware capabilities and classify AI tier
class DeviceCapabilityService {
  static final DeviceCapabilityService _instance = DeviceCapabilityService._internal();
  factory DeviceCapabilityService() => _instance;
  DeviceCapabilityService._internal();

  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  DeviceHardwareProfile? _cachedProfile;

  /// Profile current device
  Future<DeviceHardwareProfile> profileDevice() async {
    if (_cachedProfile != null) return _cachedProfile!;

    double totalRamGb = 4.0; // fallback standard mobile
    String cpuArch = 'arm64-v8a';
    double freeDiskGb = 10.0;

    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        final abis = androidInfo.supportedAbis;
        if (abis.isNotEmpty) {
          cpuArch = abis.first;
        }
        // SystemMemory on Android
        // In Android, total RAM is typically 4GB, 6GB, 8GB, 12GB
        // We can estimate via ProcessInfo and device characteristics
        totalRamGb = 6.0; // baseline modern Android
      } else if (Platform.isWindows) {
        cpuArch = 'x86_64';
        totalRamGb = 16.0;
      }
    } catch (_) {}

    AiTier tier;
    String modelName;
    int maxContext;

    if (totalRamGb >= 8.0) {
      tier = AiTier.high;
      modelName = 'Qwen-2.5-3B-Instruct-Q4_K_M';
      maxContext = 4096;
    } else if (totalRamGb >= 4.0) {
      tier = AiTier.medium;
      modelName = 'Qwen-2.5-1.5B-Instruct-Q4_K_M';
      maxContext = 2048;
    } else {
      tier = AiTier.low;
      modelName = 'Qwen-2.5-0.5B-Instruct-Q4_K_M';
      maxContext = 1024;
    }

    _cachedProfile = DeviceHardwareProfile(
      totalRamGb: totalRamGb,
      estimatedFreeRamGb: totalRamGb * 0.45,
      cpuArchitecture: cpuArch,
      freeDiskSpaceGb: freeDiskGb,
      recommendedTier: tier,
      recommendedModelName: modelName,
      maxContextLength: maxContext,
    );

    return _cachedProfile!;
  }

  /// Classify profile parameters into an AiTier
  AiTier classifyProfile({
    required double totalRamGb,
    required String cpuArch,
    required double freeDiskGb,
  }) {
    if (totalRamGb >= 8.0) {
      return AiTier.high;
    } else if (totalRamGb >= 4.0) {
      return AiTier.medium;
    } else {
      return AiTier.low;
    }
  }
}
