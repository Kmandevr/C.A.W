// Glass surfaces (owner, 2026-11-04): an ambient background, see-through panels, frosted (or unblurred) floating things.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'tokens.dart';

/// The Glass settings. Settings sets [enabled] and [blurEnabled], like `Motion`. The Lightweight profile keeps the
/// glass look without blur; Minimal turns glass off.
class Glass {
  Glass._();

  /// The user's Glass switch; on by default.
  static bool enabled = true;

  /// The user's Frosted blur switch; on by default.
  static bool blurEnabled = true;

  /// True when glass is drawn: the switch is on and the profile isn't Minimal.
  static bool get active => enabled && Neon.performanceMode < 3;

  /// True when floating surfaces blur what is behind them: glass is on, the blur switch is on, and the profile is
  /// Full or Balanced. Otherwise they keep the glass look with a denser tint and no blur, which costs far less.
  static bool get blur => blurChosen && !strained;

  /// The blur as the settings choose it, whatever the strain: what the app's root key follows, so a change of strain
  /// redraws the screens without rebuilding them from scratch.
  static bool get blurChosen => active && blurEnabled && Neon.performanceMode < 2;

  /// True while the audio is under strain (recent overruns, or the device is hot or saving power): the shell sets
  /// it, and floating surfaces drop the blur until it clears, to protect the audio (owner, 2026-11-09).
  static bool strained = false;

  /// The frosted blur behind floating surfaces, in logical pixels.
  static const double blurSigma = 18;
}

/// A pushed page (Settings, the theme editor, the full-screen roll) on its own glass background, so the page below
/// doesn't show through while it slides in. Glass off: the plain background.
class GlassPage extends StatelessWidget {
  const GlassPage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GlassBackdrop(child: child);
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

/// A floating surface (toolbar, menu, sheet, drag preview, transport). With glass on: a frosted blur of what is
/// behind it under a see-through tint, or with blur off a denser tint, a top highlight and a bright edge. With
/// glass off: the solid raised panel colour.
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
    final body = DecoratedBox(
      decoration: Glass.blur
          ? BoxDecoration(
              borderRadius: r,
              color: Neon.panelHi.withValues(alpha: 0.55),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            )
          : _unblurred(r, Border.all(color: Colors.white.withValues(alpha: 0.16))),
      child: Padding(padding: padding, child: child),
    );
    return ClipRRect(
      borderRadius: r,
      child: Glass.blur
          ? BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: Glass.blurSigma, sigmaY: Glass.blurSigma), child: body)
          : body,
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
        // Grey and black (owner, 2026-11-10: not green): soft neutral light from the theme's text colour, with one
        // faint touch of the accent blue, so the frost still reads as glass rather than a flat colour.
        RepaintBoundary(child: CustomPaint(painter: _BackdropPainter(Neon.bg, [Neon.text, Neon.text, Neon.blue]))),
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
  static const _spots = [(0.12, 0.0, 0.95, 0.075), (0.95, 0.6, 0.8, 0.045), (0.3, 1.05, 0.9, 0.05)];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // A dark grey that deepens to black towards the bottom.
    canvas.drawRect(rect, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color.lerp(bg, const Color(0xFF2A2A30), 0.55)!, bg]).createShader(rect));
    // A faint diagonal sheen, like light across frosted glass.
    canvas.drawRect(rect, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [const Color(0x00FFFFFF), const Color(0x0AFFFFFF), const Color(0x00FFFFFF)],
        stops: const [0.30, 0.45, 0.62]).createShader(rect));
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
  bool shouldRepaint(_BackdropPainter old) => old.bg != bg || !listEquals(old.glows, glows);
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
    // With glass the sheet draws its own handle, inside the frost.
    showDragHandle: glass ? false : showDragHandle,
    constraints: constraints,
    backgroundColor: glass ? Colors.transparent : (backgroundColor ?? Neon.panel),
    elevation: glass ? 0 : null,
    sheetAnimationStyle: Motion.of(context) == MotionLevel.full ? null : AnimationStyle.noAnimation,
    builder: glass ? (c) => _GlassSheet(handle: showDragHandle, child: builder(c)) : builder,
  );
}

/// Glass without blur: a denser tint that is lighter at the top, so it still reads as glass over what is behind.
BoxDecoration _unblurred(BorderRadius r, Border border) => BoxDecoration(
      borderRadius: r,
      border: border,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(Neon.panelHi, Colors.white, 0.06)!.withValues(alpha: 0.94),
          Neon.panelHi.withValues(alpha: 0.9),
        ],
        stops: const [0, 0.4],
      ),
    );

class _GlassSheet extends StatelessWidget {
  const _GlassSheet({required this.child, this.handle = false});

  final Widget child;
  final bool handle;

  static const _radius = BorderRadius.vertical(top: Radius.circular(Radii.l + 6));

  @override
  Widget build(BuildContext context) {
    final edge = Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.16)));
    final body = DecoratedBox(
      decoration: Glass.blur
          ? BoxDecoration(borderRadius: _radius, color: Neon.panelHi.withValues(alpha: 0.62), border: edge)
          : _unblurred(_radius, edge),
      child: Material(
        type: MaterialType.transparency,
        child: handle
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(color: Neon.dim, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Flexible(child: child),
              ])
            : child,
      ),
    );
    return ClipRRect(
      borderRadius: _radius,
      child: Glass.blur
          ? BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: Glass.blurSigma, sigmaY: Glass.blurSigma), child: body)
          : body,
    );
  }
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
    // A disabled slider fades to the theme's disabled colours, as the stock track does.
    final on = ColorTween(begin: sliderTheme.disabledActiveTrackColor, end: sliderTheme.activeTrackColor ?? Neon.green)
            .evaluate(enableAnimation) ??
        Neon.green;
    final off = ColorTween(begin: sliderTheme.disabledInactiveTrackColor, end: sliderTheme.inactiveTrackColor ?? Neon.line)
            .evaluate(enableAnimation) ??
        Neon.line;
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
        ..strokeWidth = 0.8,
    );
    canvas.drawRRect(
      value,
      stroke
        ..color = on
        ..strokeWidth = 1.1,
    );
  }
}

/// A slider thumb with a solid ring. Its inside looks see-through but is opaque (the colour mixed into the panel
/// colour it always sits on), so the track never shows through the knob.
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
    final c = ColorTween(begin: sliderTheme.disabledThumbColor, end: sliderTheme.thumbColor ?? Neon.green)
            .evaluate(enableAnimation) ??
        Neon.green;
    final canvas = context.canvas;
    // The ring grows a little while the thumb is held.
    final r = radius * (1 + 0.15 * activationAnimation.value);
    final panel = Color.from(alpha: 1, red: Neon.panel.r, green: Neon.panel.g, blue: Neon.panel.b);
    canvas.drawCircle(center, r, Paint()..color = Color.lerp(panel, c.withValues(alpha: 1), 0.28)!);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = c,
    );
  }
}
