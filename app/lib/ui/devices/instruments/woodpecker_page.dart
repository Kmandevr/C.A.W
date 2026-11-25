// Woodpecker's page (org.caw.woodpecker, tuned percussion): the Marimba to Timpani cards, the bars over their resonator tubes, the hanging chimes or the drum head drawn live with the woodpecker pecking the struck one (drag up and down for the mallet's hardness), and the Mallet, Tone and Space panels.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../kit/birds.dart';
import 'instrument_page.dart';

const woodpeckerComponentId = 'org.caw.woodpecker';

/// Variant indices (engine/src/builtin_woodpecker.cpp).
abstract final class WoodpeckerInstrument {
  static const marimba = 0, xylophone = 1, glockenspiel = 2, vibraphone = 3, chimes = 4, timpani = 5;
}

/// Each instrument's played range in MIDI keys (docs/engine.md, Woodpecker).
const woodpeckerRanges = [(41, 96), (65, 108), (79, 108), (53, 89), (60, 77), (38, 57)];

const woodpeckerKnobs = ['hardness', 'decay', 'attack', 'resonator', 'sustain', 'motor', 'motor_depth'];
const woodpeckerLabels = {'decay': 'Decay', 'attack': 'Attack', 'resonator': 'Resonator', 'sustain': 'Damper',
  'motor': 'Motor', 'motor_depth': 'Depth', 'tier': 'Quality'};

final woodpeckerSpec = InstrumentSpec(
  id: woodpeckerComponentId,
  key: 'woodpecker',
  title: 'TUNED PERCUSSION',
  icon: Icons.graphic_eq,
  hint: 'Pick an instrument, then play: the struck bar rings. Drag the picture up and down for the mallet\'s hardness.',
  cardIcon: woodpeckerIcon,
  cardNames: const ['Marimba', 'Xylo', 'Glock', 'Vibes', 'Chimes', 'Timpani'],
  drag: (t, variant, at, size) => const PictureDrag(y: 'hardness', span: 0.8),
  painter: (p) => WoodpeckerPainter(p),
  inlineKnobs: const ['hardness', 'decay', 'attack', 'resonator'],
  panels: [
    InstrumentPanel('Mallet', (context, knob) {
      final timpani = instrumentVariantOf(context) == WoodpeckerInstrument.timpani;
      return InstrumentOwnControls(prefix: 'woodpecker', order: woodpeckerKnobs, knob: knob,
          labels: {...woodpeckerLabels, 'hardness': timpani ? 'Stick' : 'Mallet'});
    }),
    InstrumentPanel('Tone', (context, knob) => instrumentKnobPanel(instrumentToneKnobs, knob)),
    InstrumentPanel('Space', (context, knob) => instrumentKnobPanel(instrumentSpaceKnobs, knob)),
  ],
);

class WoodpeckerPainter extends CustomPainter {
  WoodpeckerPainter(this.p);
  final InstrumentPicture p;

  @override
  void paint(Canvas canvas, Size s) {
    if (s.isEmpty) return;
    final k = p.variant.clamp(0, 5);
    if (k == WoodpeckerInstrument.timpani) return _drum(canvas, s);
    final chimes = k == WoodpeckerInstrument.chimes;
    final count = chimes ? 9 : 12;
    final (low, high) = woodpeckerRanges[k];
    final hit = p.struck(count, low: low, high: high);
    final left = s.width * 0.04, right = s.width * 0.96;
    final top = s.height * 0.2, bottom = s.height * 0.95;
    final w = (right - left) / count;
    final tubes = k == WoodpeckerInstrument.marimba || k == WoodpeckerInstrument.xylophone || k == WoodpeckerInstrument.vibraphone;
    final resonator = p.value('resonator').clamp(0.0, 1.0);
    final motor = p.value('motor');
    final pedal = math.max(p.value('sustain'), p.frame.pedal).clamp(0.0, 1.0);
    Offset? strike;
    if (chimes) canvas.drawLine(Offset(left, top), Offset(right, top), instrumentLine(Neon.ink.withValues(alpha: 0.4), 2));
    for (var i = 0; i < count; i++) {
      final u = i / (count - 1);
      final x = left + w * (i + 0.5);
      final struck = i == hit;
      final ring = struck ? p.swing : 0.0;
      final c = struck ? p.accent : Neon.ink.withValues(alpha: 0.5);
      if (chimes) {
        // Tubes hanging from the rail, longer in the bass, the struck one swinging.
        final len = (bottom - top - 8) * (1 - u * 0.45);
        final swing = ring * 4 * math.sin(p.seconds * 2 * math.pi * 1.2);
        canvas.drawLine(Offset(x, top), Offset(x + swing, top + len), instrumentLine(c.withValues(alpha: struck ? 0.9 : 0.5), w * 0.42));
        canvas.drawLine(Offset(x - w * 0.22, top + 6), Offset(x + w * 0.22 + swing * 0.05, top + 6), instrumentLine(Neon.bg, 1.4));
        if (struck) strike = Offset(x - w * 0.3 + swing * 0.1, top + 16);
        continue;
      }
      // A bar, shorter in the treble, over its tube where it has one.
      final len = (bottom - top) * (0.5 - u * 0.24) * (k == WoodpeckerInstrument.glockenspiel ? 0.7 : 1);
      final bar = Rect.fromLTWH(x - w * 0.4, top + ((bottom - top) * 0.5 - len) / 2, w * 0.8, len);
      final shake = ring * 1.5 * math.sin(p.seconds * 2 * math.pi * 7);
      final shown = bar.translate(0, shake);
      final metal = k == WoodpeckerInstrument.glockenspiel || k == WoodpeckerInstrument.vibraphone;
      final tint = metal ? Color.lerp(Neon.ink, p.secondary, 0.3)! : Color.lerp(Neon.ink, const Color(0xFFB07A4A), 0.5)!;
      canvas.drawRRect(RRect.fromRectAndRadius(shown, const Radius.circular(3)),
          Paint()..color = (struck ? p.accent : tint).withValues(alpha: struck ? 0.35 + 0.55 * p.energy : 0.3));
      if (struck && p.energy > 0) {
        canvas.drawRRect(RRect.fromRectAndRadius(shown.inflate(2), const Radius.circular(4)), instrumentLine(p.accent, 1.2));
      }
      if (tubes) {
        final tube = Rect.fromLTRB(x - w * 0.22, bar.bottom + 5, x + w * 0.22, bottom - (bottom - top) * 0.25 * u);
        canvas.drawRect(tube, Paint()..color = (struck ? p.accent : Neon.dim).withValues(alpha: 0.06 + 0.16 * resonator + 0.2 * ring * resonator));
        // The vibraphone's motor: the disc in each tube's top turning (the engine's phase while it plays).
        if (k == WoodpeckerInstrument.vibraphone && motor > 0) {
          final ph = (p.frame.live ? p.frame.own(1) : p.seconds * motor) * 2 * math.pi;
          canvas.drawLine(Offset(x - w * 0.2 * math.cos(ph), tube.top + 4), Offset(x + w * 0.2 * math.cos(ph), tube.top + 4),
              instrumentLine(p.secondary, 1.6));
        }
      }
      if (struck) strike = Offset(x + w * 0.1, shown.top + len * 0.45);
    }
    // The vibraphone's damper bar under the bars, lowered off them as the pedal goes down.
    if (k == WoodpeckerInstrument.vibraphone) {
      final y = top + (bottom - top) * 0.5 + 4 + pedal * 5;
      canvas.drawLine(Offset(left, y), Offset(right, y), instrumentLine(p.secondary.withValues(alpha: 0.5), 3));
    }
    _bird(canvas, s, strike ?? Offset(left + w * (count / 2), top + (bottom - top) * 0.2));
  }

  /// The timpani: the kettle and its head from above, rippling while it sounds; the woodpecker pecks near the rim.
  void _drum(Canvas canvas, Size s) {
    final c = Offset(s.width * 0.5, s.height * 0.6);
    final rx = math.min(s.width * 0.36, s.height * 0.9), ry = s.height * 0.3;
    final kettle = Path()
      ..moveTo(c.dx - rx, c.dy)
      ..quadraticBezierTo(c.dx - rx * 0.85, c.dy + ry * 1.5, c.dx, c.dy + ry * 1.55)
      ..quadraticBezierTo(c.dx + rx * 0.85, c.dy + ry * 1.5, c.dx + rx, c.dy);
    canvas.drawPath(kettle, Paint()..color = Color.lerp(Neon.ink, const Color(0xFFB07A4A), 0.6)!.withValues(alpha: 0.18));
    canvas.drawPath(kettle, instrumentLine(p.accent.withValues(alpha: 0.35), 1.2));
    final head = Rect.fromCenter(center: c, width: rx * 2, height: ry * 2);
    canvas.drawOval(head, Paint()..color = p.accent.withValues(alpha: 0.06 + 0.2 * p.energy));
    canvas.drawOval(head, instrumentLine(p.accent.withValues(alpha: 0.7), 1.6));
    // The (1,1) mode's ripples, spreading from the strike point while it rings.
    if (p.energy > 0) {
      for (var i = 0; i < 3; i++) {
        final u = (p.seconds * 0.8 + i / 3) % 1.0;
        canvas.drawOval(Rect.fromCenter(center: c + Offset(-rx * 0.45 * (1 - u), 0), width: rx * 2 * u, height: ry * 2 * u),
            instrumentLine(p.accent.withValues(alpha: (1 - u) * 0.6 * p.energy), 1.2));
      }
    }
    _bird(canvas, s, c + Offset(-rx * 0.72, -ry * 0.25));
  }

  /// The one motif: the woodpecker at the strike point, pecking harder (its beak lower) with the mallet.
  void _bird(Canvas canvas, Size s, Offset at) =>
      paintWoodpecker(canvas, at, s.height * 0.17, p.accent, beak: p.value('hardness').clamp(0.0, 1.0));

  @override
  bool shouldRepaint(covariant WoodpeckerPainter o) => true;
}

/// The cards' icons: bars over tubes, short bright bars, metal bars, bars with a motor, hanging tubes, a drum.
void woodpeckerIcon(Canvas canvas, Rect r, int k, Color c) {
  final line = instrumentLine(c, 1.4);
  final box = Rect.fromCenter(center: r.center, width: r.height * 1.4, height: r.height);
  if (k == WoodpeckerInstrument.timpani) {
    canvas.drawOval(Rect.fromLTWH(box.left, box.top + box.height * 0.1, box.width, box.height * 0.4), line);
    canvas.drawArc(Rect.fromLTWH(box.left, box.top - box.height * 0.1, box.width, box.height * 1.1), 0, math.pi, false, line);
    return;
  }
  if (k == WoodpeckerInstrument.chimes) {
    canvas.drawLine(box.topLeft, box.topRight, line);
    for (var i = 0; i < 4; i++) {
      final x = box.left + box.width * (i + 0.5) / 4;
      canvas.drawLine(Offset(x, box.top), Offset(x, box.bottom - box.height * 0.15 * i), instrumentLine(c, 2.4));
    }
    return;
  }
  for (var i = 0; i < 5; i++) {
    final h = box.height * (k == WoodpeckerInstrument.glockenspiel ? 0.5 : 0.6) * (1 - i * 0.12);
    final bar = Rect.fromLTWH(box.left + box.width * i / 5 + 1, box.top, box.width / 5 - 2, h);
    canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(1.5)), line);
    if (k != WoodpeckerInstrument.glockenspiel && k != WoodpeckerInstrument.xylophone) {
      canvas.drawLine(Offset(bar.center.dx, bar.bottom + 2), Offset(bar.center.dx, box.bottom), line);
    }
  }
  if (k == WoodpeckerInstrument.vibraphone) canvas.drawCircle(Offset(box.right, box.bottom), 2.2, Paint()..color = c);
}
