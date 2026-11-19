// Pitch/Shift's 1.1.0 modes (variants 2 and 3): Harmonizer (a keyboard with the scale lit, the sung note and each voice's note; the voices' intervals by scale degree) and Octaver (the tracked note's partials with the sub an octave under and the octave up over them).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../kit/repaint.dart';
import '../dyn_drive/common.dart' show ChoiceChips, chipWrap, clampParam;
import '../effect_page.dart';
import '../modes_kit.dart' show ChoicePill;
import 'space_devices.dart' show mergedPage, smallLabel, controlsRow;

/// The Harmonizer's scales, as the engine's (builtin_fx_shift_voices.cpp): each one's pitch classes from its key.
const harmonizerScales = <List<int>>[
  [0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10], [0, 2, 3, 5, 7, 8, 11], [0, 2, 3, 5, 7, 9, 11],
  [0, 2, 3, 5, 7, 9, 10], [0, 1, 3, 5, 7, 8, 10], [0, 2, 4, 6, 7, 9, 11], [0, 2, 4, 5, 7, 9, 10],
  [0, 2, 4, 7, 9], [0, 3, 5, 7, 10], [0, 3, 5, 6, 7, 10], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
];

/// The note [degree] scale steps from the scale note nearest [midi] (key [key], scale [scale]), as the Harmonizer
/// aims a voice.
int harmonyNote(double midi, int key, int scale, int degree) {
  final steps = harmonizerScales[scale.clamp(0, harmonizerScales.length - 1)];
  final n = steps.length;
  // The scale's notes as one index line: index i is octave i ~/ n, step i % n.
  int noteAt(int i) => key + 12 * (i / n).floor() + steps[i % n];
  final base = ((midi - key) / 12).floor() * n;
  var best = base, bestD = double.infinity;
  for (var i = base - n; i <= base + 2 * n; i++) {
    final d = (noteAt(i) - midi).abs();
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return noteAt(best + degree);
}

const _noteNames = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];

String noteName(int midi) => '${_noteNames[midi % 12]}${midi ~/ 12 - 1}';

/// The voices' colours: the accent, then the family's other neons.
List<Color> voiceColors(Color accent) => [accent, Neon.yellow, Neon.blue, Neon.green];

/// The Harmonizer: a keyboard (two and a half octaves round the sung note) with the scale lit, the sung note and each
/// voice's note on it; under it each voice's interval on a scale-degree ruler (drag a voice's handle sideways, a
/// detent each degree; double-tap: its default). Then key and scale, the voices' levels and Mix; formant, detune,
/// glide and the pans under MORE.
class HarmonizerPage extends StatelessWidget {
  const HarmonizerPage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final voices = t.value('voices').round().clamp(1, 4);
    return mergedPage(context, 'shift',
      cards: cards,
      hero: HeroCanvas(
        color: scope.accent,
        height: 230,
        caption: 'VOICES',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final live = f?.raw != null && f!.raw!.length >= 18 && f.at(2) > 0.5;
          return Text(live ? '${noteName(f.at(4).round())} · ${f.at(3).toStringAsFixed(0)} Hz' : 'sing or play: ≈ C4');
        }),
        child: const _HarmonyHero(),
      ),
      rows: [
        controlsRow([smallLabel('KEY'), const ChoicePill('key'), smallLabel('SCALE'), const ChoicePill('scale'),
          smallLabel('VOICES'), const _VoiceCount()]),
      ],
      knobs: KnobRow([for (var v = 1; v <= voices; v++) 'v${v}_level', 'mix'], size: 48,
          labels: {for (var v = 1; v <= voices; v++) 'v${v}_level': 'Voice $v'}),
      more: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const KnobRow(['formant', 'detune', 'glide', 'output'], size: 42),
        KnobRow([for (var v = 1; v <= voices; v++) 'v${v}_pan'], size: 40,
            labels: {for (var v = 1; v <= voices; v++) 'v${v}_pan': 'Pan $v'}),
      ]),
    );
  }
}

/// The voice count as four small pills (1..4).
class _VoiceCount extends StatelessWidget {
  const _VoiceCount();

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final n = t.value('voices').round();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var k = 1; k <= 4; k++)
        GestureDetector(
          key: ValueKey('voices-$k'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            DeviceFeel.tap();
            t.set('voices', k.toDouble());
          },
          child: Container(
            width: 30, height: 30,
            margin: const EdgeInsets.only(right: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle,
                color: k <= n ? voiceColors(scope.accent)[k - 1].withValues(alpha: 0.22) : Neon.ink.withValues(alpha: 0.03),
                border: Border.all(color: k <= n ? voiceColors(scope.accent)[k - 1] : Neon.line)),
            child: Text('$k', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: k <= n ? Neon.text : Neon.dim)),
          ),
        ),
    ]);
  }
}

class _HarmonyHero extends StatefulWidget {
  const _HarmonyHero();

  @override
  State<_HarmonyHero> createState() => _HarmonyHeroState();
}

class _HarmonyHeroState extends State<_HarmonyHero> {
  int? _voice;
  double _at = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final voices = t.value('voices').round().clamp(1, 4);
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final lanes = HarmonyPainter.lanes(size, voices);
      return GrabGesture(
        key: const ValueKey('harmonizer-hero'),
        grabs: (p) => p.dy >= lanes.first.top - 6,
        onStart: (p, _) {
          var v = 0;
          for (var k = 0; k < voices; k++) {
            if (p.dy >= lanes[k].top - 4) v = k;
          }
          _voice = v + 1;
          _at = t.value('v${v + 1}_degree');
          DeviceFeel.grab();
          setState(() {});
        },
        onUpdate: (u) {
          final id = 'v${_voice}_degree';
          _at = clampParam(scope, id, _at + u.delta.dx / (size.width - 24) * 28 * DeviceFingers.fine);
          final whole = _at.roundToDouble();
          if (whole != t.value(id)) DeviceFeel.detent();
          t.setLive(id, whole);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _voice = null);
        },
        onDoubleTap: (p) {
          for (var k = voices - 1; k >= 0; k--) {
            if (p.dy >= lanes[k].top - 4) {
              final id = 'v${k + 1}_degree';
              t.set(id, t.param(id)?.defaultValue ?? 0);
              return;
            }
          }
        },
        child: DeviceDisplay(builder: (context, f) {
          final live = f?.raw != null && f!.raw!.length >= 18 && f.at(2) > 0.5;
          return CustomPaint(size: size, painter: HarmonyPainter(
            key: t.value('key').round(),
            scale: t.value('scale').round(),
            degrees: [for (var v = 1; v <= voices; v++) t.value('v${v}_degree').round()],
            levels: [for (var v = 1; v <= voices; v++) t.value('v${v}_level')],
            input: live ? f.at(4) : null,
            targets: live ? [for (var v = 0; v < voices; v++) f.at(12 + v)] : null,
            colors: voiceColors(scope.accent),
            active: _voice));
        }),
      );
    });
  }
}

/// The Harmonizer's picture: a keyboard round the sung note ([input], MIDI; none: C4 ≈) with [key]'s [scale] lit,
/// the sung note in white and each voice's note (the engine's [targets], else worked out from [degrees]) in its
/// colour; under it a lane per voice, its interval as a handle on a −14..14 scale-degree ruler.
class HarmonyPainter extends CustomPainter {
  HarmonyPainter({required this.key, required this.scale, required this.degrees, required this.levels, required this.input,
    required this.targets, required this.colors, required this.active});
  final int key, scale;
  final List<int> degrees;
  final List<double> levels;
  final double? input;
  final List<double>? targets;
  final List<Color> colors;
  final int? active;

  /// Each voice's lane under the keyboard.
  static List<Rect> lanes(Size size, int voices) {
    final top = size.height * 0.5;
    final h = (size.height - top - 6) / voices;
    return [for (var v = 0; v < voices; v++) Rect.fromLTWH(12, top + h * v, size.width - 24, h)];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final kb = Rect.fromLTRB(12, 24, w - 12, size.height * 0.5 - 8);
    final sung = input ?? 60.0;
    final notes = [for (var v = 0; v < degrees.length; v++)
      if (targets != null && targets![v] >= 0) targets![v].round() else harmonyNote(sung, key, scale, degrees[v])];
    // Two and a half octaves, from the C under the lowest note shown.
    final lowest = [sung.round(), ...notes].reduce(math.min);
    final from = ((lowest - 2) ~/ 12) * 12;
    const span = 30;
    final whites = [for (var m = from; m < from + span; m++) if (!_black(m)) m];
    final ww = kb.width / whites.length;
    final steps = harmonizerScales[scale.clamp(0, harmonizerScales.length - 1)];
    bool inScale(int m) => steps.contains(((m - key) % 12 + 12) % 12);
    Rect keyRect(int m) {
      if (!_black(m)) {
        final i = whites.indexOf(m);
        return Rect.fromLTWH(kb.left + i * ww, kb.top, ww, kb.height);
      }
      final i = whites.indexOf(m - 1);
      return Rect.fromLTWH(kb.left + (i + 1) * ww - ww * 0.32, kb.top, ww * 0.64, kb.height * 0.6);
    }
    Color? mark(int m) {
      for (var v = notes.length - 1; v >= 0; v--) {
        if (notes[v] == m) return colors[v % colors.length];
      }
      return null;
    }
    for (final black in [false, true]) {
      for (var m = from; m < from + span; m++) {
        if (_black(m) != black) continue;
        final r = keyRect(m).deflate(0.8);
        final lit = mark(m);
        final base = black ? Color.lerp(Neon.bg, Neon.ink, 0.15)! : Color.lerp(Neon.bg, Neon.ink, 0.72)!;
        canvas.drawRRect(RRect.fromRectAndCorners(r, bottomLeft: const Radius.circular(3), bottomRight: const Radius.circular(3)),
            Paint()..color = lit != null ? Color.lerp(base, lit, 0.85)! : base);
        if (inScale(m) && lit == null) {
          canvas.drawCircle(Offset(r.center.dx, r.bottom - 6), 2.2, Paint()..color = colors.first.withValues(alpha: 0.7));
        }
        if (m % 12 == 0 && !black) paintLabel(canvas, 'C${m ~/ 12 - 1}', Offset(r.center.dx, r.bottom - 15), Neon.bg, size: 7, align: 0);
      }
    }
    // The sung note: a white line over its key (bends and vibrato move it between keys).
    final sx = _xOf(sung, keyRect, from, span);
    canvas.drawLine(Offset(sx, kb.top - 4), Offset(sx, kb.bottom + 3), Paint()
      ..color = Neon.text.withValues(alpha: input == null ? 0.35 : 0.9)
      ..strokeWidth = 2);
    // The lanes: −14..14 degrees, the octaves (every scale length) marked.
    final ls = lanes(size, degrees.length);
    final n = steps.length;
    for (var v = 0; v < degrees.length; v++) {
      final r = ls[v];
      final c = colors[v % colors.length];
      final y = r.center.dy;
      double dx(double d) => r.left + 16 + (d + 14) / 28 * (r.width - 22);
      canvas.drawLine(Offset(dx(-14), y), Offset(dx(14), y), Paint()..color = Neon.ink.withAlpha(0x22));
      for (var d = -14; d <= 14; d++) {
        final major = d % n == 0;
        final len = major ? 8.0 : 3.0;
        canvas.drawLine(Offset(dx(d.toDouble()), y - len / 2), Offset(dx(d.toDouble()), y + len / 2),
            Paint()..color = (major ? Neon.text : Neon.dim).withValues(alpha: major ? 0.5 : 0.3));
      }
      final d = degrees[v].toDouble().clamp(-14.0, 14.0);
      strokeGlow(canvas, Path()..moveTo(dx(0), y)..lineTo(dx(d), y), c.withValues(alpha: 0.4 + 0.6 * levels[v]), width: 3, glow: false);
      paintLabel(canvas, '${v + 1}', Offset(r.left + 4, y), c, size: 8, weight: FontWeight.w800);
      final hr = math.min(7.0, r.height / 2 - 2);
      paintHandle(canvas, Offset(dx(d), y), c, active: active == v + 1, r: hr);
      final name = '${degrees[v] >= 0 ? '+' : ''}${degrees[v]} · ${noteName(notes[v])}';
      final right = d < 0 || dx(d) > r.right - 70;
      paintLabel(canvas, name, Offset(dx(d) + (right ? -12 : 12), y), Neon.text.withValues(alpha: 0.85), size: 8,
          align: right ? 1 : -1);
    }
  }

  static bool _black(int m) => const [1, 3, 6, 8, 10].contains(m % 12);

  static double _xOf(double midi, Rect Function(int) keyRect, int from, int span) {
    final m = midi.clamp(from.toDouble(), (from + span - 1).toDouble());
    final lo = m.floor(), frac = m - lo;
    final a = keyRect(lo).center.dx, b = keyRect(math.min(lo + 1, from + span - 1)).center.dx;
    return a + (b - a) * frac;
  }

  @override
  bool shouldRepaint(covariant HarmonyPainter o) => paintInputsChanged(
      [o.key, o.scale, ...o.degrees, ...o.levels, o.input, ...?o.targets, ...o.colors, o.active, o.degrees.length],
      [key, scale, ...degrees, ...levels, input, ...?targets, ...colors, active, degrees.length]);
}

/// The Octaver: the tracked note's partials (grey, by Dry), the sub an octave under (in the accent, by Sub) and
/// the octave up over them (yellow, by Up); drag up and down on the left half for the sub's level, on the right
/// half for the octave up's. Tracking and range as chips, Sub, Up and Dry as knobs; the sub's tone and the output
/// under MORE.
class OctaverPage extends StatelessWidget {
  const OctaverPage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return mergedPage(context, 'shift',
      cards: cards,
      hero: HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'OCTAVES',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final live = f?.raw != null && f!.raw!.length >= 8;
          if (!live || f.at(3) <= 0) return Text(live ? 'tracking…' : '≈ A2');
          const modes = ['AUTO', 'MONO', 'POLY'];
          final mode = f.at(2).round().clamp(0, 2);
          final share = mode == 0 ? ' ${(f.at(5) * 100).round()}% mono' : '';
          return Text('${f.at(3).toStringAsFixed(0)} Hz · ${modes[mode]}$share');
        }),
        child: const _OctaveHero(),
      )),
      rows: [chipWrap([const ChoiceChips('tracking', title: 'TRACKING'), const ChoiceChips('range', title: 'RANGE')])],
      knobs: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        DeviceKnob('sub', size: 64, label: 'Sub', color: scope.accent),
        const DeviceKnob('up', size: 54, label: 'Up', color: Neon.yellow),
        const DeviceKnob('dry', size: 46, label: 'Dry'),
      ]),
      more: const KnobRow(['tone', 'output'], size: 42),
    );
  }
}

class _OctaveHero extends StatefulWidget {
  const _OctaveHero();

  @override
  State<_OctaveHero> createState() => _OctaveHeroState();
}

class _OctaveHeroState extends State<_OctaveHero> {
  String? _param;
  double _at = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return GrabGesture(
        key: const ValueKey('octaver-hero'),
        onStart: (p, _) {
          _param = p.dx < size.width / 2 ? 'sub' : 'up';
          _at = t.value(_param!);
          DeviceFeel.grab();
          setState(() {});
        },
        onUpdate: (u) {
          _at = clampParam(scope, _param!, _at - u.delta.dy / (size.height - 40) * DeviceFingers.fine);
          t.setLive(_param!, _at);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _param = null);
        },
        onDoubleTap: (p) {
          final id = p.dx < size.width / 2 ? 'sub' : 'up';
          t.set(id, t.param(id)?.defaultValue ?? 0);
        },
        child: DeviceDisplay(builder: (context, f) {
          final live = f?.raw != null && f!.raw!.length >= 8 && f.at(3) > 0;
          return CustomPaint(size: size, painter: OctavePainter(
            hz: live ? f.at(3) : 110,
            sub: t.value('sub'),
            up: t.value('up'),
            dry: t.value('dry'),
            tone: t.value('tone'),
            subDb: live ? f.at(6) : null,
            upDb: live ? f.at(7) : null,
            color: scope.accent,
            second: Neon.yellow,
            active: _param));
        }),
      );
    });
  }
}

/// A note at [hz] on a log axis (25 Hz .. 4 kHz): its partials in grey by [dry], the sub an octave under (each
/// partial's half, the sub's [tone] low-pass rolling them off) by [sub], the octave up (the even partials, doubled)
/// by [up]; the levels the engine measured ([subDb], [upDb]) as ticks on each side's bar.
class OctavePainter extends CustomPainter {
  OctavePainter({required this.hz, required this.sub, required this.up, required this.dry, required this.tone,
    required this.subDb, required this.upDb, required this.color, required this.second, required this.active});
  final double hz, sub, up, dry, tone;
  final double? subDb, upDb;
  final Color color, second;
  final String? active;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const x0 = 34.0;
    final x1 = w - 34, top = 26.0, base = h - 20;
    double x(double f) => x0 + (math.log(f.clamp(25.0, 4000.0) / 25) / math.log(160)) * (x1 - x0);
    for (final (f, l) in [(50.0, '50'), (100.0, '100'), (500.0, '500'), (1000.0, '1k')]) {
      canvas.drawLine(Offset(x(f), top), Offset(x(f), base), Paint()..color = Neon.ink.withValues(alpha: 0.05));
      paintLabel(canvas, l, Offset(x(f) + 3, top + 2), Neon.dim, size: 8);
    }
    final hh = base - top - 14;
    void bar(double f, double level, Color c, {double dx = 0, bool glow = false}) {
      if (f < 25 || f > 4000 || level <= 0.001) return;
      strokeGlow(canvas, Path()..moveTo(x(f) + dx, base)..lineTo(x(f) + dx, base - hh * level.clamp(0.0, 1.0)), c,
          width: 2.2, glow: glow);
    }
    for (var k = 1; k <= 10; k++) {
      bar(hz * k, dry / math.sqrt(k), Neon.dim.withValues(alpha: 0.5));
    }
    for (var k = 1; k <= 10; k++) {
      final f = hz * (k - 0.5);
      final roll = 1 / math.sqrt(1 + math.pow(f / tone, 4));
      bar(f, sub * roll / math.sqrt(k), color, glow: k == 1);
    }
    for (var k = 1; k <= 5; k++) {
      bar(hz * 2 * k, up / math.sqrt(k), second, dx: 2.5, glow: k == 1);
    }
    canvas.drawLine(Offset(x0, base), Offset(x1, base), Paint()..color = Neon.ink.withAlpha(0x26));
    // Each side's level bar: the sub on the left, the octave up on the right.
    void side(double left, double level, double? db, Color c, String label, bool on) {
      final r = Rect.fromLTWH(left, top, 10, base - top);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(5)), Paint()..color = Neon.ink.withValues(alpha: 0.05));
      final fill = Rect.fromLTRB(r.left, r.bottom - r.height * level, r.right, r.bottom);
      canvas.drawRRect(RRect.fromRectAndRadius(fill, const Radius.circular(5)),
          Paint()..color = c.withValues(alpha: on ? 0.9 : 0.6));
      if (db != null) {
        final y = r.bottom - r.height * dbUnit(db);
        canvas.drawLine(Offset(r.left - 2, y), Offset(r.right + 2, y), Paint()
          ..color = Neon.text
          ..strokeWidth = 1.4);
      }
      paintLabel(canvas, label, Offset(r.center.dx, base + 10), c, size: 7, align: 0, weight: FontWeight.w800);
    }
    side(10, sub, subDb, color, 'SUB', active == 'sub');
    side(w - 20, up, upDb, second, 'UP', active == 'up');
  }

  @override
  bool shouldRepaint(covariant OctavePainter o) => paintInputsChanged(
      [o.hz, o.sub, o.up, o.dry, o.tone, o.subDb, o.upDb, o.color, o.second, o.active],
      [hz, sub, up, dry, tone, subDb, upDb, color, second, active]);
}
