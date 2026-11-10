// Plays a MIDI keyboard on a track and records it: notes go to the armed track (else the selected one) as live
// previews; while recording they are captured against the playhead and become a new pattern clip at Stop.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../platform/midi_input.dart';
import 'app_state.dart';
import 'pattern_doc.dart';
import 'project.dart';

/// One captured note, in sixteenth steps of the song.
class TakenNote {
  const TakenNote(this.at, this.len, this.pitch, this.vel);
  final double at, len, pitch, vel;
}

class LiveMidi extends ChangeNotifier {
  /// The app's one instance (main.dart makes it, above the shell, so a theme change doesn't drop the keyboard), for
  /// the transport's Record and the track menu's Record arm.
  static LiveMidi? current;

  LiveMidi(this.state, this.input) {
    final i = input;
    if (i == null) return;
    _subs.add(i.messages.listen(handle));
    _subs.add(i.devices.listen((names) {
      // A keyboard unplugged with keys down sends no note-offs: end every note.
      if (names.length < devices.length) _releaseAll();
      devices = names;
      notifyListeners();
    }));
    state.addListener(_onState);
    state.tick.addListener(_onTick);
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
  final Map<int, (int, double, double)> _held = {};
  final Set<int> _sustained = {};
  bool _sustain = false;
  final List<TakenNote> taken = [];
  double? _recordFrom;
  double _bend = 0;

  // Song time keeps counting across loop wraps while recording: each wrap adds the song's length.
  double _wraps = 0, _lastStep = 0, _lastNow = 0;

  /// The playhead now, in steps since the song's start, counting every pass since recording began.
  double _now() {
    // Stopped, the playhead is where play would resume, or (after Stop) where it last was.
    final step = state.transportOn ? state.playheadStep : state.pausedStep;
    if (step == null) return _lastNow;
    if (recording && step + 1 < _lastStep) _wraps += state.project.engineLoopSteps;
    _lastStep = step;
    return _lastNow = step + _wraps;
  }

  /// The track the keyboard plays: the armed one, else the selected one, else the first track that isn't a folder.
  String? get targetLayerId {
    final layers = state.project.layers;
    String? ok(String? id) => id != null && layers.any((l) => l.id == id && !l.isFolder) ? id : null;
    return ok(armedLayerId) ?? ok(state.selectedLayerId) ?? layers.where((l) => !l.isFolder).firstOrNull?.id;
  }

  /// Arms [layerId] and starts recording (and playback, if stopped); a call while recording stops and keeps the take.
  void toggleRecord([String? layerId]) {
    if (recording) {
      _commit();
      if (state.transportOn) state.togglePlay();
      return;
    }
    final id = layerId ?? targetLayerId;
    if (id == null) return;
    armedLayerId = id;
    taken.clear();
    if (!state.transportOn) state.togglePlay();
    _wraps = 0;
    _lastStep = state.playheadStep;
    _lastNow = _lastStep;
    _recordFrom = _lastStep;
    notifyListeners();
  }

  void handle(MidiMessage m) {
    final layer = targetLayerId;
    if (layer == null) return;
    final now = _now();
    if (m.isNoteOn) {
      _sustained.remove(m.data1); // pressed again: it is held by the key now, not the pedal
      _release(m.data1, now); // a repeated key ends its earlier note
      final id = state.nextPreviewId();
      final vel = m.data2 / 127;
      state.previewOn(layer, id, m.data1 + _bend * 2, vel);
      _held[m.data1] = (id, now, vel);
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
    if (recording && _recordFrom != null) taken.add(TakenNote(h.$2, math.max(0.25, now - h.$2), note.toDouble(), h.$3));
  }

  void _releaseAll() {
    final now = _lastNow;
    for (final n in _held.keys.toList()) {
      _release(n, now);
    }
    _sustained.clear();
  }

  void _onState() {
    if (!state.transportOn && recording) _commit(); // Stop (or a pause) ends the take
  }

  /// Writes the take as new pattern clips on the armed track: one per pass through the song, the first from the bar
  /// where recording began, later ones from the song's start.
  void _commit() {
    final layerId = armedLayerId;
    final from = _recordFrom;
    _releaseAll(); // keys still down end where the playhead last was
    armedLayerId = null;
    _recordFrom = null;
    final notes = List.of(taken);
    taken.clear();
    notifyListeners();
    if (layerId == null || from == null || notes.isEmpty) return;
    final layer = state.project.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return;
    final bar = state.project.stepsPerBar;
    final loop = state.project.engineLoopSteps.toDouble();
    final passes = <int, List<TakenNote>>{};
    for (final n in notes) {
      final pass = (n.at / loop).floor();
      final at = n.at - pass * loop;
      // A note held past the song's end stops there; the next pass starts fresh.
      (passes[pass] ??= []).add(TakenNote(at, math.min(n.len, loop - at), n.pitch, n.vel));
    }
    for (final pass in passes.keys.toList()..sort()) {
      final start = pass == 0 ? (from / bar).floor() * bar : 0;
      final m = takeModule(passes[pass]!, start: start, stepsPerBar: bar, name: _takeName());
      state.editProject((p) => p.modules.add(m));
      state.addClip(layer, m.id, startSteps: start);
    }
  }

  String _takeName() {
    var n = 1;
    while (state.project.modules.any((m) => m.name == 'Take $n')) {
      n++;
    }
    return 'Take $n';
  }

  /// A pattern module holding [notes] (song steps) relative to [start], whole bars long; times on a 1/8-step grid.
  static ModuleDoc takeModule(List<TakenNote> notes, {required int start, required int stepsPerBar, required String name}) {
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
    final bars = math.max(1, (end / stepsPerBar).ceil());
    final span = rel.map((n) => n.end).fold<Steps>(Steps.zero, Steps.max);
    final doc = PatternDoc.blank(name: name, bars: bars).paste(PatternClip(rel, span), Steps.zero).doc;
    return ModuleDoc(id: newId('m'), name: name, source: doc.serialize());
  }

  @override
  void dispose() {
    if (recording) _commit();
    _releaseAll();
    for (final s in _subs) {
      s.cancel();
    }
    if (input != null) {
      state.removeListener(_onState);
      state.tick.removeListener(_onTick);
    }
    super.dispose();
  }
}
