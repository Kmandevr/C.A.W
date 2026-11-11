// The fx-space stereo UIs: Haas (the two sides' arrivals and the mono comb), the imager (band widths over a vectorscope) and the channel mixer's matrix.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../visuals/filter_curve.dart' show freqToX;
import '../effect_page.dart';
import 'space_fx.dart';

/// Haas: the left and right arrivals on a 0–40 ms line (the delayed side's level as its height), and what the mono
/// sum does (its comb, the notches marked), on a pad of delay (sideways) and the delayed side's level (up); the side,
/// Mono check, then the bass guard and mix, and the correlation and mono loss meters.
class HaasPage extends StatelessWidget {
  const HaasPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('haas', [
      HeroWithMeters(height: 200, gr: false, hero: XYPad(
        xParam: 'delay', yParam: 'level', height: 200, caption: 'HAAS',
        painter: (dot) => _HaasPainter(delay: t.value('delay'), level: t.value('level'), right: t.value('side') >= 0.5,
            guard: t.value('guard'), color: scope.accent, second: scope.secondary))),
      Row(children: [
        spaceLabel('DELAY'),
        const Flexible(child: DeviceChoice('side', maxSegments: 2)),
        const SizedBox(width: 8),
        const DeviceToggle('mono_check', label: 'Mono check', icon: Icons.speaker_phone_outlined),
      ]),
      const KnobRow(['guard', 'mix'], size: 54),
      DeviceDisplay(builder: (context, f) => Column(mainAxisSize: MainAxisSize.min, children: [
        SpaceBar(label: 'CORRELATION', value: f?.values['correlation']),
        SpaceBar(label: 'MONO LOSS', value: f?.values['mono_loss_db'], lo: -12, hi: 0, centred: false,
            text: f == null ? '—' : '${(f.values['mono_loss_db'] ?? 0).toStringAsFixed(1)} dB'),
      ])),
    ]);
  }
}

class _HaasPainter extends CustomPainter {
  _HaasPainter({required this.delay, required this.level, required this.right, required this.guard, required this.color,
    required this.second});
  final double delay, level, guard;
  final bool right;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Top half: the arrivals on 0..40 ms.
    final base = h * 0.48;
    double x(double ms) => 14 + (w - 28) * ms / 40;
    canvas.drawLine(Offset(14, base), Offset(w - 14, base), Paint()..color = Colors.white12);
    final g = math.pow(10, level / 20).toDouble();
    void spike(double ms, double height, Color c, String label) {
      canvas.drawLine(Offset(x(ms), base), Offset(x(ms), base - height), Paint()
        ..color = c
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round);
      paintLabel(canvas, label, Offset(x(ms), base - height - 8), c, size: 9, align: 0, weight: FontWeight.w800);
    }
    spike(0, 50, right ? color : second, right ? 'L' : 'R');
    spike(delay, 50 * g.clamp(0.2, 1.6), right ? second : color, right ? 'R' : 'L');
    // Bottom half: the mono sum's response, 1 + g e^{-jwd}, on a log axis; below the guard it stays flat.
    final top = h * 0.58, bottom = h - 12;
    final p = Path();
    for (var i = 0; i <= 200; i++) {
      final xx = w * i / 200;
      final hz = 20 * math.pow(1000, i / 200).toDouble();
      final ph = 2 * math.pi * hz * delay / 1000;
      final m = hz < guard ? (1 + g) : math.sqrt((1 + g * math.cos(ph)) * (1 + g * math.cos(ph)) + g * g * math.sin(ph) * math.sin(ph));
      final db = 20 * math.log(math.max(1e-3, m / (1 + g))) / math.ln10;
      final yy = top + (bottom - top) * (-db / 24).clamp(0.0, 1.0);
      i == 0 ? p.moveTo(xx, yy) : p.lineTo(xx, yy);
    }
    strokeGlow(canvas, p, Neon.pink.withValues(alpha: 0.8), width: 1.4, glow: false);
    paintLabel(canvas, 'MONO SUM', Offset(10, top - 2), Neon.dim, size: 8);
    if (delay > 0.05) paintLabel(canvas, 'first notch ${(500 / delay).round()} Hz', Offset(w - 8, top - 2), Neon.dim, size: 8, align: 1);
    if (guard > 20.5) {
      final gx = freqToX(guard, w);
      canvas.drawLine(Offset(gx, top), Offset(gx, bottom), Paint()..color = Neon.yellow.withValues(alpha: 0.4));
    }
  }

  @override
  bool shouldRepaint(covariant _HaasPainter o) => true;
}

/// The imager: the vectorscope of the output (mid up, side across: a vertical line is mono, a wide blob is wide), with
/// the three bands' widths as columns you drag up and down over it; the crossovers, mid, side and output, and the
/// correlation of each band.
class ImagerPage extends StatelessWidget {
  const ImagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('imager', [
      HeroWithMeters(height: 220, gr: false, hero: liveHero(context: context, caption: 'IMAGE', height: 220,
          readout: const Text('drag a band'), builder: (context, secs, v) => _ImagerHero(values: v))),
      const KnobRow(['low_freq', 'high_freq', 'mid_gain', 'side_gain', 'output'], size: 48),
      DeviceDisplay(builder: (context, f) => Column(mainAxisSize: MainAxisSize.min, children: [
        SpaceBar(label: 'CORRELATION', value: f?.values['correlation']),
        SpaceBar(label: 'LOW', value: f?.values['corr_low']),
        SpaceBar(label: 'MID', value: f?.values['corr_mid']),
        SpaceBar(label: 'HIGH', value: f?.values['corr_high']),
        SpaceBar(label: 'BALANCE', value: f?.values['balance']),
      ])),
      KnobRow(const ['low_width', 'mid_width', 'high_width'], size: 44, color: scope.secondary),
    ]);
  }
}

class _ImagerHero extends StatefulWidget {
  const _ImagerHero({required this.values});
  final Map<String, double>? values;

  @override
  State<_ImagerHero> createState() => _ImagerHeroState();
}

class _ImagerHeroState extends State<_ImagerHero> {
  static const _bands = ['low_width', 'mid_width', 'high_width'];
  int? _band;
  double _v = 1;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      int bandAt(Offset p) => (p.dx / w * 3).floor().clamp(0, 2);
      return GrabGesture(
        key: const ValueKey('imager-hero'),
        onStart: (p, _) {
          _band = bandAt(p);
          _v = t.value(_bands[_band!]);
          setState(() {});
        },
        onUpdate: (u) {
          final b = _band;
          if (b == null) return;
          final before = _v;
          _v = (_v - u.delta.dy / (h * 0.8) * 2 * DeviceFingers.fine).clamp(0.0, 2.0);
          if ((before - 1) * (_v - 1) <= 0 && before != 1) DeviceFeel.detent();
          t.setLive(_bands[b], (_v - 1).abs() < 0.02 ? 1 : _v);
        },
        onEnd: () {
          t.commit();
          setState(() => _band = null);
        },
        onDoubleTap: (p) => t.set(_bands[bandAt(p)], 1),
        child: CustomPaint(size: Size(w, h), painter: _ImagerPainter(
          widths: [for (final b in _bands) t.value(b)], active: _band, values: widget.values,
          freqs: [t.value('low_freq'), t.value('high_freq')], color: scope.accent, second: scope.secondary)),
      );
    });
  }
}

class _ImagerPainter extends CustomPainter {
  _ImagerPainter({required this.widths, required this.active, required this.values, required this.freqs, required this.color,
    required this.second});
  final List<double> widths, freqs;
  final int? active;
  final Map<String, double>? values;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // The vectorscope, centred: side across, mid up; the points' extent normalised to the canvas.
    final v = values;
    final c = Offset(w / 2, h / 2 + 6);
    final r = math.min(w, h) / 2 - 18;
    for (final k in [0.5, 1.0]) {
      canvas.drawCircle(c, r * k, Paint()
        ..color = Colors.white10
        ..style = PaintingStyle.stroke);
    }
    canvas.drawLine(c - Offset(0, r), c + Offset(0, r), Paint()..color = Colors.white12);
    canvas.drawLine(c - Offset(r, 0), c + Offset(r, 0), Paint()..color = Colors.white12);
    if (v != null) {
      var most = 1e-4;
      for (var p = 0; p < 128; p++) {
        most = math.max(most, math.max((v['m$p'] ?? 0).abs(), (v['s$p'] ?? 0).abs()));
      }
      final dot = Paint()..color = color.withValues(alpha: 0.7);
      for (var p = 0; p < 128; p++) {
        final m = (v['m$p'] ?? 0) / most, s = (v['s$p'] ?? 0) / most;
        canvas.drawCircle(c + Offset(-s * r, -m * r), 1.6, dot);
      }
    }
    // The bands: a column each, its width as a bar from the centre line (1: as is).
    const names = ['LOW', 'MID', 'HIGH'];
    for (var b = 0; b < 3; b++) {
      final x0 = w * b / 3, x1 = w * (b + 1) / 3, cx = (x0 + x1) / 2;
      final on = active == b;
      final bar = Rect.fromLTRB(cx - 10, h - 16 - (h - 46) * widths[b] / 2, cx + 10, h - 16);
      canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(5)),
          Paint()..color = Color.lerp(color, second, b / 2)!.withValues(alpha: on ? 0.55 : 0.28));
      final unity = h - 16 - (h - 46) / 2;
      canvas.drawLine(Offset(cx - 14, unity), Offset(cx + 14, unity), Paint()..color = Colors.white30);
      paintLabel(canvas, '${names[b]} ${(widths[b] * 100).round()}%', Offset(cx, h - 7), on ? Neon.text : Neon.dim, size: 8,
          align: 0, weight: FontWeight.w800);
      if (b > 0) canvas.drawLine(Offset(x0, 22), Offset(x0, h - 4), Paint()..color = Colors.white10);
    }
    paintLabel(canvas, '${freqs[0].round()} Hz', Offset(w / 3, 26), Neon.dim, size: 8, align: 0);
    paintLabel(canvas, '${(freqs[1] / 1000).toStringAsFixed(1)} kHz', Offset(2 * w / 3, 26), Neon.dim, size: 8, align: 0);
  }

  @override
  bool shouldRepaint(covariant _ImagerPainter o) => true;
}

/// The channel mixer: the 2 x 2 matrix as four cells (rows: the outputs, columns: the inputs), each dragged up and
/// down from −1 (inverted) through 0 to 1; double-tap a cell for its default. Corner presets are in the browser.
class ChannelMixerPage extends StatelessWidget {
  const ChannelMixerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return effectPage('mixer', [
      HeroWithMeters(height: 200, gr: false, hero: liveHero(context: context, caption: 'MATRIX', height: 200,
          readout: const Text('out ← in'), builder: (context, secs, v) => const _MatrixHero())),
      DeviceDisplay(builder: (context, f) => Column(mainAxisSize: MainAxisSize.min, children: [
        SpaceBar(label: 'CORRELATION', value: f?.values['correlation']),
        SpaceBar(label: 'BALANCE', value: f?.values['balance']),
      ])),
      const KnobRow(['left_to_left', 'right_to_left', 'left_to_right', 'right_to_right'], size: 46),
    ]);
  }
}

class _MatrixHero extends StatefulWidget {
  const _MatrixHero();

  @override
  State<_MatrixHero> createState() => _MatrixHeroState();
}

class _MatrixHeroState extends State<_MatrixHero> {
  static const _cells = ['left_to_left', 'right_to_left', 'left_to_right', 'right_to_right'];
  int? _cell;
  double _v = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      int cellAt(Offset p) => ((p.dy - 22) / ((h - 22) / 2)).floor().clamp(0, 1) * 2 + (p.dx / (w / 2)).floor().clamp(0, 1);
      return GrabGesture(
        key: const ValueKey('matrix-hero'),
        onStart: (p, _) {
          _cell = cellAt(p);
          _v = t.value(_cells[_cell!]);
          setState(() {});
        },
        onUpdate: (u) {
          final c = _cell;
          if (c == null) return;
          final before = _v;
          _v = (_v - u.delta.dy / (h * 0.6) * 2 * DeviceFingers.fine).clamp(-1.0, 1.0);
          if (before * _v <= 0 && before != 0) DeviceFeel.detent();
          t.setLive(_cells[c], _v.abs() < 0.02 ? 0 : _v);
        },
        onEnd: () {
          t.commit();
          setState(() => _cell = null);
        },
        onDoubleTap: (p) {
          final k = _cells[cellAt(p)];
          t.set(k, t.param(k)?.defaultValue ?? 0);
        },
        child: CustomPaint(size: Size(w, h), painter: _MatrixPainter(
            values: [for (final k in _cells) t.value(k)], active: _cell, color: scope.accent, second: scope.secondary)),
      );
    });
  }
}

class _MatrixPainter extends CustomPainter {
  _MatrixPainter({required this.values, required this.active, required this.color, required this.second});
  final List<double> values;
  final int? active;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height - 22;
    const labels = ['L ← L', 'L ← R', 'R ← L', 'R ← R'];
    for (var k = 0; k < 4; k++) {
      final rect = Rect.fromLTWH((k % 2) * w / 2 + 6, 22 + (k ~/ 2) * h / 2 + 4, w / 2 - 12, h / 2 - 10);
      final v = values[k];
      final c = v < 0 ? Neon.pink : (k < 2 ? color : second);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(10)),
          Paint()..color = Colors.white.withValues(alpha: active == k ? 0.08 : 0.03));
      final mid = rect.center.dy;
      final fill = Rect.fromLTRB(rect.left + 8, v >= 0 ? mid - v * (rect.height / 2 - 6) : mid, rect.right - 8,
          v >= 0 ? mid : mid - v * (rect.height / 2 - 6));
      canvas.drawRRect(RRect.fromRectAndRadius(fill, const Radius.circular(4)), Paint()..color = c.withValues(alpha: 0.45));
      canvas.drawLine(Offset(rect.left + 4, mid), Offset(rect.right - 4, mid), Paint()..color = Colors.white24);
      paintLabel(canvas, labels[k], Offset(rect.left + 8, rect.top + 9), Neon.dim, size: 8, weight: FontWeight.w800);
      paintLabel(canvas, '${v >= 0 ? '' : '−'}${(v.abs() * 100).round()}%', Offset(rect.right - 8, rect.top + 9),
          active == k ? Neon.text : c, size: 9, align: 1, weight: FontWeight.w800);
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixPainter o) => true;
}
