// The Android host: thermal and battery-saver signals for the resource adapter, the C++ compiler channel, MIDI
// devices and the Bluetooth MIDI scan, saving exports, the music video's encoder, haptics, the display's refresh rate
// (DisplayRate.kt), the microphone permission and the audio route (AudioRoute.kt).
package com.kmandevr.caw

import android.app.ActivityManager
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
    private var pendingSave: Pair<String, MethodChannel.Result>? = null
    private var bluetoothMidi: BluetoothMidi? = null
    private var pendingFolder: FolderSave? = null
    private var micPermission: MicPermission? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RESOURCE_METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "read") {
                    result.success(readResourceSignals())
                } else if (call.method == "device") {
                    result.success(readDeviceFacts())
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COMPILER_METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                val args = call.argument<List<String>>("args")
                if (call.method == "run" && args != null) {
                    CompilerClient(applicationContext).run(args) { code, output ->
                        result.success(mapOf("code" to code, "output" to output))
                    }
                } else if (call.method == "installToolchain") {
                    // Unpacking takes seconds the first time: off the main thread.
                    val main = android.os.Handler(mainLooper)
                    Thread {
                        try {
                            val dir = ToolchainInstaller.install(applicationContext)
                            main.post { result.success(dir.absolutePath) }
                        } catch (e: Exception) {
                            main.post { result.error("unavailable", e.message, null) }
                        }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }

        // Saving an export: the system picker asks where, then the file is copied there a chunk at a time, so a long
        // WAV never has to fit in memory (#91).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "saveFolder") {
                    // Stems: the system's folder picker, then each file copied into a new document there.
                    val paths = call.argument<List<String>>("paths")
                    val names = call.argument<List<String>>("names")
                    if (paths == null || names == null || paths.size != names.size || pendingSave != null || pendingFolder != null) {
                        result.error("busy", "a save is already open or the files are missing", null)
                        return@setMethodCallHandler
                    }
                    pendingFolder = FolderSave(paths, names, call.argument<String>("mime") ?: "audio/wav", result)
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), SAVE_FOLDER_REQUEST)
                    } catch (e: Exception) {
                        pendingFolder = null
                        result.error("unavailable", e.message, null)
                    }
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val name = call.argument<String>("name")
                if (call.method != "saveCopy" || path == null || name == null || pendingSave != null) {
                    if (pendingSave != null) result.error("busy", "a save is already open", null) else result.notImplemented()
                    return@setMethodCallHandler
                }
                pendingSave = Pair(path, result)
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = call.argument<String>("mime") ?: "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                try {
                    startActivityForResult(intent, SAVE_REQUEST)
                } catch (e: Exception) {
                    pendingSave = null
                    result.error("unavailable", e.message, null)
                }
            }

        // The music video's MP4 encoder: H.264 + AAC with MediaCodec and MediaMuxer (VideoEncoder.kt).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "caw/video").setMethodCallHandler(VideoEncoder())

        // Touch feedback with the vibrator's fine primitives (Haptics.kt).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTICS_METHOD_CHANNEL).setMethodCallHandler(Haptics(this))

        // The screen's refresh rates and the frame-rate setting's request (DisplayRate.kt).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_METHOD_CHANNEL).setMethodCallHandler(DisplayRate(this))

        // RECORD_AUDIO, asked only when audio input is turned on or a track is armed (MicPermission.kt).
        val mic = MicPermission(this)
        micPermission = mic
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS_METHOD_CHANNEL).setMethodCallHandler(mic)

        // MIDI devices (MidiInput.kt) and the in-app Bluetooth LE MIDI scan (BluetoothMidi.kt).
        val midi = MidiInput(applicationContext)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, MIDI_EVENT_CHANNEL).setStreamHandler(midi)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MIDI_METHOD_CHANNEL).setMethodCallHandler(midi)
        // The routed audio devices and their changes, for output latency compensation (AudioRoute.kt).
        val route = AudioRoute(applicationContext)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_ROUTE_EVENT_CHANNEL).setStreamHandler(route)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_ROUTE_METHOD_CHANNEL).setMethodCallHandler(route)
        val bluetooth = BluetoothMidi(this)
        bluetoothMidi = bluetooth
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_EVENT_CHANNEL).setStreamHandler(bluetooth)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_METHOD_CHANNEL).setMethodCallHandler(bluetooth)

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

    // The device facts an anonymous telemetry report carries (docs/app.md "Privacy, telemetry and feedback"): the
    // Android release, total RAM, the SoC model (Android 12+), and the maker's Build.MANUFACTURER and Build.MODEL.
    // Never the device's own name (Settings › About phone), a serial number or a build fingerprint.
    private fun readDeviceFacts(): Map<String, Any?> {
        val memory = ActivityManager.MemoryInfo()
        (getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)?.getMemoryInfo(memory)
        val soc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null
        return mapOf(
            "osRelease" to Build.VERSION.RELEASE,
            "totalMemBytes" to memory.totalMem,
            "socModel" to soc,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
        )
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

    @Deprecated("startActivityForResult keeps this simple; the app has one save at a time")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SAVE_FOLDER_REQUEST) return saveIntoFolder(resultCode, data)
        if (requestCode != SAVE_REQUEST) return super.onActivityResult(requestCode, resultCode, data)
        val (path, result) = pendingSave ?: return
        pendingSave = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) return result.success(null)
        val main = android.os.Handler(mainLooper)
        Thread {
            try {
                java.io.FileInputStream(path).use { input ->
                    val output = contentResolver.openOutputStream(uri, "wt") ?: throw java.io.IOException("cannot open the destination")
                    output.use { input.copyTo(it, 1 shl 16) }
                }
                main.post { result.success(uri.toString()) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message, null) }
            }
        }.start()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (bluetoothMidi?.onPermissionResult(requestCode) == true) return
        if (micPermission?.onPermissionResult(requestCode) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private class FolderSave(val paths: List<String>, val names: List<String>, val mime: String,
                             val result: MethodChannel.Result)

    private fun saveIntoFolder(resultCode: Int, data: Intent?) {
        val save = pendingFolder ?: return
        pendingFolder = null
        val tree = data?.data
        if (resultCode != RESULT_OK || tree == null) return save.result.success(-1)
        val main = android.os.Handler(mainLooper)
        Thread {
            try {
                val parent = android.provider.DocumentsContract.buildDocumentUriUsingTree(
                    tree, android.provider.DocumentsContract.getTreeDocumentId(tree))
                var copied = 0
                for (i in save.paths.indices) {
                    val doc = android.provider.DocumentsContract.createDocument(contentResolver, parent, save.mime, save.names[i])
                        ?: throw java.io.IOException("cannot create " + save.names[i])
                    java.io.FileInputStream(save.paths[i]).use { input ->
                        val output = contentResolver.openOutputStream(doc, "wt") ?: throw java.io.IOException("cannot open " + save.names[i])
                        output.use { input.copyTo(it, 1 shl 16) }
                    }
                    copied++
                }
                main.post { save.result.success(copied) }
            } catch (e: Exception) {
                main.post { save.result.error("failed", e.message, null) }
            }
        }.start()
    }

    override fun onDestroy() {
        stopMonitoring()
        bluetoothMidi?.close()
        bluetoothMidi = null
        super.onDestroy()
    }

    companion object {
        private const val RESOURCE_METHOD_CHANNEL = "caw/resource_signals"
        private const val RESOURCE_EVENT_CHANNEL = "caw/resource_signals/events"
        private const val COMPILER_METHOD_CHANNEL = "caw/compiler"
        private const val MIDI_EVENT_CHANNEL = "caw/midi"
        private const val MIDI_METHOD_CHANNEL = "caw/midi/control"
        private const val BLUETOOTH_EVENT_CHANNEL = "caw/midi/bluetooth/events"
        private const val BLUETOOTH_METHOD_CHANNEL = "caw/midi/bluetooth"
        private const val FILES_METHOD_CHANNEL = "caw/files"
        private const val HAPTICS_METHOD_CHANNEL = "caw/haptics"
        private const val DISPLAY_METHOD_CHANNEL = "caw/display"
        private const val PERMISSIONS_METHOD_CHANNEL = "caw/permissions"
        private const val AUDIO_ROUTE_METHOD_CHANNEL = "caw/audio_route"
        private const val AUDIO_ROUTE_EVENT_CHANNEL = "caw/audio_route/events"
        private const val SAVE_REQUEST = 4711
        private const val SAVE_FOLDER_REQUEST = 4712
    }
}
