// A note's own expression in the roll's extras panel: small curve editors (pitch, volume, timbre), vibrato and presets.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/pattern_doc.dart';
import 'theme.dart';

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

/// The vibrato knobs, the presets and an editor per curve, for the notes the extras panel is showing.
class ExpressionPanel extends StatelessWidget {
  const ExpressionPanel({super.key, required this.expr, required this.onChanged, required this.color, this.timeSnap = 0});
  final NoteExpression expr;
  final ValueChanged<NoteExpression> onChanged;
  final Color color;
  /// Grid spacing as a fraction of the note's duration; zero disables time snapping.
  final double timeSnap;

  @override
  Widget build(BuildContext context) {
    final e = expr;
    Widget slider(String label, double v, double min, double max, String Function(double) show, NoteExpression Function(double) set) =>
        Row(children: [
          SizedBox(width: 92, child: Text('$label ${show(v)}', style: Neon.code(size: 12))),
          Expanded(child: Slider(value: v.clamp(min, max), min: min, max: max, onChanged: (x) => onChanged(set(x)))),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      const Text('Expression', style: TextStyle(fontWeight: FontWeight.w700)),
      Wrap(spacing: 6, runSpacing: 4, children: [
        for (final (name, f) in expressionPresets) ActionChip(label: Text(name), onPressed: () => onChanged(f(e))),
      ]),
      const SizedBox(height: 6),
      Text('Pitch (semitones): tap to add a point, drag it, drag a line to bend it, hold to delete',
          style: TextStyle(color: Neon.dim, fontSize: 12)),
      NoteCurveEditor(
          points: e.bend, min: -12, max: 12, zero: 0, snap: 1, timeSnap: timeSnap, color: color, onChanged: (p) => onChanged(e.copyWith(bend: p))),
      slider('Vibrato', e.vibDepth, 0, 2, (v) => v.toStringAsFixed(2), (v) => e.copyWith(vibDepth: v)),
      slider('Rate', e.vibRate, 0.5, 12, (v) => '${v.toStringAsFixed(1)} Hz', (v) => e.copyWith(vibRate: v)),
      slider('Fade-in', e.vibFade, 0, 1, (v) => '${(v * 100).round()}%', (v) => e.copyWith(vibFade: v)),
      Text('Volume over the note', style: TextStyle(color: Neon.dim, fontSize: 12)),
      NoteCurveEditor(
          points: e.press, min: 0, max: 1, zero: 1, timeSnap: timeSnap, color: color, onChanged: (p) => onChanged(e.copyWith(press: p))),
      Text('Timbre (the sound reads it as timbre)', style: TextStyle(color: Neon.dim, fontSize: 12)),
      NoteCurveEditor(
          points: e.timbre, min: 0, max: 1, zero: 0, timeSnap: timeSnap, color: color, onChanged: (p) => onChanged(e.copyWith(timbre: p))),
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
    return pts.take(NoteExpression.maxPoints).toList();
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
      final y = s._y(NoteExpression.valueAt(points, x / size.width), size);
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
