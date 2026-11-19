// The Bit distortion device page (org.caw.bits, 1.0.8; Crush): a sine as a staircase, its step heights from the bits and widths from the rate, both drawn.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../creative/creative_common.dart' show dragAlongTaper;
import '../effect_page.dart';
import '../eqfilter/variant_cards.dart' show VariantCards;
import 'bitwise_device.dart';

/// Bit distortion (Crush): two cycles of a 400 Hz sine (≈) as the crusher holds and rounds it: the levels the bits
/// allow as faint lines on the left (when few enough to see), each sample the rate takes as a tick along the bottom,
/// the staircase in the family's colour over the clean wave, smoothed back toward it by Anti-image. Drag up and
/// down for the bits, sideways for the rate. Bits and rate as big knobs, jitter and dither under them, the
/// converter filters under MORE (Output and Mix are the footer's). Bitwise is its own page ([BitwiseDevice]).
class BitsDevice extends StatelessWidget {
  const BitsDevice({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final inline = DeviceScope.isInline(context);
    final cards = Padding(padding: const EdgeInsets.only(bottom: 8), child: VariantCards(height: inline ? 44 : 50,
        icon: (canvas, r, i, c) => i == 1 ? bitwiseIcon(canvas, r.deflate(2), c)
            : iconCurve(canvas, r.deflate(2), c, (x) => (math.sin(x * math.pi) * 3).roundToDouble() / 3.3)));
    if ((t.info?.variantIndex ?? 0) == 1) return BitwiseDevice(cards: cards);
    final hero = HeroCanvas(
      color: scope.accent,
      height: 200,
      caption: 'CRUSH ≈',
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        final bits = f?.values['bits'] ?? t.value('bits');
        final rate = f?.values['rate_hz'] ?? t.value('rate');
        return Text('${bits.toStringAsFixed(1)} bit · ${formatParamValue(t.param('rate'), rate)}');
      }),
      child: const _CrushHero(),
    );
    if (inline) return effectPage('bits', [cards, hero, const KnobRow(['bits', 'rate', 'jitter', 'dither'], size: 44)]);
    return effectPage('bits', [
      cards,
      hero,
      const KnobRow(['bits', 'rate'], size: 66),
      const KnobRow(['jitter', 'dither'], size: 46),
      const DeviceFold(child: ParamGrid(only: ['adc', 'dac'])),
    ]);
  }
}

class _CrushHero extends StatefulWidget {
  const _CrushHero();

  @override
  State<_CrushHero> createState() => _CrushHeroState();
}

class _CrushHeroState extends State<_CrushHero> {
  bool _active = false;
  double _bits = 8, _rate = 8000;

  double _v(DeviceScope s, String id, double d) => s.target.param(id) == null ? d : s.target.value(id);

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return GrabGesture(
        key: const ValueKey('bits-hero'),
        onStart: (_, _) {
          _bits = t.value('bits');
          _rate = t.value('rate');
          DeviceFeel.grab();
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _bits = (_bits - u.delta.dy / h * 16 * DeviceFingers.fine).clamp(1.0, 24.0);
          t.setLive('bits', _bits);
          _rate = dragAlongTaper(scope, 'rate', _rate, u.delta.dx / w) ?? _rate;
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['bits', 'rate']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _StairPainter(
          bits: _v(scope, 'bits', 8), rate: _v(scope, 'rate', 8000), dac: _v(scope, 'dac', 0), jitter: _v(scope, 'jitter', 0),
          color: scope.accent, second: scope.secondary, active: _active)),
      );
    });
  }
}

class _StairPainter extends CustomPainter {
  _StairPainter({required this.bits, required this.rate, required this.dac, required this.jitter, required this.color,
    required this.second, required this.active});
  final double bits, rate, dac, jitter;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 30.0, span = 0.005, hz = 400.0;
    final right = size.width - 10, top = 26.0, bottom = size.height - 26;
    final mid = (top + bottom) / 2, amp = (bottom - top) / 2 - 2;
    final levels = math.pow(2, bits.clamp(1, 24) - 1).toDouble();
    // The levels the bits allow, when there are few enough to tell apart.
    final step = amp / levels;
    if (step >= 3) {
      final line = Paint()..color = Neon.ink.withValues(alpha: 0.07);
      for (var k = -levels; k <= levels; k++) {
        final y = mid - k * step;
        canvas.drawLine(Offset(left, y), Offset(right, y), line);
      }
    }
    // The bit-depth ruler on the left: one tick per level up to 32, its count beside it.
    canvas.drawLine(Offset(left - 6, mid - amp), Offset(left - 6, mid + amp), Paint()..color = second.withValues(alpha: 0.6));
    if (step >= 3) {
      for (var k = -levels; k <= levels; k++) {
        canvas.drawLine(Offset(left - 10, mid - k * step), Offset(left - 6, mid - k * step), Paint()..color = second);
      }
    }
    final dry = Path(), crushed = Path();
    final period = 1 / rate.clamp(200, 48000);
    var held = 0.0, next = 0.0, k = 0;
    const n = 480;
    final ticks = <double>[];
    for (var i = 0; i <= n; i++) {
      final ts = span * i / n;
      final px = left + (right - left) * i / n;
      final x = math.sin(2 * math.pi * hz * ts);
      i == 0 ? dry.moveTo(px, mid - x * amp) : dry.lineTo(px, mid - x * amp);
      if (ts >= next) {
        held = (x * levels).roundToDouble() / levels;
        // Jitter: the hold times wander (a fixed pattern here, ≈).
        next += period * (1 + 0.9 * jitter * math.sin(k * 2.3999));
        k++;
        ticks.add(px);
        if (i > 0) crushed.lineTo(px, mid - held * amp);
      }
      i == 0 ? crushed.moveTo(px, mid - held * amp) : crushed.lineTo(px, mid - held * amp);
    }
    canvas.drawPath(dry, Paint()
      ..color = Neon.dim.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
    strokeGlow(canvas, crushed, color, width: active ? 2.6 : 2);
    if (dac > 0.05) {
      strokeGlow(canvas, dry, second.withValues(alpha: 0.3 + 0.5 * dac), width: 1.4, glow: false);
    }
    // The samples the rate takes: ticks along the bottom (when they are far enough apart to see).
    final tickPaint = Paint()
      ..color = second.withValues(alpha: 0.8)
      ..strokeWidth = 1.2;
    final spaced = ticks.length < 2 || (ticks[1] - ticks[0]) >= 3;
    if (spaced) {
      for (final x in ticks) {
        canvas.drawLine(Offset(x, bottom + 6), Offset(x, bottom + 11), tickPaint);
      }
    } else {
      canvas.drawLine(Offset(left, bottom + 8), Offset(right, bottom + 8), tickPaint);
    }
    paintLabel(canvas, '${bits.toStringAsFixed(bits < 10 ? 1 : 0)} bit · ${levels >= 1e5 ? '∞' : (2 * levels).round()} levels',
        Offset(left - 20, size.height - 7), second, size: 9, weight: FontWeight.w800);
    final rateText = rate >= 1000 ? '${(rate / 1000).toStringAsFixed(rate < 10000 ? 2 : 1)} kHz' : '${rate.round()} Hz';
    paintLabel(canvas, '$rateText · ${(1000 / rate).toStringAsFixed(rate > 10000 ? 3 : 2)} ms a step', Offset(right, size.height - 7),
        second, size: 9, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _StairPainter o) =>
      paintInputsChanged([o.bits, o.rate, o.dac, o.jitter, o.color, o.second, o.active], [bits, rate, dac, jitter, color, second, active]);
}
