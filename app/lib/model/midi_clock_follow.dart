// Following an incoming MIDI clock (engine API 47): the setting turns the engine's follow and the devices' clock
// bytes on together, and passes each device's clock bytes to the engine (caw_engine_midi_clock_in) while it is on.
import '../platform/midi_input.dart';

/// What following needs from the engine (`Engine` implements it).
abstract class MidiClockEngine {
  void setMidiClockFollow(bool on);
  int midiClockIn(List<int> bytes, int timeNs);
}

class MidiClockFollow {
  MidiClockFollow(this.source);

  /// The input whose devices' clock is read, or null where the platform reads none.
  final MidiClockSource? source;
  bool _on = false;
  MidiClockEngine? _engine;
  bool _told = false;

  bool get on => _on;

  /// The setting [on] and the engine now (a new engine is told too). Turning it off tells the old engine as well.
  void apply({required bool on, required MidiClockEngine? engine}) {
    final changed = on != _on || !_told;
    if (changed) source?.setClockFollow(on);
    if (changed || !identical(engine, _engine)) {
      if (!on && !identical(engine, _engine)) _engine?.setMidiClockFollow(false);
      engine?.setMidiClockFollow(on);
    }
    _on = on;
    _engine = engine;
    _told = true;
  }

  /// A device's clock bytes: to the engine while following, else dropped.
  void add(MidiClockBytes b) {
    final e = _engine;
    if (!_on || e == null || b.bytes.isEmpty) return;
    e.midiClockIn(b.bytes, b.timeNs);
  }
}
