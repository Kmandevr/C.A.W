// The Delay's 1.1.0 modes (org.caw.delay 2-4): Tape's reels wobbling with wow and flutter, Reverse's backward windows, Multi-tap's draggable taps in time.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import '../modes_kit.dart';
import '../space_editors.dart' show delaySeconds;
import 'space_delay_reverb.dart' show SyncTimeToggle;
import 'space_devices.dart';

/// The cards' icons for Tape (two reels), Reverse (backward ramps) and Multi-tap (four stems).
void delayNewModeIcon(Canvas canvas, Rect r, int index, Color c) {
  final p = Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4;
  switch (index) {
    case 2:
      final rad = math.min(r.height * 0.36, r.width * 0.18);
      for (final x in [r.center.dx - rad * 1.4, r.center.dx + rad * 1.4]) {
        canvas.drawCircle(Offset(x, r.center.dy - 2), rad, p);
        canvas.drawCircle(Offset(x, r.center.dy - 2), rad * 0.3, Paint()..color = c);
      }
      canvas.drawLine(Offset(r.center.dx - rad * 1.4, r.center.dy + rad - 2), Offset(r.center.dx + rad * 1.4, r.center.dy + rad - 2), p);
    case 3:
      for (var k = 0; k < 3; k++) {
        final x0 = r.left + r.width * (0.08 + k * 0.3), x1 = x0 + r.width * 0.26;
        final a = 1.0 - k * 0.28;
        canvas.drawPath(Path()
          ..moveTo(x0, r.bottom - 2)
          ..lineTo(x1, r.bottom - 2 - (r.height - 4) * a)
          ..lineTo(x1, r.bottom - 2), Paint()..color = c.withValues(alpha: 0.3 + 0.5 * a));
      }
    default:
      const lv = [0.9, 0.65, 0.8, 0.45];
      for (var k = 0; k < 4; k++) {
        final x = r.left + r.width * (0.15 + k * 0.23);
        canvas.drawLine(Offset(x, r.bottom - 2), Offset(x, r.bottom - 2 - (r.height - 6) * lv[k]), p);
        canvas.drawCircle(Offset(x, r.bottom - 2 - (r.height - 6) * lv[k]), 2.4, Paint()..color = c);
      }
  }
}

String _time(double s) => s < 1 ? '${(s * 1000).round()} ms' : '${s.toStringAsFixed(2)} s';

bool _free(DeviceScope scope) {
  final p = scope.target.param('sync');
  return p == null || formatParamValue(p, scope.target.value('sync')) == 'Free';
}

/// The Delay's Tape, Reverse and Multi-tap pages under the Delay's [cards].
class DelayModesPage extends StatelessWidget {
  const DelayModesPage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final variant = variantOf(context);
    final free = _free(scope);
    final timeRow = controlsRow([const SyncTimeToggle(), if (!free) const DeviceChoice('sync', maxSegments: 0)]);
    Widget hero(String caption, Widget child) => HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
      color: scope.accent,
      height: 190,
      caption: caption,
      grid: false,
      readout: Builder(builder: (context) => Text(_time(delaySeconds(scope, 'sync', 'time')))),
      child: child,
    ));
    return switch (variant) {
      2 => mergedPage(context, 'delay',
          cards: cards,
          hero: hero('TAPE', const _TapeHero()),
          rows: [timeRow],
          knobs: Column(mainAxisSize: MainAxisSize.min, children: [
            KnobRow([if (free) 'time', 'feedback', 'wow', 'flutter'], size: 50),
            const KnobRow(['saturation', 'loss', 'wear', 'spread'], size: 44),
          ])),
      3 => mergedPage(context, 'delay',
          cards: cards,
          hero: hero('REVERSE', const _ReverseHero()),
          rows: [timeRow],
          knobs: KnobRow([if (free) 'time', 'feedback', 'tone', 'spread'], size: 50, labels: const {'time': 'Window'})),
      _ => mergedPage(context, 'delay',
          cards: cards,
          hero: hero('TAPS', const _TapsHero()),
          rows: [
            timeRow,
            controlsRow([smallLabel('PATTERN'), const DeviceChoice('pattern', maxSegments: 0)]),
          ],
          knobs: Column(mainAxisSize: MainAxisSize.min, children: [
            KnobRow([if (free) 'time', 'feedback', 'tone'], size: 48, labels: const {'time': 'Step'}),
            const KnobRow(['t1_level', 't2_level', 't3_level', 't4_level'], size: 40,
                labels: {'t1_level': 'Tap 1', 't2_level': 'Tap 2', 't3_level': 'Tap 3', 't4_level': 'Tap 4'}),
          ]),
          more: const KnobRow(['t1_pitch', 't2_pitch', 't3_pitch', 't4_pitch', 't1_pan', 't2_pan', 't3_pan', 't4_pan'],
              size: 38)),
    };
  }
}

/// A drag on a delay's picture: sideways the time (Free: the time knob's travel; in sync, a division per 28 px), up
/// and down the feedback.
mixin _TimeDrag<T extends StatefulWidget> on State<T> {
  bool active = false;
  double _time = 0, _fb = 0, _steps = 0;
  double _sync = 0;

  Widget timeDrag(Key key, Size size, Widget child) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return GrabGesture(
      key: key,
      onStart: (_, _) {
        _time = t.value('time');
        _fb = t.value('feedback');
        _sync = t.value('sync');
        _steps = 0;
        DeviceFeel.grab();
        setState(() => active = true);
      },
      onUpdate: (u) {
        final fine = DeviceFingers.fine;
        if (_free(scope)) {
          _time = travelBy(scope, 'time', _time, u.delta.dx / size.width * fine);
          t.setLive('time', _time);
        } else if (t.param('sync') case final p?) {
          _steps += u.delta.dx / 28 * fine;
          // Never onto Free (index 0): the time toggle does that.
          t.setLive('sync', (_sync + _steps.round()).clamp(p.min + 1, p.max).toDouble());
        }
        _fb = travelBy(scope, 'feedback', _fb, -u.delta.dy / size.height * fine);
        t.setLive('feedback', _fb);
      },
      onEnd: () {
        t.commit();
        DeviceFeel.release();
        setState(() => active = false);
      },
      onDoubleTap: (_) => t.setAll({for (final id in ['time', 'feedback']) if (t.param(id) case final p?) id: p.defaultValue}),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Tape

class _TapeHero extends StatefulWidget {
  const _TapeHero();

  @override
  State<_TapeHero> createState() => _TapeHeroState();
}

class _TapeHeroState extends State<_TapeHero> with _TimeDrag {
  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return timeDrag(const ValueKey('tape-hero'), size, DeviceDisplay(builder: (context, f) => DevicePhase(
        builder: (context, secs) => CustomPaint(size: size, painter: _TapePainter(
          secs: secs,
          wow: t.value('wow'),
          flutter: t.value('flutter'),
          wobbleMs: f?.raw == null ? null : f!.at(6),
          dropout: f?.raw == null ? 1 : f!.at(12, 1),
          feedback: t.value('feedback'),
          wear: t.value('wear'),
          time: delaySeconds(scope, 'sync', 'time'),
          color: scope.accent,
          second: scope.secondary,
          active: active)),
      )));
    });
  }
}

class _TapePainter extends CustomPainter {
  _TapePainter({required this.secs, required this.wow, required this.flutter, required this.wobbleMs,
    required this.dropout, required this.feedback, required this.wear, required this.time, required this.color,
    required this.second, required this.active});
  final double secs, wow, flutter, feedback, wear, time, dropout;
  final double? wobbleMs;
  final Color color, second;
  final bool active;

  /// The wobble now, −1..1: the engine's (its wow and flutter in ms, up to about 6.4) or the knobs' at [secs].
  double get wobble => wobbleMs != null
      ? (wobbleMs! / 3.2).clamp(-1.0, 1.0)
      : wow * math.sin(2 * math.pi * 0.55 * secs) * 0.8 + flutter * 0.3 * math.sin(2 * math.pi * 7.3 * secs);

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height, w = size.width;
    final rad = math.min(h * 0.3, w * 0.16);
    final cy = 22 + rad;
    final lx = w * 0.27, rx = w * 0.73;
    final spin = secs * 2 * math.pi * 0.6;
    final wob = wobble;
    // The reels: rims, spokes turning (the right one faster: it is filling), a hub, each nudged by the wobble.
    for (final (x, phase, fill) in [(lx, spin, 0.55), (rx, spin * 1.15 + 0.6, 0.8)]) {
      final c = Offset(x + wob * 2.5, cy);
      canvas.drawCircle(c, rad * fill, Paint()..color = color.withValues(alpha: 0.16));
      canvas.drawCircle(c, rad, Paint()
        ..color = color.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2.2 : 1.6);
      for (var k = 0; k < 3; k++) {
        final a = phase + wob * 0.35 + k * 2 * math.pi / 3;
        canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * rad * 0.22, c + Offset(math.cos(a), math.sin(a)) * rad * 0.82,
            Paint()
              ..color = color.withValues(alpha: 0.7)
              ..strokeWidth = 3
              ..strokeCap = StrokeCap.round);
      }
      canvas.drawCircle(c, rad * 0.16, Paint()..color = Neon.text);
    }
    // The tape running under the heads, its path rippling with wow and flutter.
    final ty = cy + rad + 12;
    final tape = Path()..moveTo(lx - rad, cy);
    tape.quadraticBezierTo(lx - rad, ty, lx, ty);
    const n = 60;
    for (var i = 0; i <= n; i++) {
      final x = lx + (rx - lx) * i / n;
      final y = ty + wob * 5 * math.sin(i / n * math.pi * (2 + 6 * flutter) + secs * 9) * math.sin(i / n * math.pi);
      tape.lineTo(x, y);
    }
    tape.quadraticBezierTo(rx + rad, ty, rx + rad, cy);
    strokeGlow(canvas, tape, second, width: 1.6);
    // The heads: record and play.
    for (final (x, label) in [(w * 0.42, 'REC'), (w * 0.58, 'PLAY')]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, ty + 9), width: 18, height: 10),
          const Radius.circular(2)), Paint()..color = Neon.ink.withValues(alpha: 0.5));
      paintLabel(canvas, label, Offset(x, ty + 22), Neon.dim, size: 7.5, align: 0);
    }
    // The repeats along the bottom: each darker and more worn than the last.
    final base = h - 10, top = ty + 34;
    if (base - top > 8) {
      final span = math.max(time * 6, 0.5);
      var a = 1.0;
      for (var k = 1; k <= 8 && a > 0.04; k++) {
        final x = 10 + (w - 20) * (k * time / span);
        if (x > w - 6) break;
        final hgt = (base - top) * a * (k == 1 ? dropout : 1);
        final blur = 1.5 + k * (1 + wear * 2);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - blur / 2, base - hgt, blur + 2, hgt), const Radius.circular(2)),
            Paint()..color = color.withValues(alpha: 0.25 + 0.65 * a));
        a *= feedback;
      }
      canvas.drawLine(Offset(10, base), Offset(w - 10, base), Paint()..color = Neon.ink.withValues(alpha: 0.12));
    }
  }

  @override
  bool shouldRepaint(covariant _TapePainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Reverse

class _ReverseHero extends StatefulWidget {
  const _ReverseHero();

  @override
  State<_ReverseHero> createState() => _ReverseHeroState();
}

class _ReverseHeroState extends State<_ReverseHero> with _TimeDrag {
  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return timeDrag(const ValueKey('reverse-hero'), size, DeviceDisplay(builder: (context, f) => CustomPaint(size: size,
        painter: _ReversePainter(
          window: delaySeconds(scope, 'sync', 'time'),
          feedback: t.value('feedback'),
          spread: t.value('spread'),
          heads: f?.raw == null ? null : (f!.at(4), f.at(5)),
          color: scope.accent,
          second: scope.secondary,
          active: active))));
    });
  }
}

class _ReversePainter extends CustomPainter {
  _ReversePainter({required this.window, required this.feedback, required this.spread, required this.heads,
    required this.color, required this.second, required this.active});
  final double window, feedback, spread;
  final (double, double)? heads;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final lanes = [(h * 0.25 + 12, color, 0.0), (h * 0.7, second, spread)];
    // 2.2 s across, so a longer window draws longer.
    final ww = math.max(14.0, (w - 20) * window / 2.2);
    for (final (y, c, off) in lanes) {
      final laneH = h * 0.36;
      canvas.drawLine(Offset(10, y + laneH / 2), Offset(w - 10, y + laneH / 2), Paint()..color = Neon.ink.withValues(alpha: 0.08));
      // Each window plays the last one backwards: a swell that rises to its end, then the next, quieter by the feedback.
      var a = 1.0;
      for (var k = 0; k < 12 && a > 0.05; k++) {
        final x0 = 10 + (k + off) * ww;
        if (x0 > w - 10) break;
        final x1 = math.min(w - 10, x0 + ww);
        final path = Path()..moveTo(x0, y + laneH / 2);
        for (var i = 0; i <= 24; i++) {
          final u = i / 24;
          final x = x0 + (x1 - x0) * u;
          final env = math.pow(u, 1.6);
          path.lineTo(x, y + laneH / 2 - laneH / 2 * a * env * (0.6 + 0.4 * math.sin(u * 40).abs()));
        }
        path.lineTo(x1, y + laneH / 2);
        canvas.drawPath(path, Paint()..color = c.withValues(alpha: 0.18 + 0.4 * a));
        strokeGlow(canvas, path, c.withValues(alpha: 0.5 + 0.5 * a), width: active ? 2 : 1.4, glow: k == 0);
        // The arrow: played backwards.
        paintLabel(canvas, '◀', Offset((x0 + x1) / 2, y + laneH / 2 + 9), c.withValues(alpha: 0.6 * a + 0.2), size: 8, align: 0);
        a *= feedback;
      }
    }
    // The two heads of the left side, where the engine has them.
    if (heads case (final h1, final h2)) {
      for (final p in [h1, h2]) {
        final x = 10 + p.clamp(0.0, 1.0) * ww;
        canvas.drawLine(Offset(x, 22), Offset(x, h * 0.25 + 12 + h * 0.36), Paint()
          ..color = Neon.text.withValues(alpha: 0.6)
          ..strokeWidth = 1.2);
      }
    }
    paintLabel(canvas, 'L', Offset(w - 14, h * 0.25 + 12), color, size: 8, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(w - 14, h * 0.7), second, size: 8, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _ReversePainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Multi-tap

/// Each pattern's taps in steps (the engine's: Straight, Dotted, Triplet, Swing, Gallop, Cascade).
const multiTapSteps = [
  [1.0, 2.0, 3.0, 4.0],
  [1.5, 3.0, 4.5, 6.0],
  [2 / 3, 4 / 3, 2.0, 8 / 3],
  [1.0, 5 / 3, 3.0, 11 / 3],
  [1.0, 1.5, 2.0, 3.0],
  [0.25, 0.5, 1.0, 2.0],
];

class _TapsHero extends StatefulWidget {
  const _TapsHero();

  @override
  State<_TapsHero> createState() => _TapsHeroState();
}

class _TapsHeroState extends State<_TapsHero> {
  int? _tap;
  double _pan = 0, _time = 0, _sync = 0, _steps = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final plot = Rect.fromLTRB(14, 26, w - 14, h - 12);
      final step = delaySeconds(scope, 'sync', 'time');
      final pattern = t.value('pattern').round().clamp(0, multiTapSteps.length - 1);
      final times = [for (final s in multiTapSteps[pattern]) s * step];
      final span = math.max(times.reduce(math.max) * 1.12, 0.05);
      Offset at(int k) => Offset(plot.left + times[k] / span * plot.width,
          plot.center.dy + t.value('t${k + 1}_pan').clamp(-1.0, 1.0) * plot.height / 2 * 0.85);
      int? hit(Offset p) {
        int? best;
        var d = 36.0;
        for (var k = 0; k < 4; k++) {
          final dk = (at(k) - p).distance;
          if (dk < d) {
            d = dk;
            best = k;
          }
        }
        return best;
      }
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('taps-hero'),
        onStart: (p, _) {
          _tap = hit(p);
          final k = _tap;
          if (k != null) {
            _pan = t.value('t${k + 1}_pan');
          }
          _time = t.value('time');
          _sync = t.value('sync');
          _steps = 0;
          DeviceFeel.grab();
          setState(() {});
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          final k = _tap;
          if (k != null) {
            // A tap: up and down its place between left (top) and right (bottom); sideways the step it rides on.
            _pan = (_pan + u.delta.dy / (plot.height / 2 * 0.85) * fine).clamp(-1.0, 1.0);
            t.setLive('t${k + 1}_pan', _pan);
          }
          if (_free(scope)) {
            _time = travelBy(scope, 'time', _time, u.delta.dx / plot.width * fine);
            t.setLive('time', _time);
          } else if (t.param('sync') case final p?) {
            _steps += u.delta.dx / 28 * fine;
            t.setLive('sync', (_sync + _steps.round()).clamp(p.min + 1, p.max).toDouble());
          }
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _tap = null);
        },
        onDoubleTap: (p) {
          final k = hit(p);
          if (k != null) t.set('t${k + 1}_pan', t.param('t${k + 1}_pan')?.defaultValue ?? 0);
        },
        child: CustomPaint(size: Size(w, h), painter: _TapsPainter(
          plot: plot,
          span: span,
          taps: [
            for (var k = 0; k < 4; k++)
              (at(k), t.value('t${k + 1}_level'), t.value('t${k + 1}_pitch'), f?.raw == null ? null : f!.at(9 + k * 5, -120)),
          ],
          feedback: t.value('feedback'),
          grabbed: _tap,
          color: scope.accent,
          second: scope.secondary)),
      ));
    });
  }
}

class _TapsPainter extends CustomPainter {
  _TapsPainter({required this.plot, required this.span, required this.taps, required this.feedback, required this.grabbed,
    required this.color, required this.second});
  final Rect plot;
  final double span, feedback;
  final List<(Offset, double, double, double?)> taps;
  final int? grabbed;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = plot.center.dy;
    canvas.drawLine(Offset(plot.left, mid), Offset(plot.right, mid), Paint()..color = Neon.ink.withValues(alpha: 0.12));
    paintLabel(canvas, 'L', Offset(plot.left - 8, plot.top + 4), color, size: 8, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(plot.left - 8, plot.bottom - 4), second, size: 8, weight: FontWeight.w800);
    canvas.drawCircle(Offset(plot.left, mid), 4, Paint()..color = Neon.text);
    // Second time round (the feedback): the taps again, fainter, after the last.
    final last = taps.map((e) => e.$1.dx).reduce(math.max) - plot.left;
    for (var round = 0; round < 2; round++) {
      final shift = round * last, fade = round == 0 ? 1.0 : feedback * 0.8;
      if (fade < 0.05) break;
      for (var k = 0; k < taps.length; k++) {
        final (p0, level, pitch, peak) = taps[k];
        final p = p0 + Offset(shift, 0);
        if (p.dx > plot.right + 4) continue;
        final c = Color.lerp(color, second, (p.dy - plot.top) / plot.height)!.withValues(alpha: fade);
        final lit = peak == null ? 0.0 : dbUnit(peak, floor: 48);
        canvas.drawLine(Offset(p.dx, mid), p, Paint()
          ..color = c.withValues(alpha: 0.5 * fade)
          ..strokeWidth = 1.5);
        final r = 5 + 9 * level;
        if (lit > 0) canvas.drawCircle(p, r + 6 * lit, Paint()..color = c.withValues(alpha: 0.25 * lit * fade));
        canvas.drawCircle(p, r, Paint()..color = c.withValues(alpha: (0.35 + 0.55 * level) * fade));
        if (round == 0) {
          if (grabbed == k) paintHandle(canvas, p, Neon.text, active: true, r: r + 2);
          paintLabel(canvas, '${k + 1}', p, Neon.bg, size: 8, align: 0, weight: FontWeight.w900);
          if (pitch.abs() >= 0.5) {
            paintLabel(canvas, '${pitch > 0 ? '+' : ''}${pitch.round()}', p + Offset(0, -r - 8), c, size: 8, align: 0,
                weight: FontWeight.w700);
          }
        }
      }
    }
    paintLabel(canvas, _time(span / 1.12), Offset(plot.right, plot.bottom + 4), Neon.dim, size: 8, align: 1);
  }

  @override
  bool shouldRepaint(covariant _TapsPainter o) => true;
}
