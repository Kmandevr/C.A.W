// Design tokens: spacing, radii, type sizes, touch targets and colours by role, so every screen looks like one app.
import 'package:flutter/material.dart';

import 'theme.dart';

/// Spacing steps (logical pixels). Layouts use these instead of loose numbers.
class Space {
  Space._();
  static const double xs = 4, s = 8, m = 12, l = 16, xl = 24;
}

/// Corner radii: small for chips and notes, medium for buttons and cards, large for sheets and panels.
class Radii {
  Radii._();
  static const double s = 6, m = 10, l = 14;
}

/// Touch targets: 48 dp when comfortable (Android's guidance), 36 dp when compact.
class Targets {
  Targets._();
  static const double comfortable = 48, compact = 36;
  static double of(BuildContext context) => Neon.compact(context) ? compact : comfortable;
}

/// The type scale. UI text uses the system font, code and numbers the bundled mono ([Neon.code]).
class TypeScale {
  TypeScale._();
  static const double caption = 11, label = 12, body = 14, title = 16;

  /// A section heading: small capitals, spaced, quiet.
  static TextStyle heading() => const TextStyle(fontSize: caption, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: Neon.dim);

  /// A number readout (BPM, lengths, values), in the mono font so digits don't jump.
  static TextStyle number({double size = label, Color color = Neon.text}) => Neon.code(size: size, color: color);
}

/// Colours by meaning (owner, 2026-11-04: track colours plus one accent). Screens use these, not a colour per screen.
class Roles {
  Roles._();

  /// The one main accent: play, primary actions, the selected tab.
  static const Color accent = Neon.green;

  /// Selection, focus and the edit cursor.
  static const Color selection = Neon.blue;

  /// Warnings and edits in progress.
  static const Color warning = Neon.yellow;

  /// Errors, delete, record.
  static const Color danger = Neon.pink;

  /// Automation and modulation.
  static const Color automation = Neon.violet;

  /// Track [i]'s colour, wrapping over the theme's track colours.
  static Color track(int i) => Neon.layer(i);
}
