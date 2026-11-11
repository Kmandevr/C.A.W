// Note clips to and from Standard MIDI Files: a .mid's tracks (or channels) become pattern clips in the project, and
// a clip's notes, with their per-note bend, pressure and timbre, become a .mid (lib/model/midi_file.dart writes it),
// with its track's automation lanes over the clip as controller changes (CC7 volume, CC10 pan, CC20 up for others).
//
// Clips stay stored as C.A.W.'s pattern text (docs/decisions.md "MIDI files are an import and export format").
// Times convert by ticks per quarter note (one 16th step is a quarter of a quarter note), so a file's notes keep their
// beats whatever the tempo; the file's first tempo and meter are applied only to a project with no clips yet.
import 'dart:math' as math;
import 'dart:typed_data';

import 'app_state.dart';
import 'midi_file.dart';
import 'pattern_doc.dart';
import 'project.dart';

/// One clip's worth of notes read from a file, as pattern text.
class MidiClipSource {
  const MidiClipSource(this.name, this.source, this.notes);
  final String name;
  final String source; // a `kind: pattern` module
  final int notes;
}

/// What [midiImport] read from a file.
class MidiImport {
  const MidiImport({required this.clips, this.bpm, this.beatsPerBar, this.tempoChanges = false, this.name = 'MIDI'});
  final List<MidiClipSource> clips; // in file order; empty when the file has no notes
  final String name; // the file's name without its extension
  final double? bpm; // the file's first tempo
  final int? beatsPerBar; // the file's first meter in quarter notes per bar, when it is a whole number 1..16
  final bool tempoChanges; // the file changes tempo (only the first one can apply)

  int get noteCount => clips.fold(0, (n, c) => n + c.notes);
}

/// Quarter notes per bar in [f]'s first meter (6/8 is 3), when it is a whole number from 1 to 16.
int? beatsPerBarOf(MidiFile f) {
  final n = f.meterNumerator, d = f.meterDenominator;
  if (n == null || d == null) return null;
  final q = n * 4 / d;
  return q == q.roundToDouble() && q >= 1 && q <= 16 ? q.toInt() : null;
}

/// Reads a Standard MIDI File as pattern clips: one per track that has notes (a format 0 file's one track, or each
/// track of a format 1 or 2 file), split by channel where a track uses several, except in an MPE file, where a track's
/// channels carry one part together. Pattern lengths are whole bars of [beatsPerBar] (the file's own meter when
/// [adoptMeter] and it has one). Throws a [MidiFileException] for a file it can't read. Pure, so it can run on
/// another isolate.
MidiImport midiImport(Uint8List bytes, {required int beatsPerBar, bool adoptMeter = false, String name = 'MIDI'}) {
  final f = readMidiFile(bytes);
  final meter = beatsPerBarOf(f);
  final bar = (adoptMeter && meter != null ? meter : beatsPerBar).clamp(1, 16) * 4;
  final groups = <({int track, int? channel, String name, List<MidiNote> notes})>[];
  for (final (i, t) in f.tracks.indexed) {
    if (t.notes.isEmpty) continue;
    final channels = {for (final n in t.notes) n.channel}.toList()..sort();
    final label = t.name.isNotEmpty ? t.name : '$name ${i + 1}';
    if (f.mpe || channels.length == 1) {
      groups.add((track: i, channel: null, name: label, notes: t.notes));
    } else {
      for (final c in channels) {
        groups.add((track: i, channel: c, name: '$label · ch ${c + 1}', notes: [for (final n in t.notes) if (n.channel == c) n]));
      }
    }
  }
  final single = groups.length == 1 && f.tracks.where((t) => t.notes.isNotEmpty).single.name.isEmpty;
  return MidiImport(
    clips: [
      for (final g in groups) MidiClipSource(single ? name : g.name, _patternText(g.notes, f.ppq, bar, single ? name : g.name), g.notes.length),
    ],
    bpm: f.firstBpm,
    beatsPerBar: meter,
    tempoChanges: f.tempoChanges,
    name: name,
  );
}

double _round(double v, int places) {
  final s = math.pow(10, places);
  return (v * s).round() / s;
}

String _patternText(List<MidiNote> notes, int ppq, int bar, String name) {
  Steps steps(int tick) => Steps(tick * 4, ppq);
  final out = <PatternNote>[];
  for (final (i, n) in notes.indexed) {
    final at = steps(n.on), end = steps(n.off);
    if (end > Steps(kPatternMaxSteps)) throw const MidiFileException('the notes run past the longest pattern C.A.W. holds');
    final start = n.bend.isNotEmpty && n.bend.first.tick <= n.on ? n.bend.first.value : 0.0;
    final span = math.max(1, n.off - n.on), gap = math.max(1, ppq ~/ 16);
    final bend = n.bend.length > 1 ? _curve(n.bend, n.on, span, gap, start, 0.01, -NoteExpression.maxBend, NoteExpression.maxBend) : const <NotePoint>[];
    out.add(PatternNote(
      id: i,
      at: at,
      len: Steps.max(end - at, kMinNoteLength),
      pitch: _round((n.key + start).clamp(0, 127).toDouble(), 3),
      vel: _round(n.velocity / 127, 3),
      expr: NoteExpression(
        bend: bend.every((p) => p.v == 0) ? const [] : bend,
        press: _curve(n.pressure, n.on, span, gap, 0, 0.005, 0, 1),
        timbre: _curve(n.timbre, n.on, span, gap, 0, 0.005, 0, 1),
      ),
    ));
  }
  out.sort((a, b) => a.at != b.at ? a.at.compareTo(b.at) : a.pitch.compareTo(b.pitch));
  final last = out.fold(Steps.zero, (m, n) => Steps.max(m, n.end));
  final bars = math.max(1, (last / Steps(bar)).ceil()).clamp(1, kPatternMaxBars);
  final doc = PatternDoc.blank(name: name, bars: bars).paste(PatternClip(out, last), Steps.zero).doc;
  return doc.serialize();
}

/// A note's MIDI values as a pattern curve through it: times 0..1, values less [offset] within [lo]..[hi]. MIDI holds
/// a value until the next, so a change after a long gap (more than [gap] ticks) keeps the old value up to it; closely
/// spaced changes (a sampled curve) are joined. Points within [tolerance] of a straight line are dropped.
List<NotePoint> _curve(List<MidiPoint> pts, int on, int span, int gap, double offset, double tolerance, double lo, double hi) {
  if (pts.isEmpty) return const [];
  final raw = <NotePoint>[];
  for (var i = 0; i < pts.length; i++) {
    final t = ((pts[i].tick - on) / span).clamp(0.0, 1.0);
    final v = (pts[i].value - offset).clamp(lo, hi).toDouble();
    if (i > 0 && pts[i].tick - pts[i - 1].tick > gap) raw.add(NotePoint(t, raw.last.v));
    raw.add(NotePoint(t, v));
  }
  var tol = tolerance;
  var kept = _simplify(raw, tol);
  while (kept.length > 256) {
    tol *= 2;
    kept = _simplify(raw, tol);
  }
  return List.unmodifiable([for (final p in kept) NotePoint(_round(p.t, 4), _round(p.v, 3))]);
}

/// Ramer-Douglas-Peucker on (t, v), measured in value: the fewest points within [tol] of the line through them.
List<NotePoint> _simplify(List<NotePoint> p, double tol) {
  if (p.length <= 2) return p;
  final keep = List.filled(p.length, false);
  keep[0] = keep[p.length - 1] = true;
  final stack = <(int, int)>[(0, p.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var worst = -1.0, at = -1;
    for (var i = a + 1; i < b; i++) {
      final span = p[b].t - p[a].t;
      final line = span > 0 ? p[a].v + (p[b].v - p[a].v) * (p[i].t - p[a].t) / span : p[a].v;
      // Points at one time (a held value then a jump) can't lie on a sloped line between their neighbours.
      final d = span > 0 ? (p[i].v - line).abs() : (p[i].v - p[b].v).abs() + (p[i].v - p[a].v).abs();
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (at >= 0 && worst > tol) {
      keep[at] = true;
      stack.add((a, at));
      stack.add((at, b));
    }
  }
  return [for (var i = 0; i < p.length; i++) if (keep[i]) p[i]];
}

// ---------------------------------------------------------------------------------------------------------------
// Export

/// The part of a pattern a clip plays: [from] to [to] in the pattern, placed [at] steps into the file.
typedef _Window = ({Steps from, Steps to, Steps at});

/// [doc] as a Standard MIDI File at [bpm] in [beatsPerBar]/4. With a [clip], the notes it plays (its source offset,
/// length and looping, as the engine arranges it), else one loop of the pattern. Each ratchet hit is its own note;
/// chance and slide have no MIDI form and are left out. Notes with expression (bend, vibrato, pressure, timbre or a
/// microtonal pitch) make the file MPE.
/// [controls] (a clip's automation lanes as CCs, [automationControls]) go in the same track.
Uint8List patternToMidi(PatternDoc doc,
    {required double bpm, required int beatsPerBar, ClipDoc? clip, String? name, List<MidiControl> controls = const []}) {
  final source = Steps(clip?.loopLength(doc.lengthSteps(beatsPerBar)) ?? math.max(1, doc.lengthSteps(beatsPerBar)));
  final windows = <_Window>[];
  if (clip == null) {
    windows.add((from: Steps.zero, to: source, at: Steps.zero));
  } else if (doc.notes.isNotEmpty) {
    var pos = Steps(clip.sourceOffsetSteps), done = Steps.zero;
    final length = Steps(clip.lengthSteps);
    while (done < length) {
      if (pos >= source) {
        if (!clip.loop) break;
        pos = Steps(pos.floor() % source.floor());
      }
      final seg = Steps.min(length - done, source - pos);
      if (seg <= Steps.zero) break;
      windows.add((from: pos, to: pos + seg, at: done));
      if (windows.length * doc.notes.length > kMaxMidiNotes) {
        throw const MidiFileException('the clip would write more than $kMaxMidiNotes notes');
      }
      pos = pos + seg;
      done = done + seg;
    }
  }
  final tempo = bpm.isFinite ? bpm.clamp(20.0, 400.0).toDouble() : 120.0;
  const tps = kMidiExportPpq ~/ 4; // ticks per step
  int tick(Steps s) => (s.toDouble() * tps).round();
  final notes = <MidiNote>[];
  for (final w in windows) {
    for (final n in doc.notes) {
      final r = n.ratchet.clamp(1, kPatternMaxRatchet);
      final part = n.len / Steps(r);
      for (var q = 0; q < r; q++) {
        final hit = n.at + part * Steps(q), hitEnd = hit + part;
        if (hitEnd <= w.from || hit >= w.to) continue;
        final a = Steps.max(hit, w.from), b = Steps.min(hitEnd, w.to);
        final on = tick(a - w.from + w.at), off = math.max(on + 1, tick(b - w.from + w.at));
        notes.add(_note(n, hit, part, a, on, off, w, tps, tempo));
        if (notes.length > kMaxMidiNotes) throw const MidiFileException('the clip would write more than $kMaxMidiNotes notes');
      }
    }
  }
  final end = clip == null ? tick(source) : tick(windows.isEmpty ? Steps(clip.lengthSteps) : windows.last.at + windows.last.to - windows.last.from);
  return writeMidiFile(MidiFile(
    tempos: [MidiTempo(0, tempo)],
    meterNumerator: beatsPerBar.clamp(1, 16),
    meterDenominator: 4,
    tracks: [MidiTrack(name: name ?? doc.name, notes: notes, endTick: math.max(end, controls.fold(0, (e, c) => math.max(e, c.tick))), controls: controls)],
  ));
}

MidiNote _note(PatternNote n, Steps hit, Steps part, Steps from, int on, int off, _Window w, int tps, double bpm) {
  final key = n.pitch.round().clamp(0, 127);
  final frac = n.pitch - key;
  final x = n.expr;
  final hitTicks = part.toDouble() * tps;
  final startTick = (hit - w.from + w.at).toDouble() * tps; // where the hit would start, inside or before the window
  double u(int t) => hitTicks > 0 ? ((t - startTick) / hitTicks).clamp(0.0, 1.0) : 0;
  // Ticks to sample a curve at: its points' times, a 1/128 note grid (smooth enough for bends and vibrato), the end.
  List<int> ticks(List<NotePoint> c) {
    final every = math.max(kMidiExportPpq ~/ 32, (off - on) ~/ 4096);
    return {
      for (var t = on; t < off; t += every) t,
      for (final p in c)
        if (startTick + p.t * hitTicks >= on && startTick + p.t * hitTicks < off) (startTick + p.t * hitTicks).round(),
      off - 1,
    }.where((t) => t >= on && t < off).toList()
      ..sort();
  }

  List<MidiPoint> sample(List<NotePoint> c, double Function(int t) f) {
    final out = <MidiPoint>[];
    for (final t in ticks(c)) {
      final v = f(t);
      if (out.isEmpty || out.last.value != v) out.add(MidiPoint(t, v));
    }
    return out;
  }

  final bends = x.bend.isEmpty && x.vibDepth <= 0
      ? [if (frac != 0) MidiPoint(on, frac)]
      : sample(x.bend, (t) => frac + x.pitchAt(u(t), (t - startTick) / tps * 15 / bpm));
  return MidiNote(
    key: key,
    velocity: (n.vel * 127).round().clamp(1, 127),
    on: on,
    off: off,
    bend: bends,
    pressure: x.press.isEmpty ? null : sample(x.press, (t) => NoteExpression.valueAt(x.press, u(t))),
    timbre: x.timbre.isEmpty ? null : sample(x.timbre, (t) => NoteExpression.valueAt(x.timbre, u(t))),
  );
}

// ---------------------------------------------------------------------------------------------------------------
// The project

/// True while no track has a clip: a MIDI file's tempo and meter may then become the project's.
bool projectHasNoClips(ProjectDoc p) => p.layers.every((l) => l.clips.isEmpty);

/// Adds [m]'s clips to the project as new pattern modules (one undo step with the rest of the burst). One clip goes on
/// [layer] (the selected track) when there is one, after its last clip; several go on new tracks, one each, from the
/// song's start. With [adoptTempo], the file's first tempo and meter become the project's. Returns what happened,
/// for a one-line message.
String placeMidiImport(AppState s, MidiImport m, {LayerDoc? layer, bool adoptTempo = false}) {
  if (m.clips.isEmpty) return 'The MIDI file has no notes.';
  final p = s.project;
  final notes = <String>[];
  if (adoptTempo) {
    final bpm = m.bpm, beats = m.beatsPerBar;
    if (bpm != null || beats != null) {
      s.editProject((p) {
        if (bpm != null) p.bpm = _round(bpm.clamp(20.0, 400.0), 1);
        if (beats != null) p.beatsPerBar = beats;
      });
      if (bpm != null) notes.add('tempo ${formatNumber(p.bpm)} BPM');
    }
  } else if (m.bpm != null && (m.bpm! - p.bpm).abs() >= 0.05) {
    notes.add('kept the project\'s tempo, not the file\'s ${formatNumber(_round(m.bpm!, 1))} BPM');
  }
  if (m.tempoChanges) notes.add('tempo changes ignored');
  final target = layer != null && !layer.isFolder && p.layers.contains(layer) ? layer : null;
  final modules = [for (final c in m.clips) ModuleDoc(id: newId('m'), name: _freeName(p, c.name), source: c.source)];
  // The file is listed in Files (Audio & MIDI) with its parts, so it can be dragged onto a track again.
  s.editProject((p) {
    p.modules.addAll(modules);
    p.midiFiles.add(MidiFileDoc(id: newId('mid'), name: m.name, parts: [for (final mod in modules) mod.id]));
  });
  if (modules.length == 1 && target != null) {
    s.addClip(target, modules.single.id);
  } else {
    for (final mod in modules) {
      s.addLayer();
      final l = s.project.layers.last;
      s.editLayer(l, (l) => l.name = mod.name);
      s.addClip(l, mod.id, startSteps: 0);
    }
  }
  final what = modules.length == 1 ? '1 clip' : '${modules.length} clips on new tracks';
  return 'Imported ${m.noteCount} notes as $what${notes.isEmpty ? '' : ' (${notes.join('; ')})'}.';
}

/// Places imported MIDI file [f] dropped on [layer] at [atStep]: one clip per part, the first on [layer] and each
/// other part on a new track under it, all at the same step. Parts whose pattern was deleted are skipped. Returns
/// false when nothing was placed.
bool placeMidiFile(AppState s, MidiFileDoc f, LayerDoc layer, {int? atStep}) {
  final parts = [for (final id in f.parts) ?s.project.module(id)];
  if (parts.isEmpty || layer.isFolder) return false;
  final before = {for (final c in layer.clips) c.id};
  s.addClip(layer, parts.first.id, startSteps: atStep);
  final first = layer.clips.where((c) => !before.contains(c.id)).firstOrNull;
  if (first == null) return false;
  // The others line up with the first clip, wherever it landed (after the track's last clip without a drop point).
  final at = first.startSteps;
  var below = s.project.layers.indexOf(layer);
  for (final mod in parts.skip(1)) {
    s.addLayer();
    final l = s.project.layers.last;
    s.editLayer(l, (l) {
      l.name = mod.name;
      l.parentId = layer.parentId;
    });
    // Right under the track it was dropped on, in file order.
    below++;
    final from = s.project.layers.indexOf(l);
    if (from != below) s.moveLayer(from, below);
    s.addClip(s.project.layers[below], mod.id, startSteps: at);
  }
  return true;
}

String _freeName(ProjectDoc p, String name) {
  if (p.modules.every((m) => m.name != name)) return name;
  var n = 2;
  while (p.modules.any((m) => m.name == '$name $n')) {
    n++;
  }
  return '$name $n';
}

/// [clip] (a clip on a track of [p]) as a Standard MIDI File at the project's tempo and meter, with its track's
/// automation over the clip as CCs ([automationControls]; [range] as there); null when its pattern is missing or
/// doesn't parse.
Uint8List? clipToMidi(ProjectDoc p, ClipDoc clip, {AutomationRange? range}) {
  final m = p.module(clip.patternId);
  if (m == null) return null;
  final doc = PatternDoc.parse(m.source).doc ?? PatternDoc.parse(m.runSource).doc;
  if (doc == null) return null;
  final layer = p.layers.where((l) => l.clips.contains(clip)).firstOrNull;
  final controls = layer == null ? const <MidiControl>[] : automationControls(p, layer, clip, range: range);
  return patternToMidi(doc, bpm: p.bpm, beatsPerBar: p.beatsPerBar, clip: clip, name: m.name, controls: controls);
}

// ---------------------------------------------------------------------------------------------------------------
// Automation as MIDI CCs (#11)

/// A project lane's value range, for scaling it to 0..127; null when unknown.
typedef AutomationRange = ({double lo, double hi})? Function(ProjectAutomationLaneDoc lane);

/// The CCs a track's other lanes get, in the project's lane order: the 12 undefined controllers 20-31, then the 18
/// undefined 102-119 (MIDI 1.0's controller table). Lanes past the 30th are left out.
const List<int> kAutomationCcs = [20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
  102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119];

/// A sample every 1/32 note (half a step) along a ramp; MIDI holds a value until the next one.
const double _ccEverySteps = 0.5;

/// [layer]'s automation over [clip] (song time from the clip's start to its end) as controller changes, ticks from
/// the clip's start at [kMidiExportPpq]: the track's volume lane as CC7 (gain g as 127·√g, so 0 dB is 127 and
/// −6 dB about 90; above 0 dB holds at 127), pan as CC10 (−1 left 0, centre 64, right 127), and the project's lanes
/// on this track (its instrument's and effects' parameters, and the parameters of its .caw generator and effects)
/// as [kAutomationCcs] in lane order, scaled from [range] (else 0..1 when every point is inside it, else the lane's
/// own lowest to highest point). Each lane sends its value at the clip's start, then a change at every point and
/// along each ramp every 1/32 note, only when the 7-bit value changes. Globals have no track and are left out.
List<MidiControl> automationControls(ProjectDoc p, LayerDoc layer, ClipDoc clip, {AutomationRange? range}) {
  const tps = kMidiExportPpq ~/ 4; // ticks per step
  final from = clip.startSteps.toDouble(), to = (clip.startSteps + clip.lengthSteps).toDouble();
  final out = <MidiControl>[];

  void lane(List<AutomationPointDoc> raw, int cc, int Function(double v) seven) {
    if (raw.isEmpty) return;
    final pts = [...raw]..sort((a, b) => a.step.compareTo(b.step));
    double at(double step) {
      if (step <= pts.first.step) return pts.first.value;
      for (var i = 0; i + 1 < pts.length; i++) {
        final a = pts[i], b = pts[i + 1];
        if (step <= b.step) return b.step > a.step ? a.value + (b.value - a.value) * (step - a.step) / (b.step - a.step) : b.value;
      }
      return pts.last.value;
    }

    // The times to send: the clip's start, every point inside the clip, and a grid along each ramp.
    final times = <double>{from};
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i].step;
      if (a > from && a < to) times.add(a);
      if (i + 1 < pts.length && pts[i + 1].value != pts[i].value) {
        final b = pts[i + 1].step;
        for (var t = math.max(from, (a / _ccEverySteps).ceil() * _ccEverySteps); t < math.min(b, to); t += _ccEverySteps) {
          times.add(t);
        }
      }
    }
    var last = -1;
    for (final t in times.toList()..sort()) {
      final v = seven(at(t)).clamp(0, 127);
      if (v == last) continue;
      last = v;
      out.add(MidiControl(((t - from) * tps).round(), cc, v));
      if (out.length > kMaxMidiEvents) throw const MidiFileException('the automation would write more than $kMaxMidiEvents events');
    }
  }

  for (final a in layer.automation) {
    switch (a.target) {
      case 'volume':
        lane(a.points, 7, (g) => (127 * math.sqrt(math.max(0.0, math.min(1.0, g)))).round());
      case 'pan':
        lane(a.points, 10, (x) => (63.5 + 63.5 * x.clamp(-1.0, 1.0)).round());
    }
  }
  final mine = [for (final a in p.automation) if (a.layerId == layer.id) a];
  for (final (i, a) in mine.take(kAutomationCcs.length).indexed) {
    if (a.points.isEmpty) continue;
    final values = a.points.map((x) => x.value);
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final r = range?.call(a) ?? (lo >= 0 && hi <= 1 ? (lo: 0.0, hi: 1.0) : (lo: lo, hi: hi));
    final span = r.hi - r.lo;
    lane(a.points, kAutomationCcs[i], (v) => span > 0 ? (127 * (v - r.lo) / span).round() : 0);
  }
  out.sort((a, b) => a.tick != b.tick ? a.tick.compareTo(b.tick) : a.controller.compareTo(b.controller));
  return out;
}
