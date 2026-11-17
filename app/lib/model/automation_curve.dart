// Automation segment curves (#230): the shapes a point's segment to the next can take, the engine's closed forms
// (engine/src/params.h automationCurveShape) and a lane's value at a step, as the engine plays it.
import 'project.dart';

/// The curve from a point to the next one: stored on the earlier point ([AutomationPointDoc.curve]), with a
/// tension of -1..1 that bends [slow], [fast] and [sCurve]. JSON names: absent (linear), `slow`, `fast`, `s`, `step`.
enum AutomationCurve {
  linear('linear', 'Linear'),
  slow('slow', 'Slow'),
  fast('fast', 'Fast'),
  sCurve('s', 'S-curve'),
  step('step', 'Step');

  const AutomationCurve(this.json, this.label);
  final String json, label;

  /// Whether its tension bends it.
  bool get bends => this == slow || this == fast || this == sCurve;

  /// An unknown or missing name reads linear (bounded on load, as the engine reads it).
  static AutomationCurve parse(Object? name) => values.where((c) => c.json == name).firstOrNull ?? linear;
}

/// A tension as stored: -1..1, anything else (not a number) 0; nothing for a curve it doesn't bend.
double boundTension(AutomationCurve curve, Object? raw) {
  if (!curve.bends || raw is! num || !raw.isFinite) return 0;
  return raw.toDouble().clamp(-1.0, 1.0).toDouble();
}

/// The curve's shape at [t] (0..1 through the segment): 0 at its start and 1 at its end. The engine's closed forms,
/// in the same order of operations (+, -, *, / only), so the app draws what plays:
///   b = 0.4375 (1 + tension)        (0 .. 0.875; tension -1 is a straight line)
///   slow(t) = t(1-b) / (t(1-b) + (1-t)(1+b)),  fast(t) = t(1+b) / (t(1+b) + (1-t)(1-b))
///   S-curve: slow(2t)/2 below t = 1/2, 1/2 + fast(2t-1)/2 from it;  step: 0 (holds until the next point).
double curveShape(AutomationCurve curve, double tension, double t) {
  if (curve == AutomationCurve.linear) return t;
  if (!(tension >= -1.0)) tension = -1.0;
  if (tension > 1.0) tension = 1.0;
  final b = 0.4375 * (1.0 + tension);
  double slow(double x) {
    final a = x * (1.0 - b);
    return a / (a + (1.0 - x) * (1.0 + b));
  }

  double fast(double x) {
    final a = x * (1.0 + b);
    return a / (a + (1.0 - x) * (1.0 - b));
  }

  return switch (curve) {
    AutomationCurve.slow => slow(t),
    AutomationCurve.fast => fast(t),
    AutomationCurve.sCurve => t < 0.5 ? 0.5 * slow(2.0 * t) : 0.5 + 0.5 * fast(2.0 * t - 1.0),
    AutomationCurve.step => 0.0,
    AutomationCurve.linear => t,
  };
}

/// The value along the segment from [a] to [b] at [at] (between their steps), through [a]'s curve.
double segmentValueAt(AutomationPointDoc a, AutomationPointDoc b, double at) {
  final span = b.step - a.step;
  if (span <= 0) return b.value;
  final t = (at - a.step) / span;
  if (a.curve == AutomationCurve.linear) return a.value + (b.value - a.value) * t;
  return a.value + (b.value - a.value) * curveShape(a.curve, a.tension, t);
}

/// A lane's value at [at] (its points in time order): the first point's value before it, the last's after it,
/// each segment's curve between, and the later point at a jump (two points at one step): the engine's
/// `automationLaneValue`. [fallback] for an empty lane.
double laneValueAt(List<AutomationPointDoc> points, double at, double fallback) {
  if (points.isEmpty) return fallback;
  if (at <= points.first.step) return points.first.value;
  if (at >= points.last.step) return points.last.value;
  var lo = 0, hi = points.length - 1;
  while (lo + 1 < hi) {
    final mid = (lo + hi) >> 1;
    if (points[mid].step <= at) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return segmentValueAt(points[lo], points[hi], at);
}

/// The segment's bend as one signed amount, -1..1: 0 straight, below 0 slow (eases in), above 0 fast (eases out);
/// an S-curve's is its amount 0..1. A sideways drag on the segment's handle changes it ([withBend]).
double bendOf(AutomationPointDoc p) => switch (p.curve) {
      AutomationCurve.slow => -(p.tension + 1) / 2,
      AutomationCurve.fast => (p.tension + 1) / 2,
      AutomationCurve.sCurve => (p.tension + 1) / 2,
      _ => 0,
    };

/// [p]'s curve bent to [bend] (as [bendOf] reads it): a linear, slow or fast segment becomes slow below 0, fast above
/// and linear near 0; an S-curve keeps its shape with a new amount; a step doesn't bend.
void withBend(AutomationPointDoc p, double bend) {
  final b = bend.clamp(-1.0, 1.0).toDouble();
  switch (p.curve) {
    case AutomationCurve.step:
      return;
    case AutomationCurve.sCurve:
      p.tension = (2 * b.abs() - 1).clamp(-1.0, 1.0).toDouble();
    default:
      if (b.abs() < 0.02) {
        p.curve = AutomationCurve.linear;
        p.tension = 0;
      } else {
        p.curve = b < 0 ? AutomationCurve.slow : AutomationCurve.fast;
        p.tension = (2 * b.abs() - 1).clamp(-1.0, 1.0).toDouble();
      }
  }
}
