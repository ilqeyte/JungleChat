package com.junglechat.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // In-app updates: download + install without leaving the app.
    private val INSTALLER_CHANNEL = "com.junglechat.app/installer"
    private val INSTALL_PERMISSION_REQUEST = 4711
    private var flutterEngine: FlutterEngine? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine): Unit {
        super.configureFlutterEngine(flutterEngine)
        this.flutterEngine = flutterEngine

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("BAD_ARGS", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val launched = launchInstaller(File(path))
                            if (launched) {
                                result.success(true)
                            } else {
                                result.error(
                                    "NO_ACTIVITY",
                                    "No app can handle APK installation",
                                    null
                                )
                            }
                        } catch (t: Throwable) {
                            Log.e("Installer", "installApk failed", t)
                            result.error("INSTALL_FAILED", t.message, null)
                        }
                    }
                    "openInstallSettings" -> {
                        val opened = openInstallUnknownSourcesSettings()
                        result.success(opened)
                    }
                    else -> result.notImplemented()
                }
            }
        SecurityFlagsPlugin.register(flutterEngine, this)
    }

    override fun onResume() {
        super.onResume()
        // Re-assert FLAG_SECURE on every resume. Android can drop it after a
        // config change or when a system dialog takes focus. The rewarded-ad
        // screen temporarily clears it via the security channel.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    /**
     * Starts the Android package installer for a downloaded APK.
     *
     * Since Android 7 (API 24) a `file://` URI can no longer be shared with
     * another app — the installer would reject it with FileUriExposedException.
     * The APK therefore goes through our FileProvider, which wraps it in a
     * `content://` URI and grants the installer temporary read access to that
     * one file. The installer runs as a system overlay on top of our task, so
     * the user never leaves the app.
     */
    private fun launchInstaller(apk: File): Boolean {
        if (!apk.exists()) {
            throw IllegalStateException("APK not found at ${apk.absolutePath}")
        }

        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apk
        )

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        // Confirm the installer will accept the URI before handing it over,
        // so we can report a clean error instead of a silent no-op.
        val resolved = packageManager.queryIntentActivities(intent, 0)
        if (resolved.isEmpty()) {
            return false
        }
        startActivity(intent)
        return true
    }

    /**
     * Opens the "Install unknown apps" page for this app.
     *
     * REQUEST_INSTALL_PACKAGES is a special permission: it cannot be granted
     * from a runtime dialog, only from the system settings screen. Returns
     * true when the screen was opened (the user returns via the back button).
     */
    private fun openInstallUnknownSourcesSettings(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                true
            } else {
                val intent = Intent(Settings.ACTION_SECURITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                true
            }
        } catch (t: Throwable) {
            Log.w("Installer", "Could not open install settings", t)
            false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Ads (AdMob) are initialized from Dart via google_mobile_ads; no
        // native SDK wiring is required here.
    }
}
