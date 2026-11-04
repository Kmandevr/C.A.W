// Glass surfaces (owner, 2026-11-04): real frosted blur only on floating things, a cheap glass look on docked panels.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
        decoration: BoxDecoration(color: Neon.panel, borderRadius: r, border: Border.all(color: Neon.line)),
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
          colors: [
            Color.lerp(base, Colors.white, 0.05)!.withValues(alpha: 0.92),
            base.withValues(alpha: 0.86),
          ],
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
        decoration: BoxDecoration(color: Neon.panelHi, borderRadius: r, border: Border.all(color: Neon.line)),
        child: ClipRRect(borderRadius: r, child: Padding(padding: padding, child: child)),
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
