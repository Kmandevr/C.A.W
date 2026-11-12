// The theme editor's Feel section: haptics (strength and feel per kind), corners, font and size, how tracks and
// clips look, glow and glass, and the motion style (presets, pace, curve, entrance and exit) with a live tile.
import 'package:flutter/material.dart';

import '../model/settings.dart';
import 'arrange/clip_look.dart';
import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';
import 'theme_editor_parts.dart';
import 'tokens.dart';

/// Arrange's header and row sizes for the header styles (owner, 2026-11-11: compact or roomy).
const headerStyles = {'Default': (0.0, 0.0), 'Compact': (112.0, 48.0), 'Roomy': (200.0, 88.0)};

/// The Feel card. [set] changes profile values (in force at once, saved, and marked edited); [adjust] shows a
/// slider's value while it moves and [settle] saves it; [draft] and [onDraft] carry the theme's own glow switch.
class ThemeFeelCard extends StatelessWidget {
  const ThemeFeelCard({
    super.key,
    required this.settings,
    required this.draft,
    required this.onDraft,
    required this.set,
    required this.settle,
  });
  final Settings settings;
  final CawTheme draft;
  final ValueChanged<CawTheme> onDraft;
  final void Function(void Function(Settings)) set;
  final VoidCallback settle;

  Settings get s => settings;

  String _pct(double v) => '${(v * 100).round()}%';

  Widget _slider(String key, String title, double value, double min, double max, String Function(double) show,
          void Function(Settings, double) change, double reset, {int? divisions, String? subtitle}) =>
      editorSlider(key, title, value, min, max, show,
          divisions: divisions,
          subtitle: subtitle,
          onChanged: (v) => s.adjust((x) => change(x, v)),
          onChangeEnd: (_) => settle(),
          onReset: () => set((x) => change(x, reset)));

  @override
  Widget build(BuildContext context) {
    const accent = Neon.blue;
    final header = headerStyles.entries
        .where((e) => e.value == (s.headerWidth, s.trackHeight))
        .map((e) => e.key)
        .firstOrNull;
    return EditorCard(
      key: const ValueKey('theme-feel'),
      title: 'Feel',
      accent: accent,
      children: [
        // Touch.
        editorSwitch('haptics', 'Haptics', 'A light touch on presses, steps, snaps, grabs and drops', s.haptics,
            (v) => set((x) => x.haptics = v)),
        if (s.haptics) ...[
          _slider('hapticStrength', 'Haptic strength', s.hapticStrength, 0, 1, _pct, (x, v) => x.hapticStrength = v,
              0.5, divisions: 10),
          const EditorLabel('Haptic style', subtitle: 'Light as designed, Firm stronger, or Off, for each kind of touch'),
          for (final k in HapticKind.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                SizedBox(width: 82, child: Text(_kindName(k), style: const TextStyle(fontSize: 12))),
                Expanded(
                  child: ChoiceTiles<HapticFeel>(
                    key: ValueKey('haptic-feel-${k.name}'),
                    accent: accent,
                    value: s.hapticFeel[k] ?? HapticFeel.light,
                    choices: [for (final f in HapticFeel.values) (f, f.label)],
                    onChanged: (f) => set((x) => x.hapticFeel = {...x.hapticFeel, k: f}..removeWhere((_, v) => v == HapticFeel.light)),
                  ),
                ),
              ]),
            ),
        ],
        // Shape and type.
        _slider('roundness', 'Corner roundness', s.roundness, 0, Settings.maxRoundness,
            (v) => v == 0 ? 'Sharp' : (v >= Settings.maxRoundness ? 'Soft' : _pct(v)),
            (x, v) => x.roundness = (v * 10).round() / 10, 1,
            divisions: 20, subtitle: 'Buttons, cards, sheets, clips and knob caps, from sharp to soft'),
        const EditorLabel('Font', subtitle: 'The app\'s text; code always uses JetBrains Mono'),
        ChoiceTiles<UiFont>(
          key: const ValueKey('theme-font'),
          accent: accent,
          value: s.uiFont,
          choices: [for (final f in UiFont.values) (f, f.label)],
          onChanged: (v) => set((x) => x.uiFont = v),
        ),
        _slider('textScale', 'Text size', s.textScale, Settings.minTextScale, Settings.maxTextScale, _pct,
            (x, v) => x.textScale = (v * 20).round() / 20, 1, divisions: 9),
        // Tracks.
        const EditorLabel('Track headers', subtitle: 'Compact: narrow headers, short rows. Roomy: wide and tall'),
        ChoiceTiles<String>(
          key: const ValueKey('theme-header-style'),
          accent: accent,
          value: header,
          choices: [for (final k in headerStyles.keys) (k, k)],
          onChanged: (k) => set((x) {
            final (w, h) = headerStyles[k]!;
            x.headerWidth = w;
            x.trackHeight = h;
          }),
        ),
        _slider('trackHeight', 'Track height', s.trackHeight == 0 ? Settings.minTrackHeight - 4 : s.trackHeight,
            Settings.minTrackHeight - 4, Settings.maxTrackHeight,
            (v) => v < Settings.minTrackHeight ? 'Default' : '${v.round()} px',
            (x, v) => x.trackHeight = v < Settings.minTrackHeight ? 0 : v.roundToDouble(), 0),
        const EditorLabel('Clip corners'),
        ChoiceTiles<ClipCorner>(
          key: const ValueKey('theme-clip-corner'),
          accent: accent,
          value: s.clipCorner,
          choices: [for (final c in ClipCorner.values) (c, c.label)],
          onChanged: (v) => set((x) => x.clipCorner = v),
        ),
        const EditorLabel('Clip fill', subtitle: 'Standard follows Glass: a faint gradient with it, a tint without'),
        ChoiceTiles<ClipFill>(
          key: const ValueKey('theme-clip-fill'),
          accent: accent,
          value: s.clipFill,
          choices: [for (final c in ClipFill.values) (c, c.label)],
          onChanged: (v) => set((x) => x.clipFill = v),
        ),
        // Light and depth.
        editorSwitch(
            'glow',
            'Glow',
            draft.flat ? 'Off in a flat theme' : 'A soft glow on active things (off is lighter on slow phones)',
            draft.glow && !draft.flat,
            draft.flat ? null : (v) => onDraft(draft.copyWith(glow: v))),
        if (draft.glow && !draft.flat)
          _slider('glowStrength', 'Glow strength', s.glowStrength, 0, Settings.maxGlowStrength, _pct,
              (x, v) => x.glowStrength = (v * 20).round() / 20, 1, divisions: 40),
        editorSwitch('glass', 'Glass', draft.flat ? 'Off in a flat theme' : 'See-through panels over a soft background',
            s.glass && !draft.flat, draft.flat ? null : (v) => set((x) => x.glass = v)),
        // Motion.
        const EditorLabel('Motion', subtitle: 'Off keeps drag ghosts, snapping and press feedback'),
        ChoiceTiles<MotionLevel>(
          key: const ValueKey('theme-motion'),
          accent: accent,
          value: s.motion,
          choices: const [(MotionLevel.full, 'Full'), (MotionLevel.reduced, 'Reduced'), (MotionLevel.off, 'Off')],
          onChanged: (v) => set((x) => x.motion = v),
        ),
        MotionStyleEditor(settings: s, set: set),
      ],
    );
  }

  static String _kindName(HapticKind k) => switch (k) {
        HapticKind.tap => 'Presses',
        HapticKind.tick => 'Steps',
        HapticKind.grab => 'Grabs',
        HapticKind.drop => 'Drops',
        HapticKind.threshold => 'Thresholds',
        HapticKind.error => 'Refusals',
      };
}

/// The motion style: presets, then pace, curve, entrance and exit, and a tile that plays them.
class MotionStyleEditor extends StatelessWidget {
  const MotionStyleEditor({super.key, required this.settings, required this.set});
  final Settings settings;
  final void Function(void Function(Settings)) set;

  @override
  Widget build(BuildContext context) {
    const accent = Neon.violet;
    final f = settings.motionFeel;
    final presets = {'Standard': MotionFeel.subtle, 'Playful': MotionFeel.playful, ...MotionFeel.presets};
    final preset = presets.entries.where((e) => e.value == f).map((e) => e.key).firstOrNull;
    final off = settings.motion == MotionLevel.off;
    void feel(MotionFeel v) => set((x) => x.motionFeel = v);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EditorLabel('Animation style',
          subtitle: off ? 'Motion is Off: only the motion that helps use the app runs' : 'Pages, sheets, panels and edits'),
      ChoiceTiles<String>(
        key: const ValueKey('theme-motion-preset'),
        accent: accent,
        value: preset,
        choices: [for (final k in presets.keys) (k, k)],
        onChanged: off ? null : (k) => feel(presets[k]!),
      ),
      const SizedBox(height: 8),
      _MotionTile(feel: f, level: settings.motion),
      const EditorLabel('Pace'),
      ChoiceTiles<MotionPace>(
        key: const ValueKey('theme-motion-pace'),
        accent: accent,
        value: f.pace,
        choices: [for (final v in MotionPace.values) (v, v.label)],
        onChanged: off ? null : (v) => feel(f.copyWith(pace: v)),
      ),
      const EditorLabel('Curve'),
      ChoiceTiles<MotionCurve>(
        key: const ValueKey('theme-motion-curve'),
        accent: accent,
        value: f.curve,
        choices: [for (final v in MotionCurve.values) (v, v.label)],
        onChanged: off ? null : (v) => feel(f.copyWith(curve: v)),
      ),
      const EditorLabel('Entrance', subtitle: 'Reduced motion always fades'),
      ChoiceTiles<MotionTransition>(
        key: const ValueKey('theme-motion-enter'),
        accent: accent,
        value: f.enter,
        choices: [for (final v in MotionTransition.values) (v, v.label)],
        onChanged: off ? null : (v) => feel(f.copyWith(enter: v)),
      ),
      const EditorLabel('Exit'),
      ChoiceTiles<MotionTransition>(
        key: const ValueKey('theme-motion-exit'),
        accent: accent,
        value: f.exit,
        choices: [for (final v in MotionTransition.values) (v, v.label)],
        onChanged: off ? null : (v) => feel(f.copyWith(exit: v)),
      ),
    ]);
  }
}

/// A live tile: tap it and a card enters, waits, and exits in the motion style shown.
class _MotionTile extends StatefulWidget {
  const _MotionTile({required this.feel, required this.level});
  final MotionFeel feel;
  final MotionLevel level;

  @override
  State<_MotionTile> createState() => _MotionTileState();
}

class _MotionTileState extends State<_MotionTile> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, value: 1);
  bool _leaving = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final d = EditMotion.scaled(Motion.of(context), EditMotionKind.panels, const Duration(milliseconds: 260));
    if (d == null) return;
    _c.duration = d;
    setState(() => _leaving = true);
    await _c.reverse(from: 1);
    if (!mounted) return;
    setState(() => _leaving = false);
    await _c.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: 120,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Neon.violet.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(Radii.m),
        border: Border.all(color: Neon.violet),
      ),
      child: const Text('Tap to play', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Neon.violet)),
    );
    return GestureDetector(
      key: const ValueKey('theme-motion-tile'),
      behavior: HitTestBehavior.opaque,
      onTap: _play,
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: Neon.ink.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(Radii.m),
          border: Border.all(color: Neon.line),
        ),
        alignment: Alignment.center,
        child: EditMotion.transition(_c, card,
            enter: !_leaving, fadeOnly: Motion.of(context) == MotionLevel.reduced),
      ),
    );
  }
}
