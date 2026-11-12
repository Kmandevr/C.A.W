// The music video's view of a project: tracks, clips, notes unrolled onto the timeline, automation lanes, sections
// and per-bar energy, with the activity queries the auto director asks (what plays, what moves, what is loud).
import 'dart:math' as math;

import 'arrange_edit.dart' show clipNotes;
import 'pattern_doc.dart';
import 'project.dart';

class SceneTrack {
  const SceneTrack({required this.id, required this.name, required this.color, required this.volume,
      required this.pan, required this.devices, this.isFolder = false, this.depth = 0});
  final String id, name;

  /// ARGB, worked out by the caller (the UI's track colours follow the theme and the folder shading).
  final int color;
  final double volume, pan;
  final List<SceneDevice> devices;
  final bool isFolder;
  final int depth;
}

/// A device on a track (its instrument or an insert): its name and parameter values (0..1 where a range is known).
class SceneDevice {
  const SceneDevice({required this.name, required this.params});
  final String name;
  final Map<String, double> params;
}

class SceneClip {
  SceneClip({required this.track, required this.start, required this.end, required this.name, this.audio = false});
  final int track;
  final double start, end;
  final String name;
  final bool audio;

  /// Indexes into [VideoScene.notes], in time order.
  final List<int> notes = [];
  double lowPitch = 127, highPitch = 0;
}

class SceneNote {
  const SceneNote(this.start, this.end, this.pitch, this.vel, this.track, this.clip, [this.expr = NoteExpression.none]);
  final double start, end, pitch, vel;
  final int track, clip;

  /// The note's own pitch bend and vibrato (and pressure and timbre), as the pattern holds them.
  final NoteExpression expr;

  /// Whether its pitch moves (a bend curve or vibrato), so the views draw it as a bent line.
  bool get bends => expr.bend.any((p) => p.v != 0) || expr.vibDepth > 0;

  /// The pitch offset in semitones at [u] 0..1 through the note, at [bpm] (vibrato runs in seconds).
  double bendAt(double u, double bpm) => expr.pitchAt(u, u * (end - start) * 15 / bpm);
}

/// An automation lane in song steps with values scaled 0..1 (by the range the caller knows, else the lane's own).
class SceneLane {
  SceneLane({required this.track, required this.label, required this.device, required List<(double, double)> points})
      : points = [...points]..sort((a, b) => a.$1.compareTo(b.$1));

  /// The track index, or -1 for the master chain.
  final int track;
  final String label;

  /// The device on that track it moves (an index into its [SceneTrack.devices]), or null for the track's own mix.
  final int? device;
  final List<(double, double)> points;

  /// The lane's value at [step] (linear between points, held before the first and after the last).
  double valueAt(double step) {
    if (points.isEmpty) return 0;
    if (step <= points.first.$1) return points.first.$2;
    if (step >= points.last.$1) return points.last.$2;
    var lo = 0, hi = points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (points[mid].$1 <= step) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = points[lo], b = points[hi];
    final span = b.$1 - a.$1;
    return span <= 0 ? b.$2 : a.$2 + (b.$2 - a.$2) * (step - a.$1) / span;
  }

  /// How far the value travels in [a, b): the range of the values it passes through.
  double movement(double a, double b) {
    var lo = valueAt(a), hi = lo;
    final end = valueAt(b);
    lo = math.min(lo, end);
    hi = math.max(hi, end);
    for (final p in points) {
      if (p.$1 > a && p.$1 < b) {
        lo = math.min(lo, p.$2);
        hi = math.max(hi, p.$2);
      }
    }
    return hi - lo;
  }
}

/// A place where the song changes: a marker, a region's edge, several clips starting together, or a drop.
class SceneSection {
  const SceneSection(this.step, this.name, {this.drop = false});
  final double step;
  final String name;
  final bool drop;
}

/// The most notes the scene unrolls (a song longer than this shows its first notes only).
const int kSceneMaxNotes = 200000;

class VideoScene {
  VideoScene({required this.name, required this.bpm, required this.beatsPerBar, required this.endStep,
      required this.tracks, required this.clips, required this.notes, required this.lanes,
      required this.sections, required this.barEnergy});

  final String name;
  final double bpm;
  final int beatsPerBar;
  final double endStep;
  final List<SceneTrack> tracks;
  final List<SceneClip> clips;

  /// Every note on the timeline, sorted by start.
  final List<SceneNote> notes;
  final List<SceneLane> lanes;

  /// Sorted by step, at most one per step.
  final List<SceneSection> sections;

  /// Per bar: the summed velocity of the notes that start in it plus a little for each clip that plays, a stand-in
  /// for loudness the director can use before any audio is rendered (so the preview and the render cut alike).
  final List<double> barEnergy;

  int get stepsPerBar => beatsPerBar * 4;

  /// The longest note, in steps (how far back a view looks for notes still sounding).
  late final double maxNoteSteps = notes.fold(0.0, (m, n) => math.max(m, n.end - n.start));

  /// The lowest and highest pitch the notes of the tracks not in [hidden] (ids) play, bends included; middle C's
  /// octave when there are none.
  (double, double) pitchRange({Set<String> hidden = const {}}) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final n in notes) {
      if (hidden.isNotEmpty && n.track >= 0 && n.track < tracks.length && hidden.contains(tracks[n.track].id)) continue;
      var a = n.pitch, b = n.pitch;
      for (final p in n.expr.bend) {
        a = math.min(a, n.pitch + p.v);
        b = math.max(b, n.pitch + p.v);
      }
      lo = math.min(lo, a - n.expr.vibDepth);
      hi = math.max(hi, b + n.expr.vibDepth);
    }
    return lo.isFinite ? (lo, hi) : (60, 71);
  }

  /// The first index in [notes] starting at or after [step].
  int firstNoteFrom(double step) {
    var lo = 0, hi = notes.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (notes[mid].start < step) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Notes that start in [a, b).
  Iterable<SceneNote> notesStartingIn(double a, double b) sync* {
    for (var i = firstNoteFrom(a); i < notes.length && notes[i].start < b; i++) {
      yield notes[i];
    }
  }

  /// The clip with the most notes starting in [a, b) (on [track] only, when given), or null when none.
  int? busiestClip(double a, double b, {int? track}) {
    final counts = <int, int>{};
    for (final n in notesStartingIn(a, b)) {
      if (track != null && n.track != track) continue;
      counts[n.clip] = (counts[n.clip] ?? 0) + 1;
    }
    int? best;
    var most = 0;
    for (final e in counts.entries) {
      if (e.value > most || (e.value == most && best != null && e.key < best)) {
        best = e.key;
        most = e.value;
      }
    }
    return best;
  }

  /// The mean energy of the bars [a, b) touches, 0..1 of the song's loudest bar.
  double energy(double a, double b) {
    if (barEnergy.isEmpty) return 0;
    final top = barEnergy.reduce(math.max);
    if (top <= 0) return 0;
    final first = (a / stepsPerBar).floor().clamp(0, barEnergy.length - 1);
    final last = ((b - 1e-9) / stepsPerBar).floor().clamp(first, barEnergy.length - 1);
    var sum = 0.0;
    for (var i = first; i <= last; i++) {
      sum += barEnergy[i];
    }
    return sum / (last - first + 1) / top;
  }

  /// The lane that moves most in [a, b) and how far (0..1), or null when nothing moves more than [threshold].
  (int, double)? movingLane(double a, double b, {double threshold = 0.05, int? track}) {
    (int, double)? best;
    for (var i = 0; i < lanes.length; i++) {
      if (track != null && lanes[i].track != track) continue;
      final m = lanes[i].movement(a, b);
      if (m > threshold && (best == null || m > best.$2)) best = (i, m);
    }
    return best;
  }

  /// The section at [step] exactly (within a hundredth of a step), if any.
  SceneSection? sectionAt(double step) {
    for (final s in sections) {
      if ((s.step - step).abs() < 0.01) return s;
      if (s.step > step) break;
    }
    return null;
  }
}

/// Builds the scene from [p]. [colorOf] gives a track's on-screen colour (ARGB); [laneRange] the value range of a
/// project lane when the caller knows it (else the lane's own lowest and highest values make 0..1).
VideoScene buildVideoScene(ProjectDoc p, {required int Function(LayerDoc) colorOf,
    ({double lo, double hi})? Function(ProjectAutomationLaneDoc lane)? laneRange,
    String Function(ComponentUseDoc use)? deviceName,
    ({double lo, double hi})? Function(ComponentUseDoc use, String param)? paramRange}) {
  final layers = p.layers;
  final index = {for (var i = 0; i < layers.length; i++) layers[i].id: i};
  int depthOf(LayerDoc l) {
    var d = 0;
    var parent = l.parentId;
    while (parent != null && d <= layers.length) {
      d++;
      final i = index[parent];
      parent = i == null ? null : layers[i].parentId;
    }
    return d;
  }

  String nameOf(ComponentUseDoc u) => deviceName?.call(u) ?? u.id.split(RegExp(r'[/.:]')).last;
  SceneDevice device(ComponentUseDoc u) => SceneDevice(name: nameOf(u), params: {
        for (final e in u.params.entries)
          e.key: switch (paramRange?.call(u, e.key)) {
            final r? when r.hi > r.lo => ((e.value - r.lo) / (r.hi - r.lo)).clamp(0.0, 1.0).toDouble(),
            _ => e.value,
          },
      });
  final tracks = [
    for (final l in layers)
      SceneTrack(
        id: l.id, name: l.name, color: colorOf(l), volume: l.volume, pan: l.pan, isFolder: l.isFolder, depth: depthOf(l),
        devices: [
          if (l.instrument != null) device(l.instrument!),
          for (final c in l.components) device(c),
        ],
      ),
  ];

  final clips = <SceneClip>[];
  final notes = <SceneNote>[];
  final docs = <String, PatternDoc?>{};
  for (var t = 0; t < layers.length; t++) {
    final l = layers[t];
    for (final c in l.clips) {
      if (c.mute || c.lengthSteps <= 0) continue;
      final m = p.module(c.patternId);
      final clip = SceneClip(track: t, start: c.startSteps.toDouble(), end: (c.startSteps + c.lengthSteps).toDouble(),
          name: c.name ?? m?.name ?? 'Clip');
      final ci = clips.length;
      clips.add(clip);
      if (m == null) continue;
      final doc = docs.putIfAbsent(m.id, () => PatternDoc.parse(m.source).doc ?? PatternDoc.parse(m.runSource).doc);
      if (doc == null || doc.notes.isEmpty) continue;
      // The notes as the engine plays them (#183): the source window from the offset, wrapping to the pattern's
      // start while the clip loops, a note already sounding at the window's start kept from there, and notes cut at
      // the window's edges. The same rule the arranger draws and edits with ([clipNotes]).
      final played = clipNotes(doc, c, p.beatsPerBar, limit: kSceneMaxNotes - notes.length);
      if (played == null) continue;
      for (final n in played) {
        final s = clip.start + n.at.toDouble();
        final e = math.min(clip.end, s + n.len.toDouble());
        if (e <= s) continue;
        notes.add(SceneNote(s, e, n.pitch, n.vel, t, ci, n.expr));
        clip.lowPitch = math.min(clip.lowPitch, n.pitch);
        clip.highPitch = math.max(clip.highPitch, n.pitch);
      }
    }
    for (final a in l.audioClips) {
      if (a.mute) continue;
      clips.add(SceneClip(track: t, start: a.startSteps, end: a.startSteps + a.lengthAt(p.bpm), name: 'Audio', audio: true));
    }
  }
  notes.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.pitch.compareTo(b.pitch);
  });
  for (var i = 0; i < notes.length; i++) {
    clips[notes[i].clip].notes.add(i);
  }

  // Lanes: project lanes (an instrument's or a component's parameter) and each track's own lanes (volume, pan, ...).
  List<(double, double)> scaled(List<AutomationPointDoc> pts, ({double lo, double hi})? range) {
    if (pts.isEmpty) return const [];
    var lo = range?.lo, hi = range?.hi;
    if (lo == null || hi == null || hi <= lo) {
      lo = pts.map((x) => x.value).reduce(math.min);
      hi = pts.map((x) => x.value).reduce(math.max);
    }
    final span = hi - lo;
    return [for (final x in pts) (x.step, span <= 0 ? 0.5 : ((x.value - lo) / span).clamp(0.0, 1.0).toDouble())];
  }

  final lanes = <SceneLane>[];
  for (final a in p.automation) {
    if (a.points.length < 2) continue;
    final t = a.layerId == null ? -1 : (index[a.layerId] ?? -2);
    if (t == -2) continue;
    int? device;
    if (t >= 0) {
      final l = layers[t];
      device = a.targetType == 'instrument'
          ? (l.instrument != null ? 0 : null)
          : (a.component != null && a.component! < l.components.length ? a.component! + (l.instrument != null ? 1 : 0) : null);
    }
    lanes.add(SceneLane(track: t, label: a.target, device: device, points: scaled(a.points, laneRange?.call(a))));
  }
  for (var t = 0; t < layers.length; t++) {
    for (final a in layers[t].automation) {
      if (a.points.length < 2) continue;
      final range = switch (a.target) { 'volume' => (lo: 0.0, hi: 1.0), 'pan' => (lo: -1.0, hi: 1.0), _ => null };
      lanes.add(SceneLane(track: t, label: a.target, device: null, points: scaled(a.points, range)));
    }
  }

  final spb = p.stepsPerBar;
  final end = math.max(p.engineLoopSteps.toDouble(), spb.toDouble());
  final bars = (end / spb).ceil();
  final energy = List<double>.filled(bars, 0);
  for (final n in notes) {
    final b = (n.start / spb).floor();
    if (b >= 0 && b < bars) energy[b] += n.vel;
  }
  for (final c in clips) {
    final b0 = (c.start / spb).floor().clamp(0, bars), b1 = (c.end / spb).ceil().clamp(0, bars);
    for (var b = b0; b < b1; b++) {
      energy[b] += c.audio ? 1.0 : 0.25;
    }
  }

  // Sections: markers and region edges, bars where two or more clips start, and drops (a bar with at least
  // 1.8 times the energy of the one before and at least the song's median).
  final found = <double, SceneSection>{};
  for (final m in p.markers) {
    found[m.startSteps.toDouble()] = SceneSection(m.startSteps.toDouble(), m.name);
    if (m.endSteps != null) found.putIfAbsent(m.endSteps!.toDouble(), () => SceneSection(m.endSteps!.toDouble(), ''));
  }
  final starts = <double, int>{};
  for (final c in clips) {
    if (c.start % spb == 0) starts[c.start] = (starts[c.start] ?? 0) + 1;
  }
  for (final e in starts.entries) {
    if (e.value >= 2 && e.key > 0) found.putIfAbsent(e.key, () => SceneSection(e.key, ''));
  }
  if (bars > 2) {
    final sorted = [...energy]..sort();
    final median = sorted[sorted.length ~/ 2];
    for (var b = 1; b < bars; b++) {
      if (energy[b] >= median && energy[b] >= 1.8 * energy[b - 1] && energy[b] > 0) {
        final s = (b * spb).toDouble();
        found[s] = SceneSection(s, found[s]?.name ?? '', drop: true);
      }
    }
  }
  final sections = found.values.toList()..sort((a, b) => a.step.compareTo(b.step));

  return VideoScene(name: p.name, bpm: p.bpm, beatsPerBar: p.beatsPerBar, endStep: end, tracks: tracks, clips: clips,
      notes: notes, lanes: lanes, sections: sections, barEnergy: energy);
}
