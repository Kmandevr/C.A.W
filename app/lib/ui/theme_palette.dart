// Light and dark palettes: WCAG contrast, and the generator that makes a theme's light palette from its dark one
// (and back), the same for the built-in families and for custom themes.
import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// The surface slots, darkest first in a dark palette (lightest first in a light one).
const surfaceSlots = ['bg', 'panel', 'panelHi'];

/// The five accents, which also colour text (code tokens, values, labels).
const accentSlots = ['green', 'pink', 'yellow', 'blue', 'violet'];

/// The eight track colours.
const layerSlots = ['layer1', 'layer2', 'layer3', 'layer4', 'layer5', 'layer6', 'layer7', 'layer8'];

/// WCAG 2.x AA floors: body text (text, dim and the accents, which colour text too) at 4.5:1 on every surface; track
/// colours, which draw clips, meters and large labels, at 3:1 (WCAG's large text and non-text UI floor).
const double minTextContrast = 4.5, minUiContrast = 3.0;

/// The WCAG 2.x contrast ratio of [a] and [b] (1 to 21), from their relative luminance.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The lowest contrast [c] has against any of [palette]'s surfaces.
double worstContrast(Map<String, Color> palette, Color c) =>
    surfaceSlots.map((s) => contrast(c, palette[s]!)).reduce(math.min);

/// True when [palette] is a light one: its background is lighter than mid grey.
bool isLightPalette(Map<String, Color> palette) => (palette['bg'] ?? const Color(0xFF000000)).computeLuminance() > 0.18;

/// Every slot that misses its floor in [palette] (empty when it passes AA), as `slot: ratio`.
List<String> contrastFailures(Map<String, Color> palette) => [
      for (final s in ['text', 'dim', ...accentSlots])
        if (worstContrast(palette, palette[s]!) < minTextContrast)
          '$s: ${worstContrast(palette, palette[s]!).toStringAsFixed(2)}',
      for (final s in layerSlots)
        if (worstContrast(palette, palette[s]!) < minUiContrast)
          '$s: ${worstContrast(palette, palette[s]!).toStringAsFixed(2)}',
    ];

// The generator's targets: a margin over the AA floors, so a colour rounded to 8 bits still passes.
const _textTarget = 12.0, _dimTarget = 5.0, _accentTarget = 4.8, _layerTarget = 3.4;
const _darkAccentTarget = 6.0, _darkLayerTarget = 4.5;

// Surface lightness (HSL) in each mode. A light palette mirrors the dark one, as Material 3's light surfaces do:
// raised panels are a step darker than the background, so each step reads as clearly as it does in the dark.
const _lightSurfaces = {'bg': 0.965, 'panel': 0.935, 'panelHi': 0.895, 'line': 0.80};
const _darkSurfaces = {'bg': 0.035, 'panel': 0.065, 'panelHi': 0.10, 'line': 0.19};

/// The colour of [hue] and [saturation] whose lightness is the one nearest [from] (moving toward [to]) that gives
/// at least [target] contrast against every surface in [surfaces]; [to] if none does.
Color _seek(double hue, double saturation, List<Color> surfaces, double target, double from, double to) {
  Color at(double l) => HSLColor.fromAHSL(1, hue, saturation, l).toColor();
  bool ok(double l) => surfaces.every((s) => contrast(at(l), s) >= target);
  if (ok(from)) return at(from);
  if (!ok(to)) return at(to);
  // Contrast against these surfaces rises steadily from [from] to [to]: halve toward the first lightness that passes.
  var a = from, b = to;
  for (var i = 0; i < 24; i++) {
    final m = (a + b) / 2;
    if (ok(m)) {
      b = m;
    } else {
      a = m;
    }
  }
  return at(b);
}

Map<String, Color> _surfaces(Color bg, Map<String, double> lightness, double maxSaturation) {
  final h = HSLColor.fromColor(bg);
  final s = math.min(h.saturation, maxSaturation);
  return {for (final e in lightness.entries) e.key: HSLColor.fromAHSL(1, h.hue, s, e.value).toColor()};
}

/// A light palette made from the dark [dark]: the same hues, surfaces mirrored to near-white tinted like the dark
/// background, text and the accents darkened (and a touch less saturated) until each passes AA on every surface.
/// Glow and glass are tuned for light by [Neon] itself, not here.
Map<String, Color> lightFrom(Map<String, Color> dark) {
  final out = _surfaces(dark['bg']!, _lightSurfaces, 0.5);
  final surfaces = [for (final s in surfaceSlots) out[s]!];
  Color text(String slot, double satCap, double target, double ceiling) {
    final h = HSLColor.fromColor(dark[slot]!);
    return _seek(h.hue, math.min(h.saturation, satCap), surfaces, target, ceiling, 0);
  }

  out['text'] = text('text', 0.3, _textTarget, 0.5);
  out['dim'] = text('dim', 0.25, _dimTarget, 0.6);
  for (final s in accentSlots) {
    out[s] = text(s, 0.9, _accentTarget, 0.5);
  }
  for (final s in layerSlots) {
    out[s] = text(s, 0.9, _layerTarget, 0.55);
  }
  return out;
}

/// A dark palette made from the light [light], the reverse of [lightFrom]: near-black surfaces tinted like the light
/// background, text and the accents lightened (and a touch more saturated) until each passes AA on every surface.
Map<String, Color> darkFrom(Map<String, Color> light) {
  final out = _surfaces(light['bg']!, _darkSurfaces, 0.4);
  final surfaces = [for (final s in surfaceSlots) out[s]!];
  Color text(String slot, double satScale, double satCap, double target, double floor) {
    final h = HSLColor.fromColor(light[slot]!);
    return _seek(h.hue, math.min(1, math.min(h.saturation * satScale, satCap)), surfaces, target, floor, 1);
  }

  out['text'] = text('text', 1, 0.25, _textTarget, 0.85);
  out['dim'] = text('dim', 1, 0.2, _dimTarget, 0.5);
  for (final s in accentSlots) {
    out[s] = text(s, 1.1, 1, _darkAccentTarget, 0.55);
  }
  for (final s in layerSlots) {
    out[s] = text(s, 1.1, 1, _darkLayerTarget, 0.55);
  }
  return out;
}

/// [palette] with every text, dim, accent or track colour that misses its AA floor moved, at its own hue and
/// saturation, to the nearest lightness that passes (darker on a light palette, lighter on a dark one). Colours
/// that pass stay exactly as they are.
Map<String, Color> withSafeContrast(Map<String, Color> palette) {
  final light = isLightPalette(palette);
  final surfaces = [for (final s in surfaceSlots) palette[s]!];
  final out = {...palette};
  for (final s in ['text', 'dim', ...accentSlots, ...layerSlots]) {
    final floor = layerSlots.contains(s) ? _layerTarget : (s == 'text' ? 7.0 : _accentTarget);
    final c = palette[s]!;
    if (worstContrast(palette, c) >= (layerSlots.contains(s) ? minUiContrast : minTextContrast)) continue;
    final h = HSLColor.fromColor(c);
    out[s] = _seek(h.hue, h.saturation, surfaces, floor, h.lightness, light ? 0 : 1);
  }
  return out;
}

/// The other mode's palette of [palette]: a light one from a dark one, a dark one from a light one.
Map<String, Color> otherPalette(Map<String, Color> palette) =>
    isLightPalette(palette) ? darkFrom(palette) : lightFrom(palette);
