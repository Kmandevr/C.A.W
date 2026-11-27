// MIDI out (engine caw.h API 48): lists the devices' input ports, opens the one each engine port (0..15) is routed to,
// and runs the sender thread that takes the engine's due messages through JNI and sends each with its timestamp.
package com.kmandevr.caw

import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** The engine's side of the sender, in libcaw.so (engine/platform/midi_out_android.cpp). */
object MidiOutNative {
    /** 16 bytes a message: port, size, data[3], 3 zero bytes, time (little-endian, System.nanoTime's clock). */
    const val RECORD = 16

    val loaded: Boolean = runCatching { System.loadLibrary("caw") }.isSuccess

    /** The messages due by now + [leadNs] into [buf]; 0 after a short wait with none due; -1 once detached. */
    @JvmStatic external fun poll(buf: ByteArray, leadNs: Long): Int

    /** CC 123 for each channel [port] used, into [buf] (room for 16): for the old device before the port moves. */
    @JvmStatic external fun notesOff(port: Int, buf: ByteArray): Int
}

/**
 * "caw/midi/out" methods: "route" {port, id: "deviceId:portNumber" or null} opens that input port for the engine port
 * (closing what it had, after its CC 123s) and answers whether it opened; "start" starts the sender thread (Dart has
 * just attached the engine with caw_midi_out_start; the thread ends by itself when caw_midi_out_stop or the engine's
 * destruction detaches it); "closeAll". "caw/midi/out/devices" streams [{id, name}] on every change.
 *
 * Timing: caw_midi_clock_ns is std::chrono::steady_clock, CLOCK_MONOTONIC on Android, the clock System.nanoTime and
 * MidiInputPort.send's timestamp use (developer.android.com MidiReceiver, checked 2026-11-11), so a message's time
 * goes on as its timestamp unchanged. The thread hands each one over [LEAD_NS] before its time: a receiver that
 * schedules by timestamp plays it exactly, one that doesn't at most that early.
 */
class MidiOutput(context: Context) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {
    private class Opened(val id: String, val device: MidiDevice, val port: MidiInputPort)

    private val manager = context.getSystemService(Context.MIDI_SERVICE) as? MidiManager
    private val main = Handler(Looper.getMainLooper())
    private val known = linkedMapOf<Int, MidiDeviceInfo>()
    private var sink: EventChannel.EventSink? = null

    // Engine port -> its open input port. Replaced whole on the main thread; the sender thread reads it.
    @Volatile private var ports = arrayOfNulls<MidiInputPort>(16)
    private val opened = arrayOfNulls<Opened>(16)
    private val generation = IntArray(16) // a route's newest request, so a slow open that lost doesn't win
    private val lock = Any()
    private var thread: Thread? = null // under lock
    private var restart = false        // under lock: a start came while the thread was running (or ending)

    private val callback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(device: MidiDeviceInfo) {
            if (device.inputPortCount > 0) known[device.id] = device
            sendDevices()
        }

        override fun onDeviceRemoved(device: MidiDeviceInfo) {
            known.remove(device.id)
            for (p in 0 until 16) if (opened[p]?.id?.substringBefore(':') == device.id.toString()) closePort(p)
            sendDevices()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val m = manager ?: return sendDevices()
        if (Build.VERSION.SDK_INT >= 33) {
            m.registerDeviceCallback(MidiManager.TRANSPORT_MIDI_BYTE_STREAM, java.util.concurrent.Executor { main.post(it) }, callback)
            for (info in m.getDevicesForTransport(MidiManager.TRANSPORT_MIDI_BYTE_STREAM)) {
                if (info.inputPortCount > 0) known[info.id] = info
            }
        } else {
            @Suppress("DEPRECATION")
            m.registerDeviceCallback(callback, main)
            @Suppress("DEPRECATION")
            for (info in m.devices) if (info.inputPortCount > 0) known[info.id] = info
        }
        sendDevices()
    }

    override fun onCancel(arguments: Any?) {
        manager?.unregisterDeviceCallback(callback)
        known.clear()
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "route" -> {
                val port = call.argument<Int>("port") ?: -1
                if (port !in 0 until 16) return result.success(false)
                route(port, call.argument<String>("id"), result)
            }
            "start" -> {
                startThread()
                result.success(MidiOutNative.loaded)
            }
            "closeAll" -> {
                for (p in 0 until 16) closePort(p)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun nameOf(info: MidiDeviceInfo): String =
        info.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "MIDI device"

    private fun sendDevices() {
        val list = mutableListOf<Map<String, Any>>()
        for (info in known.values) {
            val inputs = info.ports.filter { it.type == MidiDeviceInfo.PortInfo.TYPE_INPUT }
            for (p in inputs) {
                // One entry per input port; a device with several names each by its port name, else its number.
                val name = if (inputs.size == 1) nameOf(info)
                else "${nameOf(info)} ${p.name.takeIf { it.isNotBlank() } ?: (p.portNumber + 1).toString()}"
                list.add(mapOf("id" to "${info.id}:${p.portNumber}", "name" to name))
            }
        }
        main.post { sink?.success(list) }
    }

    private fun route(port: Int, id: String?, result: MethodChannel.Result) {
        val gen = ++generation[port]
        if (opened[port]?.id == id && id != null) return result.success(true)
        closePort(port)
        if (id == null) return result.success(true)
        val info = id.substringBefore(':').toIntOrNull()?.let { known[it] }
        val number = id.substringAfter(':', "").toIntOrNull()
        val m = manager
        if (info == null || number == null || m == null) return result.success(false)
        m.openDevice(info, { device ->
            if (device == null) return@openDevice result.success(false)
            val input = if (gen == generation[port]) device.openInputPort(number) else null
            if (input == null) {
                runCatching { device.close() }
                return@openDevice result.success(false)
            }
            opened[port] = Opened(id, device, input)
            ports = ports.copyOf().also { it[port] = input }
            result.success(true)
        }, main)
    }

    /** The port's CC 123s to its old device, then closed. */
    private fun closePort(port: Int) {
        val o = opened[port] ?: return
        opened[port] = null
        ports = ports.copyOf().also { it[port] = null }
        if (MidiOutNative.loaded) {
            val buf = ByteArray(MidiOutNative.RECORD * 16)
            val n = MidiOutNative.notesOff(port, buf)
            for (i in 0 until n) {
                val at = i * MidiOutNative.RECORD
                runCatching { o.port.send(buf, at + 2, buf[at + 1].toInt(), System.nanoTime()) }
            }
        }
        runCatching { o.port.close() }
        runCatching { o.device.close() }
    }

    private fun startThread() {
        if (!MidiOutNative.loaded) return
        synchronized(lock) {
            if (thread != null) {
                restart = true // it may be ending: it polls once more instead
                return
            }
            thread = Thread({ run() }, "caw-midi-out").also { it.start() }
        }
    }

    /** The sender: poll waits in native code while nothing is due; -1 (detached, CC 123s sent) ends it. */
    private fun run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buf = ByteArray(MidiOutNative.RECORD * 64)
        while (true) {
            val n = MidiOutNative.poll(buf, LEAD_NS)
            if (n < 0) {
                synchronized(lock) {
                    if (!restart) {
                        thread = null
                        return
                    }
                    restart = false
                }
                continue
            }
            val now = ports
            for (i in 0 until n) {
                val at = i * MidiOutNative.RECORD
                val target = now[buf[at].toInt() and 0x0F] ?: continue // no device on that port
                var t = 0L
                for (k in 7 downTo 0) t = (t shl 8) or (buf[at + 8 + k].toLong() and 0xFF)
                try {
                    target.send(buf, at + 2, buf[at + 1].toInt(), t)
                } catch (e: java.io.IOException) {
                    // closed meanwhile (the device went): its messages are dropped
                }
            }
        }
    }

    companion object {
        const val LEAD_NS = 1_000_000L
    }
}
