// fx-dynamics: the Clipper UI (org.caw.clipper): the curve against its ceiling with the input riding it, how far peaks went over, and Clip to 0 dB.
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

double _db(double v) => math.pow(10, v / 20).toDouble();

/// The clipper: Hard, Soft and Analog as drawn-curve tiles, then the transfer curve (input −1..1 after the drive)
/// under its ceiling line, with dots where the input's peak sits and a readout of how far peaks went over. Drag the
/// ceiling line up or down for the ceiling; anywhere else, up or down for the drive and sideways for the softness.
/// Clip to 0 dB holds every sample to full scale for mastering (the ceiling, output and mix then step aside).
class ClipperPage extends StatelessWidget {
  const ClipperPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final master = scope.target.value('master') >= 0.5;
    return effectPage('clipper', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('mode', height: 52, icon: (canvas, r, i, c) {
        iconCurve(canvas, r.deflate(2), c, (x) => clipCurve(i, x * 2.2, 0.6) * 0.8);
      })),
      HeroWithMeters(height: 210, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: master ? 'CLIP TO 0 dB' : 'CLIPPER',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final over = f?.values['over_db'];
          return Text(over == null ? '' : 'over ${over.toStringAsFixed(1)} dB',
            style: Neon.code(size: 10, color: over != null && over > 0.05 ? Neon.pink : Neon.dim));
        }),
        child: const _ClipHero(),
      )),
      KnobRow(['drive', if (!master) 'ceiling', 'softness', if (!master) ...['output', 'mix']], size: 50),
      const Padding(padding: EdgeInsets.only(top: 6, bottom: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [
        DeviceToggle('master', label: 'Clip to 0 dB', icon: Icons.vertical_align_top),
      ])),
      const ParamGrid(only: ['oversample']),
    ]);
  }
}

class _ClipHero extends StatefulWidget {
  const _ClipHero();

  @override
  State<_ClipHero> createState() => _ClipHeroState();
}

class _ClipHeroState extends State<_ClipHero> {
  String? _param;
  double _drive = 0, _ceiling = 0, _soft = 0.5;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final mode = t.value('mode').round(), drive = t.value('drive'), soft = t.value('softness');
    final master = t.value('master') >= 0.5;
    final ceiling = master ? 0.0 : t.value('ceiling');
    final g = _db(drive), c = _db(ceiling);
    double curve(double x) => c * clipCurve(mode, x * g / c, soft);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final side = math.min(h - 30, w - 24);
      final sq = Rect.fromLTWH((w - side) / 2, 24, side, side);
      double yOf(double v) => sq.top + (1 - (v.clamp(-1.15, 1.15) + 1) / 2) * sq.height;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('clip-hero'),
        onStart: (p, _) {
          _drive = drive;
          _ceiling = ceiling;
          _soft = soft;
          _param = !master && (p.dy - yOf(c)).abs() < 18 ? 'ceiling' : 'drive';
          setState(() {});
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          if (_param == 'ceiling') {
            // The line follows the finger: its height is the ceiling's gain.
            final gain = (_db(_ceiling) - u.delta.dy / (sq.height / 2) * fine).clamp(0.063, 1.0);
            _ceiling = 20 * math.log(gain) / math.ln10;
            t.setLive('ceiling', _ceiling.clamp(-24.0, 0.0));
          } else {
            _drive = (_drive - u.delta.dy / sq.height * 24 * fine).clamp(0.0, 24.0);
            _soft = (_soft + u.delta.dx / sq.width * fine).clamp(0.0, 1.0);
            t.setLive('drive', _drive);
            t.setLive('softness', _soft);
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _param = null);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['drive', 'ceiling', 'softness']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, h), painter: _ClipPainter(sq: sq, curve: curve, ceiling: c, yOf: yOf,
          input: f?.inputDb, color: scope.accent, second: scope.secondary, active: _param)),
      ));
    });
  }
}

class _ClipPainter extends CustomPainter {
  _ClipPainter({required this.sq, required this.curve, required this.ceiling, required this.yOf, required this.input,
    required this.color, required this.second, required this.active});
  final Rect sq;
  final double Function(double x) curve;
  final double ceiling;
  final double Function(double v) yOf;
  final double? input;
  final Color color, second;
  final String? active;

  @override
  void paint(Canvas canvas, Size size) {
    Offset pt(double x, double y) => Offset(sq.left + (x + 1) / 2 * sq.width, yOf(y));
    final faint = Paint()..color = Colors.white.withValues(alpha: 0.08);
    canvas.drawRect(sq, Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke);
    canvas.drawLine(pt(-1, 0), pt(1, 0), faint);
    canvas.drawLine(pt(0, -1), pt(0, 1), faint);
    canvas.drawLine(pt(-1, -1), pt(1, 1), Paint()..color = Colors.white.withValues(alpha: 0.12));
    // The ceiling, both ways.
    for (final s in [1.0, -1.0]) {
      final y = yOf(s * ceiling);
      final p = Path()
        ..moveTo(sq.left, y)
        ..lineTo(sq.right, y);
      strokeGlow(canvas, p, second, width: active == 'ceiling' ? 2.4 : 1.2, glow: active == 'ceiling');
    }
    paintHandle(canvas, Offset(sq.right - 10, yOf(ceiling)), second, active: active == 'ceiling', r: 6);
    paintLabel(canvas, '${(20 * math.log(ceiling) / math.ln10).toStringAsFixed(1)} dB', Offset(sq.left + 4, yOf(ceiling) + 10), second,
      size: 8, weight: FontWeight.w700);
    final path = Path();
    for (var i = 0; i <= 160; i++) {
      final x = -1 + 2 * i / 160;
      final p = pt(x, curve(x));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.save();
    canvas.clipRect(sq.inflate(2));
    strokeGlow(canvas, path, color, width: active == 'drive' ? 3 : 2.4);
    canvas.restore();
    if (input case final db? when db > -60) {
      final a = math.pow(10, db / 20).toDouble().clamp(0.0, 1.0);
      for (final x in [a, -a]) {
        final p = pt(x, curve(x));
        canvas.drawCircle(p, 9, Paint()..color = Colors.white.withValues(alpha: 0.14));
        canvas.drawCircle(p, 4, Paint()..color = Colors.white);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ClipPainter o) => true;
}
