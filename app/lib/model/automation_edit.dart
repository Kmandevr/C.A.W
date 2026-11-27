// Automation lane editing (#230): the lane tools' point maths (pencil, line, shapes, eraser), box transforms, copy and
// paste, snapping, points following a moved clip, and Automate from a control (a lane made or revealed, armed).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'arrange_fx.dart';
import 'automation_curve.dart';
import 'automation_writer.dart';
import 'project.dart';

/// The shapes the shape tool draws, one cycle per grid step.
enum LaneShape {
  sine('Sine'),
  triangle('Triangle'),
  saw('Saw'),
  square('Square'),
  random('Random');

  const LaneShape(this.label);
  final String label;
}

/// [points] (time order) with [span] (time order) in place of whatever they had from its first step to its last:
/// a point before it keeps its curve, now ending where the span starts.
List<AutomationPointDoc> replaceSpan(List<AutomationPointDoc> points, List<AutomationPointDoc> span) {
  if (span.isEmpty) return [for (final p in points) p.copy()];
  final a = span.first.step, b = span.last.step;
  return [
    for (final p in points)
      if (p.step < a - 1e-9 || p.step > b + 1e-9) p.copy(),
    ...span,
  ]..sort((x, y) => x.step.compareTo(y.step));
}

/// The pencil's stroke ([samples]: step and height fraction, in drawing order) thinned to the points that bend it by
/// more than [tolerance] of the lane's height (Ramer-Douglas-Peucker, as the Automate button thins what it writes).
List<AutomationPointDoc> pencilPoints(List<(double, double)> samples, {double tolerance = 0.006}) => [
      for (final (step, f) in AutomationWriter.thin(samples, tolerance: tolerance))
        AutomationPointDoc(step: math.max(0, step), value: f.clamp(0.0, 1.0).toDouble()),
    ];

/// The line tool: a straight line from [a] to [b] (step, fraction), in time order.
List<AutomationPointDoc> linePoints((double, double) a, (double, double) b) {
  final (first, last) = a.$1 <= b.$1 ? (a, b) : (b, a);
  return [
    AutomationPointDoc(step: math.max(0, first.$1), value: first.$2.clamp(0.0, 1.0).toDouble()),
    if (last.$1 > first.$1) AutomationPointDoc(step: math.max(0, last.$1), value: last.$2.clamp(0.0, 1.0).toDouble()),
  ];
}

/// The shape tool: [shape] from step [from] to [to], one cycle every [period] steps (the grid), around [centre] (a
/// fraction) by [depth] (a fraction; below 0 starts downwards). Random holds a value [seed] picks for each period.
/// A sine is drawn with curved segments (fast from the centre to each peak, slow back), so it needs four points a
/// cycle. At most [maxPoints] points.
List<AutomationPointDoc> shapePoints(LaneShape shape, double from, double to, double period, double centre, double depth,
    {int seed = 1, int maxPoints = 4096}) {
  if (to < from) (from, to) = (to, from);
  from = math.max(0, from);
  final p = math.max(1e-3, period);
  final out = <AutomationPointDoc>[];
  double f(double v) => v.clamp(0.0, 1.0).toDouble();
  void add(double step, double v, [AutomationCurve curve = AutomationCurve.linear]) {
    if (out.length < maxPoints) out.add(AutomationPointDoc(step: step, value: f(v), curve: curve));
  }

  final hi = centre + depth, lo = centre - depth;
  final rnd = math.Random(seed);
  if (to - from < 1e-6) return out;
  var k = 0;
  for (var t = from; t < to - 1e-9 && out.length < maxPoints; t = from + (++k) * p) {
    final end = math.min(to, t + p);
    final quarter = p / 4;
    switch (shape) {
      case LaneShape.sine:
        add(t, centre, AutomationCurve.fast);
        if (t + quarter < end) add(t + quarter, hi, AutomationCurve.slow);
        if (t + 2 * quarter < end) add(t + 2 * quarter, centre, AutomationCurve.fast);
        if (t + 3 * quarter < end) add(t + 3 * quarter, lo, AutomationCurve.slow);
      case LaneShape.triangle:
        add(t, centre);
        if (t + quarter < end) add(t + quarter, hi);
        if (t + 3 * quarter < end) add(t + 3 * quarter, lo);
      case LaneShape.saw:
        add(t, lo);
        add(end, lo + (hi - lo) * (end - t) / p); // up the tooth; the next one's first point drops straight back
      case LaneShape.square:
        add(t, hi, AutomationCurve.step);
        if (t + p / 2 < end) add(t + p / 2, lo, AutomationCurve.step);
      case LaneShape.random:
        add(t, centre + depth * (2 * rnd.nextDouble() - 1), AutomationCurve.step);
    }
  }
  // The last point: where the shape is at [to] (a cycle cut short ends part way through it).
  if (out.isEmpty || out.last.step < to - 1e-9) {
    final phase = ((to - from) % p) / p;
    add(to, switch (shape) {
      LaneShape.sine => centre + depth * math.sin(2 * math.pi * phase),
      LaneShape.triangle => centre + depth * (phase < 0.25 ? 4 * phase : phase < 0.75 ? 2 - 4 * phase : 4 * phase - 4),
      LaneShape.square => phase < 0.5 ? hi : lo,
      _ => laneValueAt(out, to, centre),
    });
  }
  if (out.isNotEmpty) {
    out.last.curve = AutomationCurve.linear;
    out.last.tension = 0;
  }
  return out;
}

/// [points] without those from [from] to [to] (the eraser's sweep), the first and last kept when [keepOne] and the
/// sweep would empty the lane (a lane with no points plays its control's value; keep one so the lane holds).
List<AutomationPointDoc> erasePoints(List<AutomationPointDoc> points, double from, double to, {bool keepOne = true}) {
  if (to < from) (from, to) = (to, from);
  final kept = [for (final p in points) if (p.step < from || p.step > to) p.copy()];
  if (kept.isEmpty && keepOne && points.isNotEmpty) return [points.first.copy()];
  return kept;
}

/// The grid's step nearest [step] ([grid] steps apart; 0 or less: free).
double snapStep(double step, num grid) => grid <= 0 ? step : (step / grid).round() * grid.toDouble();

/// A selection transform's result: the lane's new points and which of them are the selection.
typedef Transformed = ({List<AutomationPointDoc> points, Set<int> selected});

/// [points] with the [selected] ones changed by [change] (from a copy of each: call it on the drag's first points
/// every time, so nothing drifts). Unselected points the moved ones now cover give way; the rest are kept exactly.
Transformed transformSelection(List<AutomationPointDoc> points, Set<int> selected,
    AutomationPointDoc Function(AutomationPointDoc p) change) {
  final moved = [for (var i = 0; i < points.length; i++) if (selected.contains(i)) change(points[i].copy())];
  if (moved.isEmpty) return (points: [for (final p in points) p.copy()], selected: <int>{});
  for (final p in moved) {
    p.step = math.max(0, p.step);
  }
  moved.sort((a, b) => a.step.compareTo(b.step));
  final a = moved.first.step, b = moved.last.step;
  final rest = [
    for (var i = 0; i < points.length; i++)
      if (!selected.contains(i) && (points[i].step < a - 1e-9 || points[i].step > b + 1e-9)) points[i].copy(),
  ];
  final all = [...rest, ...moved]..sort((x, y) => x.step.compareTo(y.step));
  return (points: all, selected: {for (var i = 0; i < all.length; i++) if (moved.any((m) => identical(m, all[i]))) i});
}

double _same(double v) => v;

/// Moves the selection by [dStep] steps and [dHeight] of the lane's height. [toHeight] and [toValue] turn a value
/// into a height fraction and back (the lane's scale; volume on the faders' taper).
Transformed moveSelection(List<AutomationPointDoc> points, Set<int> selected, double dStep, double dHeight,
        {double Function(double) toHeight = _same, double Function(double) toValue = _same}) =>
    transformSelection(points, selected, (p) => p..step += dStep..value = toValue(toHeight(p.value) + dHeight));

/// Scales the selection's heights about [anchor] (a fraction: the box's opposite edge) by [factor].
Transformed scaleSelection(List<AutomationPointDoc> points, Set<int> selected, double anchor, double factor,
        {double Function(double) toHeight = _same, double Function(double) toValue = _same}) =>
    transformSelection(points, selected, (p) => p..value = toValue(anchor + (toHeight(p.value) - anchor) * factor));

/// Tilts the selection: its points over [x0]..[x1] rise by [dLeft] of the height at the left end and [dRight] at
/// the right end, in a straight line between (a corner handle moves one end).
Transformed tiltSelection(List<AutomationPointDoc> points, Set<int> selected, double x0, double x1, double dLeft,
        double dRight, {double Function(double) toHeight = _same, double Function(double) toValue = _same}) =>
    transformSelection(points, selected, (p) {
      final t = x1 > x0 ? ((p.step - x0) / (x1 - x0)).clamp(0.0, 1.0) : 0.0;
      return p..value = toValue(toHeight(p.value) + dLeft + (dRight - dLeft) * t);
    });

/// Copied automation: points as fractions of the height, with steps from the first one's, so a paste fits any lane.
class AutomationClipboard {
  AutomationClipboard(this.points);
  final List<AutomationPointDoc> points;
  double get length => points.isEmpty ? 0 : points.last.step;

  /// What was copied last, in this run of the app.
  static AutomationClipboard? current;

  /// The [selected] points of [points], their values as heights through [toHeight].
  static AutomationClipboard? of(List<AutomationPointDoc> points, Set<int> selected,
      {double Function(double) toHeight = _same}) {
    final picked = [for (var i = 0; i < points.length; i++) if (selected.contains(i)) points[i]];
    if (picked.isEmpty) return null;
    final first = picked.first.step;
    return AutomationClipboard(
        [for (final p in picked) p.copy(step: p.step - first, value: toHeight(p.value), fresh: true)]);
  }

  /// [points] with this pasted at [at] (heights back to values through [toValue]), over what they had there; the
  /// pasted points are the selection.
  Transformed pasteInto(List<AutomationPointDoc> points, double at, {double Function(double) toValue = _same}) {
    // Each paste is new points (their own ids), however often the same copy goes in.
    final span = [for (final p in this.points) p.copy(step: math.max(0, at) + p.step, value: toValue(p.value), fresh: true)];
    final all = replaceSpan(points, span);
    return (points: all, selected: {for (var i = 0; i < all.length; i++) if (span.any((s) => identical(s, all[i]))) i});
  }
}

/// The automation points inside any of [spans] (from, to) moved by [shift] steps, where they land the lane's own
/// points giving way: clips moved with "Automation follows clips" on take the points over them along.
List<AutomationPointDoc> shiftSpans(List<AutomationPointDoc> points, List<(double, double)> spans, double shift) {
  bool within(double s, double by) => spans.any((r) => s >= r.$1 + by && s <= r.$2 + by);
  final inside = [for (final q in points) if (within(q.step, 0)) q];
  if (inside.isEmpty || shift == 0) return [for (final p in points) p.copy()];
  return [
    for (final q in points)
      if (!inside.contains(q) && !within(q.step, shift)) q.copy(),
    for (final q in inside) q.copy(step: math.max(0, q.step + shift)),
  ]..sort((x, y) => x.step.compareTo(y.step));
}

final _reveal = Expando<ValueNotifier<String?>>('automation reveal');

extension AutomationEdits on AppState {
  /// The lane Automate asked to show (its [automationKey]): its row scrolls itself into view and clears it.
  ValueNotifier<String?> get automationReveal => _reveal[this] ??= ValueNotifier<String?>(null);

  /// Where a paste or Automate puts its point: the playhead while playing, else where play would start.
  double get automationCursor => meters.playing ? playheadStep : (pausedStep ?? timeSelectionStart?.toDouble() ?? 0);

  /// [key] at the top of the automation picker's Recent group.
  void noteRecentAutomation(String key) {
    final r = project.recentAutomation..remove(key);
    r.insert(0, key);
    if (r.length > ProjectDoc.kRecentAutomation) r.removeRange(ProjectDoc.kRecentAutomation, r.length);
  }

  /// The value [t]'s control holds now, or null when [t] names nothing on [layer].
  double? controlValueOf(LayerDoc layer, AutomationTarget t) {
    switch (t.kind) {
      case 'track':
        return t.name == 'volume' ? layer.volume : t.name == 'pan' ? layer.pan : null;
      case 'instrument':
        final use = layer.instrument;
        if (use == null) return null;
        return use.params[t.name] ??
            useInfo(use)?.parameters.where((p) => p.id == t.name).firstOrNull?.defaultValue ?? 0;
      case 'component':
        final i = t.component ?? -1;
        if (i < 0 || i >= layer.components.length) return null;
        final use = layer.components[i];
        return use.params[t.name] ??
            useInfo(use)?.parameters.where((p) => p.id == t.name).firstOrNull?.defaultValue ?? 0;
    }
    return null;
  }

  /// Whether [t] already has a lane on [layer].
  bool hasLaneFor(LayerDoc layer, AutomationTarget t) => t.kind == 'track'
      ? layer.automation.any((a) => a.target == t.name)
      : project.automation.any((a) => a.key == t.key);

  /// Adds [t]'s lane on [layer], armed and flat at its control's value across the song; with [pointAt], a point
  /// there too (Automate's point at the playhead). Inside an edit; false when [t] names nothing on [layer].
  bool _addLane(ProjectDoc p, LayerDoc layer, AutomationTarget t, double value, {double? pointAt}) {
    final end = p.arrangementEndSteps.clamp(1, p.maxArrangementSteps).toDouble();
    final at = pointAt?.clamp(0.0, p.maxArrangementSteps.toDouble()).toDouble();
    final last = math.max(end, (at ?? 0) + 1);
    final points = [
      AutomationPointDoc(step: 0, value: value),
      if (at != null && at > 0.01) AutomationPointDoc(step: at, value: value),
      AutomationPointDoc(step: last, value: value),
    ];
    if (t.kind == 'track') {
      if (t.name != 'volume' && t.name != 'pan') return false;
      layer.automation.add(AutomationLaneDoc(target: t.name, points: points));
    } else {
      p.automation.add(ProjectAutomationLaneDoc(targetType: t.kind, target: t.name, layerId: layer.id,
          component: t.kind == 'component' ? t.component : null, points: points));
    }
    return true;
  }

  /// The automation picker's choice: [t]'s lane on [layer], armed and flat at its value now (one automation undo
  /// step), its lanes shown. A lane already there is only revealed.
  void addLaneFor(LayerDoc layer, AutomationTarget t) => _automate(layer, t, point: false);

  /// "Automate" on a control's hold menu (#230): opens [t]'s lane under its track, armed, scrolled into view, with a
  /// point at the playhead at the control's value; a lane already there is revealed. One automation undo step.
  /// Returns the lane's key, or null when [t] has no track lane to show (the master's chain, a modulator).
  String? automate(AutomationTarget t) {
    final layer = project.layers.where((l) => l.id == t.layerId).firstOrNull;
    if (layer == null) return null;
    return _automate(layer, t, point: true) ? t.key : null;
  }

  bool _automate(LayerDoc layer, AutomationTarget t, {required bool point}) {
    if (layer.isFolder && (!layer.busEnabled || t.kind != 'track')) return false;
    final value = controlValueOf(layer, t);
    if (value == null) return false;
    final exists = hasLaneFor(layer, t);
    endUndoStep();
    if (!exists) beginAutomationGesture();
    var made = exists;
    editProject((p) {
      layer.showLanes = true;
      if (!exists) made = _addLane(p, layer, t, value, pointAt: point ? automationCursor : null);
      if (made) noteRecentAutomation(t.key);
    });
    if (!exists) endAutomationGesture();
    endUndoStep();
    if (made) automationReveal.value = t.key;
    return made;
  }

  /// Clips on [layer] moved from [spans] (each from, to) by [shift] steps along the track: with "Automation follows
  /// clips" on, the points of the track's lanes over them (volume, pan, its instrument's and effects') go along.
  /// Call it inside the move's edit.
  void followClipAutomation(LayerDoc layer, List<(double, double)> spans, double shift) {
    if (!project.automationFollowsClips || shift == 0 || spans.isEmpty) return;
    for (final lane in layer.automation) {
      lane.points = shiftSpans(lane.points, spans, shift);
    }
    for (final lane in project.automation) {
      if (lane.layerId == layer.id) lane.points = shiftSpans(lane.points, spans, shift);
    }
  }
}
