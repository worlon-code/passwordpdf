package com.passwordpdf.passwordpdf_manager

import io.flutter.embedding.android.FlutterFragmentActivity
import android.os.Bundle

class MainActivity: FlutterFragmentActivity() {
    private var screenshotHandler: ScreenshotRenameHandler? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        screenshotHandler = ScreenshotRenameHandler(this)
    }

    override fun onStart() {
        super.onStart()
        screenshotHandler?.register()
    }

    override fun onStop() {
        super.onStop()
        screenshotHandler?.unregister()
    }
}
