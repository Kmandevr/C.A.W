// Where Android routes audio (AudioManager.getDevices and, from Android 13, getAudioDevicesForAttributes) and when
// that changes (AudioDeviceCallback), over "caw/audio_route" and "caw/audio_route/events", so output latency
// compensation can pick the right per-device offset. Device types go out as AudioDeviceInfo's raw TYPE_* ints.
// "openBluetoothSettings" opens the system's Bluetooth page (LE Audio, low-latency modes; an app can't pick a codec);
// "openDeveloperOptions" opens Developer options, where the user picks the Bluetooth codec and rate, or says they are off.
// AudioNoisy sends AudioManager.ACTION_AUDIO_BECOMING_NOISY over "caw/audio_noisy" (#244: pause when unplugged).
package com.kmandevr.caw

import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioRoute(private val context: Context) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private val callback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) { send() }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) { send() }
    }

    private fun send() {
        // Android routes a little after it reports the device; a second look catches the settled route.
        sink?.success(snapshot())
        main.postDelayed({ sink?.success(snapshot()) }, 600)
    }

    // No address goes out (a Bluetooth address identifies a person's device); the product name keys the offset.
    private fun describe(d: AudioDeviceInfo): Map<String, Any> =
        mapOf("id" to d.id, "type" to d.type, "name" to (d.productName?.toString() ?: ""), "sink" to d.isSink)

    private fun snapshot(): Map<String, Any?> {
        val outputs = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map(::describe)
        val inputs = audio.getDevices(AudioManager.GET_DEVICES_INPUTS).map(::describe)
        var routed: List<Map<String, Any>> = emptyList()
        if (Build.VERSION.SDK_INT >= 33) {
            val media = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
            routed = try { audio.getAudioDevicesForAttributes(media).map(::describe) } catch (e: Exception) { emptyList() }
        }
        return mapOf("outputs" to outputs, "inputs" to inputs, "routed" to routed, "sdk" to Build.VERSION.SDK_INT)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "snapshot" -> result.success(snapshot())
            "openBluetoothSettings" -> result.success(openBluetoothSettings())
            "openDeveloperOptions" -> result.success(openDeveloperOptions())
            else -> result.notImplemented()
        }
    }

    // From the application context, so a new task; false when no activity handles it.
    private fun openBluetoothSettings(): Boolean = try {
        context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    // "opened"; "off" when Developer options are not turned on (the page would not open: the app shows how); "failed".
    private fun openDeveloperOptions(): String {
        val on = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) != 0
        } catch (e: Exception) {
            false
        }
        if (!on) return "off"
        return try {
            context.startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            "opened"
        } catch (e: ActivityNotFoundException) {
            "failed"
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        audio.registerAudioDeviceCallback(callback, main)
    }

    override fun onCancel(arguments: Any?) {
        audio.unregisterAudioDeviceCallback(callback)
        sink = null
    }
}

// Headphones or a Bluetooth output about to fall back to the speaker (#244): one event per broadcast while Dart
// listens. Registered in code, never in the manifest; not exported to other apps where the API asks.
class AudioNoisy(private val context: Context) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) sink?.success(true)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(receiver, filter)
    }

    override fun onCancel(arguments: Any?) {
        try { context.unregisterReceiver(receiver) } catch (e: IllegalArgumentException) { }
        sink = null
    }
}
