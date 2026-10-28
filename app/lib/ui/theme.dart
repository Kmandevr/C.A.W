// The neon look: near-black surfaces with neon green, pink, yellow and blue, and a monospace code font.
import 'package:flutter/material.dart';

class Neon {
  static const Color bg = Color(0xFF07070B);
  static const Color panel = Color(0xFF101018);
  static const Color panelHi = Color(0xFF181824);
  static const Color line = Color(0xFF2A2A3C);
  static const Color text = Color(0xFFE9E9F2);
  static const Color dim = Color(0xFF8C8CA3);

  static const Color green = Color(0xFF39FF14);
  static const Color pink = Color(0xFFFF2BD6);
  static const Color yellow = Color(0xFFFFE81F);
  static const Color blue = Color(0xFF1FD8FF);

  /// Layer colours, in order.
  static const List<Color> layers = [green, pink, yellow, blue];
  static Color layer(int i) => layers[i % layers.length];

  static const String mono = 'monospace';
  static const List<String> monoFallback = ['Consolas', 'Cascadia Mono', 'Roboto Mono', 'Courier New'];

  static TextStyle code({double size = 15, Color color = text}) =>
      TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: size, color: color, height: 1.45);

  static List<BoxShadow> glow(Color c, {double strength = 0.55}) =>
      [BoxShadow(color: c.withValues(alpha: strength), blurRadius: 12, spreadRadius: -2)];

  static ThemeData theme() {
    final scheme = const ColorScheme.dark(
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
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: line,
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        inactiveTrackColor: line,
        overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderSide: BorderSide(color: line)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: blue)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel,
        indicatorColor: green.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, color: text)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: panel,
        indicatorColor: green.withValues(alpha: 0.18),
      ),
      snackBarTheme: const SnackBarThemeData(backgroundColor: panelHi, contentTextStyle: TextStyle(color: text)),
    );
  }
}
