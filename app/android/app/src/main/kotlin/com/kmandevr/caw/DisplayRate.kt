// The display-rate channel: lists the screen's refresh rates at its current resolution and asks for one.
package com.kmandevr.caw

import android.app.Activity
import android.os.Build
import android.view.Display
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `rates`: {rates: the refresh rates (Hz, ascending, distinct) of the display modes with the current mode's
 * resolution, current: the rate the display runs at now}.
 * `request` {hz}: asks for the mode at the current resolution with the highest rate not above [hz] (the lowest
 * mode when none is), through the window's preferredDisplayModeId and preferredRefreshRate; 0 clears the request,
 * so the system chooses again. Answers {modeId, hz} of the mode asked for (0 and 0 when cleared).
 *
 * Only a request: the system still decides (battery saver, the user's peak refresh rate, a higher-priority surface
 * can keep another rate), and the app works at whatever rate the display runs.
 *
 * Sources (Android Developers, read 2026-11-12):
 * - Display.getSupportedModes, Display.getMode (API 23), Display.Mode getPhysicalWidth/Height, getRefreshRate:
 *   developer.android.com/reference/android/view/Display
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
            "rates" -> {
                val d = display() ?: return result.success(mapOf("rates" to emptyList<Double>(), "current" to 0.0))
                val rates = modes(d).map { it.refreshRate.toDouble() }.distinctBy { Math.round(it * 10) }
                result.success(mapOf("rates" to rates, "current" to d.refreshRate.toDouble()))
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
                val mode = all.lastOrNull { it.refreshRate <= hz + 0.5 } ?: all.firstOrNull()
                    ?: return result.error("unavailable", "no modes", null)
                // Unchanged: no new layout pass for the window.
                if (attrs.preferredDisplayModeId != mode.modeId || attrs.preferredRefreshRate != mode.refreshRate) {
                    attrs.preferredDisplayModeId = mode.modeId
                    attrs.preferredRefreshRate = mode.refreshRate
                    window.attributes = attrs
                }
                result.success(mapOf("modeId" to mode.modeId, "hz" to mode.refreshRate.toDouble()))
            }
            else -> result.notImplemented()
        }
    }
}
