// Light and dark palettes: WCAG contrast, and the generator that makes a theme's light palette from its dark one
// (and back), the same for the built-in families and for custom themes, and the palette builder (seeds, harmony).
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

/// How the palette builder spreads its accents around the seed hue (owner, 2026-11-11: "a theme editor that builds
/// the theme for you").
enum Harmony {
  analogous('Analogous'),
  complementary('Complementary'),
  triadic('Triadic'),
  monochrome('Monochrome');

  const Harmony(this.label);
  final String label;
}

/// What the palette builder makes a theme from: one or two seed colours, a harmony and a variation number
/// ([buildPalettes]; Shuffle picks another [variation]). The same recipe always makes the same palettes.
class PaletteRecipe {
  const PaletteRecipe({required this.seed, this.second, this.harmony = Harmony.analogous, this.variation = 0});
  final Color seed;
  final Color? second;
  final Harmony harmony;
  final int variation;

  PaletteRecipe copyWith({Color? seed, Color? second, bool clearSecond = false, Harmony? harmony, int? variation}) =>
      PaletteRecipe(
          seed: seed ?? this.seed,
          second: clearSecond ? null : (second ?? this.second),
          harmony: harmony ?? this.harmony,
          variation: variation ?? this.variation);
}

/// A named starting point for the builder.
class PaletteMood {
  const PaletteMood(this.name, this.recipe);
  final String name;
  final PaletteRecipe recipe;
}

/// The builder's mood presets.
const paletteMoods = [
  PaletteMood('Ocean', PaletteRecipe(seed: Color(0xFF1E9BD7), harmony: Harmony.analogous)),
  PaletteMood('Forest', PaletteRecipe(seed: Color(0xFF3FAE5A), harmony: Harmony.analogous)),
  PaletteMood('Sunset', PaletteRecipe(seed: Color(0xFFFF7A45), second: Color(0xFFB44CD9), harmony: Harmony.complementary)),
  PaletteMood('Synthwave', PaletteRecipe(seed: Color(0xFFFF3CAC), second: Color(0xFF2DE2E6), harmony: Harmony.complementary)),
  PaletteMood('Candy', PaletteRecipe(seed: Color(0xFFFF6FB5), harmony: Harmony.triadic)),
  PaletteMood('Studio', PaletteRecipe(seed: Color(0xFF6E8BA8), harmony: Harmony.monochrome)),
];

/// The builder's seed swatches.
const seedSwatches = [
  Color(0xFFFF4D5E), Color(0xFFFF8A1F), Color(0xFFFFC21F), Color(0xFF39D353), Color(0xFF2BD9C0),
  Color(0xFF1FA8FF), Color(0xFF6C7BFF), Color(0xFFB46CFF), Color(0xFFFF2BD6), Color(0xFF8C95A3),
];

double _wrap(double h) => (h % 360 + 360) % 360;

/// The dark and light palettes for [r]: surfaces tinted by the seed, text and dim text, the five accents at the
/// harmony's hues (the danger accent, `pink`, which also marks a clipping meter, kept in the red to magenta range),
/// and eight track colours in a ramp around the wheel from the seed. Every colour then passes AA in both modes
/// ([withSafeContrast], [lightFrom]). Deterministic: the same recipe gives the same palettes.
({Map<String, Color> dark, Map<String, Color> light}) buildPalettes(PaletteRecipe r) {
  final rnd = math.Random(r.variation * 7919 + r.harmony.index * 31 + r.seed.toARGB32() % 1000003);
  double jitter(double span) => r.variation == 0 ? 0 : (rnd.nextDouble() * 2 - 1) * span;
  final s1 = HSLColor.fromColor(r.seed);
  final h1 = s1.hue;
  final h2 = r.second == null ? null : HSLColor.fromColor(r.second!).hue;
  final sat = ((s1.saturation < 0.12 ? 0.45 : s1.saturation) + jitter(0.08)).clamp(0.45, 0.95);
  // Five accent hues for green (the main accent), pink, yellow, blue and violet.
  final List<double> hues = switch (r.harmony) {
    Harmony.analogous => [h1, h2 ?? h1 + 150, h1 + 40, h1 - 35, h1 + 75],
    Harmony.complementary => [h1, h2 ?? h1 + 180, h1 + 30, (h2 ?? h1 + 180) + 30, h1 - 40],
    Harmony.triadic => [h1, h2 ?? h1 + 120, h1 + 240, h1 + 60, h1 + 180],
    Harmony.monochrome => [h1, h2 ?? h1, h1 + 12, h1 - 12, h1 + 24],
  };
  // Shuffle: a different order for the four supporting hues and a small turn of the wheel.
  final support = hues.sublist(1);
  if (r.variation != 0) support.shuffle(rnd);
  final turn = jitter(12);
  final accents = [hues[0], ...support].map((h) => _wrap(h + turn)).toList();
  // The danger accent stays recognisably red to magenta (errors, record, a clipping meter).
  final danger = accents[1];
  final inRed = danger >= 320 || danger <= 15;
  if (!inRed) accents[1] = _wrap(r.harmony == Harmony.monochrome ? 350 : (danger < 167 ? 5 : 335));
  final mono = r.harmony == Harmony.monochrome;
  final dark = <String, Color>{};
  final surfSat = ((mono ? 0.18 : 0.22) + jitter(0.06)).clamp(0.0, 1.0);
  dark['bg'] = HSLColor.fromAHSL(1, h1, surfSat, 0.045).toColor();
  dark['panel'] = HSLColor.fromAHSL(1, h1, surfSat, 0.075).toColor();
  dark['panelHi'] = HSLColor.fromAHSL(1, h1, surfSat, 0.11).toColor();
  dark['line'] = HSLColor.fromAHSL(1, h1, surfSat, 0.2).toColor();
  dark['text'] = HSLColor.fromAHSL(1, h1, 0.12, 0.92).toColor();
  dark['dim'] = HSLColor.fromAHSL(1, h1, 0.1, 0.62).toColor();
  for (final (i, slot) in accentSlots.indexed) {
    final l = mono ? 0.55 + 0.06 * i : 0.6;
    dark[slot] = HSLColor.fromAHSL(1, accents[i], mono && i > 1 ? sat * 0.7 : sat, l.clamp(0.0, 0.85)).toColor();
  }
  // Eight track colours: around the wheel from the seed (monochrome: a narrow band, stepped in lightness).
  for (final (i, slot) in layerSlots.indexed) {
    final h = mono ? h1 + (i - 3.5) * 9 : h1 + i * 45 + turn;
    final l = mono ? 0.5 + 0.035 * i : 0.6;
    dark[slot] = HSLColor.fromAHSL(1, _wrap(h), sat, l).toColor();
  }
  final safe = withSafeContrast(dark);
  return (dark: safe, light: lightFrom(safe));
}
