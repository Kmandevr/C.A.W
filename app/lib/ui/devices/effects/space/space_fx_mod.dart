// The fx-space modulation UIs: ensemble voices, doubler takes, vibrato's pitch, tremolo and auto-pan shapes, and the rotary's spinning horn and drum.
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
import '../mod_editors.dart' show modRateHz;
import 'space_fx.dart';

/// The LFO shapes of tremolo and auto-pan (sine, triangle, saws, square, sample & hold, smooth random), −1..1 at
/// phase [x] in 0..1.
double lfoShape(int shape, double x) {
  final t = x - x.floorToDouble();
  double rand(int k) => (math.sin(k * 12.9898) * 43758.5453) % 1 * 2 - 1;
  switch (shape) {
    case 1: return t < 0.25 ? 4 * t : (t < 0.75 ? 2 - 4 * t : 4 * t - 4);
    case 2: return 2 * t - 1;
    case 3: return 1 - 2 * t;
    case 4: return t < 0.5 ? 1 : -1;
    case 5: return rand(x.floor());
    case 6:
      final s = t * t * (3 - 2 * t);
      return rand(x.floor()) + (rand(x.floor() + 1) - rand(x.floor())) * s;
    default: return math.sin(2 * math.pi * t);
  }
}

void _shapeIcon(Canvas canvas, Rect r, int index, Color color) => iconCurve(canvas, r, color, (x) => lfoShape(index, (x + 1) / 2 * 2));

/// The ensemble: its voices as dots across the stereo field, each swaying with its own LFO (phases spread), on a
/// pad of spread (sideways) and detune (up); voices and motion, then delay, rate, tone and mix.
class EnsemblePage extends StatelessWidget {
  const EnsemblePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final voices = t.value('voices').round() + 2;
    return effectPage('ensemble', [
      HeroWithMeters(height: 200, gr: false, hero: DevicePhase(builder: (context, secs) => XYPad(
        xParam: 'spread', yParam: 'detune', height: 200, caption: 'ENSEMBLE',
        painter: (dot) => _VoicesPainter(secs: secs, voices: voices, spread: t.value('spread'), detune: t.value('detune'),
            rate: t.value('rate'), color: scope.accent, second: scope.secondary)))),
      spaceRow('VOICES', const DeviceChoice('voices', maxSegments: 7)),
      Padding(padding: const EdgeInsets.only(top: 8), child: ModeTiles('motion', icon: (c, r, i, col) => iconCurve(c, r, col,
          (x) => i == 3 ? 0.7 * math.sin(math.pi * x) + 0.3 * math.sin(6 * math.pi * x) : lfoShape(i == 1 ? 1 : (i == 2 ? 6 : 0), (x + 1) / 2 * 2)))),
      const KnobRow(['delay', 'rate', 'tone', 'mix'], size: 52),
    ]);
  }
}

class _VoicesPainter extends CustomPainter {
  _VoicesPainter({required this.secs, required this.voices, required this.spread, required this.detune, required this.rate,
    required this.color, required this.second});
  final double secs, spread, detune, rate;
  final int voices;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawLine(Offset(w / 2, 20), Offset(w / 2, h - 8), Paint()..color = Neon.ink.withAlpha(0x1F));
    paintLabel(canvas, 'L', Offset(10, h - 12), color, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(w - 10, h - 12), second, size: 9, align: 1, weight: FontWeight.w800);
    for (var v = 0; v < voices; v++) {
      final place = voices == 1 ? 0.0 : 2 * v / (voices - 1) - 1;
      final pan = spread * place;
      final sway = math.sin(2 * math.pi * (secs * rate + v / voices));
      final x = w / 2 + pan * (w / 2 - 20);
      final y = h / 2 + sway * (h / 2 - 30) * (detune / 50).clamp(0.05, 1.0);
      final c = Color.lerp(color, second, (pan + 1) / 2)!;
      canvas.drawCircle(Offset(x, y), 10, Paint()..color = c.withValues(alpha: 0.18));
      canvas.drawCircle(Offset(x, y), 5, Paint()..color = c);
      canvas.drawLine(Offset(x, h / 2), Offset(x, y), Paint()
        ..color = c.withValues(alpha: 0.4)
        ..strokeWidth = 1.5);
    }
    paintLabel(canvas, '$voices voices · ±${detune.round()} ct', Offset(w - 8, 30), Neon.text, size: 9, align: 1);
  }

  @override
  bool shouldRepaint(covariant _VoicesPainter o) =>
      paintInputsChanged([o.secs, o.spread, o.detune, o.rate, o.voices, o.color, o.second], [secs, spread, detune, rate, voices, color, second]);
}

/// The doubler: the dry in the middle and its doubles as late, slightly detuned copies to the sides (their
/// distance from the dry is their delay), on a pad of width (sideways) and detune (up).
class DoublerPage extends StatelessWidget {
  const DoublerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('doubler', [
      HeroWithMeters(height: 190, gr: false, hero: DeviceDisplay(builder: (context, f) => DevicePhase(builder: (context, secs) => XYPad(
        xParam: 'width', yParam: 'detune', height: 190, caption: 'DOUBLER',
        painter: (dot) => _TakesPainter(secs: secs, count: t.value('voices') >= 0.5 ? 4 : 2, width: t.value('width'),
            delay: t.value('delay'), drift: t.value('drift'), live: f?.values, color: scope.accent, second: scope.secondary))))),
      spaceRow('DOUBLES', const DeviceChoice('voices', maxSegments: 2)),
      const KnobRow(['delay', 'drift', 'mix'], size: 54),
      const KnobRow(['low_cut', 'high_cut'], size: 46),
    ]);
  }
}

class _TakesPainter extends CustomPainter {
  _TakesPainter({required this.secs, required this.count, required this.width, required this.delay, required this.drift,
    required this.live, required this.color, required this.second});
  final double secs, width, delay, drift;
  final int count;
  final Map<String, double>? live;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const kPan = [-1.0, 1.0, -0.5, 0.5], kTime = [1.0, 1.37, 0.62, 1.81];
    // Time runs down the canvas: the dry starts at the top, each double lower by its delay (up to 110 ms).
    double yOf(double ms) => 26 + (h - 40) * (ms / 110).clamp(0.0, 1.0);
    void take(double pan, double ms, Color c, double r) {
      final x = w / 2 + pan * (w / 2 - 24);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, yOf(ms) + 10), width: 36, height: 20),
          const Radius.circular(6)), Paint()..color = c.withValues(alpha: 0.25));
      canvas.drawCircle(Offset(x, yOf(ms) + 10), r, Paint()..color = c);
    }
    take(0, 0, Neon.text, 4);
    for (var v = 0; v < count; v++) {
      final ms = live?['double$v'] ?? delay * kTime[v] + 3 * drift * math.sin(secs * (0.7 + 0.3 * v) + v);
      take(kPan[v] * width, ms, Color.lerp(color, second, (kPan[v] + 1) / 2)!, 5);
      paintLabel(canvas, '${ms.round()} ms', Offset(w / 2 + kPan[v] * width * (w / 2 - 24), yOf(ms) + 28), Neon.dim, size: 8, align: 0);
    }
    paintLabel(canvas, 'DRY', Offset(w / 2, yOf(0) + 28), Neon.dim, size: 8, align: 0, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _TakesPainter o) =>
      paintInputsChanged([o.secs, o.width, o.delay, o.drift, o.count, o.live, o.color, o.second], [secs, width, delay, drift, count, live, color, second]);
}

/// The vibrato: the pitch over two seconds (up to ±depth cents), left and right, on a pad of rate and depth.
class VibratoPage extends StatelessWidget {
  const VibratoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final shape = t.value('shape').round();
    return effectPage('vibrato', [
      HeroWithMeters(height: 190, gr: false, hero: DevicePhase(builder: (context, secs) => XYPad(
        xParam: 'rate', yParam: 'depth', height: 190, caption: 'PITCH',
        painter: (dot) => _WavePainter(secs: secs, rate: modRateHz(scope), depth: t.value('depth') / 100, stereo: t.value('stereo'),
            shape: shape == 1 ? 1 : (shape == 2 ? 6 : 0), color: scope.accent, second: scope.secondary,
            label: '±${t.value('depth').round()} ct')))),
      Row(children: [
        spaceLabel('SYNC'),
        const DeviceChoice('sync', maxSegments: 0),
        const SizedBox(width: 10),
        const Flexible(child: DeviceChoice('shape', maxSegments: 3)),
      ]),
      const KnobRow(['stereo', 'mix'], size: 54),
    ]);
  }
}

/// A modulation's curve over the last two seconds (newest at the right), left and right (`stereo` x half a cycle
/// apart), [depth] 0..1 of the half height.
class _WavePainter extends CustomPainter {
  _WavePainter({required this.secs, required this.rate, required this.depth, required this.stereo, required this.shape,
    required this.color, required this.second, required this.label});
  final double secs, rate, depth, stereo;
  final int shape;
  final Color color, second;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, mid = h * 0.55, amp = (h * 0.36) * depth.clamp(0.0, 1.0);
    canvas.drawLine(Offset(0, mid), Offset(w, mid), Paint()..color = Neon.ink.withAlpha(0x1A));
    for (final (off, c) in [(0.0, color), (stereo * 0.5, second)]) {
      final p = Path();
      for (var i = 0; i <= 160; i++) {
        final x = w * i / 160;
        final tt = secs - 2 * (1 - i / 160);
        final yy = mid - amp * lfoShape(shape, tt * rate - off);
        i == 0 ? p.moveTo(x, yy) : p.lineTo(x, yy);
      }
      strokeGlow(canvas, p, c, width: 2, glow: c == color);
    }
    paintLabel(canvas, label, Offset(w - 8, h - 10), Neon.text, size: 9, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _WavePainter o) =>
      paintInputsChanged([o.secs, o.rate, o.depth, o.stereo, o.shape, o.color, o.second, o.label], [secs, rate, depth, stereo, shape, color, second, label]);
}

/// Tremolo ([pan] false: the level, dipping by depth) and auto-pan ([pan] true: a dot swinging between the sides),
/// on a pad of rate (sideways; free only) and depth (up); shape tiles, sync, then smooth and the rest.
class TremoloPage extends StatelessWidget {
  const TremoloPage({super.key, required this.pan});
  final bool pan;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final shape = t.value('shape').round();
    final hz = modRateHz(scope);
    return effectPage(pan ? 'autopan' : 'tremolo', [
      HeroWithMeters(height: 190, gr: false, hero: DeviceDisplay(builder: (context, f) => DevicePhase(builder: (context, secs) => XYPad(
        xParam: 'rate', yParam: 'depth', height: 190, caption: pan ? 'AUTO-PAN' : 'TREMOLO',
        painter: (dot) => pan
            ? _PanPainter(secs: secs, rate: hz, depth: t.value('depth'), shape: shape, offset: t.value('offset'),
                live: f?.values, color: scope.accent, second: scope.secondary)
            : _WavePainter(secs: secs, rate: hz, depth: t.value('depth'), stereo: t.value('stereo'), shape: shape,
                color: scope.accent, second: scope.secondary, label: '${hz.toStringAsFixed(2)} Hz'))))),
      Padding(padding: const EdgeInsets.only(bottom: 6), child: ModeTiles('shape', icon: _shapeIcon, height: 48,
          names: const ['Sine', 'Tri', 'Up', 'Down', 'Sq', 'S&H', 'Rnd'])),
      Row(children: [
        spaceLabel('SYNC'),
        const DeviceChoice('sync', maxSegments: 0),
        if (!pan) ...[const SizedBox(width: 10), const Flexible(child: DeviceChoice('mode', maxSegments: 2))],
      ]),
      KnobRow(pan ? const ['smooth', 'offset', 'width'] : const ['smooth', 'stereo'], size: 52),
    ]);
  }
}

class _PanPainter extends CustomPainter {
  _PanPainter({required this.secs, required this.rate, required this.depth, required this.shape, required this.offset,
    required this.live, required this.color, required this.second});
  final double secs, rate, depth, offset;
  final int shape;
  final Map<String, double>? live;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final arc = Rect.fromCenter(center: Offset(w / 2, h + 10), width: w - 30, height: (h - 20) * 2);
    canvas.drawArc(arc, math.pi, math.pi, false, Paint()
      ..color = Neon.ink.withAlpha(0x1F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    paintLabel(canvas, 'L', Offset(10, h - 12), color, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(w - 10, h - 12), second, size: 9, align: 1, weight: FontWeight.w800);
    // A trail of the last half second, then the dot now (the engine's LFO while it plays).
    for (var k = 12; k >= 0; k--) {
      final tt = secs - k * 0.04;
      final v = k == 0 && live?['lfo_l'] != null ? live!['lfo_l']! : lfoShape(shape, tt * rate + offset);
      final a = math.pi * 1.5 + depth.clamp(0.0, 1.0) * v * math.pi / 2;
      final at = arc.center + Offset(math.cos(a) * arc.width / 2, math.sin(a) * arc.height / 2);
      final c = Color.lerp(color, second, (v * depth + 1) / 2)!;
      canvas.drawCircle(at, k == 0 ? 8 : 5 - k * 0.3, Paint()..color = c.withValues(alpha: k == 0 ? 1 : 0.5 - k * 0.035));
    }
  }

  @override
  bool shouldRepaint(covariant _PanPainter o) =>
      paintInputsChanged([o.secs, o.rate, o.depth, o.offset, o.shape, o.live, o.color, o.second], [secs, rate, depth, offset, shape, live, color, second]);
}

/// The rotary speaker from above: the horn (outer, its two bells) and the drum (inner, a slotted baffle) spinning at
/// the engine's speeds (≈ from the speed choice when it isn't playing), the two mics either side; tap it to switch
/// Slow and Fast, the speed tiles for Brake; then inertia, horn/drum, drive, mic width, doppler and mix.
class RotaryPage extends StatelessWidget {
  const RotaryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final speed = t.value('speed').round();
    return effectPage('rotary', [
      HeroWithMeters(height: 200, gr: false, hero: liveHero(context: context, caption: 'ROTARY', height: 200,
        readout: Text(const ['CHORALE', 'TREMOLO', 'BRAKE'][speed.clamp(0, 2)]),
        builder: (context, secs, v) => GestureDetector(
          key: const ValueKey('rotary-hero'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            DeviceFeel.tap();
            t.set('speed', speed == 1 ? 0 : 1);
          },
          child: CustomPaint(size: Size.infinite, painter: _RotorPainter(
            horn: v?['horn_angle'] ?? secs * const [0.83, 6.75, 0.0][speed.clamp(0, 2)],
            drum: v?['drum_angle'] ?? 0.25 + secs * const [0.67, 5.8, 0.0][speed.clamp(0, 2)],
            width: t.value('width'), color: scope.accent, second: scope.secondary))))),
      ModeTiles('speed', height: 46, icon: (c, r, i, col) => iconCurve(c, r, col,
          (x) => i == 2 ? -x * 0.8 : 0.8 * math.sin(math.pi * x * (i == 0 ? 1 : 4)))),
      const KnobRow(['accel', 'balance', 'drive', 'width', 'doppler', 'mix'], size: 48),
    ]);
  }
}

class _RotorPainter extends CustomPainter {
  _RotorPainter({required this.horn, required this.drum, required this.width, required this.color, required this.second});
  final double horn, drum, width;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2 + 8);
    final r = math.min(size.width, size.height) / 2 - 22;
    canvas.drawCircle(c, r + 6, Paint()..color = Neon.ink.withValues(alpha: 0.04));
    // The drum: a disc with a slot.
    final da = 2 * math.pi * drum;
    canvas.drawCircle(c, r * 0.45, Paint()..color = second.withValues(alpha: 0.18));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.45), da - 0.6, 1.2, true, Paint()..color = second.withValues(alpha: 0.55));
    // The horn: two bells on a bar, one open (it sounds), one a dummy.
    final ha = 2 * math.pi * horn;
    final tip = c + Offset(math.cos(ha), math.sin(ha)) * r, back = c - Offset(math.cos(ha), math.sin(ha)) * r * 0.85;
    canvas.drawLine(back, tip, Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round);
    final bell = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + math.cos(ha + 2.6) * 18, tip.dy + math.sin(ha + 2.6) * 18)
      ..lineTo(tip.dx + math.cos(ha - 2.6) * 18, tip.dy + math.sin(ha - 2.6) * 18)
      ..close();
    canvas.drawPath(bell, Paint()..color = color);
    canvas.drawCircle(c, 5, Paint()..color = Neon.text);
    // The mics, `width` x 90 degrees either side of the front (the bottom).
    for (final s in [-1, 1]) {
      final a = math.pi / 2 - s * width * math.pi / 2;
      final m = c + Offset(math.cos(a), math.sin(a)) * (r + 14);
      paintHandle(canvas, m, s < 0 ? color : second, r: 5, label: s < 0 ? 'L' : 'R');
    }
  }

  @override
  bool shouldRepaint(covariant _RotorPainter o) =>
      paintInputsChanged([o.horn, o.drum, o.width, o.color, o.second], [horn, drum, width, color, second]);
}
