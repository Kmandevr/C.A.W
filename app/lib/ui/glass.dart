// Glass surfaces (owner, 2026-11-04): real frosted blur only on floating things, a cheap glass look on docked panels.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'tokens.dart';

/// The Glass setting. Settings sets [enabled], like `Motion`; the Lightweight and Minimal profiles turn it off.
class Glass {
  Glass._();

  /// The user's switch; on by default.
  static bool enabled = true;

  /// True when glass is drawn: the switch is on and the performance profile is Full or Balanced.
  static bool get active => enabled && Neon.performanceMode < 2;

  /// The frosted blur behind floating surfaces, in logical pixels.
  static const double blurSigma = 18;
}

/// A docked panel's surface. With glass on: a translucent tint, a soft highlight along the top and a thin
/// white edge, and no blur (docked panels redraw often). With glass off: the plain panel colour and line border.
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.radius = Radii.m, this.tint});

  final Widget child;
  final double radius;

  /// The colour the tint leans to (a track colour, say); the panel colour by default.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    if (!Glass.active) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Neon.panel,
          borderRadius: r,
          border: Border.all(color: Neon.line),
        ),
        child: ClipRRect(borderRadius: r, child: child),
      );
    }
    final base = tint == null ? Neon.panel : Color.lerp(Neon.panel, tint, 0.08)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(base, Colors.white, 0.05)!.withValues(alpha: 0.8), base.withValues(alpha: 0.7)],
          stops: const [0, 0.35],
        ),
      ),
      child: ClipRRect(borderRadius: r, child: child),
    );
  }
}

/// A floating surface (toolbar, menu, sheet, drag preview, transport). With glass on: a real frosted blur of what
/// is behind it under a see-through tint. With glass off: the solid raised panel colour.
class GlassOverlay extends StatelessWidget {
  const GlassOverlay({super.key, required this.child, this.radius = Radii.l, this.padding = EdgeInsets.zero});

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    if (!Glass.active) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Neon.panelHi,
          borderRadius: r,
          border: Border.all(color: Neon.line),
        ),
        child: ClipRRect(
          borderRadius: r,
          child: Padding(padding: padding, child: child),
        ),
      );
    }
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: Glass.blurSigma, sigmaY: Glass.blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: r,
            color: Neon.panelHi.withValues(alpha: 0.55),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// The ambient background behind every screen while glass is on: the theme's background with a few large, faint
/// glows of the accent colours, so the see-through panels sit on depth instead of a flat colour. Drawn once.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Glass.active) return ColoredBox(color: Neon.bg, child: child);
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: CustomPaint(painter: _BackdropPainter(Neon.bg, [Neon.green, Neon.blue, Neon.violet]))),
        child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  // Theme colours become plain colours here: a painter's Paint doesn't read a theme slot's overridden channels.
  _BackdropPainter(Color bg, List<Color> glows)
      : bg = _plain(bg),
        glows = [for (final g in glows) _plain(g)];

  static Color _plain(Color c) => Color.from(alpha: c.a, red: c.r, green: c.g, blue: c.b);

  final Color bg;
  final List<Color> glows;

  /// Where each glow sits (fractions of the screen), its radius (of the longer side) and strength.
  static const _spots = [(0.12, 0.05, 0.9, 0.13), (0.95, 0.55, 0.8, 0.10), (0.3, 1.05, 0.9, 0.08)];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final long = size.longestSide;
    for (var i = 0; i < _spots.length && i < glows.length; i++) {
      final (x, y, r, a) = _spots[i];
      final centre = Offset(size.width * x, size.height * y);
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = RadialGradient(
            colors: [
              glows[i].withValues(alpha: a),
              glows[i].withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: centre, radius: long * r)),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.bg != bg || old.glows != glows;
}

/// A bottom sheet that slides up as frosted glass (a plain sheet with glass off). Takes the same arguments as the
/// `showModalBottomSheet` calls it replaces. Reduced and Off motion show it without the slide.
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool showDragHandle = false,
  BoxConstraints? constraints,
}) {
  final glass = Glass.active;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    constraints: constraints,
    backgroundColor: glass ? Colors.transparent : (backgroundColor ?? Neon.panel),
    elevation: glass ? 0 : null,
    sheetAnimationStyle: Motion.of(context) == MotionLevel.full ? null : AnimationStyle.noAnimation,
    builder: glass ? (c) => _GlassSheet(child: builder(c)) : builder,
  );
}

class _GlassSheet extends StatelessWidget {
  const _GlassSheet({required this.child});

  final Widget child;

  static const _radius = BorderRadius.vertical(top: Radius.circular(Radii.l + 6));

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: _radius,
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: Glass.blurSigma, sigmaY: Glass.blurSigma),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: _radius,
          color: Neon.panelHi.withValues(alpha: 0.62),
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.16))),
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    ),
  );
}

/// A slider track with a see-through fill and a solid outline: the whole track outlined in the inactive colour,
/// the value part filled faintly and outlined in the active colour.
class GlassSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const GlassSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.isEmpty) return;
    final canvas = context.canvas;
    final r = Radius.circular(rect.height / 2);
    final on = sliderTheme.activeTrackColor ?? Neon.green;
    final off = sliderTheme.inactiveTrackColor ?? Neon.line;
    final whole = RRect.fromRectAndRadius(rect, r);
    final ltr = textDirection == TextDirection.ltr;
    final x = thumbCenter.dx.clamp(rect.left, rect.right);
    final value = RRect.fromRectAndRadius(
      ltr ? Rect.fromLTRB(rect.left, rect.top, x, rect.bottom) : Rect.fromLTRB(x, rect.top, rect.right, rect.bottom),
      r,
    );
    canvas.drawRRect(whole, Paint()..color = off.withValues(alpha: off.a * 0.25));
    canvas.drawRRect(value, Paint()..color = on.withValues(alpha: on.a * 0.32));
    final stroke = Paint()..style = PaintingStyle.stroke;
    canvas.drawRRect(
      whole,
      stroke
        ..color = off
        ..strokeWidth = 1,
    );
    canvas.drawRRect(
      value,
      stroke
        ..color = on
        ..strokeWidth = 1.5,
    );
  }
}

/// A slider thumb as a see-through disc with a solid ring.
class GlassSliderThumbShape extends SliderComponentShape {
  const GlassSliderThumbShape({this.radius = 9});

  final double radius;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.fromRadius(radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final c = sliderTheme.thumbColor ?? Neon.green;
    final canvas = context.canvas;
    // The ring grows a little while the thumb is held.
    final r = radius * (1 + 0.15 * activationAnimation.value);
    canvas.drawCircle(center, r, Paint()..color = Color.lerp(Neon.bg, c, 0.3)!.withValues(alpha: 0.85));
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = c,
    );
  }
}
