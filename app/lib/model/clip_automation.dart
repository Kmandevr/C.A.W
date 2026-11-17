// Clip automation (owner, 2026-11-11): lanes that belong to a MIDI clip, in its own time, and how they are unrolled
// onto the song timeline for the engine (ProjectDoc.toEngineJson), merged with the track's own lane on the same target.
import 'dart:math' as math;

import 'automation_curve.dart';
import 'pattern_doc.dart';
import 'project.dart';

/// One automation lane on a clip: the track's volume or pan (`track`), its instrument's parameter (`instrument`) or
/// one of its effects' (`component`, [component] its index in the track's chain). Points are in the clip's own time:
/// steps from its pattern's start, within its loop ([ClipDoc.loopLength]), joined as track lanes are (each point's
/// curve to the next, holding before the first and after the last).
class ClipAutomationLaneDoc {
  ClipAutomationLaneDoc({required this.targetType, required this.target, this.component, List<AutomationPointDoc>? points})
      : points = points ?? [];
  String targetType;
  String target;
  int? component;
  List<AutomationPointDoc> points;

  /// The key of the track or project lane on the same target ([automationKey]) on track [layerId].
  String keyOn(String layerId) => automationKey(targetType, target, layerId: layerId, component: component);

  bool get isTrack => targetType == 'track';

  Map<String, dynamic> toJson() => {
        'target_type': targetType,
        'target': target,
        if (component != null) 'component': component,
        'points': [for (final p in points) p.toJson()],
      };

  /// Null for a lane that names nothing a clip can automate.
  static ClipAutomationLaneDoc? fromJson(Map<String, dynamic> j) {
    final type = j['target_type'], target = j['target'];
    if (type is! String || target is! String || target.isEmpty) return null;
    if (type == 'track' ? target != 'volume' && target != 'pan' : type != 'instrument' && type != 'component') return null;
    final component = (j['component'] as num?)?.toInt();
    if (type == 'component' && (component == null || component < 0 || component >= 64)) return null;
    return ClipAutomationLaneDoc(targetType: type, target: target, component: type == 'component' ? component : null,
        points: [
          for (final p in (j['points'] as List?) ?? const [])
            if (p is Map<String, dynamic>) AutomationPointDoc.fromJson(p),
        ].take(kMaxClipLanePoints).toList()
          ..sort((a, b) => a.step.compareTo(b.step)));
  }

  ClipAutomationLaneDoc copy() => ClipAutomationLaneDoc.fromJson(toJson())!;
}

/// The most points one clip lane holds, and the most an unrolled lane sends the engine: past it a long clip's
/// later repeats hold the last value (a 1-step loop over a whole song would otherwise be millions of points).
const int kMaxClipLanePoints = 1 << 16;

typedef _P = ({double step, double value, AutomationCurve curve, double tension});

_P _of(AutomationPointDoc p) => (step: p.step, value: p.value, curve: p.curve, tension: p.tension);
_P _flat(double step, double value) => (step: step, value: value, curve: AutomationCurve.linear, tension: 0.0);

/// The value along [a]'s segment to [b] at [x], through [a]'s curve (lib/model/automation_curve.dart).
double _seg(_P a, _P b, double x) {
  final span = b.step - a.step;
  if (span <= 0) return b.value;
  final t = (x - a.step) / span;
  if (a.curve == AutomationCurve.linear) return a.value + (b.value - a.value) * t;
  return a.value + (b.value - a.value) * curveShape(a.curve, a.tension, t);
}

/// The last point at or before [x] (-1: none).
int _at(List<_P> pts, double x) {
  var lo = 0, hi = pts.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (pts[mid].step <= x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo - 1;
}

/// The value of a point list (time order, equal steps allowed) at [x], as the engine reads a lane
/// (`automationLaneValue`): where two points share a step, the later one holds from there.
double _right(List<_P> pts, double x) {
  if (x <= pts.first.step) return pts.first.value;
  if (x >= pts.last.step) return pts.last.value;
  final i = _at(pts, x);
  return _seg(pts[i], pts[i + 1], x);
}

/// The value just before [x] (where two points share a step, the earlier one).
double _left(List<_P> pts, double x) {
  if (x <= pts.first.step) return pts.first.value;
  if (x > pts.last.step) return pts.last.value;
  final j = pts.indexWhere((p) => p.step >= x);
  return _seg(pts[j - 1], pts[j], x);
}

/// How many straight pieces stand in for a bent segment cut by a clip's edge: a part of a curve isn't the same curve.
const int _cutPieces = 16;

/// [src]'s points from [x] to [y] (null: from its start, to its end) through [add], shifted by [shift]: the value at
/// each end, the points between with their curves, and where an end cuts a bent segment, the cut part as straight
/// pieces along the curve (a step's or a line's part is a step or a line).
void _range(List<_P> src, double? x, double? y, void Function(_P) add, {double shift = 0}) {
  void pieces(int i, double from, double to) {
    for (var k = 1; k < _cutPieces; k++) {
      final at = from + (to - from) * k / _cutPieces;
      add(_flat(at + shift, _seg(src[i], src[i + 1], at)));
    }
  }

  if (x != null) {
    final i = _at(src, x);
    final inside = i >= 0 && i + 1 < src.length;
    final v = _right(src, x);
    final cut = inside && src[i].curve.bends && (src[i].step != x || (y != null && src[i + 1].step > y));
    if (cut) {
      add(_flat(x + shift, v));
      pieces(i, x, y == null ? src[i + 1].step : math.min(y, src[i + 1].step));
    } else if (inside && src[i].step == x) {
      add((step: x + shift, value: v, curve: src[i].curve, tension: src[i].tension));
    } else {
      add((step: x + shift, value: v, curve: inside ? src[i].curve : AutomationCurve.linear, tension: 0.0));
    }
  }
  for (var j = 0; j < src.length; j++) {
    final p = src[j];
    if ((x != null && p.step <= x) || (y != null && p.step >= y)) continue;
    if (y != null && p.curve.bends && j + 1 < src.length && src[j + 1].step > y) {
      add(_flat(p.step + shift, p.value));
      pieces(j, p.step, y);
    } else {
      add((step: p.step + shift, value: p.value, curve: p.curve, tension: p.tension));
    }
  }
  if (y != null) add(_flat(y + shift, _left(src, y)));
}

/// The value of a lane's [points] (time order) at [at], as the engine plays it; with [left], just before [at].
double pointsValueAt(List<AutomationPointDoc> points, double at, {bool left = false}) {
  if (points.isEmpty) return 0;
  final pts = [for (final p in points) _of(p)];
  return left ? _left(pts, at) : _right(pts, at);
}

/// Where a clip's lane plays on the song timeline: [start] to [end], as points with times on the timeline.
typedef ClipLaneSpan = ({double start, double end, List<_P> points});

/// [clip]'s lane [points] (clip time) on the song timeline: one pass of the loop from the clip's source offset, then
/// a pass every [loop] steps while the clip loops, to the clip's end. Each pass starts at the lane's value there, so a
/// repeat jumps back to the loop's first value as the notes do. A clip that doesn't loop plays one pass and then holds.
/// Curves go with their points; a bent segment cut by a pass's ends is drawn in straight pieces along it.
ClipLaneSpan clipLaneSpan(ClipDoc clip, List<AutomationPointDoc> points, int loop, {int budget = kMaxClipLanePoints}) {
  final start = clip.startSteps.toDouble(), end = (clip.startSteps + clip.lengthSteps).toDouble();
  final local = [for (final p in points) _of(p)]..sort((a, b) => a.step.compareTo(b.step));
  final out = <_P>[];
  if (local.isEmpty) return (start: start, end: end, points: out);
  final length = math.max(1, loop).toDouble();
  var t = start;
  var u = clip.loop ? clip.sourceOffsetSteps % length : clip.sourceOffsetSteps.toDouble();
  while (t < end && out.length < budget) {
    final dt = clip.loop ? math.min(end - t, length - u) : end - t;
    if (dt <= 0) break;
    _range(local, u, u + dt, out.add, shift: t - u);
    t += dt;
    u = 0;
    if (!clip.loop) break;
  }
  return (start: start, end: end, points: out);
}

/// The lane the engine plays for one target on one track: [base] (the track's or project's own lane, time order;
/// empty when there is none, then the control's [baseValue]) everywhere except inside each clip's span, where that
/// clip's lane plays instead. Where clips with lanes on the target overlap, the one that starts later wins (the later
/// one in [spans] on a tie); after it ends, the one under it plays again.
List<AutomationPointDoc> mergeClipLanes(List<AutomationPointDoc> base, double baseValue, List<ClipLaneSpan> spans) {
  final baseP = base.isEmpty
      ? <_P>[_flat(0, baseValue)]
      : [for (final p in base) _of(p)]..sort((a, b) => a.step.compareTo(b.step));
  final live = [for (final s in spans) if (s.points.isNotEmpty && s.end > s.start) s];
  if (live.isEmpty) return [for (final p in base) p.copy()]..sort((a, b) => a.step.compareTo(b.step));
  // Priority: later start wins; a stable sort keeps list order for equal starts.
  final ranked = [...live.indexed]..sort((a, b) => a.$2.start != b.$2.start ? a.$2.start.compareTo(b.$2.start) : a.$1.compareTo(b.$1));
  final bounds = {for (final s in live) ...[s.start, s.end]}.toList()..sort();
  final out = <_P>[];
  void add(_P q) {
    if (out.length >= 2 && out[out.length - 1].step == q.step && out[out.length - 2].step == q.step) {
      out[out.length - 1] = q; // three at one step: the middle one never plays
    } else if (out.isEmpty || out.last.step != q.step || out.last.value != q.value) {
      out.add(q);
    } else {
      out[out.length - 1] = q; // the same point again: the later one's curve goes on from it
    }
  }

  _range(baseP, null, bounds.first, add);
  for (var i = 0; i + 1 < bounds.length; i++) {
    final x = bounds[i], y = bounds[i + 1];
    ClipLaneSpan? winner;
    for (final (_, s) in ranked) {
      if (s.start <= x && s.end >= y) winner = s;
    }
    _range(winner?.points ?? baseP, x, y, add);
  }
  _range(baseP, bounds.last, null, add);
  return [
    for (final p in out.take(kMaxClipLanePoints * 2))
      AutomationPointDoc(step: p.step, value: p.value, curve: p.curve, tension: p.tension),
  ];
}

/// One target's lane on a track as the engine gets it, the clips' lanes merged in ([unrollClipAutomation]).
typedef UnrolledLane = ({String layerId, String targetType, String target, int? component, List<AutomationPointDoc> points});

extension ClipAutomationProject on ProjectDoc {
  /// [clip]'s loop length in steps: its own loop point, else its pattern's length (as the engine reads it).
  int clipLoopSteps(ClipDoc clip) {
    if ((clip.loopSteps ?? 0) > 0) return clip.loopSteps!;
    final m = module(clip.patternId);
    final doc = m == null ? null : PatternDoc.parse(m.runSource).doc ?? PatternDoc.parse(m.source).doc;
    return clip.loopLength(doc?.lengthSteps(beatsPerBar) ?? stepsPerBar);
  }

  /// The value a target holds without automation: the track's fader or pan, or the parameter's stored value. Null
  /// when the project doesn't store it (a parameter at its default).
  double? controlValue(LayerDoc layer, String targetType, String target, int? component) => switch (targetType) {
        'track' => target == 'volume' ? layer.volume : layer.pan,
        'instrument' => layer.instrument?.params[target],
        'component' when component != null && component >= 0 && component < layer.components.length =>
          layer.components[component].params[target],
        _ => null,
      };

  /// Every clip lane unrolled onto the timeline and merged with the track's or project's lane on its target (the
  /// clip's lane plays inside the clip, the other lane elsewhere), keyed by [automationKey]. Muted clips add nothing.
  Map<String, UnrolledLane> unrollClipAutomation() {
    final out = <String, UnrolledLane>{};
    for (final layer in layers) {
      final byKey = <String, List<(ClipDoc, ClipAutomationLaneDoc)>>{};
      for (final clip in layer.clips) {
        if (clip.mute) continue;
        for (final lane in clip.automation) {
          if (lane.points.isNotEmpty) byKey.putIfAbsent(lane.keyOn(layer.id), () => []).add((clip, lane));
        }
      }
      for (final MapEntry(key: key, value: lanes) in byKey.entries) {
        final first = lanes.first.$2;
        final base = first.isTrack
            ? layer.automation.where((a) => a.target == first.target).firstOrNull?.points
            : automation.where((a) => a.key == key).firstOrNull?.points;
        final loops = <String, int>{};
        var budget = kMaxClipLanePoints;
        final spans = <ClipLaneSpan>[];
        for (final (clip, lane) in lanes) {
          final span = clipLaneSpan(clip, lane.points, loops[clip.id] ??= clipLoopSteps(clip), budget: math.max(0, budget));
          budget -= span.points.length;
          spans.add(span);
        }
        final value = controlValue(layer, first.targetType, first.target, first.component) ??
            (spans.firstWhere((s) => s.points.isNotEmpty, orElse: () => spans.first).points.firstOrNull?.value ?? 0);
        out[key] = (layerId: layer.id, targetType: first.targetType, target: first.target, component: first.component,
            points: mergeClipLanes(base ?? const [], value, spans));
      }
    }
    return out;
  }
}
