// The utility family's plugin UI (utility, width, balance): the stereo field as a fan you drag (pan sideways, width up or pinch),
// phase and mono marks, the output's correlation.
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

/// The utility, the width and the balance: the stereo field (drag sideways for pan, up and down or pinch for width),
/// the correlation of what comes out, then the switches and knobs the device has.
class StereoPage extends StatelessWidget {
  const StereoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('stereo', [
      HeroWithMeters(height: 210, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'STEREO FIELD',
        grid: false,
        readout: Text([
          if (t.param('width') != null) 'width ${(t.value('width') * 100).round()}%',
          if (t.param('pan') != null) 'pan ${formatParamValue(t.param('pan'), t.value('pan'), pan: true)}',
        ].join(' · ')),
        child: const _FieldHero(),
      )),
      DeviceDisplay(builder: (context, f) => _Correlation(value: f?.values['correlation'])),
      if (t.param('channels') != null) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [
        const Text('CHANNELS', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
        const SizedBox(width: 8),
        const Flexible(child: DeviceChoice('channels', maxSegments: 5)),
      ])),
      Padding(padding: const EdgeInsets.only(top: 8), child: Wrap(spacing: 6, runSpacing: 6, children: const [
        DeviceToggle('invert_l', label: 'Ø Left', icon: Icons.swap_vert),
        DeviceToggle('invert_r', label: 'Ø Right', icon: Icons.swap_vert),
        DeviceToggle('bass_mono', label: 'Bass mono', icon: Icons.speaker_outlined),
        DeviceToggle('dc_block', label: 'DC block', icon: Icons.horizontal_rule),
      ])),
      KnobRow(['gain', 'width', 'pan', if (t.value('bass_mono') >= 0.5) 'bass_freq'], size: 56),
    ]);
  }
}

class _Correlation extends StatelessWidget {
  const _Correlation({required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final c = DeviceScope.of(context).accent;
    return Semantics(
      label: 'Correlation',
      value: value?.toStringAsFixed(2) ?? 'no signal',
      child: SizedBox(height: 26, child: Row(children: [
        const SizedBox(width: 30, child: Text('−1', style: TextStyle(fontSize: 9, color: Neon.dim))),
        Expanded(child: CustomPaint(size: const Size.fromHeight(10), painter: _CorrPainter(value, c))),
        const SizedBox(width: 30, child: Text('+1', textAlign: TextAlign.right, style: TextStyle(fontSize: 9, color: Neon.dim))),
      ])),
    );
  }
}

class _CorrPainter extends CustomPainter {
  _CorrPainter(this.v, this.color);
  final double? v;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, size.height / 2 - 4, size.width, 8), const Radius.circular(4));
    canvas.drawRRect(r, Paint()
      ..shader = LinearGradient(colors: Neon.ramp([Neon.pink.withValues(alpha: 0.35), Neon.ink.withValues(alpha: 0.08),
        color.withValues(alpha: 0.35)])).createShader(r.outerRect));
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), Paint()..color = Neon.ink.withAlpha(0x3D));
    if (v case final x?) {
      final px = (x.clamp(-1.0, 1.0) + 1) / 2 * size.width;
      final c = x < 0 ? Neon.pink : color;
      canvas.drawCircle(Offset(px, size.height / 2), 7, Paint()..color = c.withValues(alpha: 0.3));
      canvas.drawCircle(Offset(px, size.height / 2), 4, Paint()..color = c);
    }
  }

  @override
  bool shouldRepaint(covariant _CorrPainter o) => o.v != v || o.color != color;
}

class _FieldHero extends StatefulWidget {
  const _FieldHero();

  @override
  State<_FieldHero> createState() => _FieldHeroState();
}

class _FieldHeroState extends State<_FieldHero> {
  bool _active = false;
  double _pan = 0, _width = 1, _width0 = 1;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final hasPan = t.param('pan') != null, hasWidth = t.param('width') != null;
    final pan = hasPan ? t.value('pan') : 0.0, width = hasWidth ? t.value('width') : 1.0;
    final channels = t.param('channels') == null ? 0 : t.value('channels').round();
    final gain = t.param('gain') == null ? 0.0 : t.value('gain');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return GrabGesture(
        key: const ValueKey('stereo-hero'),
        onStart: (_, pointers) {
          _pan = pan;
          _width = _width0 = width;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          if (u.pointers >= 2) {
            if (hasWidth) t.setLive('width', _width0 * u.scale);
            return;
          }
          if (hasPan) {
            _pan = (_pan + u.delta.dx / (w / 2) * fine).clamp(-1.0, 1.0);
            if (_pan.abs() < 0.02 && (_pan - u.delta.dx / (w / 2) * fine).abs() >= 0.02) DeviceFeel.detent();
            t.setLive('pan', _pan.abs() < 0.02 ? 0 : _pan);
          }
          if (hasWidth) {
            _width = (_width - u.delta.dy / (h * 0.6) * 2 * fine).clamp(0.0, 2.0);
            t.setLive('width', _width);
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['pan', 'width']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: DevicePhase(builder: (context, secs) => CustomPaint(size: Size(w, h), painter: _FieldPainter(
          pan: pan, width: channels == 1 ? 0 : width, channels: channels, gain: gain,
          invertL: t.value('invert_l') >= 0.5, invertR: t.value('invert_r') >= 0.5,
          bassMono: t.value('bass_mono') >= 0.5, bassHz: t.param('bass_freq') == null ? 120 : t.value('bass_freq'),
          secs: secs, color: scope.accent, second: scope.secondary, active: _active))),
      );
    });
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter({required this.pan, required this.width, required this.channels, required this.gain,
    required this.invertL, required this.invertR, required this.bassMono, required this.bassHz, required this.secs,
    required this.color, required this.second, required this.active});
  final double pan, width, gain, bassHz, secs;
  final int channels;
  final bool invertL, invertR, bassMono, active;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height - 14);
    final radius = math.min(size.width / 2 - 16, size.height - 40);
    // The half-circle: left at 180°, right at 0°.
    final arcs = Paint()
      ..color = Neon.ink.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke;
    for (final k in [0.33, 0.66, 1.0]) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: radius * k), math.pi, math.pi, false, arcs);
    }
    for (final a in [math.pi, math.pi * 1.25, math.pi * 1.5, math.pi * 1.75, math.pi * 2]) {
      canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * radius, arcs);
    }
    paintLabel(canvas, 'L', c + Offset(-radius - 8, -6), invertL ? Neon.pink : color, size: 10, align: 0, weight: FontWeight.w800);
    paintLabel(canvas, 'R', c + Offset(radius + 8, -6), invertR ? Neon.pink : second, size: 10, align: 0, weight: FontWeight.w800);
    if (invertL) paintLabel(canvas, 'Ø', c + Offset(-radius - 8, -22), Neon.pink, size: 12, align: 0, weight: FontWeight.w800);
    if (invertR) paintLabel(canvas, 'Ø', c + Offset(radius + 8, -22), Neon.pink, size: 12, align: 0, weight: FontWeight.w800);
    // The image: a fan centred on the pan, half as wide as 90° per unit of width (0 mono, 2 the whole field).
    final centre = channels == 2 ? -1.0 : (channels == 3 ? 1.0 : pan);
    final mid = math.pi * 1.5 + centre * math.pi / 2;
    final half = (channels == 2 || channels == 3) ? 0.0 : (width.clamp(0.0, 2.0) * math.pi / 4);
    final lo = math.max(math.pi, mid - half), hi = math.min(math.pi * 2, mid + half);
    final reach = radius * (0.55 + 0.45 * ((gain + 60) / 84).clamp(0.0, 1.0));
    final fan = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(Rect.fromCircle(center: c, radius: reach), lo, math.max(0.02, hi - lo), false)
      ..close();
    canvas.drawPath(fan, Paint()
      ..shader = RadialGradient(colors: Neon.ramp([color.withValues(alpha: 0.55), second.withValues(alpha: 0.12)]))
          .createShader(Rect.fromCircle(center: c, radius: reach)));
    strokeGlow(canvas, Path()..addArc(Rect.fromCircle(center: c, radius: reach), lo, math.max(0.02, hi - lo)), color,
        width: active ? 3 : 2.2);
    // Particles: the sound inside the image, flickering.
    var seed = 77;
    double rand() {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return seed / 0x7FFFFFFF;
    }
    for (var i = 0; i < 46; i++) {
      final a = lo + (hi - lo) * rand();
      final r = reach * (0.15 + 0.8 * rand()) * (0.85 + 0.15 * math.sin(secs * (3 + 4 * rand()) + i));
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * r, 1.6, Paint()..color = Neon.ink.withValues(alpha: 0.5 * rand() + 0.2));
    }
    if (bassMono) {
      canvas.drawCircle(c, radius * 0.22, Paint()..color = Neon.yellow.withValues(alpha: 0.18));
      paintLabel(canvas, 'MONO < ${bassHz.round()} Hz', c + Offset(0, -radius * 0.22 - 8), Neon.yellow, size: 8, align: 0,
          weight: FontWeight.w800);
    }
    if (channels == 4) paintLabel(canvas, 'L ⇄ R', c + Offset(0, -radius - 4), Neon.text, size: 10, align: 0, weight: FontWeight.w800);
    paintHandle(canvas, c + Offset(math.cos(mid), math.sin(mid)) * reach, color, active: active, r: 7);
  }

  @override
  bool shouldRepaint(covariant _FieldPainter o) => true;
}
