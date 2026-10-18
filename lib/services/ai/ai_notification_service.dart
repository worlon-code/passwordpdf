import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Notification service for AI background completions
class AiNotificationService {
  static final AiNotificationService _instance = AiNotificationService._internal();
  factory AiNotificationService() => _instance;
  AiNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  static void Function(String sessionId)? onNotificationClicked;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        if (response.payload != null && response.payload!.isNotEmpty) {
          onNotificationClicked?.call(response.payload!);
        }
      },
    );

    _initialized = true;
  }

  /// Show completion notification when AI finishes analyzing while user is outside chat screen
  Future<void> showAiResponseNotification({
    required String sessionId,
    required String chatTitle,
    required String answerPreview,
  }) async {
    try {
      await init();

      const androidDetails = AndroidNotificationDetails(
        'ai_chat_channel',
        'AI Document Intelligence',
        channelDescription: 'Notifications when offline AI finishes analyzing documents',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
      );

      const darwinDetails = DarwinNotificationDetails();

      const details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
      );

      final cleanPreview = answerPreview.replaceAll('\n', ' ').trim();
      final body = cleanPreview.length > 120
          ? '${cleanPreview.substring(0, 117)}...'
          : cleanPreview;

      await _notifications.show(
        sessionId.hashCode,
        'AI: $chatTitle',
        body,
        details,
        payload: sessionId,
      );
    } catch (_) {
      // Fallback silently if platform notifications are unavailable
    }
  }
}
