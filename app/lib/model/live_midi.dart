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
  LiveMidi(this.state, this.input) {
    final i = input;
    if (i == null) return;
    _subs.add(i.messages.listen(handle));
    _subs.add(i.devices.listen((names) {
      devices = names;
      notifyListeners();
    }));
    state.addListener(_onState);
  }

  final AppState state;
  final MidiInput? input;
  final _subs = <StreamSubscription<Object?>>[];

  /// The connected devices' names.
  List<String> devices = const [];

  /// The track being recorded into, or null.
  String? armedLayerId;
  bool get recording => armedLayerId != null;

  /// Notes still held: MIDI note number -> (preview id, start step, velocity).
  final Map<int, (int, double, double)> _held = {};
  final Set<int> _sustained = {};
  bool _sustain = false;
  final List<TakenNote> taken = [];
  double? _recordFrom;
  double _bend = 0;

  /// The track the keyboard plays: the armed one, else the selected one, else the first track that isn't a folder.
  String? get targetLayerId {
    final layers = state.project.layers;
    String? ok(String? id) => id != null && layers.any((l) => l.id == id && !l.isFolder) ? id : null;
    return ok(armedLayerId) ?? ok(state.selectedLayerId) ?? layers.where((l) => !l.isFolder).firstOrNull?.id;
  }

  /// Arms [layerId] and starts recording (and playback, if stopped); a second call stops and keeps the take.
  void toggleRecord([String? layerId]) {
    if (recording) {
      if (state.transportOn) state.togglePlay();
      _commit();
      return;
    }
    final id = layerId ?? targetLayerId;
    if (id == null) return;
    armedLayerId = id;
    taken.clear();
    if (!state.transportOn) state.togglePlay();
    _recordFrom = state.playheadStep;
    notifyListeners();
  }

  void handle(MidiMessage m) {
    final layer = targetLayerId;
    if (layer == null) return;
    final now = state.playheadStep;
    if (m.isNoteOn) {
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
    if (recording && _recordFrom != null) {
      final loop = state.project.engineLoopSteps.toDouble();
      // Playback looped back while the key was down: the note runs to the song's end.
      final len = now >= h.$2 ? now - h.$2 : loop - h.$2;
      taken.add(TakenNote(h.$2, math.max(0.25, len), note.toDouble(), h.$3));
    }
  }

  void _onState() {
    // Stop (or a pause) ends the take.
    if (recording && !state.transportOn) _commit();
  }

  /// Writes the take as a new pattern on the armed track, starting at the bar where recording began.
  void _commit() {
    final layerId = armedLayerId;
    final from = _recordFrom;
    armedLayerId = null;
    _recordFrom = null;
    for (final n in _held.keys.toList()) {
      _release(n, state.playheadStep);
    }
    final notes = List.of(taken);
    taken.clear();
    notifyListeners();
    if (layerId == null || from == null || notes.isEmpty) return;
    final layer = state.project.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return;
    final bar = state.project.stepsPerBar;
    final start = (from / bar).floor() * bar;
    final m = takeModule(notes, start: start, stepsPerBar: bar, name: _takeName());
    state.editProject((p) => p.modules.add(m));
    state.addClip(layer, m.id, startSteps: start);
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
    for (final s in _subs) {
      s.cancel();
    }
    if (input != null) state.removeListener(_onState);
    super.dispose();
  }
}
