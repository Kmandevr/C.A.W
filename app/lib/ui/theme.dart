// The look: themes (the five built-in families, each light and dark), the readable theme file, the active theme behind Neon.*, fonts.
import 'dart:ui' show ColorSpace;

import 'package:flutter/material.dart';

import 'glass.dart';
import 'theme_palette.dart';

/// One theme: a dark and a light palette (owner, 2026-11-11: light and dark for every built-in theme; the Mode
/// switch picks which one shows), whether active things glow, whether it is [flat], and (owner, 2026-11-11: a theme
/// is a full profile) the rest of its look, layout and behaviour in [profile]. Saved as a readable theme file.
///
/// A theme object shows one palette ([light]); [shown] gives the same theme in the other mode, kept as one object
/// per mode so a mode switch back and forth makes no new theme (and no new Material theme).
class CawTheme {
  CawTheme({
    required this.name,
    required Map<String, Color> colors,
    Map<String, Color>? lightColors,
    this.glow = true,
    this.flat = false,
    this.profile = const {},
    this.light = false,
  })  : darkColors = colors,
        _lightGiven = lightColors;

  final String name;

  /// The dark palette (the file's plain `slot:` lines). A slot left out comes from Neon's.
  final Map<String, Color> darkColors;

  /// The light palette as set (the file's `light.slot:` lines); null when it is made from the dark one.
  final Map<String, Color>? _lightGiven;

  /// The light palette: as set, or made from the dark one by [lightFrom] (the built-ins' own algorithm).
  late final Map<String, Color> lightColors = _lightGiven == null
      ? lightFrom(_full(darkColors, _neonDark))
      : _full(_lightGiven, lightFrom(_full(darkColors, _neonDark)));

  /// True when the light palette was set rather than made ([lightFrom]).
  bool get hasOwnLight => _lightGiven != null;

  /// Which palette this object shows.
  final bool light;
  final bool glow;

  /// The plain look of a standard DAW (the Flat family, owner 2026-11-11): no glow and no glass whatever the
  /// settings say, solid fills instead of gradients. Kept in both modes.
  final bool flat;

  /// The palette shown.
  Map<String, Color> get colors => light ? lightColors : darkColors;

  /// The profile's values by key (`look.font`, `layout.track_height`, `behaviour.motion`, ...), as the file writes
  /// them. Settings reads and fills them ([Settings.captureProfile]); a key left out (a colours-only theme from
  /// before profiles, a value added later) keeps the current setting when the theme is chosen. Empty for the
  /// starter themes, which share the user's own settings.
  final Map<String, String> profile;

  /// The parts of a profile, in file order: a key starts with one of them and a dot.
  static const profileParts = ['look', 'layout', 'behaviour'];

  static bool isProfileKey(String key) {
    final dot = key.indexOf('.');
    return dot > 0 && profileParts.contains(key.substring(0, dot)) && dot < key.length - 1;
  }

  /// Every colour slot, in file order, with what it colours.
  static const slots = {
    'bg': 'Background',
    'panel': 'Panels and bars',
    'panelHi': 'Raised panels and buttons',
    'line': 'Thin lines and borders',
    'text': 'Text',
    'dim': 'Quiet text and comments',
    'green': 'Generators, play, built-ins',
    'pink': 'Effects, errors, keywords',
    'yellow': 'Patterns, numbers, edits',
    'blue': 'Libraries, focus, variables',
    'violet': 'Modulation, automation and spectrum',
    'layer1': 'Layer colour 1',
    'layer2': 'Layer colour 2',
    'layer3': 'Layer colour 3',
    'layer4': 'Layer colour 4',
    'layer5': 'Track colour 5',
    'layer6': 'Track colour 6',
    'layer7': 'Track colour 7',
    'layer8': 'Track colour 8',
  };

  static Map<String, Color> _full(Map<String, Color> c, Map<String, Color> base) =>
      c.length == slots.length && slots.keys.every(c.containsKey) ? c : {...base, ...c};

  /// The colour of [slot] in the palette shown; a slot the theme leaves out comes from Neon's. Besides the
  /// [slots], `ink` is the colour that stands out from every surface for faint lines, grids, handles and highlights:
  /// white on a dark palette, the text colour on a light one.
  Color operator [](String slot) {
    if (slot == 'ink') return light ? this['text'] : const Color(0xFFFFFFFF);
    return colors[slot] ?? (light ? neonLight.lightColors : _neonDark)[slot] ?? const Color(0xFFFF00FF);
  }

  CawTheme? _twin;

  /// This theme showing its light palette ([light] true) or its dark one. The same object each time.
  CawTheme shown(bool light) {
    if (light == this.light) return this;
    final twin = _twin ??= CawTheme(
        name: name, colors: darkColors, lightColors: _lightGiven, glow: glow, flat: flat, profile: profile,
        light: light);
    twin._twin ??= this;
    return twin;
  }

  CawTheme copyWith({
    String? name,
    Map<String, Color>? colors,
    Map<String, Color>? lightColors,
    bool clearLight = false,
    bool? glow,
    bool? flat,
    Map<String, String>? profile,
    bool? light,
  }) =>
      CawTheme(
          name: name ?? this.name,
          colors: colors ?? darkColors,
          lightColors: clearLight ? null : (lightColors ?? _lightGiven),
          glow: glow ?? this.glow,
          flat: flat ?? this.flat,
          profile: profile ?? this.profile,
          light: light ?? this.light);

  /// Sets [slot] in the palette shown (the other palette stays; a light palette made from the dark one follows it).
  CawTheme withColor(String slot, Color c) =>
      light ? copyWith(lightColors: {...lightColors, slot: c}) : copyWith(colors: {...darkColors, slot: c});

  /// The theme with its light palette made afresh from the dark one ([lightFrom]), editable afterwards.
  CawTheme makeLight() => copyWith(lightColors: lightFrom(_full(darkColors, _neonDark)));

  /// The theme with its dark palette made afresh from the light one ([darkFrom]), editable afterwards.
  CawTheme makeDark() => copyWith(colors: darkFrom(lightColors), lightColors: lightColors);

  static String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// `#RRGGBB` (or `#AARRGGBB`) to a colour; null if it isn't one.
  static Color? parseHex(String s) {
    final h = s.trim().replaceFirst('#', '');
    if (!RegExp(r'^([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(h)) return null;
    final v = int.parse(h, radix: 16);
    return Color(h.length == 6 ? 0xFF000000 | v : v);
  }

  /// The theme file: a header like a module's, then one `slot: #RRGGBB` line per colour of the dark palette, the
  /// light palette's `light.slot: #RRGGBB` lines when it was set (not made from the dark one), then the profile's
  /// `part.key: value` lines by part (look, layout, behaviour; a layout value may be one line of JSON). With no
  /// light palette and no profile the file is exactly a colours-only theme, as before profiles; an older build reads
  /// the dark palette and skips the rest.
  String toFile() {
    final b = StringBuffer('---\nkind: theme\nname: $name\n---\n');
    b.writeln('// C.A.W theme: one colour per line as #RRGGBB. Missing lines fall back to Neon.');
    b.writeln('glow: ${glow ? 'on' : 'off'}');
    if (flat) b.writeln('flat: on');
    final dark = _full(darkColors, _neonDark);
    for (final s in slots.keys) {
      b.writeln('$s: ${hex(dark[s]!)}');
    }
    if (_lightGiven != null) {
      b.writeln('// The light palette (Mode: Light).');
      for (final s in slots.keys) {
        b.writeln('light.$s: ${hex(lightColors[s]!)}');
      }
    }
    if (profile.isNotEmpty) {
      b.writeln('// The look, layout and behaviour. Missing lines keep the current settings.');
      for (final part in profileParts) {
        final keys = profile.keys.where((k) => k.startsWith('$part.')).toList()..sort();
        for (final k in keys) {
          b.writeln('$k: ${profile[k]!.replaceAll('\n', ' ')}');
        }
      }
    }
    return b.toString();
  }

  /// Reads a theme file. Unknown keys are ignored; anything that isn't a theme throws a [FormatException]. A file
  /// with one palette (from before light and dark) loads it as the dark palette, or as the light one when its
  /// background is light, and makes the other ([lightFrom], [darkFrom]).
  static CawTheme parse(String text) {
    String? kind, name;
    var glow = true, flat = false;
    final colors = <String, Color>{};
    final lightColors = <String, Color>{};
    final profile = <String, String>{};
    bool on(String v) => !{'off', 'false', 'no', '0'}.contains(v.toLowerCase());
    final lines = text.replaceAll('\r', '').split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line == '---' || line.startsWith('//')) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) throw FormatException('Line ${i + 1}: expected "key: value"');
      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      switch (key) {
        case 'kind':
          kind = value;
        case 'name':
          name = value;
        case 'glow':
          glow = on(value);
        case 'flat':
          flat = on(value);
        default:
          if (isProfileKey(key)) {
            if (value.length <= 64 * 1024) profile[key] = value;
            continue;
          }
          final lightSlot = key.startsWith('light.') ? key.substring(6) : null;
          if (!slots.containsKey(lightSlot ?? key)) continue;
          final c = parseHex(value);
          if (c == null) throw FormatException('Line ${i + 1}: "$value" is not a #RRGGBB colour');
          (lightSlot == null ? colors : lightColors)[lightSlot ?? key] = c;
      }
    }
    if (kind != 'theme') throw const FormatException('Not a theme file (it needs "kind: theme")');
    final themeName = (name == null || name.isEmpty) ? 'Imported theme' : name;
    if (lightColors.isEmpty && colors.containsKey('bg') && isLightPalette(colors)) {
      // One light palette: it is the light one, and the dark one is made from it.
      final light = _full(colors, neonLight.lightColors);
      return CawTheme(
          name: themeName, colors: darkFrom(light), lightColors: light, glow: glow, flat: flat, profile: profile);
    }
    return CawTheme(
        name: themeName,
        colors: colors,
        lightColors: lightColors.isEmpty ? null : lightColors,
        glow: glow,
        flat: flat,
        profile: profile);
  }
}

Map<String, Color> _palette(List<int> v) => {
      for (final (i, s) in CawTheme.slots.keys.indexed) s: Color(v[i]),
    };

/// Neon's dark palette, the fallback for a slot a theme leaves out.
final Map<String, Color> _neonDark = _palette(const [
  0xFF07070B, 0xFF101018, 0xFF181824, 0xFF2A2A3C, 0xFFE9E9F2, 0xFF8C8CA3, //
  0xFF39FF14, 0xFFFF2BD6, 0xFFFFE81F, 0xFF1FD8FF, 0xFFB46CFF, //
  0xFF39FF14, 0xFFFF2BD6, 0xFFFFE81F, 0xFF1FD8FF, 0xFFB46CFF, 0xFFFF8A1F, 0xFF2BFFB0, 0xFFFF4D5E,
]);

/// The built-in families (owner, 2026-11-11), in the picker's order. Each has a dark and a light palette; the
/// light ones are made by [lightFrom] (Dawn, designed light first, makes its dark one by [darkFrom]), so a custom
/// theme's "Make light version" is the same algorithm.
const themeFamilies = ['Neon', 'Flat', 'Dusk', 'Dawn', 'Amber'];

/// Neon (was Calm neon), the default: near-black, thin neon lines, glow only on what's active.
final calmNeon = CawTheme(name: 'Neon', colors: _neonDark);

/// Neon in its light palette.
CawTheme get neonLight => calmNeon.shown(true);

/// Flat (owner, 2026-11-11): Neon's counterpart, a standard DAW look. Flat neutral greys, muted accents at ordinary
/// saturation, no glow and no glass, solid fills and thin borders. Its own palette, not any one DAW's theme.
final flatTheme = CawTheme(
  name: 'Flat',
  glow: false,
  flat: true,
  colors: _palette(const [
    0xFF1F2023, 0xFF27292C, 0xFF303236, 0xFF45484D, 0xFFE2E3E5, 0xFFA3A6AB, //
    0xFF6DBA74, 0xFFE6879A, 0xFFD9B95A, 0xFF64A3DB, 0xFFA48DD8, //
    0xFF6DBA74, 0xFFE6879A, 0xFFD9B95A, 0xFF64A3DB, 0xFFA48DD8, 0xFFDB9358, 0xFF5CBFA8, 0xFFDB6A62,
  ]),
);

/// Dusk (was Night): dim, muted and without glow, for late sessions.
final duskTheme = CawTheme(
  name: 'Dusk',
  glow: false,
  colors: _palette(const [
    0xFF040406, 0xFF0B0B10, 0xFF12121A, 0xFF20202C, 0xFFC4C4D0, 0xFF7E7E93, //
    0xFF4CC38A, 0xFFC45BB2, 0xFFD6C25A, 0xFF4FA6C6, 0xFF9C83D6, //
    0xFF4CC38A, 0xFFC45BB2, 0xFFD6C25A, 0xFF4FA6C6, 0xFF9C83D6, 0xFFD68A4C, 0xFF4CC3A6, 0xFFC45B66,
  ]),
);

/// Dawn (new): Dusk's light-hearted counterpart, a warm sunrise. Designed light first (cream and peach surfaces,
/// coral, honey, sky and lavender accents); its dark palette is made from the light one ([darkFrom]).
final dawnTheme = () {
  final light = withSafeContrast(_palette(const [
    0xFFFCF5EB, 0xFFF6EADB, 0xFFEFDFCB, 0xFFDDC7AC, 0xFF2E1F16, 0xFF715A49, //
    0xFF2E7D52, 0xFFC23D62, 0xFF9A5F00, 0xFF2D6CA5, 0xFF7B4DB0, //
    0xFF2E7D52, 0xFFC23D62, 0xFF9A5F00, 0xFF2D6CA5, 0xFF7B4DB0, 0xFFC0561A, 0xFF1F7F70, 0xFFBE3B3B,
  ]));
  return CawTheme(name: 'Dawn', colors: darkFrom(light), lightColors: light);
}();

/// Amber (was Amber terminal): a warm monochrome terminal.
final amberTheme = CawTheme(
  name: 'Amber',
  colors: _palette(const [
    0xFF0B0804, 0xFF15100A, 0xFF1E170E, 0xFF3A2C18, 0xFFFFD9A0, 0xFFA08060, //
    0xFFFFB000, 0xFFFF6A3D, 0xFFFFE08A, 0xFFFFC861, 0xFFB68AE0, //
    0xFFFFB000, 0xFFFF6A3D, 0xFFFFE08A, 0xFFD9A066, 0xFFB68AE0, 0xFFFF8A3D, 0xFFE0C060, 0xFFD96650,
  ]),
);

/// The themes that ship with the app, in [themeFamilies] order (they can be duplicated, not changed).
final starterThemes = [calmNeon, flatTheme, duskTheme, dawnTheme, amberTheme];

/// The family a saved theme name from before the families stands for (2026-11-11: Calm neon, Night and Amber
/// terminal became Neon, Dusk and Amber, all dark).
const legacyThemeNames = {'Calm neon': 'Neon', 'Night': 'Dusk', 'Amber terminal': 'Amber'};

/// A colour that always shows the active theme's slot, so `const` uses of Neon.* follow the theme.
class _ThemeColor extends Color {
  const _ThemeColor(this.slot) : super(0);
  final String slot;

  Color get _c => Neon.active[slot];
  @override
  double get a => _c.a;
  @override
  double get r => _c.r;
  @override
  double get g => _c.g;
  @override
  double get b => _c.b;
  @override
  ColorSpace get colorSpace => _c.colorSpace;
}

class Neon {
  /// The theme every Neon colour reads from, in the palette shown. Settings sets it; widgets built earlier repaint
  /// when the app remounts.
  static CawTheme active = calmNeon;

  /// Performance profile: 0 full, 1 balanced, 2 lightweight, 3 minimal.
  static int performanceMode = 1;
  static bool light = false;
  static bool showScopes = true;

  /// The theme's glow strength (Settings, a theme's look): scales every [glow], 1 as designed.
  static double glowStrength = 1;

  static const Color bg = _ThemeColor('bg');
  static const Color panel = _ThemeColor('panel');
  static const Color panelHi = _ThemeColor('panelHi');
  static const Color line = _ThemeColor('line');
  static const Color text = _ThemeColor('text');
  static const Color dim = _ThemeColor('dim');

  static const Color green = _ThemeColor('green');
  static const Color pink = _ThemeColor('pink');
  static const Color yellow = _ThemeColor('yellow');
  static const Color blue = _ThemeColor('blue');
  static const Color violet = _ThemeColor('violet');

  /// The colour that stands out from every surface, for faint grids, guide lines, handles and highlights: white on
  /// a dark palette, the text colour on a light one (use it at the alpha a white overlay had).
  static const Color ink = _ThemeColor('ink');

  /// Code's quoted text and operators: soft pink and lavender on a dark palette; on a light one a mix of two
  /// accents, so they pass AA like the accents do.
  static Color get codeString =>
      active.light ? Color.lerp(active['pink'], active['violet'], 0.4)! : const Color(0xFFFF9EE8);
  static Color get codeOperator =>
      active.light ? Color.lerp(active['blue'], active['violet'], 0.5)! : const Color(0xFFB9B9FF);

  /// True while the active theme shows its light palette.
  static bool get isLight => active.light;

  /// True while the active theme is flat (the Flat family): solid fills, no glow, no glass.
  static bool get flat => active.flat;

  /// A gradient's colours, or with a [flat] theme one solid colour (the middle of them) in their place.
  static List<Color> ramp(List<Color> colors) {
    if (!flat || colors.length < 2) return colors;
    final mid = Color.lerp(colors.first, colors.last, 0.5)!;
    return List.filled(colors.length, mid);
  }

  /// A drawn stroke's glow strength: 1 on a dark palette, softer on a light one (a halo on white reads as a smudge),
  /// none with a flat theme.
  static double get strokeGlow => flat ? 0 : (active.light ? 0.6 : 1);

  /// Track (layer) colours, in order: eight, so a song's tracks are told apart before colours repeat.
  static const List<Color> layers = [
    _ThemeColor('layer1'),
    _ThemeColor('layer2'),
    _ThemeColor('layer3'),
    _ThemeColor('layer4'),
    _ThemeColor('layer5'),
    _ThemeColor('layer6'),
    _ThemeColor('layer7'),
    _ThemeColor('layer8'),
  ];
  static Color layer(int i) => layers[i % layers.length];

  /// The bundled code and number font (JetBrains Mono, SIL OFL 1.1), with system monospace fonts behind it.
  static const String mono = 'JetBrainsMono';
  static const List<String> monoFallback = ['monospace', 'Consolas', 'Cascadia Mono', 'Roboto Mono', 'Courier New'];

  static TextStyle code({double size = 15, Color color = text}) =>
      TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: size, color: color, height: 1.45);

  /// The glow around active things; nothing when the theme turns glow off.
  static List<BoxShadow> glow(Color c, {double strength = 0.55}) {
    // On a light palette the glow is softer and tighter: a wide halo on white reads as a smudge.
    final scale = (performanceMode == 0 ? 1.0 : performanceMode == 1 ? 0.55 : 0.0) * glowStrength *
        (active.light ? 0.6 : 1);
    return active.glow && !active.flat && !light && scale > 0
        ? [
            BoxShadow(
                color: c.withValues(alpha: (strength * scale).clamp(0.0, 1.0)),
                blurRadius: active.light ? 8 : 12,
                spreadRadius: -2)
          ]
        : const [];
  }

  /// A button style that only adds the pressed glow and the hover tint (merged under a button's own style).
  static ButtonStyle pressedGlow(Color accent, Color text) => ButtonStyle(
        overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed)
            ? accent.withValues(alpha: 0.20)
            : s.contains(WidgetState.hovered)
                ? text.withValues(alpha: 0.08)
                : s.contains(WidgetState.focused)
                    ? text.withValues(alpha: 0.10)
                    : null),
      );

  /// True when the compact density is on.
  static bool compact(BuildContext context) => Theme.of(context).visualDensity == VisualDensity.compact;

  /// Material theme for [look] (the active theme by default). Compact density shrinks paddings and tap targets.
  /// With [glass] (the Glass setting, by default): see-through fills with solid outlines on sliders, buttons and
  /// switches, a transparent scaffold over the [GlassBackdrop], and translucent dialogs, menus and sheets.
  /// [fontFamily] is the UI font (null: the system's; [mono] for the bundled one) and [roundness] scales the corners
  /// of dialogs, menus, chips and buttons (1 as designed).
  static ThemeData theme({CawTheme? look, bool compact = false, bool? glass, String? fontFamily, double roundness = 1}) {
    final t = look ?? active;
    final g = glass ?? Glass.active;
    double r(double v) => v * roundness;
    final bg = t['bg'], panel = t['panel'], panelHi = t['panelHi'], line = t['line'], text = t['text'];
    final green = t['green'], pink = t['pink'], blue = t['blue'];
    final scheme = t.light
        ? ColorScheme.light(
            surface: panel,
            primary: green,
            secondary: pink,
            tertiary: blue,
            error: pink,
            onPrimary: bg,
            onSecondary: bg,
            onSurface: text,
            onSurfaceVariant: t['dim'],
            outline: line,
          )
        : ColorScheme.dark(
            surface: panel,
            primary: green,
            secondary: pink,
            tertiary: blue,
            error: pink,
            onPrimary: bg,
            onSecondary: bg,
            onSurface: text,
          );
    return ThemeData(
      useMaterial3: true,
      brightness: t.light ? Brightness.light : Brightness.dark,
      colorScheme: scheme,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamily == mono ? monoFallback : null,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      materialTapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
      listTileTheme: ListTileThemeData(dense: compact),
      scaffoldBackgroundColor: g ? Colors.transparent : bg,
      canvasColor: bg,
      dividerColor: line,
      // Every press shows (owner, 2026-11-10: feedback on every touch): a quick accent ripple on every InkWell, list
      // tile, chip and button, and a soft accent glow on icon buttons while held. InkRipple is the cheaper, snappier
      // ripple. (highlightColor stays the default: scrollbars take their thumb colour from it.)
      splashFactory: InkRipple.splashFactory,
      splashColor: green.withValues(alpha: 0.16),
      hoverColor: text.withValues(alpha: 0.06),
      iconButtonTheme: IconButtonThemeData(style: pressedGlow(green, text)),
      sliderTheme: g
          ? SliderThemeData(
              trackHeight: 7,
              inactiveTrackColor: line,
              trackShape: const GlassSliderTrackShape(),
              thumbShape: const GlassSliderThumbShape(),
              overlayShape: RoundSliderOverlayShape(overlayRadius: compact ? 12 : 16),
            )
          : SliderThemeData(
              trackHeight: 3,
              inactiveTrackColor: line,
              overlayShape: RoundSliderOverlayShape(overlayRadius: compact ? 12 : 16),
            ),
      filledButtonTheme: g
          ? FilledButtonThemeData(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((s) =>
                    s.contains(WidgetState.disabled) ? line.withValues(alpha: 0.12) : green.withValues(alpha: 0.18)),
                foregroundColor:
                    WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? t['dim'] : green),
                side: WidgetStateProperty.resolveWith(
                    (s) => BorderSide(color: s.contains(WidgetState.disabled) ? line : green, width: 1.5)),
              ),
            )
          : null,
      segmentedButtonTheme: g
          ? SegmentedButtonThemeData(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected) ? pink.withValues(alpha: 0.2) : Colors.transparent),
                foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? pink : text),
                side: WidgetStateProperty.all(BorderSide(color: pink.withValues(alpha: 0.7), width: 1.2)),
              ),
            )
          : null,
      switchTheme: g
          ? SwitchThemeData(
              thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? green : t['dim']),
              trackColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? green.withValues(alpha: 0.25) : line.withValues(alpha: 0.2)),
              trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? green : line),
            )
          : null,
      dialogTheme: g
          ? DialogThemeData(
              backgroundColor: panelHi.withValues(alpha: 0.9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(r(20)),
                side: BorderSide(color: t['ink'].withValues(alpha: 0.14)),
              ),
            )
          : roundness == 1
              ? null
              : DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(28)))),
      popupMenuTheme: g
          ? PopupMenuThemeData(
              color: panelHi.withValues(alpha: 0.92),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(r(14)),
                side: BorderSide(color: t['ink'].withValues(alpha: 0.14)),
              ),
            )
          : roundness == 1
              ? null
              : PopupMenuThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(4)))),
      bottomSheetTheme: g ? BottomSheetThemeData(backgroundColor: panelHi.withValues(alpha: 0.92)) : null,
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderSide: BorderSide(color: line), borderRadius: BorderRadius.circular(r(4))),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: line), borderRadius: BorderRadius.circular(r(4))),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: blue), borderRadius: BorderRadius.circular(r(4))),
      ),
      // Material 3's own corners (8 and 12) unless the theme's roundness changes them.
      chipTheme: roundness == 1
          ? null
          : ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(8)))),
      cardTheme: roundness == 1
          ? null
          : CardThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(12)))),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel,
        indicatorColor: green.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.all(TextStyle(fontSize: 12, color: text)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: panel,
        indicatorColor: green.withValues(alpha: 0.18),
      ),
      snackBarTheme: SnackBarThemeData(backgroundColor: panelHi, contentTextStyle: TextStyle(color: text)),
    );
  }
}
