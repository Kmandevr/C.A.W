// The Modulation merged devices' pages: Chorus/Flanger (its voices as moving dots in the stereo field), the Phaser (its notches sweeping) and Tremolo/Pan (the LFO shape with a stereo puck).
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import '../ducker_editor.dart' show DuckerPage, duckAt;
import '../mod_editors.dart' show CombHero, modRateHz;
import 'space_devices.dart';
import 'space_fx.dart' show liveHero;
import 'space_fx_mod.dart' show RotorPainter, lfoShape;

// ---------------------------------------------------------------------------------------------------------------
// Chorus/Flanger

/// One voice now: where it sits (−1 left .. 1 right), its delay now in ms, and its past [trail] delays (newest first).
typedef Voice = ({double pan, double ms, List<double> trail});

/// The voices of [variant] at [secs] (the engine's delays when it gives them, else ≈ from the knobs).
List<Voice> chorusVoices(DeviceScope scope, int variant, double secs, Map<String, double>? live) {
  final t = scope.target;
  double v(String id, double or) => t.param(id) == null ? or : t.value(id);
  final out = <Voice>[];
  void add(double pan, double Function(double s) ms, [double? now]) =>
      out.add((pan: pan, ms: now ?? ms(secs), trail: [for (var k = 1; k <= 6; k++) ms(secs - k * 0.06)]));
  switch (variant) {
    case 1: // Ensemble: up to 8 voices across the spread, phases spread
      final n = v('voices', 2).round() + 2, rate = v('rate', 0.6), base = v('delay', 12), depth = v('detune', 12) / 50 * 4;
      for (var k = 0; k < n; k++) {
        final place = n == 1 ? 0.0 : 2 * k / (n - 1) - 1;
        add(v('spread', 0.8) * place, (s) => base + depth * math.sin(2 * math.pi * (s * rate + k / n)), live?['voice$k']);
      }
    case 2: // Doubler: late, slightly drifting copies to the sides
      const pans = [-1.0, 1.0, -0.5, 0.5], times = [1.0, 1.37, 0.62, 1.81];
      final n = v('voices', 0) >= 0.5 ? 4 : 2, base = v('delay', 18), drift = v('drift', 0.4);
      for (var k = 0; k < n; k++) {
        add(pans[k] * v('width', 0.9), (s) => base * times[k] + 3 * drift * math.sin(s * (0.7 + 0.3 * k) + k), live?['double$k']);
      }
    case 3: // Flanger: two short delays swept, the right `stereo` half a cycle behind
      final rate = modRateHz(scope), base = v('delay', 2), depth = v('depth', 0.7), st = v('stereo', 0.5);
      for (final (k, pan) in [(0, -0.6), (1, 0.6)]) {
        add(pan, (s) => base * (1 + 0.95 * depth * math.sin(2 * math.pi * (s * rate - k * st * 0.5))),
            live?[k == 0 ? 'delay_l_ms' : 'delay_r_ms']);
      }
    case 4: // Vibrato: the wet only, its delay swept for pitch
      final rate = modRateHz(scope), st = v('stereo', 0), depthMs = live?['depth_ms'] ?? v('depth', 25) / 100 * 3;
      for (final (k, pan) in [(0, -0.35 - 0.4 * st), (1, 0.35 + 0.4 * st)]) {
        add(pan, (s) => 4 + depthMs * lfoShape(0, s * rate - k * st * 0.5));
      }
    default: // Chorus: two voices a quarter cycle apart
      final rate = v('rate', 0.6), depth = v('depth', 0.5);
      for (final (k, pan) in [(0, -0.7), (1, 0.7)]) {
        add(pan, (s) => 12 + 8 * depth * math.sin(2 * math.pi * (s * rate - k * 0.25)));
      }
  }
  return out;
}

/// The pad each Chorus/Flanger variant's hero drags: across, up.
const _chorusPads = <int, (String, String)>{
  0: ('rate', 'depth'), 1: ('spread', 'detune'), 2: ('width', 'detune'), 3: ('delay', 'feedback'), 4: ('rate', 'depth'),
};

/// Chorus/Flanger: its six variants as cards; its voices as dots moving in the stereo field (sideways where each sits,
/// down its delay now, a short trail behind), on a pad of the variant's two main knobs; the Rotary its spinning horn
/// and drum (a tap for Slow and Fast). Then each variant's chips and knobs, the rest under MORE.
class ChorusDevicePage extends StatelessWidget {
  const ChorusDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = variantOf(context);
    const names = ['Chorus', 'Ensemble', 'Doubler', 'Flanger', 'Vibrato', 'Rotary'];
    final free = t.param('sync') == null || formatParamValue(t.param('sync'), t.value('sync')) == 'Off' ||
        formatParamValue(t.param('sync'), t.value('sync')) == 'Free';
    final Widget hero;
    if (variant == 5) {
      final speed = t.value('speed').round();
      hero = HeroWithMeters(height: 200, gr: false, hero: liveHero(context: context, caption: 'ROTARY', height: 200,
        readout: Builder(builder: (context) => Text(const ['SLOW', 'FAST', 'BRAKE'][speed.clamp(0, 2)])),
        builder: (context, secs, v) => GestureDetector(
          key: const ValueKey('rotary-hero'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            DeviceFeel.tap();
            t.set('speed', speed == 1 ? 0 : 1);
          },
          child: CustomPaint(size: Size.infinite, painter: RotorPainter(
            horn: v?['horn_angle'] ?? secs * const [0.83, 6.75, 0.0][speed.clamp(0, 2)],
            drum: v?['drum_angle'] ?? 0.25 + secs * const [0.67, 5.8, 0.0][speed.clamp(0, 2)],
            width: t.value('width'), color: scope.accent, second: scope.secondary)))));
    } else {
      final (x, y) = _chorusPads[variant]!;
      hero = HeroWithMeters(height: 200, gr: false, hero: DeviceDisplay(builder: (context, f) => DevicePhase(
        builder: (context, secs) => XYPad(xParam: x, yParam: y, height: 200, caption: '${names[variant].toUpperCase()} · VOICES',
          painter: (dot) => VoicesPainter(voices: chorusVoices(scope, variant, secs, f?.values), color: scope.accent,
              second: scope.secondary, label: variant == 3 ? 'FB ${(t.value('feedback') * 100).round()}%' : null)))));
    }
    return mergedPage(context, 'chorus',
      cards: VariantCards(icon: _variantIcon, names: names, height: 52),
      hero: hero,
      rows: [
        switch (variant) {
          1 => controlsRow([smallLabel('VOICES'), const DeviceChoice('voices', maxSegments: 7)]),
          2 => controlsRow([smallLabel('DOUBLES'), const DeviceChoice('voices', maxSegments: 2)]),
          3 => controlsRow([smallLabel('SYNC'), const DeviceChoice('sync', maxSegments: 0)]),
          4 => controlsRow([smallLabel('SYNC'), const DeviceChoice('sync', maxSegments: 0), const DeviceChoice('shape', maxSegments: 3)]),
          5 => ModeTiles('speed', height: 44, icon: (c, r, i, col) => iconCurve(c, r, col,
              (x) => i == 2 ? -x * 0.8 : 0.8 * math.sin(math.pi * x * (i == 0 ? 1 : 4)))),
          _ => const SizedBox.shrink(),
        },
        if (variant == 1) ModeTiles('motion', height: 44, icon: (c, r, i, col) => iconCurve(c, r, col,
            (x) => i == 3 ? 0.7 * math.sin(math.pi * x) + 0.3 * math.sin(6 * math.pi * x) : lfoShape(i == 1 ? 1 : (i == 2 ? 6 : 0), (x + 1) / 2 * 2))),
      ],
      knobs: KnobRow(switch (variant) {
        1 => const ['delay', 'rate', 'detune', 'spread'],
        2 => const ['delay', 'drift', 'width', 'detune'],
        3 => [if (free) 'rate', 'depth', 'delay', 'feedback'],
        4 => [if (free) 'rate', 'depth'],
        5 => const ['accel', 'balance', 'width'],
        _ => const ['rate', 'depth'],
      }, size: 50),
      more: switch (variant) {
        1 => const ParamGrid(only: ['tone']),
        2 => const ParamGrid(only: ['low_cut', 'high_cut']),
        3 || 4 => const ParamGrid(only: ['stereo']),
        5 => const ParamGrid(only: ['drive', 'doppler']),
        _ => null,
      },
    );
  }
}

/// The variants' icons: dots for voices (two, a spread of five, a dry and two late ones), a comb, a wobble, a rotor.
void _variantIcon(Canvas canvas, Rect r, int index, Color color) {
  final p = Paint()..color = color;
  final c = r.center;
  switch (index) {
    case 0:
      canvas.drawCircle(c + Offset(-r.width * 0.22, -3), 3.5, p);
      canvas.drawCircle(c + Offset(r.width * 0.22, 3), 3.5, p);
    case 1:
      for (var k = 0; k < 5; k++) {
        canvas.drawCircle(Offset(r.left + r.width * (0.1 + 0.2 * k), c.dy + 5 * math.sin(k * 1.7)), 2.6, p);
      }
    case 2:
      canvas.drawCircle(c, 3, p..color = color.withValues(alpha: 0.5));
      canvas.drawCircle(c + Offset(-r.width * 0.3, 6), 3.2, p..color = color);
      canvas.drawCircle(c + Offset(r.width * 0.3, 8), 3.2, p);
    case 3:
      iconCurve(canvas, r, color, (x) => 0.8 * math.cos(x * math.pi * 3).abs() * 2 - 0.8);
    case 4:
      iconCurve(canvas, r, color, (x) => 0.7 * math.sin(x * math.pi * 3));
    default:
      final s = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      final rad = math.min(r.width, r.height) * 0.42;
      canvas.drawCircle(c, rad, s);
      canvas.drawLine(c - Offset(rad * 0.8, rad * 0.3), c + Offset(rad * 0.8, rad * 0.3), s);
      canvas.drawCircle(c + Offset(rad * 0.8, rad * 0.3), 2.5, p);
  }
}

/// The voices in the stereo field: left to right where each sits, top to bottom its delay now (the span fits the
/// longest), each a glowing dot with a fading trail of where it was; the dry signal's place at the top centre.
class VoicesPainter extends CustomPainter {
  VoicesPainter({required this.voices, required this.color, required this.second, this.label});
  final List<Voice> voices;
  final Color color, second;
  final String? label;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    var most = 1.0;
    for (final v in voices) {
      most = math.max(most, v.ms);
      for (final m in v.trail) {
        most = math.max(most, m);
      }
    }
    final span = most * 1.25;
    const top = 28.0;
    double y(double ms) => top + (h - top - 22) * (ms / span).clamp(0.0, 1.0);
    double x(double pan) => w / 2 + pan.clamp(-1.0, 1.0) * (w / 2 - 22);
    final faint = Paint()..color = Neon.ink.withAlpha(0x1A);
    canvas.drawLine(Offset(w / 2, top - 6), Offset(w / 2, h - 16), faint);
    for (final k in [0.25, 0.5, 0.75]) {
      canvas.drawLine(Offset(14, top + (h - top - 22) * k), Offset(w - 14, top + (h - top - 22) * k), faint);
    }
    paintLabel(canvas, 'L', Offset(10, h - 10), color, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(w - 10, h - 10), second, size: 9, align: 1, weight: FontWeight.w800);
    paintLabel(canvas, '${span.toStringAsFixed(span < 10 ? 1 : 0)} ms', Offset(w / 2 + 6, h - 10), Neon.dim, size: 8);
    canvas.drawCircle(Offset(w / 2, top - 4), 3, Paint()..color = Neon.text.withValues(alpha: 0.7));
    for (final v in voices) {
      final c = Color.lerp(color, second, (v.pan + 1) / 2)!;
      final px = x(v.pan);
      for (var k = v.trail.length - 1; k >= 0; k--) {
        canvas.drawCircle(Offset(px, y(v.trail[k])), 4.5 - k * 0.5, Paint()..color = c.withValues(alpha: 0.32 - k * 0.045));
      }
      canvas.drawLine(Offset(px, top - 4), Offset(px, y(v.ms)), Paint()
        ..color = c.withValues(alpha: 0.25)
        ..strokeWidth = 1.2);
      canvas.drawCircle(Offset(px, y(v.ms)), 11, Paint()..color = c.withValues(alpha: 0.18));
      canvas.drawCircle(Offset(px, y(v.ms)), 5.5, Paint()..color = c);
    }
    paintLabel(canvas, label ?? '${voices.length} voices', Offset(w - 24, h - 10), Neon.text, size: 9, align: 1);
  }

  @override
  bool shouldRepaint(covariant VoicesPainter o) => paintInputsChanged(
      [o.voices.map((v) => v.ms).toList(), o.voices.map((v) => v.pan).toList(), o.color, o.second, o.label],
      [voices.map((v) => v.ms).toList(), voices.map((v) => v.pan).toList(), color, second, label]);
}

// ---------------------------------------------------------------------------------------------------------------
// Phaser

/// The Phaser: its notches sweeping, left and right, with the LFO (drag sideways for the centre, up and down for
/// the feedback); stages and sync; rate, depth, centre and feedback, stereo under MORE.
class PhaserDevicePage extends StatelessWidget {
  const PhaserDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final free = t.value('sync') < 0.5;
    return mergedPage(context, 'phaser',
      hero: HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'NOTCHES ≈',
        grid: false,
        readout: Builder(builder: (context) => Text('${formatParamValue(t.param('center'), t.value('center'))} Hz')),
        child: const CombHero(flanger: false),
      )),
      rows: [
        controlsRow([
          smallLabel('STAGES'), const DeviceChoice('stages', maxSegments: 6),
          smallLabel('SYNC'), const DeviceChoice('sync', maxSegments: 0),
        ]),
      ],
      knobs: KnobRow([if (free) 'rate', 'depth', 'center', 'feedback'], size: 50),
      more: const ParamGrid(only: ['stereo']),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Tremolo/Pan

/// Tremolo/Pan: Tremolo, Pan and (1.1.0) Shape as cards. Shape, the drawn-shape ducker, keeps the ducker's page
/// under the cards until the owner approves its page. Tremolo and Pan: the LFO's shape over two cycles with where it is now, and under it the stereo
/// puck (Pan: the sound's place swinging; Tremolo: the left and right levels dipping), on a pad of rate (free only)
/// and depth; shape tiles, sync, then smooth and the rest.
class TremoloDevicePage extends StatelessWidget {
  const TremoloDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final pan = variantOf(context) == 1;
    final cards = VariantCards(height: 48, icon: (c, r, i, col) {
        if (i == 0) {
          iconCurve(c, r, col, (x) => 0.75 * math.sin(x * math.pi * 2).abs() * 2 - 0.75);
        } else if (i == 2) {
          iconCurve(c, r, col, (x) => 0.8 - 1.6 * duckAt((x + 1) / 2 * 300, 5, 20, 220, 0.5));
        } else {
          c.drawLine(Offset(r.left + 4, r.center.dy), Offset(r.right - 4, r.center.dy), Paint()
            ..color = col.withValues(alpha: 0.5)
            ..strokeWidth = 1.4);
          c.drawCircle(Offset(r.left + r.width * 0.68, r.center.dy), 4.5, Paint()..color = col);
          c.drawCircle(Offset(r.left + r.width * 0.42, r.center.dy), 3, Paint()..color = col.withValues(alpha: 0.45));
        }
      });
    if (variantOf(context) == 2) {
      if (DeviceScope.isInline(context)) return const DuckerPage();
      return Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 0), child: cards),
        const Expanded(child: DuckerPage()),
      ]);
    }
    return mergedPage(context, 'tremolo',
      cards: cards,
      hero: HeroWithMeters(height: 200, gr: false, hero: DeviceDisplay(builder: (context, f) => DevicePhase(
        builder: (context, secs) => XYPad(xParam: 'rate', yParam: 'depth', height: 200, caption: pan ? 'PAN' : 'TREMOLO',
          painter: (dot) => LfoPuckPainter(secs: secs, rate: modRateHz(scope), depth: t.value('depth'),
              shape: t.value('shape').round(), pan: pan, stereo: pan ? 0 : t.value('stereo'),
              offset: pan ? t.value('offset') : 0, width: pan ? t.value('width') : 1, live: f?.values,
              color: scope.accent, second: scope.secondary))))),
      rows: [
        ModeTiles('shape', icon: (c, r, i, col) => iconCurve(c, r, col, (x) => lfoShape(i, (x + 1) / 2 * 2)), height: 44,
            names: const ['Sine', 'Tri', 'Up', 'Down', 'Sq', 'S&H', 'Rnd']),
        controlsRow([
          smallLabel('SYNC'), const DeviceChoice('sync', maxSegments: 0),
          if (!pan) const DeviceChoice('mode', maxSegments: 2),
        ]),
      ],
      knobs: KnobRow(pan ? const ['smooth', 'offset', 'width'] : const ['smooth', 'stereo'], size: 50),
    );
  }
}

/// The LFO's shape (two cycles, the phase now as a glowing dot riding it) over a stereo strip with the puck: Pan's
/// place now, or Tremolo's left and right levels as two pucks whose size and light follow the gain.
class LfoPuckPainter extends CustomPainter {
  LfoPuckPainter({required this.secs, required this.rate, required this.depth, required this.shape, required this.pan,
    required this.stereo, required this.offset, required this.width, required this.live, required this.color,
    required this.second});
  final double secs, rate, depth, stereo, offset, width;
  final int shape;
  final bool pan;
  final Map<String, double>? live;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final strip = h - 30.0, top = 26.0, bottom = strip - 18;
    final mid = (top + bottom) / 2, amp = (bottom - top) / 2;
    final phase = (secs * rate + offset) % 2.0; // where the LFO is, in cycles over the two shown
    double ly(double v) => pan ? mid - amp * v * depth : bottom - (bottom - top) * (1 - depth * (1 - v) / 2);
    final path = Path();
    for (var i = 0; i <= 200; i++) {
      final x = 12 + (w - 24) * i / 200;
      final yy = ly(lfoShape(shape, 2 * i / 200));
      i == 0 ? path.moveTo(x, yy) : path.lineTo(x, yy);
    }
    canvas.drawLine(Offset(12, pan ? mid : top), Offset(w - 12, pan ? mid : top), Paint()..color = Neon.ink.withAlpha(0x1A));
    fillFade(canvas, path, bottom, size, color, alpha: 0.16);
    strokeGlow(canvas, path, color, width: 2);
    final lNow = live?['lfo_l'] ?? lfoShape(shape, phase);
    final px = 12 + (w - 24) * phase / 2;
    canvas.drawLine(Offset(px, top - 4), Offset(px, bottom + 4), Paint()..color = Neon.ink.withAlpha(0x33));
    canvas.drawCircle(Offset(px, ly(lNow)), 6, Paint()..color = Neon.ink);
    // The stereo strip.
    final sy = strip + 4, l = 26.0, r = w - 26.0;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(l, sy - 3, r, sy + 3), const Radius.circular(3)),
        Paint()..color = Neon.ink.withValues(alpha: 0.07));
    canvas.drawLine(Offset((l + r) / 2, sy - 8), Offset((l + r) / 2, sy + 8), Paint()..color = Neon.ink.withAlpha(0x33));
    paintLabel(canvas, 'L', Offset(10, sy), color, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(w - 10, sy), second, size: 9, align: 1, weight: FontWeight.w800);
    if (pan) {
      final place = (lNow * depth).clamp(-1.0, 1.0) * width.clamp(0.0, 1.0);
      final at = Offset((l + r) / 2 + place * (r - l) / 2, sy);
      final c = Color.lerp(color, second, (place + 1) / 2)!;
      canvas.drawCircle(at, 14, Paint()..color = c.withValues(alpha: 0.2));
      canvas.drawCircle(at, 8, Paint()..color = c);
    } else {
      final gl = live?['gain_l'] ?? (1 - depth * (1 - lNow) / 2);
      final rNow = live?['lfo_r'] ?? lfoShape(shape, phase - stereo * 0.5);
      final gr = live?['gain_r'] ?? (1 - depth * (1 - rNow) / 2);
      for (final (g, x, c) in [(gl, l + (r - l) * 0.25, color), (gr, l + (r - l) * 0.75, second)]) {
        final k = g.clamp(0.0, 1.0);
        canvas.drawCircle(Offset(x, sy), 6 + 8 * k, Paint()..color = c.withValues(alpha: 0.12 + 0.2 * k));
        canvas.drawCircle(Offset(x, sy), 3 + 5 * k, Paint()..color = c.withValues(alpha: 0.4 + 0.6 * k));
      }
    }
  }

  @override
  bool shouldRepaint(covariant LfoPuckPainter o) => paintInputsChanged(
      [o.secs, o.rate, o.depth, o.shape, o.pan, o.stereo, o.offset, o.width, o.live, o.color, o.second],
      [secs, rate, depth, shape, pan, stereo, offset, width, live, color, second]);
}
