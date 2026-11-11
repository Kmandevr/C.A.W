// The microphone permission (RECORD_AUDIO) for audio input: asked only when the user turns input on or arms a
// track (docs/app.md, Recording audio), answered over the "caw/permissions" channel.
package com.kmandevr.caw

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MicPermission(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null

    private fun granted(): Boolean =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recordAudioGranted" -> result.success(granted())
            "requestRecordAudio" -> {
                if (granted()) return result.success(true)
                if (pending != null) return result.error("busy", "a permission request is already open", null)
                pending = result
                activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
            }
            else -> result.notImplemented()
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
