# 14 Theming & Styling - PasswordPDF

## Table of Contents
1. [Overview](#overview)
2. [Color System](#color-system)
3. [Typography](#typography)
4. [Theming Engine](#theming-engine)

---

## Overview
PasswordPDF uses **Material 3 (M3)** with a focus on high-contrast readability and user customization.

## Color System
The app uses a **Dynamic Color Seed** architecture:
- **Seed Color**: Defined by the user in `Settings -> Accent Color`.
- **Light Theme**: Generated using `ColorScheme.fromSeed(seedColor, brightness: light)`.
- **Dark Theme**: Generated using `ColorScheme.fromSeed(seedColor, brightness: dark)`.

### Core Colors
| Token | Default Hex (Purple) | Purpose |
|-------|----------------------|---------|
| `primary` | `#6750A4` | Icons, Brand elements, Selection highlight. |
| `secondary` | `#625B71` | Secondary buttons and text. |
| `surface` | `#FFFBFE` | Screen backgrounds and cards. |
| `error` | `#B3261E` | Delete actions, Error messages. |

## Typography
- **Primary Font**: `GoogleFonts.inter()` (Global fallback).
- **Styling**: `Material 3 Typography` scale (`titleLarge`, `bodyMedium`, `labelSmall`).
- **Scaling**: Fonts are globally scaled using `MediaQuery.textScaler` based on the user's `fontSizeAdjustment` setting (-7 to 0).

## Theming Engine
- **Implementation**: Uses `Consumer<SettingsService>` in `MyApp` to rebuild the theme instantly when the user toggles Light/Dark mode or changes the accent color.
- **Components**: Large components (like `FolderCard`) use `surfaceContainerLow` and rounded corners (16.0) for a modern, sleek aesthetic.
