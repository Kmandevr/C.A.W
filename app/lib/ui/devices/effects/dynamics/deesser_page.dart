// fx-dynamics: the De-esser UI (org.caw.deesser): the sibilance band on a frequency axis, its level against the threshold, and the reduction.
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

// The hero's frequency axis: 1 kHz .. 20 kHz (log).
double _fx(double hz) => (math.log(hz.clamp(1000, 20000) / 1000) / math.log(20)).toDouble();

/// The de-esser: the band it listens to (everything above the frequency, shaded) on a 1–20 kHz axis, the sibilance
/// level now (a bar in the band) against the threshold (a line), and the reduction hanging from the top. Drag
/// sideways for the frequency, up or down for the threshold. Split turns down only the band, Wideband everything.
class DeesserPage extends StatelessWidget {
  const DeesserPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('deesser', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('mode', height: 46, icon: (canvas, r, i, c) {
        // Split: only the top dips; Wideband: everything dips.
        iconCurve(canvas, r.deflate(3), c, (x) => i == 0 ? (x > 0.2 ? -0.4 : 0.3) : -0.1);
      })),
      HeroWithMeters(height: 200, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'DE-ESS',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) => Text(f?.gainReductionDb == null ? '' : '−${(-f!.gainReductionDb!).toStringAsFixed(1)} dB',
          style: Neon.code(size: 10, color: Neon.pink))),
        child: const _DeessHero(),
      )),
      const KnobRow(['freq', 'threshold', 'range', 'release'], size: 52),
      const Padding(padding: EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [
        DeviceToggle('listen', label: 'Listen', icon: Icons.hearing),
      ])),
    ]);
  }
}

class _DeessHero extends StatefulWidget {
  const _DeessHero();

  @override
  State<_DeessHero> createState() => _DeessHeroState();
}

class _DeessHeroState extends State<_DeessHero> {
  bool _active = false;
  double _freq = 6000, _thr = -30;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final freq = t.value('freq'), thr = t.value('threshold'), range = t.value('range');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final area = Rect.fromLTRB(8, 22, w - 8, h - 16);
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('deess-hero'),
        onStart: (_, _) {
          _freq = freq;
          _thr = thr;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          _freq = (_freq * math.pow(20, u.delta.dx / area.width * fine)).toDouble().clamp(2000.0, 16000.0);
          _thr = (_thr - u.delta.dy / area.height * 60 * fine).clamp(-60.0, 0.0);
          t.setLive('freq', _freq);
          t.setLive('threshold', _thr);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['freq', 'threshold']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, h), painter: _DeessPainter(area: area, freq: freq, thr: thr, range: range,
          level: f?.values['level_db'], gr: f?.gainReductionDb, color: scope.accent, second: scope.secondary, active: _active)),
      ));
    });
  }
}

class _DeessPainter extends CustomPainter {
  _DeessPainter({required this.area, required this.freq, required this.thr, required this.range, required this.level,
    required this.gr, required this.color, required this.second, required this.active});
  final Rect area;
  final double freq, thr, range;
  final double? level, gr;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    double yOf(double db) => area.bottom - dbUnit(db, floor: 60) * area.height;
    final fx = area.left + _fx(freq) * area.width;
    // The band it listens to: a high-pass's rise to the right of the frequency.
    final path = Path();
    for (var i = 0; i <= 80; i++) {
      final x = i / 80;
      final hz = 1000 * math.pow(20, x).toDouble();
      final r = hz / freq;
      final mag = r * r / math.sqrt(1 + r * r * r * r); // 2nd-order Butterworth high-pass, squared below
      final p = Offset(area.left + x * area.width, area.bottom - (mag * mag).clamp(0.0, 1.0) * area.height * 0.9);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    fillFade(canvas, path, area.bottom, Size(area.right, area.bottom), second, alpha: 0.25);
    strokeGlow(canvas, path, second, width: 1.6, glow: false);
    canvas.drawLine(Offset(fx, area.top), Offset(fx, area.bottom), Paint()
      ..color = second.withValues(alpha: active ? 0.9 : 0.5)
      ..strokeWidth = active ? 2 : 1);
    for (final k in [2.0, 5.0, 10.0]) {
      final x = area.left + _fx(k * 1000) * area.width;
      paintLabel(canvas, '${k.toStringAsFixed(0)}k', Offset(x, area.bottom + 8), Neon.dim, size: 8, align: 0);
    }
    // The sibilance level now, a bar in the band, and the threshold line across.
    if (level case final l? when l > -60) {
      final bx = math.min(area.right - 14, fx + 18);
      final top = yOf(l);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(bx - 7, top, bx + 7, area.bottom), const Radius.circular(3)),
        Paint()..color = (l > thr ? Neon.pink : color).withValues(alpha: 0.7));
    }
    final ty = yOf(thr);
    strokeGlow(canvas, Path()
      ..moveTo(area.left, ty)
      ..lineTo(area.right, ty), color, width: active ? 2.4 : 1.6, glow: active);
    paintHandle(canvas, Offset(fx, ty), color, active: active, r: 7);
    paintLabel(canvas, '${(freq / 1000).toStringAsFixed(1)} kHz  ${thr.toStringAsFixed(1)} dB', Offset(area.left + 4, ty - 11),
      color, size: 9, weight: FontWeight.w800);
    // The reduction, hanging from the top (up to the range).
    if (gr case final g? when g < -0.05) {
      final hgt = (-g / math.max(range, 1)).clamp(0.0, 1.0) * area.height * 0.4;
      canvas.drawRect(Rect.fromLTRB(fx, area.top, area.right, area.top + hgt), Paint()..color = Neon.pink.withValues(alpha: 0.3));
    }
  }

  @override
  bool shouldRepaint(covariant _DeessPainter o) =>
      paintInputsChanged([o.area, o.freq, o.thr, o.range, o.level, o.gr, o.color, o.second, o.active], [area, freq, thr, range, level, gr, color, second, active]);
}
