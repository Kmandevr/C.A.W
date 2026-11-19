// The Reverb's 1.1.0 algorithms (org.caw.reverb 2-6): Room, Plate, Spring, Gated and Reverse, each a decay picture in time (reflections and tail) dragged for its decay and size, with its own knobs.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../kit/param_watch.dart';
import '../../../../model/device_display.dart';
import '../effect_page.dart';
import '../modes_kit.dart';
import 'space_devices.dart';

/// The algorithm cards' icons for Room, Plate, Spring, Gated and Reverse: each its decay's shape.
void reverbNewModeIcon(Canvas canvas, Rect r, int index, Color c) {
  final base = r.bottom - 2;
  final p = Paint()
    ..color = c
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round;
  for (var k = 0; k < 14; k++) {
    final u = k / 13;
    final x = r.left + r.width * (k + 0.5) / 14;
    final env = switch (index) {
      2 => k < 5 ? (k.isEven ? 1.0 : 0.6) * (1 - k * 0.1) : math.exp(-(k - 4) / 2.0) * 0.6,
      3 => math.exp(-k / 6.0),
      4 => math.exp(-k / 5.0) * (0.6 + 0.4 * math.cos(k * 1.4).abs()),
      5 => k < 9 ? 0.85 : 0.05,
      _ => math.pow(u, 1.8).toDouble(),
    };
    canvas.drawLine(Offset(x, base), Offset(x, base - (r.height - 4) * env), p..color = c.withValues(alpha: 0.35 + 0.65 * env));
  }
}

/// One algorithm's picture: reflections (time s, level 0..1), the tail's level at a time, the span drawn, and the
/// two knobs the picture drags (sideways, up and down).
class _Decay {
  const _Decay(this.spikes, this.tail, this.span, this.x, this.y, {this.tailFrom = 0, this.gate, this.warp = true});

  /// Time on a square-root axis (the reflections spread out); false: linear (Gated, Reverse).
  final bool warp;
  final List<(double, double)> spikes;
  final double Function(double t) tail;
  final double span, tailFrom;
  final String x, y;

  /// Gated: the gate's hold and close (s from the onset).
  final (double, double)? gate;
}

_Decay _model(DeviceScope scope, int variant, DeviceDisplayFrame? f) {
  final t = scope.target;
  double v(String id, double d) => t.param(id) == null ? d : t.value(id);
  double fall(double decay, double at) => math.pow(10, -3 * at / math.max(0.05, decay)).toDouble(); // −60 dB at decay
  switch (variant) {
    case 2: // Room: eight early reflections (the engine's times when it publishes them), the tail among them
      final size = v('size', 0.4), decay = v('decay', 0.8), early = v('early', 0.6), pre = v('predelay', 5) / 1000;
      const base = [0.0043, 0.0071, 0.0109, 0.0152, 0.0198, 0.0247, 0.0301, 0.0367];
      final scale = 0.3 + 1.7 * size;
      final live = f?.raw != null && f!.at(7) > 0;
      final times = [for (var k = 0; k < 8; k++) live ? f.at(7 + k) : pre + base[k] * scale];
      var g = 1.0;
      final spikes = <(double, double)>[];
      for (final tt in times) {
        spikes.add((tt, early * g));
        g *= 0.8;
      }
      final from = pre + base[2] * scale;
      return _Decay(spikes, (s) => s < from ? 0 : 0.55 * fall(decay, s - from), math.max(0.25, pre + decay * 1.15), 'decay', 'size',
          tailFrom: from);
    case 3: // Plate: dense from the start, smooth
      final decay = v('decay', 2), pre = v('predelay', 10) / 1000, diff = v('diffusion', 0.75);
      return _Decay([for (var k = 0; k < 6; k++) (pre + 0.002 + k * 0.004 * (1.2 - diff), 0.7 * (1 - diff * 0.6) * math.pow(0.8, k))],
          (s) => s < pre ? 0 : 0.8 * fall(decay, s - pre) * math.min(1, (s - pre) / 0.012 + 0.2), math.max(0.3, pre + decay * 1.15),
          'decay', 'diffusion', tailFrom: pre);
    case 4: // Spring: the loop's returns, each a chirp, dripping away
      final decay = v('decay', 1.8), length = v('length', 0.5), tension = v('tension', 0.5);
      final loop = f?.raw != null && f!.at(6) > 0 ? f.at(6) : 0.025 + 0.055 * length;
      return _Decay([for (var k = 1; k * loop < decay * 1.15 && k < 60; k++) (k * loop, 0.9 * fall(decay, k * loop))],
          (s) => 0.45 * fall(decay, s) * (0.65 + 0.35 * math.cos(2 * math.pi * s / loop * (1 + tension))).abs(),
          math.max(0.3, decay * 1.15), 'decay', 'tension');
    case 5: // Gated: a full tail held open, then shut
      final decay = v('decay', 2.5), hold = v('hold', 250) / 1000, release = v('release', 40) / 1000, pre = v('predelay', 0) / 1000;
      final open = hold + pre;
      return _Decay(const [], (s) {
        if (s < pre) return 0;
        final body = 0.85 * fall(decay, s - pre);
        if (s < open) return body;
        return body * math.max(0, 1 - (s - open) / math.max(0.002, release));
      }, math.max(0.2, (open + release) * 1.5), 'hold', 'size', tailFrom: pre, gate: (open, open + release), warp: false);
    default: // Reverse: 24 taps swelling to the length, then nothing
      final length = v('length', 600) / 1000, curve = v('curve', 0.5);
      final live = f?.raw != null && f!.at(5) >= 24;
      final gains = [for (var k = 0; k < 24; k++) live ? f.at(6 + k) : math.pow((k + 1) / 24, 1 + 4 * curve).toDouble()];
      final top = gains.fold(1e-9, math.max);
      return _Decay([for (var k = 0; k < 24; k++) (length * (k + 0.5) / 24, gains[k] / top)], (s) => 0,
          math.max(0.2, length * 1.25), 'length', 'curve', warp: false);
  }
}

/// The Reverb's Room, Plate, Spring, Gated and Reverse pages under its algorithm [cards].
class ReverbModesPage extends StatelessWidget {
  const ReverbModesPage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = variantOf(context);
    const names = ['HALL', 'SHIMMER', 'ROOM', 'PLATE', 'SPRING', 'GATED', 'REVERSE'];
    final hero = HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
      color: scope.accent,
      height: 200,
      caption: names[variant.clamp(0, 6)],
      grid: false,
      readout: Builder(builder: (context) => Text(switch (variant) {
        6 => '${valueText(scope, 'length')} · curve ${(t.value('curve') * 100).round()}%',
        5 => '${valueText(scope, 'decay')} · hold ${valueText(scope, 'hold')}',
        _ => valueText(scope, 'decay'),
      })),
      child: _DecayHero(variant: variant),
    ));
    final (main, second) = switch (variant) {
      2 => (const ['size', 'decay', 'early'], const ['predelay', 'damping', 'width']),
      3 => (const ['decay', 'diffusion', 'damping'], const ['predelay', 'mod', 'width']),
      4 => (const ['decay', 'tension', 'length'], const ['tone', 'width']),
      5 => (const ['threshold', 'hold', 'release'], const ['size', 'decay', 'predelay']),
      _ => (const ['length', 'curve', 'diffusion'], const ['width']),
    };
    return mergedPage(context, 'reverb',
      cards: cards,
      hero: hero,
      rows: [if (variant == 5) const _GateLamp()],
      knobs: Column(mainAxisSize: MainAxisSize.min, children: [
        KnobRow(main, size: 52, labels: const {'mod': 'Mod depth', 'early': 'Early'}),
        KnobRow(second, size: 44),
      ]),
      more: const KnobRow(['low_cut', 'high_cut'], size: 42, labels: {'low_cut': 'Low cut', 'high_cut': 'High cut'}),
    );
  }
}

/// Gated's gate: open or shut now (the engine's), with the threshold it listens for.
class _GateLamp extends StatelessWidget {
  const _GateLamp();

  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    return DeviceDisplay(builder: (context, f) {
      final open = (f?.raw == null ? 0.0 : f!.at(3)) > 0.5;
      return Row(children: [
        LedLight(on: open, color: scope.accent, size: 14),
        const SizedBox(width: 8),
        Text(open ? 'GATE OPEN' : 'GATE SHUT', style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800,
            color: open ? Neon.text : Neon.dim)),
        const Spacer(),
        Text('THR ${valueText(scope, 'threshold')}', style: Neon.code(size: 10, color: Neon.dim)),
      ]);
    });
  }
}

class _DecayHero extends StatefulWidget {
  const _DecayHero({required this.variant});
  final int variant;

  @override
  State<_DecayHero> createState() => _DecayHeroState();
}

class _DecayHeroState extends State<_DecayHero> {
  bool _active = false;
  double _x = 0, _y = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) {
        final m = _model(scope, widget.variant, f);
        return GrabGesture(
          key: const ValueKey('reverb-hero'),
          onStart: (_, _) {
            _x = t.value(m.x);
            _y = t.value(m.y);
            DeviceFeel.grab();
            setState(() => _active = true);
          },
          onUpdate: (u) {
            final fine = DeviceFingers.fine;
            _x = travelBy(scope, m.x, _x, u.delta.dx / w * fine);
            _y = travelBy(scope, m.y, _y, -u.delta.dy / h * fine);
            t.setLive(m.x, _x);
            t.setLive(m.y, _y);
          },
          onEnd: () {
            t.commit();
            DeviceFeel.release();
            setState(() => _active = false);
          },
          onDoubleTap: (_) => t.setAll({for (final id in [m.x, m.y]) if (t.param(id) case final p?) id: p.defaultValue}),
          child: CustomPaint(size: Size(w, h), painter: _DecayPainter(
            model: m,
            gateNow: widget.variant == 5 && f?.raw != null ? f!.at(3) : null,
            yLabel: '${shortParamLabel(t.param(m.y), m.y).toUpperCase()} ${valueText(scope, m.y)}',
            color: scope.accent,
            second: scope.secondary,
            active: _active)),
        );
      });
    });
  }
}

class _DecayPainter extends CustomPainter {
  _DecayPainter({required this.model, required this.gateNow, required this.yLabel, required this.color,
    required this.second, required this.active});
  final _Decay model;
  final double? gateNow;
  final String yLabel;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(12, 26, size.width - 12, size.height - 18);
    // Time on a square-root axis: the first reflections get room, the tail still reads as a fall.
    double x(double s) {
      final u = (s / model.span).clamp(0.0, 1.0);
      return r.left + (model.warp ? math.sqrt(u) : u) * r.width;
    }
    // Level on a dB axis (−60..0) so a decay is a straight fall.
    double y(double a) => r.bottom - dbUnit(a <= 0 ? -120 : 20 * math.log(a) / math.ln10, floor: 60) * r.height;
    final grid = Paint()..color = Neon.ink.withValues(alpha: 0.07);
    for (var k = 1; k < 4; k++) {
      canvas.drawLine(Offset(r.left, r.top + r.height * k / 4), Offset(r.right, r.top + r.height * k / 4), grid);
    }
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.right, r.bottom), Paint()..color = Neon.ink.withValues(alpha: 0.15));
    // The tail.
    final tail = Path()..moveTo(x(model.tailFrom), r.bottom);
    var any = false;
    const n = 220;
    for (var i = 0; i <= n; i++) {
      final s = model.span * i / n;
      if (s < model.tailFrom) continue;
      final a = model.tail(s);
      tail.lineTo(x(s), y(a));
      if (a > 0) any = true;
    }
    tail.lineTo(r.right, r.bottom);
    tail.close();
    if (any) {
      canvas.drawPath(tail, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0.05)]).createShader(r));
      final edge = Path();
      var started = false;
      for (var i = 0; i <= n; i++) {
        final s = model.span * i / n;
        if (s < model.tailFrom) continue;
        final p = Offset(x(s), y(model.tail(s)));
        started ? edge.lineTo(p.dx, p.dy) : edge.moveTo(p.dx, p.dy);
        started = true;
      }
      strokeGlow(canvas, edge, color, width: active ? 2.4 : 1.8);
    }
    // The reflections (or the swell's taps).
    for (final (s, a) in model.spikes) {
      if (s > model.span) continue;
      canvas.drawLine(Offset(x(s), r.bottom), Offset(x(s), y(a)), Paint()
        ..color = second.withValues(alpha: model.spikes.length > 20 ? 0.55 : 0.85)
        ..strokeWidth = model.spikes.length > 20 ? 1.4 : (active ? 2.6 : 2)
        ..strokeCap = StrokeCap.round);
    }
    // Gated: the hold and the close, and the gate now.
    if (model.gate case (final open, final shut)) {
      for (final (s, label) in [(open, 'HOLD'), (shut, 'SHUT')]) {
        canvas.drawLine(Offset(x(s), r.top), Offset(x(s), r.bottom), Paint()..color = Neon.text.withValues(alpha: 0.35));
        paintLabel(canvas, label, Offset(x(s) + 3, r.bottom - 12), Neon.dim, size: 8);
      }
      if (gateNow case final g?) {
        canvas.drawRect(Rect.fromLTWH(r.left, r.bottom - 4, r.width * g.clamp(0.0, 1.0), 3), Paint()..color = color.withValues(alpha: 0.8));
      }
    }
    // The time axis and what the up and down drag sets.
    paintLabel(canvas, '0', Offset(r.left, r.bottom + 9), Neon.dim, size: 8);
    final span = model.span;
    paintLabel(canvas, span < 1 ? '${(span * 1000).round()} ms' : '${span.toStringAsFixed(1)} s', Offset(r.right, r.bottom + 9),
        Neon.dim, size: 8, align: 1);
    paintLabel(canvas, '↕ $yLabel', Offset(r.right, r.top + 8), Neon.dim, size: 8, align: 1);
  }

  @override
  bool shouldRepaint(covariant _DecayPainter o) => true;
}
