package com.passwordpdf.passwordpdf_manager

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Handles screenshot detection and renaming to append app name.
 * Renames: Screenshot_YYYYMMDD_HHMMSS.png -> Screenshot_YYYYMMDD_HHMMSS_PDF Manager.png
 */
class ScreenshotRenameHandler(private val context: Context) {
    private val TAG = "ScreenshotRename"
    private val APP_NAME = "PDF Manager"
    private var screenshotObserver: ContentObserver? = null
    private var lastProcessedUri: Uri? = null
    private var lastProcessedTime: Long = 0

    fun register() {
        if (screenshotObserver != null) return

        screenshotObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                uri?.let { handleNewImage(it) }
            }
        }

        context.contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true,
            screenshotObserver!!
        )
        Log.d(TAG, "Screenshot observer registered")
    }

    fun unregister() {
        screenshotObserver?.let {
            context.contentResolver.unregisterContentObserver(it)
            screenshotObserver = null
            Log.d(TAG, "Screenshot observer unregistered")
        }
    }

    private fun handleNewImage(uri: Uri) {
        // Debounce - avoid processing same image multiple times
        val now = System.currentTimeMillis()
        if (uri == lastProcessedUri && now - lastProcessedTime < 2000) {
            return
        }
        lastProcessedUri = uri
        lastProcessedTime = now

        try {
            val cursor = context.contentResolver.query(
                uri,
                arrayOf(
                    MediaStore.Images.Media._ID,
                    MediaStore.Images.Media.DISPLAY_NAME,
                    MediaStore.Images.Media.RELATIVE_PATH
                ),
                null,
                null,
                null
            )

            cursor?.use {
                if (it.moveToFirst()) {
                    val displayName = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME))
                    val relativePath = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)) ?: ""

                    // Check if it's a screenshot and not already renamed
                    if (isScreenshot(displayName, relativePath) && !displayName.contains(APP_NAME)) {
                        renameScreenshot(uri, displayName)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error processing image: ${e.message}")
        }
    }

    private fun isScreenshot(displayName: String, relativePath: String): Boolean {
        val nameCheck = displayName.lowercase().startsWith("screenshot")
        val pathCheck = relativePath.lowercase().contains("screenshot")
        return nameCheck || pathCheck
    }

    private fun renameScreenshot(uri: Uri, originalName: String) {
        try {
            // Get file extension
            val lastDot = originalName.lastIndexOf('.')
            val baseName = if (lastDot > 0) originalName.substring(0, lastDot) else originalName
            val extension = if (lastDot > 0) originalName.substring(lastDot) else ""
            
            // Create new name with app suffix
            val newName = "${baseName}_$APP_NAME$extension"

            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, newName)
            }

            val updated = context.contentResolver.update(uri, values, null, null)
            if (updated > 0) {
                Log.d(TAG, "Renamed: $originalName -> $newName")
            } else {
                Log.w(TAG, "Failed to rename: $originalName")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error renaming screenshot: ${e.message}")
        }
    }
}
