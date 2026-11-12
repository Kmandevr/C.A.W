// fx-dynamics: the Phase distortion UI (org.caw.phasedist): a sine cycle bent by its own value, the live delay swing of each side.
import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import 'fx_math.dart';

/// Phase distortion: two cycles of a sine (faint) and the same sine read early and late by its own value (bright),
/// as drive and bias set it, with the left and right delay now as two dots on a strip below (the centre is the
/// effect's fixed 1 ms). Drag up or down for drive, sideways for bias.
class PhaseDistPage extends StatelessWidget {
  const PhaseDistPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('phasedist', [
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'PHASE ≈',
        grid: false,
        readout: const LevelReadout(),
        child: const _PdHero(),
      )),
      const KnobRow(['drive', 'normalize', 'tone', 'bias', 'spread', 'mix'], size: 50),
    ]);
  }
}

class _PdHero extends StatefulWidget {
  const _PdHero();

  @override
  State<_PdHero> createState() => _PdHeroState();
}

class _PdHeroState extends State<_PdHero> {
  bool _active = false;
  double _drive = 0, _bias = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final drive = t.value('drive'), bias = t.value('bias'), mix = t.value('mix');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('pd-hero'),
        onStart: (_, _) {
          _drive = drive;
          _bias = bias;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          _drive = (_drive - u.delta.dy / (h * 0.8) * fine).clamp(0.0, 1.0);
          _bias = (_bias + u.delta.dx / w * 2 * fine).clamp(-1.0, 1.0);
          t.setLive('drive', _drive);
          t.setLive('bias', _bias);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['drive', 'bias']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, h), painter: _PdPainter(drive: drive, bias: bias, mix: mix,
          delayL: f?.values['delay_l_ms'], delayR: f?.values['delay_r_ms'], color: scope.accent, second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _PdPainter extends CustomPainter {
  _PdPainter({required this.drive, required this.bias, required this.mix, required this.delayL, required this.delayR,
    required this.color, required this.second, required this.active});
  final double drive, bias, mix;
  final double? delayL, delayR;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(10, 24, size.width - 10, size.height - 34);
    final mid = area.center.dy, amp = area.height / 2 * 0.9;
    final dry = Path(), wet = Path();
    for (var i = 0; i <= 200; i++) {
      final ph = 2 * i / 200;
      final x = area.left + i / 200 * area.width;
      final s = mid - amp * _sin(ph);
      final y = mid - amp * (_sin(ph) + (phaseDistorted(ph % 1, drive, bias) - _sin(ph)) * mix);
      i == 0 ? dry.moveTo(x, s) : dry.lineTo(x, s);
      i == 0 ? wet.moveTo(x, y) : wet.lineTo(x, y);
    }
    canvas.drawLine(Offset(area.left, mid), Offset(area.right, mid), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    canvas.drawPath(dry, Paint()
      ..color = Neon.ink.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);
    strokeGlow(canvas, wet, color, width: active ? 2.8 : 2.2);
    // The delay strip: 0..2 ms with the centre marked, a dot per side.
    final sy = size.height - 16;
    canvas.drawLine(Offset(area.left, sy), Offset(area.right, sy), Paint()
      ..color = Neon.ink.withValues(alpha: 0.1)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round);
    canvas.drawLine(Offset(area.center.dx, sy - 6), Offset(area.center.dx, sy + 6), Paint()..color = Neon.dim);
    for (final (ms, c, label) in [(delayL, color, 'L'), (delayR, second, 'R')]) {
      if (ms == null) continue;
      final x = area.left + (ms / 2).clamp(0.0, 1.0) * area.width;
      canvas.drawCircle(Offset(x, sy), 5, Paint()..color = c);
      paintLabel(canvas, label, Offset(x, sy - 11), c, size: 8, align: 0, weight: FontWeight.w800);
    }
    paintLabel(canvas, 'DELAY', Offset(area.left, sy - 11), Neon.dim, size: 8);
  }

  static double _sin(double ph) => phaseDistorted(ph % 1, 0, 0);

  @override
  bool shouldRepaint(covariant _PdPainter o) => true;
}
