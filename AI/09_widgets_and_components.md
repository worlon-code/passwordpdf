# 09 Widgets & Components - PasswordPDF

## Table of Contents
1. [Common Components](#common-components)
2. [Screen-Specific Widgets](#screen-specific-widgets)
3. [Design Pattern](#design-pattern)

---

## Common Components
Located in `/lib/core/widgets/` or used globally.

| Widget Name | File Path | Props/Parameters | Purpose |
|-------------|-----------|------------------|---------|
| **FileListItem** | `lib/core/widgets/file_list_item.dart` | `DocumentItem`, `onTap`, `onLongPress` | Displays a single file with icon, name, and size. |
| **FolderCard** | `lib/core/widgets/folder_card.dart` | `DocumentItem`, `onOpen` | Displays a folder icon with file count badge. |
| **SearchField** | `lib/core/widgets/search_field.dart` | `controller`, `onChanged` | A styled Material 3 search input. |
| **AnimatedSplashLogo**| `lib/features/authentication/widgets/animated_splash_logo.dart` | `animateText` | The heartbeat animation shown on startup. |

## Screen-Specific Widgets

### 1. Document Dashboard
- **`FolderNavigationHeader`**: Shows the breadcrumb path (e.g. `Home > Work > Invoices`).
- **`ConflictResolutionDialog`**: A complex stateful dialog that lists multiple file conflicts for batch processing.

### 2. PDF Viewer
- **`PasswordPromptDialog`**: The custom dialog used to ask for a PDF password or select a saved one.
- **`PageIndicator`**: A floating widget in the bottom-right showing `Page X of Y`.

### 3. Settings
- **`ColorPickerItem`**: A horizontal scrollable list of colored circles to select the app's accent color.

## Design Pattern
- **Material 3**: All widgets use `Theme.of(context).colorScheme` for dynamic color support.
- **Composition**: Larger screens (like `DocumentDashboardScreen`) are composed of smaller, private widget methods `_buildFileList()`, `_buildFolderGrid()` to keep files readable.
- **Shimmer**: `Shimmer.fromColors` is used for skeleton loaders in `AllDocumentsScreen` during file system scanning.
