package com.junglechat.app

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Screenshot / screen-recorder blocking.
 *
 * Exposes a MethodChannel `com.junglechat/security` with `setSecure(true|false)`
 * that adds/clears [WindowManager.LayoutParams.FLAG_SECURE] on the bound
 * activity's window. MainActivity re-applies the flag on every resume so it
 * survives config changes and system-dialog focus loss.
 *
 * Registered from MainActivity.configureFlutterEngine with a single line.
 */
object SecurityFlagsPlugin {
    private const val CHANNEL = "com.junglechat/security"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val secure = call.argument<Boolean>("secure") ?: true
                        try {
                            if (secure) {
                                activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("SECURE_FAILED", t.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
