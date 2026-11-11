// How Arrange's clips look (a theme's track look, owner 2026-11-11): their corner shape and fill, read when a clip builds.
import 'package:flutter/material.dart';

import '../glass.dart';
import '../tokens.dart';

/// A clip's corners: Square, Rounded (the theme's corner roundness, [Radii.scale]) or Round (pill ends).
enum ClipCorner {
  square('Square'),
  rounded('Rounded'),
  round('Round');

  const ClipCorner(this.label);
  final String label;
}

/// A clip's fill: Standard (as the Glass setting draws it: a faint gradient with glass, a tint without), Solid, an
/// Outline only, or a Gradient.
enum ClipFill {
  standard('Standard'),
  solid('Solid'),
  outline('Outline'),
  gradient('Gradient');

  const ClipFill(this.label);
  final String label;
}

/// The theme's clip look. Settings sets the statics, like `Neon`.
class ClipLook {
  ClipLook._();

  static ClipCorner corner = ClipCorner.rounded;
  static ClipFill fill = ClipFill.standard;

  /// The corner radius of a clip [height] tall: 5 px times the theme's roundness for Rounded (5 as designed).
  static double radius(double height) => switch (corner) {
        ClipCorner.square => 0,
        ClipCorner.rounded => 5 * Radii.scale,
        ClipCorner.round => height / 2,
      };

  /// The colour under a clip (its Material): the tint for Standard without glass and for Solid, nothing otherwise.
  static Color under(Color color, bool selected) => switch (fill) {
        ClipFill.standard => Glass.active ? Colors.transparent : color.withValues(alpha: selected ? .42 : .23),
        ClipFill.solid => color.withValues(alpha: selected ? .5 : .32),
        ClipFill.outline || ClipFill.gradient => Colors.transparent,
      };

  /// The gradient over a clip: Standard with glass, and Gradient; none otherwise.
  static Gradient? gradient(Color color, bool selected) =>
      fill == ClipFill.gradient || (fill == ClipFill.standard && Glass.active)
          ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
              color.withValues(alpha: selected ? .40 : .26),
              color.withValues(alpha: selected ? .24 : .12),
            ])
          : null;
}
