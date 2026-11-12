// The drive family's plugin UI (saturator and distortion): the transfer curve with the input riding it, the harmonics it adds,
// and the modes as drawn-curve tiles (two rows for the saturator's eleven).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import 'effect_page.dart';

/// The curve families the drive devices offer.
enum DriveShape { tape, tube, soft, hard, fold, crush, fuzz, rectify, triFold, bitShape, fat }

DriveShape driveShapeOf(String label) {
  final l = label.toLowerCase();
  // fx-dynamics: the saturator's newer curves first ("Tri fold" before "Fold", "Bit shape" before "Crush").
  if (l.contains('fuzz')) return DriveShape.fuzz;
  if (l.contains('rect')) return DriveShape.rectify;
  if (l.contains('tri')) return DriveShape.triFold;
  if (l.contains('bit shape')) return DriveShape.bitShape;
  if (l.contains('fat')) return DriveShape.fat;
  if (l.contains('tube')) return DriveShape.tube;
  if (l.contains('soft')) return DriveShape.soft;
  if (l.contains('hard') || l.contains('clip')) return DriveShape.hard;
  if (l.contains('fold')) return DriveShape.fold;
  if (l.contains('crush')) return DriveShape.crush;
  return DriveShape.tape; // Tape, Drive
}

double _tanh(double x) {
  final e = math.exp(2 * x.clamp(-20.0, 20.0));
  return (e - 1) / (e + 1);
}

/// The output for input [x] (−1..1) of [shape] at [gain] (linear) with [bias]: the textbook curves (tanh, an
/// asymmetric tube, cubic soft clip, hard clip, sine fold, a [bits] quantiser), for drawing; the bias's DC is removed
/// as the engine does.
double driveCurve(DriveShape shape, double x, double gain, {double bias = 0, double bits = 8}) {
  double f(double u) => switch (shape) {
        DriveShape.tape => _tanh(u),
        DriveShape.tube => u >= 0 ? _tanh(u) : _tanh(u * 0.55) / 0.55 * 0.7,
        DriveShape.soft => u.abs() >= 1 ? u.sign : 1.5 * u - 0.5 * u * u * u,
        DriveShape.hard => u.clamp(-1.0, 1.0),
        DriveShape.fold => math.sin(u * math.pi / 2),
        DriveShape.crush || DriveShape.bitShape => () {
            final q = math.pow(2, bits.clamp(1, 16) - 1).toDouble();
            return ((u.clamp(-1.0, 1.0)) * q).roundToDouble() / q;
          }(),
        DriveShape.fuzz => () {
            final v = u + u * u * u;
            return u >= 0 ? _tanh(v) : 0.7 * _tanh(v / 0.7);
          }(),
        DriveShape.rectify => _tanh(u.abs()),
        DriveShape.triFold => () {
            final t = (u + 1) * 0.25;
            final f = t - t.floorToDouble();
            return 1 - 4 * (f - 0.5).abs();
          }(),
        DriveShape.fat => _tanh(u) + 0.5 * _tanh(u) * _tanh(u),
      };
  final b = bias * 0.5;
  return f(gain * x + b) - f(b);
}

/// The first [n] harmonics' levels (0..1, the fundamental first) of a full-scale sine through [curve].
List<double> harmonics(double Function(double x) curve, {int n = 8}) {
  const m = 128;
  final y = [for (var i = 0; i < m; i++) curve(math.sin(2 * math.pi * i / m))];
  final out = <double>[];
  for (var k = 1; k <= n; k++) {
    var re = 0.0, im = 0.0;
    for (var i = 0; i < m; i++) {
      re += y[i] * math.cos(2 * math.pi * k * i / m);
      im += y[i] * math.sin(2 * math.pi * k * i / m);
    }
    out.add(math.sqrt(re * re + im * im) * 2 / m);
  }
  final top = out.fold(1e-9, math.max);
  return [for (final v in out) v / top];
}

/// The saturator and the distortion: mode tiles, the transfer curve (drag up and down for drive, sideways for bias),
/// the harmonics it adds to a sine, and the knobs.
class DrivePage extends StatelessWidget {
  const DrivePage({super.key});

  static String modeId(DeviceScope scope) =>
      ['mode', 'shape', 'type'].firstWhere((id) => scope.target.param(id)?.isChoice ?? false, orElse: () => 'mode');

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final mode = modeId(scope);
    final p = t.param(mode);
    final shape = p == null ? DriveShape.tape : driveShapeOf(formatParamValue(p, t.value(mode)));
    return effectPage('drive', [
      Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles(mode, height: 56, perRow: 6, icon: (canvas, r, i, c) {
        final label = p == null || i >= p.choices.length ? '' : p.choices[i];
        iconCurve(canvas, r.deflate(2), c, (x) => driveCurve(driveShapeOf(label), x, 2.6, bits: 3) * 0.95);
      })),
      HeroWithMeters(height: 210, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'TRANSFER',
        grid: false,
        readout: Text('${shortParamLabel(t.param('drive'), 'Drive')} ${formatParamValue(t.param('drive'), t.value('drive'))}'),
        child: const _DriveHero(),
      )),
      KnobRow(['drive', 'bias', 'tone', if (shape == DriveShape.crush) ...['bits', 'rate'], if (shape == DriveShape.bitShape) 'bits',
        'output', 'mix'], size: 50),
      const KnobRow(['spread', 'dynamics'], size: 42),
      Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: const [
        DeviceToggle('oversample', label: '2× oversample', icon: Icons.high_quality_outlined),
        DeviceToggle('auto_gain', label: 'Auto gain', icon: Icons.auto_fix_high),
      ])),
    ]);
  }
}

class _DriveHero extends StatefulWidget {
  const _DriveHero();

  @override
  State<_DriveHero> createState() => _DriveHeroState();
}

class _DriveHeroState extends State<_DriveHero> {
  bool _active = false;
  double _drive = 0, _bias = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final mode = DrivePage.modeId(scope);
    final p = t.param(mode);
    final shape = p == null ? DriveShape.tape : driveShapeOf(formatParamValue(p, t.value(mode)));
    final dp = t.param('drive');
    final db = dp?.unit == 'dB';
    final gain = db ? math.pow(10, t.value('drive') / 20).toDouble() : t.value('drive');
    final bias = t.param('bias') == null ? 0.0 : t.value('bias');
    final bits = t.param('bits') == null ? 8.0 : t.value('bits');
    final mix = t.param('mix') == null ? 1.0 : t.value('mix');
    double curve(double x) => mix * driveCurve(shape, x, gain, bias: bias, bits: bits) + (1 - mix) * x;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('drive-hero'),
        onStart: (_, _) {
          _drive = t.value('drive');
          _bias = bias;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          if (dp == null) return;
          final fine = DeviceFingers.fine;
          final travel = taperOf(dp);
          final pos = (travel.position(_drive) - u.delta.dy / (h * 1.2) * fine).clamp(0.0, 1.0);
          _drive = travel.value(pos);
          t.setLive('drive', _drive);
          if (t.param('bias') != null) {
            _bias = (_bias + u.delta.dx / w * 2 * fine).clamp(-1.0, 1.0);
            t.setLive('bias', _bias);
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['drive', 'bias']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, h), painter: _DrivePainter(
          curve: curve,
          engineCurve: [
            for (var k = 0; k < 65; k++) ?f?.values['curve$k'],
          ],
          input: f?.inputDb,
          harmonics: harmonics(curve),
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _DrivePainter extends CustomPainter {
  _DrivePainter({required this.curve, required this.engineCurve, required this.input, required this.harmonics,
    required this.color, required this.second, required this.active});
  final double Function(double x) curve;
  final List<double> engineCurve;
  final double? input;
  final List<double> harmonics;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // The curve in a square on the left, the harmonics beside it.
    final side = math.min(size.height - 30, size.width * 0.62);
    final sq = Rect.fromLTWH(12, 24, side, side);
    Offset pt(double x, double y) => Offset(sq.left + (x + 1) / 2 * sq.width, sq.top + (1 - (y.clamp(-1.15, 1.15) + 1) / 2) * sq.height);
    final faint = Paint()..color = Neon.ink.withValues(alpha: 0.08);
    canvas.drawRect(sq, faint..style = PaintingStyle.stroke);
    faint.style = PaintingStyle.fill;
    canvas.drawLine(pt(-1, 0), pt(1, 0), faint);
    canvas.drawLine(pt(0, -1), pt(0, 1), faint);
    canvas.drawLine(pt(-1, -1), pt(1, 1), Paint()..color = Neon.ink.withValues(alpha: 0.12));
    // A live curve from the engine when it has one (non-zero), else the drawing's.
    final live = engineCurve.length == 65 && engineCurve.any((v) => v != 0);
    final path = Path();
    final n = live ? 64 : 160;
    for (var i = 0; i <= n; i++) {
      final x = -1 + 2 * i / n;
      final p = pt(x, live ? engineCurve[i] : curve(x));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.save();
    canvas.clipRect(sq.inflate(2));
    canvas.drawPath(path, Paint()
      ..shader = LinearGradient(colors: Neon.ramp([second, color, second])).createShader(sq)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 3 : 2.4
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2));
    canvas.restore();
    if (input case final db? when db > -60) {
      final a = math.pow(10, db / 20).toDouble().clamp(0.0, 1.0);
      for (final x in [a, -a]) {
        final p = pt(x, curve(x));
        canvas.drawCircle(p, 9, Paint()..color = Neon.ink.withValues(alpha: 0.14));
        canvas.drawCircle(p, 4, Paint()..color = Neon.ink);
      }
    }
    // The harmonics of a sine, odd in the family colour, even in its second colour.
    final hx = sq.right + 16, hw = size.width - hx - 10;
    if (hw > 40) {
      paintLabel(canvas, 'HARMONICS', Offset(hx, sq.top + 4), Neon.dim, size: 8, weight: FontWeight.w700);
      final bw = hw / harmonics.length;
      final base = sq.bottom;
      for (var k = 0; k < harmonics.length; k++) {
        final v = k == 0 ? harmonics[k] : math.pow(harmonics[k], 0.5).toDouble(); // the overtones lifted to be seen
        final bh = (base - sq.top - 22) * v;
        final c = (k + 1).isOdd ? color : second;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(hx + k * bw + 1, base - bh, bw - 3, bh), const Radius.circular(2)),
          Paint()..color = c.withValues(alpha: k == 0 ? 0.35 : 0.85));
        paintLabel(canvas, '${k + 1}', Offset(hx + k * bw + bw / 2 - 1, base + 7), Neon.dim, size: 7, align: 0);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DrivePainter o) => true;
}
