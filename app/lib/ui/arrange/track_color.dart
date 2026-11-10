// A track's colour on screen: its own, or a shade of its folder's (owner, 2026-11-10: colours carry meaning by folder).
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/project.dart';
import '../theme.dart';

/// Shades for the tracks in a folder, in order: lighter and darker steps around the folder's colour.
const _shades = [0.18, -0.16, 0.34, -0.30, 0.08, -0.06];

/// [layer]'s colour: a top-level track or folder, or one the user coloured ([LayerDoc.ownColor]), keeps its own;
/// a track in a folder takes a shade of its folder's colour (which may itself come from a folder above).
Color trackColor(AppState state, LayerDoc layer) => trackColorIn(state.project.layers, layer);

Color trackColorIn(List<LayerDoc> layers, LayerDoc layer, [int depth = 0]) {
  final parentId = layer.parentId;
  // Any depth (folders nest without a limit); the walk ends at the layer count, so a broken loop ends too.
  if (layer.ownColor || parentId == null || depth > layers.length) return Neon.layer(layer.color);
  final folder = layers.where((l) => l.id == parentId).firstOrNull;
  if (folder == null) return Neon.layer(layer.color);
  final base = trackColorIn(layers, folder, depth + 1);
  final siblings = layers.where((l) => l.parentId == parentId).toList();
  final shade = _shades[siblings.indexOf(layer).clamp(0, 1 << 20) % _shades.length];
  return shade >= 0 ? Color.lerp(base, Colors.white, shade)! : Color.lerp(base, Colors.black, -shade)!;
}
