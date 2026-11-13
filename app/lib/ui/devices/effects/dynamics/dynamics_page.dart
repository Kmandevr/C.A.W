// fx-dynamics: the Dynamics UI (org.caw.dynamics): the transfer curve with two draggable threshold handles and a live dot.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import 'fx_math.dart';

const _floor = 72.0; // the curve's axes: -72..0 dB

/// Dynamics: the input-to-output curve (−72..0 dB both ways) with a handle at each threshold. Drag a handle
/// sideways for its threshold, up or down for its ratio (up gives more output: below the low threshold that is
/// upward compression, above the high one upward expansion). The white dot rides the curve at the detector's level;
/// the bar on the right is the gain change now (up: lift, down: cut).
class DynamicsPage extends StatelessWidget {
  const DynamicsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('dynamics', [
      HeroWithMeters(height: 220, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 220,
        caption: 'DYNAMICS',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final g = f?.values['gain_db'];
          return Text(g == null ? '' : '${g >= 0 ? '+' : ''}${g.toStringAsFixed(1)} dB',
            style: Neon.code(size: 10, color: (g ?? 0) >= 0 ? scope.accent : Neon.pink));
        }),
        child: const _DynamicsHero(),
      )),
      const KnobRow(['low_threshold', 'low_ratio', 'high_threshold', 'high_ratio', 'attack', 'release'], size: 50,
        labels: {'low_threshold': 'Low thr', 'high_threshold': 'High thr'}),
      const KnobRow(['knee', 'range', 'in_gain', 'out_gain', 'mix'], size: 44),
      const DeviceFold(child: ParamGrid(only: ['detect'])),
    ]);
  }
}

class _DynamicsHero extends StatefulWidget {
  const _DynamicsHero();

  @override
  State<_DynamicsHero> createState() => _DynamicsHeroState();
}

class _DynamicsHeroState extends State<_DynamicsHero> {
  String? _side; // 'low' or 'high' while dragging
  double _thr = 0, _ratio = 1;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    double v(String id, double d) => t.param(id) == null ? d : t.value(id);
    final lowThr = v('low_threshold', -40), lowRatio = v('low_ratio', 1), highThr = v('high_threshold', -12);
    final highRatio = v('high_ratio', 2), knee = v('knee', 6), range = v('range', 24);
    double out(double x) => x + dynamicsGainDb(x, lowThr: lowThr, lowRatio: lowRatio, highThr: highThr, highRatio: highRatio,
        knee: knee, range: range);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final plot = Rect.fromLTRB(10, 22, w - 22, h - 8);
      Offset pt(double inDb, double outDb) =>
          Offset(plot.left + dbUnit(inDb, floor: _floor) * plot.width, plot.bottom - dbUnit(outDb, floor: _floor) * plot.height);
      final lowAt = pt(math.min(lowThr, highThr), out(math.min(lowThr, highThr))), highAt = pt(highThr, out(highThr));
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('dyn-hero'),
        onStart: (p, _) {
          _side = (p - lowAt).distance < (p - highAt).distance ? 'low' : 'high';
          _thr = _side == 'low' ? lowThr : highThr;
          _ratio = _side == 'low' ? lowRatio : highRatio;
          setState(() {});
        },
        onUpdate: (u) {
          final side = _side;
          if (side == null) return;
          final fine = DeviceFingers.fine;
          _thr = (_thr + u.delta.dx / plot.width * _floor * fine).clamp(-80.0, 0.0);
          // Up gives more output: below the low threshold a larger ratio, above the high one a smaller.
          final up = -u.delta.dy / 50 * fine;
          _ratio = (_ratio * math.pow(2, side == 'low' ? up : -up)).toDouble().clamp(0.1, 10.0);
          t.setLive('${side}_threshold', _thr);
          t.setLive('${side}_ratio', _ratio);
        },
        onEnd: () {
          t.commit();
          setState(() => _side = null);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['low_threshold', 'low_ratio', 'high_threshold', 'high_ratio'])
            if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, h), painter: _DynamicsPainter(
          plot: plot, pt: pt, out: out, lowAt: lowAt, highAt: highAt, lowRatio: lowRatio, highRatio: highRatio,
          level: f?.values['level_db'], gain: f?.values['gain_db'], boost: f?.values['boost_db'], cut: f?.values['cut_db'],
          color: scope.accent, second: scope.secondary, active: _side)),
      ));
    });
  }
}

class _DynamicsPainter extends CustomPainter {
  _DynamicsPainter({required this.plot, required this.pt, required this.out, required this.lowAt, required this.highAt,
    required this.lowRatio, required this.highRatio, required this.level, required this.gain, required this.boost,
    required this.cut, required this.color, required this.second, required this.active});
  final Rect plot;
  final Offset Function(double inDb, double outDb) pt;
  final double Function(double x) out;
  final Offset lowAt, highAt;
  final double lowRatio, highRatio;
  final double? level, gain, boost, cut;
  final Color color, second;
  final String? active;

  @override
  void paint(Canvas canvas, Size size) {
    final faint = Paint()..color = Neon.ink.withValues(alpha: 0.07);
    for (final d in [-60.0, -48.0, -36.0, -24.0, -12.0]) {
      canvas.drawLine(pt(d, -_floor), pt(d, 0), faint);
      canvas.drawLine(pt(-_floor, d), pt(0, d), faint);
    }
    canvas.drawLine(pt(-_floor, -_floor), pt(0, 0), Paint()..color = Neon.ink.withValues(alpha: 0.14));
    // The three regions, tinted: lifted (above the unity line) in the family colour, cut in pink.
    final path = Path();
    for (var i = 0; i <= 120; i++) {
      final x = -_floor + _floor * i / 120;
      final p = pt(x, out(x));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.save();
    canvas.clipRect(plot.inflate(1));
    fillFade(canvas, path, plot.bottom, Size(plot.right, plot.bottom), color, alpha: 0.18);
    strokeGlow(canvas, path, color, width: active == null ? 2.2 : 2.8);
    if (level case final l? when l > -_floor) {
      final x = l.clamp(-_floor, 0.0);
      final p = pt(x, out(x));
      canvas.drawCircle(p, 10, Paint()..color = Neon.ink.withValues(alpha: 0.15));
      canvas.drawCircle(p, 5, Paint()..color = Neon.ink);
    }
    canvas.restore();
    paintHandle(canvas, lowAt, second, active: active == 'low', r: 7, label: 'L');
    paintHandle(canvas, highAt, color, active: active == 'high', r: 7, label: 'H');
    paintLabel(canvas, ratioLabel(lowRatio), lowAt + const Offset(0, 18), second, size: 9, align: 0, weight: FontWeight.w800);
    paintLabel(canvas, ratioLabel(highRatio), highAt + const Offset(0, -18), color, size: 9, align: 0, weight: FontWeight.w800);
    paintLabel(canvas, 'in → out', Offset(plot.left + 4, plot.top + 8), Neon.dim, size: 8);
    // The gain change now: a bar from the middle of the right edge, up for lift, down for cut (24 dB each way).
    final bx = size.width - 12, mid = plot.center.dy, half = plot.height / 2;
    canvas.drawLine(Offset(bx, plot.top), Offset(bx, plot.bottom), Paint()
      ..color = Neon.ink.withValues(alpha: 0.08)
      ..strokeWidth = 6);
    if (gain case final g?) {
      final y = mid - (g / 24).clamp(-1.0, 1.0) * half;
      canvas.drawLine(Offset(bx, mid), Offset(bx, y), Paint()
        ..color = g >= 0 ? color : Neon.pink
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round);
    }
    for (final (v, c) in [(boost, color), (-(cut ?? 0), Neon.pink)]) {
      if (v == null || v.abs() < 0.1) continue;
      final y = mid - (v / 24).clamp(-1.0, 1.0) * half;
      canvas.drawLine(Offset(bx - 5, y), Offset(bx + 5, y), Paint()
        ..color = c
        ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _DynamicsPainter o) =>
      paintInputsChanged([o.plot, o.pt, o.out, o.lowAt, o.highAt, o.lowRatio, o.highRatio, o.level, o.gain, o.boost, o.cut, o.color, o.second, o.active], [plot, pt, out, lowAt, highAt, lowRatio, highRatio, level, gain, boost, cut, color, second, active]);
}
