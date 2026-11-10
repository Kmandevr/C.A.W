// What every control in a device editor shares: the device, its mod matrix, the source being dragged, value text.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/device_target.dart';
import '../../model/mod_matrix.dart';
import '../theme.dart';

/// Hands the device editor's state to its controls.
class DeviceScope extends InheritedWidget {
  const DeviceScope({super.key, required this.target, required this.matrix, required this.dragging,
    required this.accent, Color? secondary, required this.focusSource, this.openSource, required super.child})
      : secondary = secondary ?? accent;

  final DeviceTarget target;

  /// The device's mod matrix, or null when it has none.
  final ModMatrix? matrix;

  /// The mod source being dragged onto a knob (every knob it can reach lights up), or null.
  final ValueNotifier<ModSource?> dragging;

  /// The device's colour, and its family's second colour (the right channel, the output, a gradient's end).
  final Color accent, secondary;

  /// The source the MOD page shows (a tapped chip picks it).
  final ValueNotifier<ModSource> focusSource;

  /// Shows [ModSource]'s page (the editor's MOD tab), when the editor has one.
  final ValueChanged<ModSource>? openSource;

  static DeviceScope of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<DeviceScope>();
    assert(s != null, 'a device control outside a DeviceScope');
    return s!;
  }

  @override
  // The editor rebuilds the scope only when the device changed (a value, undo, the catalog), and every control
  // reads its values through it, so each rebuild reaches them (an effect has no mod matrix whose new object would).
  bool updateShouldNotify(DeviceScope old) => true;
}

/// A source's colour: envelopes green, LFOs blue, random violet, the note's own sources yellow.
Color modSourceColor(ModSource s) => switch (s) {
      ModSource.env1 || ModSource.env2 || ModSource.env3 => Neon.green,
      ModSource.lfo1 || ModSource.lfo2 || ModSource.lfo3 => Neon.blue,
      ModSource.random => Neon.violet,
      ModSource.none => Neon.dim,
      _ => Neon.yellow,
    };

/// A value as a short readout: choices by name, Hz as Hz or kHz, seconds as ms below one, a 0..1 value with no unit
/// as a percentage, a −1..1 pan as L/C/R.
String formatParamValue(ComponentParameterInfo? p, double v, {bool pan = false}) {
  if (p == null) return v.toStringAsFixed(2);
  if (p.isChoice) {
    final i = (v - p.min).round().clamp(0, p.choices.length - 1);
    return p.choices[i];
  }
  if (pan || p.id.endsWith('pan')) {
    if (v.abs() < 0.005) return 'C';
    return '${(v.abs() * 100).round()}${v < 0 ? 'L' : 'R'}';
  }
  switch (p.unit) {
    case 'Hz':
      return v >= 1000 ? '${(v / 1000).toStringAsFixed(v >= 10000 ? 1 : 2)}k' : (v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 10 ? 1 : 2));
    case 's':
      return v < 1 ? '${(v * 1000).toStringAsFixed(v < 0.01 ? 1 : 0)} ms' : '${v.toStringAsFixed(2)} s';
    case 'dB':
      return '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}';
    case 'ct':
      return '${v.round()} ct';
    case 'st':
      return '${v > 0 ? '+' : ''}${v.round()} st';
  }
  if (p.step >= 1) return '${v > 0 && p.min < 0 ? '+' : ''}${v.round()}';
  if (p.min == 0 && p.max == 1) return '${(v * 100).round()}%';
  if (p.min == -1 && p.max == 1) return '${v > 0 ? '+' : ''}${(v * 100).round()}%';
  final range = p.max - p.min;
  return v.toStringAsFixed(range > 20 ? 0 : (range > 2 ? 1 : 2));
}

/// A short knob label: the descriptor's name without its section ("Osc 1 detune" → "detune"), capitalised.
String shortParamLabel(ComponentParameterInfo? p, String fallback) {
  final name = p?.label ?? fallback;
  final m = RegExp(r'^(Osc|Filter|Env|LFO|Mod|Band) \d+ ').firstMatch(name);
  final s = m == null ? name : name.substring(m.end);
  return s.isEmpty ? name : s[0].toUpperCase() + s.substring(1);
}

/// A section heading inside a device card: small capitals, spaced.
class DeviceHeading extends StatelessWidget {
  const DeviceHeading(this.text, {super.key, this.color = Neon.dim, this.trailing});
  final String text;
  final Color color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(height: 22, child: Row(children: [
    Text(text, style: TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: color)),
    const SizedBox(width: 8),
    if (trailing != null) Expanded(child: Align(alignment: Alignment.centerRight, child: trailing)),
  ]));
}

/// A device card: a see-through panel with a thin outline in [color], a title row and [child].
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.title, required this.child, this.color = Neon.blue, this.actions = const [],
    this.dimmed = false, this.leading});
  final String title;
  final Widget child;
  final Color color;
  final List<Widget> actions;
  final bool dimmed;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    duration: const Duration(milliseconds: 120),
    opacity: dimmed ? 0.5 : 1,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
          Color.lerp(Neon.panel, color, 0.12)!.withValues(alpha: 0.7),
          Color.lerp(Neon.panel, color, 0.03)!.withValues(alpha: 0.6),
        ]),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(height: 2, decoration: BoxDecoration(gradient: LinearGradient(colors: [
          color.withValues(alpha: 0.9), color.withValues(alpha: 0.0)]))),
        Padding(padding: const EdgeInsets.fromLTRB(10, 2, 8, 8), child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            SizedBox(height: 32, child: Row(children: [
              ?leading,
              if (leading != null) const SizedBox(width: 6),
              Text(title, style: TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: color,
                shadows: [Shadow(color: color.withValues(alpha: 0.5), blurRadius: 8)])),
              const SizedBox(width: 8),
              Expanded(child: Align(alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: [for (final a in actions) Flexible(child: a)]))),
            ])),
            child,
          ])),
      ]),
    ),
  );
}

/// Lays [children] out in columns of at least [minWidth] each when there is room, else stacked.
class DeviceColumns extends StatelessWidget {
  const DeviceColumns({super.key, required this.children, this.minWidth = 320, this.gap = 8});
  final List<Widget> children;
  final double minWidth, gap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final n = math.max(1, math.min(children.length, (box.maxWidth / minWidth).floor()));
    if (n == 1) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += n) {
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var k = 0; k < n; k++) ...[
          if (k > 0) SizedBox(width: gap),
          Expanded(child: i + k < children.length ? children[i + k] : const SizedBox.shrink()),
        ],
      ]));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  });
}
