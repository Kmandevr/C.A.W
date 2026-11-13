// Tempo-map and time-signature edits on AppState (#207): the tempo lane's points (add, drag, stepped or ramped,
// delete) and the ruler's signature flags, each one undo step; and the span moves a section's move, copy or delete
// makes in the map and the signatures.
import 'dart:math' as math;

import 'app_state.dart';
import 'project.dart';
import 'tempo_map.dart';

/// A tempo rounded to 0.1 BPM, held to the map's range.
double roundBpm(double v) => (v.clamp(kMinMapBpm, kMaxMapBpm) * 10).roundToDouble() / 10;

/// [points] without a point that changes nothing (its tempo is the one already playing and it doesn't ramp to it).
List<TempoPoint> dropRedundantTempo(List<TempoPoint> points) {
  final out = <TempoPoint>[];
  for (final p in points) {
    // Same tempo as the point before: stepped or ramped, nothing changes from there.
    if (out.isNotEmpty && p.bpm == out.last.bpm) continue;
    out.add(p);
  }
  return out;
}

/// The tempo map with span [a]..[b) (beats) cut out of it, the music after it keeping its tempo: points inside go
/// (the one at beat 0 stays), and a point at [b] holds what played there.
List<TempoPoint> tempoCut(List<TempoPoint> map, double a, double b) {
  final m = TempoMath(map);
  final after = m.bpmAt(b);
  final out = [for (final p in map) if (p.beat == 0 || p.beat < a || p.beat >= b) p];
  if (!out.any((p) => p.beat == b)) out.add(TempoPoint(b, after));
  return normalizeTempoMap(out, fallbackBpm: map.first.bpm);
}

/// The tempo points of span [a]..[b) moved to start at [to]: a point at [to] with the tempo the span starts at, the
/// points inside it, and the tempo [map] had at the span's new end after it.
List<TempoPoint> tempoPaste(List<TempoPoint> map, List<TempoPoint> from, double a, double b, double to) {
  final src = TempoMath(from), dst = TempoMath(map);
  final d = to - a, end = b + d;
  final tail = dst.bpmAt(end);
  final out = [
    for (final p in map) if (p.beat < to || p.beat > end || (p.beat == 0 && to > 0)) p,
    TempoPoint(to, src.bpmAt(a)),
    for (final p in from) if (p.beat > a && p.beat < b) TempoPoint(p.beat + d, p.bpm, ramp: p.ramp),
    TempoPoint(end, tail),
  ];
  return dropRedundantTempo(normalizeTempoMap(out, fallbackBpm: map.first.bpm));
}

List<SignatureAt> _sigBeats(List<TimeSignature> sigs) => [for (final s in sigs) (beat: s.beat, num: s.num, den: s.den)];

/// The signatures with span [a]..[b) (beats) cut out: changes inside go (bar 0's stays), and the one playing at [b]
/// starts again there.
List<TimeSignature> signatureCut(List<TimeSignature> sigs, double a, double b) {
  final m = BarMath(sigs);
  final at = m.signatureAt(b);
  final out = [for (final s in _sigBeats(sigs)) if (s.beat == 0 || s.beat < a || s.beat >= b) s];
  if (!out.any((s) => s.beat == b)) out.add((beat: b, num: at.num, den: at.den));
  return signaturesFromBeats(out, sigs.first.num);
}

/// The signature changes of span [a]..[b) moved to start at [to], as [tempoPaste] does for tempo.
List<TimeSignature> signaturePaste(List<TimeSignature> sigs, List<TimeSignature> from, double a, double b, double to) {
  final src = BarMath(from), dst = BarMath(sigs);
  final d = to - a, end = b + d;
  final tail = dst.signatureAt(end), head = src.signatureAt(a);
  final out = [
    for (final s in _sigBeats(sigs)) if (s.beat < to || s.beat > end || (s.beat == 0 && to > 0)) s,
    (beat: to, num: head.num, den: head.den),
    for (final s in _sigBeats(from)) if (s.beat > a && s.beat < b) (beat: s.beat + d, num: s.num, den: s.den),
    (beat: end, num: tail.num, den: tail.den),
  ];
  return signaturesFromBeats(out, sigs.first.num);
}

extension ArrangeTempo on AppState {
  /// Adds a tempo point at [beat] with [bpm] (the tempo playing there when null), stepped; returns its index. One
  /// undo step. The tempo lane shows from the first one.
  int addTempoPoint(double beat, {double? bpm}) {
    final p = project;
    final at = beat.clamp(0.0, p.maxArrangementSteps / 4).toDouble();
    final v = roundBpm(bpm ?? p.tempo.bpmAt(at));
    endUndoStep();
    editProject((p) => p.tempoMap = [...p.tempoMap.where((t) => t.beat != at), TempoPoint(at, v)]);
    endUndoStep();
    return project.tempoMap.indexWhere((t) => t.beat == at);
  }

  /// Moves tempo point [index] to [beat] (held between its neighbours; the first point stays at 0) with tempo [bpm].
  /// A drag calls this on every move; it is one undo step with the [endUndoStep] calls around the drag.
  void moveTempoPoint(int index, {double? beat, double? bpm}) {
    final map = project.tempoMap;
    if (index < 0 || index >= map.length) return;
    final t = map[index];
    var at = beat ?? t.beat;
    if (index == 0) {
      at = 0;
    } else {
      final lo = map[index - 1].beat + 1 / 64;
      final hi = index + 1 < map.length ? map[index + 1].beat - 1 / 64 : project.maxArrangementSteps / 4;
      at = at.clamp(lo, math.max(lo, hi)).toDouble();
    }
    final v = bpm == null ? t.bpm : roundBpm(bpm);
    if (at == t.beat && v == t.bpm) return;
    editProject((p) => p.tempoMap = [for (var i = 0; i < map.length; i++) i == index ? t.copyWith(beat: at, bpm: v) : map[i]]);
  }

  /// Point [index] ramps to its tempo from the point before ([ramp]) or jumps to it. One undo step.
  void setTempoRamp(int index, bool ramp) {
    final map = project.tempoMap;
    if (index <= 0 || index >= map.length || map[index].ramp == ramp) return;
    endUndoStep();
    editProject((p) => p.tempoMap = [for (var i = 0; i < map.length; i++) i == index ? map[i].copyWith(ramp: ramp) : map[i]]);
    endUndoStep();
  }

  /// Deletes tempo point [index] (the first can't go: the map always has a tempo at the start). One undo step. With
  /// the last change gone the tempo lane hides.
  void removeTempoPoint(int index) {
    final map = project.tempoMap;
    if (index <= 0 || index >= map.length) return;
    endUndoStep();
    editProject((p) => p.tempoMap = [...map]..removeAt(index));
    endUndoStep();
  }

  /// Sets the signature from bar [bar] (0-based) on to [num]/[den]; one undo step.
  void setTimeSignature(int bar, int num, int den) {
    if (num < 1 || num > 32 || !kSignatureDens.contains(den) || bar < 0) return;
    final sigs = project.timeSignatures;
    endUndoStep();
    editProject((p) => p.timeSignatures = [
          for (final s in sigs) if (s.bar != bar) s,
          TimeSignature(bar, 0, num, den),
        ]);
    endUndoStep();
  }

  /// Removes the signature change at bar [bar] (not bar 0's); the bars after it keep the one before. One undo step.
  void removeTimeSignature(int bar) {
    final sigs = project.timeSignatures;
    if (bar <= 0 || !sigs.any((s) => s.bar == bar)) return;
    endUndoStep();
    editProject((p) => p.timeSignatures = [for (final s in sigs) if (s.bar != bar) s]);
    endUndoStep();
  }
}

/// The tempo map and signatures of [p] after span [a]..[b) (sixteenth steps) moves or copies to [to] (or is
/// deleted, [to] null): applied by the section edits in one undo step with the clips and automation.
void moveTempoSpan(ProjectDoc p, int a, int b, int? to, {bool copy = false}) {
  final ba = a / 4, bb = b / 4;
  final map0 = p.tempoMap, sigs0 = p.timeSignatures;
  var map = copy ? map0 : tempoCut(map0, ba, bb);
  var sigs = copy ? sigs0 : signatureCut(sigs0, ba, bb);
  if (to != null) {
    map = tempoPaste(map, map0, ba, bb, to / 4);
    sigs = signaturePaste(sigs, sigs0, ba, bb, to / 4);
  }
  p.tempoMap = dropRedundantTempo(map);
  p.timeSignatures = sigs;
}
