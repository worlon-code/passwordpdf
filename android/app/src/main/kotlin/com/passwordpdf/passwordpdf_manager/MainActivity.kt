package com.passwordpdf.passwordpdf_manager

import io.flutter.embedding.android.FlutterFragmentActivity
import android.content.Intent
import android.os.Bundle

class MainActivity: FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    // singleTask reuses this activity for new "Open With"/share intents. Make the
    // NEW intent authoritative BEFORE forwarding to Flutter/the sharing plugin, so
    // getIntent() can never serve the stale original (part of the "opens the
    // previous file" fix). New intents reach Flutter via the plugin's event stream.
    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        super.onNewIntent(intent)
    }
}
