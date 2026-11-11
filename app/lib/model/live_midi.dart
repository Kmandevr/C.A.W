// Plays MIDI devices (and the on-screen keys and pads) on a track and records them: a device's messages go to the
// armed track (else the selected one) through the engine's device input, placed at the frame they were played; the
// on-screen keys as live previews. While recording, after a count-in, notes are captured against the playhead (a
// device's at its own timestamps) and become a new pattern clip at Stop, one take per loop pass, with a "Keep
// take?" undo. Controller learn maps a device's CC to a knob.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../platform/midi_input.dart';
import 'app_state.dart';
import 'device_target.dart';
import 'midi_mapping.dart';
import 'pattern_doc.dart';
import 'project.dart';
import 'settings.dart';

/// What one recording added (for the "Keep take?" toast's Undo): its clip and the take patterns on [layerId].
class RecordedTake {
  const RecordedTake(this.layerId, this.clipIds, this.moduleIds);
  final String layerId;
  final List<String> clipIds, moduleIds;
  int get takes => moduleIds.length;
}

/// One captured note, in sixteenth steps of the song.
class TakenNote {
  const TakenNote(this.at, this.len, this.pitch, this.vel, [this.pass = 0]);
  final double at, len, pitch, vel;

  /// The loop pass it began in (0: the first); [at] counts every pass before it.
  final int pass;
}

class LiveMidi extends ChangeNotifier {
  /// The app's one instance (main.dart makes it, above the shell, so a theme change doesn't drop the keyboard), for
  /// the transport's Record and the track menu's Record arm.
  static LiveMidi? current;

  LiveMidi(this.state, this.input) {
    state.addListener(_onState);
    state.tick.addListener(_onTick);
    state.settings.addListener(_applyMetronome);
    state.settings.addListener(_applyMidiSettings);
    final i = input;
    if (i == null) return;
    _subs.add(i.messages.listen(handle));
    _subs.add(i.devices.listen((names) {
      // A keyboard unplugged with keys down sends no note-offs: end every note.
      if (names.length < devices.length) {
        _releaseAll();
        _releaseDevices();
      }
      devices = names;
      notifyListeners();
    }));
    _subs.add(i.ports.listen((list) {
      ports = list;
      notifyListeners();
    }));
    _closed = {...state.settings.midiClosed};
    i.setClosed(_closed);
  }

  /// Every device the platform sees, open or turned off (Settings › MIDI's list).
  List<MidiPort> ports = const [];

  /// When each device (by name) last sent something, for its activity light; [activity] ticks with it.
  final Map<String, DateTime> lastActivity = {};
  final ValueNotifier<int> activity = ValueNotifier(0);

  void _blink(String source) {
    final now = DateTime.now();
    final last = lastActivity[source];
    lastActivity[source] = now;
    if (last == null || now.difference(last).inMilliseconds > 40) activity.value++;
  }

  Set<String> _closed = {};
  (bool, int)? _midiOptions;

  /// Settings › MIDI: the devices turned off, and MPE and the bend range for the engine.
  void _applyMidiSettings() {
    final s = state.settings;
    if (!_sameSet(s.midiClosed, _closed)) {
      _closed = {...s.midiClosed};
      input?.setClosed(_closed);
    }
    final want = (s.midiMpe, s.midiBendRange);
    final e = state.engine;
    if (e != null && want != _midiOptions) {
      _midiOptions = want;
      e.setMidiOptions(mpe: s.midiMpe, bendRange: s.midiBendRange.toDouble());
    }
  }

  static bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  /// Controller learn: the knob waiting for a device's next CC, or null.
  ({String layerId, int slot, String paramId})? get learning => _learning;
  ({String layerId, int slot, String paramId})? _learning;

  /// The mapping the last learn made (the knob's sheet says so and plays its feedback), or null.
  final ValueNotifier<MidiCcMapping?> learned = ValueNotifier(null);

  /// Waits for a CC from a device to map to [paramId] of the device at [slot] on [layerId]; [cancelLearn] stops.
  void learn(String layerId, int slot, String paramId) {
    _learning = (layerId: layerId, slot: slot, paramId: paramId);
    learned.value = null;
    notifyListeners();
  }

  void cancelLearn() {
    if (_learning == null) return;
    _learning = null;
    notifyListeners();
  }

  /// The CC mapped to that knob, or null.
  MidiCcMapping? mappingOf(String layerId, int slot, String paramId) =>
      state.project.midiMappings.where((m) => m.targets(layerId, slot, paramId)).firstOrNull;

  /// Removes a mapping (one undo step).
  void forget(MidiCcMapping m) {
    state.editProject((p) => p.midiMappings.remove(m));
    notifyListeners();
  }

  final Map<String, Timer> _commits = {};

  /// A device's CC: learnt onto the waiting knob, or moving the knobs mapped to it. True when it was used.
  bool _control(MidiMessage m) {
    if (m.data1 >= 120) return false; // channel mode messages (all notes off, reset) are never a knob
    final l = _learning;
    if (l != null) {
      final made = MidiCcMapping(channel: m.channel, cc: m.data1, layerId: l.layerId, slot: l.slot, paramId: l.paramId);
      state.editProject((p) {
        p.midiMappings.removeWhere((x) => x.targets(l.layerId, l.slot, l.paramId));
        p.midiMappings.add(made);
      });
      _learning = null;
      learned.value = made;
      notifyListeners();
      return true; // the control that was learnt doesn't move the knob yet: the next movement does
    }
    var used = false;
    for (final map in state.project.midiMappings) {
      if (!map.matches(m.channel, m.data1)) continue;
      final t = DeviceTarget(state, map.layerId, map.slot);
      final p = t.param(map.paramId);
      if (p == null) continue;
      used = true;
      t.setLive(p.id, MidiCcMapping.valueFor(p, m.data2));
      // One undo step per movement: saved once the control rests.
      _commits.remove(map.layerId)?.cancel();
      _commits[map.layerId] = Timer(const Duration(milliseconds: 400), () {
        _commits.remove(map.layerId);
        t.commit();
      });
    }
    return used;
  }

  /// The on-screen keys and pads (owner, 2026-11-10): a slide-up panel over the transport.
  bool get keysOpen => _keysOpen;
  bool _keysOpen = false;
  set keysOpen(bool open) {
    if (open == _keysOpen) return;
    _keysOpen = open;
    if (!open) _releaseAll();
    notifyListeners();
  }

  /// The last recording's clip and takes, for the "Keep take?" toast; null once dealt with.
  final ValueNotifier<RecordedTake?> lastTake = ValueNotifier(null);

  /// When the count-in ends (wall clock, for the transport's countdown), or null when none runs.
  DateTime? countInEnds;
  int countInBeats = 0;

  /// The count-in's beats still to come (0 when none runs).
  int get countInLeft {
    final end = countInEnds;
    if (end == null || !recording || state.meters.playing) return 0;
    final ms = end.difference(DateTime.now()).inMilliseconds;
    final beatMs = 60000 / state.project.bpm;
    return ms <= 0 ? 0 : (ms / beatMs).ceil().clamp(0, countInBeats);
  }

  /// A key or pad on screen pressed: a note on at [velocity] (0..1), as a USB keyboard's.
  void keyDown(int note, double velocity) =>
      handle(MidiMessage(0x90, note.clamp(0, 127), (velocity * 127).round().clamp(1, 127)));

  void keyUp(int note) => handle(MidiMessage(0x80, note.clamp(0, 127), 0));

  bool _metronomeOn = false;

  /// The engine's click: always, or while recording (with its count-in), as the Record long-press sets it.
  void _applyMetronome() {
    state.applyAudioSettings(recording: recording);  // Auto's buffer: the small one while recording
    final want = switch (state.settings.metronome) {
      Metronome.off => false,
      Metronome.recording => recording,
      Metronome.always => true,
    };
    if (want == _metronomeOn) return;
    final e = state.engine;
    if (e == null) return;
    _metronomeOn = want;
    e.setMetronome(want);
  }

  void _onTick() {
    if (state.transportOn) _now(); // follow the playhead (and count wraps) between notes
  }

  final AppState state;
  final MidiInput? input;
  final _subs = <StreamSubscription<Object?>>[];

  /// The connected devices' names.
  List<String> devices = const [];

  /// The track being recorded into, or null.
  String? armedLayerId;
  bool get recording => armedLayerId != null;

  /// Notes still held: MIDI note number -> (preview id, start, velocity); starts are song time unwrapped ([_now]).
  final Map<int, (int, double, double, int)> _held = {};
  final Set<int> _sustained = {};
  bool _sustain = false;
  final List<TakenNote> taken = [];
  double? _recordFrom;
  double _bend = 0;

  // Song time keeps counting across loop wraps while recording: each wrap adds the loop's length (the loop range's
  // when one is on, else the song's).
  double _wraps = 0, _lastStep = 0, _lastNow = 0;
  int _pass = 0;

  /// Where playback loops: the loop range when it is on, else the whole song.
  (double, double) get loopSpan {
    final p = state.project;
    return p.loopsRange
        ? (p.loopStartSteps.toDouble(), p.loopEndSteps.toDouble())
        : (0.0, p.engineLoopSteps.toDouble());
  }

  /// The playhead now, in steps since the song's start, counting every pass since recording began.
  double _now() {
    // Stopped, the playhead is where play would resume, or (after Stop) where it last was.
    // During a count-in (and until the engine starts), notes count from where recording begins.
    if (recording && state.transportOn && !state.meters.playing && state.engine != null) {
      return _lastNow = _recordFrom ?? _lastNow;
    }
    final step = state.transportOn ? state.playheadStep : state.pausedStep;
    if (step == null) return _lastNow;
    if (recording && step + 1 < _lastStep) {
      final (from, to) = loopSpan;
      _wraps += to - from;
      _pass++;
    }
    _lastStep = step;
    return _lastNow = step + _wraps;
  }

  /// The track the keyboard plays: the armed one, else the selected one, else the first track that isn't a folder.
  String? get targetLayerId {
    final layers = state.project.layers;
    String? ok(String? id) => id != null && layers.any((l) => l.id == id && !l.isFolder) ? id : null;
    return ok(armedLayerId) ?? ok(state.selectedLayerId) ?? layers.where((l) => !l.isFolder).firstOrNull?.id;
  }

  /// Arms [layerId] and starts recording (and playback, if stopped, after the count-in); a call while recording
  /// stops and keeps the take. With no USB keyboard the on-screen keys open, so Record always has something to play.
  void toggleRecord([String? layerId]) {
    if (recording) {
      _commit();
      if (state.transportOn) state.togglePlay();
      return;
    }
    final id = layerId ?? targetLayerId;
    if (id == null) return;
    if (devices.isEmpty) keysOpen = true;
    armedLayerId = id;
    taken.clear();
    lastTake.value = null;
    final from = state.playheadStep; // where play starts (a pause resumes there)
    var start = from;
    _applyMetronome();
    if (!state.transportOn) {
      // Pre-roll (Settings › Metronome and recording): play starts that many bars earlier, recording at [from].
      final preRoll = state.settings.preRollBars * state.project.stepsPerBar;
      if (preRoll > 0 && from > 0) {
        start = math.max(0.0, from - preRoll);
        state.pausedStep = start; // not seekTo: its notification would end this recording as a Stop does
      }
      countInBeats = state.settings.countInBars * state.project.beatsPerBar;
      state.togglePlay(countInBeats: countInBeats);
      countInEnds = countInBeats > 0 && state.transportOn
          ? DateTime.now().add(Duration(microseconds: (countInBeats * 60e6 / state.project.bpm).round()))
          : null;
    }
    _wraps = 0;
    _pass = 0;
    _lastStep = start;
    _lastNow = start;
    _recordFrom = from;
    notifyListeners();
  }

  /// The toast's Undo: takes the last recording back out (its clip and its take patterns).
  void discardTake() {
    final t = lastTake.value;
    lastTake.value = null;
    if (t == null) return;
    state.editProject((p) {
      for (final l in p.layers) {
        l.clips.removeWhere((c) => t.clipIds.contains(c.id));
      }
      p.modules.removeWhere((m) => t.moduleIds.contains(m.id));
    });
  }


  /// Whether Settings › MIDI lets [m] through: a keyboard other than the chosen one, or a channel other than the
  /// chosen one, is ignored (the on-screen keys always pass).
  bool accepts(MidiMessage m) {
    final s = state.settings;
    if (m.source.isEmpty) return true;
    if (s.midiDevice.isNotEmpty && m.source != s.midiDevice) return false;
    return s.midiChannel == 0 || m.channel == s.midiChannel - 1;
  }

  void handle(MidiMessage m) {
    final words = m.ump;
    if (words != null && m.status == 0) {
      // A UMP batch: each packet on its own, with its MIDI 1.0 view.
      for (final one in MidiMessage.fromUmp(words, m.source, m.timeNs)) {
        handle(one);
      }
      return;
    }
    if (m.status == MidiMessage.perNote) {
      if (!accepts(MidiMessage(0x80 | m.data1, 0, 0, m.source))) return;
      _blink(m.source);
      final to = _deviceTo[m.data1 << 7 | m.data2] ?? (recording || state.settings.midiThru ? targetLayerId : null);
      if (to != null) state.deviceMidi(to, words: words, timeNs: m.timeNs);
      return;
    }
    if (!accepts(m)) return;
    if (m.source.isNotEmpty) {
      _blink(m.source);
      if (m.isControl && _control(m)) return;
    }
    // MIDI thru off: notes sound only on a track being recorded.
    final layer = recording || state.settings.midiThru ? targetLayerId : null;
    if (m.source.isNotEmpty) return _device(m, layer);
    if (layer == null) return;
    final now = _now();
    if (m.isNoteOn) {
      _sustained.remove(m.data1); // pressed again: it is held by the key now, not the pedal
      _release(m.data1, now); // a repeated key ends its earlier note
      final id = state.nextPreviewId();
      // A keyboard's velocity goes through the curve; the on-screen keys have their own (Settings › MIDI).
      final played = m.data2 / 127;
      final vel = m.source.isEmpty ? played : state.settings.velocityCurve.apply(played, state.settings.midiFixedVelocity);
      state.previewOn(layer, id, m.data1 + _bend * 2, vel);
      _held[m.data1] = (id, now, vel, _pass);
    } else if (m.isNoteOff) {
      if (_sustain) {
        _sustained.add(m.data1);
      } else {
        _release(m.data1, now);
      }
    } else if (m.isSustain) {
      _sustain = m.data2 >= 64;
      if (!_sustain) {
        for (final n in _sustained.toList()) {
          _release(n, now);
        }
        _sustained.clear();
      }
    } else if (m.isPitchBend) {
      _bend = m.bend;
      _held.forEach((note, h) => state.previewPitch(h.$1, note + _bend * 2));
    }
  }

  void _release(int note, double now) {
    final h = _held.remove(note);
    if (h == null) return;
    state.previewOff(h.$1);
    _keep(h.$2, now, note.toDouble(), h.$3, h.$4);
  }

  /// A recorded note from [start] to [end] (steps, every pass counted), begun in loop pass [pass].
  void _keep(double start, double end, double pitch, double vel, int pass) {
    final from = _recordFrom;
    if (!recording || from == null) return;
    // Notes begun in the pre-roll (before the record point, on the first pass) are heard, not recorded.
    if (pass == 0 && start < from - 1e-9) return;
    // Written earlier by the recording offset, for the delay between a note and hearing it (Settings › Recording).
    final early = recordOffsetSteps;
    taken.add(TakenNote(start - early, math.max(0.25, end - start), pitch, vel, pass));
  }

  // ---- Devices (caw.h API 11: the engine places each message at the frame it was played) ----

  /// The track each held device key (channel << 7 | key) sounds on: its off, pressure and pedal go there even if
  /// the target changed since.
  final Map<int, String> _deviceTo = {};
  final Map<int, (double, double, int)> _deviceTakes = {}; // key -> (start, velocity, pass) while recording
  final Set<int> _deviceSustained = {};
  final List<bool> _devicePedal = List.filled(16, false);

  /// Where the playhead was when a device message at [timeNs] was played: (steps with every pass counted, pass).
  /// From the engine's position at that time when it knows it; else the playhead now.
  (double, int) _at(int timeNs) {
    final now = _now();
    final countingIn = recording && state.transportOn && !state.meters.playing;
    final exact = countingIn ? null : state.stepAt(timeNs);
    if (exact == null) return (now, _pass);
    final (from, to) = loopSpan;
    final loop = to - from;
    var s = exact, pass = _pass, wraps = _wraps;
    if (loop > 0 && state.meters.playing) {
      if (s >= to) {
        s -= loop; // played after the wrap, before the callback that crossed it reported back
        pass++;
        wraps += loop;
      } else if (s < _lastStep - loop / 2) {
        pass++; // the engine has wrapped; the playhead here has not caught up
        wraps += loop;
      } else if (s > _lastStep + loop / 2 && pass > 0) {
        pass--; // played just before a wrap the playhead here already counted
        wraps -= loop;
      }
    }
    return (s + wraps, pass);
  }

  /// A Note On's velocity through Settings › MIDI's curve (its UMP packet too).
  MidiMessage _curved(MidiMessage m, double vel) {
    final words = m.ump;
    if (words == null) return m.withData2((vel * 127).round().clamp(1, 127));
    final w = [...words];
    if (w[0] >> 28 == 2) {
      w[0] = (w[0] & 0xFFFFFF00) | (vel * 127).round().clamp(1, 127);
    } else if (w.length > 1) {
      w[1] = ((vel * 65535).round().clamp(1, 65535) << 16) | (w[1] & 0xFFFF);
    }
    return MidiMessage(m.status, m.data1, m.data2, m.source, m.timeNs, w);
  }

  void _send(String layer, MidiMessage m) {
    final words = m.ump;
    if (words != null) {
      state.deviceMidi(layer, words: words, timeNs: m.timeNs);
    } else {
      state.deviceMidi(layer, bytes: m.bytes, timeNs: m.timeNs);
    }
  }

  void _device(MidiMessage m, String? layer) {
    final key = m.channel << 7 | m.data1;
    final ch = m.channel;
    if (m.isNoteOn) {
      if (layer == null) return;
      final old = _deviceTo[key];
      if (old != null && old != layer) _send(old, MidiMessage(0x80 | ch, m.data1, 0, m.source, m.timeNs));
      _endTake(key, m.timeNs);
      final words = m.ump;
      // A MIDI 2.0 note's 16-bit velocity goes through the curve at its own resolution.
      final played = words != null && words[0] >> 28 == 4 && words.length > 1 ? (words[1] >> 16) / 65535 : m.data2 / 127;
      final vel = state.settings.velocityCurve.apply(played, state.settings.midiFixedVelocity);
      _send(layer, _curved(m, vel));
      _deviceTo[key] = layer;
      _deviceSustained.remove(key);
      if (recording) {
        final (at, pass) = _at(m.timeNs);
        _deviceTakes[key] = (at, vel, pass);
      }
    } else if (m.isNoteOff) {
      final to = _deviceTo[key] ?? layer;
      if (to == null) return;
      _send(to, m);
      if (_devicePedal[ch] && _deviceTo.containsKey(key)) {
        _deviceSustained.add(key);
      } else {
        _deviceTo.remove(key);
        _endTake(key, m.timeNs);
      }
    } else if (m.isPolyPressure) {
      final to = _deviceTo[key] ?? layer;
      if (to != null) _send(to, m);
    } else if (m.isControl && (m.data1 == 64 || m.data1 == 120 || m.data1 == 123)) {
      // The pedal and all-notes-off reach every track that holds this channel's keys, and the target.
      final on = {for (final e in _deviceTo.entries) if (e.key >> 7 == ch) e.value, ?layer};
      for (final to in on) {
        _send(to, m);
      }
      final up = m.data1 == 64 ? m.data2 < 64 : true;
      if (m.data1 == 64) _devicePedal[ch] = !up;
      if (up) {
        for (final k in _deviceSustained.where((k) => k >> 7 == ch).toList()) {
          _deviceSustained.remove(k);
          _deviceTo.remove(k);
          _endTake(k, m.timeNs);
        }
        if (m.data1 != 64) {
          for (final k in _deviceTo.keys.where((k) => k >> 7 == ch).toList()) {
            _deviceTo.remove(k);
            _endTake(k, m.timeNs);
          }
        }
      }
    } else {
      if (layer == null) return;
      _send(layer, m);
    }
    state.deviceNotesHeld = _deviceTo.length;
  }

  void _endTake(int key, int timeNs) {
    final t = _deviceTakes.remove(key);
    if (t == null) return;
    final (end, _) = _at(timeNs);
    _keep(t.$1, end, (key & 0x7F).toDouble(), t.$2, t.$3);
  }

  /// The device notes recording still holds end where the playhead last was (Stop).
  void _endDeviceTakes() {
    final now = _lastNow;
    for (final e in _deviceTakes.entries.toList()) {
      _keep(e.value.$1, now, (e.key & 0x7F).toDouble(), e.value.$2, e.value.$3);
    }
    _deviceTakes.clear();
  }

  /// A device went away: its keys can never send their offs, so the engine ends them.
  void _releaseDevices() {
    if (_deviceTo.isEmpty) return;
    _endDeviceTakes();
    _deviceTo.clear();
    _deviceSustained.clear();
    _devicePedal.fillRange(0, 16, false);
    state.deviceNotesHeld = 0;
    state.deviceMidiRelease();
  }

  /// Settings › Metronome and recording's offset in sixteenth steps at the project's tempo.
  double get recordOffsetSteps => state.settings.recordOffsetMs / 1000 * state.project.bpm / 15;

  void _releaseAll() {
    final now = _lastNow;
    for (final n in _held.keys.toList()) {
      _release(n, now);
    }
    _sustained.clear();
  }

  void _onState() {
    if (!state.transportOn && recording) _commit(); // Stop (or a pause) ends the take
    _applyMetronome();
    _applyMidiSettings(); // a new engine takes the MIDI options too
  }

  /// Writes the recording on the armed track: one pass is one clip from the bar where recording began; a loop
  /// recording is one clip whose takes are the passes.
  void _commit() {
    final layerId = armedLayerId;
    final from = _recordFrom;
    _releaseAll(); // keys still down end where the playhead last was
    _endDeviceTakes();
    armedLayerId = null;
    _recordFrom = null;
    countInEnds = null;
    final notes = List.of(taken);
    taken.clear();
    _applyMetronome();
    notifyListeners();
    if (layerId == null || from == null || notes.isEmpty) return;
    final layer = state.project.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return;
    final bar = state.project.stepsPerBar;
    final (loopFrom, loopTo) = loopSpan;
    final loop = loopTo - loopFrom;
    final passes = <int, List<TakenNote>>{};
    for (final n in notes) {
      final at = n.at - n.pass * loop;
      // A note held past the loop's end stops there; the next pass starts fresh.
      (passes[n.pass] ??= []).add(TakenNote(at, math.max(0.125, math.min(n.len, loopTo - at)), n.pitch, n.vel));
    }
    final order = passes.keys.toList()..sort();
    int floorBar(double v) => (v / bar).floor() * bar;
    final firstStart = order.first == 0 ? floorBar(from) : floorBar(loopFrom);
    if (order.length == 1) {
      final m = takeModule(passes[order.first]!, start: firstStart, stepsPerBar: bar, name: _takeName());
      state.editProject((p) => p.modules.add(m));
      state.addClip(layer, m.id, startSteps: firstStart);
      final clip = layer.clips.lastOrNull;
      lastTake.value = RecordedTake(layer.id, [?clip?.id], [m.id]);
      return;
    }
    // Loop recording (the loop range, or the whole song): every pass is a take of one clip over the span they
    // share; the newest plays (REAPER's default), and the clip's Takes picker switches.
    final start = math.min(firstStart, floorBar(loopFrom));
    final end = passes.values.expand((n) => n).map((n) => n.at + n.len).fold<double>(loopTo, math.max);
    final bars = math.max(1, ((end - start) / bar).ceil());
    final modules = [
      for (final pass in order) takeModule(passes[pass]!, start: start, stepsPerBar: bar, name: _takeName(order.indexOf(pass)), bars: bars),
    ];
    state.editProject((p) => p.modules.addAll(modules));
    state.addClip(layer, modules.last.id, startSteps: start);
    final clip = layer.clips.lastOrNull;
    if (clip == null || clip.patternId != modules.last.id) return;
    state.editLayer(layer, (_) {
      clip.takes = [for (final m in modules) m.id];
      clip.lengthSteps = bars * bar;
    });
    lastTake.value = RecordedTake(layer.id, [clip.id], [for (final m in modules) m.id]);
  }

  /// "Take 3", the first free number; [skip] more for the later passes of one recording, which aren't added yet.
  String _takeName([int skip = 0]) {
    var n = 1;
    while (state.project.modules.any((m) => m.name == 'Take $n')) {
      n++;
    }
    return 'Take ${n + skip}';
  }

  /// A pattern module holding [notes] (song steps) relative to [start], whole bars long; times on a 1/8-step grid.
  /// At least [bars] long (the takes of one loop recording share a length).
  static ModuleDoc takeModule(List<TakenNote> notes,
      {required int start, required int stepsPerBar, required String name, int bars = 1}) {
    Steps grid(double v) => Steps.fromDouble((v * 8).round() / 8);
    final rel = [
      for (final (i, n) in notes.indexed)
        PatternNote(
          id: i,
          at: grid(math.max(0, n.at - start)),
          len: grid(math.max(0.125, n.len)),
          pitch: n.pitch,
          vel: (n.vel * 1000).round() / 1000,
        ),
    ];
    final end = notes.map((n) => n.at - start + n.len).fold<double>(0, math.max);
    final length = math.max(bars, (end / stepsPerBar).ceil());
    final span = rel.map((n) => n.end).fold<Steps>(Steps.zero, Steps.max);
    final doc = PatternDoc.blank(name: name, bars: length).paste(PatternClip(rel, span), Steps.zero).doc;
    return ModuleDoc(id: newId('m'), name: name, source: doc.serialize());
  }

  @override
  void dispose() {
    if (recording) _commit();
    _releaseAll();
    _releaseDevices();
    for (final t in _commits.values) {
      t.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    state.removeListener(_onState);
    state.tick.removeListener(_onTick);
    state.settings.removeListener(_applyMetronome);
    state.settings.removeListener(_applyMidiSettings);
    lastTake.dispose();
    learned.dispose();
    activity.dispose();
    super.dispose();
  }
}
