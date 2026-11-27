// MIDI out to devices (engine API 47's queue, API 48's senders): Android opens devices in MidiOutput.kt and its
// thread sends them the engine's timed messages; Windows opens WinMM ports and the engine's native thread sends.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../engine/bindings.dart';

/// One outbound message from the engine: when it should reach its port, on the engine's MIDI clock
/// (`caw_midi_clock_ns`), which port (0..15, as a MIDI-out layer names it), and its MIDI 1.0 bytes (1..3).
class MidiOutEvent {
  const MidiOutEvent(this.timeNs, this.port, this.bytes);
  final int timeNs;
  final int port;
  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      other is MidiOutEvent &&
      other.timeNs == timeNs &&
      other.port == port &&
      other.bytes.length == bytes.length &&
      Iterable.generate(bytes.length).every((i) => other.bytes[i] == bytes[i]);

  @override
  int get hashCode => Object.hash(timeNs, port, Object.hashAll(bytes));

  @override
  String toString() => 'MidiOutEvent($timeNs, port $port, $bytes)';
}

/// A device output a port can send to: [id] as the platform opens it (Android "device id:port number", Windows the
/// name), [name] as shown and stored in the settings (stable across reconnects, where ids are not).
class MidiOutDevice {
  const MidiOutDevice({required this.id, required this.name});
  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is MidiOutDevice && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// The engine side of a sender (caw.h API 48; `Engine` implements it): attaching starts the engine's queue and, on
/// Windows, the native thread that sends it; detaching ends it with CC 123 on every channel each port used.
abstract class MidiSenderHost {
  bool startMidiSender();
  void stopMidiSender();
}

/// Where the engine's outbound MIDI goes: a map from the engine's ports (0..15) to devices, and a sender attached to
/// an engine. The sending itself is native or the platform's (no per-message call crosses into Dart).
abstract class MidiOutput {
  /// Whether this platform can send at all (false: the no-op output).
  bool get available;

  /// The devices it can send to, each time that changes (and the current ones to a new listener).
  Stream<List<MidiOutDevice>> get devices;

  /// Opens [deviceId] for engine port [port] (0..15; null: closes the port, after CC 123 on the channels it used).
  /// False when the device can't be opened.
  Future<bool> route(int port, String? deviceId);

  /// Attaches the sender to [host]'s engine (one at a time). False when it can't.
  Future<bool> attach(MidiSenderHost host);

  /// Detaches it (the engine queues nothing more; CC 123 goes on the channels used).
  Future<void> detach();

  /// Detaches and closes every device.
  Future<void> close();
}

/// The output where no sender exists: it lists no device.
class NoMidiOutput implements MidiOutput {
  const NoMidiOutput();
  @override
  bool get available => false;
  @override
  Stream<List<MidiOutDevice>> get devices => const Stream.empty();
  @override
  Future<bool> route(int port, String? deviceId) async => deviceId == null;
  @override
  Future<bool> attach(MidiSenderHost host) async => false;
  @override
  Future<void> detach() async {}
  @override
  Future<void> close() async {}
}

/// Android: MidiOutput.kt lists the devices' input ports and opens them ('caw/midi/out'); its thread takes the due
/// messages from the engine through JNI and sends each with its timestamp.
class AndroidMidiOutput implements MidiOutput {
  static const _control = MethodChannel('caw/midi/out');
  static const _events = EventChannel('caw/midi/out/devices');
  MidiSenderHost? _host;

  @override
  bool get available => true;

  @override
  late final Stream<List<MidiOutDevice>> devices = _events.receiveBroadcastStream().map(parseAndroidDevices);

  /// The Kotlin side's list: [{id, name}].
  static List<MidiOutDevice> parseAndroidDevices(Object? e) => [
        if (e is List)
          for (final d in e)
            if (d is Map && d['id'] is String) MidiOutDevice(id: d['id'] as String, name: '${d['name'] ?? 'MIDI device'}'),
      ];

  @override
  Future<bool> route(int port, String? deviceId) async =>
      await _control.invokeMethod<bool>('route', {'port': port, 'id': deviceId}) ?? false;

  @override
  Future<bool> attach(MidiSenderHost host) async {
    if (identical(_host, host)) return true;
    await detach();
    if (!host.startMidiSender()) return false;
    _host = host;
    await _control.invokeMethod<void>('start'); // the thread drains until the detach
    return true;
  }

  @override
  Future<void> detach() async {
    final h = _host;
    _host = null;
    h?.stopMidiSender(); // the thread sends the CC 123s, then ends
  }

  @override
  Future<void> close() async {
    await detach();
    await _control.invokeMethod<void>('closeAll');
  }
}

/// Windows: WinMM's output ports through the engine (caw_midi_out_devices, _open, _close); the engine's native
/// thread sends. WinMM has no plug-in notification: the list is read every two seconds while listened to.
class WindowsMidiOutput implements MidiOutput {
  WindowsMidiOutput([Bindings? b]) : _b = b;
  final Bindings? _b;
  Bindings get _bindings => _b ?? Bindings.instance;
  MidiSenderHost? _host;
  List<MidiOutDevice> _last = const [];
  Timer? _poll;
  late final _list = StreamController<List<MidiOutDevice>>.broadcast(onListen: _startPoll, onCancel: _stopPoll);

  @override
  bool get available => true;

  @override
  Stream<List<MidiOutDevice>> get devices => _list.stream;

  void _startPoll() {
    _read(force: true);
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _read());
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  List<MidiOutDevice> _now() {
    final p = _bindings.midiOutDevices();
    if (p == nullptr) return const [];
    try {
      return parseWindowsDevices(p.toDartString());
    } finally {
      _bindings.free(p);
    }
  }

  /// caw_midi_out_devices' JSON (["name", ...], WinMM's order): the name is the id too.
  static List<MidiOutDevice> parseWindowsDevices(String json) {
    try {
      final l = jsonDecode(json);
      if (l is! List) return const [];
      return [for (final n in l.take(256)) if (n is String) MidiOutDevice(id: n, name: n)];
    } on FormatException {
      return const [];
    }
  }

  void _read({bool force = false}) {
    final now = _now();
    if (!force && _same(now, _last)) return;
    _last = now;
    _list.add(now);
  }

  static bool _same(List<MidiOutDevice> a, List<MidiOutDevice> b) =>
      a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  @override
  Future<bool> route(int port, String? deviceId) async {
    if (port < 0 || port > 15) return false;
    if (deviceId == null) {
      _bindings.midiOutClose(port);
      return true;
    }
    // Opened by its place in today's list (a port's number shifts when another goes).
    final index = _now().indexWhere((d) => d.id == deviceId);
    return index >= 0 && _bindings.midiOutOpen(port, index) == 1;
  }

  @override
  Future<bool> attach(MidiSenderHost host) async {
    if (identical(_host, host)) return true;
    await detach();
    if (!host.startMidiSender()) return false;
    _host = host;
    return true;
  }

  @override
  Future<void> detach() async {
    final h = _host;
    _host = null;
    h?.stopMidiSender();
  }

  @override
  Future<void> close() async {
    await detach();
    for (var p = 0; p < 16; p++) {
      _bindings.midiOutClose(p);
    }
  }
}

/// The platform's MIDI output: Android and Windows send; elsewhere [NoMidiOutput].
MidiOutput platformMidiOutput() {
  if (Platform.isAndroid) return AndroidMidiOutput();
  if (Platform.isWindows) return WindowsMidiOutput();
  return const NoMidiOutput();
}
