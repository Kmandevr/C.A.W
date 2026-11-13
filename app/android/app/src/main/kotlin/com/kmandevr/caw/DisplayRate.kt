// The display-rate channel: lists the screen's modes and what may limit its rate, and asks for a rate.
package com.kmandevr.caw

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.view.Display
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `info`: {modes: every supported mode [{w, h, hz}], active: the mode now {w, h, hz}, alternatives: the active
 * mode's seamless alternative rates (API 31), current: the rate the display runs at now, powerSave, thermal (API 29,
 * PowerManager.THERMAL_STATUS_*), maker: Build.MANUFACTURER}. Dart (`lib/platform/display_rate.dart`) picks the rates
 * at the active resolution, so that choice is tested there with a fake.
 * `request` {hz}: asks for the mode at the current resolution with the highest rate not above [hz] (the lowest
 * mode when none is), through the window's preferredDisplayModeId and preferredRefreshRate; a rate no mode lists
 * (an alternative) is asked through preferredRefreshRate alone; 0 clears the request, so the system chooses again.
 * Answers {modeId, hz} of the mode asked for (0 and 0 when cleared).
 *
 * Only a request: the system still decides (battery saver, Samsung's Motion smoothness, heat, a higher-priority
 * surface can keep another rate), and the app works at whatever rate the display runs.
 *
 * Sources (Android Developers, read 2026-11-12 and 2026-11-13):
 * - Display.getSupportedModes ("might include synthetic modes"), Display.getMode (API 23), Display.Mode
 *   getPhysicalWidth/Height, getRefreshRate, getAlternativeRefreshRates (API 31; "Presence in this list does not
 *   guarantee a switch"): developer.android.com/reference/android/view/Display and .../Display.Mode
 * - PowerManager.isPowerSaveMode (API 21), getCurrentThermalStatus (API 29), THERMAL_STATUS_SEVERE = 3:
 *   developer.android.com/reference/android/os/PowerManager
 * - WindowManager.LayoutParams.preferredDisplayModeId (API 23) and preferredRefreshRate:
 *   developer.android.com/reference/android/view/WindowManager.LayoutParams
 * - "there is no guarantee that your app will get the frame rate you request"; battery saver can restrict the
 *   rate; "preferredRefreshRate is ignored for Surfaces that use setFrameRate()"; prefer preferredRefreshRate when only
 *   the rate should change: developer.android.com/media/optimize/performance/frame-rate
 * Surface.setFrameRate (API 30) needs Flutter's own Surface, which its embedding does not hand out; the window
 * request covers every surface in the window instead.
 */
class DisplayRate(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private fun display(): Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        activity.display
    } else {
        @Suppress("DEPRECATION")
        activity.windowManager.defaultDisplay
    }

    /** The modes with the current mode's resolution, by rate. */
    private fun modes(d: Display): List<Display.Mode> {
        val now = d.mode
        return d.supportedModes
            .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
            .sortedBy { it.refreshRate }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> {
                val d = display() ?: return result.success(mapOf("modes" to emptyList<Any>()))
                fun m(x: Display.Mode) = mapOf("w" to x.physicalWidth, "h" to x.physicalHeight, "hz" to x.refreshRate.toDouble())
                val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
                val alternatives = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    d.mode.alternativeRefreshRates.map { it.toDouble() }
                } else emptyList()
                val thermal = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) power?.currentThermalStatus ?: 0 else 0
                result.success(mapOf(
                    "modes" to d.supportedModes.map(::m),
                    "active" to m(d.mode),
                    "alternatives" to alternatives,
                    "current" to d.refreshRate.toDouble(),
                    "powerSave" to (power?.isPowerSaveMode ?: false),
                    "thermal" to thermal,
                    "maker" to Build.MANUFACTURER,
                ))
            }
            "request" -> {
                val hz = call.argument<Double>("hz") ?: 0.0
                val window = activity.window ?: return result.error("unavailable", "no window", null)
                val d = display() ?: return result.error("unavailable", "no display", null)
                val attrs = window.attributes
                if (hz <= 0.0) {
                    attrs.preferredDisplayModeId = 0
                    attrs.preferredRefreshRate = 0f
                    window.attributes = attrs
                    return result.success(mapOf("modeId" to 0, "hz" to 0.0))
                }
                val all = modes(d)
                val listed = all.lastOrNull { it.refreshRate <= hz + 0.5 } ?: all.firstOrNull()
                // A rate only the active mode's alternatives list: the rate alone, the system picks the mode.
                val (id, rate) = if (listed == null || Math.abs(listed.refreshRate - hz) > 0.5 && listed.refreshRate < hz) {
                    0 to hz.toFloat()
                } else listed.modeId to listed.refreshRate
                // Unchanged: no new layout pass for the window.
                if (attrs.preferredDisplayModeId != id || attrs.preferredRefreshRate != rate) {
                    attrs.preferredDisplayModeId = id
                    attrs.preferredRefreshRate = rate
                    window.attributes = attrs
                }
                result.success(mapOf("modeId" to id, "hz" to rate.toDouble()))
            }
            else -> result.notImplemented()
        }
    }
}
