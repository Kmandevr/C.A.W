// Each device family's colour identity (two accents from the theme's neon slots, an icon), so devices read apart at a glance.
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../effects/space/space_fx.dart' show fxSpaceFamilies; // fx-space

/// The families devices are coloured by (owner, 2026-11-10: "in the theme of the app, but more colorful").
enum DeviceFamily { eq, dynamics, space, drive, filter, modulation, utility, synth, drums }

/// A family's look: [primary] for its controls and curves, [secondary] for the second voice of a visual (the right
/// channel, the output, a gradient's far end), and its [icon].
class DeviceStyle {
  const DeviceStyle(this.family, this.primary, this.secondary, this.icon, this.label);
  final DeviceFamily family;
  final Color primary, secondary;
  final IconData icon;
  final String label;

  /// The faceplate's stripe and a hero's glow: primary into secondary.
  LinearGradient get gradient => LinearGradient(colors: [primary, secondary]);

  /// The tinted dark of a hero canvas.
  Color get canvas => Color.lerp(Neon.bg, primary, 0.07)!;
}

// The theme's three extra track hues (orange, mint, red) widen the five neon accents; all follow the active theme.
Color get _orange => Neon.layers[5];
Color get _mint => Neon.layers[6];
Color get _red => Neon.layers[7];

/// The style of [family]. Colours come from theme slots, so a user theme recolours every device consistently.
DeviceStyle deviceStyle(DeviceFamily family) => switch (family) {
      DeviceFamily.eq => DeviceStyle(family, Neon.blue, _mint, Icons.graphic_eq, 'EQ'),
      DeviceFamily.dynamics => DeviceStyle(family, _orange, Neon.yellow, Icons.compress, 'DYNAMICS'),
      DeviceFamily.space => DeviceStyle(family, Neon.violet, Neon.blue, Icons.blur_on, 'SPACE'),
      DeviceFamily.drive => DeviceStyle(family, _red, Neon.pink, Icons.whatshot_outlined, 'DRIVE'),
      DeviceFamily.filter => DeviceStyle(family, _mint, Neon.green, Icons.filter_alt_outlined, 'FILTER'),
      DeviceFamily.modulation => DeviceStyle(family, Neon.pink, Neon.violet, Icons.waves, 'MOD'),
      DeviceFamily.utility => DeviceStyle(family, Neon.yellow, Neon.green, Icons.tune, 'UTILITY'),
      DeviceFamily.synth => DeviceStyle(family, Neon.green, Neon.blue, Icons.piano, 'SYNTH'),
      DeviceFamily.drums => DeviceStyle(family, _orange, Neon.pink, Icons.grid_view_rounded, 'DRUMS'),
    };

/// The family of built-in component [id], or null for anything else (a project's own C++ keeps the track colour).
DeviceFamily? familyOfComponent(String id) => switch (id) {
      'org.caw.eq' => DeviceFamily.eq,
      'org.caw.compressor' || 'org.caw.limiter' || 'org.caw.gate' || 'org.caw.transient' => DeviceFamily.dynamics,
      'org.caw.reverb.pro' || 'org.caw.delay.pro' || 'org.caw.delay.pingpong' => DeviceFamily.space,
      'org.caw.saturator' || 'org.caw.distortion' => DeviceFamily.drive,
      'org.caw.filter' => DeviceFamily.filter,
      'org.caw.phaser' || 'org.caw.flanger' || 'org.caw.chorus' => DeviceFamily.modulation,
      'org.caw.utility' || 'org.caw.stereo.width' || 'org.caw.stereo.balance' => DeviceFamily.utility,
      'org.caw.drum.kick' || 'org.caw.drum.snare' || 'org.caw.drum.hats' || 'org.caw.drum.kit' => DeviceFamily.drums,
      _ when id.startsWith('org.caw.synth.') || id == 'org.caw.bass' => DeviceFamily.synth,
      _ when fxSpaceFamilies.containsKey(id) => fxSpaceFamilies[id], // fx-space
      _ => null,
    };

/// Colours for a set of things that sit side by side (EQ bands, drum pads): the neon accents and extra hues in turn.
List<Color> spectrumColors() => [Neon.pink, _orange, Neon.yellow, Neon.green, _mint, Neon.blue, Neon.violet, _red];
