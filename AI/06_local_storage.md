# 06 Local Storage - PasswordPDF

## Table of Contents
1. [Overview](#overview)
2. [Storage Types](#storage-types)
3. [SQLite Schema](#sqlite-schema)
4. [Caching Strategy](#caching-strategy)

---

## Overview
PasswordPDF relies entirely on local storage for persistence. It uses three different storage engines based on the nature of the data.

## Storage Types

| Storage Engine | Implementation | Purpose |
|----------------|----------------|---------|
| **SQL Database** | `sqflite` | Document indexing, Folder hierarchy, Export jobs, Recent files, and Logs. |
| **Key-Value** | `shared_preferences` | UI preferences (theme, font scale, accent color) and document metadata. |
| **Secure Storage** | `flutter_secure_storage` | Master App PIN and sensitive authentication flags. |

## SQLite Schema
Managed by `StorageService.dart`. Total tables: 4.

### 1. `passwords` Table
Stores user vault passwords.
- `id`: INTEGER (PK)
- `key_name`: TEXT (Unique)
- `encrypted_value`: TEXT
- `created_at`: TEXT

### 2. `files_index` Table
Caches device file metadata for "All Documents" screen.
- `path`: TEXT (PK)
- `name`: TEXT
- `extension`: TEXT
- `parent_path`: TEXT
- `size`: INTEGER
- `modified_at`: INTEGER
- `has_pdf`: INTEGER (bool flag)

### 3. `export_jobs` Table
Tracks background ZIP operations.
- `id`: TEXT (PK)
- `status`: TEXT (pending, completed, error)
- `progress`: INTEGER
- `output_path`: TEXT

## Caching Strategy
- **File Indexing**: The "All Documents" screen does not scan the entire disk on every launch. It reads the `files_index` table and performs a "background sync" to find new or deleted files.
- **Zero Copy**: No actual PDF files are cached; only their metadata and absolute paths are stored.
- **Log Rotation**: The `logs` table is pruned to a max of 8000 entries (configurable) to prevent database bloat.
