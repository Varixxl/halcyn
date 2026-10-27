package io.github.varixxl.halcyn

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** audio_service's activity (it shares the engine with the media service), plus the
 *  `halcyn/android` channel for reading the music folder and showing notifications. */
class MainActivity : AudioServiceActivity() {
    companion object {
        init {
            System.loadLibrary("halcyn_core")
        }
    }

    /** Gives the audio engine the app context it needs to ask Android about the output. */
    private external fun initNative(context: Context)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initNative(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "halcyn/android")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canReadMusic" -> result.success(canReadMusic())
                    "askToReadMusic" -> {
                        askToReadMusic()
                        result.success(null)
                    }
                    "askToNotify" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun canReadMusic(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    /** Android 11+: the "All files access" page for Halcyn; older: the usual prompt. */
    private fun askToReadMusic() {
        if (Build.VERSION.SDK_INT >= 30) {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            try {
                startActivity(intent)
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 1)
        }
    }
}
