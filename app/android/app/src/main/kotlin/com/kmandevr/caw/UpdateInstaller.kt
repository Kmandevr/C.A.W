// The update channel: whether C.A.W may install packages, that setting, and installing a downloaded APK through a
// PackageInstaller session (the system asks the user unless Android allows an update without asking).
package com.kmandevr.caw

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.SecureRandom

/**
 * `canInstall`: PackageManager.canRequestPackageInstalls() (API 26; needs REQUEST_INSTALL_PACKAGES).
 * `openInstallSettings`: Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES for this package (API 26).
 * `silentPossible`: Android 12+ (API 31) and C.A.W is its own installer of record
 *   (PackageManager.getInstallSourceInfo, API 30), so an update may install without the prompt.
 * `install` {path, silent}: a PackageInstaller session (MODE_FULL_INSTALL) with the APK copied in; on API 31+ it asks
 *   for USER_ACTION_NOT_REQUIRED when [silent], else USER_ACTION_REQUIRED. Only a file directly inside the cache's
 *   updates/ folder ending in .apk is accepted. The session's result comes to [UpdateStatusReceiver], a manifest
 *   receiver that is not exported (no other app can send to it, on every API level), through an explicit
 *   PendingIntent carrying a random token; it is reported on the channel as `status` {status, message}.
 *   STATUS_PENDING_USER_ACTION opens the system's confirmation, and only when that intent resolves to a system app
 *   holding INSTALL_PACKAGES (the platform's package installer); anything else is refused.
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
    init {
        current = this
    }

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
                    // Explicit: only UpdateStatusReceiver (not exported) gets it. Mutable because the installer
                    // fills in EXTRA_STATUS and EXTRA_INTENT; the explicit component can't be changed by a fill-in.
                    val intent = Intent(activity, UpdateStatusReceiver::class.java)
                        .setAction(ACTION_STATUS)
                        .putExtra(EXTRA_TOKEN, token)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                    session.commit(PendingIntent.getBroadcast(activity, id, intent, flags).intentSender)
                }
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { result.error("unavailable", e.message, null) }
            }
        }.start()
    }

    /** The session's outcome, from [UpdateStatusReceiver]. */
    internal fun onStatus(intent: Intent) {
        if (intent.getStringExtra(EXTRA_TOKEN) != token) return
        var status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        var message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            if (confirm != null && isSystemInstaller(confirm)) {
                activity.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } else {
                status = PackageInstaller.STATUS_FAILURE
                message = "refused a confirmation that is not the system's installer"
            }
        }
        channel()?.invokeMethod("status", mapOf("status" to status, "message" to message))
    }

    /** Whether [confirm] opens a system app that holds INSTALL_PACKAGES (only the platform's package installer). */
    private fun isSystemInstaller(confirm: Intent): Boolean {
        val pm = activity.packageManager
        return try {
            val pkg = confirm.component?.packageName
                ?: pm.resolveActivity(confirm, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
                ?: return false
            if (confirm.`package` != null && confirm.`package` != pkg) return false
            val app = pm.getApplicationInfo(pkg, 0)
            (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
                pm.checkPermission(Manifest.permission.INSTALL_PACKAGES, pkg) == PackageManager.PERMISSION_GRANTED
        } catch (e: Exception) {
            false
        }
    }

    fun dispose() {
        if (current === this) current = null
    }

    companion object {
        internal const val ACTION_STATUS = "com.kmandevr.caw.UPDATE_STATUS"
        private const val EXTRA_TOKEN = "com.kmandevr.caw.UPDATE_TOKEN"

        /** A fresh random token per process: a status without it is ignored. */
        private val token: String = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }

        @Volatile
        internal var current: UpdateInstaller? = null
    }
}

/**
 * Receives the install session's status. Declared in the manifest with exported="false", so only C.A.W's own
 * PendingIntent (sent by the system on C.A.W's behalf) reaches it, on every API level; it hands the status to the
 * running [UpdateInstaller].
 */
class UpdateStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != UpdateInstaller.ACTION_STATUS) return
        UpdateInstaller.current?.onStatus(intent)
    }
}
