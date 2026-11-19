// The Transient device page (org.caw.transient, 1.0.8): a drum hit's waveform split into attack and sustain, reshaped, with two big knobs.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';

/// The Transient shaper: a drum hit's waveform (≈) as it comes in (faint) and as shaped, the attack part in the
/// family's colour and the sustain in its second, split where the onset ends; the gain change the engine applies
/// now as a bar at the right. Drag the attack part up or down for Attack, the rest for Sustain; two big knobs under
/// it (Output and Mix are the footer's).
class TransientDevice extends StatelessWidget {
  const TransientDevice({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final inline = DeviceScope.isInline(context);
    final hero = HeroWithMeters(height: 210, gr: false, hero: HeroCanvas(
      color: scope.accent,
      height: 210,
      caption: 'TRANSIENTS ≈',
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        final g = f?.values['gain_db'];
        return Text(g == null ? '' : '${g > 0 ? '+' : ''}${g.toStringAsFixed(1)} dB',
          style: Neon.code(size: 10, color: g != null && g >= 0 ? scope.accent : Neon.yellow));
      }),
      child: const _TransientHero(),
    ));
    return effectPage('transient', [
      hero,
      KnobRow(const ['attack', 'sustain'], size: inline ? 52 : 76),
    ]);
  }
}

/// A hit: a 3 ms rise, a fast fall to a body that decays over 0.4 s.
double transientHit(double s) =>
    s < 0.003 ? s / 0.003 : 0.7 * math.exp(-(s - 0.003) / 0.015) + 0.3 * math.exp(-(s - 0.003) / 0.25);

/// The shaper's gain at [s] seconds into the hit, for drawing: attack ±24 dB over the first ~25 ms, sustain after.
double transientGain(double s, double attack, double sustain) {
  final a = math.pow(10, attack * 24 / 20).toDouble(), su = math.pow(10, sustain * 24 / 20).toDouble();
  final k = 1 / (1 + math.exp((s - 0.03) / 0.008));
  return a * k + su * (1 - k);
}

class _TransientHero extends StatefulWidget {
  const _TransientHero();

  @override
  State<_TransientHero> createState() => _TransientHeroState();
}

class _TransientHeroState extends State<_TransientHero> {
  String? _param;
  double _v = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final attack = t.value('attack'), sustain = t.value('sustain');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('transient-hero'),
        onStart: (p, _) {
          _param = p.dx < _TransientPainter.splitX(w) + 8 ? 'attack' : 'sustain';
          _v = t.value(_param!);
          DeviceFeel.grab();
          setState(() {});
        },
        onUpdate: (u) {
          _v = (_v - u.delta.dy / (h * 0.6) * DeviceFingers.fine).clamp(-1.0, 1.0);
          t.setLive(_param!, _v);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _param = null);
        },
        onDoubleTap: (_) => t.setAll({'attack': 0, 'sustain': 0}),
        child: CustomPaint(size: Size(w, h), painter: _TransientPainter(attack, sustain, f?.values['gain_db'],
            scope.accent, scope.secondary, _param)),
      ));
    });
  }
}

class _TransientPainter extends CustomPainter {
  _TransientPainter(this.attack, this.sustain, this.gainNow, this.color, this.second, this.active);
  final double attack, sustain;
  final double? gainNow;
  final Color color, second;
  final String? active;

  static const span = 0.5;
  static double xOf(double s, double w) => 8 + (w - 30) * math.sqrt(s / span); // more room for the attack
  static double splitX(double w) => xOf(0.03, w);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final mid = size.height / 2 + 8, half = size.height / 2 - 22;
    // A 120 Hz body with a click: the waveform under its envelope, ±.
    double wave(double s) => math.sin(2 * math.pi * (70 * s + 4 * math.exp(-s / 0.004)));
    final orig = Path(), shapedTop = Path(), shapedBot = Path();
    const n = 420;
    // Scaled so the shaped hit's peak fits (at least the incoming one's).
    var peak = 1.0;
    for (var i = 0; i <= 60; i++) {
      final s = 0.03 * i / 60;
      peak = math.max(peak, transientHit(s) * transientGain(s, attack, sustain));
    }
    final norm = peak * 1.05;
    final pts = <(double, double, double)>[];
    for (var i = 0; i <= n; i++) {
      final s = span * i / n;
      final x = xOf(s, w);
      final env = transientHit(s);
      final sh = env * transientGain(s, attack, sustain);
      final yv = wave(s);
      pts.add((x, _lift(env / norm) * yv, _lift(sh / norm) * yv));
      i == 0 ? orig.moveTo(x, mid - pts.last.$2 * half) : orig.lineTo(x, mid - pts.last.$2 * half);
      final e = _lift(sh / norm);
      i == 0 ? shapedTop.moveTo(x, mid - e * half) : shapedTop.lineTo(x, mid - e * half);
      i == 0 ? shapedBot.moveTo(x, mid + e * half) : shapedBot.lineTo(x, mid + e * half);
    }
    canvas.drawLine(Offset(8, mid), Offset(w - 22, mid), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    final split = splitX(w);
    for (final (from, to, c, part) in [(0.0, split, color, 'attack'), (split, w, second, 'sustain')]) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(from, 0, to, size.height));
      canvas.drawRect(Rect.fromLTRB(from, 20, to, size.height - 4),
          Paint()..color = c.withValues(alpha: active == part ? 0.1 : 0.04));
      final shaped = Path();
      for (var i = 0; i < pts.length; i++) {
        final (x, _, y) = pts[i];
        i == 0 ? shaped.moveTo(x, mid - y * half) : shaped.lineTo(x, mid - y * half);
      }
      canvas.drawPath(shaped, Paint()
        ..color = c.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1);
      strokeGlow(canvas, shapedTop, c, width: active == part ? 2.6 : 2);
      strokeGlow(canvas, shapedBot, c, width: active == part ? 2.6 : 2, glow: false);
      canvas.restore();
    }
    canvas.drawPath(orig, Paint()
      ..color = Neon.ink.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8);
    for (var y = 22.0; y < size.height - 4; y += 7) {
      canvas.drawLine(Offset(split, y), Offset(split, y + 3), Paint()..color = Neon.ink.withValues(alpha: 0.3));
    }
    paintLabel(canvas, 'ATTACK ${_pct(attack)}', Offset(10, size.height - 10), active == 'attack' ? Neon.text : color, size: 9,
        weight: FontWeight.w800);
    paintLabel(canvas, 'SUSTAIN ${_pct(sustain)}', Offset(w - 26, size.height - 10), active == 'sustain' ? Neon.text : second,
        size: 9, align: 1, weight: FontWeight.w800);
    // The gain change now (±24 dB): a bar from the middle of the right edge.
    final bx = w - 10, top = 24.0, bottom = size.height - 6, m = (top + bottom) / 2;
    canvas.drawLine(Offset(bx, top), Offset(bx, bottom), Paint()
      ..color = Neon.ink.withValues(alpha: 0.08)
      ..strokeWidth = 5);
    if (gainNow case final g?) {
      canvas.drawLine(Offset(bx, m), Offset(bx, m - (g / 24).clamp(-1.0, 1.0) * (bottom - top) / 2), Paint()
        ..color = g >= 0 ? color : Neon.yellow
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round);
    }
  }

  // Amplitude on a square-root scale, so the quieter body reads beside the hit.
  static double _lift(double v) => math.sqrt(v.clamp(0.0, 1.0));

  static String _pct(double v) => '${v > 0 ? '+' : ''}${(v * 100).round()}%';

  @override
  bool shouldRepaint(covariant _TransientPainter o) => o.attack != attack || o.sustain != sustain || o.gainNow != gainNow ||
      o.color != color || o.second != second || o.active != active;
}
