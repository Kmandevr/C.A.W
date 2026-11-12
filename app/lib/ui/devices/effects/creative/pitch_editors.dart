// The pitch and frequency plugin UIs (fx-creative): pitch shifter (a semitone ruler), frequency shifter (partials moved by the same hertz) and ring mod (carrier, input and product).
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

// ---------- Pitch shifter ----------

/// The pitch shifter: a ruler of ±24 semitones with the shift as a handle (drag sideways; whole semitones snap with a
/// tick, a second finger drags cents), the grains' windows under it, the latency it reports, then the knobs.
class PitchShiftPage extends StatelessWidget {
  const PitchShiftPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final semis = t.value('semitones') + t.value('cents') / 100;
    return effectPage('pitchshift', [
      HeroWithMeters(height: 170, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 170,
        caption: 'PITCH',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final latency = f?.values['latency_ms'] ?? (valueOr(scope, 'grain', 60) / 2);
          return Text('${semis >= 0 ? '+' : ''}${semis.toStringAsFixed(2)} st · ${latency.toStringAsFixed(1)} ms latency');
        }),
        child: const _PitchHero(),
      )),
      KnobRow(const ['semitones', 'cents', 'grain', 'jitter', 'mix'], size: 50),
    ]);
  }
}

class _PitchHero extends StatefulWidget {
  const _PitchHero();

  @override
  State<_PitchHero> createState() => _PitchHeroState();
}

class _PitchHeroState extends State<_PitchHero> {
  bool _active = false;
  double _at = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('pitchshift-hero'),
        onStart: (_, _) {
          _at = t.value('semitones') + t.value('cents') / 100;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          _at = (_at + u.delta.dx / (w - 24) * 48 * fine).clamp(-24.0, 24.0);
          // One finger: whole semitones (a tick on each); fine (two fingers or Shift): cents as well.
          final whole = fine < 1 ? _at.truncateToDouble() : _at.roundToDouble();
          if (whole != t.value('semitones')) DeviceFeel.detent();
          t.setLive('semitones', whole);
          t.setLive('cents', fine < 1 ? ((_at - whole) * 100).clamp(-100.0, 100.0) : 0);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({'semitones': 0, 'cents': 0}),
        child: CustomPaint(size: Size(w, h), painter: _PitchPainter(
          semis: t.value('semitones') + t.value('cents') / 100,
          live: f?.values['semitones_now'],
          phase: f?.values['phase'],
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _PitchPainter extends CustomPainter {
  _PitchPainter({required this.semis, required this.live, required this.phase, required this.color, required this.second,
    required this.active});
  final double semis;
  final double? live, phase;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final left = 12.0, right = size.width - 12, mid = size.height * 0.48;
    double x(double s) => left + (s + 24) / 48 * (right - left);
    for (var s = -24; s <= 24; s++) {
      final major = s % 12 == 0, fifth = s % 12 == 7 || s % 12 == -5;
      final len = major ? 22.0 : (fifth ? 14.0 : 7.0);
      canvas.drawLine(Offset(x(s.toDouble()), mid - len / 2), Offset(x(s.toDouble()), mid + len / 2),
        Paint()..color = (major ? Neon.text : Neon.dim).withValues(alpha: major ? 0.6 : 0.35)..strokeWidth = major ? 1.5 : 1);
      if (major) paintLabel(canvas, s == 0 ? '0' : '${s > 0 ? '+' : ''}${s ~/ 12} oct', Offset(x(s.toDouble()), mid + 22), Neon.dim, size: 8, align: 0);
    }
    // The span from no shift to the shift, glowing.
    final bar = Path()..moveTo(x(0), mid)..lineTo(x(semis), mid);
    strokeGlow(canvas, bar, color, width: active ? 5 : 4);
    paintHandle(canvas, Offset(x(semis), mid), color, active: active, r: 8);
    if (live case final s? when (s - semis).abs() > 0.01) {
      canvas.drawCircle(Offset(x(s.clamp(-24.0, 24.0)), mid - 18), 3, Paint()..color = second);  // with jitter
    }
    // The two grains' windows (sin² and cos², always summing to one) under the ruler, where the engine is.
    final gy = size.height - 14.0, gh = size.height * 0.2;
    final p0 = phase ?? 0.25;
    for (var tap = 0; tap < 2; tap++) {
      final path = Path();
      for (var i = 0; i <= 64; i++) {
        final u = i / 64;
        final ph = (u + p0 + tap * 0.5) % 1.0;
        final v = math.pow(math.sin(math.pi * ph), 2).toDouble();
        final px = left + u * (right - left), py = gy - v * gh;
        i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
      }
      strokeGlow(canvas, path, (tap == 0 ? color : second).withValues(alpha: 0.6), width: 1.4, glow: false);
    }
    paintLabel(canvas, 'GRAINS', Offset(left, gy - gh - 8), Neon.dim, size: 7);
  }

  @override
  bool shouldRepaint(covariant _PitchPainter o) =>
      paintInputsChanged([o.semis, o.live, o.phase, o.color, o.second, o.active], [semis, live, phase, color, second, active]);
}

// ---------- Frequency shifter ----------

/// The frequency shifter: a harmonic series (grey) and where each partial lands after the shift (the same hertz for
/// all, so the series goes inharmonic), left in the family colour, right in its second; drag sideways for the shift,
/// up and down for the feedback. Direction tiles above, knobs below.
class FreqShiftPage extends StatelessWidget {
  const FreqShiftPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('freqshift', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('direction', height: 52, icon: (canvas, r, i, c) {
        final p = Paint()..color = c..strokeWidth = 2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
        final y = r.center.dy;
        void arrow(double from, double to, double dy) {
          canvas.drawLine(Offset(from, y + dy), Offset(to, y + dy), p);
          final s = to > from ? -1.0 : 1.0;
          canvas.drawLine(Offset(to, y + dy), Offset(to + s * 5, y + dy - 4), p);
          canvas.drawLine(Offset(to, y + dy), Offset(to + s * 5, y + dy + 4), p);
        }
        if (i == 0) arrow(r.left + 4, r.right - 4, 0);
        if (i == 1) arrow(r.right - 4, r.left + 4, 0);
        if (i == 2) {
          arrow(r.center.dx, r.right - 4, -5);
          arrow(r.center.dx, r.left + 4, 5);
        }
      })),
      HeroWithMeters(height: 180, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 180,
        caption: 'PARTIALS ≈',
        grid: false,
        readout: Text('${t.value('shift') >= 0 ? '+' : ''}${t.value('shift').toStringAsFixed(1)} Hz'),
        child: const _ShiftHero(),
      )),
      KnobRow(const ['shift', 'spread', 'feedback', 'delay', 'mix'], size: 50),
    ]);
  }
}

class _ShiftHero extends StatefulWidget {
  const _ShiftHero();

  @override
  State<_ShiftHero> createState() => _ShiftHeroState();
}

class _ShiftHeroState extends State<_ShiftHero> {
  bool _active = false;
  double _shift = 0, _fb = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('freqshift-hero'),
        onStart: (_, _) {
          _shift = t.value('shift');
          _fb = t.value('feedback');
          setState(() => _active = true);
        },
        onUpdate: (u) {
          // Finer near 0: the drag moves the shift on a cubic, so small shifts (the beating, widening range) are easy.
          final fine = DeviceFingers.fine;
          final c = math.pow(_shift.abs() / 2000, 1 / 3).toDouble() * _shift.sign;
          final n = (c + u.delta.dx / w * 1.5 * fine).clamp(-1.0, 1.0);
          _shift = 2000 * n * n * n;
          t.setLive('shift', _shift);
          _fb = (_fb - u.delta.dy / h * fine).clamp(0.0, 0.95);
          t.setLive('feedback', _fb);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['shift', 'feedback']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _ShiftPainter(
          left: f?.values['shift_l'] ?? (t.value('direction') == 1 ? -1 : 1) * (t.value('shift') - t.value('spread') / 2),
          right: f?.values['shift_r'] ?? (t.value('direction') == 0 ? 1 : -1) * (t.value('shift') + t.value('spread') / 2),
          feedback: t.value('feedback'),
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _ShiftPainter extends CustomPainter {
  _ShiftPainter({required this.left, required this.right, required this.feedback, required this.color, required this.second,
    required this.active});
  final double left, right, feedback;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // 50 Hz .. 5 kHz on a log axis; a 110 Hz harmonic series.
    final x0 = 12.0, x1 = size.width - 12, base = size.height - 18, top = 30.0;
    double x(double hz) => x0 + (math.log(hz.clamp(50.0, 5000.0) / 50) / math.log(100)) * (x1 - x0);
    for (final hz in [100.0, 1000.0]) {
      canvas.drawLine(Offset(x(hz), top), Offset(x(hz), base), Paint()..color = Neon.line);
      paintLabel(canvas, hz >= 1000 ? '1k' : '100', Offset(x(hz), base + 9), Neon.dim, size: 8, align: 0);
    }
    for (var k = 1; k <= 12; k++) {
      final hz = 110.0 * k, level = 1 / math.sqrt(k);
      final h = (base - top) * level;
      canvas.drawLine(Offset(x(hz), base), Offset(x(hz), base - h), Paint()..color = Neon.dim.withValues(alpha: 0.5)..strokeWidth = 2);
      for (final (shift, c, dx) in [(left, color, -1.5), (right, second, 1.5)]) {
        final to = hz + shift;
        if (to < 50 || to > 5000) continue;
        final p = Path()..moveTo(x(to) + dx, base)..lineTo(x(to) + dx, base - h * 0.92);
        strokeGlow(canvas, p, c, width: active ? 2.4 : 1.8, glow: k < 4);
      }
    }
    if (feedback > 0.01) {
      // Feedback: fainter copies shifted again.
      for (var pass = 2; pass <= 4; pass++) {
        final a = math.pow(feedback, pass - 1).toDouble();
        for (var k = 1; k <= 6; k++) {
          final to = 110.0 * k + left * pass;
          if (to < 50 || to > 5000) continue;
          canvas.drawLine(Offset(x(to), base), Offset(x(to), base - (base - top) * a / math.sqrt(k)),
            Paint()..color = color.withValues(alpha: 0.35 * a)..strokeWidth = 1.2);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ShiftPainter o) =>
      paintInputsChanged([o.left, o.right, o.feedback, o.color, o.second, o.active], [left, right, feedback, color, second, active]);
}

// ---------- Ring mod ----------

/// The ring mod's carrier at phase [ph] (cycles) for source [source] (Sine, Triangle, Square, Saw, Noise), with bias
/// and rectify as the engine applies them.
double ringCarrier(int source, double ph, double bias, double rectify, {int seed = 0}) {
  final p = ph - ph.floorToDouble();
  final c = switch (source) {
    1 => 4 * (p - 0.5).abs() - 1,
    2 => p < 0.5 ? 1.0 : -1.0,
    3 => 2 * p - 1,
    4 => math.sin(ph * 37.1 + seed) * math.cos(ph * 91.7 - seed),
    _ => math.sin(2 * math.pi * p),
  };
  final a = c.abs();
  final folded = rectify >= 0 ? c + (a - c) * rectify : c + (-a - c) * -rectify;
  return bias + (1 - bias) * folded;
}

/// The ring mod: carrier tiles above; the hero shows the carrier (top), a tone (middle) and their product (bottom),
/// drag sideways for the frequency and up and down for the bias; then the knobs. On Sidechain the key's sound is the
/// carrier (picked in the header's sidechain bar).
class RingModPage extends StatelessWidget {
  const RingModPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final keyed = t.value('source').round() == 5;
    return effectPage('ringmod', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('source', height: 52,
        names: const ['Sine', 'Tri', 'Square', 'Saw', 'Noise', 'Key'], icon: (canvas, r, i, c) {
          if (i == 5) {
            iconCurve(canvas, r.deflate(2), c, (x) => 0.8 * math.sin(x * 9) * math.exp(-2 * (x + 1)));
          } else {
            iconCurve(canvas, r.deflate(2), c, (x) => 0.85 * ringCarrier(i, (x + 1) * 1.5, 0, 0, seed: 3));
          }
        })),
      HeroWithMeters(height: 180, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 180,
        caption: keyed ? 'INPUT × KEY' : 'CARRIER × INPUT ≈',
        grid: false,
        readout: Text(keyed ? 'sidechain' : formatParamValue(t.param('freq'), t.value('freq'))),
        child: const _RingHero(),
      )),
      KnobRow([if (!keyed) 'freq', if (!keyed) 'spread', 'bias', 'rectify', 'mix'], size: 50),
    ]);
  }
}

class _RingHero extends StatefulWidget {
  const _RingHero();

  @override
  State<_RingHero> createState() => _RingHeroState();
}

class _RingHeroState extends State<_RingHero> {
  bool _active = false;
  double _freq = 440, _bias = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return GrabGesture(
        key: const ValueKey('ringmod-hero'),
        onStart: (_, _) {
          _freq = t.value('freq');
          _bias = t.value('bias');
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _freq = dragAlongTaper(scope, 'freq', _freq, u.delta.dx / w) ?? _freq;
          _bias = (_bias - u.delta.dy / h * DeviceFingers.fine).clamp(0.0, 1.0);
          t.setLive('bias', _bias);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['freq', 'bias']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: DevicePhase(builder: (context, secs) => CustomPaint(size: Size(w, h), painter: _RingPainter(
          source: t.value('source').round(),
          freq: t.value('freq'),
          bias: t.value('bias'),
          rectify: t.value('rectify'),
          mix: valueOr(scope, 'mix', 1),
          drift: secs,
          color: scope.accent,
          second: scope.secondary,
          active: _active))),
      );
    });
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.source, required this.freq, required this.bias, required this.rectify, required this.mix,
    required this.drift, required this.color, required this.second, required this.active});
  final int source;
  final double freq, bias, rectify, mix, drift;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // A window of 20 ms: the carrier's cycles across it (a slow one shown moving), a 220 Hz tone, the product.
    final left = 10.0, right = size.width - 10;
    final lanes = [size.height * 0.27, size.height * 0.52, size.height * 0.8];
    final amp = size.height * 0.1;
    const window = 0.02;
    final cycles = (freq * window).clamp(0.25, 40.0);
    double carrier(double u) => source == 5
        ? math.sin(2 * math.pi * (u * 7 + drift * 0.3)) * math.exp(-3 * ((u + drift * 0.2) % 1))
        : ringCarrier(source, u * cycles + drift * math.min(freq, 2.0), bias, rectify, seed: 1);
    double tone(double u) => math.sin(2 * math.pi * u * 220 * window);
    Path lane(double y, double Function(double u) f) {
      final p = Path();
      for (var i = 0; i <= 160; i++) {
        final u = i / 160;
        final px = left + u * (right - left), py = y - f(u).clamp(-1.6, 1.6) * amp;
        i == 0 ? p.moveTo(px, py) : p.lineTo(px, py);
      }
      return p;
    }
    strokeGlow(canvas, lane(lanes[0], carrier), second.withValues(alpha: 0.85), width: 1.5, glow: false);
    strokeGlow(canvas, lane(lanes[1], tone), Neon.dim, width: 1.3, glow: false);
    strokeGlow(canvas, lane(lanes[2], (u) => tone(u) * (1 - mix) + tone(u) * carrier(u) * mix), color, width: active ? 2.6 : 2);
    paintLabel(canvas, '×', Offset(left + 2, (lanes[0] + lanes[1]) / 2), Neon.dim, size: 10);
    paintLabel(canvas, '=', Offset(left + 2, (lanes[1] + lanes[2]) / 2), Neon.dim, size: 10);
  }

  @override
  bool shouldRepaint(covariant _RingPainter o) =>
      paintInputsChanged([o.source, o.freq, o.bias, o.rectify, o.mix, o.drift, o.color, o.second, o.active], [source, freq, bias, rectify, mix, drift, color, second, active]);
}
