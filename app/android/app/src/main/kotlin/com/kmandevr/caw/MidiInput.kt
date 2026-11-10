// Reads every connected MIDI keyboard (USB, or Bluetooth once paired in Android) and sends its notes to Dart.
package com.kmandevr.caw

import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Opens each device's output ports (what the keyboard sends) and posts note on/off, controller and pitch-bend
 * messages as [status, data1, data2] lists; a device change posts {"devices": [names]}. Everything reaches Dart on the
 * main thread. Bluetooth MIDI devices appear here once Android has connected them.
 */
class MidiInput(context: Context) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(Context.MIDI_SERVICE) as? MidiManager
    private val main = Handler(Looper.getMainLooper())
    private val devices = mutableMapOf<Int, Pair<MidiDevice, String>>()
    private val ports = mutableMapOf<Int, MutableList<MidiOutputPort>>()
    private val pending = mutableSetOf<Int>() // opening: a removal or cancel meanwhile closes it on arrival
    private var sink: EventChannel.EventSink? = null

    private val callback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(device: MidiDeviceInfo) = open(device)
        override fun onDeviceRemoved(device: MidiDeviceInfo) {
            close(device.id)
            sendDevices()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val m = manager ?: return sendDevices()
        m.registerDeviceCallback(callback, main)
        @Suppress("DEPRECATION")
        for (info in m.devices) open(info)
        sendDevices()
    }

    override fun onCancel(arguments: Any?) {
        manager?.unregisterDeviceCallback(callback)
        for (id in devices.keys.toList()) close(id)
        sink = null
    }

    private fun open(info: MidiDeviceInfo) {
        val m = manager ?: return
        if (info.outputPortCount == 0 || devices.containsKey(info.id) || !pending.add(info.id)) return
        val name = info.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "MIDI device"
        m.openDevice(info, { device ->
            val wanted = pending.remove(info.id) && sink != null
            if (device == null) return@openDevice
            if (!wanted) {
                runCatching { device.close() }
                return@openDevice
            }
            devices[info.id] = device to name
            val opened = mutableListOf<MidiOutputPort>()
            for (p in info.ports) {
                if (p.type != MidiDeviceInfo.PortInfo.TYPE_OUTPUT) continue
                val port = device.openOutputPort(p.portNumber) ?: continue
                port.connect(Parser())
                opened.add(port)
            }
            ports[info.id] = opened
            sendDevices()
        }, main)
    }

    private fun close(id: Int) {
        pending.remove(id)
        ports.remove(id)?.forEach { runCatching { it.close() } }
        devices.remove(id)?.first?.let { runCatching { it.close() } }
    }

    private fun sendDevices() {
        val names = devices.values.map { it.second }
        main.post { sink?.success(mapOf("devices" to names)) }
    }

    /** One port's byte stream, with running status; system messages and SysEx are skipped. */
    private inner class Parser : MidiReceiver() {
        private var status = 0
        private val data = IntArray(2)
        private var have = 0
        private var sysex = false

        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            for (i in offset until offset + count) {
                val b = msg[i].toInt() and 0xFF
                when {
                    b >= 0xF8 -> continue // clock and other real-time bytes may appear anywhere
                    b == 0xF0 -> { sysex = true; status = 0 }
                    b == 0xF7 -> sysex = false
                    b >= 0x80 -> { sysex = false; status = if (b >= 0xF0) 0 else b; have = 0 }
                    sysex || status == 0 -> continue
                    else -> {
                        data[have++] = b
                        val kind = status and 0xF0
                        val needed = if (kind == 0xC0 || kind == 0xD0) 1 else 2
                        if (have == needed) {
                            have = 0
                            if (kind == 0x80 || kind == 0x90 || kind == 0xB0 || kind == 0xE0) {
                                val event = listOf(status, data[0], if (needed == 2) data[1] else 0)
                                main.post { sink?.success(event) }
                            }
                        }
                    }
                }
            }
        }
    }
}
