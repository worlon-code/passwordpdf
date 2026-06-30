# 11 Notifications - PasswordPDF

## Table of Contents
1. [Notification System](#notification-system)
2. [Local Notifications](#local-notifications)
3. [Push Notifications](#push-notifications)
4. [Deep Linking & Actions](#deep-linking--actions)

---

## Notification System
PasswordPDF uses notifications primarily to communicate **background task progress** to the user.

## Local Notifications
**Package**: `flutter_local_notifications`  
**Service**: `ExportQueueService`

| Notification Type | Trigger | Actions |
|-------------------|---------|---------|
| **Export Status** | Starting a ZIP export. | Tap opens `ExportProgressScreen`. |
| **Export Complete**| ZIP successfully generated. | Tap opens the destination folder. |
| **Export Error** | ZIP task failed (e.g., Disk Full). | Tap opens `LoggingService`. |
| **Duplicate Found**| Sharing a file that already exists. | Tap opens a location selector popup. |

## Push Notifications
- **⚠️ Not Implemented**: There are no remote push notifications (FCM/OneSignal) as the app has no backend component.

## Deep Linking & Actions

### 1. Sharing Intent ("Open With")
- **Handler**: `receive_sharing_intent` logic in `main.dart`.
- **Flow**: User selects a PDF in an external app (Email, WhatsApp) -> PDF PDF Manager appears in the share sheet -> User selects it -> App opens and auto-navigates to `PdfViewerScreen` or shows a Duplicate notification.

### 2. Notification Actions
Notifications include a `payload` string that the `ExportQueueService` listens for in `onNotificationTap`:
- `open_folder:[id]`: Switches the app to the "Documents" tab and navigates into the specific folder.
- `open_duplicates`: Triggers the duplicate selection bottom sheet.
