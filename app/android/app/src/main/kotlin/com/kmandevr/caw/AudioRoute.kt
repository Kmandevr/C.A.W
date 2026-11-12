// Where Android routes audio (AudioManager.getDevices and, from Android 13, getAudioDevicesForAttributes) and when
// that changes (AudioDeviceCallback), over "caw/audio_route" and "caw/audio_route/events", so output latency
// compensation can pick the right per-device offset. Device types go out as AudioDeviceInfo's raw TYPE_* ints.
package com.kmandevr.caw

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioRoute(context: Context) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {
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
            else -> result.notImplemented()
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
