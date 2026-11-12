// The ducker's plugin UI (org.caw.ducker, #175): the duck curve as the hero (drag its handles for attack, hold,
// release, depth and curve), a playhead riding it and the live gain-reduction trace behind; trigger tiles and shapes.
import '../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_display.dart';
import '../../theme.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import 'effect_page.dart';

/// The shapes the hero offers as one-tap chips (the engine's built-in presets carry the same values).
const duckerShapes = <String, Map<String, double>>{
  'Pump': {'attack': 1.0, 'hold': 10.0, 'release': 260.0, 'tension': 0.6, 'depth': 1.0},
  'Quick': {'attack': 0.5, 'hold': 0.0, 'release': 90.0, 'tension': -0.3, 'depth': 0.8},
  'Smooth': {'attack': 15.0, 'hold': 30.0, 'release': 400.0, 'tension': -0.5, 'depth': 0.6},
  'Gate': {'attack': 0.3, 'hold': 120.0, 'release': 8.0, 'tension': 0.0, 'depth': 1.0},
};

/// The Tempo mode's divisions in beats (the engine's `kRateBeats`).
const _rateBeats = [0.25, 1 / 3, 0.5, 0.75, 2 / 3, 1.0, 1.5, 2.0, 4.0, 8.0];

/// 0..1 to 0..1 with a bend, as the engine draws it: 0 straight, > 0 slow then fast, < 0 fast then settling.
double duckBend(double x, double tension) {
  x = x.clamp(0.0, 1.0);
  if (tension.abs() < 1e-3) return x;
  final c = tension * 6;
  return (math.exp(c * x) - 1) / (math.exp(c) - 1);
}

/// How far down the duck is (0 none, 1 full) [ms] after a trigger: the attack, hold and release the engine plays.
double duckAt(double ms, double attack, double hold, double release, double tension) {
  if (ms < 0) return 0;
  if (ms < attack) return 1 - duckBend(1 - ms / attack, 0.5);
  if (ms < attack + hold) return 1;
  if (ms < attack + hold + release) return 1 - duckBend((ms - attack - hold) / release, tension);
  return 0;
}

class DuckerPage extends StatelessWidget {
  const DuckerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final mode = t.value('mode').round();
    return effectPage('ducker', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('mode', icon: _modeIcon, height: 50)),
      HeroWithMeters(height: 200, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'DUCK',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final gr = f?.values['gr'] ?? 0;
          return Text(f == null ? '' : 'GR −${gr.toStringAsFixed(1)} dB', style: Neon.code(size: 10, color: Neon.pink));
        }),
        child: const _DuckHero(),
      )),
      const _ShapeChips(),
      const KnobRow(['depth', 'attack', 'hold', 'release', 'tension', 'mix'], size: 48,
        labels: {'tension': 'Curve'}),
      switch (mode) {
        0 => ControlGroup(title: 'KEY · AUDIO', color: scope.secondary, child: Column(children: [
            const KnobRow(['threshold', 'key_hpf', 'key_lpf'], size: 44, labels: {'key_hpf': 'HPF', 'key_lpf': 'LPF'}),
            const Padding(padding: EdgeInsets.only(top: 4), child: ModeTiles('response', icon: _responseIcon, height: 44)),
            Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: const [
              DeviceToggle('listen', label: 'Key listen', icon: Icons.hearing),
            ])),
          ])),
        1 => ControlGroup(title: 'KEY · NOTES', color: scope.secondary,
            child: const KnobRow(['velocity'], size: 44, labels: {'velocity': 'Velocity'})),
        _ => ControlGroup(title: 'TEMPO', color: scope.secondary, child: const ParamGrid(only: ['rate', 'offset'])),
      },
      const DeviceFold(child: ParamGrid(only: ['bands', 'crossover', 'link', 'lookahead'])),
    ]);
  }
}

/// [iconCurve] over x 0..1 with y 0..1 (bottom to top).
void _curve01(Canvas canvas, Rect r, Color c, double Function(double x) f, {double width = 1.8}) =>
    iconCurve(canvas, r, c, (x) => f((x + 1) / 2) * 2 - 1, width: width);

void _modeIcon(Canvas canvas, Rect r, int i, Color c) {
  final p = Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.8
    ..strokeCap = StrokeCap.round;
  switch (i) {
    case 0: // a kick's waveform
      _curve01(canvas, r, c, (x) => 0.5 + 0.45 * math.exp(-x * 5) * math.sin(x * 26));
    case 1: // two notes
      for (final x in [0.3, 0.72]) {
        canvas.drawCircle(Offset(r.left + r.width * x, r.bottom - r.height * 0.2), r.height * 0.14, p);
        canvas.drawLine(Offset(r.left + r.width * x + r.height * 0.14, r.bottom - r.height * 0.2),
            Offset(r.left + r.width * x + r.height * 0.14, r.top + r.height * 0.1), p);
      }
    default: // the pump on each beat
      _curve01(canvas, r, c, (x) => 1 - duckAt((x * 2 % 1) * 300, 5, 10, 260, 0.6) * 0.9);
  }
}

void _responseIcon(Canvas canvas, Rect r, int i, Color c) => i == 0
    ? _curve01(canvas, r, c, (x) => 1 - duckAt(x * 300, 5, 20, 200, 0.5) * 0.9)
    : _curve01(canvas, r, c, (x) => 0.5 + 0.4 * math.sin(x * 9) * (1 - x));

/// One-tap duck shapes: Pump, Quick, Smooth, Gate (the trigger is left as it is).
class _ShapeChips extends StatelessWidget {
  const _ShapeChips();

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    bool on(Map<String, double> v) => v.entries.every((e) => (t.value(e.key) - e.value).abs() < 1e-6);
    return Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
      for (final e in duckerShapes.entries)
        Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Semantics(
          button: true,
          selected: on(e.value),
          label: 'Shape ${e.key}',
          child: InkWell(
            key: ValueKey('duck-shape-${e.key}'),
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              DeviceFeel.tap();
              t.setAll(e.value);
            },
            child: Container(
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: on(e.value) ? scope.accent.withValues(alpha: 0.22) : Neon.ink.withValues(alpha: 0.03),
                border: Border.all(color: on(e.value) ? scope.accent : Neon.line)),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, children: [
                CustomPaint(size: const Size(22, 14), painter: _MiniShape(e.value, on(e.value) ? scope.accent : Neon.dim)),
                const SizedBox(width: 5),
                Text(e.key.toUpperCase(), style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6,
                  color: on(e.value) ? Neon.text : Neon.dim)),
              ])),
            ),
          ),
        ))),
    ]));
  }
}

class _MiniShape extends CustomPainter {
  _MiniShape(this.v, this.color);
  final Map<String, double> v;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final a = v['attack']!, h = v['hold']!, r = v['release']!, k = v['tension']!, d = v['depth']!;
    final total = (a + h + r) * 1.2;
    _curve01(canvas, Offset.zero & size, color, (x) => 1 - d * duckAt(x * total, a, h, r, k), width: 1.4);
  }

  @override
  bool shouldRepaint(covariant _MiniShape o) => o.color != color;
}

enum _Handle { attack, hold, release, depth, tension }

/// The duck curve, drawn and draggable: gain over time from a trigger (top unity, down by the depth). Handles: the
/// attack's end, the hold's end and the release's end (sideways for their times), the floor (up and down for the
/// depth) and the middle of the release (up and down for its curve). The playhead rides the curve where the engine
/// is; the gain reduction it applied lately scrolls behind in pink.
class _DuckHero extends StatefulWidget {
  const _DuckHero();

  @override
  State<_DuckHero> createState() => _DuckHeroState();
}

class _DuckHeroState extends State<_DuckHero> {
  _Handle? _grab;
  double _start = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    double v(String id, double d) => t.param(id) == null ? d : t.value(id);
    final attack = v('attack', 1), hold = v('hold', 10), release = v('release', 220), tension = v('tension', 0.35);
    final depth = v('depth', 0.9), mix = v('mix', 1);
    final mode = v('mode', 2).round();
    final period = mode == 2
        ? _rateBeats[v('rate', 5).round().clamp(0, _rateBeats.length - 1)] * 60000 / t.state.project.bpm
        : null;
    // The window: the whole shape and a little after it, or one tempo period.
    final window = period ?? math.max(60.0, (attack + hold + release) * 1.15);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final geo = _DuckGeometry(Size(w, h), window, depth * mix);
      final handles = {
        _Handle.attack: geo.point(attack, 1),
        _Handle.hold: geo.point(attack + hold, 1),
        _Handle.release: geo.point(attack + hold + release, 0),
        // The floor's handle sits on its guide line, right of the shape, clear of the attack and hold handles.
        _Handle.depth: Offset(geo.x(math.max(attack + hold + release * 0.5, window * 0.78)), geo.y(1)),
        _Handle.tension: geo.point(attack + hold + release / 2, duckAt(attack + hold + release / 2, attack, hold, release, tension)),
      };
      return HistoryRecorder(lanes: 1, length: 120, pick: (f) => [f.values['gr'] ?? 0], builder: (context, hist, f) => GrabGesture(
        key: const ValueKey('duck-hero'),
        onStart: (p, _) {
          _Handle? best;
          var bestD = double.infinity;
          for (final e in handles.entries) {
            final d = (e.value - p).distance;
            if (d < bestD) {
              bestD = d;
              best = e.key;
            }
          }
          // Far from every handle: the floor (depth), the most useful drag.
          _grab = bestD < 44 ? best : _Handle.depth;
          _start = switch (_grab!) {
            _Handle.attack => attack,
            _Handle.hold => hold,
            _Handle.release => release,
            _Handle.depth => depth,
            _Handle.tension => tension,
          };
          DeviceFeel.grab();
          setState(() {});
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          final msPerPx = window / w * fine;
          switch (_grab) {
            case _Handle.attack:
              _start += u.delta.dx * msPerPx;
              t.setLive('attack', _start);
            case _Handle.hold:
              _start += u.delta.dx * msPerPx;
              t.setLive('hold', _start);
            case _Handle.release:
              _start += u.delta.dx * msPerPx;
              t.setLive('release', _start);
            case _Handle.depth:
              _start += u.delta.dy / math.max(1, geo.span) * fine;
              t.setLive('depth', _start.clamp(0.0, 1.0));
            case _Handle.tension:
              // Up swells back sooner (springs), down holds it low longer (the pump).
              _start += u.delta.dy / 60 * fine;
              t.setLive('tension', _start.clamp(-1.0, 1.0));
            case null:
          }
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _grab = null);
        },
        onDoubleTap: (_) => t.setAll(duckerShapes['Pump']!),
        child: CustomPaint(size: Size(w, h), painter: _DuckPainter(
          geo: geo, attack: attack, hold: hold, release: release, tension: tension, handles: handles, grab: _grab,
          hist: hist, frame: f, period: period, color: scope.accent, second: scope.secondary)),
      ));
    });
  }
}

/// Where the curve sits: time (ms, 0..[window]) across, the duck (0 at the top, 1 at the floor) down to [depth].
class _DuckGeometry {
  _DuckGeometry(this.size, this.window, this.depth);
  final Size size;
  final double window, depth;
  static const top = 24.0, bottom = 18.0, left = 10.0, right = 10.0;

  /// Pixels from unity to silence.
  double get span => size.height - top - bottom;
  double x(double ms) => left + (ms / window).clamp(0.0, 1.0) * (size.width - left - right);
  double y(double duck) => top + duck * depth.clamp(0.0, 1.0) * span;
  Offset point(double ms, double duck) => Offset(x(ms), y(duck));
}

class _DuckPainter extends CustomPainter {
  _DuckPainter({required this.geo, required this.attack, required this.hold, required this.release,
    required this.tension, required this.handles, required this.grab, required this.hist, required this.frame,
    required this.period, required this.color, required this.second});
  final _DuckGeometry geo;
  final double attack, hold, release, tension;
  final Map<_Handle, Offset> handles;
  final _Handle? grab;
  final LevelHistory hist;
  final DeviceDisplayFrame? frame;
  final double? period;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final span = geo.span;
    // The live gain reduction (dB, scrolling right to left), hanging from the top in pink.
    final n = hist.length;
    final dx = size.width / (n - 1);
    final trace = Path()..moveTo(size.width, _DuckGeometry.top);
    for (var age = 0; age < n; age++) {
      final gr = hist.at(0, age).clamp(0.0, 60.0);
      trace.lineTo(size.width - age * dx, _DuckGeometry.top + (1 - math.pow(10, -gr / 20)) * span);
    }
    trace.lineTo(0, _DuckGeometry.top);
    canvas.drawPath(trace, Paint()..color = Neon.pink.withValues(alpha: 0.12));
    // Unity and silence.
    final line = Paint()..color = Neon.ink.withValues(alpha: 0.08);
    canvas.drawLine(Offset(0, _DuckGeometry.top), Offset(size.width, _DuckGeometry.top), line);
    canvas.drawLine(Offset(0, _DuckGeometry.top + span), Offset(size.width, _DuckGeometry.top + span), line);
    // The floor (how deep it ducks): a guide line with the depth handle on it.
    final floor = geo.y(1);
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, floor), Offset(x + 4, floor), Paint()..color = second.withValues(alpha: 0.45));
    }
    // The curve.
    final path = Path();
    const steps = 160;
    for (var i = 0; i <= steps; i++) {
      final ms = geo.window * i / steps;
      final p = geo.point(ms, duckAt(ms, attack, hold, release, tension));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    final under = Path.from(path)
      ..lineTo(geo.x(geo.window), _DuckGeometry.top)
      ..lineTo(geo.x(0), _DuckGeometry.top)
      ..close();
    canvas.drawPath(under, Paint()..color = color.withValues(alpha: 0.14));
    strokeGlow(canvas, path, color, width: grab == null ? 2 : 2.6);
    // The playhead: where the engine is in the shape (or in the beat, on Tempo).
    final f = frame;
    if (f != null) {
      final pos = f.values['pos_ms'] ?? -1, phase = f.values['phase'] ?? -1;
      final ms = period != null && phase >= 0 ? phase * period! : pos;
      if (ms >= 0) {
        final duck = f.values['duck'] ?? duckAt(ms, attack, hold, release, tension);
        final at = geo.point(ms, duck);
        canvas.drawLine(Offset(at.dx, _DuckGeometry.top), Offset(at.dx, _DuckGeometry.top + span),
            Paint()..color = second.withValues(alpha: 0.5));
        canvas.drawCircle(at, 5, Paint()..color = second);
        canvas.drawCircle(at, 9, Paint()..color = second.withValues(alpha: 0.25));
      }
      // The key's level on its own scale, at the right edge (Audio mode).
      if ((f.values['mode'] ?? 0) == 0) {
        final key = f.values['key_db'] ?? -120;
        final ky = _DuckGeometry.top + (1 - dbUnit(key)) * span;
        canvas.drawLine(Offset(size.width - 4, _DuckGeometry.top + span), Offset(size.width - 4, ky),
            Paint()..color = Neon.yellow.withValues(alpha: 0.8)..strokeWidth = 3);
        final thr = f.values['threshold'] ?? -24;
        final ty = _DuckGeometry.top + (1 - dbUnit(thr)) * span;
        canvas.drawLine(Offset(size.width - 10, ty), Offset(size.width, ty), Paint()..color = Neon.yellow..strokeWidth = 1.2);
      }
    }
    for (final e in handles.entries) {
      paintHandle(canvas, e.value, e.key == _Handle.depth || e.key == _Handle.tension ? second : color,
          active: grab == e.key, r: e.key == _Handle.tension ? 5 : 6);
    }
    final ms = attack + hold + release;
    paintLabel(canvas, 'A ${_ms(attack)}  H ${_ms(hold)}  R ${_ms(release)}', Offset(10, size.height - 8), Neon.dim, size: 8);
    if (period != null) {
      paintLabel(canvas, '1 period ${_ms(period!)}', Offset(size.width - 10, size.height - 8), Neon.dim, size: 8, align: 1);
    } else {
      paintLabel(canvas, 'total ${_ms(ms)}', Offset(size.width - 14, size.height - 8), Neon.dim, size: 8, align: 1);
    }
  }

  static String _ms(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(2)} s' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ms';

  @override
  bool shouldRepaint(covariant _DuckPainter o) =>
      paintInputsChanged([o.geo, o.attack, o.hold, o.release, o.tension, o.handles, o.grab, o.hist, o.frame, o.period, o.color, o.second], [geo, attack, hold, release, tension, handles, grab, hist, frame, period, color, second]);
}
