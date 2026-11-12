// Background playback: a foreground service of type mediaPlayback (plus microphone while recording) that keeps the app
// running while it plays or records behind other apps, with a notification whose Play/Pause and Stop drive the transport.
package com.kmandevr.caw

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// developer.android.com, read 2026-11-12: "Foreground service types" (mediaPlayback needs FOREGROUND_SERVICE_MEDIA_PLAYBACK
// and no runtime permission; microphone needs FOREGROUND_SERVICE_MICROPHONE and RECORD_AUDIO, and cannot be created while
// the app is in the background), "Restrictions on starting a foreground service from the background" (Android 12+: not
// from the background; Android 14+: SecurityException without the type's permissions), "Launch a foreground service"
// (startForegroundService, then startForeground in onStartCommand; startForeground again to add a type),
// "Notification runtime permission" (Android 13+: POST_NOTIFICATIONS; a foreground service runs without it, its
// notification then shows only in the Task Manager) and PendingIntent (Android 12+: FLAG_IMMUTABLE or FLAG_MUTABLE).
class PlaybackService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SHOW -> {
                val playing = intent.getBooleanExtra(EXTRA_PLAYING, true)
                val recording = intent.getBooleanExtra(EXTRA_RECORDING, false)
                if (!promote(playing, recording)) {
                    stopSelf()
                    running = false
                }
            }
            ACTION_PLAY_PAUSE, ACTION_STOP -> {
                val l = listener
                if (l == null) {
                    // The app's engine is gone: nothing to drive, so the notification goes too.
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    running = false
                } else {
                    l(if (intent.action == ACTION_STOP) "stop" else "playPause")
                }
            }
            else -> {
                // Restarted by the system with no intent (START_NOT_STICKY makes this rare): nothing to show.
                stopSelf()
                running = false
            }
        }
        return START_NOT_STICKY
    }

    // Into the foreground with the notification; the microphone type only while recording, with RECORD_AUDIO granted
    // (Android 14 throws otherwise; then mediaPlayback alone, the recording still runs while the app is in front).
    private fun promote(playing: Boolean, recording: Boolean): Boolean {
        val n = notification(playing, recording)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, n)
            return true
        }
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        val mic = recording && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (mic) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        return try {
            startForeground(NOTIFICATION_ID, n, type)
            true
        } catch (_: SecurityException) {
            if (!mic) return false
            try {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                true
            } catch (_: RuntimeException) {
                false
            }
        } catch (_: RuntimeException) {
            false  // ForegroundServiceStartNotAllowedException (Android 12+): asked from the background
        }
    }

    private fun notification(playing: Boolean, recording: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager != null && manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Playback", NotificationManager.IMPORTANCE_LOW).apply {
                description = "While C.A.W plays or records in the background"
                setShowBadge(false)
            })
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        // Explicit intents only: the app's own activity and this (not exported) service.
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags)
        val playPause = PendingIntent.getService(this, 1,
            Intent(this, PlaybackService::class.java).setAction(ACTION_PLAY_PAUSE), flags)
        val stop = PendingIntent.getService(this, 2,
            Intent(this, PlaybackService::class.java).setAction(ACTION_STOP), flags)
        val title = when {
            recording -> "C.A.W is recording"
            playing -> "C.A.W is playing"
            else -> "C.A.W is paused"
        }
        val toggle = if (playing) {
            Notification.Action.Builder(Icon.createWithResource(this, android.R.drawable.ic_media_pause), "Pause", playPause)
        } else {
            Notification.Action.Builder(Icon.createWithResource(this, android.R.drawable.ic_media_play), "Play", playPause)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(if (recording) android.R.drawable.ic_btn_speak_now else android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(toggle.build())
            .addAction(Notification.Action.Builder(Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel), "Stop", stop).build())
            .build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away from Recents: the user closed the app, so playback stops with it.
        listener?.invoke("stop")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        running = false
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "playback"
        private const val NOTIFICATION_ID = 7001
        private const val ACTION_SHOW = "com.kmandevr.caw.playback.SHOW"
        private const val ACTION_PLAY_PAUSE = "com.kmandevr.caw.playback.PLAY_PAUSE"
        private const val ACTION_STOP = "com.kmandevr.caw.playback.STOP"
        private const val EXTRA_PLAYING = "playing"
        private const val EXTRA_RECORDING = "recording"

        /** The notification's buttons, on the main thread; set while the Flutter engine is attached. */
        var listener: ((String) -> Unit)? = null
        @Volatile var running = false

        /** Starts (while the app is in front) or updates the service. False when Android refused. */
        fun show(context: Context, playing: Boolean, recording: Boolean): Boolean {
            val intent = Intent(context, PlaybackService::class.java).setAction(ACTION_SHOW)
                .putExtra(EXTRA_PLAYING, playing).putExtra(EXTRA_RECORDING, recording)
            return try {
                if (running) context.startService(intent) else context.startForegroundService(intent)
                running = true
                true
            } catch (_: RuntimeException) {
                false  // IllegalStateException / ForegroundServiceStartNotAllowedException: from the background
            }
        }

        fun hide(context: Context) {
            if (!running) return
            running = false
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }
}

/** The "caw/playback_service" channel: show, hide and the notification permission; the buttons come back as "action". */
class PlaybackChannel(private val activity: Activity, private val channel: MethodChannel) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null

    init {
        val main = Handler(Looper.getMainLooper())
        PlaybackService.listener = { action -> main.post { channel.invokeMethod("action", action) } }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> result.success(PlaybackService.show(activity.applicationContext,
                call.argument<Boolean>("playing") ?: true, call.argument<Boolean>("recording") ?: false))
            "hide" -> {
                PlaybackService.hide(activity.applicationContext)
                result.success(null)
            }
            "notificationsAllowed" -> result.success(notificationsAllowed())
            "requestNotifications" -> {
                if (notificationsAllowed() || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return result.success(notificationsAllowed())
                if (pending != null) return result.error("busy", "a permission request is already open", null)
                pending = result
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
            }
            else -> result.notImplemented()
        }
    }

    private fun notificationsAllowed(): Boolean =
        activity.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() ?: false

    /** MainActivity forwards the answer here; true when it was this class's request. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        pending?.success(notificationsAllowed())
        pending = null
        return true
    }

    /** The activity is going away for good: the buttons have nothing to drive, and playback stops with the app. */
    fun close(finishing: Boolean) {
        PlaybackService.listener = null
        if (finishing) PlaybackService.hide(activity.applicationContext)
    }

    companion object {
        private const val PERMISSION_REQUEST = 4721
    }
}
