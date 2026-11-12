// The 3-band EQ's, the tilt EQ's and the graphic EQ's plugin UIs: band regions with crossover handles, a tilting line, and 31 bars drawn with a finger.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../visuals/filter_curve.dart' show freqToX, xToFreq;
import '../effect_page.dart';
import 'filters_shared.dart';
import '../../../../model/device_target.dart' show clampToParam;

// ---------- 3-band EQ ----------

const _bandIds = ['low', 'mid', 'high'];
const _killIds = ['kill_low', 'kill_mid', 'kill_high'];

/// The 3-band EQ: its three bands as regions (drag a band up or down for its gain, a crossover line sideways for
/// the split; double-tap a band to kill it), kill switches, the three gains; the splits and output in MORE.
class Eq3Page extends StatelessWidget {
  const Eq3Page({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('eq.dj', [
      HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: '3-BAND ≈',
        grid: false,
        readout: Text('${t.value('low_x').round()} · ${t.value('high_x').round()} Hz'),
        child: const _Eq3Hero(),
      )),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        for (var b = 0; b < 3; b++) DeviceToggle(_killIds[b], label: 'KILL ${['LOW', 'MID', 'HIGH'][b]}', icon: Icons.block, color: Neon.pink),
      ]),
      const SizedBox(height: 6),
      const KnobRow(['low', 'mid', 'high'], size: 56),
      const DeviceFold(child: ParamGrid(only: ['low_x', 'high_x', 'output'])),
    ]);
  }
}

class _Eq3Hero extends StatefulWidget {
  const _Eq3Hero();

  @override
  State<_Eq3Hero> createState() => _Eq3HeroState();
}

class _Eq3HeroState extends State<_Eq3Hero> {
  String? _param;  // what the finger moves: a band's gain or a crossover
  double _pos = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      double y(double db) => h * 0.45 - db / 30 * (h * 0.45 - 22);
      String bandAt(double x) {
        final hz = xToFreq(x, w);
        return hz < t.value('low_x') ? 'low' : (hz < t.value('high_x') ? 'mid' : 'high');
      }
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('eq3-hero'),
        onStart: (p, _) {
          final lx = freqToX(t.value('low_x'), w), hx = freqToX(t.value('high_x'), w);
          _param = (p.dx - lx).abs() < 18 ? 'low_x' : ((p.dx - hx).abs() < 18 ? 'high_x' : bandAt(p.dx));
          final pp = t.param(_param!);
          _pos = _param!.endsWith('_x') ? freqToX(t.value(_param!), w) : (pp == null ? 0 : taperOf(pp).position(t.value(_param!)));
          setState(() {});
        },
        onUpdate: (u) {
          final id = _param, p = id == null ? null : t.param(id);
          if (id == null || p == null) return;
          final fine = DeviceFingers.fine;
          if (id.endsWith('_x')) {
            _pos = (_pos + u.delta.dx * fine).clamp(0.0, w);
            t.setLive(id, clampToParam(p, xToFreq(_pos, w)));
          } else {
            _pos = (_pos - u.delta.dy / (h * 0.8) * fine).clamp(0.0, 1.0);
            t.setLive(id, taperOf(p).value(_pos));
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _param = null);
        },
        onDoubleTap: (p) {
          final k = _killIds[_bandIds.indexOf(bandAt(p.dx))];
          t.set(k, t.value(k) >= 0.5 ? 0 : 1);
        },
        child: CustomPaint(size: Size(w, h), painter: _Eq3Painter(
          gains: [for (var b = 0; b < 3; b++) t.value(_killIds[b]) >= 0.5 ? 0.0 : math.pow(10, t.value(_bandIds[b]) / 20).toDouble()],
          kills: [for (final k in _killIds) t.value(k) >= 0.5],
          low: t.value('low_x'), high: t.value('high_x'), out: t.value('output'), y: y,
          peaks: f == null ? null : [for (final k in ['low_db', 'mid_db', 'high_db']) f.values[k] ?? -120],
          active: _param, colors: [scope.accent, scope.secondary, Neon.violet])),
      ));
    });
  }
}

class _Eq3Painter extends CustomPainter {
  _Eq3Painter({required this.gains, required this.kills, required this.low, required this.high, required this.out,
    required this.y, required this.peaks, required this.active, required this.colors});
  final List<double> gains;
  final List<bool> kills;
  final double low, high, out;
  final double Function(double db) y;
  final List<double>? peaks;
  final String? active;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    paintFrequencyGrid(canvas, size, y(0));
    final lx = freqToX(low, w), hx = freqToX(high, w);
    final edges = [0.0, lx, hx, w];
    for (var b = 0; b < 3; b++) {
      final r = Rect.fromLTRB(edges[b], 20, edges[b + 1], h);
      canvas.drawRect(r, Paint()..color = (kills[b] ? Neon.pink : colors[b]).withValues(alpha: kills[b] ? 0.06 : 0.08));
      paintLabel(canvas, kills[b] ? 'KILLED' : ['LOW', 'MID', 'HIGH'][b], Offset(r.center.dx, h - 22),
        kills[b] ? Neon.pink : colors[b], size: 9, align: 0, weight: FontWeight.w800);
      // The band's level lately (live): a bar at its region's foot.
      if (peaks case final p?) {
        final u = ((p[b] + 60) / 60).clamp(0.0, 1.0);
        canvas.drawRect(Rect.fromLTWH(r.left + 4, h - 6, (r.width - 8) * u, 3), Paint()..color = colors[b].withValues(alpha: 0.7));
      }
    }
    final g = math.pow(10, out / 20).toDouble();
    double db(double hz) {
      final bands = eq3Bands(hz, low: low, high: high);
      var s = const Cx(0);
      for (var b = 0; b < 3; b++) {
        s = s + bands[b].scale(gains[b]);
      }
      return toDb(s.abs * g);
    }
    final path = responsePath(size, db, y);
    fillFade(canvas, path, h, size, colors[0], alpha: 0.22);
    strokeGlow(canvas, path, colors[0], width: 2.4);
    for (final (x, id) in [(lx, 'low_x'), (hx, 'high_x')]) {
      canvas.drawLine(Offset(x, 20), Offset(x, h), Paint()
        ..color = Neon.ink.withValues(alpha: active == id ? 0.6 : 0.25)
        ..strokeWidth = active == id ? 2 : 1);
      paintHandle(canvas, Offset(x, 30), colors[1], active: active == id, r: 6);
    }
  }

  @override
  bool shouldRepaint(covariant _Eq3Painter o) =>
      paintInputsChanged([o.gains, o.kills, o.low, o.high, o.out, o.y, o.peaks, o.active, o.colors], [gains, kills, low, high, out, y, peaks, active, colors]);
}

// ---------- Tilt ----------

/// The tilt EQ: the tilting line (drag: sideways the pivot, up tilts the highs up), then tilt, pivot and
/// steepness; the channel and output in MORE.
class TiltPage extends StatelessWidget {
  const TiltPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final tilt = t.value('tilt');
    return effectPage('tilt', [
      HeroWithMeters(height: 180, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 180,
        caption: 'TILT ≈',
        grid: false,
        readout: Text('${tilt >= 0 ? '+' : ''}${tilt.toStringAsFixed(1)} dB'),
        child: DragHero(heroKey: 'tilt-hero', xParam: 'freq', yParam: 'tilt', paint: (canvas, size, active, f) {
          final h = size.height, freq = t.value('freq'), q = t.value('q');
          double y(double db) => h * 0.5 - db / 15 * (h * 0.5 - 22);
          paintFrequencyGrid(canvas, size, y(0));
          final path = responsePath(size, (hz) => toDb(tiltResponse(hz, tilt: tilt, freq: freq, q: q).abs) + t.value('output'), y);
          fillFade(canvas, path, h, size, tilt >= 0 ? scope.secondary : scope.accent, alpha: 0.28);
          strokeGlow(canvas, path, scope.accent, width: 2.6);
          paintLabel(canvas, 'DARKER', Offset(10, h - 20), Neon.dim, size: 8, weight: FontWeight.w800);
          paintLabel(canvas, 'BRIGHTER', Offset(size.width - 10, h - 20), Neon.dim, size: 8, align: 1, weight: FontWeight.w800);
          paintHandle(canvas, Offset(freqToX(freq, size.width), y(0)), scope.accent, active: active, r: 8);
        }),
      )),
      const KnobRow(['tilt', 'freq', 'q'], size: 56),
      Row(children: [fieldLabel('CHANNEL'), const DeviceChoice('channel')]),
      const DeviceFold(child: ParamGrid(only: ['output'])),
    ]);
  }
}

// ---------- Graphic EQ ----------

const geqCentres = [20.0, 25.0, 31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0, 200.0, 250.0, 315.0, 400.0, 500.0,
  630.0, 800.0, 1000.0, 1250.0, 1600.0, 2000.0, 2500.0, 3150.0, 4000.0, 5000.0, 6300.0, 8000.0, 10000.0, 12500.0, 16000.0,
  20000.0];

/// The graphic EQ: 31 bars drawn with a finger (a drag across them sets each it passes to the finger's height; a
/// double-tap flattens the bar under it), the analyser and the engine's real curve while it plays, Flat, range and
/// output.
class GraphicEqPage extends StatelessWidget {
  const GraphicEqPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('geq', [
      HeroCanvas(color: scope.accent, height: 210, caption: 'GRAPHIC EQ', grid: false,
        readout: const LevelReadout(), child: const _GeqHero()),
      Row(children: [
        Expanded(child: KnobRow(const ['range', 'output'], size: 52)),
        OutlinedButton.icon(
          key: const ValueKey('geq-flat'),
          onPressed: () {
            DeviceFeel.tap();
            t.setAll({for (var b = 1; b <= 31; b++) 'g$b': 0});
          },
          icon: const Icon(Icons.horizontal_rule, size: 16),
          label: const Text('FLAT')),
      ]),
    ]);
  }
}

class _GeqHero extends StatefulWidget {
  const _GeqHero();

  @override
  State<_GeqHero> createState() => _GeqHeroState();
}

class _GeqHeroState extends State<_GeqHero> {
  int? _last;  // the bar the finger was over

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      const top = 24.0, foot = 16.0;
      double y(double db) => top + (h - top - foot) * (0.5 - db / 24);
      double dbAt(double py) => ((0.5 - (py - top) / (h - top - foot)) * 24).clamp(-12.0, 12.0);
      int barAt(double x) => (x / w * 31).floor().clamp(0, 30);
      void paintTo(Offset p) {
        final b = barAt(p.dx), db = (dbAt(p.dy) * 2).roundToDouble() / 2;
        // A quick swipe skips bars: fill in between from the last one.
        final from = _last ?? b;
        for (var k = math.min(from, b); k <= math.max(from, b); k++) {
          t.setLive('g${k + 1}', db);
        }
        _last = b;
      }
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('geq-hero'),
        onStart: (p, _) {
          _last = null;
          paintTo(p);
          setState(() {});
        },
        onUpdate: (u) => paintTo(u.local),
        onEnd: () {
          t.commit();
          setState(() => _last = null);
        },
        onDoubleTap: (p) => t.set('g${barAt(p.dx) + 1}', 0),
        child: CustomPaint(size: Size(w, h), painter: _GeqPainter(
          gains: [for (var b = 1; b <= 31; b++) t.value('g$b') * t.value('range')],
          spectrum: f?.spectrum,
          curve: f == null ? null : [for (var j = 0; j < 64; j++) f.values['c$j'] ?? 0],
          y: y, color: scope.accent, second: scope.secondary, active: _last)),
      ));
    });
  }
}

class _GeqPainter extends CustomPainter {
  _GeqPainter({required this.gains, required this.spectrum, required this.curve, required this.y, required this.color,
    required this.second, required this.active});
  final List<double> gains;
  final List<double>? spectrum, curve;
  final double Function(double db) y;
  final Color color, second;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    for (final db in [-12.0, -6.0, 0.0, 6.0, 12.0]) {
      canvas.drawLine(Offset(0, y(db)), Offset(w, y(db)), Paint()..color = Neon.ink.withValues(alpha: db == 0 ? 0.12 : 0.04));
    }
    // The analyser behind (the output's spectrum while it plays).
    if (spectrum case final s? when s.isNotEmpty) {
      final p = Path()..moveTo(0, h);
      for (var j = 0; j < s.length; j++) {
        p.lineTo(w * (j + 0.5) / s.length, h - s[j] * (h - 24));
      }
      p
        ..lineTo(w, h)
        ..close();
      canvas.drawPath(p, Paint()..color = second.withValues(alpha: 0.1));
    }
    final bw = w / 31;
    for (var b = 0; b < 31; b++) {
      final g = gains[b].clamp(-18.0, 18.0);
      final r = Rect.fromLTRB(b * bw + 1.5, math.min(y(0), y(g)), (b + 1) * bw - 1.5, math.max(y(0), y(g)) + 1);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)),
        Paint()..color = (b == active ? second : color).withValues(alpha: b == active ? 0.9 : 0.55));
      if (b % 3 == 0 || b == 30) {
        final hz = geqCentres[b];
        paintLabel(canvas, hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)}k' : hz.toStringAsFixed(0),
          Offset((b + 0.5) * bw, h - 7), Neon.dim, size: 7, align: 0);
      }
    }
    // The engine's curve (the cascade's real response) over the bars while it plays.
    if (curve case final c?) {
      final p = Path();
      for (var j = 0; j < c.length; j++) {
        final x = w * (j + 0.5) / c.length, py = y(c[j].clamp(-18.0, 18.0));
        j == 0 ? p.moveTo(x, py) : p.lineTo(x, py);
      }
      strokeGlow(canvas, p, second, width: 1.8);
    }
  }

  @override
  bool shouldRepaint(covariant _GeqPainter o) =>
      paintInputsChanged([o.gains, o.spectrum, o.curve, o.y, o.color, o.second, o.active], [gains, spectrum, curve, y, color, second, active]);
}
