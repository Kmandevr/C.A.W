// Android thermal and battery-saver signals exposed to the shared Flutter resource adapter.
package com.kmandevr.caw

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var eventSink: EventChannel.EventSink? = null
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private var powerSaveReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RESOURCE_METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "read") {
                    result.success(readResourceSignals())
                } else {
                    result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, RESOURCE_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    startMonitoring(events)
                }

                override fun onCancel(arguments: Any?) {
                    stopMonitoring()
                }
            })
    }

    private fun readResourceSignals(): Map<String, Any?> {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            power?.currentThermalStatus
        } else {
            null
        }
        return mapOf(
            "thermalStatus" to thermalStatus,
            "batterySaver" to power?.isPowerSaveMode,
        )
    }

    private fun startMonitoring(sink: EventChannel.EventSink) {
        stopMonitoring()
        eventSink = sink
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && power != null) {
            val listener = PowerManager.OnThermalStatusChangedListener { emitResourceSignals() }
            power.addThermalStatusListener(listener)
            thermalListener = listener
        }

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                emitResourceSignals()
            }
        }
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, filter)
        }
        powerSaveReceiver = receiver
        emitResourceSignals()
    }

    private fun emitResourceSignals() {
        eventSink?.success(readResourceSignals())
    }

    private fun stopMonitoring() {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        thermalListener?.let { listener ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                power?.removeThermalStatusListener(listener)
            }
        }
        thermalListener = null
        powerSaveReceiver?.let { receiver ->
            try {
                unregisterReceiver(receiver)
            } catch (_: IllegalArgumentException) {
                // It may already have been unregistered during Activity teardown.
            }
        }
        powerSaveReceiver = null
        eventSink = null
    }

    override fun onDestroy() {
        stopMonitoring()
        super.onDestroy()
    }

    companion object {
        private const val RESOURCE_METHOD_CHANNEL = "caw/resource_signals"
        private const val RESOURCE_EVENT_CHANNEL = "caw/resource_signals/events"
    }
}
