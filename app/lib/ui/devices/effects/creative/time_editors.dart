// The time plugin UIs (fx-creative): tape stop (its speed curve with a hold-to-stop pad), reverser (chunks played backwards) and stutter (a beat repeat's slices).
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import 'creative_common.dart';

// ---------- Tape stop ----------

/// The tape stop's speed v at progress x (0..1) of a stop ([stopping]) or a start, with [curve] −1..1: the engine's
/// (1 − x)^p and 1 − (1 − x)^p, p = 4^curve.
double tapeSpeed(double x, double curve, {required bool stopping}) {
  final p = math.pow(4, curve.clamp(-1.0, 1.0)).toDouble();
  final v = math.pow((1 - x).clamp(0.0, 1.0), p).toDouble();
  return stopping ? v : 1 - v;
}

/// Seconds of a stop or start: its sync division at the song's tempo, else its free time.
double tapeSeconds(DeviceScope scope, String time, String sync) {
  final t = scope.target;
  final p = t.param(sync);
  if (p != null && t.value(sync) >= 0.5) {
    final s = divisionSeconds(formatParamValue(p, t.value(sync)), t.state.project.bpm);
    if (s != null) return s.clamp(0.001, 8.0);
  }
  return valueOr(scope, time, 500) / 1000;
}

/// The tape stop: the motor's speed over a stop and a start (drag sideways for the stop time, up and down for the
/// curve), a dot riding it where the engine is, the hold-to-stop pad, then the knobs.
class TapeStopPage extends StatelessWidget {
  const TapeStopPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final stopFree = t.value('stop_sync') < 0.5, startFree = t.value('start_sync') < 0.5;
    return effectPage('tapestop', [
      HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: 'TAPE SPEED',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) => Text(f == null
            ? '${(tapeSeconds(scope, 'stop_time', 'stop_sync') * 1000).round()} ms ≈'
            : '${((f.values['speed'] ?? 1) * 100).round()} % speed')),
        child: const _TapeHero(),
      )),
      const Padding(padding: EdgeInsets.only(bottom: 8),
        child: HoldPad('stop', label: 'HOLD TO STOP', held: 'STOPPED · LET GO TO START', icon: Icons.stop_circle_outlined)),
      const LabelledChoice('STOP SYNC', 'stop_sync'),
      const LabelledChoice('START SYNC', 'start_sync'),
      KnobRow([if (stopFree) 'stop_time', if (startFree) 'start_time', 'curve', 'stop', 'mix'], size: 50,
        labels: const {'stop': 'Trigger'}),
    ]);
  }
}

class _TapeHero extends StatefulWidget {
  const _TapeHero();

  @override
  State<_TapeHero> createState() => _TapeHeroState();
}

class _TapeHeroState extends State<_TapeHero> {
  bool _active = false;
  double _time = 0, _curve = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final curve = t.value('curve');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('tapestop-hero'),
        onStart: (_, _) {
          _time = t.value('stop_time');
          _curve = curve;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          if (t.value('stop_sync') < 0.5) _time = dragAlongTaper(scope, 'stop_time', _time, u.delta.dx / w) ?? _time;
          _curve = (_curve - u.delta.dy / (h * 0.8) * 2).clamp(-1.0, 1.0);
          t.setLive('curve', _curve);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['stop_time', 'curve']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _TapePainter(
          curve: curve,
          stopS: tapeSeconds(scope, 'stop_time', 'stop_sync'),
          startS: tapeSeconds(scope, 'start_time', 'start_sync'),
          state: f?.values['state']?.round(),
          progress: f?.values['progress'],
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _TapePainter extends CustomPainter {
  _TapePainter({required this.curve, required this.stopS, required this.startS, required this.state, required this.progress,
    required this.color, required this.second, required this.active});
  final double curve, stopS, startS;
  final int? state;
  final double? progress;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // Playing, the stop's ramp, stopped, the start's ramp, playing; the ramps' widths follow their times.
    final top = 26.0, bottom = size.height - 18;
    final total = size.width - 20;
    final share = (stopS / (stopS + startS)).clamp(0.2, 0.8);
    final ramps = total * 0.72;
    final x0 = 10 + total * 0.08, x1 = x0 + ramps * share, x2 = x1 + total * 0.12, x3 = x2 + ramps * (1 - share);
    double y(double v) => bottom - (bottom - top) * v.clamp(0.0, 1.0);
    final path = Path()..moveTo(10, y(1))..lineTo(x0, y(1));
    for (var i = 1; i <= 48; i++) {
      final x = i / 48;
      path.lineTo(x0 + (x1 - x0) * x, y(tapeSpeed(x, curve, stopping: true)));
    }
    path.lineTo(x2, y(0));
    for (var i = 1; i <= 48; i++) {
      final x = i / 48;
      path.lineTo(x2 + (x3 - x2) * x, y(tapeSpeed(x, curve, stopping: false)));
    }
    path.lineTo(size.width - 10, y(1));
    fillFade(canvas, path, bottom, size, color);
    strokeGlow(canvas, path, color, width: active ? 3 : 2.2);
    canvas.drawLine(Offset(10, bottom), Offset(size.width - 10, bottom), Paint()..color = Neon.line);
    paintLabel(canvas, 'STOP ${_ms(stopS)}', Offset((x0 + x1) / 2, bottom + 9), Neon.dim, size: 8, align: 0);
    paintLabel(canvas, 'START ${_ms(startS)}', Offset((x2 + x3) / 2, bottom + 9), Neon.dim, size: 8, align: 0);
    // Where the motor is now (the engine's state and progress).
    if (state case final s?) {
      final p = (progress ?? 0).clamp(0.0, 1.0);
      final (x, v) = switch (s) {
        1 => (x0 + (x1 - x0) * p, tapeSpeed(p, curve, stopping: true)),
        2 => ((x1 + x2) / 2, 0.0),
        3 => (x2 + (x3 - x2) * p, tapeSpeed(p, curve, stopping: false)),
        _ => (x0 * 0.6, 1.0),
      };
      paintHandle(canvas, Offset(x, y(v)), second, active: s == 1 || s == 3, r: 6);
    }
  }

  static String _ms(double s) => s < 1 ? '${(s * 1000).round()} ms' : '${s.toStringAsFixed(2)} s';

  @override
  bool shouldRepaint(covariant _TapePainter o) =>
      paintInputsChanged([o.curve, o.stopS, o.startS, o.state, o.progress, o.color, o.second, o.active], [curve, stopS, startS, state, progress, color, second, active]);
}

// ---------- Reverser ----------

/// The reverser: chunks drawn as blocks, each played back reversed one chunk later (an arrow pointing back), the
/// crossfades as ramps at their seams (drag sideways for the time or the division, up and down for the crossfade).
class ReverserPage extends StatelessWidget {
  const ReverserPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final free = t.value('sync') < 0.5;
    return effectPage('reverser', [
      HeroWithMeters(height: 180, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 180,
        caption: 'REVERSED CHUNKS',
        grid: false,
        readout: Text(free ? '${t.value('time').round()} ms' : formatParamValue(t.param('sync'), t.value('sync'))),
        child: const _ReverserHero(),
      )),
      const LabelledChoice('SYNC', 'sync'),
      KnobRow([if (free) 'time', 'crossfade', 'mix'], size: 52),
    ]);
  }
}

class _ReverserHero extends StatefulWidget {
  const _ReverserHero();

  @override
  State<_ReverserHero> createState() => _ReverserHeroState();
}

class _ReverserHeroState extends State<_ReverserHero> {
  bool _active = false;
  double _x = 0, _fade = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final sp = t.param('sync');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('reverser-hero'),
        onStart: (_, _) {
          _x = t.value('sync') < 0.5 ? t.value('time') : t.value('sync');
          _fade = t.value('crossfade');
          setState(() => _active = true);
        },
        onUpdate: (u) {
          if (t.value('sync') < 0.5) {
            _x = dragAlongTaper(scope, 'time', _x, u.delta.dx / w) ?? _x;
          } else if (sp != null) {
            // A synced chunk steps through the divisions (never down to Free).
            _x = (_x + u.delta.dx / w * 10).clamp(1.0, sp.max);
            t.setLive('sync', _x.roundToDouble());
          }
          _fade = (_fade - u.delta.dy / h * 60).clamp(0.0, 50.0);
          t.setLive('crossfade', _fade);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['crossfade']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _ReverserPainter(
          fade: t.value('crossfade') / 100,
          position: f?.values['position'],
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _ReverserPainter extends CustomPainter {
  _ReverserPainter({required this.fade, required this.position, required this.color, required this.second, required this.active});
  final double fade;
  final double? position;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // Three chunks in (top lane), each coming out reversed a chunk later (bottom lane), with a ramp at its seams.
    const n = 3;
    final left = 12.0, cw = (size.width - 24) / (n + 1);
    final inTop = 30.0, laneH = (size.height - 60) / 2, outTop = inTop + laneH + 14;
    final hues = [color, second, Color.lerp(color, second, 0.5)!];
    for (var k = 0; k < n; k++) {
      final r = Rect.fromLTWH(left + k * cw + 2, inTop, cw - 4, laneH);
      final c = hues[k % 3];
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), Paint()..color = c.withValues(alpha: 0.18));
      // A rising ramp in: the chunk as recorded.
      final rec = Path()..moveTo(r.left + 4, r.bottom - 4)..lineTo(r.right - 4, r.top + 6);
      strokeGlow(canvas, rec, c.withValues(alpha: 0.8), width: 1.6, glow: false);
      // Out, reversed: the same ramp falling, a chunk later, faded at its seams.
      final o = Rect.fromLTWH(left + (k + 1) * cw + 2, outTop, cw - 4, laneH);
      final f = (fade * (cw - 4)).clamp(0.0, (cw - 4) / 2);
      final env = Path()
        ..moveTo(o.left, o.bottom)
        ..lineTo(o.left + f, o.top)
        ..lineTo(o.right - f, o.top)
        ..lineTo(o.right, o.bottom);
      fillFade(canvas, env, o.bottom, size, c, alpha: 0.35);
      final back = Path()..moveTo(o.left + 4, o.top + 6)..lineTo(o.right - 4, o.bottom - 4);
      strokeGlow(canvas, back, c, width: active ? 2.6 : 2);
      // An arrow from the chunk to its reversed copy.
      final a = Offset(r.center.dx, r.bottom + 2), b = Offset(o.center.dx, o.top - 2);
      canvas.drawLine(a, b, Paint()..color = c.withValues(alpha: 0.4)..strokeWidth = 1);
    }
    // The empty corners name the lanes: in (top right), out reversed (bottom left).
    paintLabel(canvas, 'IN', Offset(left + n * cw + cw / 2, inTop + laneH / 2), Neon.dim, size: 8, align: 0);
    paintLabel(canvas, 'OUT', Offset(left + cw / 2, outTop + laneH / 2 - 6), Neon.dim, size: 8, align: 0);
    paintLabel(canvas, 'REVERSED', Offset(left + cw / 2, outTop + laneH / 2 + 6), Neon.dim, size: 7, align: 0);
    if (position case final p?) {
      final x = left + cw + 2 + p.clamp(0.0, 1.0) * (cw - 4);
      canvas.drawLine(Offset(x, inTop), Offset(x, size.height - 8), Paint()..color = Neon.text.withValues(alpha: 0.7)..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _ReverserPainter o) =>
      paintInputsChanged([o.fade, o.position, o.color, o.second, o.active], [fade, position, color, second, active]);
}

// ---------- Stutter ----------

/// The stutter: one interval with its repeat drawn as slices, each quieter (decay) and higher or lower (pitch),
/// gated to the gate's share (drag up and down for the pitch per repeat, sideways for the decay), a light while
/// it repeats, the hold pad, then the grid's choices and the knobs.
class StutterPage extends StatelessWidget {
  const StutterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('stutter', [
      HeroWithMeters(height: 180, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 180,
        caption: 'REPEATS ≈',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) => Text(f == null
            ? '${(scope.target.value('chance') * 100).round()} % chance'
            : (f.values['active'] ?? 0) > 0.5 ? 'REPEAT ${(f.values['repeat'] ?? 0).round() + 1}' : 'waiting')),
        child: const _StutterHero(),
      )),
      const Padding(padding: EdgeInsets.only(bottom: 8),
        child: HoldPad('hold', label: 'HOLD TO REPEAT', held: 'REPEATING', icon: Icons.repeat)),
      const LabelledChoice('EVERY', 'interval'),
      const LabelledChoice('SLICE', 'division'),
      const LabelledChoice('LENGTH', 'length'),
      KnobRow(const ['chance', 'decay', 'pitch', 'gate', 'mix'], size: 50),
      const DeviceFold(child: ParamGrid(only: ['offset', 'seed'])),
    ]);
  }
}

class _StutterHero extends StatefulWidget {
  const _StutterHero();

  @override
  State<_StutterHero> createState() => _StutterHeroState();
}

class _StutterHeroState extends State<_StutterHero> {
  bool _active = false;
  double _pitch = 0, _decay = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    double beats(String id, List<double> table) {
      final i = t.value(id).round();
      return i >= 0 && i < table.length ? table[i] : table.first;
    }
    final slice = beats('division', const [0.0625, 0.125, 1 / 6, 0.25, 1 / 3, 0.5, 1, 2]);
    final length = beats('length', const [0.25, 0.5, 1, 2, 4, 8]);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('stutter-hero'),
        onStart: (_, _) {
          _pitch = t.value('pitch');
          _decay = t.value('decay');
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _pitch = (_pitch - u.delta.dy / h * 12).clamp(-12.0, 12.0);
          t.setLive('pitch', _pitch);
          _decay = (_decay + u.delta.dx / w).clamp(0.0, 1.0);
          t.setLive('decay', _decay);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({'pitch': 0, if (t.param('decay') case final p?) 'decay': p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _StutterPainter(
          repeats: (length / slice).clamp(1, 64).round(),
          decay: t.value('decay'),
          pitch: t.value('pitch'),
          gate: valueOr(scope, 'gate', 1),
          now: (f?.values['active'] ?? 0) > 0.5 ? f?.values['repeat']?.round() : null,
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _StutterPainter extends CustomPainter {
  _StutterPainter({required this.repeats, required this.decay, required this.pitch, required this.gate, required this.now,
    required this.color, required this.second, required this.active});
  final int repeats;
  final double decay, pitch, gate;
  final int? now;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final left = 10.0, top = 28.0, bottom = size.height - 12;
    final sw = (size.width - 20) / repeats;
    for (var n = 0; n < repeats; n++) {
      final level = math.pow(1 - decay, n).toDouble();
      final ratio = math.pow(2, (n * pitch).clamp(-48, 48) / 12).toDouble();
      final audible = math.min(1.0, gate / ratio);
      final x = left + n * sw;
      final hh = (bottom - top) * level;
      final r = Rect.fromLTWH(x + 1, bottom - hh, math.max(1.0, (sw - 2) * audible), hh);
      final c = n == 0 ? Neon.dim : Color.lerp(color, second, n / math.max(1, repeats - 1))!;
      final lit = now == n;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)),
        Paint()..color = c.withValues(alpha: lit ? 0.9 : (active ? 0.5 : 0.35)));
      // The repeat's pitch as a wave of its frequency (more cycles up, fewer down).
      if (sw > 14) {
        final wave = Path();
        final cycles = 2 * ratio;
        for (var i = 0; i <= 24; i++) {
          final u = i / 24;
          final px = r.left + u * r.width, py = r.center.dy + math.sin(u * cycles * 2 * math.pi) * r.height * 0.3;
          i == 0 ? wave.moveTo(px, py) : wave.lineTo(px, py);
        }
        canvas.drawPath(wave, Paint()..color = Neon.text.withValues(alpha: 0.55)..style = PaintingStyle.stroke..strokeWidth = 1);
      }
    }
    paintLabel(canvas, pitch == 0 ? 'NO PITCH' : '${pitch > 0 ? '+' : ''}${pitch.toStringAsFixed(1)} st / repeat',
      Offset(size.width - 12, size.height - 6), Neon.dim, size: 8, align: 1);
  }

  @override
  bool shouldRepaint(covariant _StutterPainter o) =>
      paintInputsChanged([o.repeats, o.decay, o.pitch, o.gate, o.now, o.color, o.second, o.active], [repeats, decay, pitch, gate, now, color, second, active]);
}
