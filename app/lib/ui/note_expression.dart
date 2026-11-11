// A note's own expression in the roll's extras panel: small curve editors (pitch, volume, timbre), vibrato and presets.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/pattern_doc.dart';
import 'theme.dart';
import 'widgets.dart';

/// Shapes to stamp on a note (the owner asked for presets besides drawing and the vibrato knob).
final List<(String, NoteExpression Function(NoteExpression))> expressionPresets = [
  ('Scoop up', (e) => e.copyWith(bend: const [NotePoint(0, -2, -0.5), NotePoint(0.15, 0), NotePoint(1, 0)])),
  ('Fall off', (e) => e.copyWith(bend: const [NotePoint(0, 0), NotePoint(0.7, 0, 0.6), NotePoint(1, -5)])),
  ('Bend up 2', (e) => e.copyWith(bend: const [NotePoint(0, 0, 0.4), NotePoint(0.5, 2), NotePoint(1, 2)])),
  ('Dive', (e) => e.copyWith(bend: const [NotePoint(0, 0, 0.6), NotePoint(1, -12)])),
  ('Vibrato', (e) => e.copyWith(vibDepth: 0.4, vibRate: 5.5, vibFade: 0.3)),
  (
    'Trill',
    (e) => e.copyWith(bend: [
          for (var i = 0; i < 16; i++) NotePoint(i / 15, i.isEven ? 0 : 2, i.isEven ? 0.9 : -0.9),
        ])
  ),
  ('Swell', (e) => e.copyWith(press: const [NotePoint(0, 0.2, 0.5), NotePoint(1, 1)])),
  ('Fade', (e) => e.copyWith(press: const [NotePoint(0, 1), NotePoint(1, 0, -0.5)])),
  ('Clear', (e) => NoteExpression.none),
];

/// Curve [c] as the editors draw it, at [u] (0..1) across a note [widthPx] wide (owner, 2026-11-10: "the bend was
/// always smooth ... just the UI"): the stored curve, with the corner at each point softened over at most [soften] px
/// each side (a third of a segment at most) by a monotone cubic through the point's true value, so the point stays
/// where it is drawn and nothing overshoots. Display only: the sound and the stored points follow
/// [NoteExpression.valueAt].
double displayCurveAt(List<NotePoint> c, double u, double widthPx, {double empty = 0, double soften = 6}) {
  if (c.isEmpty) return empty;
  final raw = NoteExpression.valueAt(c, u, empty: empty);
  if (c.length < 2 || widthPx <= 0) return raw;
  final r = soften / widthPx;
  // Only the points either side of u can have a window over it.
  var hi = c.length;
  for (var lo = 0; lo < hi;) {
    final mid = (lo + hi) >> 1;
    c[mid].t < u ? lo = mid + 1 : hi = mid;
  }
  for (final i in [hi - 1, hi]) {
    if (i < 0 || i >= c.length) continue;
    final t = c[i].t;
    final left = i > 0 ? c[i - 1].t : 0.0, right = i + 1 < c.length ? c[i + 1].t : 1.0;
    final rl = math.min(r, (t - left) / 3), rr = math.min(r, (right - t) / 3);
    if (rl <= 1e-9 || rr <= 1e-9 || u <= t - rl || u >= t + rr) continue;
    final ta = t - rl, tb = t + rr, eps = math.min(rl, rr) * 0.05;
    double at(double x) => NoteExpression.valueAt(c, x, empty: empty);
    final a = at(ta), b = at(tb), v = c[i].v;
    final dl = (v - a) / rl, dr = (b - v) / rr;
    // The slope through the point: none at a peak or a valley, else the harmonic mean of the two sides.
    final m = dl * dr <= 0 ? 0.0 : 2 / (1 / dl + 1 / dr);
    // Each end keeps the stored curve's slope there, limited so the cubic stays monotone (Fritsch-Carlson).
    double limit(double s, double d) => d == 0 || s / d < 0 ? 0 : (s / d > 3 ? 3 * d : s);
    final sa = limit((a - at(ta - eps)) / eps, dl), sb = limit((at(tb + eps) - b) / eps, dr);
    double hermite(double p0, double m0, double p1, double m1, double h, double x) {
      final x2 = x * x, x3 = x2 * x;
      return (2 * x3 - 3 * x2 + 1) * p0 + (x3 - 2 * x2 + x) * h * m0 + (-2 * x3 + 3 * x2) * p1 + (x3 - x2) * h * m1;
    }
    return u < t ? hermite(a, sa, v, m, rl, (u - ta) / rl) : hermite(v, m, b, sb, rr, (u - t) / rr);
  }
  return raw;
}

/// The vibrato knobs, the presets and an editor per curve, for the notes the extras panel is showing.
class ExpressionPanel extends StatelessWidget {
  const ExpressionPanel(
      {super.key, required this.expr, required this.onChanged, required this.color, this.timeSnap = 0, this.valueSnap = 0});
  final NoteExpression expr;
  final ValueChanged<NoteExpression> onChanged;
  final Color color;
  /// Grid spacing as a fraction of the note's duration; zero disables time snapping.
  final double timeSnap;

  /// The value grid for volume and timbre (0..1); zero disables value snapping. Pitch always snaps to semitones.
  final double valueSnap;

  @override
  Widget build(BuildContext context) {
    final e = expr;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Heading('Expression'),
      Wrap(spacing: 6, runSpacing: 4, children: [
        for (final (name, f) in expressionPresets) ActionChip(label: Text(name), onPressed: () => onChanged(f(e))),
      ]),
      const SizedBox(height: 6),
      Text('Pitch (semitones): tap to add a point, drag it, drag a line to bend it, hold to delete',
          style: TextStyle(color: Neon.dim, fontSize: 12)),
      NoteCurveEditor(
          points: e.bend, min: -12, max: 12, zero: 0, snap: 1, timeSnap: timeSnap, color: color, onChanged: (p) => onChanged(e.copyWith(bend: p))),
      // Vibrato: big sliders with a type-in and a reset (none, 5 Hz, no fade-in).
      ValueSlider(label: 'Vibrato depth', value: e.vibDepth, min: 0, max: 2, reset: 0, scale: 100, unit: ' cents',
          onChanged: (v) => onChanged(e.copyWith(vibDepth: v))),
      ValueSlider(label: 'Vibrato rate', value: e.vibRate, min: 0.5, max: 12, reset: const NoteExpression().vibRate,
          decimals: 1, unit: ' Hz', onChanged: (v) => onChanged(e.copyWith(vibRate: v))),
      ValueSlider(label: 'Vibrato fade-in', value: e.vibFade, min: 0, max: 1, reset: 0, scale: 100, unit: '%',
          onChanged: (v) => onChanged(e.copyWith(vibFade: v))),
      Text('Volume over the note', style: TextStyle(color: Neon.dim, fontSize: 12)),
      NoteCurveEditor(
          points: e.press, min: 0, max: 1, zero: 1, snap: valueSnap, timeSnap: timeSnap, color: color, onChanged: (p) => onChanged(e.copyWith(press: p))),
      Text('Timbre (the sound reads it as timbre)', style: TextStyle(color: Neon.dim, fontSize: 12)),
      NoteCurveEditor(
          points: e.timbre, min: 0, max: 1, zero: 0, snap: valueSnap, timeSnap: timeSnap, color: color, onChanged: (p) => onChanged(e.copyWith(timbre: p))),
    ]);
  }
}

/// A curve over one note (time 0..1 across, [min]..[max] up): tap adds a point, drag moves one, drag between two bends
/// that segment, long-press deletes. An empty curve shows a flat dashed line at [zero], the value the note has
/// without one. [snap] rounds values while dragging (0 = none).
class NoteCurveEditor extends StatefulWidget {
  const NoteCurveEditor({
    super.key,
    required this.points,
    required this.min,
    required this.max,
    required this.zero,
    required this.color,
    required this.onChanged,
    this.snap = 0,
    this.timeSnap = 0,
    this.height = 72,
  });
  final List<NotePoint> points;
  final double min, max, zero, snap, timeSnap, height;
  final Color color;
  final ValueChanged<List<NotePoint>> onChanged;

  @override
  State<NoteCurveEditor> createState() => _NoteCurveEditorState();
}

class _NoteCurveEditorState extends State<NoteCurveEditor> {
  int? _point, _seg;
  double _bend0 = 0, _startY = 0;

  double _x(double t, Size s) => t * s.width;
  double _y(double v, Size s) => (1 - (v - widget.min) / (widget.max - widget.min)) * (s.height - 8) + 4;
  double _t(double x, Size s) => NoteExpression.snapTime(x / s.width, grid: widget.timeSnap);
  double _v(double y, Size s) {
    var v = widget.min + (1 - (y - 4) / (s.height - 8)) * (widget.max - widget.min);
    if (widget.snap > 0) v = (v / widget.snap).roundToDouble() * widget.snap;
    return v.clamp(widget.min, widget.max).toDouble();
  }

  int? _near(Offset p, Size s) {
    final pts = widget.points;
    for (var i = 0; i < pts.length; i++) {
      if ((Offset(_x(pts[i].t, s), _y(pts[i].v, s)) - p).distance < 18) return i;
    }
    return null;
  }

  List<NotePoint> _with(NotePoint q) {
    final pts = [...widget.points];
    final i = pts.indexWhere((p) => p.t > q.t);
    pts.insert(i < 0 ? pts.length : i, q);
    return pts;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, widget.height);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (_near(d.localPosition, size) != null) return;
            widget.onChanged(_with(NotePoint(_t(d.localPosition.dx, size), _v(d.localPosition.dy, size))));
          },
          onLongPressStart: (d) {
            final i = _near(d.localPosition, size);
            if (i != null) widget.onChanged([...widget.points]..removeAt(i));
          },
          onPanStart: (d) {
            final p = d.localPosition;
            _point = _near(p, size);
            _seg = null;
            _startY = p.dy;
            if (_point == null) {
              final t = _t(p.dx, size), pts = widget.points;
              for (var i = 0; i + 1 < pts.length; i++) {
                if (t > pts[i].t && t < pts[i + 1].t) {
                  _seg = i;
                  _bend0 = pts[i].k;
                }
              }
              if (_seg == null) {
                // Outside the points (or none yet): start a new point here and drag it.
                final q = NotePoint(t, _v(p.dy, size));
                final next = _with(q);
                _point = next.indexOf(q);
                widget.onChanged(next);
              }
            }
          },
          onPanUpdate: (d) {
            final pts = [...widget.points];
            final i = _point, seg = _seg;
            if (i != null && i < pts.length) {
              final lo = i > 0 ? pts[i - 1].t : 0.0, hi = i + 1 < pts.length ? pts[i + 1].t : 1.0;
              pts[i] = NotePoint(_t(d.localPosition.dx, size).clamp(lo, hi), _v(d.localPosition.dy, size), pts[i].k);
              widget.onChanged(pts);
            } else if (seg != null && seg < pts.length) {
              // Up bends the segment to rise late (eases in), down to rise early.
              final k = (_bend0 - (d.localPosition.dy - _startY) / size.height * 2).clamp(-1.0, 1.0);
              pts[seg] = NotePoint(pts[seg].t, pts[seg].v, (k * 100).roundToDouble() / 100);
              widget.onChanged(pts);
            }
          },
          onPanEnd: (_) => _point = _seg = null,
          child: CustomPaint(
            size: size,
            painter: _CurvePainter(widget.points, widget, this),
          ),
        );
      });
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.points, this.w, this.s);
  final List<NotePoint> points;
  final NoteCurveEditor w;
  final _NoteCurveEditorState s;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)), Paint()..color = Neon.bg);
    final zeroY = s._y(w.zero, size);
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), Paint()..color = Neon.line);
    if (points.isEmpty) return;
    final path = Path();
    for (var x = 0.0; x <= size.width; x += 2) {
      final y = s._y(displayCurveAt(points, x / size.width, size.width), size);
      x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, Paint()
      ..color = w.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    for (final p in points) {
      canvas.drawCircle(Offset(s._x(p.t, size), s._y(p.v, size)), math.max(4, 5), Paint()..color = Neon.text);
    }
  }

  @override
  bool shouldRepaint(_CurvePainter o) => true;
}
