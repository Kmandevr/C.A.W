// Curlew's page (org.caw.curlew, winds): the woodwind and brass cards in two rows, the instrument's body drawn live with its breath column (drag up and down for the breath) and the standing wave in its bore, and the Breath, Tone and Space panels.
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../kit/hero.dart';
import 'instrument_page.dart';

const curlewComponentId = 'org.caw.curlew';

/// Variant indices (engine/src/builtin_curlew.cpp).
abstract final class CurlewInstrument {
  static const flute = 0, clarinet = 1, sax = 2, trumpet = 3, trombone = 4, horn = 5, piccolo = 6, oboe = 7, tuba = 8;
  static const last = tuba;

  /// The lips' instruments (thinner tubing, valves, a big bell).
  static bool brass(int k) => k == trumpet || k == trombone || k == horn || k == tuba;

  /// Open at both ends (no bell, a whole wave over the bore).
  static bool flutes(int k) => k == flute || k == piccolo;
}

const curlewKnobs = ['breath', 'noise', 'reed', 'attack', 'vibrato', 'vib_rate', 'growl'];

final curlewSpec = InstrumentSpec(
  id: curlewComponentId,
  key: 'curlew',
  title: 'WINDS',
  icon: Icons.air,
  hint: 'Pick an instrument, then play: the bore sings with what sounds. Drag the picture up and down for the breath.',
  cardIcon: curlewIcon,
  cardNames: const ['Flute', 'Clarinet', 'Sax', 'Trumpet', 'Trombone', 'Horn', 'Piccolo', 'Oboe', 'Tuba'],
  // Woodwinds over brass (docs/decisions.md, 2026-11-26).
  cardRows: const [
    [CurlewInstrument.flute, CurlewInstrument.piccolo, CurlewInstrument.clarinet, CurlewInstrument.oboe, CurlewInstrument.sax],
    [CurlewInstrument.trumpet, CurlewInstrument.trombone, CurlewInstrument.horn, CurlewInstrument.tuba],
  ],
  drag: (t, variant, at, size) => const PictureDrag(y: 'breath', span: 0.8),
  painter: (p) => CurlewPainter(p),
  inlineKnobs: const ['breath', 'noise', 'reed', 'vibrato'],
  panels: [
    InstrumentPanel('Breath', (context, knob) => Builder(builder: (context) {
      // The third knob is the descriptor's own name for it: a jet on the flute, lips on brass, else a reed.
      return InstrumentOwnControls(prefix: 'curlew', order: curlewKnobs, knob: knob,
          labels: const {'breath': 'Breath', 'noise': 'Noise', 'growl': 'Growl'});
    })),
    InstrumentPanel('Tone', (context, knob) => instrumentKnobPanel(instrumentToneKnobs, knob)),
    InstrumentPanel('Space', (context, knob) => instrumentKnobPanel(instrumentSpaceKnobs, knob)),
  ],
);

/// The wind: its bore drawn as the instrument's shape (a straight flute and a short piccolo, the clarinet's bell, the
/// oboe's slant and small bell, the sax's curve, the trumpet's wrap, the trombone's slide, the horn's coil, the tuba's
/// big loop and upturned bell) with the standing wave inside while it sounds, and the
/// breath column at the mouthpiece filled to the breath (the engine's while it sounds), noisy with Breath noise.
class CurlewPainter extends CustomPainter {
  CurlewPainter(this.p);
  final InstrumentPicture p;

  @override
  void paint(Canvas canvas, Size s) {
    if (s.isEmpty) return;
    final k = p.variant.clamp(0, CurlewInstrument.last);
    final col = Rect.fromLTWH(s.width * 0.03, s.height * 0.2, s.width * 0.06, s.height * 0.72);
    final bore = curlewBore(k, Rect.fromLTRB(s.width * 0.14, s.height * 0.16, s.width * 0.97, s.height * 0.95));
    final width = s.height * (CurlewInstrument.brass(k) ? 0.045 : 0.07);
    canvas.drawPath(bore.path, instrumentLine(p.accent.withValues(alpha: 0.12 + 0.08 * p.value('body')), width * 2));
    canvas.drawPath(bore.path, instrumentLine(p.accent.withValues(alpha: 0.55), 1.3));
    // The bell (none on the flutes).
    if (!CurlewInstrument.flutes(k)) {
      final flare = s.height * switch (k) {
        CurlewInstrument.clarinet => 0.1,
        CurlewInstrument.oboe => 0.07,
        CurlewInstrument.horn => 0.17,
        CurlewInstrument.tuba => 0.24,
        _ => 0.2,
      };
      final b = bore.bell, d = bore.dir;
      final n = Offset(-d.dy, d.dx);
      final bell = Path()
        ..moveTo(b.dx - d.dx * flare * 0.9 + n.dx * width, b.dy - d.dy * flare * 0.9 + n.dy * width)
        ..quadraticBezierTo(b.dx + n.dx * width, b.dy + n.dy * width, b.dx + n.dx * flare, b.dy + n.dy * flare)
        ..lineTo(b.dx - n.dx * flare, b.dy - n.dy * flare)
        ..quadraticBezierTo(b.dx - n.dx * width, b.dy - n.dy * width, b.dx - d.dx * flare * 0.9 - n.dx * width,
            b.dy - d.dy * flare * 0.9 - n.dy * width)
        ..close();
      canvas.drawPath(bell, Paint()..color = p.accent.withValues(alpha: 0.1 + 0.25 * p.energy));
      canvas.drawPath(bell, instrumentLine(p.accent.withValues(alpha: 0.6), 1.3));
    }
    // Keys on the woodwinds, valves on the trumpet, horn and tuba.
    final metric = bore.path.computeMetrics().first;
    if (!CurlewInstrument.brass(k)) {
      for (var i = 0; i < 7; i++) {
        final at = metric.getTangentForOffset(metric.length * (0.3 + i * 0.075))!.position;
        canvas.drawCircle(at, width * 0.35, Paint()..color = Neon.bg);
        canvas.drawCircle(at, width * 0.35, instrumentLine(Neon.dim, 1));
      }
    } else if (k != CurlewInstrument.trombone) {
      for (var i = 0; i < 3; i++) {
        final at = metric.getTangentForOffset(metric.length * (0.42 + i * 0.05))!.position;
        canvas.drawRect(Rect.fromCenter(center: at - Offset(0, width * 1.2), width: width * 0.8, height: width * 1.6),
            Paint()..color = p.secondary.withValues(alpha: 0.6));
      }
    }
    // The standing wave along the bore while it sounds.
    if (p.energy > 0) _wave(canvas, metric, width, k);
    _column(canvas, col, bore.mouth);
  }

  void _wave(Canvas canvas, PathMetric m, double width, int k) {
    final path = Path();
    final ph = math.sin(p.seconds * 2 * math.pi * 3);
    // The flute is open at both ends (a whole wave over the bore), the reeds and lips closed at one (three quarters).
    final waves = CurlewInstrument.flutes(k) ? 2.0 : 1.5;
    const n = 60;
    for (var i = 0; i <= n; i++) {
      final u = i / n;
      final tan = m.getTangentForOffset(m.length * u)!;
      final nrm = Offset(-tan.vector.dy, tan.vector.dx);
      final at = tan.position + nrm * (width * 0.8 * p.swing * ph * math.cos(math.pi * u * waves));
      i == 0 ? path.moveTo(at.dx, at.dy) : path.lineTo(at.dx, at.dy);
    }
    strokeGlow(canvas, path, p.secondary, width: 1.4);
  }

  /// The breath column: a tube at the mouthpiece filled to the breath, its bubbles livelier with the breath noise.
  void _column(Canvas canvas, Rect r, Offset mouth) {
    final breath = (p.energy > 0 ? p.frame.own(1) : p.value('breath')).clamp(0.0, 1.0);
    final noise = p.value('noise').clamp(0.0, 1.0);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(r.width / 2));
    canvas.drawRRect(rr, Paint()..color = Neon.ink.withValues(alpha: 0.05));
    canvas.drawRRect(rr, instrumentLine(p.accent.withValues(alpha: 0.5), 1.2));
    final fill = Rect.fromLTRB(r.left + 2, r.bottom - (r.height - 4) * breath - 2, r.right - 2, r.bottom - 2);
    canvas.drawRRect(RRect.fromRectAndRadius(fill, Radius.circular(r.width / 2 - 2)),
        Paint()..color = p.accent.withValues(alpha: 0.3 + 0.4 * breath));
    final rnd = math.Random(5);
    for (var i = 0; i < 8; i++) {
      final u = (p.seconds * (0.4 + breath) + i / 8) % 1.0;
      final x = fill.center.dx + (rnd.nextDouble() - 0.5) * fill.width * (0.3 + noise);
      final y = fill.bottom - fill.height * u;
      if (y > fill.top) canvas.drawCircle(Offset(x, y), 1 + noise * 1.5, Paint()..color = Neon.ink.withValues(alpha: 0.35));
    }
    // The air going in at the top, to the mouthpiece.
    canvas.drawLine(Offset(r.center.dx, r.top), mouth, instrumentLine(p.accent.withValues(alpha: 0.25 + 0.5 * breath), 1.2));
    paintLabel(canvas, 'BREATH', Offset(r.center.dx, r.top - 7), Neon.dim, size: 7, align: 0);
  }

  @override
  bool shouldRepaint(covariant CurlewPainter o) => true;
}

/// An instrument's bore in [r]: its centre line from the mouthpiece to the bell, the bell's place and direction.
({Path path, Offset mouth, Offset bell, Offset dir}) curlewBore(int k, Rect r) {
  final p = Path();
  final cy = r.center.dy;
  switch (k) {
    case CurlewInstrument.flute:
      p..moveTo(r.left, cy)..lineTo(r.right, cy);
      return (path: p, mouth: Offset(r.left, cy), bell: Offset(r.right, cy), dir: const Offset(1, 0));
    case CurlewInstrument.piccolo:
      // Half the flute's length.
      final a = r.left + r.width * 0.2, b = r.right - r.width * 0.2;
      p..moveTo(a, cy)..lineTo(b, cy);
      return (path: p, mouth: Offset(a, cy), bell: Offset(b, cy), dir: const Offset(1, 0));
    case CurlewInstrument.oboe:
      // A slanting cone from the reed, a small bell at its foot.
      final y0 = cy - r.height * 0.12, y1 = cy + r.height * 0.12, x1 = r.right - r.width * 0.08;
      final d = Offset(x1 - r.left, y1 - y0);
      p..moveTo(r.left, y0)..lineTo(x1, y1);
      return (path: p, mouth: Offset(r.left, y0), bell: Offset(x1, y1), dir: d / d.distance);
    case CurlewInstrument.tuba:
      // The leadpipe into one big loop, then up the body into a bell pointing at the sky.
      final c = Offset(r.left + r.width * 0.42, cy + r.height * 0.1), rad = r.height * 0.32;
      final x = r.right - r.width * 0.16, top = r.top + r.height * 0.06;
      p
        ..moveTo(r.left, c.dy)
        ..lineTo(c.dx - rad, c.dy)
        ..arcTo(Rect.fromCircle(center: c, radius: rad), math.pi, math.pi * 1.5, false)
        ..lineTo(x, c.dy + rad)
        ..lineTo(x, top);
      return (path: p, mouth: Offset(r.left, c.dy), bell: Offset(x, top), dir: const Offset(0, -1));
    case CurlewInstrument.clarinet:
      p..moveTo(r.left, cy)..lineTo(r.right - r.width * 0.08, cy);
      return (path: p, mouth: Offset(r.left, cy), bell: Offset(r.right - r.width * 0.08, cy), dir: const Offset(1, 0));
    case CurlewInstrument.sax:
      // Down the body, round the bow and up into the bell.
      final y0 = r.top + r.height * 0.15, y1 = r.bottom - r.height * 0.12;
      p
        ..moveTo(r.left, y0)
        ..lineTo(r.left + r.width * 0.55, y0 + r.height * 0.18)
        ..quadraticBezierTo(r.left + r.width * 0.75, y1 + r.height * 0.05, r.left + r.width * 0.83, y1 - r.height * 0.2)
        ..lineTo(r.left + r.width * 0.86, r.top + r.height * 0.3);
      return (path: p, mouth: Offset(r.left, y0), bell: Offset(r.left + r.width * 0.86, r.top + r.height * 0.3), dir: const Offset(0.1, -1));
    case CurlewInstrument.trumpet:
      // The leadpipe, one wrap and the bell out to the right.
      final a = r.top + r.height * 0.35, b = r.bottom - r.height * 0.2;
      p
        ..moveTo(r.left, a)
        ..lineTo(r.left + r.width * 0.6, a)
        ..arcToPoint(Offset(r.left + r.width * 0.6, b), radius: Radius.circular((b - a) / 2))
        ..lineTo(r.left + r.width * 0.25, b)
        ..arcToPoint(Offset(r.left + r.width * 0.25, (a + b) / 2), radius: Radius.circular((b - a) / 4))
        ..lineTo(r.right - r.width * 0.1, (a + b) / 2);
      return (path: p, mouth: Offset(r.left, a), bell: Offset(r.right - r.width * 0.1, (a + b) / 2), dir: const Offset(1, 0));
    case CurlewInstrument.trombone:
      // The slide out and back, then the bell.
      final a = r.top + r.height * 0.3, b = r.bottom - r.height * 0.25;
      p
        ..moveTo(r.left, a)
        ..lineTo(r.right - r.width * 0.05, a)
        ..arcToPoint(Offset(r.right - r.width * 0.05, b), radius: Radius.circular((b - a) / 2))
        ..lineTo(r.left + r.width * 0.25, b);
      return (path: p, mouth: Offset(r.left, a), bell: Offset(r.left + r.width * 0.25, b), dir: const Offset(-1, 0));
    default:
      // The horn's coil, the bell out at the lower right.
      final c = Offset(r.left + r.width * 0.42, cy), rad = r.height * 0.36;
      p.moveTo(r.left, cy - rad);
      p.lineTo(c.dx, cy - rad);
      p.arcTo(Rect.fromCircle(center: c, radius: rad), -math.pi / 2, math.pi * 1.6, false);
      p.arcTo(Rect.fromCircle(center: c, radius: rad * 0.7), math.pi * 1.1, math.pi * 1.2, false);
      p.lineTo(r.right - r.width * 0.12, r.bottom - r.height * 0.18);
      return (path: p, mouth: Offset(r.left, cy - rad), bell: Offset(r.right - r.width * 0.12, r.bottom - r.height * 0.18),
          dir: const Offset(0.8, 0.6));
  }
}

/// The cards' icons: each instrument's bore drawn small.
void curlewIcon(Canvas canvas, Rect r, int k, Color c) {
  final b = curlewBore(k, Rect.fromCenter(center: r.center, width: r.height * 1.6, height: r.height));
  canvas.drawPath(b.path, instrumentLine(c, CurlewInstrument.brass(k) ? 1.3 : 2.2));
  if (!CurlewInstrument.flutes(k)) canvas.drawCircle(b.bell, r.height * (k == CurlewInstrument.oboe ? 0.09 : 0.14), Paint()..color = c);
}
