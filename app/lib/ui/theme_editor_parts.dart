// The theme editor's building blocks in the device kit's style: a tinted section card with an accent heading, a row
// of choice tiles, and labelled switch and slider rows.
import 'package:flutter/material.dart';

import 'feedback.dart';
import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';
import 'tokens.dart';
import 'widgets.dart' show ResetOnDoubleTap;

/// A section of the editor: a panel faintly tinted with [accent], its title in small capitals in that accent with a
/// rule after it (as the device editors head their sections), and its rows.
class EditorCard extends StatelessWidget {
  const EditorCard({super.key, required this.title, required this.accent, required this.children, this.trailing});
  final String title;
  final Color accent;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    // A Material, so the rows' ink shows on the card.
    child: Material(
      color: Color.lerp(Neon.panel, accent, 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.l),
        side: BorderSide(color: accent.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: accent),
                ),
                const SizedBox(width: 8),
                Expanded(child: Container(height: 1, color: accent.withValues(alpha: 0.25))),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    ),
  );
}

/// A row's label and, below or beside it, a quiet line saying what it does.
class EditorLabel extends StatelessWidget {
  const EditorLabel(this.title, {super.key, this.subtitle, this.value});
  final String title;
  final String? subtitle;
  final String? value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              if (subtitle != null) Text(subtitle!, style: const TextStyle(color: Neon.dim, fontSize: 11)),
            ],
          ),
        ),
        if (value != null) Text(value!, style: Neon.code(size: 12, color: Neon.yellow)),
      ],
    ),
  );
}

/// Choices as a row of tiles (the device kit's mode tiles, without the drawn icon): the selected one tinted in
/// [accent]. Wraps onto more rows on a narrow screen.
class ChoiceTiles<T> extends StatelessWidget {
  const ChoiceTiles({
    super.key,
    required this.choices,
    required this.value,
    required this.onChanged,
    required this.accent,
  });
  final List<(T, String)> choices;
  final T? value;
  final ValueChanged<T>? onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final (v, label) in choices)
        Pressable(
          glow: accent,
          radius: Radii.s,
          enabled: onChanged != null,
          child: InkWell(
            key: ValueKey('tile-$label'),
            borderRadius: BorderRadius.circular(Radii.s),
            onTap: onChanged == null
                ? null
                : () {
                    Haptics.tap();
                    onChanged!(v);
                  },
            child: AnimatedContainer(
              duration: Motion.fade(Motion.small, Motion.of(context)),
              constraints: const BoxConstraints(minWidth: 56, minHeight: 34),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: v == value ? accent.withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(Radii.s),
                border: Border.all(color: v == value ? accent : Neon.line, width: v == value ? 1.4 : 1),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: v == value ? FontWeight.w700 : FontWeight.w500,
                  color: onChanged == null ? Neon.dim : (v == value ? accent : Neon.text),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// A labelled switch.
Widget editorSwitch(String key, String title, String subtitle, bool value, ValueChanged<bool>? onChanged) =>
    SwitchListTile(
      key: ValueKey('theme-$key'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(color: Neon.dim, fontSize: 11)),
      value: value,
      onChanged: onChanged,
    );

/// A labelled slider with its value shown; a double-tap puts back [reset].
Widget editorSlider(
  String key,
  String title,
  double value,
  double min,
  double max,
  String Function(double) show, {
  required ValueChanged<double> onChanged,
  required ValueChanged<double> onChangeEnd,
  required VoidCallback onReset,
  int? divisions,
  String? subtitle,
}) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    EditorLabel(title, subtitle: subtitle, value: show(value)),
    ResetOnDoubleTap(
      onReset: onReset,
      child: Slider(
        key: ValueKey('theme-$key'),
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    ),
  ],
);
