// The clip pitch editor's model (Lark, 1.1.0; one voice): an audio clip's notes and pitch curve as the engine's C API 42 analysed them, the per-note edits, the editor's work as cancellable jobs, and the render applied as a new take or in place of the clip (one undo step).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'audio_clips.dart';
import 'audio_edit.dart';
import 'freeze.dart';
import 'project.dart';

/// The most notes read from an analysis (the engine's own bound) and the most hops of its curve.
const int kMaxPitchNotes = 100000, kMaxPitchHops = 1 << 22;

/// One note the engine found: a voiced run ([start]..[end] frames of the file), its centre [pitch] (a fractional
/// MIDI note), its slow drift and vibrato, its transitions and level.
@immutable
class PitchNote {
  const PitchNote({required this.index, required this.start, required this.end, required this.pitch,
      this.driftCents = 0, this.vibratoRate = 0, this.vibratoCents = 0, this.transitionInMs = 0,
      this.transitionOutMs = 0, this.gainDb = 0});
  final int index, start, end;
  final double pitch, driftCents, vibratoRate, vibratoCents, transitionInMs, transitionOutMs, gainDb;

  int get length => end - start;
}

double _n(Object? v, double min, double max, [double or = 0]) =>
    v is num && v.isFinite ? v.toDouble().clamp(min, max) : or;

/// An analysed clip: its rate and length, the hop the curve is read at (hop k is centred on frame k × [hopFrames]),
/// the [notes] and, per hop, [midi] (0 when unvoiced), [voicing] (0..1) and [rmsDb].
class PitchAnalysis {
  PitchAnalysis({required this.sampleRate, required this.frames, required this.hopFrames, required this.notes,
      required this.midi, required this.voicing, required this.rmsDb});
  final int sampleRate, frames, hopFrames;
  final List<PitchNote> notes;
  final Float32List midi, voicing, rmsDb;

  int get hops => midi.length;
  double get seconds => sampleRate > 0 ? frames / sampleRate : 0;

  /// The analysis from the engine's untrusted JSON [j] and its curve; null unless it is ok. Every number is bounded
  /// and at most [kMaxPitchNotes] notes are read; notes outside the file or empty are dropped.
  static PitchAnalysis? fromJson(Map<String, dynamic> j, {required Float32List midi, required Float32List voicing,
      required Float32List rmsDb}) {
    if (j['ok'] != true) return null;
    final rate = _n(j['sample_rate'], 0, 192000.0).round(), frames = _n(j['frames'], 0, 1e12).round();
    final hop = _n(j['hop_frames'], 1, 65536, 256).round();
    if (rate < 8000 || frames <= 0) return null;
    final notes = <PitchNote>[];
    final raw = j['notes'];
    if (raw is List) {
      for (final n in raw.take(kMaxPitchNotes)) {
        if (n is! Map) continue;
        final s = _n(n['start'], 0, frames.toDouble()).round(), e = _n(n['end'], 0, frames.toDouble()).round();
        final p = n['pitch'];
        if (e <= s || p is! num || !p.isFinite) continue;
        notes.add(PitchNote(index: notes.length, start: s, end: e, pitch: p.toDouble().clamp(0.0, 127.0),
            driftCents: _n(n['drift_cents'], 0, 1200), vibratoRate: _n(n['vibrato_rate'], 0, 40),
            vibratoCents: _n(n['vibrato_cents'], 0, 1200), transitionInMs: _n(n['transition_in_ms'], 0, 10000),
            transitionOutMs: _n(n['transition_out_ms'], 0, 10000), gainDb: _n(n['gain_db'], -200, 60)));
      }
    }
    return PitchAnalysis(sampleRate: rate, frames: frames, hopFrames: hop, notes: notes, midi: midi, voicing: voicing,
        rmsDb: rmsDb);
  }

  /// The hop nearest [frame], clamped to the curve.
  int hopAt(double frame) => hops == 0 ? 0 : (frame / hopFrames).round().clamp(0, hops - 1);
}

/// One note's edit, as `caw_pitch_clip_render` takes it: [pitch] semitones (−24..24), [drift] (1 keeps the slow
/// wander, 0 flattens it), [vibrato] (the depth's scale, 0..2), [transitionMs] (the ramps at its changes, 0..500),
/// the time move [timeFrames] (at most 10 s either way) and [stretch] (0.25..4).
@immutable
class PitchNoteEdit {
  const PitchNoteEdit({this.pitch = 0, this.drift = 1, this.vibrato = 1, this.transitionMs = 30, this.timeFrames = 0,
      this.stretch = 1});
  final double pitch, drift, vibrato, transitionMs, stretch;
  final int timeFrames;

  static const none = PitchNoteEdit();
  static const double maxPitch = 24, maxVibrato = 2, maxTransitionMs = 500, minStretch = 0.25, maxStretch = 4;

  bool get identity => this == none;

  PitchNoteEdit copyWith({double? pitch, double? drift, double? vibrato, double? transitionMs, int? timeFrames,
          double? stretch}) =>
      PitchNoteEdit(
          pitch: (pitch ?? this.pitch).clamp(-maxPitch, maxPitch),
          drift: (drift ?? this.drift).clamp(0.0, 1.0),
          vibrato: (vibrato ?? this.vibrato).clamp(0.0, maxVibrato),
          transitionMs: (transitionMs ?? this.transitionMs).clamp(0.0, maxTransitionMs),
          timeFrames: timeFrames ?? this.timeFrames,
          stretch: (stretch ?? this.stretch).clamp(minStretch, maxStretch));

  /// The engine's edit of note [note]: only what differs from the defaults.
  Map<String, dynamic> toJson(int note) => {
        'note': note,
        if (pitch != 0) 'pitch': pitch,
        if (drift != 1) 'drift': drift,
        if (vibrato != 1) 'vibrato': vibrato,
        if (transitionMs != 30) 'transition_ms': transitionMs,
        if (timeFrames != 0) 'time_frames': timeFrames,
        if (stretch != 1) 'stretch': stretch,
      };

  @override
  bool operator ==(Object other) => other is PitchNoteEdit && other.pitch == pitch && other.drift == drift &&
      other.vibrato == vibrato && other.transitionMs == transitionMs && other.timeFrames == timeFrames &&
      other.stretch == stretch;

  @override
  int get hashCode => Object.hash(pitch, drift, vibrato, transitionMs, timeFrames, stretch);
}

/// The edits JSON `caw_pitch_clip_render` takes: the notes that differ from their defaults, in order, with a time
/// move bounded to 10 s of [sampleRate].
Map<String, dynamic> pitchEditsJson(Map<int, PitchNoteEdit> edits, {required int sampleRate}) {
  final limit = 10 * sampleRate;
  return {
    'edits': [
      for (final k in edits.keys.toList()..sort())
        if (!edits[k]!.identity) edits[k]!.copyWith(timeFrames: edits[k]!.timeFrames.clamp(-limit, limit)).toJson(k),
    ],
  };
}

/// The offset that puts a note centred on [centre] onto the whole semitone nearest [centre] + [offset] (Snap).
double snapPitchOffset(double centre, double offset) => (centre + offset).roundToDouble() - centre;

const _names = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'];

/// "A4", "C#3": MIDI note [midi] (fractional: the nearest).
String pitchNoteName(double midi) {
  final m = midi.round();
  return '${_names[m % 12]}${m ~/ 12 - 1}';
}

/// "+12 ct", "−3 ct": how far [midi] is from its nearest semitone.
String pitchCentsLabel(double midi) {
  final c = ((midi - midi.roundToDouble()) * 100).round();
  return c == 0 ? '±0 ct' : '${c > 0 ? '+' : '−'}${c.abs()} ct';
}

/// A note's slow drift and its vibrato at each hop of the curve, from the curve's residual around its centre: a
/// moving average over about 0.4 s is the drift, the rest is the vibrato (an estimate for drawing; the engine
/// splits them with its own filters). Unvoiced hops are 0.
({Float32List drift, Float32List vibrato}) pitchResidual(PitchAnalysis a, PitchNote n) {
  final h0 = a.hopAt(n.start.toDouble()), h1 = math.max(h0, a.hopAt(n.end.toDouble()));
  final len = h1 - h0 + 1;
  final res = Float32List(len), drift = Float32List(len), vib = Float32List(len);
  for (var i = 0; i < len; i++) {
    final m = a.midi[h0 + i];
    res[i] = m > 0 ? m - n.pitch : 0;
  }
  final w = math.max(1, (0.2 * a.sampleRate / a.hopFrames).round());
  for (var i = 0; i < len; i++) {
    var sum = 0.0;
    var count = 0;
    for (var k = math.max(0, i - w); k <= math.min(len - 1, i + w); k++) {
      if (a.midi[h0 + k] <= 0) continue;
      sum += res[k];
      count++;
    }
    drift[i] = count == 0 ? 0 : sum / count;
    vib[i] = a.midi[h0 + i] > 0 ? res[i] - drift[i] : 0;
  }
  return (drift: drift, vibrato: vib);
}

// ---------------------------------------------------------------------------------------------------------------
// The work

/// Long editor work (decoding and analysing a clip, rendering it) running off the UI isolate: its [progress] (0..1,
/// null while a step can't tell), what it is doing ([stage]) and [result] (null when cancelled; an error with the
/// engine's reason when it failed). [cancel] stops waiting at once and throws the result away.
class PitchJob<T> {
  PitchJob(Future<T?> Function(PitchJob<T> job) run) {
    result = run(this).then((v) => _cancelled ? null : v);
  }
  final ValueNotifier<double?> progress = ValueNotifier(0);
  final ValueNotifier<String> stage = ValueNotifier('');
  late final Future<T?> result;
  bool _cancelled = false;
  final List<VoidCallback> _onCancel = [];

  bool get cancelled => _cancelled;

  /// Runs [f] when the job is cancelled (a worker's stop flag).
  void whenCancelled(VoidCallback f) => _onCancel.add(f);

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final f in _onCancel) {
      f();
    }
  }

  /// A job that is already done: [value], or [error].
  static PitchJob<T> done<T>(T? value, {Object? error}) =>
      PitchJob<T>((_) => error != null ? Future<T?>.error(error) : Future.value(value));
}

/// Why an analysis or render failed, in a line.
class PitchClipError implements Exception {
  const PitchClipError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// An analysed clip the editor works on: its [analysis] and what the backend keeps for rendering it ([native]).
class PitchClipSession {
  PitchClipSession(this.analysis, {this.channels = 1, this.native});
  final PitchAnalysis analysis;
  final int channels;
  final Object? native;
}

/// A rendered file: where it is and its length.
@immutable
class PitchRenderResult {
  const PitchRenderResult({required this.path, required this.frames, required this.sampleRate, required this.channels,
      this.notesEdited = 0});
  final String path;
  final int frames, sampleRate, channels, notesEdited;
  double get seconds => sampleRate > 0 ? frames / sampleRate : 0;
}

/// What the editor asks of the engine (the C API 42 binding implements it, lib/engine/pitch_clip_engine.dart; tests
/// give a fake): analyse a file, render it with edits into a new file, and let a session go.
abstract interface class PitchClipBackend {
  PitchJob<PitchClipSession> analyse(String path);
  PitchJob<PitchRenderResult> render(PitchClipSession session, Map<int, PitchNoteEdit> edits, String outPath);
  void release(PitchClipSession session);
}

/// The backend the editor uses for [s] (the engine's by default, set by lib/engine/pitch_clip_engine.dart's
/// importer); tests swap in a fake.
PitchClipBackend Function(AppState s)? pitchClipBackendFor;

/// What the render does with its file.
enum PitchRenderTarget { newTake, replace }

/// What a pitch render is called on disk, in the project's audio folder.
const String pitchFilePrefix = 'pitch_';

extension PitchClipEdit on AppState {
  /// Where a render of [clip] goes: a new name in the project's audio folder.
  String pitchRenderPath(AudioClipDoc clip) =>
      '${audioDirectory.path}/$pitchFilePrefix${clip.id}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}.wav';

  /// Puts a render of [clip] into the project, one undo step: a new asset that the clip plays, as a new take (the
  /// old file stays a take to go back to) or in its place (the old file stays in the project, so undo brings it
  /// back). The clip keeps its place, window, fades and loop: the file is the same length. Null when the clip is
  /// gone, its track frozen or the file is not a render of the same length.
  AudioAssetDoc? applyPitchRender(LayerDoc layer, AudioClipDoc clip, PitchRenderResult r,
      {required PitchRenderTarget target}) {
    if (!layer.audioClips.contains(clip) || r.frames <= 0 || guardFrozen(layer)) return null;
    final source = project.asset(clip.assetId);
    final asset = AudioAssetDoc(id: newId('a'), path: r.path, name: '${source?.name ?? audioClipName(clip)} (pitch)',
        bpm: source?.bpm, seconds: r.seconds, channels: r.channels, sourceRate: r.sampleRate);
    endUndoStep();
    editProject((p) {
      p.assets.add(asset);
      if (target == PitchRenderTarget.newTake) {
        if (clip.takes.isEmpty) clip.takes.add(clip.assetId);
        clip.takes.add(asset.id);
        clip.comp = [];
      }
      clip.assetId = asset.id;
    });
    endUndoStep();
    return asset;
  }
}
