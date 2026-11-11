// Clip automation (owner, 2026-11-11): lanes that belong to a MIDI clip, in its own time, and how they are unrolled
// onto the song timeline for the engine (ProjectDoc.toEngineJson), merged with the track's own lane on the same target.
import 'dart:math' as math;

import 'pattern_doc.dart';
import 'project.dart';

/// One automation lane on a clip: the track's volume or pan (`track`), its instrument's parameter (`instrument`) or
/// one of its effects' (`component`, [component] its index in the track's chain). Points are in the clip's own time:
/// steps from its pattern's start, within its loop ([ClipDoc.loopLength]), joined as track lanes are (straight,
/// holding before the first and after the last).
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

typedef _P = ({double step, double value});

/// The value of a point list (time order, equal steps allowed) at [x], as the engine reads a lane
/// (`automationLaneValue`): where two points share a step, the later one holds from there.
double _right(List<_P> pts, double x) {
  if (x <= pts.first.step) return pts.first.value;
  if (x >= pts.last.step) return pts.last.value;
  var lo = 0, hi = pts.length - 1;
  while (lo + 1 < hi) {
    final mid = (lo + hi) >> 1;
    if (pts[mid].step <= x) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = pts[lo], b = pts[hi];
  return a.value + (b.value - a.value) * (x - a.step) / (b.step - a.step);
}

/// The value just before [x] (where two points share a step, the earlier one).
double _left(List<_P> pts, double x) {
  if (x <= pts.first.step) return pts.first.value;
  if (x > pts.last.step) return pts.last.value;
  var j = pts.indexWhere((p) => p.step >= x);
  final a = pts[j - 1], b = pts[j];
  return a.value + (b.value - a.value) * (x - a.step) / (b.step - a.step);
}

/// The value of a lane's [points] (time order) at [at], as the engine plays it; with [left], just before [at].
double pointsValueAt(List<AutomationPointDoc> points, double at, {bool left = false}) {
  if (points.isEmpty) return 0;
  final pts = [for (final p in points) (step: p.step, value: p.value)];
  return left ? _left(pts, at) : _right(pts, at);
}

/// Where a clip's lane plays on the song timeline: [start] to [end], as points with times on the timeline.
typedef ClipLaneSpan = ({double start, double end, List<_P> points});

/// [clip]'s lane [points] (clip time) on the song timeline: one pass of the loop from the clip's source offset, then
/// a pass every [loop] steps while the clip loops, to the clip's end. Each pass starts at the lane's value there, so a
/// repeat jumps back to the loop's first value as the notes do. A clip that doesn't loop plays one pass and then holds.
ClipLaneSpan clipLaneSpan(ClipDoc clip, List<AutomationPointDoc> points, int loop, {int budget = kMaxClipLanePoints}) {
  final start = clip.startSteps.toDouble(), end = (clip.startSteps + clip.lengthSteps).toDouble();
  final local = [for (final p in points) (step: p.step, value: p.value)]..sort((a, b) => a.step.compareTo(b.step));
  final out = <_P>[];
  if (local.isEmpty) return (start: start, end: end, points: out);
  final length = math.max(1, loop).toDouble();
  var t = start;
  var u = clip.loop ? clip.sourceOffsetSteps % length : clip.sourceOffsetSteps.toDouble();
  while (t < end && out.length < budget) {
    final dt = clip.loop ? math.min(end - t, length - u) : end - t;
    if (dt <= 0) break;
    out.add((step: t, value: _right(local, u)));
    for (final p in local) {
      if (p.step > u && p.step < u + dt) out.add((step: t + p.step - u, value: p.value));
    }
    out.add((step: t + dt, value: _left(local, u + dt)));
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
      ? <_P>[(step: 0, value: baseValue)]
      : [for (final p in base) (step: p.step, value: p.value)]..sort((a, b) => a.step.compareTo(b.step));
  final live = [for (final s in spans) if (s.points.isNotEmpty && s.end > s.start) s];
  if (live.isEmpty) return [for (final p in base) AutomationPointDoc(step: p.step, value: p.value)]..sort((a, b) => a.step.compareTo(b.step));
  // Priority: later start wins; a stable sort keeps list order for equal starts.
  final ranked = [...live.indexed]..sort((a, b) => a.$2.start != b.$2.start ? a.$2.start.compareTo(b.$2.start) : a.$1.compareTo(b.$1));
  final bounds = {for (final s in live) ...[s.start, s.end]}.toList()..sort();
  final out = <_P>[];
  void add(double step, double value) {
    if (out.length >= 2 && out[out.length - 1].step == step && out[out.length - 2].step == step) {
      out[out.length - 1] = (step: step, value: value); // three at one step: the middle one never plays
    } else if (out.isEmpty || out.last.step != step || out.last.value != value) {
      out.add((step: step, value: value));
    }
  }

  void interval(List<_P> src, double? x, double? y) {
    if (x != null) add(x, _right(src, x));
    for (final p in src) {
      if ((x == null || p.step > x) && (y == null || p.step < y)) add(p.step, p.value);
    }
    if (y != null) add(y, _left(src, y));
  }

  interval(baseP, null, bounds.first);
  for (var i = 0; i + 1 < bounds.length; i++) {
    final x = bounds[i], y = bounds[i + 1];
    ClipLaneSpan? winner;
    for (final (_, s) in ranked) {
      if (s.start <= x && s.end >= y) winner = s;
    }
    interval(winner?.points ?? baseP, x, y);
  }
  interval(baseP, bounds.last, null);
  return [for (final p in out.take(kMaxClipLanePoints * 2)) AutomationPointDoc(step: p.step, value: p.value)];
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
