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
  static String? pendingSessionId;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          final sId = payload.startsWith('open_ai_chat:')
              ? payload.replaceFirst('open_ai_chat:', '')
              : payload;
          pendingSessionId = sId;
          onNotificationClicked?.call(sId);
        }
      },
    );

    // Request runtime permission on Android 13+ (POST_NOTIFICATIONS)
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();

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
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
        playSound: true,
        enableVibration: true,
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
        payload: 'open_ai_chat:$sessionId',
      );
    } catch (_) {
      // Fallback silently if platform notifications are unavailable
    }
  }
}
