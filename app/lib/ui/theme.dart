// The look: themes (Calm neon and the starter themes), the readable theme file, the active theme behind Neon.*, fonts.
import 'dart:ui' show ColorSpace;

import 'package:flutter/material.dart';

/// One look: a colour for each slot, plus whether active things glow. Saved as a readable theme file.
class CawTheme {
  const CawTheme({required this.name, required this.colors, this.glow = true});

  final String name;
  final Map<String, Color> colors;
  final bool glow;

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
    'layer1': 'Layer colour 1',
    'layer2': 'Layer colour 2',
    'layer3': 'Layer colour 3',
    'layer4': 'Layer colour 4',
  };

  /// The colour of [slot]; a slot the theme leaves out comes from Calm neon.
  Color operator [](String slot) => colors[slot] ?? calmNeon.colors[slot] ?? const Color(0xFFFF00FF);

  CawTheme copyWith({String? name, Map<String, Color>? colors, bool? glow}) =>
      CawTheme(name: name ?? this.name, colors: colors ?? this.colors, glow: glow ?? this.glow);

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

  /// The theme file: a header like a module's, then one `slot: #RRGGBB` line per colour.
  String toFile() {
    final b = StringBuffer('---\nkind: theme\nname: $name\n---\n');
    b.writeln('// C.A.W theme: one colour per line as #RRGGBB. Missing lines fall back to Calm neon.');
    b.writeln('glow: ${glow ? 'on' : 'off'}');
    for (final s in slots.keys) {
      b.writeln('$s: ${hex(this[s])}');
    }
    return b.toString();
  }

  /// Reads a theme file. Unknown keys are ignored; anything that isn't a theme throws a [FormatException].
  static CawTheme parse(String text) {
    String? kind, name;
    var glow = true;
    final colors = <String, Color>{};
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
          if (!slots.containsKey(key)) continue;
          final c = parseHex(value);
          if (c == null) throw FormatException('Line ${i + 1}: "$value" is not a #RRGGBB colour');
          colors[key] = c;
      }
    }
    if (kind != 'theme') throw const FormatException('Not a theme file (it needs "kind: theme")');
    return CawTheme(name: (name == null || name.isEmpty) ? 'Imported theme' : name, colors: colors, glow: glow);
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
    0xFF39FF14, 0xFFFF2BD6, 0xFFFFE81F, 0xFF1FD8FF, //
    0xFF39FF14, 0xFFFF2BD6, 0xFFFFE81F, 0xFF1FD8FF,
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
      0xFF4CC38A, 0xFFC45BB2, 0xFFD6C25A, 0xFF4FA6C6, //
      0xFF4CC38A, 0xFFC45BB2, 0xFFD6C25A, 0xFF4FA6C6,
    ]),
  ),
  CawTheme(
    name: 'Amber terminal',
    colors: _palette(const [
      0xFF0B0804, 0xFF15100A, 0xFF1E170E, 0xFF3A2C18, 0xFFFFD9A0, 0xFFA08060, //
      0xFFFFB000, 0xFFFF6A3D, 0xFFFFE08A, 0xFFFFC861, //
      0xFFFFB000, 0xFFFF6A3D, 0xFFFFE08A, 0xFFD9A066,
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

  /// Light mode (for slow devices) turns glow off whatever the theme says.
  static bool light = false;

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

  /// Layer colours, in order.
  static const List<Color> layers = [
    _ThemeColor('layer1'),
    _ThemeColor('layer2'),
    _ThemeColor('layer3'),
    _ThemeColor('layer4'),
  ];
  static Color layer(int i) => layers[i % layers.length];

  /// The bundled code and number font (JetBrains Mono, SIL OFL 1.1), with system monospace fonts behind it.
  static const String mono = 'JetBrainsMono';
  static const List<String> monoFallback = ['monospace', 'Consolas', 'Cascadia Mono', 'Roboto Mono', 'Courier New'];

  static TextStyle code({double size = 15, Color color = text}) =>
      TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: size, color: color, height: 1.45);

  /// The glow around active things; nothing when the theme turns glow off.
  static List<BoxShadow> glow(Color c, {double strength = 0.55}) => active.glow && !light
      ? [BoxShadow(color: c.withValues(alpha: strength), blurRadius: 12, spreadRadius: -2)]
      : const [];

  /// True when the compact density is on.
  static bool compact(BuildContext context) => Theme.of(context).visualDensity == VisualDensity.compact;

  /// Material theme for [look] (the active theme by default). Compact density shrinks paddings and tap targets.
  static ThemeData theme({CawTheme? look, bool compact = false}) {
    final t = look ?? active;
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
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      materialTapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
      listTileTheme: ListTileThemeData(dense: compact),
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: line,
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        inactiveTrackColor: line,
        overlayShape: RoundSliderOverlayShape(overlayRadius: compact ? 12 : 16),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderSide: BorderSide(color: line)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: blue)),
      ),
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
