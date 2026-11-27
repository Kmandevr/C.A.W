// Reads every connected MIDI device (USB, Bluetooth once opened, virtual) and sends what it plays to Dart, each
// message with its time on the device's clock, so the engine places it at the frame it was played (caw.h, API 11);
// while following, the devices' MIDI clock too (API 47).
package com.kmandevr.caw

import android.content.Context
import android.hardware.usb.UsbDevice
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Opens each device's output ports (what a keyboard or pad controller sends) unless Settings › MIDI turned the device
 * off ("setClosed"), and posts to Dart, on the main thread:
 * - each MIDI 1.0 Channel Voice message as [status, data1, data2, device name, time (System.nanoTime ns), device id];
 * - from a Universal MIDI Packet device (Android 13+), {"ump": words, "t": time, "name", "id"};
 * - on any change, {"devices": [{id, name, kind, ump, open}]}.
 * MidiReceiver timestamps use System.nanoTime (developer.android.com MidiReceiver, checked 2026-11-11), the clock the
 * engine's caw_midi_clock_ns reads (CLOCK_MONOTONIC).
 *
 * UMP (developer.android.com android.media.midi "Using MIDI 2.0", checked 2026-11-11): from Android 13 (API 33) a
 * MIDI 2.0 USB device shows a MIDI 1.0 interface (getDevices / TRANSPORT_MIDI_BYTE_STREAM) and a UMP one
 * (TRANSPORT_UNIVERSAL_MIDI_PACKETS); UMP bytes come in network order, 4 to a word. A UMP interface is used only when
 * its default protocol is pre-negotiated (not PROTOCOL_UMP_USE_MIDI_CI or PROTOCOL_UNKNOWN: this app does no MIDI-CI);
 * then the same USB device's MIDI 1.0 interface is left closed, so nothing plays twice.
 */
class MidiInput(context: Context) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {
    private class Open(val device: MidiDevice, val ports: List<MidiOutputPort>)

    private val manager = context.getSystemService(Context.MIDI_SERVICE) as? MidiManager
    private val main = Handler(Looper.getMainLooper())
    private val known = linkedMapOf<Int, MidiDeviceInfo>() // every device seen, open or not
    private val umpIds = mutableSetOf<Int>()               // the ones on the UMP transport
    private val open = mutableMapOf<Int, Open>()
    private val pending = mutableSetOf<Int>() // opening: a removal or close meanwhile closes it on arrival
    private var closedNames = setOf<String>()
    private var sink: EventChannel.EventSink? = null

    private inner class Callback(private val ump: Boolean) : MidiManager.DeviceCallback() {
        // Delivered on the main thread (the handler, or the executor that posts there).
        override fun onDeviceAdded(device: MidiDeviceInfo) {
            add(device, ump)
        }

        override fun onDeviceRemoved(device: MidiDeviceInfo) {
            remove(device.id)
        }
    }

    private val byteCallback = Callback(false)
    private val umpCallback = Callback(true)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val m = manager ?: return sendDevices()
        val executor = java.util.concurrent.Executor { main.post(it) }
        if (Build.VERSION.SDK_INT >= 33) {
            m.registerDeviceCallback(MidiManager.TRANSPORT_MIDI_BYTE_STREAM, executor, byteCallback)
            m.registerDeviceCallback(MidiManager.TRANSPORT_UNIVERSAL_MIDI_PACKETS, executor, umpCallback)
            for (info in m.getDevicesForTransport(MidiManager.TRANSPORT_UNIVERSAL_MIDI_PACKETS)) add(info, true)
            for (info in m.getDevicesForTransport(MidiManager.TRANSPORT_MIDI_BYTE_STREAM)) add(info, false)
        } else {
            @Suppress("DEPRECATION")
            m.registerDeviceCallback(byteCallback, main)
            @Suppress("DEPRECATION")
            for (info in m.devices) add(info, false)
        }
        sendDevices()
    }

    override fun onCancel(arguments: Any?) {
        manager?.unregisterDeviceCallback(byteCallback)
        if (Build.VERSION.SDK_INT >= 33) manager?.unregisterDeviceCallback(umpCallback)
        for (id in open.keys.toList()) close(id)
        known.clear()
        umpIds.clear()
        sink = null
    }

    /**
     * "setClosed" {names}: the devices Settings › MIDI turned off (closed now, opened again when removed).
     * "setClockFollow" {on}: while on, each device's clock bytes (F8, FA, FB, FC, and F2 with its two data bytes) are
     * posted as {"clock": bytes, "t": time, "name"} for the engine's clock follow (caw_engine_midi_clock_in).
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setClosed" -> {
                closedNames = (call.argument<List<String>>("names") ?: emptyList()).toSet()
                refresh()
            }
            "setClockFollow" -> follow = call.argument<Boolean>("on") == true
            else -> return result.notImplemented()
        }
        result.success(null)
    }

    @Volatile private var follow = false

    /** A port's clock bytes from one onSend, posted together. */
    private inner class ClockBatch(private val source: String) {
        private val bytes = ByteArray(48)
        private var n = 0
        fun add(b: Int) {
            if (n < bytes.size) bytes[n++] = b.toByte()
        }
        fun post(timestamp: Long) {
            if (n == 0) return
            val event = mapOf("clock" to bytes.copyOf(n), "t" to timestamp, "name" to source)
            n = 0
            main.post { sink?.success(event) }
        }
    }

    private fun nameOf(info: MidiDeviceInfo): String =
        info.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "MIDI device"

    private fun usbOf(info: MidiDeviceInfo): String? {
        @Suppress("DEPRECATION")
        return (info.properties.getParcelable(MidiDeviceInfo.PROPERTY_USB_DEVICE) as? UsbDevice)?.deviceName
    }

    private fun usbDeviceOf(info: MidiDeviceInfo): UsbDevice? {
        if (info.type != MidiDeviceInfo.TYPE_USB) return null
        @Suppress("DEPRECATION")
        return info.properties.getParcelable(MidiDeviceInfo.PROPERTY_USB_DEVICE) as? UsbDevice
    }

    /** A UMP interface this app can read without MIDI-CI. */
    private fun usableUmp(info: MidiDeviceInfo): Boolean =
        Build.VERSION.SDK_INT >= 33 && info.defaultProtocol != MidiDeviceInfo.PROTOCOL_UMP_USE_MIDI_CI &&
            info.defaultProtocol != MidiDeviceInfo.PROTOCOL_UNKNOWN

    private fun add(info: MidiDeviceInfo, ump: Boolean) {
        if (sink == null || info.outputPortCount == 0) return
        if (ump && !usableUmp(info)) return
        known[info.id] = info
        if (ump) umpIds.add(info.id)
        refresh()
    }

    private fun remove(id: Int) {
        close(id)
        known.remove(id)
        umpIds.remove(id)
        refresh()
    }

    /** Opens what should be open and closes the rest, then tells Dart. */
    private fun refresh() {
        val umpUsb = known.filterKeys { it in umpIds }.values.mapNotNull { usbOf(it) }.toSet()
        for ((id, info) in known) {
            val shadowed = id !in umpIds && usbOf(info)?.let { it in umpUsb } == true
            val want = !shadowed && nameOf(info) !in closedNames
            if (want) openDevice(info) else close(id)
        }
        sendDevices()
    }

    private fun openDevice(info: MidiDeviceInfo) {
        val m = manager ?: return
        if (open.containsKey(info.id) || !pending.add(info.id)) return
        val name = nameOf(info)
        val ump = info.id in umpIds
        m.openDevice(info, { device ->
            val wanted = pending.remove(info.id) && sink != null && known.containsKey(info.id)
            if (device == null) return@openDevice
            if (!wanted) {
                runCatching { device.close() }
                return@openDevice
            }
            val ports = mutableListOf<MidiOutputPort>()
            for (p in info.ports) {
                if (p.type != MidiDeviceInfo.PortInfo.TYPE_OUTPUT) continue
                val port = device.openOutputPort(p.portNumber) ?: continue
                port.connect(if (ump) UmpParser(name, info.id) else Parser(name, info.id))
                ports.add(port)
            }
            open[info.id] = Open(device, ports)
            sendDevices()
        }, main)
    }

    private fun close(id: Int) {
        pending.remove(id)
        open.remove(id)?.let { o ->
            o.ports.forEach { runCatching { it.close() } }
            runCatching { o.device.close() }
        }
    }

    private fun sendDevices() {
        val list = known.values.map { info ->
            mapOf(
                "id" to info.id,
                "name" to nameOf(info),
                "kind" to when (info.type) {
                    MidiDeviceInfo.TYPE_USB -> "usb"
                    MidiDeviceInfo.TYPE_BLUETOOTH -> "bluetooth"
                    else -> "virtual"
                },
                "ump" to (info.id in umpIds),
                // A USB device's vendor and product ids, for the anonymous telemetry's peripherals. Never a name: not
                // the port name (it can be renamed) nor the USB product string (DIY boards let their owner set it).
                "usbVendor" to usbDeviceOf(info)?.vendorId,
                "usbProductId" to usbDeviceOf(info)?.productId,
                "open" to open.containsKey(info.id),
                "off" to (nameOf(info) in closedNames),
            )
        }
        main.post { sink?.success(mapOf("devices" to list)) }
    }

    /** One MIDI 1.0 port's byte stream, with running status; system messages and SysEx are skipped. */
    private inner class Parser(private val source: String, private val id: Int) : MidiReceiver() {
        private var status = 0
        private val data = IntArray(2)
        private var have = 0
        private var sysex = false
        private val clock = ClockBatch(source)
        private var spp = -1 // a Song Position Pointer's data bytes so far (-1: none coming)
        private var sppLow = 0

        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            val following = follow
            for (i in offset until offset + count) {
                val b = msg[i].toInt() and 0xFF
                when {
                    b >= 0xF8 -> { // clock and other real-time bytes may appear anywhere
                        if (following && (b == 0xF8 || b == 0xFA || b == 0xFB || b == 0xFC)) clock.add(b)
                        continue
                    }
                    b == 0xF0 -> { sysex = true; status = 0; spp = -1 }
                    b == 0xF7 -> sysex = false
                    b >= 0x80 -> {
                        sysex = false; status = if (b >= 0xF0) 0 else b; have = 0
                        spp = if (b == 0xF2 && following) 0 else -1
                    }
                    spp >= 0 -> {
                        if (spp == 0) { sppLow = b; spp = 1 } else {
                            clock.add(0xF2); clock.add(sppLow); clock.add(b)
                            spp = -1
                        }
                    }
                    sysex || status == 0 -> continue
                    else -> {
                        data[have++] = b
                        val kind = status and 0xF0
                        val needed = if (kind == 0xC0 || kind == 0xD0) 1 else 2
                        if (have == needed) {
                            have = 0
                            // Every Channel Voice message: notes, poly pressure, controllers, program, channel
                            // pressure and bend.
                            val event = listOf(status, data[0], if (needed == 2) data[1] else 0, source, timestamp, id)
                            main.post { sink?.success(event) }
                        }
                    }
                }
            }
            clock.post(timestamp)
        }
    }

    /** One UMP port: whole packets (network byte order), each sent with its time. */
    private inner class UmpParser(private val source: String, private val id: Int) : MidiReceiver() {
        private val partial = ByteArray(4)
        private var have = 0
        private val words = ArrayList<Long>(16)
        private val clock = ClockBatch(source)
        private var rest = 0 // the current packet's words still to come

        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            val following = follow
            for (i in offset until offset + count) {
                partial[have++] = msg[i]
                if (have < 4) continue
                have = 0
                var w = 0L
                for (k in 0 until 4) w = (w shl 8) or (partial[k].toLong() and 0xFF)
                if (rest > 0) { // a longer packet's later word
                    rest--
                    words.add(w)
                    continue
                }
                val type = (w shr 28).toInt()
                rest = when (type) { 0, 1, 2, 6, 7 -> 0; 3, 4, 8, 9, 10 -> 1; 11, 12 -> 2; else -> 3 }
                // A System message (type 1, one word) carrying the clock: to the follow, not the instrument.
                val st = ((w shr 16) and 0xFF).toInt()
                if (following && type == 1 && (st == 0xF8 || st == 0xFA || st == 0xFB || st == 0xFC || st == 0xF2)) {
                    clock.add(st)
                    if (st == 0xF2) { clock.add(((w shr 8) and 0x7F).toInt()); clock.add((w and 0x7F).toInt()) }
                    continue
                }
                words.add(w)
            }
            clock.post(timestamp)
            if (words.isEmpty()) return
            val event = mapOf("ump" to words.toLongArray(), "t" to timestamp, "name" to source, "id" to id)
            words.clear()
            main.post { sink?.success(event) }
        }
    }
}
