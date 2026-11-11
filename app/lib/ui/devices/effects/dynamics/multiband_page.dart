// fx-dynamics: the Multiband dynamics UI (org.caw.multiband): three band columns with live level and gain meters, draggable crossovers and thresholds.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';

const _bandNames = ['LOW', 'MID', 'HIGH'];
// The OTT mode's thresholds, low to high (builtin_fx_dynamics.cpp's kOtt), drawn before live data comes.
const _ottDown = [-33.8, -30.2, -35.5], _ottUp = [-40.8, -41.8, -40.8];

/// Frequency 20 Hz..20 kHz as 0..1 across the hero (log).
double _fx(double hz) => (math.log(hz.clamp(20, 20000) / 20) / math.log(1000)).toDouble();
double _hz(double x) => 20 * math.pow(1000, x.clamp(0.0, 1.0)).toDouble();

/// Multiband dynamics: the Mode tiles (Multiband or OTT), then the three bands side by side on a frequency axis,
/// each with its level now (a fill from the bottom), its downward threshold (the family colour) and upward one (its
/// second colour), and its gain change (a bar from the middle: up lift, down cut). Drag a crossover line sideways
/// to move it; in Multiband mode drag inside a band up or down for the nearer threshold. Depth, time, upward and
/// downward amounts are the big knobs; each band's own settings are under BANDS.
class MultibandPage extends StatelessWidget {
  const MultibandPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final ott = scope.target.value('mode') >= 0.5;
    return effectPage('multiband', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('mode', height: 50, icon: (canvas, r, i, c) {
        // Multiband: three bumps; OTT: a squashed wave.
        if (i == 0) {
          iconCurve(canvas, r.deflate(3), c, (x) => 0.7 * math.sin((x + 1) * 1.5 * math.pi).abs() - 0.35);
        } else {
          iconCurve(canvas, r.deflate(3), c, (x) => (math.sin(x * 3 * math.pi) * 2).clamp(-0.6, 0.6));
        }
      })),
      HeroWithMeters(height: 220, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 220,
        caption: ott ? 'OTT' : 'MULTIBAND',
        grid: false,
        readout: const LevelReadout(),
        child: const _MultibandHero(),
      )),
      const KnobRow(['depth', 'time', 'upward', 'downward', 'in_gain', 'out_gain'], size: 48),
      DeviceFold(title: 'BANDS', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const KnobRow(['xover_low', 'xover_high'], size: 42),
        for (var b = 1; b <= 3; b++) ControlGroup(
          title: '${_bandNames[b - 1]} BAND${ott ? ' (OTT uses only the gain)' : ''}',
          color: spectrumColors()[b * 2],
          child: KnobRow([for (final k in ['down_thr', 'down_ratio', 'up_thr', 'up_ratio', 'gain', 'attack', 'release']) 'b${b}_$k'],
            size: 40, labels: {
              'b${b}_down_thr': 'Down thr', 'b${b}_down_ratio': 'Down', 'b${b}_up_thr': 'Up thr', 'b${b}_up_ratio': 'Up',
              'b${b}_gain': 'Gain', 'b${b}_attack': 'Attack', 'b${b}_release': 'Release',
            }),
        ),
      ])),
    ]);
  }
}

class _MultibandHero extends StatefulWidget {
  const _MultibandHero();

  @override
  State<_MultibandHero> createState() => _MultibandHeroState();
}

class _MultibandHeroState extends State<_MultibandHero> {
  String? _param; // the parameter being dragged
  double _v = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final ott = t.value('mode') >= 0.5;
    final x1 = _fx(t.value('xover_low')), x2 = _fx(t.value('xover_high'));
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final area = Rect.fromLTRB(6, 22, w - 6, h - 16);
      double yOf(double db) => area.bottom - dbUnit(db, floor: 72) * area.height;
      return DeviceDisplay(builder: (context, f) {
        double? val(String k) => f?.values[k];
        return GrabGesture(
          key: const ValueKey('mb-hero'),
          onStart: (p, _) {
            final px = (p.dx - area.left) / area.width;
            final near1 = (px - x1).abs() * area.width < 22, near2 = (px - x2).abs() * area.width < 22;
            if (near1 || near2) {
              _param = near1 && (!near2 || (px - x1).abs() < (px - x2).abs()) ? 'xover_low' : 'xover_high';
              _v = t.value(_param!);
            } else if (!ott) {
              final b = px < x1 ? 1 : (px < x2 ? 2 : 3);
              final down = yOf(t.value('b${b}_down_thr')), up = yOf(t.value('b${b}_up_thr'));
              _param = (p.dy - down).abs() <= (p.dy - up).abs() ? 'b${b}_down_thr' : 'b${b}_up_thr';
              _v = t.value(_param!);
            } else {
              _param = null;
            }
            setState(() {});
          },
          onUpdate: (u) {
            final id = _param;
            if (id == null) return;
            final fine = DeviceFingers.fine;
            if (id.startsWith('xover')) {
              _v = _hz(_fx(_v) + u.delta.dx / area.width * fine);
            } else {
              _v -= u.delta.dy / area.height * 72 * fine;
            }
            final p = t.param(id);
            if (p != null) t.setLive(id, _v.clamp(p.min, p.max).toDouble());
          },
          onEnd: () {
            t.commit();
            setState(() => _param = null);
          },
          onDoubleTap: (_) => t.setAll({
            for (final id in ['xover_low', 'xover_high']) if (t.param(id) case final p?) id: p.defaultValue,
          }),
          child: CustomPaint(size: Size(w, h), painter: _MultibandPainter(
            area: area, x1: x1, x2: x2, yOf: yOf, ott: ott,
            bands: [
              for (var b = 1; b <= 3; b++) (
                level: val('b${b}_level_db'), gain: val('b${b}_gr_db'),
                // In OTT mode the engine's table sets the thresholds: drawn from the live frame when there is one.
                down: ott ? val('b${b}_down_db') ?? _ottDown[b - 1] : t.value('b${b}_down_thr'),
                up: ott ? val('b${b}_up_db') ?? _ottUp[b - 1] : t.value('b${b}_up_thr'),
              ),
            ],
            color: scope.accent, second: scope.secondary, active: _param)),
        );
      });
    });
  }
}

typedef _Band = ({double? level, double? gain, double down, double up});

class _MultibandPainter extends CustomPainter {
  _MultibandPainter({required this.area, required this.x1, required this.x2, required this.yOf, required this.ott,
    required this.bands, required this.color, required this.second, required this.active});
  final Rect area;
  final double x1, x2;
  final double Function(double db) yOf;
  final bool ott;
  final List<_Band> bands;
  final Color color, second;
  final String? active;

  @override
  void paint(Canvas canvas, Size size) {
    final xs = [0.0, x1, x2, 1.0];
    final colors = spectrumColors();
    for (var b = 0; b < 3; b++) {
      final left = area.left + xs[b] * area.width, right = area.left + xs[b + 1] * area.width;
      final col = Rect.fromLTRB(left + 3, area.top, right - 3, area.bottom);
      final c = colors[(b + 1) * 2];
      canvas.drawRRect(RRect.fromRectAndRadius(col, const Radius.circular(6)), Paint()..color = c.withValues(alpha: 0.05));
      final band = bands[b];
      // Level now: a fill from the bottom.
      if (band.level case final l? when l > -72) {
        final top = yOf(l);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(col.left + 4, top, col.right - 4, col.bottom), const Radius.circular(4)),
          Paint()..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
            colors: Neon.ramp([c.withValues(alpha: 0.15), c.withValues(alpha: 0.55)])).createShader(col));
      }
      // Thresholds.
      for (final (db, tc, id) in [(band.down, color, 'b${b + 1}_down_thr'), (band.up, second, 'b${b + 1}_up_thr')]) {
        final y = yOf(db);
        strokeGlow(canvas, Path()
          ..moveTo(col.left, y)
          ..lineTo(col.right, y), tc, width: active == id ? 2.4 : 1.4, glow: active == id);
      }
      // Gain change: a bar from the middle (24 dB each way).
      if (band.gain case final g?) {
        final mid = col.center.dy, y = mid - (g / 24).clamp(-1.0, 1.0) * col.height / 2;
        canvas.drawLine(Offset(col.right - 8, mid), Offset(col.right - 8, y), Paint()
          ..color = g >= 0 ? color : Neon.pink
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round);
        paintLabel(canvas, '${g >= 0 ? '+' : ''}${g.toStringAsFixed(1)}', Offset(col.center.dx, col.top + 8), g >= 0 ? color : Neon.pink,
          size: 8, align: 0, weight: FontWeight.w700);
      }
      paintLabel(canvas, _bandNames[b], Offset(col.center.dx, area.bottom + 8), c, size: 8, align: 0, weight: FontWeight.w800);
    }
    for (final (x, id) in [(x1, 'xover_low'), (x2, 'xover_high')]) {
      final px = area.left + x * area.width;
      canvas.drawLine(Offset(px, area.top), Offset(px, area.bottom), Paint()
        ..color = Neon.ink.withValues(alpha: active == id ? 0.8 : 0.3)
        ..strokeWidth = active == id ? 2 : 1);
      paintHandle(canvas, Offset(px, area.bottom - 10), Neon.ink, active: active == id, r: 5);
      final hz = 20 * math.pow(1000, x);
      paintLabel(canvas, hz >= 1000 ? '${(hz / 1000).toStringAsFixed(1)}k' : hz.toStringAsFixed(0), Offset(px, area.bottom - 24),
        Neon.text, size: 8, align: 0, weight: FontWeight.w700);
    }
  }

  @override
  bool shouldRepaint(covariant _MultibandPainter o) => true;
}
