// The Drive device page (org.caw.drive, 1.0.8): variant and mode cards with a curve colour each, the transfer curve morphing with drive, harmonics with their even/odd balance.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart' show spectrumColors;
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../drive_editors.dart' show DriveShape, driveShapeOf, driveCurve;
import '../dynamics/fx_math.dart' show clipCurve, phaseDistorted;
import '../effect_page.dart';
import 'common.dart';

// The spectrum's slots: 0 pink, 1 orange, 2 yellow, 3 green, 4 mint, 5 blue, 6 violet, 7 red.
Color _spectrum(int i) => spectrumColors()[i];

/// Each variant's card colour: Distortion red, Saturate orange, Clip yellow, Phase violet.
Color driveVariantColor(int v) => _spectrum(const [7, 1, 2, 6][v.clamp(0, 3)]);

/// A curve family's colour (the curve and its card share it).
Color driveShapeColor(DriveShape s) => _spectrum(switch (s) {
      DriveShape.tape || DriveShape.fat => 1,
      DriveShape.tube => 2,
      DriveShape.soft => 4,
      DriveShape.hard => 7,
      DriveShape.fold || DriveShape.triFold => 3,
      DriveShape.crush || DriveShape.bitShape => 5,
      DriveShape.fuzz => 0,
      DriveShape.rectify => 6,
    });

/// The Clip variant's modes (Hard, Soft, Analog) as clipCurve's modes, and their colours.
Color _clipColor(int mode) => _spectrum(const [7, 4, 1][mode.clamp(0, 2)]);

/// The variant's mode parameter: Distortion's `shape`, Saturate's and Clip's `mode`; Phase has none.
String? driveModeParam(int variant) => switch (variant) { 0 => 'shape', 1 || 2 => 'mode', _ => null };

double _db(double v) => math.pow(10, v / 20).toDouble();

/// One cycle of what the variant does to a sine and its transfer curve (null for Phase, which bends time, not level).
({double Function(double x)? curve, double Function(double phase) cycle, Color color, String caption}) driveModel(
    DeviceScope scope) {
  final t = scope.target;
  double v(String id, double d) => t.param(id) == null ? d : t.value(id);
  final variant = t.info?.variantIndex ?? 0;
  final mix = v('mix', 1);
  double Function(double x) blend(double Function(double x) f) => (x) => mix * f(x) + (1 - mix) * x;
  switch (variant) {
    case 3:
      final drive = v('drive', 0.4), bias = v('bias', 0);
      return (curve: null, cycle: (p) => mix * phaseDistorted(p, drive, bias) + (1 - mix) * math.sin(2 * math.pi * p),
          color: driveVariantColor(3), caption: 'ONE CYCLE');
    case 2:
      final mode = v('mode', 0).round(), g = _db(v('drive', 0)), soft = v('softness', 0.5);
      final c = v('master', 0) >= 0.5 ? 1.0 : _db(v('ceiling', -0.3));
      final f = blend((x) => c * clipCurve(mode, x * g / c, soft));
      return (curve: f, cycle: (p) => f(math.sin(2 * math.pi * p)), color: _clipColor(mode), caption: 'TRANSFER');
    default:
      final id = driveModeParam(variant)!;
      final p = t.param(id);
      final shape = p == null ? DriveShape.tape : driveShapeOf(formatParamValue(p, t.value(id)));
      final dp = t.param('drive');
      final gain = dp?.unit == 'dB' ? _db(v('drive', 6)) : v('drive', 4);
      final f = blend((x) => driveCurve(shape, x, gain, bias: v('bias', 0), bits: v('bits', 8)));
      return (curve: f, cycle: (ph) => f(math.sin(2 * math.pi * ph)), color: driveShapeColor(shape), caption: 'TRANSFER');
  }
}

/// The first [n] harmonics' levels (the fundamental first) of one cycle [y] (sampled evenly).
List<double> cycleHarmonics(List<double> y, {int n = 9}) {
  final m = y.length;
  return [
    for (var k = 1; k <= n; k++) () {
      var re = 0.0, im = 0.0;
      for (var i = 0; i < m; i++) {
        re += y[i] * math.cos(2 * math.pi * k * i / m);
        im += y[i] * math.sin(2 * math.pi * k * i / m);
      }
      return math.sqrt(re * re + im * im) * 2 / m;
    }(),
  ];
}

/// The share of the overtones' power in the even harmonics (0..1), or null with no overtones to speak of.
double? evenShare(List<double> h) {
  var even = 0.0, odd = 0.0;
  for (var k = 1; k < h.length; k++) {
    final p = h[k] * h[k];
    (k + 1).isEven ? even += p : odd += p;
  }
  final total = even + odd;
  return total < 1e-6 * h.first * h.first || total < 1e-12 ? null : even / total;
}

/// The Drive: Distortion, Saturate, Clip and Phase as variant cards (one undo step each), the variant's modes as
/// cards with their own curve colour, then the transfer curve (Phase: one cycle of a sine, bent) in the mode's
/// colour, morphing as the drive moves (the engine's live curve where it publishes one), the input riding it, and the
/// harmonics it adds with their even/odd balance. Up and down on it drives harder; sideways sets the bias (Saturate,
/// Phase) or the softness (Clip). Tone is a post-curve tone (the engine has no pre tone yet).
class DriveDevice extends StatelessWidget {
  const DriveDevice({super.key});

  static void _modeIcon(Canvas canvas, Rect r, int variant, int i, String label, Color c) {
    final rr = r.deflate(2);
    if (variant == 2) {
      iconCurve(canvas, rr, c, (x) => clipCurve(i, x * 2.2, 0.6) * 0.8);
    } else {
      iconCurve(canvas, rr, c, (x) => driveCurve(driveShapeOf(label), x, 2.6, bits: 3) * 0.95);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = t.info?.variantIndex ?? 0;
    final inline = DeviceScope.isInline(context);
    final modeId = driveModeParam(variant);
    final mp = modeId == null ? null : t.param(modeId);
    final shape = mp == null || variant == 2 ? null : driveShapeOf(formatParamValue(mp, t.value(modeId!)));
    final cards = Padding(padding: const EdgeInsets.only(bottom: 6), child: VariantCards(
      height: inline ? 44 : 52,
      colorOf: driveVariantColor,
      icon: (canvas, r, i, c) {
        final rr = r.deflate(2);
        switch (i) {
          case 0:
            iconCurve(canvas, rr, c, (x) => driveCurve(DriveShape.hard, x, 2.2) * 0.85);
          case 1:
            iconCurve(canvas, rr, c, (x) => driveCurve(DriveShape.tape, x, 2.5) * 0.85);
          case 2:
            iconCurve(canvas, rr, c, (x) => clipCurve(1, x * 1.8, 0.4) * 0.7);
          default:
            iconCurve(canvas, rr, c, (x) => phaseDistorted((x + 1) / 4, 0.7, 0) * 0.85);
        }
      }));
    final modes = mp == null || !mp.isChoice ? null : Padding(padding: const EdgeInsets.only(bottom: 8), child: ColorModeCards(
      modeId!,
      height: inline ? 44 : 50,
      perRow: 6,
      colorOf: (k) => variant == 2 ? _clipColor(k) : driveShapeColor(driveShapeOf(k < mp.choices.length ? mp.choices[k] : '')),
      icon: (canvas, r, i, c) => _modeIcon(canvas, r, variant, i, i < mp.choices.length ? mp.choices[i] : '', c)));
    final hero = HeroWithMeters(height: 210, gr: false, hero: HeroCanvas(
      color: scope.accent,
      height: 210,
      caption: null,
      grid: false,
      readout: Builder(builder: (context) => Text('${shortParamLabel(t.param('drive'), 'Drive')} ${formatParamValue(t.param('drive'), t.value('drive'))}')),
      child: const _DriveHero(),
    ));
    final crush = shape == DriveShape.crush, bitShape = shape == DriveShape.bitShape;
    final master = variant == 2 && t.value('master') >= 0.5;
    final main = switch (variant) {
      0 => ['drive', if (crush) 'bits'],
      1 => ['drive', 'bias', 'tone', if (crush) ...['bits', 'rate'], if (bitShape) 'bits'],
      2 => ['drive', if (!master) 'ceiling', 'softness'],
      _ => ['drive', 'bias', 'tone', 'spread'],
    };
    const labels = {'tone': 'Tone (post)', 'bits': 'Bits', 'rate': 'Rate'};
    if (inline) return effectPage('drive', [cards, ?modes, hero, KnobRow(main, size: 44, labels: labels)]);
    return effectPage('drive', [
      cards,
      ?modes,
      hero,
      KnobRow(main, size: 52, labels: labels),
      if (variant == 1 || variant == 2) chipWrap([
        if (variant == 1) const DeviceToggle('oversample', label: '2× oversample', icon: Icons.high_quality_outlined),
        if (variant == 1) const DeviceToggle('auto_gain', label: 'Auto gain', icon: Icons.auto_fix_high),
        if (variant == 2) const DeviceToggle('master', label: 'Clip to 0 dB', icon: Icons.vertical_align_top),
      ]),
      switch (variant) {
        1 => const DeviceFold(child: ParamGrid(only: ['spread', 'dynamics'])),
        2 => const DeviceFold(child: ParamGrid(only: ['oversample'])),
        3 => const DeviceFold(child: ParamGrid(only: ['normalize'])),
        _ => const SizedBox.shrink(),
      },
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
  double _drive = 0, _side = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = t.info?.variantIndex ?? 0;
    final m = driveModel(scope);
    final sideParam = switch (variant) { 1 || 3 => 'bias', 2 => 'softness', _ => null };
    const samples = 128;
    final cycle = [for (var i = 0; i < samples; i++) m.cycle(i / samples)];
    final h = cycleHarmonics(cycle);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, hh = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('drive-hero'),
        onStart: (_, _) {
          _drive = t.value('drive');
          _side = sideParam == null ? 0 : t.value(sideParam);
          DeviceFeel.grab();
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final dp = t.param('drive');
          if (dp == null) return;
          final fine = DeviceFingers.fine;
          final travel = taperOf(dp);
          _drive = travel.value((travel.position(_drive) - u.delta.dy / (hh * 1.2) * fine).clamp(0.0, 1.0));
          t.setLive('drive', _drive);
          if (sideParam != null && t.param(sideParam) != null) {
            final span = sideParam == 'bias' ? 2.0 : 1.0;
            _side = clampParam(scope, sideParam, _side + u.delta.dx / w * span * fine);
            t.setLive(sideParam, _side);
          }
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['drive', ?sideParam]) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, hh), painter: _DrivePainter(
          curve: m.curve,
          cycle: cycle,
          engineCurve: [for (var k = 0; k < 65; k++) ?f?.values['curve$k']],
          input: f?.inputDb,
          harmonics: h,
          caption: m.caption,
          color: m.color,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _DrivePainter extends CustomPainter {
  _DrivePainter({required this.curve, required this.cycle, required this.engineCurve, required this.input,
    required this.harmonics, required this.caption, required this.color, required this.second, required this.active});
  final double Function(double x)? curve;
  final List<double> cycle, engineCurve, harmonics;
  final double? input;
  final String caption;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // The curve's box: square where the hero is wide, taller than wide on a phone (the hero grows to a third of it).
    final bw0 = math.max(40.0, size.width * 0.56), bh0 = math.max(40.0, size.height - 34);
    final sq = Rect.fromLTWH(12, 26, math.min(bw0, bh0 * 1.2), bh0);
    paintLabel(canvas, caption, Offset(10, 12), color.withValues(alpha: 0.9), size: 9, weight: FontWeight.w800);
    Offset pt(double x, double y) => Offset(sq.left + (x + 1) / 2 * sq.width, sq.top + (1 - (y.clamp(-1.15, 1.15) + 1) / 2) * sq.height);
    final faint = Paint()..color = Neon.ink.withValues(alpha: 0.08);
    canvas.drawRect(sq, Paint()
      ..color = Neon.ink.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke);
    canvas.drawLine(pt(-1, 0), pt(1, 0), faint);
    canvas.drawLine(pt(0, -1), pt(0, 1), faint);
    final path = Path();
    if (curve case final c?) {
      canvas.drawLine(pt(-1, -1), pt(1, 1), Paint()..color = Neon.ink.withValues(alpha: 0.12));
      final live = engineCurve.length == 65 && engineCurve.any((v) => v != 0);
      final n = live ? 64 : 160;
      for (var i = 0; i <= n; i++) {
        final x = -1 + 2 * i / n;
        final p = pt(x, live ? engineCurve[i] : c(x));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
    } else {
      // One cycle: the clean sine faint, the bent one in colour.
      final clean = Path();
      for (var i = 0; i <= cycle.length; i++) {
        final x = -1 + 2 * i / cycle.length;
        final s = pt(x, math.sin(math.pi * (x + 1)));
        i == 0 ? clean.moveTo(s.dx, s.dy) : clean.lineTo(s.dx, s.dy);
        final p = pt(x, cycle[i % cycle.length]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(clean, Paint()
        ..color = Neon.ink.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    canvas.save();
    canvas.clipRect(sq.inflate(2));
    strokeGlow(canvas, path, color, width: active ? 3 : 2.4);
    canvas.restore();
    if (curve case final c? when input != null && input! > -60) {
      final a = math.pow(10, input! / 20).toDouble().clamp(0.0, 1.0);
      for (final x in [a, -a]) {
        final p = pt(x, c(x));
        canvas.drawCircle(p, 9, Paint()..color = Neon.ink.withValues(alpha: 0.14));
        canvas.drawCircle(p, 4, Paint()..color = Neon.ink);
      }
    }
    // The harmonics of a full-scale sine (the overtones lifted to be seen), odd in the curve's colour, even in the
    // family's second; under them the overtones' even/odd balance.
    final hx = sq.right + 16, hw = size.width - hx - 10;
    if (hw < 44) return;
    paintLabel(canvas, 'HARMONICS', Offset(hx, sq.top + 2), Neon.dim, size: 8, weight: FontWeight.w700);
    final top = harmonics.fold(1e-9, math.max);
    final bw = hw / harmonics.length;
    final base = sq.bottom - 44;
    for (var k = 0; k < harmonics.length; k++) {
      final rel = harmonics[k] / top;
      final v = k == 0 ? rel : math.pow(rel, 0.5).toDouble();
      final bh = (base - sq.top - 16) * v;
      final c = (k + 1).isOdd ? color : second;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(hx + k * bw + 1, base - bh, math.max(1, bw - 3), bh), const Radius.circular(2)),
          Paint()..color = c.withValues(alpha: k == 0 ? 0.3 : 0.85));
      paintLabel(canvas, '${k + 1}', Offset(hx + k * bw + bw / 2 - 1, base + 7), Neon.dim, size: 7, align: 0);
    }
    final even = evenShare(harmonics);
    final bar = Rect.fromLTWH(hx, sq.bottom - 12, hw, 8);
    canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(4)), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    if (even != null) {
      final split = bar.left + bar.width * even;
      canvas.drawRRect(RRect.fromRectAndCorners(Rect.fromLTRB(bar.left, bar.top, split, bar.bottom),
          topLeft: const Radius.circular(4), bottomLeft: const Radius.circular(4)), Paint()..color = second.withValues(alpha: 0.85));
      canvas.drawRRect(RRect.fromRectAndCorners(Rect.fromLTRB(split, bar.top, bar.right, bar.bottom),
          topRight: const Radius.circular(4), bottomRight: const Radius.circular(4)), Paint()..color = color.withValues(alpha: 0.85));
    }
    paintLabel(canvas, even == null ? 'CLEAN' : 'EVEN ${(even * 100).round()}%', Offset(hx, bar.top - 9), even == null ? Neon.dim : second,
        size: 8, weight: FontWeight.w700);
    if (even != null) {
      paintLabel(canvas, 'ODD ${(100 - even * 100).round()}%', Offset(bar.right, bar.top - 9), color, size: 8, align: 1,
          weight: FontWeight.w700);
    }
  }

  @override
  bool shouldRepaint(covariant _DrivePainter o) => paintInputsChanged(
      [o.curve, o.cycle, o.engineCurve, o.input, o.harmonics, o.caption, o.color, o.second, o.active],
      [curve, cycle, engineCurve, input, harmonics, caption, color, second, active]);
}
