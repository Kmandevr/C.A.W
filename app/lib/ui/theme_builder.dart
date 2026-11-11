// The theme editor's palette builder: pick one or two seed colours or a mood and a harmony, Shuffle for another
// variation, and the whole light and dark palette is made from them (buildPalettes, AA-safe).
import 'package:flutter/material.dart';

import 'haptics.dart';
import 'theme.dart';
import 'theme_editor_parts.dart';
import 'theme_palette.dart';
import 'tokens.dart';

/// The builder's card. [recipe] is the one in force (null until the user first builds); [onBuild] gets each new
/// recipe, and the editor applies [buildPalettes] to the draft. [pickColor] opens the editor's colour picker for a
/// custom seed.
class PaletteBuilderCard extends StatefulWidget {
  const PaletteBuilderCard({super.key, required this.recipe, required this.onBuild, required this.pickColor});
  final PaletteRecipe? recipe;
  final ValueChanged<PaletteRecipe> onBuild;
  final Future<Color?> Function(Color start) pickColor;

  @override
  State<PaletteBuilderCard> createState() => _PaletteBuilderCardState();
}

class _PaletteBuilderCardState extends State<PaletteBuilderCard> {
  /// Which seed a swatch tap sets: the first, or the second.
  bool _second = false;

  PaletteRecipe get _r => widget.recipe ?? paletteMoods.first.recipe;

  void _build(PaletteRecipe r) {
    Haptics.tap();
    widget.onBuild(r);
  }

  void _seed(Color c) =>
      _build(_second ? _r.copyWith(second: c, variation: 0) : _r.copyWith(seed: c, variation: 0));

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final current = _second ? r.second : r.seed;
    Widget swatch(Color c, {bool selected = false, Key? key, VoidCallback? onTap, Widget? child}) => InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(color: selected ? Neon.text : Neon.line, width: selected ? 2.5 : 1),
            ),
            child: child,
          ),
        );
    return EditorCard(
      key: const ValueKey('theme-builder'),
      title: 'Palette builder',
      accent: Neon.green,
      trailing: TextButton.icon(
        key: const ValueKey('theme-shuffle'),
        onPressed: () => _build(r.copyWith(variation: r.variation + 1)),
        icon: const Icon(Icons.shuffle, size: 18),
        label: const Text('Shuffle'),
      ),
      children: [
        const EditorLabel('Mood', subtitle: 'A starting point; the light and dark palettes are made together'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final m in paletteMoods)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  key: ValueKey('mood-${m.name}'),
                  avatar: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: Neon.ramp([m.recipe.seed, m.recipe.second ?? m.recipe.seed])),
                    ),
                  ),
                  label: Text(m.name),
                  selected: widget.recipe != null &&
                      widget.recipe!.seed == m.recipe.seed &&
                      widget.recipe!.second == m.recipe.second &&
                      widget.recipe!.harmony == m.recipe.harmony,
                  onSelected: (_) => _build(m.recipe),
                ),
              ),
          ]),
        ),
        Row(children: [
          const Expanded(child: EditorLabel('Seed colours', subtitle: 'The first is the main accent')),
          ChoiceTiles<bool>(
            accent: Neon.green,
            value: _second,
            choices: const [(false, 'First'), (true, 'Second')],
            onChanged: (v) => setState(() => _second = v),
          ),
        ]),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final c in seedSwatches)
            swatch(c,
                key: ValueKey('seed-${CawTheme.hex(c)}'),
                selected: current != null && current.toARGB32() == c.toARGB32(),
                onTap: () => _seed(c)),
          swatch(current ?? r.seed,
              key: const ValueKey('seed-custom'),
              onTap: () async {
                final c = await widget.pickColor(current ?? r.seed);
                if (c != null) _seed(c);
              },
              child: Icon(Icons.colorize, size: 16, color: Neon.ink)),
          if (_second && r.second != null)
            TextButton(
              key: const ValueKey('seed-clear-second'),
              onPressed: () => _build(r.copyWith(clearSecond: true)),
              child: const Text('No second colour'),
            ),
        ]),
        const EditorLabel('Harmony', subtitle: 'How the other accents sit around the seed on the colour wheel'),
        ChoiceTiles<Harmony>(
          accent: Neon.green,
          value: widget.recipe?.harmony,
          choices: [for (final h in Harmony.values) (h, h.label)],
          onChanged: (h) => _build(r.copyWith(harmony: h, variation: 0)),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.verified_outlined, size: 14, color: Neon.dim),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              widget.recipe == null
                  ? 'Pick a mood or a colour to build a palette. Every colour stays editable under Advanced.'
                  : 'Built for light and dark; text and accents meet WCAG AA contrast (4.5:1, tracks 3:1).',
              style: const TextStyle(color: Neon.dim, fontSize: 11),
            ),
          ),
        ]),
        SizedBox(height: Space.xs),
      ],
    );
  }
}
