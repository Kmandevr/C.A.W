// The ladder filter's and the nonlinear filter's plugin UIs: their response drawn from the knobs, dragged for cutoff and resonance (or Q).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/hero.dart';
import '../../visuals/filter_curve.dart' show freqToX;
import '../effect_page.dart';
import 'filters_shared.dart';

double _y(double db, double h) => h * 0.55 - db / 36 * (h * 0.55 - 24);

/// The ladder: mode tiles and the slope, the response (drag: sideways the cutoff, up the resonance; past about
/// 0.91 it self-oscillates and says so), then cutoff, resonance, drive and mix; bias, bass comp and output in MORE.
class LadderPage extends StatelessWidget {
  const LadderPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final res = t.value('resonance');
    return effectPage('ladder', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('mode', height: 50, names: const ['LOW', 'BAND', 'HIGH'],
        icon: (canvas, r, i, c) => iconCurve(canvas, r.deflate(1), c, (x) {
          final hz = 1000 * math.pow(2, x * 4).toDouble();
          return ((toDb(ladderResponse(hz, cutoff: 1000, resonance: 0.6, mode: i, slope: 1).abs) + 6) / 20).clamp(-1.0, 1.0);
        }))),
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'LADDER ≈',
        grid: false,
        readout: Text('${formatParamValue(t.param('cutoff'), t.value('cutoff'))} Hz${res >= 0.91 ? '  ● SELF-OSC' : ''}'),
        child: DragHero(heroKey: 'ladder-hero', xParam: 'cutoff', yParam: 'resonance', paint: (canvas, size, active, f) {
          final mode = t.value('mode').round(), slope = t.value('slope').round();
          final cut = t.value('cutoff'), mix = t.value('mix'), comp = t.value('comp');
          double db(double hz) =>
              mixDb(ladderResponse(hz, cutoff: cut, resonance: math.min(res, 0.9), mode: mode, slope: slope, comp: comp), mix);
          final h = size.height;
          paintFrequencyGrid(canvas, size, _y(0, h));
          final path = responsePath(size, db, (d) => _y(d, h));
          fillFade(canvas, path, h, size, scope.accent, alpha: 0.3);
          strokeGlow(canvas, path, scope.accent, width: 2.4);
          final hx = freqToX(cut, size.width);
          paintHandle(canvas, Offset(hx, _y(db(cut), h).clamp(28.0, h - 16)), scope.accent, active: active, r: 8);
          if (res >= 0.91) {
            // Self-oscillation: a sine rings at the cutoff whatever comes in.
            final x = hx;
            for (var k = 1; k <= 3; k++) {
              canvas.drawCircle(Offset(x, _y(db(cut), h).clamp(28.0, h - 16)), 8.0 + k * 6, Paint()
                ..style = PaintingStyle.stroke
                ..color = scope.secondary.withValues(alpha: 0.35 / k));
            }
          }
          if (f != null) paintLabel(canvas, '● LIVE', Offset(size.width - 8, 30), scope.secondary, size: 8, align: 1, weight: FontWeight.w800);
        }),
      )),
      Row(children: [fieldLabel('SLOPE'), const DeviceChoice('slope')]),
      const SizedBox(height: 4),
      const KnobRow(['cutoff', 'resonance', 'drive', 'mix'], size: 54),
      const DeviceFold(child: ParamGrid(only: ['bias', 'comp', 'output'])),
    ]);
  }
}

/// The nonlinear filter's loop shapes (builtin_fx_filters.cpp's shapeOf), for the shape tiles.
double nlShape(int shape, double v) => switch (shape) {
  1 => _tanh(v),
  2 => v >= 0 ? _tanh(v) : 0.6 * _tanh(v / 0.6),
  3 => v.clamp(-1.0, 1.0),
  4 => math.sin(v.clamp(-6.0, 6.0)),
  5 => _tanh(v) + 0.35 * _tanh(v) * _tanh(v) - 0.35 * _tanh(v * v * 0.25),
  _ => v,
};
double _tanh(double x) {
  final e = math.exp(-2 * x.abs().clamp(0.0, 19.0));
  return (x < 0 ? -1 : 1) * (1 - e) / (1 + e);
}

/// The nonlinear filter: type tiles and shape tiles (each drawing its curve), the clean response (drag: sideways
/// the cutoff, up the Q), then cutoff, Q, drive and mix; output in MORE.
class NonlinearPage extends StatelessWidget {
  const NonlinearPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('nlfilter', [
      Padding(padding: const EdgeInsets.only(bottom: 6), child: ModeTiles('type', height: 46, names: const ['LP', 'BP', 'HP', 'NOTCH', 'AP'],
        icon: (canvas, r, i, c) => iconCurve(canvas, r.deflate(1), c, (x) {
          final hz = 1000 * math.pow(2, x * 4).toDouble();
          if (i == 4) return -x * 0.8;  // the all-pass: its phase turning
          return ((toDb(svfResponse(hz, cutoff: 1000, q: 2, type: i).abs) + 8) / 20).clamp(-1.0, 1.0);
        }))),
      HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: 'NONLINEAR ≈',
        grid: false,
        readout: Text('${formatParamValue(t.param('cutoff'), t.value('cutoff'))} Hz  Q ${t.value('q').toStringAsFixed(1)}'),
        child: DragHero(heroKey: 'nlfilter-hero', xParam: 'cutoff', yParam: 'q', paint: (canvas, size, active, f) {
          final type = t.value('type').round(), cut = t.value('cutoff'), q = t.value('q'), mix = t.value('mix');
          final shape = t.value('shape').round(), drive = t.value('drive');
          double db(double hz) => mixDb(svfResponse(hz, cutoff: cut, q: q, type: type), mix);
          final h = size.height;
          paintFrequencyGrid(canvas, size, _y(0, h));
          final path = responsePath(size, db, (d) => _y(d, h));
          fillFade(canvas, path, h, size, scope.accent, alpha: 0.3);
          // The drive bends the drawing: the louder the drive, the more the curve frays (the loop saturates).
          final fray = shape == 0 ? 0.0 : (drive / 36).clamp(0.0, 1.0);
          strokeGlow(canvas, path, Color.lerp(scope.accent, scope.secondary, fray)!, width: 2.4 + 2 * fray);
          final hx = freqToX(cut, size.width);
          paintHandle(canvas, Offset(hx, _y(db(cut), h).clamp(28.0, h - 16)), scope.accent, active: active, r: 8);
          if (shape != 0) {
            paintLabel(canvas, '${drive.toStringAsFixed(0)} dB INTO THE LOOP', Offset(10, h - 20), scope.secondary, size: 8,
              weight: FontWeight.w800);
          }
        }),
      )),
      Padding(padding: const EdgeInsets.only(bottom: 4), child: ModeTiles('shape', height: 46, color: scope.secondary,
        names: const ['CLEAN', 'WARM', 'DIODE', 'HARD', 'FOLD', 'RECT'],
        icon: (canvas, r, i, c) => iconCurve(canvas, r.deflate(2), c, (x) => nlShape(i, x * 3) * 0.9))),
      const KnobRow(['cutoff', 'q', 'drive', 'mix'], size: 54),
      const DeviceFold(child: ParamGrid(only: ['output'])),
    ]);
  }
}
