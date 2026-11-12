// The microphone permission (RECORD_AUDIO) for audio input, asked only when the user turns input on or arms a track
// (docs/app.md, Recording audio), and whether Android is silencing our input for another app, over "caw/permissions".
package com.kmandevr.caw

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MicPermission(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null

    private fun granted(): Boolean =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recordAudioGranted" -> result.success(granted())
            "inputSilenced" -> result.success(silenced())
            "requestRecordAudio" -> {
                if (granted()) return result.success(true)
                if (pending != null) return result.error("busy", "a permission request is already open", null)
                pending = result
                activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
            }
            else -> result.notImplemented()
        }
    }

    // Android 10+ shares the microphone by priority and gives the losing app silence, not an error; its
    // recording configuration says so (AudioRecordingConfiguration.isClientSilenced, API 29; developer.android.com,
    // "Sharing audio input", read 2026-11-12). [Assumption] the list holds this app's own recordings.
    private fun silenced(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val audio = activity.getSystemService(AudioManager::class.java) ?: return false
        return try {
            audio.activeRecordingConfigurations.any { it.isClientSilenced }
        } catch (_: RuntimeException) {
            false
        }
    }

    /** MainActivity forwards the answer here; true when it was this class's request. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val result = pending
        pending = null
        result?.success(granted())
        return true
    }

    companion object {
        private const val PERMISSION_REQUEST = 4721
    }
}
