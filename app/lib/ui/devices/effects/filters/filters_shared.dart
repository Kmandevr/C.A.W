// The EQ & Filter group's shared pieces: the browser entries, the analog-prototype responses the heroes draw, and a draggable response hero.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../model/device_display.dart';
import '../../../../model/device_target.dart' show clampToParam;
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../visuals/filter_curve.dart' show freqToX, xToFreq;

/// One effect as the effect browser lists it: its category tab, a one-line description and an icon.
class FxBrowserEntry {
  const FxBrowserEntry(this.id, this.name, this.category, this.description, this.icon);
  final String id, name, category, description;
  final IconData icon;
}

/// The group's effects for the browser (category "EQ & Filter").
const filtersBrowserEntries = <FxBrowserEntry>[
  FxBrowserEntry('org.caw.ladder', 'Ladder filter', 'EQ & Filter',
      'A Moog-style 4-pole ladder: 12 or 24 dB, drive, and resonance up to self-oscillation.', Icons.stairs_outlined),
  FxBrowserEntry('org.caw.nlfilter', 'Nonlinear filter', 'EQ & Filter',
      'A resonant filter with the drive inside its loop: warm, diode, hard, fold or rectify.', Icons.waves_outlined),
  FxBrowserEntry('org.caw.comb', 'Comb filter', 'EQ & Filter',
      'Peaks at every harmonic of a note or frequency: metallic, hollow or flanged.', Icons.view_week_outlined),
  FxBrowserEntry('org.caw.resonator', 'Resonator', 'EQ & Filter',
      'A bank of tuned resonances (string, bell, chord or scale) that rings out of any sound.', Icons.music_note_outlined),
  FxBrowserEntry('org.caw.formant', 'Formant filter', 'EQ & Filter',
      'Vowels A, E, I, O, U on a pad: make anything talk.', Icons.record_voice_over_outlined),
  FxBrowserEntry('org.caw.disperser', 'Disperser', 'EQ & Filter',
      'A chain of all-passes that smears transients into a chirp: zaps, booms and wet basses.', Icons.blur_linear),
  FxBrowserEntry('org.caw.eq.dj', '3-band EQ', 'EQ & Filter',
      'A DJ EQ: low, mid and high with kill switches and movable crossovers.', Icons.tune),
  FxBrowserEntry('org.caw.tilt', 'Tilt EQ', 'EQ & Filter', 'One knob from darker to brighter around a pivot.',
      Icons.trending_up),
  FxBrowserEntry('org.caw.geq', 'Graphic EQ', 'EQ & Filter',
      '31 third-octave bands you draw with a finger, corrected so the curve is what you hear.', Icons.equalizer),
];

/// A complex number, enough for an analog prototype's response.
class Cx {
  const Cx(this.re, [this.im = 0]);
  final double re, im;
  Cx operator +(Cx o) => Cx(re + o.re, im + o.im);
  Cx operator -(Cx o) => Cx(re - o.re, im - o.im);
  Cx operator *(Cx o) => Cx(re * o.re - im * o.im, re * o.im + im * o.re);
  Cx operator /(Cx o) {
    final d = o.re * o.re + o.im * o.im;
    return d == 0 ? const Cx(0) : Cx((re * o.re + im * o.im) / d, (im * o.re - re * o.im) / d);
  }

  Cx scale(double k) => Cx(re * k, im * k);
  double get abs => math.sqrt(re * re + im * im);
}

const _rate = 48000.0;

/// s at [hz] for a filter at [cutoff], prewarped as the engine's bilinear (TPT) filters are.
Cx sAt(double hz, double cutoff) {
  final f = math.min(hz, 0.49 * _rate), c = math.min(cutoff, 0.49 * _rate);
  return Cx(0, math.tan(math.pi * f / _rate) / math.tan(math.pi * c / _rate));
}

double toDb(double magnitude) => 20 * math.log(math.max(1e-6, magnitude)) / math.ln10;

/// A wet path blended with the dry one ([mix] 0..1), in dB.
double mixDb(Cx wet, double mix) => toDb((wet.scale(mix) + Cx(1 - mix)).abs);

/// The ladder's small-signal response (org.caw.ladder): four one-poles H = 1 / (1 + s) in a loop with feedback
/// 4.4 x [resonance]; [mode] 0 low-pass, 1 band-pass, 2 high-pass; [slope] 0 is 12 dB, 1 is 24 dB.
Cx ladderResponse(double hz, {required double cutoff, required double resonance, required int mode, required int slope,
    double comp = 0.5}) {
  final s = sAt(hz, cutoff);
  final h = const Cx(1) / (const Cx(1) + s), g = const Cx(1) - h;
  final k = 4.4 * resonance.clamp(0.0, 1.0);
  final h2 = h * h, h4 = h2 * h2;
  final c = 1 + comp.clamp(0.0, 1.0) * k;
  final w = Cx(c) / (const Cx(1) + h4.scale(k));
  final g2 = g * g;
  return switch ((mode, slope)) {
    (0, 0) => w * h2,
    (0, _) => w * h4,
    (1, 0) => (w * h * g).scale(2 / c),
    (1, _) => (w * h2 * g2).scale(4 / c),
    (_, 0) => (w * g2).scale(1 / c),
    _ => (w * g2 * g2).scale(1 / c),
  };
}

/// A state-variable filter (org.caw.nlfilter clean): [type] 0 LP, 1 BP, 2 HP, 3 notch, 4 all-pass.
Cx svfResponse(double hz, {required double cutoff, required double q, required int type}) {
  final s = sAt(hz, cutoff), k = 1 / q;
  final d = s * s + s.scale(k) + const Cx(1);
  final n = switch (type) {
    1 => s.scale(k),
    2 => s * s,
    3 => s * s + const Cx(1),
    4 => s * s - s.scale(k) + const Cx(1),
    _ => const Cx(1),
  };
  return n / d;
}

/// The comb (org.caw.comb): (x + p d) / 2 with d = z x / (1 - p fb L z), z the delay of one period and L the
/// damping's one-pole, scaled down the engine's way.
Cx combResponse(double hz, {required double freq, required double feedback, required double damping, required bool minus}) {
  final w = 2 * math.pi * hz / _rate, period = _rate / freq;
  final z = Cx(math.cos(w * period), -math.sin(w * period));
  final a = 1 - 0.95 * damping;
  final l = Cx(a) / (const Cx(1) - Cx(math.cos(w), -math.sin(w)).scale(1 - a));
  final p = minus ? -1.0 : 1.0;
  final d = z / (const Cx(1) - (l * z).scale(p * feedback));
  final fb = feedback.abs().clamp(0.0, 0.99);
  final norm = math.pow(0.5 * (2 - fb) / (1 - fb), -0.7).toDouble();
  return (const Cx(1) + d.scale(p)).scale(0.5 * norm);
}

/// The tilt (eq.hpp's Tilt band): a high shelf at [freq] with half the tilt taken off the whole band.
Cx tiltResponse(double hz, {required double tilt, required double freq, required double q}) {
  final a = math.pow(10, tilt / 40).toDouble(), rootA = math.pow(10, tilt / 80).toDouble(), k = 1 / q;
  final s = sAt(hz, freq).scale(1 / rootA);
  final d = s * s + s.scale(k) + const Cx(1);
  final n = d.scale(a * a) + s.scale(k * (1 - a) * a) + Cx(1 - a * a);
  return (n / d).scale(1 / a);
}

/// The 3-band EQ's bands (org.caw.eq.dj): Linkwitz-Riley 4th-order splits at [low] and [high], the low band through
/// the high split's all-pass; their sum with all gains 1 is an all-pass.
List<Cx> eq3Bands(double hz, {required double low, required double high}) {
  Cx lp(Cx s) => const Cx(1) / (s * s + s.scale(math.sqrt2) + const Cx(1));
  Cx hp(Cx s) => (s * s) / (s * s + s.scale(math.sqrt2) + const Cx(1));
  final s1 = sAt(hz, low), s2 = sAt(hz, high);
  final ap2 = (s2 * s2 - s2.scale(math.sqrt2) + const Cx(1)) / (s2 * s2 + s2.scale(math.sqrt2) + const Cx(1));
  final lp1 = lp(s1) * lp(s1), hp1 = hp(s1) * hp(s1), lp2 = lp(s2) * lp(s2), hp2 = hp(s2) * hp(s2);
  return [lp1 * ap2, hp1 * lp2, hp1 * hp2];
}

/// The disperser's group delay in ms (org.caw.disperser): [stages] second-order all-passes at [freq] with Q [q].
double disperserDelayMs(double hz, {required double stages, required double freq, required double q}) {
  final w = hz / freq, k = 1 / q;
  final den = (1 - w * w) * (1 - w * w) + k * k * w * w;
  final tau = 2 * k * (1 + w * w) / den / (2 * math.pi * freq);  // seconds, per stage
  return stages * tau * 1000;
}

/// Draws a response hero's frame: the 100 / 1k / 10k lines and the 0 dB line.
void paintFrequencyGrid(Canvas canvas, Size size, double zeroY) {
  final w = size.width, h = size.height;
  final grid = Paint()..color = Neon.ink.withValues(alpha: 0.05);
  for (final (hz, l) in [(100.0, '100'), (1000.0, '1k'), (10000.0, '10k')]) {
    canvas.drawLine(Offset(freqToX(hz, w), 0), Offset(freqToX(hz, w), h), grid);
    paintLabel(canvas, l, Offset(freqToX(hz, w) + 3, h - 7), Neon.dim, size: 8);
  }
  canvas.drawLine(Offset(0, zeroY), Offset(w, zeroY), Paint()..color = Neon.ink.withValues(alpha: 0.1));
}

/// The path of y = [db](hz) across the width, [y] mapping dB to pixels.
Path responsePath(Size size, double Function(double hz) db, double Function(double db) y, {int steps = 160,
    double lo = -80, double hi = 40}) {
  final p = Path();
  for (var i = 0; i <= steps; i++) {
    final x = size.width * i / steps;
    final py = y(db(xToFreq(x, size.width)).clamp(lo, hi)).clamp(-4.0, size.height + 4);
    i == 0 ? p.moveTo(x, py) : p.lineTo(x, py);
  }
  return p;
}

/// What a hero draws: the canvas, its size, whether a finger is on it, and the newest display frame.
typedef HeroPaint = void Function(Canvas canvas, Size size, bool active, DeviceDisplayFrame? frame);

/// A hero edited by dragging anywhere: sideways moves [xParam] along the log-frequency axis (through [toHz] and
/// [fromHz] when it is not in Hz: a note), up and down moves [yParam] along its knob travel ([yDown] reverses it);
/// a second finger is fine; double-tap resets both.
class DragHero extends StatefulWidget {
  const DragHero({super.key, required this.heroKey, required this.xParam, this.yParam, required this.paint,
    this.toHz, this.fromHz, this.yDown = false, this.ySpan = 0.8});
  final String heroKey, xParam;
  final String? yParam;
  final HeroPaint paint;
  final double Function(double value)? toHz, fromHz;
  final bool yDown;

  /// The share of the hero's height a drag crosses for the y parameter's whole travel.
  final double ySpan;

  @override
  State<DragHero> createState() => _DragHeroState();
}

class _DragHeroState extends State<DragHero> {
  bool _active = false;
  double _x = 0, _y = 0;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final px = t.param(widget.xParam), py = widget.yParam == null ? null : t.param(widget.yParam!);
    double hzOf(double v) => widget.toHz?.call(v) ?? v;
    double valueOf(double hz) => widget.fromHz?.call(hz) ?? hz;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: ValueKey(widget.heroKey),
        onStart: (_, _) {
          if (px != null) _x = freqToX(hzOf(t.value(px.id)), w);
          if (py != null) _y = taperOf(py).position(t.value(py.id));
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          if (px != null) {
            _x = (_x + u.delta.dx * fine).clamp(0.0, w);
            t.setLive(px.id, clampToParam(px, valueOf(xToFreq(_x, w))));
          }
          if (py != null) {
            final dy = (widget.yDown ? u.delta.dy : -u.delta.dy) / (h * widget.ySpan) * fine;
            _y = (_y + dy).clamp(0.0, 1.0);
            t.setLive(py.id, taperOf(py).value(_y));
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final p in [?px, ?py]) p.id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _HeroPainter(widget.paint, _active, f)),
      ));
    });
  }
}

class _HeroPainter extends CustomPainter {
  _HeroPainter(this.draw, this.active, this.frame);
  final HeroPaint draw;
  final bool active;
  final DeviceDisplayFrame? frame;

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size, active, frame);

  @override
  bool shouldRepaint(covariant _HeroPainter o) =>
      paintInputsChanged([o.draw, o.active, o.frame], [draw, active, frame]);
}

/// A row label for a group of controls ("SLOPE", "MODE").
Widget fieldLabel(String text) => Padding(padding: const EdgeInsets.only(right: 8), child: Text(text,
    style: const TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)));

/// A MIDI note's name ("A3").
String noteName(double note) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  final n = note.round();
  return '${names[n % 12]}${n ~/ 12 - 1}';
}

double noteToHz(double note) => 440 * math.pow(2, (note - 69) / 12).toDouble();
double hzToNote(double hz) => 69 + 12 * math.log(hz / 440) / math.ln2;
