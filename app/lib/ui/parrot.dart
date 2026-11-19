// Parrot, the joke theme's moving part: a rainbow wash and frame over the app that cycles its hues, holds still with Motion Off and Reduced, and never flashes more than three times a second.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// Parrot's motion rules, as numbers a test can check.
abstract final class ParrotMotion {
  /// One trip round the colour wheel.
  static const huePeriod = Duration(seconds: 6);

  /// The wash breathes this many times a second: slow, never a flash.
  static const pulseHz = 0.5;

  /// The limit it keeps (WCAG 2.3.1, three flashes).
  static const maxFlashesPerSecond = 3;

  static const _baseAlpha = 0.16, _pulseAlpha = 0.04;

  /// The hue (0 to 360) at [t]: turning with full motion, held at 0 otherwise.
  static double hueAt(Duration t, MotionLevel level) =>
      level == MotionLevel.full ? (t.inMicroseconds / huePeriod.inMicroseconds % 1) * 360 : 0;

  /// The wash's opacity at [t]: breathing with full motion, steady otherwise.
  static double washAlphaAt(Duration t, MotionLevel level) => level == MotionLevel.full
      ? _baseAlpha + _pulseAlpha * math.sin(2 * math.pi * pulseHz * t.inMicroseconds / 1e6)
      : _baseAlpha;

  /// The wash's colours at [hue]: the whole wheel, starting there.
  static List<Color> rainbow(double hue) =>
      [for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, (hue + i * 60) % 360, 0.9, 1).toColor()];

  /// The relative luminance (WCAG) of the wash's centre over [under] at [t]: what a flash count measures.
  static double luminanceAt(Duration t, MotionLevel level, {Color under = const Color(0xFF0A0614)}) {
    final c = Color.alphaBlend(rainbow(hueAt(t, level)).first.withValues(alpha: washAlphaAt(t, level)), under);
    return c.computeLuminance();
  }
}

/// The rainbow over [child] while [on]: a sweeping frame and a soft wash, never in the way of a touch.
class ParrotGlow extends StatefulWidget {
  const ParrotGlow({super.key, required this.on, required this.child});
  final bool on;
  final Widget child;

  @override
  State<ParrotGlow> createState() => _ParrotGlowState();
}

class _ParrotGlowState extends State<ParrotGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: ParrotMotion.huePeriod);
  MotionLevel _level = MotionLevel.full;

  void _sync() {
    if (widget.on && _level == MotionLevel.full) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _level = Motion.of(context);
    _sync();
  }

  @override
  void didUpdateWidget(ParrotGlow old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.on) return widget.child;
    return Stack(fit: StackFit.passthrough, children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                key: const ValueKey('parrot-glow'),
                painter: _ParrotPainter(_c.lastElapsedDuration ?? Duration.zero, _level),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _ParrotPainter extends CustomPainter {
  _ParrotPainter(this.t, this.level);
  final Duration t;
  final MotionLevel level;

  @override
  void paint(Canvas canvas, Size size) {
    final hue = ParrotMotion.hueAt(t, level);
    final colors = ParrotMotion.rainbow(hue);
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()
      ..shader = LinearGradient(colors: [for (final c in colors) c.withValues(alpha: ParrotMotion.washAlphaAt(t, level))])
          .createShader(rect));
    canvas.drawRect(rect.deflate(2), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..shader = SweepGradient(colors: colors, transform: GradientRotation(hue * math.pi / 180)).createShader(rect));
  }

  @override
  bool shouldRepaint(_ParrotPainter old) => old.t != t || old.level != level;
}
