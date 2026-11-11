// The look: themes (Calm neon and the starter themes), the readable theme file, the active theme behind Neon.*, fonts.
import 'dart:ui' show ColorSpace;

import 'package:flutter/material.dart';

import 'glass.dart';

/// One theme: a colour for each slot, whether active things glow, and (owner, 2026-11-11: a theme is a full profile)
/// the rest of its look, layout and behaviour in [profile]. Saved as a readable theme file.
class CawTheme {
  const CawTheme({required this.name, required this.colors, this.glow = true, this.profile = const {}});

  final String name;
  final Map<String, Color> colors;
  final bool glow;

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

  /// The colour of [slot]; a slot the theme leaves out comes from Calm neon.
  Color operator [](String slot) => colors[slot] ?? calmNeon.colors[slot] ?? const Color(0xFFFF00FF);

  CawTheme copyWith({String? name, Map<String, Color>? colors, bool? glow, Map<String, String>? profile}) => CawTheme(
      name: name ?? this.name,
      colors: colors ?? this.colors,
      glow: glow ?? this.glow,
      profile: profile ?? this.profile);

  CawTheme withColor(String slot, Color c) => copyWith(colors: {...colors, slot: c});

  static String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// `#RRGGBB` (or `#AARRGGBB`) to a colour; null if it isn't one.
  static Color? parseHex(String s) {
    final h = s.trim().replaceFirst('#', '');
    if (!RegExp(r'^([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(h)) return null;
    final v = int.parse(h, radix: 16);
    return Color(h.length == 6 ? 0xFF000000 | v : v);
  }

  /// The theme file: a header like a module's, then one `slot: #RRGGBB` line per colour, then the profile's
  /// `part.key: value` lines by part (look, layout, behaviour; a layout value may be one line of JSON). With no
  /// profile the file is exactly a colours-only theme, as before profiles.
  String toFile() {
    final b = StringBuffer('---\nkind: theme\nname: $name\n---\n');
    b.writeln('// C.A.W theme: one colour per line as #RRGGBB. Missing lines fall back to Calm neon.');
    b.writeln('glow: ${glow ? 'on' : 'off'}');
    for (final s in slots.keys) {
      b.writeln('$s: ${hex(this[s])}');
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

  /// Reads a theme file. Unknown keys are ignored; anything that isn't a theme throws a [FormatException].
  static CawTheme parse(String text) {
    String? kind, name;
    var glow = true;
    final colors = <String, Color>{};
    final profile = <String, String>{};
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
          glow = !{'off', 'false', 'no', '0'}.contains(value.toLowerCase());
        default:
          if (isProfileKey(key)) {
            if (value.length <= 64 * 1024) profile[key] = value;
            continue;
          }
          if (!slots.containsKey(key)) continue;
          final c = parseHex(value);
          if (c == null) throw FormatException('Line ${i + 1}: "$value" is not a #RRGGBB colour');
          colors[key] = c;
      }
    }
    if (kind != 'theme') throw const FormatException('Not a theme file (it needs "kind: theme")');
    return CawTheme(
        name: (name == null || name.isEmpty) ? 'Imported theme' : name, colors: colors, glow: glow, profile: profile);
  }
}

Map<String, Color> _palette(List<int> v) => {
      for (final (i, s) in CawTheme.slots.keys.indexed) s: Color(v[i]),
    };

/// The default look: near-black, thin neon lines, glow only on what's active.
final calmNeon = CawTheme(
  name: 'Calm neon',
  colors: _palette(const [
    0xFF07070B, 0xFF101018, 0xFF181824, 0xFF2A2A3C, 0xFFE9E9F2, 0xFF8C8CA3, //
    0xFF39FF14, 0xFFFF2BD6, 0xFFFFE81F, 0xFF1FD8FF, 0xFFB46CFF, //
    0xFF39FF14, 0xFFFF2BD6, 0xFFFFE81F, 0xFF1FD8FF, 0xFFB46CFF, 0xFFFF8A1F, 0xFF2BFFB0, 0xFFFF4D5E,
  ]),
);

/// The themes that ship with the app (they can be duplicated, not changed).
final starterThemes = [
  calmNeon,
  CawTheme(
    name: 'Night',
    glow: false,
    colors: _palette(const [
      0xFF040406, 0xFF0B0B10, 0xFF12121A, 0xFF20202C, 0xFFC4C4D0, 0xFF6C6C80, //
      0xFF4CC38A, 0xFFC45BB2, 0xFFD6C25A, 0xFF4FA6C6, 0xFF9C83D6, //
      0xFF4CC38A, 0xFFC45BB2, 0xFFD6C25A, 0xFF4FA6C6, 0xFF9C83D6, 0xFFD68A4C, 0xFF4CC3A6, 0xFFC45B66,
    ]),
  ),
  CawTheme(
    name: 'Amber terminal',
    colors: _palette(const [
      0xFF0B0804, 0xFF15100A, 0xFF1E170E, 0xFF3A2C18, 0xFFFFD9A0, 0xFFA08060, //
      0xFFFFB000, 0xFFFF6A3D, 0xFFFFE08A, 0xFFFFC861, 0xFFB68AE0, //
      0xFFFFB000, 0xFFFF6A3D, 0xFFFFE08A, 0xFFD9A066, 0xFFB68AE0, 0xFFFF8A3D, 0xFFE0C060, 0xFFD96650,
    ]),
  ),
];

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
  /// The theme every Neon colour reads from. Settings sets it; widgets built earlier repaint when the app remounts.
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
    final scale = (performanceMode == 0 ? 1.0 : performanceMode == 1 ? 0.55 : 0.0) * glowStrength;
    return active.glow && !light && scale > 0
        ? [BoxShadow(color: c.withValues(alpha: (strength * scale).clamp(0.0, 1.0)), blurRadius: 12, spreadRadius: -2)]
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
    final scheme = ColorScheme.dark(
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
                side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
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
                side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
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
