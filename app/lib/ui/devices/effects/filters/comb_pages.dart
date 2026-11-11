// The comb filter's and the resonator's plugin UIs: the comb's teeth (drag for pitch and feedback) and the resonator's ringing partials (drag for note and decay).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/hero.dart';
import '../../visuals/filter_curve.dart' show freqToX;
import '../effect_page.dart';
import 'filters_shared.dart';

double _combY(double db, double h) => h * 0.5 - db / 30 * (h * 0.5 - 24);

/// The comb: how it's tuned (Hz or a note), polarity and stereo, the teeth of its response (drag: sideways the
/// pitch, up the feedback; below the middle line is negative feedback), then pitch, feedback, damping and mix.
class CombFilterPage extends StatelessWidget {
  const CombFilterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final byNote = t.value('tune') >= 0.5;
    final hz = byNote ? noteToHz(t.value('note') + t.value('fine') / 100) : t.value('freq') * math.pow(2, t.value('fine') / 1200);
    return effectPage('comb', [
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'COMB ≈',
        grid: false,
        readout: Text(byNote ? '${noteName(t.value('note'))} · ${hz.toStringAsFixed(1)} Hz' : '${hz.toStringAsFixed(1)} Hz'),
        child: DragHero(
          heroKey: 'comb-hero',
          xParam: byNote ? 'note' : 'freq',
          yParam: 'feedback',
          toHz: byNote ? noteToHz : null,
          fromHz: byNote ? (f) => hzToNote(f).roundToDouble() : null,
          paint: (canvas, size, active, f) {
            final fb = t.value('feedback'), damping = t.value('damping'), mix = t.value('mix');
            final minus = t.value('polarity') >= 0.5;
            double db(double x) => mixDb(combResponse(x, freq: hz, feedback: fb, damping: damping, minus: minus), mix);
            final h = size.height;
            paintFrequencyGrid(canvas, size, _combY(0, h));
            final path = responsePath(size, db, (d) => _combY(d, h), steps: 480);
            fillFade(canvas, path, h, size, scope.accent, alpha: 0.25);
            strokeGlow(canvas, path, scope.accent, width: 1.8);
            // The fundamental's tooth carries the handle; the feedback's sign shows as a label.
            final hx = freqToX(fb < 0 ? hz / 2 : hz, size.width);
            final hy = h * 0.5 - fb * (h * 0.5 - 24);
            canvas.drawLine(Offset(hx, 22), Offset(hx, h), Paint()..color = scope.secondary.withValues(alpha: 0.3));
            paintHandle(canvas, Offset(hx, hy), scope.accent, active: active, r: 8);
            paintLabel(canvas, fb < 0 ? '− FEEDBACK: ODD HARMONICS' : '+ FEEDBACK', Offset(10, h - 20), scope.secondary,
              size: 8, weight: FontWeight.w800);
          }),
      )),
      Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [fieldLabel('TUNE'), const DeviceChoice('tune')]),
        Row(mainAxisSize: MainAxisSize.min, children: [fieldLabel('POLARITY'), const DeviceChoice('polarity', labels: ['+', '−'])]),
        Row(mainAxisSize: MainAxisSize.min, children: [fieldLabel('STEREO'), const DeviceChoice('stereo', labels: ['SAME', 'FLIP R'])]),
      ]),
      const SizedBox(height: 4),
      KnobRow([byNote ? 'note' : 'freq', 'feedback', 'damping', 'mix'], size: 54),
      const DeviceFold(child: ParamGrid(only: ['fine', 'spread', 'output'])),
    ]);
  }
}

/// One of the resonator's modes as the hero draws it.
typedef Partial = ({double hz, double level, double t60});

const _chords = [[0, 4, 7, 12], [0, 3, 7, 12], [0, 5, 7, 12], [0, 4, 7, 11], [0, 3, 7, 10], [0, 7, 12, 19], [0, 12, 24, 36]];
const _scales = [[0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10], [0, 2, 4, 7, 9], [0, 3, 5, 7, 10], [0, 2, 3, 5, 7, 9, 10],
  [0, 2, 3, 5, 7, 8, 11]];

double _barRatio(int n) {
  const xs = [4.730040744862704, 7.853204624095838, 10.995607838001671];
  final x = n < 3 ? xs[n] : (2 * (n + 1) + 1) * math.pi / 2;
  return (x / xs[0]) * (x / xs[0]);
}

/// The resonator's 16 modes as builtin_fx_filters_comb.cpp tunes them: frequency, level and T60.
List<Partial> resonatorPartials({required int mode, required int chord, required int scale, required double note,
    required double decay, required double brightness}) {
  final root = noteToHz(note);
  final out = <Partial>[];
  for (var j = 0; j < 16; j++) {
    var f = root * (j + 1);
    var rank = j + 1;
    switch (mode) {
      case 1:
        f = root * (2 * j + 1);
        rank = 2 * j + 1;
      case 2:
        f = root * _barRatio(j);
      case 3:
        f = root * math.pow(2, _chords[chord.clamp(0, 6)][j % 4] / 12) * (j ~/ 4 + 1);
        rank = j ~/ 4 + 1;
      case 4:
        final s = _scales[scale.clamp(0, 5)];
        f = root * math.pow(2, (12 * (j ~/ s.length) + s[j % s.length]) / 12);
        rank = 1;
    }
    if (f >= 0.45 * 48000 || f <= 10) continue;
    out.add((hz: f, level: math.pow(rank, -(1.4 - 1.2 * brightness)).toDouble(),
      t60: decay * math.pow(root / f, 0.9 * (1 - brightness))));
  }
  return out;
}

/// The resonator: mode tiles, then (for Chord and Scale) which one, the bank's partials as ringing lines (drag:
/// sideways the note, by semitones; up the decay), then note, decay, brightness, spread and mix.
class ResonatorPage extends StatelessWidget {
  const ResonatorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final mode = t.value('mode').round();
    return effectPage('resonator', [
      Padding(padding: const EdgeInsets.only(bottom: 6), child: ModeTiles('mode', height: 48,
        names: const ['STRING', 'ODD', 'BELL', 'CHORD', 'SCALE'],
        icon: (canvas, r, i, c) {
          final ps = resonatorPartials(mode: i, chord: 0, scale: 2, note: 36, decay: 1, brightness: 0.5);
          final paint = Paint()
            ..color = c
            ..strokeWidth = 1.6;
          for (final p in ps) {
            final x = r.left + freqToX(p.hz, r.width * 1.0) * 0.9 - r.width * 0.05;
            if (x < r.left || x > r.right) continue;
            canvas.drawLine(Offset(x, r.bottom), Offset(x, r.bottom - r.height * p.level.clamp(0.15, 1.0)), paint);
          }
        })),
      if (mode == 3 || mode == 4)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
          fieldLabel(mode == 3 ? 'CHORD' : 'SCALE'),
          Flexible(child: DeviceChoice(mode == 3 ? 'chord' : 'scale', maxSegments: 0)),
        ])),
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'RESONATOR ≈',
        grid: false,
        readout: Text('${noteName(t.value('note'))} · ${formatParamValue(t.param('decay'), t.value('decay'))}'),
        child: DragHero(
          heroKey: 'resonator-hero',
          xParam: 'note',
          yParam: 'decay',
          toHz: noteToHz,
          fromHz: (f) => hzToNote(f).roundToDouble(),
          paint: (canvas, size, active, f) {
            final w = size.width, h = size.height;
            paintFrequencyGrid(canvas, size, h - 1);
            final decay = t.value('decay'), spread = t.value('spread');
            final ps = resonatorPartials(mode: mode, chord: t.value('chord').round(), scale: t.value('scale').round(),
              note: t.value('note') + t.value('fine') / 100, decay: decay, brightness: t.value('brightness'));
            // Each mode a line, as tall as its level; its glow as long as it rings (the T60 against 10 s).
            for (var j = 0; j < ps.length; j++) {
              final p = ps[j];
              final x = freqToX(p.hz, w);
              final top = h - 14 - (h - 40) * math.pow(p.level, 0.6).toDouble();
              final ring = (math.log(1 + p.t60 * 4) / math.log(41)).clamp(0.08, 1.0);
              final side = j.isOdd ? scope.secondary : scope.accent;
              final c = Color.lerp(scope.accent, side, spread)!;
              canvas.drawLine(Offset(x, h - 14), Offset(x, top), Paint()
                ..color = c.withValues(alpha: 0.25 + 0.6 * ring)
                ..strokeWidth = 2 + 4 * ring
                ..strokeCap = StrokeCap.round);
            }
            if (ps.isNotEmpty) paintHandle(canvas, Offset(freqToX(ps.first.hz, w), 34), scope.accent, active: active, r: 8);
            final gr = f?.values['ceiling_db'] ?? 0;
            if (gr < -0.5) {
              paintLabel(canvas, 'CEILING ${gr.toStringAsFixed(1)} dB', Offset(w - 8, 30), Neon.yellow, size: 8, align: 1,
                weight: FontWeight.w800);
            }
          }),
      )),
      const KnobRow(['note', 'decay', 'brightness', 'spread', 'mix'], size: 50),
      const DeviceFold(child: ParamGrid(only: ['fine', 'output'])),
    ]);
  }
}
