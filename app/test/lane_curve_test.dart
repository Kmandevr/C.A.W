// The Curve tool's lane curves: values between points, bends, and keeping points in time order.
import 'package:caw/model/lane_curve.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('holds before the first point and after the last, and is straight between', () {
    final c = const LaneCurve([CurvePoint(4, 0.2), CurvePoint(12, 1)]);
    expect(c.valueAt(0), 0.2);
    expect(c.valueAt(20), 1);
    expect(c.valueAt(8), closeTo(0.6, 1e-9));
  });

  test('a bend eases in or out and keeps the ends', () {
    final up = const LaneCurve([CurvePoint(0, 0, 0.5), CurvePoint(10, 1)]);
    final down = const LaneCurve([CurvePoint(0, 0, -0.5), CurvePoint(10, 1)]);
    expect(up.valueAt(5), lessThan(0.5));
    expect(down.valueAt(5), greaterThan(0.5));
    expect(up.valueAt(10), 1);
    expect(up.valueAt(0), 0);
  });

  test('add keeps time order; move stays between neighbours; values and bends are clamped', () {
    var (c, i) = const LaneCurve().add(8, 0.5);
    expect(i, 0);
    (c, i) = c.add(2, 2);
    expect(i, 0);
    expect(c.points.map((p) => p.at), [2, 8]);
    expect(c.points.first.value, 1);
    c = c.move(0, 50, -1);
    expect(c.points.first.at, 8);
    expect(c.points.first.value, 0);
    expect(c.bend(0, 9).points.first.bend, 1);
    expect(c.segmentAt(5), isNull);
    expect(c.remove(0).points.length, 1);
  });
}
