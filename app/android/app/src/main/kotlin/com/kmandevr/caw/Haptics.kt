// The haptics channel: plays the app's semantic touch feedback with the vibrator's fine primitives where it has them.
package com.kmandevr.caw

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.HapticFeedbackConstants
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `play` {kind, scale}: one of tap, tick, grab, drop, threshold, error, at a strength from 0 to 1.
 * `capabilities`: {primitives: whether the composed effects play here}.
 *
 * Sources (Android Developers, read 2026-11-10):
 * - VibrationEffect.Composition (API 30; PRIMITIVE_TICK and PRIMITIVE_CLICK API 30, PRIMITIVE_LOW_TICK API 31; a
 *   scale from 0 to 1): developer.android.com/reference/android/os/VibrationEffect.Composition
 * - Vibrator.areAllPrimitivesSupported (API 30): "If a primitive is not supported by the device, then no vibration
 *   will occur if it is played"; vibrate needs the VIBRATE permission: developer.android.com/reference/android/os/Vibrator
 * - Compositions have no automatic fallback, and a scale of 0 is the minimum perceivable vibration, not off:
 *   developer.android.com/develop/ui/views/haptics/custom-haptic-effects
 * - The fallback constants and their API levels: developer.android.com/reference/android/view/HapticFeedbackConstants
 */
class Haptics(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        (activity.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        activity.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    // Asked once: the answer is the hardware's.
    private val tick = supported(VibrationEffect.Composition.PRIMITIVE_TICK)
    private val click = supported(VibrationEffect.Composition.PRIMITIVE_CLICK)
    private val lowTick = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && supported(VibrationEffect.Composition.PRIMITIVE_LOW_TICK)

    private fun supported(primitive: Int): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && vibrator?.hasVibrator() == true &&
            vibrator.areAllPrimitivesSupported(primitive)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(mapOf("primitives" to (tick && click), "lowTick" to lowTick))
            "play" -> {
                val kind = call.argument<String>("kind") ?: return result.error("args", "no kind", null)
                val scale = (call.argument<Double>("scale") ?: 0.5).toFloat().coerceIn(0f, 1f)
                play(kind, scale)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun play(kind: String, scale: Float) {
        val v = vibrator
        if (v != null && tick && click && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val c = VibrationEffect.startComposition()
            // The fine primitives, light by design: a step is a tick, a press a soft click, a drop a low tick.
            when (kind) {
                "tick" -> c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, scale)
                "tap" -> c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, scale * 0.6f)
                "grab" -> c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, scale)
                "drop" -> if (lowTick) {
                    c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_LOW_TICK, scale)
                } else {
                    c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, scale)
                }
                "threshold" -> c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, scale * 0.7f)
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, scale, 30)
                "error" -> c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, scale)
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, scale, 70)
                else -> return
            }
            val effect = c.compose()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
            } else {
                v.vibrate(effect)
            }
            return
        }
        // No primitives: the system's own touch feedback, which follows the system's touch-feedback setting.
        val sdk = Build.VERSION.SDK_INT
        val constant = when (kind) {
            "tick" -> if (sdk >= 34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK
            "tap" -> HapticFeedbackConstants.VIRTUAL_KEY
            "grab" -> if (sdk >= 34) HapticFeedbackConstants.DRAG_START else HapticFeedbackConstants.LONG_PRESS
            "drop" -> if (sdk >= 30) HapticFeedbackConstants.GESTURE_END else HapticFeedbackConstants.CLOCK_TICK
            "threshold" -> if (sdk >= 34) HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE else HapticFeedbackConstants.CONTEXT_CLICK
            "error" -> if (sdk >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
            else -> return
        }
        activity.window?.decorView?.performHapticFeedback(constant)
    }
}
