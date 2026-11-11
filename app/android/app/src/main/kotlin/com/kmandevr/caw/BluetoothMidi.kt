// Bluetooth LE MIDI from inside the app: scans for MIDI peripherals and opens the one chosen, which then shows up
// in MidiInput as any other device. Asks for the Bluetooth permissions only when the user starts a scan.
package com.kmandevr.caw

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.media.midi.MidiDevice
import android.media.midi.MidiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Methods ("caw/midi/bluetooth"): "scan" {on} starts or stops a 20-second scan; "connect" {address} opens a found
 * device with MidiManager.openBluetoothDevice and keeps it open (closing it is what makes it disappear: Android's
 * MidiManager reference, checked 2026-11-11); "disconnect" {address} closes it.
 * Events: {"found": [{address, name}], "scanning", "connected": [addresses]} after each change, or {"error": code}
 * with code "permission", "off" or "unsupported".
 *
 * Facts (developer.android.com, checked 2026-11-11): the scan filters on the MIDI over Bluetooth LE service UUID
 * 03B80E5A-EDE8-4B33-A751-6CE34EC4C700 (android.media.midi package summary). On Android 12 (API 31) and later
 * BLUETOOTH_SCAN and BLUETOOTH_CONNECT are runtime permissions ("Nearby devices"); the scan is declared
 * neverForLocation, so no location permission is needed there. On Android 11 and earlier a scan needs
 * ACCESS_FINE_LOCATION at run time (Bluetooth permissions page), declared with maxSdkVersion 30.
 */
class BluetoothMidi(private val activity: Activity) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val midi = activity.getSystemService(Context.MIDI_SERVICE) as? MidiManager
    private val found = linkedMapOf<String, String>() // address -> name
    private val connected = mutableMapOf<String, MidiDevice>()
    private val connecting = mutableSetOf<String>()
    private var scanning = false
    private var sink: EventChannel.EventSink? = null
    private var afterPermission: (() -> Unit)? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        send()
    }

    override fun onCancel(arguments: Any?) {
        stopScan()
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scan" -> {
                if (call.argument<Boolean>("on") == true) withPermissions { startScan() } else stopScan()
                result.success(null)
            }
            "connect" -> {
                val address = call.argument<String>("address") ?: return result.error("args", "address", null)
                withPermissions { connect(address) }
                result.success(null)
            }
            "disconnect" -> {
                call.argument<String>("address")?.let { a -> connected.remove(a)?.let { runCatching { it.close() } } }
                send()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun needed(): Array<String> =
        if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun granted(): Boolean =
        needed().all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun withPermissions(then: () -> Unit) {
        if (granted()) return then()
        afterPermission = then
        activity.requestPermissions(needed(), PERMISSION_REQUEST)
    }

    /** MainActivity forwards the answer here; true when it was this class's request. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val then = afterPermission
        afterPermission = null
        if (granted()) then?.invoke() else fail("permission")
        return true
    }

    private val callback = object : ScanCallback() {
        @SuppressLint("MissingPermission") // granted before the scan starts
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val d = result.device ?: return
            val name = runCatching { d.name }.getOrNull() ?: result.scanRecord?.deviceName ?: d.address
            if (found[d.address] == name) return
            found[d.address] = name
            send()
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            fail("unsupported")
        }
    }

    @SuppressLint("MissingPermission") // withPermissions checked them
    private fun startScan() {
        val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            ?: return fail("unsupported")
        if (!adapter.isEnabled) return fail("off")
        val scanner = adapter.bluetoothLeScanner ?: return fail("off")
        if (scanning) return
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(MIDI_SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        runCatching { scanner.startScan(listOf(filter), settings, callback) }.onFailure { return fail("permission") }
        scanning = true
        send()
        main.postDelayed({ stopScan() }, SCAN_MS)
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        if (!scanning) return
        scanning = false
        val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        runCatching { adapter?.bluetoothLeScanner?.stopScan(callback) }
        send()
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String) {
        val m = midi ?: return fail("unsupported")
        val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            ?: return fail("unsupported")
        val device = runCatching { adapter.getRemoteDevice(address) }.getOrNull() ?: return fail("unsupported")
        if (connected.containsKey(address) || !connecting.add(address)) return
        stopScan() // scanning slows a connection down
        send()
        m.openBluetoothDevice(device, { opened ->
            connecting.remove(address)
            // Kept open: MidiInput's device callback then sees it and reads it like a USB device.
            if (opened != null) connected[address] = opened else fail("connect")
            send()
        }, main)
    }

    private fun fail(code: String) {
        main.post { sink?.success(mapOf("error" to code)) }
    }

    private fun send() {
        val event = mapOf(
            "found" to found.map { (a, n) -> mapOf("address" to a, "name" to n) },
            "scanning" to scanning,
            "connected" to connected.keys.toList(),
            "connecting" to connecting.toList(),
        )
        main.post { sink?.success(event) }
    }

    fun close() {
        stopScan()
        connected.values.forEach { runCatching { it.close() } }
        connected.clear()
    }

    companion object {
        private val MIDI_SERVICE: UUID = UUID.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
        private const val SCAN_MS = 20_000L
        const val PERMISSION_REQUEST = 4712
    }
}
