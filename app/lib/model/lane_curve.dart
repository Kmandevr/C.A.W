// A lane curve for the piano roll's Curve tool: points in time with a value 0..1, joined by segments that bend.
import 'dart:math' as math;

/// One point: [at] in 16th steps, [value] 0..1, and how the segment after it bends (-1..1, 0 is straight).
class CurvePoint {
  const CurvePoint(this.at, this.value, [this.bend = 0]);
  final double at, value, bend;

  CurvePoint copyWith({double? at, double? value, double? bend}) => CurvePoint(
        at ?? this.at,
        (value ?? this.value).clamp(0, 1).toDouble(),
        (bend ?? this.bend).clamp(-1, 1).toDouble(),
      );
}

/// Points kept in time order. Before the first point and after the last, the curve holds their values.
class LaneCurve {
  const LaneCurve([this.points = const []]);
  final List<CurvePoint> points;

  bool get isEmpty => points.isEmpty;

  /// A positive bend eases in (starts slow), a negative one eases out; the shape is u^(4^bend).
  static double shape(double u, double bend) => bend == 0 ? u : math.pow(u, math.pow(4, bend)).toDouble();

  double valueAt(double at) {
    if (points.isEmpty) return 0;
    if (at <= points.first.at) return points.first.value;
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      if (at <= b.at) {
        final u = b.at == a.at ? 1.0 : (at - a.at) / (b.at - a.at);
        return a.value + (b.value - a.value) * shape(u, a.bend);
      }
    }
    return points.last.value;
  }

  /// Adds a point and returns the new curve and the point's index.
  (LaneCurve, int) add(double at, double value) {
    final p = CurvePoint(math.max(0, at), value.clamp(0, 1).toDouble());
    final i = points.indexWhere((q) => q.at > p.at);
    final idx = i < 0 ? points.length : i;
    return (LaneCurve([...points.take(idx), p, ...points.skip(idx)]), idx);
  }

  /// Moves point [i], kept between its neighbours in time.
  LaneCurve move(int i, double at, double value) {
    final lo = i > 0 ? points[i - 1].at : 0.0, hi = i + 1 < points.length ? points[i + 1].at : double.infinity;
    return _replace(i, points[i].copyWith(at: at.clamp(lo, hi).toDouble(), value: value));
  }

  /// Sets the bend of the segment after point [i].
  LaneCurve bend(int i, double bend) => _replace(i, points[i].copyWith(bend: bend));

  LaneCurve remove(int i) => LaneCurve([...points.take(i), ...points.skip(i + 1)]);

  /// The segment (index of its first point) that spans [at], or null outside the points.
  int? segmentAt(double at) {
    for (var i = 0; i + 1 < points.length; i++) {
      if (at > points[i].at && at < points[i + 1].at) return i;
    }
    return null;
  }

  LaneCurve _replace(int i, CurvePoint p) => LaneCurve([...points.take(i), p, ...points.skip(i + 1)]);
}
