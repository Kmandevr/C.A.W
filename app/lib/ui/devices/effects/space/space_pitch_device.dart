// The Pitch/Shift merged device's page: Pitch (the spectrum before and after, a semitone dial and a fine knob), Frequency (the partials moved by the same hertz), Harmonizer and Octaver (space_voice_modes.dart), as cards.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../creative/pitch_editors.dart' show ShiftHero;
import '../effect_page.dart';
import 'space_devices.dart';
import 'space_voice_modes.dart';

/// Pitch/Shift: Pitch and Frequency as cards. Pitch: a harmonic series before (grey) and after the shift (drag
/// sideways: whole semitones with a tick, a second finger for cents), a ±24 semitone ruler under it, then the
/// semitone dial and the fine (cents) knob, grain and jitter under MORE. Frequency: the partials each moved by the
/// same hertz, the direction, then Shift in Hz, spread and feedback.
class ShiftDevicePage extends StatelessWidget {
  const ShiftDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = variantOf(context);
    final pitch = variant == 0;
    final cards = VariantCards(height: 48, icon: (c, r, i, col) {
      if (i >= 2) return _voiceIcon(c, r, i, col);
      for (var k = 1; k <= 4; k++) {
        final x = r.left + r.width * (i == 0 ? math.log(k) / math.log(5) * 0.8 + 0.08 : 0.08 + 0.2 * (k - 1) + 0.06);
        c.drawLine(Offset(x, r.bottom), Offset(x, r.bottom - r.height * (1.1 - k * 0.2)), Paint()
          ..color = col
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);
      }
    });
    if (variant == 2) return HarmonizerPage(cards: cards);
    if (variant == 3) return OctaverPage(cards: cards);
    if (!pitch) {
      return mergedPage(context, 'shift',
        cards: cards,
        hero: HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
          color: scope.accent,
          height: 190,
          caption: 'PARTIALS ≈',
          grid: false,
          readout: Builder(builder: (context) => Text('${t.value('shift') >= 0 ? '+' : ''}${t.value('shift').toStringAsFixed(1)} Hz')),
          child: const ShiftHero(),
        )),
        rows: [controlsRow([smallLabel('DIRECTION'), const DeviceChoice('direction', maxSegments: 3)])],
        knobs: const KnobRow(['shift', 'spread', 'feedback'], size: 52, labels: {'spread': 'Spread'}),
        more: const KnobRow(['delay'], size: 42, labels: {'delay': 'FB delay'}),
      );
    }
    return mergedPage(context, 'shift',
      cards: cards,
      hero: HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: 'SPECTRUM ≈',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final s = t.value('semitones') + t.value('cents') / 100;
          final latency = f?.values['latency_ms'] ?? t.value('grain') / 2;
          return Text('${s >= 0 ? '+' : ''}${s.toStringAsFixed(2)} st · ${latency.toStringAsFixed(1)} ms');
        }),
        child: const _SpectrumHero(),
      )),
      knobs: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        DeviceKnob('semitones', size: 76, label: 'Semitones', color: scope.accent),
        const DeviceKnob('cents', size: 46, label: 'Fine'),
      ]),
      more: const ParamGrid(only: ['grain', 'jitter']),
    );
  }
}

/// The Harmonizer's card (three stacked notes) and the Octaver's (a bar an octave under and over).
void _voiceIcon(Canvas c, Rect r, int i, Color col) {
  final p = Paint()..color = col;
  if (i == 2) {
    for (var k = 0; k < 3; k++) {
      c.drawCircle(Offset(r.left + r.width * (0.3 + 0.2 * k), r.bottom - r.height * (0.2 + 0.3 * k)), 3.2, p);
    }
    return;
  }
  for (final (x, h) in [(0.25, 0.9), (0.5, 0.6), (0.75, 0.45)]) {
    c.drawLine(Offset(r.left + r.width * x, r.bottom), Offset(r.left + r.width * x, r.bottom - r.height * h), Paint()
      ..color = x == 0.5 ? col.withValues(alpha: 0.5) : col
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
  }
}

class _SpectrumHero extends StatefulWidget {
  const _SpectrumHero();

  @override
  State<_SpectrumHero> createState() => _SpectrumHeroState();
}

class _SpectrumHeroState extends State<_SpectrumHero> {
  bool _active = false;
  double _at = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('pitchshift-hero'),
        onStart: (_, _) {
          _at = t.value('semitones') + t.value('cents') / 100;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          _at = (_at + u.delta.dx / (w - 24) * 48 * fine).clamp(-24.0, 24.0);
          final whole = fine < 1 ? _at.truncateToDouble() : _at.roundToDouble();
          if (whole != t.value('semitones')) DeviceFeel.detent();
          t.setLive('semitones', whole);
          t.setLive('cents', fine < 1 ? ((_at - whole) * 100).clamp(-100.0, 100.0) : 0);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({'semitones': 0, 'cents': 0}),
        child: CustomPaint(size: Size(w, h), painter: SpectrumShiftPainter(
          semis: t.value('semitones') + t.value('cents') / 100,
          live: f?.values['semitones_now'],
          color: scope.accent,
          second: Neon.yellow,
          active: _active)),
      ));
    });
  }
}

/// A 110 Hz harmonic series on a log axis (50 Hz .. 8 kHz), before the shift in grey and after it (each partial
/// times 2^(st/12)) in [color]; a ±24 semitone ruler under it with the shift as a handle, the jittered pitch now
/// (the engine's) as a dot.
class SpectrumShiftPainter extends CustomPainter {
  SpectrumShiftPainter({required this.semis, required this.live, required this.color, required this.second,
    required this.active});
  final double semis;
  final double? live;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const x0 = 12.0;
    final x1 = w - 12, top = 26.0, base = h - 46;
    double x(double hz) => x0 + (math.log(hz.clamp(50.0, 8000.0) / 50) / math.log(160)) * (x1 - x0);
    for (final (hz, l) in [(100.0, '100'), (1000.0, '1k'), (5000.0, '5k')]) {
      canvas.drawLine(Offset(x(hz), top), Offset(x(hz), base), Paint()..color = Neon.ink.withValues(alpha: 0.05));
      paintLabel(canvas, l, Offset(x(hz) + 3, top + 2), Neon.dim, size: 8);
    }
    final ratio = math.pow(2, semis / 12).toDouble();
    for (var k = 1; k <= 16; k++) {
      final hz = 110.0 * k, level = 1 / math.sqrt(k);
      final hh = (base - top - 12) * level;
      canvas.drawLine(Offset(x(hz) - 1.5, base), Offset(x(hz) - 1.5, base - hh), Paint()
        ..color = Neon.dim.withValues(alpha: 0.45)
        ..strokeWidth = 2);
      final to = hz * ratio;
      if (to < 50 || to > 8000) continue;
      strokeGlow(canvas, Path()..moveTo(x(to) + 1.5, base)..lineTo(x(to) + 1.5, base - hh * 0.95), color,
          width: active ? 2.6 : 2, glow: k < 5);
    }
    canvas.drawLine(Offset(x0, base), Offset(x1, base), Paint()..color = Neon.ink.withAlpha(0x26));
    paintLabel(canvas, 'BEFORE', Offset(x0, base + 9), Neon.dim, size: 7, weight: FontWeight.w800);
    paintLabel(canvas, 'AFTER', Offset(x0 + 44, base + 9), color, size: 7, weight: FontWeight.w800);
    // The ruler: ±24 semitones.
    final ry = h - 16;
    double sx(double s) => x0 + (s + 24) / 48 * (x1 - x0);
    for (var s = -24; s <= 24; s++) {
      final major = s % 12 == 0;
      final len = major ? 12.0 : (s % 12 == 7 || s % 12 == -5 ? 8.0 : 4.0);
      canvas.drawLine(Offset(sx(s.toDouble()), ry - len / 2), Offset(sx(s.toDouble()), ry + len / 2), Paint()
        ..color = (major ? Neon.text : Neon.dim).withValues(alpha: major ? 0.55 : 0.3));
    }
    strokeGlow(canvas, Path()..moveTo(sx(0), ry)..lineTo(sx(semis.clamp(-24.0, 24.0)), ry), color, width: 3.5);
    paintHandle(canvas, Offset(sx(semis.clamp(-24.0, 24.0)), ry), color, active: active, r: 6.5);
    if (live case final s? when (s - semis).abs() > 0.01) {
      canvas.drawCircle(Offset(sx(s.clamp(-24.0, 24.0)), ry - 11), 2.8, Paint()..color = second);
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumShiftPainter o) =>
      paintInputsChanged([o.semis, o.live, o.color, o.second, o.active], [semis, live, color, second, active]);
}
