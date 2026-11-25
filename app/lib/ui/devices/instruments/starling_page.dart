// Starling's page (org.caw.starling, the hybrid piano): the piano's action drawn live (keys, hammers rising to the strings, dampers lifting with the pedal; drag up and down for the hammer's hardness), a strings picture for its plucked models, and the Model, Tone and Space panels.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/settings.dart' show SoundQuality;
import '../../theme.dart';
import '../device_scope.dart';
import '../kit/hero.dart';
import 'instrument_page.dart';

const starlingComponentId = 'org.caw.starling';

/// The piano's knobs in the panel's order; any other model's own knobs follow theirs.
const starlingKnobs = ['hammer', 'noise', 'decay', 'sustain', 'soft', 'resonance', 'unison', 'stretch', 'touch', 'glide',
  'sympathy', 'phantom', 'position'];
const starlingLabels = {'hammer': 'Hammer', 'noise': 'Noise', 'sustain': 'Sustain', 'soft': 'Soft', 'resonance': 'Resonance',
  'unison': 'Detune', 'stretch': 'Stretch', 'touch': 'Touch', 'glide': 'Glide', 'sympathy': 'Sympathy', 'phantom': 'Phantom',
  'character': 'Character', 'action': 'Action delay', 'tier': 'Quality'};

/// Whether [name] (a Starling model) is plucked strings rather than the piano.
bool starlingPlucked(String name) => name.toLowerCase().contains('guitar') || name.toLowerCase().contains('harp');

final starlingSpec = InstrumentSpec(
  id: starlingComponentId,
  key: 'starling',
  title: 'PIANO',
  icon: Icons.piano_outlined,
  hint: 'Play: the hammers rise to the strings, the dampers lift with the pedal. Drag the picture up and down for the hammer.',
  cardIcon: starlingIcon,
  caption: (t, p) {
    final c = t.param('character');
    final v = t.value('character').round();
    return c != null && c.choices.isNotEmpty ? '${p.name.toUpperCase()} · ${c.choices[v.clamp(0, c.choices.length - 1)].toUpperCase()}'
        : p.name.toUpperCase();
  },
  // The piano's hammer up and down; a plucked model's pluck point sideways, where it has one.
  drag: (t, variant, at, size) => t.param('hammer') != null ? const PictureDrag(y: 'hammer', span: 0.8)
      : t.param('position') != null ? const PictureDrag(x: 'position', xSign: -1) : null,
  painter: (p) => StarlingPainter(p),
  inlineKnobs: const ['hammer', 'noise', 'sustain', 'resonance'],
  panels: [
    InstrumentPanel('Model', (context, knob) {
      // Phantom partials act only at High (the descriptor's note).
      final high = instrumentQuality(DeviceScope.of(context).target) == SoundQuality.high;
      return InstrumentOwnControls(prefix: 'starling', order: starlingKnobs, labels: starlingLabels, knob: knob,
          hide: high ? const {} : const {'phantom'});
    }),
    InstrumentPanel('Tone', (context, knob) => instrumentKnobPanel(instrumentToneKnobs, knob)),
    InstrumentPanel('Space', (context, knob) => instrumentKnobPanel(instrumentSpaceKnobs, knob)),
  ],
);

class StarlingPainter extends CustomPainter {
  StarlingPainter(this.p);
  final InstrumentPicture p;

  @override
  void paint(Canvas canvas, Size s) {
    if (s.isEmpty) return;
    starlingPlucked(p.name) ? _strings(canvas, s) : _action(canvas, s);
  }

  /// Two octaves of the keyboard around the last key, each white key's hammer under the strings: the struck one
  /// risen with the velocity and its string swinging; the dampers over the strings lift with the pedal.
  void _action(Canvas canvas, Size s) {
    final key = p.frame.live && p.frame.lastKey >= 0 ? p.frame.lastKey : 60;
    // The octave the last key sits in, from its C: 14 white keys from the C below.
    final c0 = (key ~/ 12) * 12 - 12;
    const whites = [0, 2, 4, 5, 7, 9, 11];
    const count = 14;
    final left = s.width * 0.03, right = s.width * 0.97;
    final w = (right - left) / count;
    final keyTop = s.height * 0.72, keyBottom = s.height * 0.97;
    final stringY = s.height * 0.24;
    final hard = p.value('hammer').clamp(0.0, 1.0);
    final soft = p.value('soft').clamp(0.0, 1.0);
    final pedal = math.max(p.value('sustain'), p.frame.pedal).clamp(0.0, 1.0);
    final felt = p.value('character').round() == 2;
    final live = p.energy > 0;
    // The strings: a line across, the struck key's swinging.
    canvas.drawLine(Offset(left, stringY), Offset(right, stringY), instrumentLine(Neon.ink.withValues(alpha: 0.35), 1));
    canvas.drawLine(Offset(left, stringY + 3), Offset(right, stringY + 3), instrumentLine(Neon.ink.withValues(alpha: 0.2), 1));
    if (felt) {
      canvas.drawRect(Rect.fromLTRB(left, stringY + 6, right, stringY + 11), Paint()..color = p.secondary.withValues(alpha: 0.2));
    }
    for (var i = 0; i < count; i++) {
      final note = c0 + (i ~/ 7) * 12 + whites[i % 7];
      final x = left + w * (i + 0.5);
      final struck = p.frame.live && note == key;
      // The key: down while it sounds.
      final dip = struck && live ? 3.0 : 0.0;
      final r = RRect.fromRectAndRadius(Rect.fromLTRB(x - w * 0.46, keyTop + dip, x + w * 0.46, keyBottom), const Radius.circular(3));
      canvas.drawRRect(r, Paint()..color = struck ? p.accent.withValues(alpha: 0.5 + 0.4 * p.energy) : Neon.ink.withValues(alpha: 0.75));
      if (i % 7 == 0) paintLabel(canvas, 'C${note ~/ 12 - 1}', Offset(x, keyBottom - 8), Neon.bg, size: 7, align: 0);
      // The hammer on its shank: risen toward the string with the velocity while it sounds; the soft pedal shifts
      // it sideways; its felt brighter as it hardens.
      final rise = struck ? (stringY + 14 - (keyTop - 10)) * (0.4 + 0.6 * p.swing) : 0.0;
      final hx = x + soft * w * 0.22;
      final hy = keyTop - 10 + rise;
      canvas.drawLine(Offset(hx, keyTop - 2), Offset(hx, hy), instrumentLine(Neon.dim.withValues(alpha: 0.6), 1.2));
      final head = Rect.fromCenter(center: Offset(hx, hy - 5), width: w * 0.5, height: 10);
      canvas.drawRRect(RRect.fromRectAndRadius(head, const Radius.circular(3)), Paint()
        ..color = Color.lerp(p.secondary.withValues(alpha: 0.35), Neon.ink, hard * 0.7)!.withValues(alpha: struck ? 1 : 0.6));
      // The damper over the string: lifted with the pedal or while its key sounds.
      final lift = math.max(pedal, struck && live ? 1.0 : 0.0) * 6;
      canvas.drawRect(Rect.fromLTWH(x - w * 0.3, stringY - 9 - lift, w * 0.6, 5), Paint()..color = Neon.dim.withValues(alpha: 0.55));
      if (struck && live) {
        final amp = p.swing * 5;
        final path = Path()..moveTo(left, stringY);
        for (var j = 1; j <= 40; j++) {
          final u = j / 40;
          path.lineTo(left + (right - left) * u, stringY + amp * math.sin(p.seconds * 2 * math.pi * 9) * math.sin(math.pi * u));
        }
        strokeGlow(canvas, path, p.accent, width: 1.4);
      }
    }
    paintLabel(canvas, pedal > 0.5 ? 'PEDAL DOWN' : '', Offset(right, s.height * 0.1), Neon.dim, size: 7.5, align: 1);
  }

  /// A plucked model: its strings across (a guitar's six over the sound hole, a harp's many), the last key's swinging.
  void _strings(Canvas canvas, Size s) {
    final harp = p.name.toLowerCase().contains('harp');
    final count = harp ? 18 : 6;
    final top = s.height * 0.2, bottom = s.height * 0.9;
    if (!harp) {
      canvas.drawCircle(Offset(s.width * 0.55, (top + bottom) / 2), (bottom - top) * 0.42, instrumentLine(p.accent.withValues(alpha: 0.4), 1.2));
    }
    final hit = p.struck(count, low: harp ? 24 : 40, high: harp ? 103 : 88);
    for (var i = 0; i < count; i++) {
      final u = i / (count - 1);
      final struck = i == hit && p.energy > 0;
      final a = harp ? Offset(s.width * (0.1 + 0.8 * u), top) : Offset(s.width * 0.04, bottom - (bottom - top) * u);
      final b = harp ? Offset(s.width * (0.1 + 0.8 * u), bottom - (bottom - top) * 0.6 * u) : Offset(s.width * 0.96, bottom - (bottom - top) * u);
      final d = b - a;
      final n = Offset(-d.dy, d.dx) / d.distance;
      final path = Path()..moveTo(a.dx, a.dy);
      for (var j = 1; j <= 24; j++) {
        final v = j / 24;
        final pt = a + d * v + n * (struck ? p.swing * 4 * math.sin(p.seconds * 2 * math.pi * 8) * math.sin(math.pi * v) : 0);
        path.lineTo(pt.dx, pt.dy);
      }
      strokeGlow(canvas, path, struck ? p.accent : Neon.ink.withValues(alpha: 0.45), width: struck ? 1.5 : 1, glow: struck);
    }
  }

  @override
  bool shouldRepaint(covariant StarlingPainter o) => true;
}

/// The model cards' icons: keys for the piano, strings for a plucked model (by its place: the guitar, then the harp).
void starlingIcon(Canvas canvas, Rect r, int k, Color c) {
  final line = instrumentLine(c, 1.4);
  final box = Rect.fromCenter(center: r.center, width: r.height * 1.3, height: r.height);
  if (k == 0) {
    for (var i = 0; i < 4; i++) {
      canvas.drawRect(Rect.fromLTWH(box.left + box.width * i / 4, box.top, box.width / 4, box.height), line);
    }
    for (final i in [1, 2]) {
      canvas.drawRect(Rect.fromLTWH(box.left + box.width * i / 4 - box.width * 0.07, box.top, box.width * 0.14, box.height * 0.6),
          Paint()..color = c);
    }
    return;
  }
  for (var i = 0; i < 5; i++) {
    final x = box.left + box.width * (i + 0.5) / 5;
    canvas.drawLine(Offset(x, box.top), Offset(x, box.bottom - (k == 2 ? box.height * 0.12 * i : 0)), line);
  }
}
