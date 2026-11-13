// The formant filter's plugin UI (vowels on an XY pad over the response they make) and the disperser's (its group delay, dragged for frequency and amount).
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/hero.dart';
import '../../visuals/filter_curve.dart' show freqToX;
import '../effect_page.dart';
import 'filters_shared.dart';

// The vowels' first three formants and where they sit on the pad (builtin_fx_filters_formant.cpp).
const _vowels = ['A', 'E', 'I', 'O', 'U'];
const _vowelHz = [[730.0, 1090.0, 2440.0], [530.0, 1840.0, 2480.0], [270.0, 2290.0, 3010.0], [570.0, 840.0, 2410.0],
  [300.0, 870.0, 2240.0]];
const _vowelXY = [[0.5, 0.85], [0.15, 0.55], [0.1, 0.1], [0.85, 0.55], [0.9, 0.1]];
const _formantLevel = [2.0, 1.4, 0.9];

/// The three formants at pad point ([x], [y]), shifted by [shift] semitones: inverse-distance weights, averaged
/// in log frequency, as the engine does.
List<double> formantsAt(double x, double y, double shift) {
  final w = <double>[];
  for (final p in _vowelXY) {
    final d2 = (x - p[0]) * (x - p[0]) + (y - p[1]) * (y - p[1]) + 1e-5;
    w.add(1 / (d2 * d2));
  }
  final total = w.reduce((a, b) => a + b);
  final s = math.pow(2, shift / 12).toDouble();
  return [
    for (var f = 0; f < 3; f++)
      math.exp([for (var v = 0; v < 5; v++) w[v] * math.log(_vowelHz[v][f])].reduce((a, b) => a + b) / total) * s,
  ];
}

/// The formant filter's response: three band-passes at the formants, and the dry lows and highs.
Cx formantResponse(double hz, List<double> formants, {required double q, required double lows, required double highs}) {
  var sum = const Cx(0);
  for (var f = 0; f < 3; f++) {
    sum = sum + svfResponse(hz, cutoff: formants[f], q: q, type: 1).scale(_formantLevel[f]);
  }
  sum = sum + svfResponse(hz, cutoff: formants[0] * 0.7, q: 0.707, type: 0).scale(lows);
  return sum + svfResponse(hz, cutoff: math.min(formants[2] * 1.4, 21600), q: 0.707, type: 2).scale(highs);
}

/// The formant filter: the vowel pad (drag the dot among A, E, I, O and U), the response the vowel makes (≈) with
/// its three formants marked, then shift, Q, lows, highs and mix.
class FormantPage extends StatelessWidget {
  const FormantPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    // Read where it is drawn (a lazy read: the hero and readout watch it, not the page; param_watch.dart).
    List<double> fs() => formantsAt(t.value('vowel_x'), t.value('vowel_y'), t.value('shift'));
    return effectPage('formant', [
      XYPad(key: const ValueKey('formant-pad'), xParam: 'vowel_x', yParam: 'vowel_y', height: 170, caption: 'VOWEL',
        painter: (dot) => _VowelPainter(dot, scope.accent, scope.secondary)),
      HeroCanvas(
        color: scope.secondary,
        height: 96,
        caption: 'FORMANTS ≈',
        grid: false,
        readout: Builder(builder: (context) => Text('${fs()[0].round()} · ${fs()[1].round()} · ${fs()[2].round()} Hz')),
        child: Builder(builder: (context) => CustomPaint(painter: _FormantCurvePainter(fs(), t.value('q'), t.value('lows'),
          t.value('highs'), t.value('mix'), scope.secondary), child: const SizedBox.expand())),
      ),
      const KnobRow(['shift', 'q', 'lows', 'highs', 'mix'], size: 50, labels: {'shift': 'Gender'}),
      const DeviceFold(child: ParamGrid(only: ['output'])),
    ]);
  }
}

class _VowelPainter extends CustomPainter {
  _VowelPainter(this.dot, this.color, this.second);
  final Offset dot;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    for (var v = 0; v < 5; v++) {
      final at = Offset(_vowelXY[v][0] * size.width, (1 - _vowelXY[v][1]) * size.height);
      final near = (at - dot).distance < 40;
      canvas.drawCircle(at, 15, Paint()..color = (near ? color : second).withValues(alpha: near ? 0.28 : 0.1));
      paintLabel(canvas, _vowels[v], at, near ? Neon.text : Neon.dim, size: 14, align: 0, weight: FontWeight.w900);
    }
  }

  @override
  bool shouldRepaint(covariant _VowelPainter o) => o.dot != dot || o.color != color;
}

class _FormantCurvePainter extends CustomPainter {
  _FormantCurvePainter(this.formants, this.q, this.lows, this.highs, this.mix, this.color);
  final List<double> formants;
  final double q, lows, highs, mix;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    double y(double db) => h * 0.62 - db / 30 * (h * 0.62 - 16);
    paintFrequencyGrid(canvas, size, y(0));
    final path = responsePath(size, (hz) => mixDb(formantResponse(hz, formants, q: q, lows: lows, highs: highs), mix), y);
    fillFade(canvas, path, h, size, color, alpha: 0.28);
    strokeGlow(canvas, path, color, width: 2);
    for (var f = 0; f < 3; f++) {
      final x = freqToX(formants[f], size.width);
      paintLabel(canvas, 'F${f + 1}', Offset(x, 22), color, size: 8, align: 0, weight: FontWeight.w800);
    }
  }

  @override
  bool shouldRepaint(covariant _FormantCurvePainter o) =>
      paintInputsChanged([o.formants, o.q, o.lows, o.highs, o.mix, o.color], [formants, q, lows, highs, mix, color]);
}

/// The disperser: its group delay over frequency (drag: sideways the frequency, up the amount; the right side's
/// curve shows the spread), then amount, frequency, pinch, spread and mix.
class DisperserPage extends StatelessWidget {
  const DisperserPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    // Read where it is drawn (a lazy read: the hero and readout watch it, not the page; param_watch.dart).
    double stages() => t.value('amount') * 64;
    return effectPage('disperser', [
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'DELAY ≈',
        grid: false,
        readout: Builder(builder: (context) => Text('${stages().toStringAsFixed(0)} stages')),
        child: DragHero(heroKey: 'disperser-hero', xParam: 'freq', yParam: 'amount', paint: (canvas, size, active, f) {
          final w = size.width, h = size.height;
          final freq = t.value('freq'), q = 0.3 * math.pow(30, t.value('pinch')).toDouble(), spread = t.value('spread');
          // The delay on a log scale: 0.1 ms at the bottom, 1 s at the top.
          double y(double ms) => h - 12 - (h - 36) * ((math.log(math.max(ms, 0.1)) / math.ln10 + 1) / 4).clamp(0.0, 1.0);
          paintFrequencyGrid(canvas, size, h - 12);
          for (final (ms, l) in [(1.0, '1 ms'), (10.0, '10 ms'), (100.0, '100 ms')]) {
            canvas.drawLine(Offset(0, y(ms)), Offset(w, y(ms)), Paint()..color = Neon.ink.withValues(alpha: 0.04));
            paintLabel(canvas, l, Offset(4, y(ms) - 6), Neon.dim, size: 8);
          }
          Path curve(double fc) => responsePath(size, (hz) => disperserDelayMs(hz, stages: stages(), freq: fc, q: q), y, lo: 0, hi: 1e4);
          if (spread > 0.01) strokeGlow(canvas, curve(math.min(freq * math.pow(2, spread), 21600)), scope.secondary, width: 1.6);
          final main = curve(freq);
          fillFade(canvas, main, h, size, scope.accent, alpha: 0.3);
          strokeGlow(canvas, main, scope.accent, width: 2.4);
          paintHandle(canvas, Offset(freqToX(freq, w), y(disperserDelayMs(freq, stages: stages(), freq: freq, q: q)).clamp(28.0, h - 16)),
            scope.accent, active: active, r: 8);
        }),
      )),
      const KnobRow(['amount', 'freq', 'pinch', 'spread', 'mix'], size: 50),
    ]);
  }
}
