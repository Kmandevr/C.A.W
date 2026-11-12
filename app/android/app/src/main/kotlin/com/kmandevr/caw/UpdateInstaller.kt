// The update channel: whether C.A.W may install packages, that setting, and installing a downloaded APK through a
// PackageInstaller session (the system asks the user unless Android allows an update without asking).
package com.kmandevr.caw

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * `canInstall`: PackageManager.canRequestPackageInstalls() (API 26; needs REQUEST_INSTALL_PACKAGES).
 * `openInstallSettings`: Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES for this package (API 26).
 * `silentPossible`: Android 12+ (API 31) and C.A.W is its own installer of record
 *   (PackageManager.getInstallSourceInfo, API 30), so an update may install without the prompt.
 * `install` {path, silent}: a PackageInstaller session (MODE_FULL_INSTALL) with the APK copied in; on API 31+ it asks
 *   for USER_ACTION_NOT_REQUIRED when [silent], else USER_ACTION_REQUIRED. Only a file directly inside the cache's
 *   updates/ folder ending in .apk is accepted. The session's result comes back on the channel as `status`
 *   {status, message}; STATUS_PENDING_USER_ACTION opens the system's confirmation.
 *
 * Android itself refuses a package signed with another key, or with a lower versionCode than the installed one,
 * whatever this code asks. A successful update replaces the running app: Android stops it; it is not restarted.
 *
 * Sources (Android Developers, read 2026-11-12):
 * - PackageManager.canRequestPackageInstalls: developer.android.com/reference/android/content/pm/PackageManager
 * - PackageInstaller.SessionParams.setRequireUserAction (API 31): without the prompt only when the installer is the
 *   app's installer of record or "Updating itself", it declares UPDATE_PACKAGES_WITHOUT_USER_ACTION, and the app
 *   targets a recent enough API; "Session owners should always be prepared to handle STATUS_PENDING_USER_ACTION":
 *   developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams
 * - versionCode protects against downgrades: developer.android.com/studio/publish/versioning
 */
class UpdateInstaller(private val activity: Activity, private val channel: () -> MethodChannel?) {
    private var receiver: BroadcastReceiver? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canInstall" -> result.success(activity.packageManager.canRequestPackageInstalls())
            "silentPossible" -> result.success(silentPossible())
            "openInstallSettings" -> {
                try {
                    activity.startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
                    )
                    result.success(null)
                } catch (e: Exception) {
                    result.error("unavailable", e.message, null)
                }
            }
            "install" -> install(call.argument<String>("path"), call.argument<Boolean>("silent") == true, result)
            else -> result.notImplemented()
        }
    }

    private fun silentPossible(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            activity.packageManager.getInstallSourceInfo(activity.packageName).installingPackageName == activity.packageName
        } catch (e: Exception) {
            false
        }
    }

    private fun install(path: String?, silent: Boolean, result: MethodChannel.Result) {
        val dir = File(activity.cacheDir, "updates").canonicalFile
        val file = path?.let { File(it).canonicalFile }
        if (file == null || file.parentFile != dir || !file.isFile || !file.name.endsWith(".apk")) {
            result.error("refused", "not a downloaded update", null)
            return
        }
        if (!activity.packageManager.canRequestPackageInstalls()) {
            result.error("not_allowed", "install unknown apps is off for C.A.W", null)
            return
        }
        // Copying a large APK into the session takes a moment: off the main thread.
        val main = android.os.Handler(activity.mainLooper)
        Thread {
            try {
                val installer = activity.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(activity.packageName)
                params.setSize(file.length())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    params.setRequireUserAction(
                        if (silent) PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
                        else PackageInstaller.SessionParams.USER_ACTION_REQUIRED
                    )
                }
                val id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    file.inputStream().use { input ->
                        session.openWrite("caw.apk", 0, file.length()).use { out ->
                            input.copyTo(out)
                            session.fsync(out)
                        }
                    }
                    listen()
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                    val intent = Intent(ACTION_STATUS).setPackage(activity.packageName)
                    session.commit(PendingIntent.getBroadcast(activity, id, intent, flags).intentSender)
                }
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { result.error("unavailable", e.message, null) }
            }
        }.start()
    }

    // The session's outcome: the system's confirmation when it asks for one, else reported to Dart.
    private fun listen() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
                if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    @Suppress("DEPRECATION")
                    val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    if (confirm != null) activity.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
                channel()?.invokeMethod("status", mapOf("status" to status, "message" to message))
            }
        }
        val filter = IntentFilter(ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(r, filter)
        }
        receiver = r
    }

    fun dispose() {
        receiver?.let { activity.unregisterReceiver(it) }
        receiver = null
    }

    companion object {
        private const val ACTION_STATUS = "com.kmandevr.caw.UPDATE_STATUS"
    }
}
