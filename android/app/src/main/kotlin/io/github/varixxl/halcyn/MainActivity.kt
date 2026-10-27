package io.github.varixxl.halcyn

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** audio_service's activity (it shares the engine with the media service), plus the
 *  `halcyn/android` channel for reading the music folder, showing notifications and finding
 *  YouTube Music's audio. */
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
                    "abi" -> result.success(Build.SUPPORTED_ABIS.first())
                    "canInstall" -> result.success(packageManager.canRequestPackageInstalls())
                    "allowInstalls" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            )
                        )
                        result.success(null)
                    }
                    "installApk" -> {
                        try {
                            installApk(File(call.argument<String>("path")!!))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                    "deviceName" -> result.success(
                        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
                            ?: Build.MODEL
                    )
                    // The cookies of a sign-in page (YouTube Music's), for the core.
                    "cookies" -> result.success(
                        android.webkit.CookieManager.getInstance().getCookie(call.argument<String>("url"))
                    )
                    "youtubeAudio" -> {
                        val id = call.argument<String>("id")!!
                        Thread {
                            val found = runCatching { YouTubeAudio.find(id) }
                            runOnUiThread {
                                found.fold(
                                    { result.success(it) },
                                    { result.error("youtube", it.message ?: "YouTube wouldn't send the audio", null) },
                                )
                            }
                        }.start()
                    }
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

    /** Hands the APK to the system installer, which asks the user and then restarts
     *  Halcyn on the new version. [UpdateReceiver] shows the confirmation. */
    private fun installApk(apk: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("halcyn.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val status = PendingIntent.getBroadcast(
                this,
                id,
                Intent(this, UpdateReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(status.intentSender)
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
