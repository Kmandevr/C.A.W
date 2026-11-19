// C.A.W's own line icons from the bundled CawIcons font (scripts/icon-font.js): the bird-family hints and the quill.
import 'package:flutter/widgets.dart';

/// Line icons in the Material icons' size and weight, each with a hint of a bird-family name.
abstract final class CawIcons {
  static const _family = 'CawIcons';

  /// Roost (reverb, the space family): a tail of arcs over a branch.
  static const roost = IconData(0xe001, fontFamily: _family);

  /// Talon (dynamics): a compressor curve whose end hooks like a claw.
  static const talon = IconData(0xe002, fontFamily: _family);

  /// Plume (EQ): a feather whose edge rises like a bell.
  static const plume = IconData(0xe003, fontFamily: _family);

  /// Nest (racks): a woven bowl.
  static const nest = IconData(0xe004, fontFamily: _family);

  /// The drag-to-modulate handle.
  static const quill = IconData(0xe005, fontFamily: _family);
}
