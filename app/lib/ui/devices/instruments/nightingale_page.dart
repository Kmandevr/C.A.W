// Nightingale's page (org.caw.nightingale, bowed strings): the Violin, Viola, Cello and Bass cards, the string drawn live under the bow (drag sideways for the bow's place, up and down for its pressure), and the Bow, Tone and Space panels.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../kit/hero.dart';
import 'instrument_page.dart';

const nightingaleComponentId = 'org.caw.nightingale';

/// The bow's knobs in the order the panel shows them.
const nightingaleKnobs = ['pressure', 'speed', 'position', 'noise', 'vibrato', 'vib_rate', 'attack'];
const nightingaleLabels = {'pressure': 'Pressure', 'speed': 'Speed', 'position': 'Position', 'noise': 'Bow noise',
  'tier': 'Quality'};

final nightingaleSpec = InstrumentSpec(
  id: nightingaleComponentId,
  key: 'nightingale',
  title: 'BOWED STRINGS',
  icon: Icons.music_note_outlined,
  hint: 'Pick an instrument, then play: the string moves under the bow. Drag sideways to move the bow, up and down to press.',
  cardIcon: nightingaleIcon,
  cardNames: const ['Violin', 'Viola', 'Cello', 'Bass'],
  twoAxes: true,
  // Sideways: the bow follows the finger (toward the bridge, right, is a lower Position); up presses harder.
  drag: (t, variant, at, size) => const PictureDrag(x: 'position', y: 'pressure', xSign: -1, span: 0.5),
  painter: (p) => NightingalePainter(p),
  inlineKnobs: const ['pressure', 'speed', 'position', 'vibrato'],
  panels: [
    InstrumentPanel('Bow', (context, knob) =>
        InstrumentOwnControls(prefix: 'nightingale', order: nightingaleKnobs, labels: nightingaleLabels, knob: knob)),
    InstrumentPanel('Tone', (context, knob) => instrumentKnobPanel(instrumentToneKnobs, knob)),
    InstrumentPanel('Space', (context, knob) => instrumentKnobPanel(instrumentSpaceKnobs, knob)),
  ],
);

/// The bowed string: the instrument's body behind, the string from the nut (left) to the bridge (right) moving as a
/// Helmholtz corner while it sounds, and the bow across it at its place, its hair as thick as it presses.
class NightingalePainter extends CustomPainter {
  NightingalePainter(this.p);
  final InstrumentPicture p;

  @override
  void paint(Canvas canvas, Size s) {
    if (s.isEmpty) return;
    final k = p.variant.clamp(0, 3);
    final nut = s.width * 0.07, bridge = s.width * 0.9;
    final cy = s.height * 0.58;
    // The body: wider and lower in the bass.
    final bw = s.width * (0.42 + k * 0.05), bh = s.height * (0.62 + k * 0.06), bx = s.width * 0.66;
    final body = Path()
      ..addOval(Rect.fromCenter(center: Offset(bx - bw * 0.24, cy), width: bw * 0.5, height: bh * 0.86))
      ..addOval(Rect.fromCenter(center: Offset(bx + bw * 0.22, cy), width: bw * 0.56, height: bh));
    canvas.drawPath(body, Paint()..color = p.accent.withValues(alpha: 0.05 + 0.08 * p.value('body') + 0.08 * p.energy));
    canvas.drawPath(body, instrumentLine(p.accent.withValues(alpha: 0.35), 1.2));
    for (final dy in [-1.0, 1.0]) {
      canvas.drawPath(Path()
        ..moveTo(bx - bw * 0.06, cy + dy * bh * 0.32)
        ..cubicTo(bx + bw * 0.02, cy + dy * bh * 0.2, bx - bw * 0.02, cy + dy * bh * 0.1, bx + bw * 0.08, cy + dy * bh * 0.05),
          instrumentLine(Neon.dim, 1.1));
    }
    // The fingerboard from the nut, the bridge and their names.
    final board = Rect.fromLTRB(nut, cy - 7, nut + (bridge - nut) * 0.58, cy + 7);
    canvas.drawRRect(RRect.fromRectAndRadius(board, const Radius.circular(3)), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    canvas.drawLine(Offset(nut, cy - 10), Offset(nut, cy + 10), instrumentLine(Neon.ink.withValues(alpha: 0.6), 2.4));
    canvas.drawLine(Offset(bridge, cy - 12), Offset(bridge, cy + 8), instrumentLine(Neon.ink.withValues(alpha: 0.6), 2.4));
    paintLabel(canvas, 'NUT', Offset(nut, cy + 20), Neon.dim, size: 7.5, align: 0);
    paintLabel(canvas, 'BRIDGE', Offset(bridge, cy + 20), Neon.dim, size: 7.5, align: 0);
    // Pressure and speed: the engine's while it sounds, else the knobs'.
    final live = p.energy > 0;
    final press = (live ? p.frame.own(1) : p.value('pressure')).clamp(0.0, 1.0);
    final speed = (live ? p.frame.own(2) : p.value('speed')).clamp(0.0, 1.0);
    // The string: a Helmholtz corner running between nut and bridge while it sounds; straight when it is still.
    final amp = p.swing * s.height * 0.12;
    final corner = (0.5 + 0.5 * math.sin(p.seconds * 2 * math.pi * 1.6)) * (bridge - nut) + nut;
    final side = math.cos(p.seconds * 2 * math.pi * 1.6) >= 0 ? 1.0 : -1.0;
    final string = Path()..moveTo(nut, cy);
    if (amp > 0.3) string.lineTo(corner, cy + side * amp * math.sin(math.pi * (corner - nut) / (bridge - nut)));
    string.lineTo(bridge, cy);
    strokeGlow(canvas, string, live ? p.accent : Neon.ink.withValues(alpha: 0.7), width: 1.4 + k * 0.3, glow: live);
    // The bow at its place: 0 at the bridge, 1 over the fingerboard; it travels along its length with the speed.
    final x = bowX(p.value('position'), s);
    final travel = live ? math.sin(p.seconds * 2 * math.pi * (0.25 + 0.5 * speed)) * s.height * 0.1 : 0.0;
    final top = s.height * 0.12 + travel, bottom = s.height * 0.98 + travel;
    final tilt = s.width * 0.03;
    canvas.drawLine(Offset(x - tilt - 4, top), Offset(x + tilt - 4, bottom), instrumentLine(Neon.dim.withValues(alpha: 0.8), 2));
    strokeGlow(canvas, Path()..moveTo(x - tilt, top + 6)..lineTo(x + tilt, bottom - 6), p.secondary,
        width: 1.5 + press * 4, glow: live);
    // Where the hair meets the string, pressed in by the pressure.
    canvas.drawCircle(Offset(x, cy + press * 3), 2.5 + press * 2.5, Paint()..color = p.secondary.withValues(alpha: 0.7));
    paintLabel(canvas, _place(p.value('position')), Offset(x, s.height * 0.2), Neon.dim, size: 7.5, align: 0);
  }

  /// The bow's x for [position] in a picture [s] wide (matching the drag: half the width over the whole range).
  static double bowX(double position, Size s) {
    final bridge = s.width * 0.9;
    return bridge - s.width * (0.05 + 0.5 * position.clamp(0.0, 1.0));
  }

  static String _place(double v) => v < 0.12 ? 'SUL PONT.' : v > 0.8 ? 'SUL TASTO' : v < 0.35 ? 'NEAR BRIDGE' : 'NORMAL';

  @override
  bool shouldRepaint(covariant NightingalePainter o) => true;
}

/// The cards' icons: the four bodies, growing, the cello and bass on an endpin.
void nightingaleIcon(Canvas canvas, Rect r, int k, Color c) {
  final line = instrumentLine(c, 1.4);
  final scale = 0.62 + k * 0.12;
  final h = r.height * scale, w = h * 0.46;
  final cx = r.center.dx, cy = r.center.dy - (k >= 2 ? r.height * 0.06 : 0);
  canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy - h * 0.2), width: w * (k == 3 ? 0.62 : 0.8), height: h * 0.42), line);
  canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy + h * 0.18), width: w, height: h * 0.48), line);
  canvas.drawLine(Offset(cx, cy - h * 0.62), Offset(cx, cy + h * 0.1), line);
  if (k >= 2) canvas.drawLine(Offset(cx, cy + h * 0.42), Offset(cx, r.bottom), line);
}
