// The space family's plugin UIs: the reverb (a room with ripples and its decaying tail, freeze) and the delays (echo taps you
// drag on left and right lanes, a ball bouncing through them in real time), for org.caw.reverb.pro, delay.pro and delay.pingpong.
import '../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import 'effect_page.dart';

// ---------------------------------------------------------------------------------------------------------------
// Reverb

/// The reverb: a room (deeper with size) with ripples spreading at the room's pace, and the tail (pre-delay gap,
/// early reflections, then the decay, darker with damping; flat and icy when frozen). Drag sideways for the decay,
/// up and down for the size.
class ReverbPage extends StatelessWidget {
  const ReverbPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('reverb', [
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'REVERB',
        grid: false,
        readout: Text('${formatParamValue(t.param('decay'), t.value('decay'))} · size ${(t.value('size') * 100).round()}%'),
        child: const _ReverbHero(),
      )),
      Row(children: [
        const DeviceToggle('freeze', label: 'Freeze', icon: Icons.ac_unit),
        const Spacer(),
        DeviceDisplay(builder: (context, f) => Text(f?.values['wet_db'] == null ? '' : 'WET ${f!.values['wet_db']!.toStringAsFixed(1)} dB',
          style: Neon.code(size: 10, color: Neon.dim))),
      ]),
      const KnobRow(['size', 'decay', 'predelay', 'damping', 'mix'], size: 50),
      const DeviceFold(child: ParamGrid(only: ['predelay_sync', 'low_cut', 'high_cut', 'width', 'mod', 'mod_rate', 'duck'])),
    ]);
  }
}

class _ReverbHero extends StatefulWidget {
  const _ReverbHero();

  @override
  State<_ReverbHero> createState() => _ReverbHeroState();
}

class _ReverbHeroState extends State<_ReverbHero> {
  bool _active = false;
  double _decay = 1, _size = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final decay = t.value('decay'), size = t.value('size');
    final damping = t.param('damping') == null ? 0.5 : t.value('damping');
    final predelay = t.param('predelay') == null ? 0.0 : t.value('predelay') / 1000;
    final freeze = t.value('freeze') >= 0.5;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return GrabGesture(
        key: const ValueKey('reverb-hero'),
        onStart: (p, _) {
          _decay = decay;
          _size = size;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final f = DeviceFingers.fine;
          _decay = (_decay * math.pow(2, u.delta.dx / 70 * f)).toDouble();
          _size = (_size - u.delta.dy / h * f).clamp(0.0, 1.0);
          t.setLive('decay', _decay);
          t.setLive('size', _size);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['decay', 'size']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: DevicePhase(builder: (context, secs) => CustomPaint(size: Size(w, h), painter: _ReverbPainter(
          decay: decay, size: size, damping: damping, predelay: predelay, freeze: freeze, seconds: secs,
          color: scope.accent, second: scope.secondary, active: _active))),
      );
    });
  }
}

class _ReverbPainter extends CustomPainter {
  _ReverbPainter({required this.decay, required this.size, required this.damping, required this.predelay,
    required this.freeze, required this.seconds, required this.color, required this.second, required this.active});
  final double decay, size, damping, predelay, seconds;
  final bool freeze, active;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size sz) {
    final w = sz.width, h = sz.height;
    final ice = Color.lerp(second, Neon.ink, 0.45)!;
    final tone = freeze ? ice : color;
    // The room: a back wall that shrinks (deeper room) with size, joined to the view's corners.
    final depth = 0.18 + size * 0.42;
    final back = Rect.fromCenter(center: Offset(w * 0.5, h * 0.46), width: w * (1 - depth) * 0.62, height: h * (1 - depth) * 0.7);
    final room = Rect.fromLTRB(w * 0.06, 22, w * 0.94, h - 8);
    final wire = Paint()
      ..color = tone.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(back, wire);
    for (final (a, b) in [(room.topLeft, back.topLeft), (room.topRight, back.topRight), (room.bottomLeft, back.bottomLeft),
        (room.bottomRight, back.bottomRight)]) {
      canvas.drawLine(a, b, wire);
    }
    // Ripples from the source (the back wall's centre), one every room-crossing, fading with the decay.
    final period = 0.5 + size * 1.3;
    for (var k = 0; k < 4; k++) {
      final age = (seconds / period - k * 0.25) % 1.0;
      final life = freeze ? 1.0 : math.exp(-age * period * 6.9 / math.max(0.15, decay) * 0.6);
      final r = back.shortestSide * 0.15 + age * room.width * 0.55;
      canvas.drawOval(Rect.fromCenter(center: back.center, width: r * 2, height: r * 1.1), Paint()
        ..color = tone.withValues(alpha: (0.35 * life * (1 - age)).clamp(0.0, 1.0))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    // The tail across the bottom half: pre-delay, early reflections, decay to −60 dB.
    final span = freeze ? 4.0 : math.max(1.5, math.min(32.0, decay * 1.25 + predelay));
    final base = h - 10, top = h * 0.36;
    double x(double s) => 8 + (w - 16) * (s / span);
    var seed = 9;
    double rand() {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return seed / 0x7FFFFFFF;
    }
    final bars = 110;
    for (var i = 0; i < bars; i++) {
      final s = span * i / bars;
      if (s < predelay) continue;
      final since = s - predelay;
      final env = freeze ? 0.85 : math.exp(-6.9 * since / math.max(0.1, decay));
      final early = since < 0.08 ? (rand() > 0.55 ? 1.0 : 0.25) : 0.55 + 0.45 * rand();
      final hh = (base - top) * env * early;
      final c = Color.lerp(tone, second, (damping * since / math.max(0.2, decay)).clamp(0.0, 1.0))!;
      canvas.drawLine(Offset(x(s), base), Offset(x(s), base - hh), Paint()
        ..color = c.withValues(alpha: 0.35 + 0.55 * env)
        ..strokeWidth = math.max(1.2, (w - 16) / bars * 0.55)
        ..strokeCap = StrokeCap.round);
    }
    // The decay envelope and its −60 dB point.
    final env = Path();
    for (var i = 0; i <= 80; i++) {
      final s = predelay + (span - predelay) * i / 80;
      final e = freeze ? 0.85 : math.exp(-6.9 * (s - predelay) / math.max(0.1, decay));
      final p = Offset(x(s), base - (base - top) * e);
      i == 0 ? env.moveTo(p.dx, p.dy) : env.lineTo(p.dx, p.dy);
    }
    strokeGlow(canvas, env, tone, width: active ? 2.4 : 1.8);
    canvas.drawLine(Offset(8, base), Offset(8, top - 6), Paint()
      ..color = Neon.text
      ..strokeWidth = 2);
    if (predelay > 0.001) paintLabel(canvas, 'PRE ${(predelay * 1000).round()} ms', Offset(x(predelay) + 4, top - 8), Neon.dim, size: 8);
    if (!freeze && decay < span) {
      paintHandle(canvas, Offset(x(predelay + decay), base - 4), tone, active: active, r: 6);
    }
    if (freeze) paintLabel(canvas, '❄ FROZEN', Offset(w - 10, top - 8), ice, size: 10, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _ReverbPainter o) =>
      paintInputsChanged([o.decay, o.size, o.damping, o.predelay, o.seconds, o.freeze, o.active, o.color, o.second], [decay, size, damping, predelay, seconds, freeze, active, color, second]);
}

// ---------------------------------------------------------------------------------------------------------------
// Delay

/// Note values by a sync choice's label, in whole notes (`delay.pro`'s T triplets and D dotted, the ping-pong
/// delay's "Dotted").
const Map<String, double> syncWholeNotes = {
  '1/64': 1 / 64, '1/32': 1 / 32, '1/16': 1 / 16, '1/8': 1 / 8, '1/4': 1 / 4, '1/2': 1 / 2, '1 bar': 1, '2 bars': 2,
  '4 bars': 4, '1/16 T': 1 / 24, '1/16 D': 3 / 32, '1/8 T': 1 / 12, '1/8 D': 3 / 16, '1/4 T': 1 / 6, '1/4 D': 3 / 8,
  '1/2 T': 1 / 3, '1/2 D': 3 / 4, 'Dotted 1/8': 3 / 16, 'Dotted 1/4': 3 / 8,
};

/// A delay's time in seconds from its sync choice [syncId] (at [bpm]) or, when free, its time knob [timeId].
double delaySeconds(DeviceScope scope, String syncId, String timeId) {
  final t = scope.target;
  if (t.param(syncId) case final p? when p.isChoice) {
    final whole = syncWholeNotes[formatParamValue(p, t.value(p.id))];
    if (whole != null) return whole * 4 * 60 / t.state.project.bpm;
  }
  final time = t.param(timeId);
  return time == null ? 0.3 : t.value(timeId) / (time.unit == 'ms' ? 1000 : 1);
}

/// The delays: the mode as tiles (when it has one), the echo taps on a left and a right lane, then the knobs.
/// Drag the first tap sideways for the time (in sync: from division to division), up and down for the feedback;
/// in Dual, the right lane's first tap sets the right time.
class DelayPage extends StatelessWidget {
  const DelayPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    bool free(String sync) {
      final p = t.param(sync);
      return p == null || formatParamValue(p, t.value(sync)) == 'Free';
    }

    final dual = t.param('mode') != null && t.value('mode').round() == 2;
    return effectPage('delay', [
      if (t.param('mode') != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('mode', icon: _modeIcon, height: 50)),
      HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: 'ECHOES',
        grid: false,
        readout: Text(_ms(delaySeconds(scope, 'sync', 'time'))),
        child: const _DelayHero(),
      )),
      // The sync pickers and Freeze: one row, or wrapped in a narrow column (inline beside the hero).
      LayoutBuilder(builder: (context, box) {
        final sync = [
          const Text('SYNC', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 8),
          const DeviceChoice('sync', maxSegments: 0),
          if (dual) ...[
            const SizedBox(width: 12),
            const Text('R', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Neon.dim)),
            const SizedBox(width: 6),
            DeviceChoice('sync_r', maxSegments: 0, color: scope.secondary),
          ],
        ];
        const freeze = DeviceToggle('freeze', label: 'Freeze', icon: Icons.ac_unit);
        if (box.maxWidth >= 320) return Row(children: [...sync, const Spacer(), freeze]);
        return Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Row(mainAxisSize: MainAxisSize.min, children: sync), freeze]);
      }),
      KnobRow([
        if (free('sync')) 'time',
        if (dual && free('sync_r')) 'time_r',
        'feedback', 'cross', 'mix', 'low_cut', 'high_cut',
      ], size: 50),
      DeviceFold(child: ParamGrid(only: [if (!dual) 'offset', 'drive', 'mod_depth', 'mod_rate', 'duck'])),
    ]);
  }

  static String _ms(double s) => s < 1 ? '${(s * 1000).round()} ms' : '${s.toStringAsFixed(2)} s';
}

void _modeIcon(Canvas canvas, Rect r, int index, Color color) {
  final p = Paint()..color = color;
  final line = Paint()
    ..color = color.withValues(alpha: 0.4)
    ..strokeWidth = 1;
  final y1 = r.top + r.height * 0.3, y2 = r.top + r.height * 0.75;
  canvas.drawLine(Offset(r.left, y1), Offset(r.right, y1), line);
  canvas.drawLine(Offset(r.left, y2), Offset(r.right, y2), line);
  for (var k = 0; k < 5; k++) {
    final x = r.left + r.width * (0.1 + k * 0.2);
    final s = 3.2 - k * 0.45;
    switch (index) {
      case 0:
        canvas.drawCircle(Offset(x, y1), s, p);
        canvas.drawCircle(Offset(x, y2), s, p);
      case 1:
        canvas.drawCircle(Offset(x, k.isEven ? y1 : y2), s, p);
      default:
        canvas.drawCircle(Offset(x, y1), s, p);
        if (k < 3) canvas.drawCircle(Offset(r.left + r.width * (0.1 + k * 0.34), y2), s, p);
    }
  }
  if (index == 1) {
    final z = Path()..moveTo(r.left + r.width * 0.1, y1);
    for (var k = 1; k < 5; k++) {
      z.lineTo(r.left + r.width * (0.1 + k * 0.2), k.isEven ? y1 : y2);
    }
    canvas.drawPath(z, Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
  }
}

class _DelayHero extends StatefulWidget {
  const _DelayHero();

  @override
  State<_DelayHero> createState() => _DelayHeroState();
}

/// One echo: its time, its side (true: right), its level.
typedef _Tap = (double seconds, bool right, double level);

class _DelayHeroState extends State<_DelayHero> {
  bool? _right; // the tap being dragged: the left lane's first (false) or the right's (true)
  double _secs = 0, _fb = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return DeviceDisplay(builder: (context, f) {
      final mode = t.param('mode') == null ? (t.value('cross') >= 0.5 ? 1 : 0) : t.value('mode').round();
      final left = f?.values['time_l_s'] ?? delaySeconds(scope, 'sync', 'time');
      final offset = t.param('offset') == null ? 0.0 : t.value('offset') / 100;
      final right = mode == 2 ? (f?.values['time_r_s'] ?? delaySeconds(scope, 'sync_r', 'time_r')) : left * (1 + offset);
      final fb = t.value('feedback'), freeze = t.value('freeze') >= 0.5;
      final mix = t.param('mix') == null ? 0.5 : t.value('mix');
      final taps = <_Tap>[];
      var level = 0.35 + 0.65 * mix;
      for (var k = 1; k <= 24 && level > 0.02; k++) {
        if (mode == 1) {
          taps.add((left * k, k.isEven, level));
        } else {
          taps.add((left * k, false, level));
          if (mode == 0) taps.add((right * k, true, level));
        }
        level *= freeze ? 1 : fb;
      }
      if (mode == 2) {
        var lr = 0.35 + 0.65 * mix;
        for (var k = 1; k <= 24 && lr > 0.02; k++) {
          taps.add((right * k, true, lr));
          lr *= freeze ? 1 : fb;
        }
      }
      final span = math.max(0.5, math.max(left, right) * 5.5);
      return LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        const x0 = 14.0;
        double x(double s) => x0 + (w - x0 - 8) * s / span;
        double sx(double px) => (px - x0) / (w - x0 - 8) * span;
        final laneL = h * 0.48, laneR = h * 0.9, tall = h * 0.3;
        Offset head(bool r) {
          final first = taps.where((tp) => tp.$2 == r).firstOrNull;
          return first == null ? const Offset(-999, -999) : Offset(x(first.$1), (r ? laneR : laneL) - tall * first.$3);
        }

        bool near(Offset p, bool r) => (Offset(head(r).dx, p.dy) - p).distance < 28 &&
            p.dy > (r ? laneR : laneL) - tall - 18 && p.dy < (r ? laneR : laneL) + 14;
        return GrabGesture(
          key: const ValueKey('delay-hero'),
          grabs: (p) => near(p, false) || (mode == 2 && near(p, true)),
          onStart: (p, _) {
            _right = mode == 2 && near(p, true) && !near(p, false);
            _secs = _right! ? right : left;
            _fb = fb;
            setState(() {});
          },
          onUpdate: (u) {
            final fine = DeviceFingers.fine;
            _secs = math.max(0.001, _secs + sx(x0 + u.delta.dx * fine));
            _setTime(scope, _right! ? 'sync_r' : 'sync', _right! ? 'time_r' : 'time', _secs);
            _fb = (_fb - u.delta.dy / tall * 0.5 * fine).clamp(0.0, 1.0);
            t.setLive('feedback', _fb);
          },
          onEnd: () {
            t.commit();
            setState(() => _right = null);
          },
          onDoubleTap: (_) => t.setAll({
            for (final id in ['feedback', 'time', 'sync']) if (t.param(id) case final p?) id: p.defaultValue,
          }),
          child: DevicePhase(builder: (context, secs) => CustomPaint(size: Size(w, h), painter: _DelayPainter(
            taps: taps, x: x, laneL: laneL, laneR: laneR, tall: tall, span: span, seconds: secs, pingPong: mode == 1,
            color: scope.accent, second: scope.secondary, active: _right, freeze: freeze,
            drive: t.param('drive') == null ? 0 : t.value('drive')))),
        );
      });
    });
  }

  /// Sets the time: in sync, the nearest division (a detent each step); free, the time knob.
  void _setTime(DeviceScope scope, String syncId, String timeId, double seconds) {
    final t = scope.target;
    final sync = t.param(syncId);
    if (sync != null && sync.isChoice && formatParamValue(sync, t.value(syncId)) != 'Free') {
      final bpm = t.state.project.bpm;
      var best = t.value(syncId).round();
      var err = double.infinity;
      for (var k = 0; k < sync.choices.length; k++) {
        final whole = syncWholeNotes[sync.choices[k]];
        if (whole == null) continue;
        final e = (math.log(whole * 240 / bpm) - math.log(seconds)).abs();
        if (e < err) {
          err = e;
          best = k;
        }
      }
      if (best != (t.value(syncId) - sync.min).round()) {
        DeviceFeel.detent();
        t.setLive(syncId, sync.min + best);
      }
      return;
    }
    final p = t.param(timeId);
    if (p != null) t.setLive(timeId, seconds * (p.unit == 'ms' ? 1000 : 1));
  }
}

class _DelayPainter extends CustomPainter {
  _DelayPainter({required this.taps, required this.x, required this.laneL, required this.laneR, required this.tall,
    required this.span, required this.seconds, required this.pingPong, required this.color, required this.second,
    required this.active, required this.freeze, required this.drive});
  final List<_Tap> taps;
  final double Function(double s) x;
  final double laneL, laneR, tall, span, seconds, drive;
  final bool pingPong, freeze;
  final bool? active;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final faint = Paint()..color = Neon.ink.withValues(alpha: 0.08);
    canvas.drawLine(Offset(0, laneL), Offset(size.width, laneL), faint);
    canvas.drawLine(Offset(0, laneR), Offset(size.width, laneR), faint);
    paintLabel(canvas, 'L', Offset(4, laneL - 8), color, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(4, laneR - 8), second, size: 9, weight: FontWeight.w800);
    // The dry hit.
    for (final lane in [laneL, laneR]) {
      canvas.drawLine(Offset(x(0), lane), Offset(x(0), lane - tall), Paint()
        ..color = Neon.text
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round);
    }
    // The ball: travels the echoes in real time and loops.
    final now = seconds % span;
    final hot = Color.lerp(Neon.ink, Neon.pink, drive.clamp(0.0, 1.0) * 0.6)!;
    var firstL = true, firstR = true;
    for (final (s, right, level) in taps) {
      if (s > span) continue;
      final lane = right ? laneR : laneL;
      final c = Color.lerp(right ? second : color, hot, 0.15)!;
      final since = now - s;
      final flash = since >= 0 && since < 0.18 ? 1 - since / 0.18 : 0.0;
      final top = Offset(x(s), lane - tall * level);
      if (flash > 0) canvas.drawCircle(top, 8 + 6 * flash, Paint()..color = c.withValues(alpha: 0.35 * flash));
      canvas.drawLine(Offset(x(s), lane), top, Paint()
        ..color = c.withValues(alpha: 0.35 + 0.6 * level)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round);
      final first = right ? firstR : firstL;
      if (first) {
        paintHandle(canvas, top, c, active: active == right, r: 7);
        right ? firstR = false : firstL = false;
      } else {
        canvas.drawCircle(top, 2.5, Paint()..color = c);
      }
    }
    if (pingPong) {
      // The bounce path between the sides.
      final zig = Path()..moveTo(x(0), laneL - tall);
      for (final (s, right, level) in taps) {
        if (s > span) break;
        zig.lineTo(x(s), (right ? laneR : laneL) - tall * level);
      }
      canvas.drawPath(zig, Paint()
        ..color = color.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    // Where the sound is now: between the last echo passed and the next.
    _Tap? prev, next;
    for (final tp in taps) {
      if (tp.$1 <= now) prev = tp;
      if (tp.$1 > now) {
        next = tp;
        break;
      }
    }
    if (next != null) {
      final a = prev ?? (0.0, false, 1.0);
      final f = ((now - a.$1) / math.max(1e-3, next.$1 - a.$1)).clamp(0.0, 1.0);
      final ya = (a.$2 ? laneR : laneL) - tall * a.$3, yb = (next.$2 ? laneR : laneL) - tall * next.$3;
      final bx = x(a.$1) + (x(next.$1) - x(a.$1)) * f;
      final by = ya + (yb - ya) * f - math.sin(f * math.pi) * 14;
      canvas.drawCircle(Offset(bx, by), 9, Paint()..color = Neon.ink.withValues(alpha: 0.15));
      canvas.drawCircle(Offset(bx, by), 4.5, Paint()..color = Neon.ink);
    }
    if (freeze) {
      paintLabel(canvas, '❄ FROZEN', Offset(size.width - 8, 30), Color.lerp(second, Neon.ink, 0.4)!, size: 10, align: 1,
          weight: FontWeight.w800);
    }
  }

  @override
  bool shouldRepaint(covariant _DelayPainter o) =>
      paintInputsChanged([o.taps, o.x, o.laneL, o.laneR, o.tall, o.span, o.seconds, o.drive, o.pingPong, o.freeze, o.active, o.color, o.second], [taps, x, laneL, laneR, tall, span, seconds, drive, pingPong, freeze, active, color, second]);
}
