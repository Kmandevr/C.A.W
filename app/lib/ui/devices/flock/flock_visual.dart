// Flock's picture: the source (the sample's waveform, or the built-in tone's outline) with the live grain cloud drawn over it as a flock of small birds (its one motif), the position, spray and grain size marked, and the tone tiles' icons.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_display.dart';
import '../../theme.dart';
import '../kit/hero.dart';

/// What Flock's display frame says (docs/engine.md, Display data, `org.caw.flock`): 44 floats, then 5 per grain, then
/// (1.1.0) one direction flag per grain.
class FlockFrame {
  const FlockFrame(this.f);
  final DeviceDisplayFrame? f;

  static const head = 12, overviewBins = 32, perGrain = 5;

  double _at(int i, [double d = 0]) => f?.at(i, d) ?? d;
  bool get live => f != null && _at(0) >= 1;
  int get grains => _at(1).round();
  int get cap => _at(2).round();
  int get dropped => _at(3).round();
  int get voices => _at(4).round();

  /// 0: a sample; 1–4: the built-in tone + 1.
  int get source => _at(5).round();

  /// A named sample failed to load (the built-in tone plays).
  bool get missing => _at(6) >= 0.5;
  double get seconds => _at(7);
  double get position => _at(8);
  double get sizeMs => _at(9);
  double get peakDb => _at(10, -120);

  /// The source's overview, 32 peaks 0..1 from first to last.
  List<double> get overview => [for (var b = 0; b < overviewBins; b++) _at(head + b).clamp(0.0, 1.0)];

  /// The grains published (held to what the frame holds).
  int get shown {
    final raw = f?.raw?.length ?? 0;
    final room = math.max(0, (raw - head - overviewBins) ~/ perGrain);
    return math.min(_at(11).round().clamp(0, 128), room);
  }

  /// Grain [k]: where it reads (0..1), its window phase 0..1, pan −1..1, semitones (negative: backwards), voice.
  ({double pos, double phase, double pan, double semitones, int voice}) grain(int k) {
    final b = head + overviewBins + perGrain * k;
    return (pos: _at(b).clamp(0.0, 1.0), phase: _at(b + 1).clamp(0.0, 1.0), pan: _at(b + 2).clamp(-1.0, 1.0),
        semitones: _at(b + 3), voice: _at(b + 4).round());
  }

  /// Whether grain [k] plays backwards, from the direction block after the grains (index 44 + 5 × [shown] + k: 1
  /// backwards, 0 forwards); null on an engine before 1.1.0, whose frame has no such block.
  bool? backwards(int k) {
    final n = shown, raw = f?.raw?.length ?? 0;
    final i = head + overviewBins + perGrain * n + k;
    if (k < 0 || k >= n || raw < head + overviewBins + (perGrain + 1) * n) return null;
    return _at(i) >= 0.5;
  }
}

/// A grain's level at [phase] through window [window] (Hann, Tukey, Gaussian, Expodec, Rexpodec), 0..1: a drawing
/// of the engine's tables, which the display does not send.
double flockWindowLevel(int window, double phase) {
  final p = phase.clamp(0.0, 1.0);
  return switch (window) {
    1 => p < 0.25 ? 0.5 - 0.5 * math.cos(math.pi * p / 0.25) : p > 0.75 ? 0.5 - 0.5 * math.cos(math.pi * (1 - p) / 0.25) : 1.0,
    2 => math.exp(-0.5 * math.pow((p - 0.5) / 0.15, 2)),
    3 => math.min(1.0, p * 40) * math.exp(-5 * p),
    4 => math.min(1.0, (1 - p) * 40) * math.exp(-5 * (1 - p)),
    _ => math.pow(math.sin(math.pi * p), 2).toDouble(),
  };
}

/// What the picture draws: the knobs it shows ([value]), the newest frame, the source's length and which source.
class FlockPicture {
  const FlockPicture({required this.value, required this.frame, required this.seconds, required this.sample,
    required this.time, required this.accent, required this.secondary, this.active = false});
  final double Function(String id) value;
  final FlockFrame frame;

  /// The source's length in seconds (the frame's, the sample file's, or the built-in tone's 2 s).
  final double seconds;

  /// A sample's waveform is drawn under the picture (so the built-in outline is not).
  final bool sample;
  final double time;
  final Color accent, secondary;
  final bool active;

  int get tone => value('builtin').round().clamp(0, 3);
}

class FlockPainter extends CustomPainter {
  FlockPainter(this.p);
  final FlockPicture p;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final mid = size.height * 0.56;
    final amp = size.height * 0.34;
    if (!p.sample) _outline(canvas, size, mid, amp);
    _marks(canvas, size, mid);
    final fr = p.frame;
    if (fr.live && fr.shown > 0) {
      _cloud(canvas, size, mid);
    } else {
      _resting(canvas, size, mid);
    }
  }

  /// The built-in tone's outline: the frame's overview when it plays, else a sketch of the tone's 2 s.
  void _outline(Canvas canvas, Size s, double mid, double amp) {
    final fr = p.frame;
    final over = fr.live && fr.source > 0 ? fr.overview : null;
    final have = over != null && over.any((v) => v > 0.001);
    double at(double u) {
      if (have) {
        final x = u * (over.length - 1);
        final i = x.floor().clamp(0, over.length - 2);
        final t = x - i;
        return over[i] * (1 - t) + over[i + 1] * t;
      }
      // Strings swell and hold, glass strikes and rings, breath rises and falls, the choir swells slowly.
      return switch (p.tone) {
        1 => math.min(1.0, u * 30) * (0.25 + 0.75 * math.exp(-u * 2.2)),
        2 => 0.25 + 0.55 * math.sin(math.pi * u) * (0.8 + 0.2 * math.sin(u * 37)),
        3 => 0.35 + 0.5 * math.pow(math.sin(math.pi * math.min(1.0, u * 1.2)), 0.6) * (0.85 + 0.15 * math.sin(u * 11)),
        _ => math.min(1.0, u * 6) * (0.75 + 0.1 * math.sin(u * 9)),
      }.clamp(0.0, 1.0);
    }
    final top = Path(), bottom = <Offset>[];
    const n = 96;
    for (var i = 0; i <= n; i++) {
      final u = i / n;
      final x = u * s.width;
      final y = amp * at(u);
      i == 0 ? top.moveTo(x, mid - y) : top.lineTo(x, mid - y);
      bottom.add(Offset(x, mid + y * 0.8));
    }
    final shape = Path.from(top);
    for (final o in bottom.reversed) {
      shape.lineTo(o.dx, o.dy);
    }
    shape.close();
    canvas.drawPath(shape, Paint()..color = p.accent.withValues(alpha: have ? 0.16 : 0.10));
    strokeGlow(canvas, top, p.accent.withValues(alpha: have ? 0.8 : 0.45), width: 1.3, glow: have);
  }

  /// The position (a line), the spray around it (a band) and one grain's length (a bracket at the bottom).
  void _marks(Canvas canvas, Size s, double mid) {
    final secs = p.seconds > 0 ? p.seconds : 2.0;
    final pos = p.value('position').clamp(0.0, 1.0);
    final x = pos * s.width;
    final spray = (p.value('spray') / 1000 / secs * s.width).clamp(0.0, s.width);
    final band = Rect.fromLTRB((x - spray).clamp(0, s.width), 4, (x + spray).clamp(0, s.width), s.height - 4);
    canvas.drawRRect(RRect.fromRectAndRadius(band, const Radius.circular(6)),
        Paint()..color = p.secondary.withValues(alpha: p.active ? 0.20 : 0.12));
    final line = Paint()
      ..color = p.accent.withValues(alpha: p.active ? 1 : 0.8)
      ..strokeWidth = p.active ? 2 : 1.4;
    canvas.drawLine(Offset(x, 4), Offset(x, s.height - 4), line);
    // Where the position is now (it scans or glides): the frame's, a small tick on top.
    final fr = p.frame;
    if (fr.live && (fr.position - pos).abs() > 0.002) {
      final nx = fr.position.clamp(0.0, 1.0) * s.width;
      canvas.drawLine(Offset(nx, 4), Offset(nx, 16), Paint()..color = Neon.text.withValues(alpha: 0.7)..strokeWidth = 2);
    }
    final grain = (p.value('size') / 1000 / secs * s.width).clamp(2.0, s.width);
    final by = s.height - 10;
    final bracket = Paint()
      ..color = p.accent.withValues(alpha: 0.7)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(Path()
      ..moveTo(x, by - 4)
      ..lineTo(x, by)
      ..lineTo(x + grain, by)
      ..lineTo(x + grain, by - 4), bracket);
    if (p.value('freeze') >= 0.5) paintLabel(canvas, 'FROZEN', Offset(x + 5, 8), p.accent, size: 8.5);
  }

  /// The live cloud: each grain a bird at its read position, as high as its pitch, as big as its level.
  void _cloud(Canvas canvas, Size s, double mid) {
    final fr = p.frame;
    final window = p.value('window').round();
    final reversing = p.value('reverse') > 0;
    final span = math.max(12.0, p.value('pitch').abs() + p.value('spread') + 12);
    for (var k = 0; k < fr.shown; k++) {
      final g = fr.grain(k);
      final level = flockWindowLevel(window, g.phase);
      // 1.1.0's direction flags say which grains play backwards (their semitones are then sent negated); an older
      // frame marks one only by a negative pitch, which with Reverse off is only a lower pitch.
      final back = fr.backwards(k) ?? (reversing && g.semitones < 0);
      final st = back ? -g.semitones : g.semitones;
      final y = (mid - st / span * s.height * 0.42 + g.pan * s.height * 0.06).clamp(10.0, s.height - 12);
      final c = Color.lerp(p.accent, p.secondary, (g.voice % 4) / 5)!;
      paintBird(canvas, Offset(g.pos * s.width, y), s.height * (0.05 + 0.08 * level), c.withValues(alpha: 0.35 + 0.65 * level),
          flap: g.phase * 6 + k * 0.37, backwards: back);
    }
  }

  /// Not playing: a small flock resting over the position and spray, drawn from the knobs.
  void _resting(Canvas canvas, Size s, double mid) {
    final secs = p.seconds > 0 ? p.seconds : 2.0;
    final pos = p.value('position').clamp(0.0, 1.0);
    final spray = p.value('spray') / 1000 / secs;
    final pitch = p.value('pitch'), spread = p.value('spread');
    final span = math.max(12.0, pitch.abs() + spread + 12);
    final rnd = math.Random(p.value('seed').round());
    final count = (3 + p.value('density') / 8).clamp(3, 12).round();
    for (var k = 0; k < count; k++) {
      final u = (pos + (rnd.nextDouble() * 2 - 1) * spray).clamp(0.0, 1.0);
      final st = pitch + (rnd.nextDouble() * 2 - 1) * spread;
      final y = (mid - st / span * s.height * 0.42 + (rnd.nextDouble() - 0.5) * s.height * 0.12).clamp(10.0, s.height - 12);
      paintBird(canvas, Offset(u * s.width, y), s.height * (0.05 + 0.02 * rnd.nextDouble()), p.accent.withValues(alpha: 0.4),
          flap: p.time * 3 + k, backwards: rnd.nextDouble() < p.value('reverse'));
    }
  }

  @override
  bool shouldRepaint(covariant FlockPainter o) => true;
}

/// Flock's one motif: a small bird in flight centred at [at], [size] px wingspan, facing right ([backwards]: left).
/// [flap] turns the wings (any number; its fractional cycles beat them).
void paintBird(Canvas canvas, Offset at, double size, Color color, {double flap = 0, bool backwards = false}) {
  final w = size.clamp(3.0, 28.0) / 2;
  final beat = math.sin(flap * 2 * math.pi);
  final tip = -w * (0.15 + 0.45 * beat); // wingtips up (negative) or down
  final dir = backwards ? -1.0 : 1.0;
  final wings = Path()
    ..moveTo(at.dx - w, at.dy + tip)
    ..quadraticBezierTo(at.dx - w * 0.45, at.dy - w * 0.35 * (1 + beat * 0.5), at.dx, at.dy)
    ..quadraticBezierTo(at.dx + w * 0.45, at.dy - w * 0.35 * (1 + beat * 0.5), at.dx + w, at.dy + tip);
  // A dark edge first, so the flock reads over a loud waveform.
  canvas.drawPath(wings, Paint()
    ..color = Neon.bg.withValues(alpha: 0.7 * color.a)
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.2, w * 0.28) + 2
    ..strokeCap = StrokeCap.round);
  canvas.drawPath(wings, Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.2, w * 0.28)
    ..strokeCap = StrokeCap.round);
  // The body and the head forward, so the flock shows which way each grain reads.
  canvas.drawOval(Rect.fromCenter(center: at + Offset(dir * w * 0.12, w * 0.06), width: w * 0.7, height: w * 0.3),
      Paint()..color = color);
  canvas.drawCircle(at + Offset(dir * w * 0.5, -w * 0.02), w * 0.13, Paint()..color = color);
}

/// The tone tiles' icons: the sample (a waveform), then Strings, Glass, Breath and Choir.
void flockSourceIcon(Canvas canvas, Rect r, int k, Color c) {
  final line = Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round;
  final s = math.min(r.width, r.height);
  final box = Rect.fromCenter(center: r.center, width: s * 1.4, height: s);
  final path = Path();
  switch (k) {
    case 0: // a sample
      for (var i = 0; i <= 12; i++) {
        final x = box.left + box.width * i / 12;
        final h = box.height * (0.15 + 0.35 * (math.sin(i * 1.7).abs()));
        canvas.drawLine(Offset(x, box.center.dy - h), Offset(x, box.center.dy + h), line);
      }
      return;
    case 1: // strings: a long even sustain
      for (var i = 0; i < 3; i++) {
        final y = box.top + box.height * (0.25 + i * 0.25);
        canvas.drawLine(Offset(box.left, y), Offset(box.right, y), line);
      }
      return;
    case 2: // glass: a strike that rings away
      path.moveTo(box.left, box.center.dy);
      for (var i = 0; i <= 24; i++) {
        final u = i / 24;
        path.lineTo(box.left + box.width * u, box.center.dy - box.height * 0.45 * math.exp(-u * 3) * math.sin(u * 30));
      }
    case 3: // breath: a soft rise and fall
      path.moveTo(box.left, box.bottom);
      path.quadraticBezierTo(box.center.dx, box.top - box.height * 0.3, box.right, box.bottom);
    default: // choir: three voices, a swell each
      for (var v = 0; v < 3; v++) {
        final y = box.top + box.height * (0.3 + v * 0.22);
        path.moveTo(box.left, y);
        path.quadraticBezierTo(box.center.dx, y - box.height * 0.2, box.right, y);
      }
  }
  canvas.drawPath(path, line);
}
