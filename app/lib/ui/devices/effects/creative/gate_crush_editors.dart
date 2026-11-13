// The gate and crush plugin UIs (fx-creative): the trance gate's drawable step pattern and the bitcrusher's stair-stepped wave.
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
import 'creative_common.dart';

// ---------- Trance gate ----------

/// The trance gate's step count now (8, 16 or 32).
int gateSteps(DeviceScope scope) => const [8, 16, 32][scope.target.value('steps').round().clamp(0, 2)];

/// The trance gate: the pattern as bars you draw (tap a step to turn it on or off, drag across the steps to paint
/// their levels), each step's envelope drawn inside it (≈), the engine's step lit; then steps, rate, the envelope
/// and the rest.
class TranceGatePage extends StatelessWidget {
  const TranceGatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('trancegate', [
      HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: 'PATTERN',
        grid: false,
        readout: Builder(builder: (context) => Text('${gateSteps(scope)} steps · ${formatParamValue(scope.target.param('rate'), scope.target.value('rate'))}')),
        child: const _GateHero(),
      )),
      Row(children: const [
        Expanded(child: LabelledChoice('STEPS', 'steps')),
        SizedBox(width: 8),
        DeviceToggle('legato', label: 'Tie', icon: Icons.link),
      ]),
      const LabelledChoice('RATE', 'rate'),
      KnobRow(const ['attack', 'decay', 'sustain', 'release'], size: 50),
      KnobRow(const ['length', 'swing', 'mix'], size: 50),
    ]);
  }
}

class _GateHero extends StatefulWidget {
  const _GateHero();

  @override
  State<_GateHero> createState() => _GateHeroState();
}

class _GateHeroState extends State<_GateHero> {
  int? _last;
  bool _active = false;

  static const _pad = 10.0, _top = 26.0, _bottom = 10.0;

  int? _stepAt(Offset local, double w, int n) {
    final k = ((local.dx - _pad) / ((w - 2 * _pad) / n)).floor();
    return k < 0 || k >= n ? null : k;
  }

  double _levelAt(Offset local, double h) => ((h - _bottom - local.dy) / (h - _top - _bottom)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final n = gateSteps(scope);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      void paint(Offset local) {
        final k = _stepAt(local, w, n);
        if (k == null) return;
        if (k != _last) DeviceFeel.detent();
        _last = k;
        // Near the bottom is off: a stroke along the floor clears steps.
        final v = _levelAt(local, h);
        t.setLive('s${k + 1}', v < 0.06 ? 0 : (v * 20).roundToDouble() / 20);
      }
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('trancegate-hero'),
        onStart: (_, _) => setState(() => _active = true),
        onUpdate: (u) => paint(u.local),
        onEnd: () {
          t.commit();
          _last = null;
          setState(() => _active = false);
        },
        onTap: (local) {
          final k = _stepAt(local, w, n);
          if (k == null) return;
          DeviceFeel.tap();
          t.set('s${k + 1}', t.value('s${k + 1}') > 0 ? 0 : 1);
        },
        child: CustomPaint(size: Size(w, h), painter: _GatePainter(
          levels: [for (var k = 1; k <= n; k++) t.value('s$k')],
          attack: t.value('attack'),
          decay: t.value('decay'),
          sustain: t.value('sustain'),
          release: t.value('release'),
          length: t.value('length'),
          swing: t.value('swing'),
          stepMs: _stepMs(scope),
          step: f?.values['step']?.round(),
          env: f?.values['env'],
          color: scope.accent,
          second: scope.secondary,
          active: _active,
          pad: _pad, top: _top, bottom: _bottom)),
      ));
    });
  }

  static double _stepMs(DeviceScope scope) {
    const wholes = [0.03125, 0.0625 * 2 / 3, 0.0625, 0.125 * 2 / 3, 0.125, 0.25];
    final i = scope.target.value('rate').round().clamp(0, 5);
    return wholes[i] * 240000 / scope.target.state.project.bpm.clamp(20, 999);
  }
}

class _GatePainter extends CustomPainter {
  _GatePainter({required this.levels, required this.attack, required this.decay, required this.sustain, required this.release,
    required this.length, required this.swing, required this.stepMs, required this.step, required this.env,
    required this.color, required this.second, required this.active, required this.pad, required this.top, required this.bottom});
  final List<double> levels;
  final double attack, decay, sustain, release, length, swing, stepMs;
  final int? step;
  final double? env;
  final Color color, second;
  final bool active;
  final double pad, top, bottom;

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    final sw = (size.width - 2 * pad) / n, base = size.height - bottom, hh = base - top;
    for (var k = 0; k < n; k++) {
      // Swing moves every second step late (drawn as a shift of its start).
      final late = k.isOdd ? swing * 0.5 * sw : 0.0;
      final x = pad + k * sw + late;
      final width = k.isOdd ? sw * (1 - swing * 0.5) : sw * (1 + swing * 0.5);
      final lvl = levels[k];
      final lit = step == k;
      final slot = Rect.fromLTWH(pad + k * sw + 1, top, sw - 2, hh);
      canvas.drawRRect(RRect.fromRectAndRadius(slot, const Radius.circular(3)),
        Paint()..color = Neon.ink.withValues(alpha: k % 4 == 0 ? 0.06 : 0.03));
      if (lvl > 0) {
        // The step's envelope: attack, decay to sustain, release at the gate's end (times relative to the step).
        final env = Path()..moveTo(x + 1, base);
        final a = (attack / stepMs).clamp(0.0, 1.0), g = length.clamp(0.05, 1.0);
        final r = (release / stepMs).clamp(0.0, 1.0);
        final peakX = x + 1 + (width - 2) * math.min(a, g);
        env.lineTo(peakX, base - hh * lvl);
        for (var i = 1; i <= 12; i++) {
          final u = math.min(a, g) + (g - math.min(a, g)) * i / 12;
          final tMs = (u - a) * stepMs;
          final d = math.exp(-3 * math.max(0.0, tMs) / math.max(1.0, decay));
          final v = lvl * (sustain + (1 - sustain) * d);
          env.lineTo(x + 1 + (width - 2) * u, base - hh * v);
        }
        env.lineTo(math.min(x + width - 1, x + 1 + (width - 2) * (g + r)), base);
        final c = Color.lerp(color, second, k / math.max(1, n - 1))!;
        fillFade(canvas, env, base, size, c, alpha: lit ? 0.7 : 0.4);
        strokeGlow(canvas, env, c, width: lit ? 2.4 : 1.6, glow: lit || active);
        canvas.drawLine(Offset(slot.left + 2, base - hh * lvl), Offset(slot.right - 2, base - hh * lvl),
          Paint()..color = c..strokeWidth = 2.5..strokeCap = StrokeCap.round);
      }
      if (lit) canvas.drawRect(Rect.fromLTWH(slot.left, base + 2, slot.width, 3), Paint()..color = Neon.text);
    }
    if (env case final e?) paintLabel(canvas, 'GAIN ${(e * 100).round()} %', Offset(size.width - pad, top - 12), Neon.dim, size: 8, align: 1);
  }

  @override
  bool shouldRepaint(covariant _GatePainter o) =>
      paintInputsChanged([o.levels, o.attack, o.decay, o.sustain, o.release, o.length, o.swing, o.stepMs, o.step, o.env, o.color, o.second, o.active, o.pad, o.top, o.bottom], [levels, attack, decay, sustain, release, length, swing, stepMs, step, env, color, second, active, pad, top, bottom]);
}

// ---------- Bitcrush ----------

/// The bitcrusher: a sine through the crusher (≈), its stair-steps' height from the bits and width from the rate,
/// the smoothed output when the anti-image filter is on; drag up and down for the bits, sideways for the rate.
class BitcrushPage extends StatelessWidget {
  const BitcrushPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('bitcrush', [
      HeroWithMeters(height: 180, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 180,
        caption: 'CRUSHED ≈',
        grid: false,
        readout: Builder(builder: (context) => Text('${t.value('bits').toStringAsFixed(1)} bit · ${formatParamValue(t.param('rate'), t.value('rate'))}')),
        child: const _CrushHero(),
      )),
      KnobRow(const ['bits', 'rate', 'jitter', 'dither'], size: 52),
      KnobRow(const ['adc', 'dac', 'output', 'mix'], size: 46),
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

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return GrabGesture(
        key: const ValueKey('bitcrush-hero'),
        onStart: (_, _) {
          _bits = t.value('bits');
          _rate = t.value('rate');
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _bits = (_bits - u.delta.dy / h * 16 * DeviceFingers.fine).clamp(1.0, 24.0);
          t.setLive('bits', _bits);
          _rate = dragAlongTaper(scope, 'rate', _rate, u.delta.dx / w) ?? _rate;
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['bits', 'rate']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _CrushPainter(
          bits: t.value('bits'),
          rate: t.value('rate'),
          dac: valueOr(scope, 'dac', 0),
          jitter: valueOr(scope, 'jitter', 0),
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      );
    });
  }
}

class _CrushPainter extends CustomPainter {
  _CrushPainter({required this.bits, required this.rate, required this.dac, required this.jitter, required this.color,
    required this.second, required this.active});
  final double bits, rate, dac, jitter;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // Two cycles of a 400 Hz sine (5 ms) at 48 kHz, held at the crushed rate and rounded to 2^(bits - 1) levels a side.
    final left = 10.0, right = size.width - 10, mid = size.height * 0.56, amp = size.height * 0.34;
    const span = 0.005, hz = 400.0;
    final levels = math.pow(2, bits.clamp(1, 24) - 1).toDouble();
    final dry = Path(), crushed = Path();
    final period = 1 / rate.clamp(200, 48000);
    var held = 0.0, next = 0.0, k = 0;
    const n = 240;
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
        if (i > 0) crushed.lineTo(px, mid - held * amp);
      }
      i == 0 ? crushed.moveTo(px, mid - held * amp) : crushed.lineTo(px, mid - held * amp);
    }
    canvas.drawPath(dry, Paint()..color = Neon.dim.withValues(alpha: 0.5)..style = PaintingStyle.stroke..strokeWidth = 1.2);
    strokeGlow(canvas, crushed, color, width: active ? 2.6 : 2);
    if (dac > 0.05) {
      // The anti-image filter rounds the steps back toward the wave.
      strokeGlow(canvas, dry, second.withValues(alpha: 0.35 + 0.5 * dac), width: 1.4, glow: false);
    }
    paintLabel(canvas, '${levels >= 1e5 ? '∞' : (2 * levels).round()} levels', Offset(right, size.height - 10), Neon.dim, size: 8, align: 1);
  }

  @override
  bool shouldRepaint(covariant _CrushPainter o) =>
      paintInputsChanged([o.bits, o.rate, o.dac, o.jitter, o.color, o.second, o.active], [bits, rate, dac, jitter, color, second, active]);
}
