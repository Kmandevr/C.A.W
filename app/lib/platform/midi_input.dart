// MIDI devices: Android reads USB, Bluetooth and UMP devices (MidiInput.kt, BluetoothMidi.kt), Windows its MIDI 1.0
// ports through WinMM (midi_input_windows.dart); each message keeps its time on the device clock.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'midi_input_windows.dart';

/// One MIDI message from a device or the on-screen keys: a MIDI 1.0 Channel Voice message ([status], [data1],
/// [data2]), or Universal MIDI Packet [ump] words from a MIDI 2.0 device (then the three are 0).
class MidiMessage {
  const MidiMessage(this.status, this.data1, this.data2, [this.source = '', this.timeNs = 0, this.ump]);
  final int status, data1, data2;

  /// The device it came from (its name); '' for the on-screen keys and pads.
  final String source;

  /// When it was played, on the engine's MIDI clock (`caw_midi_clock_ns`: Android's System.nanoTime); 0: now.
  final int timeNs;

  /// UMP words, when the device speaks UMP (Android 13+): a batch as it arrived ([status] 0), or one packet whose
  /// MIDI 1.0 view the other fields are ([fromUmp]).
  final List<int>? ump;

  /// [status] of a MIDI 2.0 message with no MIDI 1.0 view (per-note pitch and controllers): data1 is its channel,
  /// data2 its key.
  static const perNote = -1;

  int get kind => status & 0xF0;
  int get channel => status & 0x0F;
  bool get isNoteOn => kind == 0x90 && data2 > 0;
  bool get isNoteOff => kind == 0x80 || (kind == 0x90 && data2 == 0);
  bool get isControl => kind == 0xB0;
  bool get isSustain => kind == 0xB0 && data1 == 64;
  bool get isPitchBend => kind == 0xE0;
  bool get isPolyPressure => kind == 0xA0;

  /// Pitch bend from -1 to 1.
  double get bend => ((data2 << 7 | data1) - 8192) / 8192;

  /// The MIDI 1.0 bytes ([status] and the data bytes it carries).
  List<int> get bytes => kind == 0xC0 || kind == 0xD0 ? [status, data1] : [status, data1, data2];

  /// This message with another velocity (a Note On's data2).
  MidiMessage withData2(int v) => MidiMessage(status, data1, v, source, timeNs, ump);

  /// Each UMP packet's Channel Voice message (type 2, or type 4 scaled down to 7 bits) as a message that carries the
  /// packet in [ump]: the app keeps its books (recording, learn, the activity light) on the MIDI 1.0 view, and the
  /// engine gets the packet itself.
  static List<MidiMessage> fromUmp(List<int> words, String source, int timeNs) {
    final out = <MidiMessage>[];
    for (var i = 0; i < words.length;) {
      final w0 = words[i] & 0xFFFFFFFF;
      final type = w0 >> 28;
      final n = switch (type) { 0 || 1 || 2 || 6 || 7 => 1, 3 || 4 || 8 || 9 || 10 => 2, 11 || 12 => 3, _ => 4 };
      if (i + n > words.length) break;
      final status = (w0 >> 16) & 0xFF;
      final packet = [for (var k = 0; k < n; k++) words[i + k] & 0xFFFFFFFF];
      if ((type == 2 || type == 4) && status >= 0x80 && status < 0xF0) {
        if (type == 2) {
          out.add(MidiMessage(status, (w0 >> 8) & 0x7F, w0 & 0x7F, source, timeNs, packet));
        } else if (type == 4) {
          final w1 = words[i + 1] & 0xFFFFFFFF;
          final k = status & 0xF0;
          final d1 = (w0 >> 8) & 0x7F;
          final d2 = w1 >> 25; // the top 7 bits of a 16-bit velocity or a 32-bit value
          if (k == 0xC0) {
            out.add(MidiMessage(status, (w1 >> 24) & 0x7F, 0, source, timeNs, packet));
          } else if (k == 0xD0) {
            out.add(MidiMessage(status, d2, 0, source, timeNs, packet));
          } else if (k == 0xE0) {
            final v14 = w1 >> 18;
            out.add(MidiMessage(status, v14 & 0x7F, v14 >> 7, source, timeNs, packet));
          } else if (k == 0x90 || k == 0x80 || k == 0xA0 || k == 0xB0) {
            // A MIDI 2.0 Note On's velocity can be under 1/128 and is still a note: keep it at least 1.
            out.add(MidiMessage(status, d1, k == 0x90 && d2 == 0 && (w1 >> 16) > 0 ? 1 : d2, source, timeNs, packet));
          }
        }
      } else if (type == 4) {
        // MIDI 2.0's own messages (per-note controllers and pitch, relative controllers): no MIDI 1.0 view, but the
        // instrument hears them.
        out.add(MidiMessage(perNote, status & 0x0F, (w0 >> 8) & 0x7F, source, timeNs, packet));
      }
      i += n;
    }
    return out;
  }
}

/// A MIDI device the platform sees.
class MidiPort {
  const MidiPort({required this.id, required this.name, this.kind = 'usb', this.ump = false, this.open = true, this.off = false});
  final int id;
  final String name;

  /// 'usb', 'bluetooth' or 'virtual' (Android); 'port' on Windows.
  final String kind;

  /// It speaks Universal MIDI Packets (MIDI 2.0).
  final bool ump;

  /// Open and read now; [off] when Settings › MIDI turned it off.
  final bool open, off;
}

/// What the Bluetooth scan has found and connected (Android).
class BluetoothMidiState {
  const BluetoothMidiState({this.found = const [], this.scanning = false, this.connected = const {}, this.connecting = const {}, this.error});
  final List<({String address, String name})> found;
  final bool scanning;
  final Set<String> connected, connecting;

  /// The last problem: 'permission', 'off' (Bluetooth is off), 'unsupported' or 'connect'.
  final String? error;
}

abstract class BluetoothMidi {
  Stream<BluetoothMidiState> get states;
  BluetoothMidiState get state;

  /// Starts (asking for the Nearby devices permission the first time) or stops a scan.
  Future<void> scan(bool on);
  Future<void> connect(String address);
  Future<void> disconnect(String address);
}

abstract class MidiInput {
  /// The messages from every open device, in arrival order.
  Stream<MidiMessage> get messages;

  /// The names of the open devices, each time they change.
  Stream<List<String>> get devices;

  /// Every device seen (open or turned off), each time that changes.
  Stream<List<MidiPort>> get ports;

  /// Closes the devices named here and opens the others (Settings › MIDI's switches).
  void setClosed(Set<String> names);

  /// The in-app Bluetooth LE MIDI scan, where the platform has one.
  BluetoothMidi? get bluetooth;
}

/// The device's MIDI input, or null where the app reads no MIDI. [clock] is the engine's MIDI clock (Windows
/// timestamps are milliseconds from the port's start, put on it).
MidiInput? platformMidiInput({int Function()? clock}) {
  if (Platform.isAndroid) return _AndroidMidiInput();
  if (Platform.isWindows) return WindowsMidiInput(clock ?? () => 0);
  return null;
}

class _AndroidMidiInput implements MidiInput {
  static const _events = EventChannel('caw/midi');
  static const _control = MethodChannel('caw/midi/control');
  late final Stream<Object?> _raw = _events.receiveBroadcastStream();

  @override
  Stream<MidiMessage> get messages => _raw.expand((e) {
        if (e is List && e.length >= 3) {
          final t = e.length > 4 && e[4] is int ? e[4] as int : 0;
          return [MidiMessage(e[0] as int, e[1] as int, e[2] as int, e.length > 3 && e[3] is String ? e[3] as String : '', t)];
        }
        if (e is Map && e['ump'] is List) {
          final words = [for (final w in e['ump'] as List) (w as int) & 0xFFFFFFFF];
          return [MidiMessage(0, 0, 0, '${e['name'] ?? 'MIDI device'}', (e['t'] as int?) ?? 0, words)];
        }
        return const <MidiMessage>[];
      });

  Stream<List<MidiPort>> get _ports => _raw.where((e) => e is Map && e['devices'] is List).map((e) => [
        for (final d in (e as Map)['devices'] as List)
          if (d is Map)
            MidiPort(
              id: (d['id'] as int?) ?? 0,
              name: '${d['name'] ?? 'MIDI device'}',
              kind: '${d['kind'] ?? 'usb'}',
              ump: d['ump'] == true,
              open: d['open'] == true,
              off: d['off'] == true,
            ),
      ]);

  @override
  Stream<List<MidiPort>> get ports => _ports;

  @override
  Stream<List<String>> get devices => _ports.map((l) => [for (final p in l) if (p.open) p.name]);

  @override
  void setClosed(Set<String> names) {
    _control.invokeMethod<void>('setClosed', {'names': names.toList()}).catchError((_) {});
  }

  @override
  late final BluetoothMidi bluetooth = _AndroidBluetoothMidi();
}

class _AndroidBluetoothMidi implements BluetoothMidi {
  _AndroidBluetoothMidi() {
    _events.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      if (e['error'] is String) {
        _state = BluetoothMidiState(found: _state.found, scanning: false, connected: _state.connected,
            connecting: const {}, error: e['error'] as String);
      } else {
        _state = BluetoothMidiState(
          found: [
            for (final d in (e['found'] as List? ?? const []))
              if (d is Map) (address: '${d['address']}', name: '${d['name'] ?? d['address']}'),
          ],
          scanning: e['scanning'] == true,
          connected: {for (final a in (e['connected'] as List? ?? const [])) '$a'},
          connecting: {for (final a in (e['connecting'] as List? ?? const [])) '$a'},
        );
      }
      _out.add(_state);
    });
  }

  static const _events = EventChannel('caw/midi/bluetooth/events');
  static const _methods = MethodChannel('caw/midi/bluetooth');
  final _out = StreamController<BluetoothMidiState>.broadcast();
  BluetoothMidiState _state = const BluetoothMidiState();

  @override
  Stream<BluetoothMidiState> get states => _out.stream;
  @override
  BluetoothMidiState get state => _state;

  @override
  Future<void> scan(bool on) => _methods.invokeMethod<void>('scan', {'on': on}).catchError((_) {});
  @override
  Future<void> connect(String address) => _methods.invokeMethod<void>('connect', {'address': address}).catchError((_) {});
  @override
  Future<void> disconnect(String address) =>
      _methods.invokeMethod<void>('disconnect', {'address': address}).catchError((_) {});
}
