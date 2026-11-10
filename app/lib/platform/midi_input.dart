// MIDI keyboard input: Android reads connected devices (MidiInput.kt); other platforms have none yet.
import 'dart:io';

import 'package:flutter/services.dart';

/// One MIDI 1.0 channel message: note on/off, a controller, or pitch bend.
class MidiMessage {
  const MidiMessage(this.status, this.data1, this.data2);
  final int status, data1, data2;

  int get kind => status & 0xF0;
  int get channel => status & 0x0F;
  bool get isNoteOn => kind == 0x90 && data2 > 0;
  bool get isNoteOff => kind == 0x80 || (kind == 0x90 && data2 == 0);
  bool get isSustain => kind == 0xB0 && data1 == 64;
  bool get isPitchBend => kind == 0xE0;

  /// Pitch bend from -1 to 1.
  double get bend => ((data2 << 7 | data1) - 8192) / 8192;
}

abstract class MidiInput {
  /// The messages from every connected device, in arrival order.
  Stream<MidiMessage> get messages;

  /// The names of the connected devices, each time they change.
  Stream<List<String>> get devices;
}

/// The device's MIDI input, or null where the app can't read MIDI yet (desktop: #152).
MidiInput? platformMidiInput() => Platform.isAndroid ? _AndroidMidiInput() : null;

class _AndroidMidiInput implements MidiInput {
  static const _events = EventChannel('caw/midi');
  late final Stream<Object?> _raw = _events.receiveBroadcastStream();

  @override
  Stream<MidiMessage> get messages => _raw.where((e) => e is List && e.length == 3).map((e) {
        final l = e as List;
        return MidiMessage(l[0] as int, l[1] as int, l[2] as int);
      });

  @override
  Stream<List<String>> get devices => _raw
      .where((e) => e is Map && e['devices'] is List)
      .map((e) => [for (final n in (e as Map)['devices'] as List) '$n']);
}
