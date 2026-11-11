// The theme editor (Settings › Look › Theme; owner 2026-11-11: "a theme editor that builds the theme for you"): pick
// or start a theme and its Mode, build its palette from seeds, set its feel, layout and behaviour with a live preview,
// edit any colour under Advanced, and save, duplicate, import or export it.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'panel_motion.dart';
import '../model/settings.dart';
import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';
import 'theme_builder.dart';
import 'theme_editor_parts.dart';
import 'theme_feel.dart';
import 'theme_palette.dart';
import 'theme_preview.dart';
import 'tokens.dart';

/// Pick a theme, change its colours (with a live preview) and the rest of its profile, and save, duplicate, export
/// or import it. A profile value changed here is in force at once; with a custom theme chosen it is saved into that
/// theme too ([Settings.save]). Starter themes are read-only: a change offers a duplicate.
class ThemeEditor extends StatefulWidget {
  const ThemeEditor({super.key, required this.settings});
  final Settings settings;

  @override
  State<ThemeEditor> createState() => _ThemeEditorState();
}

class _ThemeEditorState extends State<ThemeEditor> {
  late CawTheme _draft = widget.settings.theme;
  late final TextEditingController _name = TextEditingController(text: _draft.name);
  String? _openSlot;
  bool _dirty = false;

  /// The palette builder's recipe while it is in use (null: the theme's own colours).
  PaletteRecipe? _recipe;

  /// A look, layout or behaviour value was changed while a starter theme is chosen: offer a duplicate.
  bool _profileEdited = false;

  Settings get s => widget.settings;
  bool get _starter => s.isStarter(s.themeName);

  @override
  void dispose() {
    _name.dispose();
    final settings = s;
    Future.microtask(() => settings.preview(null)); // unsaved edits are dropped (after the tree unlocks)
    super.dispose();
  }

  void _edit(CawTheme t) {
    setState(() {
      _draft = t;
      _dirty = true;
    });
    s.preview(t);
  }

  Future<void> _choose(CawTheme t) async {
    setState(() {
      _draft = t;
      _name.text = t.name;
      _dirty = false;
      _profileEdited = false;
    });
    s.preview(null);
    await s.chooseTheme(t.name);
    if (mounted) setState(() => _draft = s.theme);
  }

  /// Changes a profile value: in force and saved (into the chosen custom theme too).
  void _set(void Function(Settings) change) {
    Haptics.tap();
    s.update(change);
    setState(() => _profileEdited = true);
  }

  /// Makes the other mode's palette from the one shown (the built-ins' algorithm), shows it and switches Mode to it,
  /// so it can be edited at once.
  Future<void> _makeOther() async {
    final light = !_draft.light;
    _edit((light ? _draft.makeLight() : _draft.makeDark()).shown(light));
    await s.setLookMode(light ? LookMode.light : LookMode.dark);
    if (mounted) _say(light ? 'Made a light version: edit it below' : 'Made a dark version: edit it below');
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// The theme as the editor shows it: the colours being edited and the profile in force.
  CawTheme get _whole => _draft.copyWith(profile: s.captureProfile());

  Future<void> _save() async {
    final name = _name.text.trim().isEmpty ? _draft.name : _name.text.trim();
    final replacing = _starter ? null : s.themeName;
    final saved = await s.saveTheme(_whole.copyWith(name: name), replacing: replacing);
    if (!mounted) return;
    setState(() {
      _draft = saved;
      _name.text = saved.name;
      _dirty = false;
      _profileEdited = false;
    });
    _say('Saved theme "${saved.name}"');
  }

  Future<void> _duplicate() async {
    final copy = await s.saveTheme(_whole.copyWith(name: s.freeName('${_draft.name} copy')));
    if (!mounted) return;
    await _choose(copy);
  }

  Future<void> _delete() async {
    await s.deleteTheme(s.themeName);
    if (mounted) await _choose(s.theme);
  }

  Future<void> _export() async {
    final t = _whole;
    try {
      final saved = await FilePicker.saveFile(
        fileName: '${t.name}.theme',
        bytes: utf8.encode(t.toFile()),
        mimeType: 'text/plain',
      );
      if (mounted) _say(saved == null ? 'Not exported (picker closed).' : 'Exported ${t.name}.theme');
    } catch (e) {
      if (mounted) _say('Could not export: $e');
    }
  }

  Future<void> _import() async {
    try {
      final f = await FilePicker.pickFile();
      if (f == null) return;
      final t = CawTheme.parse(await f.xFile.readAsString());
      final saved = await s.saveTheme(t.copyWith(name: s.freeName(t.name)));
      if (!mounted) return;
      await _choose(saved);
      _say('Imported "${saved.name}"');
    } catch (e) {
      if (mounted) _say(e is FormatException ? 'Not a theme: ${e.message}' : 'Could not import: $e');
    }
  }

  /// The palette builder made [r]: both palettes go into the draft (shown live), editable afterwards.
  void _buildPalette(PaletteRecipe r) {
    final p = buildPalettes(r);
    setState(() => _recipe = r);
    _edit(_draft.copyWith(colors: p.dark, lightColors: p.light));
  }

  /// A colour from the picker in a dialog (the builder's custom seed).
  Future<Color?> _pickColor(Color start) => showDialog<Color>(
    context: context,
    builder: (c) {
      var picked = start;
      return AlertDialog(
        title: const Text('Seed colour'),
        content: SizedBox(
          width: 320,
          child: ColorPicker(color: start, onChanged: (v) => picked = v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, picked), child: const Text('Use')),
        ],
      );
    },
  );

  /// Start from: a new custom theme from a built-in family or the current theme, with the profile in force.
  Future<void> _startFrom() async {
    final from = await showModalBottomSheet<CawTheme>(
      context: context,
      sheetAnimationStyle: sheetAnimation(context), // in and out at the theme's pace
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('New theme from…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            for (final t in [...starterThemes, if (!_starter) s.themeNamed(s.themeName)])
              ListTile(
                key: ValueKey('start-from-${t.name}'),
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final slot in ['bg', 'green', 'pink', 'blue']) _Swatch(t.shown(s.showsLight)[slot], size: 14),
                  ],
                ),
                title: Text(starterThemes.contains(t) ? t.name : 'Your current theme (${t.name})'),
                subtitle: Text(
                  t.flat ? 'Flat: no glow or glass' : 'Light and dark',
                  style: const TextStyle(color: Neon.dim),
                ),
                onTap: () => Navigator.pop(c, t),
              ),
          ],
        ),
      ),
    );
    if (from == null || !mounted) return;
    final base = from.shown(s.showsLight);
    final copy = await s.saveTheme(
      base.copyWith(
        name: s.freeName(starterThemes.contains(from) ? 'My ${from.name}' : '${from.name} copy'),
        profile: s.captureProfile(),
      ),
    );
    if (!mounted) return;
    setState(() => _recipe = null);
    await _choose(copy);
    _say('Made "${copy.name}": build its palette, set its feel, then Save');
  }

  /// A choice of [values] as tiles, in force at once ([_set]).
  Widget _tiles<T>(
    String key,
    String title,
    T value,
    List<(T, String)> choices,
    void Function(Settings, T) change, {
    String? subtitle,
    Color accent = Neon.yellow,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      EditorLabel(title, subtitle: subtitle),
      ChoiceTiles<T>(
        key: ValueKey('theme-$key'),
        accent: accent,
        value: value,
        choices: choices,
        onChanged: (v) => _set((x) => change(x, v)),
      ),
    ],
  );

  Widget _slider(
    String key,
    String title,
    double value,
    double min,
    double max,
    String Function(double) show,
    void Function(Settings, double) change,
    double reset, {
    int? divisions,
  }) => editorSlider(
    key,
    title,
    value,
    min,
    max,
    show,
    divisions: divisions,
    onChanged: (v) => s.adjust((x) => change(x, v)),
    onChangeEnd: (_) => _settle(),
    onReset: () => _set((x) => change(x, reset)),
  );

  /// A slider let go: saved, and with a starter chosen a duplicate is offered.
  void _settle() {
    s.save();
    Haptics.tick();
    setState(() => _profileEdited = true);
  }

  String _pct(double v) => '${(v * 100).round()}%';
  String _px(double v) => v == 0 ? 'Default' : '${v.round()} px';

  Widget _layout() {
    final dock = s.dockLayouts.keys.where((k) => !k.endsWith('_floating')).length;
    final e = s.editor;
    const accent = Neon.yellow;
    return EditorCard(
      key: const ValueKey('theme-layout'),
      title: 'Layout',
      accent: accent,
      children: [
        _tiles<Density>('density', 'Density', s.density, const [
          (Density.comfortable, 'Roomy'),
          (Density.compact, 'Compact'),
        ], (x, v) => x.density = v),
        _slider(
          'headerWidth',
          'Track header width',
          s.headerWidth == 0 ? Settings.minHeaderWidth - 8 : s.headerWidth,
          Settings.minHeaderWidth - 8,
          Settings.maxHeaderWidth,
          (v) => _px(v < Settings.minHeaderWidth ? 0 : v),
          (x, v) => x.headerWidth = v < Settings.minHeaderWidth ? 0 : v.roundToDouble(),
          0,
        ),
        _slider(
          'trackGap',
          'Gap between tracks',
          s.trackGap,
          0,
          Settings.maxTrackGap,
          (v) => '${v.round()} px',
          (x, v) => x.trackGap = v.roundToDouble(),
          6,
          divisions: 24,
        ),
        _slider(
          'focusShare',
          'Focus panel width',
          s.focusPanelShare,
          Settings.minFocusPanelShare,
          Settings.maxFocusPanelShare,
          _pct,
          (x, v) => x.focusPanelShare = v,
          Settings.defaultFocusPanelShare,
        ),
        ListTile(
          key: const ValueKey('theme-dock'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Docked panels'),
          subtitle: Text(
            dock == 0
                ? 'The presets on every screen shape; arrange the panels and the theme keeps them'
                : 'Kept for $dock screen shape${dock == 1 ? '' : 's'} (phone, landscape, desktop) as you arranged them',
            style: const TextStyle(color: Neon.dim, fontSize: 11),
          ),
          trailing: dock == 0
              ? null
              : TextButton(onPressed: () => _set((x) => x.dockLayouts = {}), child: const Text('Presets')),
        ),
        ListTile(
          key: const ValueKey('theme-toolbars'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Toolbars'),
          subtitle: Text(
            [
              'Key row: ${e.keyRow.length} keys',
              e.soloButton ? 'Solo shown' : 'Solo hidden',
              e.scope ? 'scope shown' : 'scope hidden',
              e.barOnTop ? 'Run bar on top' : 'Run bar below',
            ].join(' · '),
            style: const TextStyle(color: Neon.dim, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _behaviour() {
    const accent = Neon.pink;
    return EditorCard(
      key: const ValueKey('theme-behaviour'),
      title: 'Behaviour',
      accent: accent,
      children: [
        _tiles<LongPressMenuStyle>(
          'longPress',
          'Long-press menus',
          s.longPressMenu,
          const [(LongPressMenuStyle.list, 'List'), (LongPressMenuStyle.ring, 'Ring')],
          (x, v) => x.longPressMenu = v,
          accent: accent,
        ),
        const EditorLabel('Edit animations', subtitle: 'Which edits animate (the style is under Feel)'),
        for (final k in EditMotionKind.values)
          editorSwitch(
            'edit-${k.name}',
            'Animate ${k.name}',
            k.label,
            s.editMotionKinds.contains(k),
            (v) => _set((x) => x.editMotionKinds = v ? {...x.editMotionKinds, k} : ({...x.editMotionKinds}..remove(k))),
          ),
        editorSwitch(
          'snap',
          'Snap to grid',
          'Whether the piano roll opens with snapping on',
          s.rollSnap,
          (v) => _set((x) => x.rollSnap = v),
        ),
        _tiles<int>(
          'grid',
          'Grid',
          s.rollGrid,
          [for (final g in Settings.rollGrids) (g, '1/$g')],
          (x, v) => x.rollGrid = v,
          accent: accent,
        ),
        _tiles<ValueGrid>(
          'valueGrid',
          'Value grid',
          s.roll.valueGrid,
          [for (final g in ValueGrid.values) (g, g.label)],
          (x, v) => x.roll = x.roll.copyWith(valueGrid: v),
          accent: accent,
        ),
      ],
    );
  }

  /// Advanced: every colour of the palette shown, with hex, and the other palette made from it.
  Widget _advanced() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Material(
      color: Neon.panel,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.l),
        side: BorderSide(color: Neon.line),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey('theme-advanced'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: const Text('Advanced: every colour', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(
            '${CawTheme.slots.length} colours of the ${_draft.light ? 'light' : 'dark'} palette, as hex',
            style: const TextStyle(color: Neon.dim, fontSize: 11),
          ),
          children: [
            _Preview(theme: _draft),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _draft.light
                        ? 'Editing the light palette (Mode: Light). The dark one stays as it is.'
                        : 'Editing the dark palette. The light one is made from it until you make and edit your own.',
                    style: const TextStyle(color: Neon.dim, fontSize: 11),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('theme-make-other'),
                  onPressed: _makeOther,
                  icon: Icon(_draft.light ? Icons.dark_mode_outlined : Icons.light_mode_outlined, size: 18),
                  label: Text(_draft.light ? 'Make dark version' : 'Make light version'),
                ),
              ],
            ),
            for (final e in CawTheme.slots.entries) ...[
              ListTile(
                key: ValueKey('slot-${e.key}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: _Swatch(_draft[e.key]),
                title: Text(e.value),
                subtitle: Text('${e.key}  ${CawTheme.hex(_draft[e.key])}', style: Neon.code(size: 12, color: Neon.dim)),
                selected: _openSlot == e.key,
                onTap: () => setState(() => _openSlot = _openSlot == e.key ? null : e.key),
              ),
              if (_openSlot == e.key)
                ColorPicker(
                  key: ValueKey(e.key),
                  color: _draft[e.key],
                  onChanged: (c) {
                    setState(() => _recipe = null);
                    _edit(_draft.withColor(e.key, c));
                  },
                ),
            ],
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: s, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    _draft = _draft.shown(s.showsLight); // the Mode switch shows the draft's other palette, edits and all
    final starter = _starter && !_dirty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Theme'),
        backgroundColor: Neon.panel,
        actions: [
          IconButton(
            key: const ValueKey('theme-start-from'),
            tooltip: 'New theme from a family or this one',
            icon: const Icon(Icons.add),
            onPressed: _startFrom,
          ),
          IconButton(tooltip: 'Import a theme file', icon: const Icon(Icons.file_open), onPressed: _import),
          IconButton(tooltip: 'Export this theme', icon: const Icon(Icons.ios_share), onPressed: _export),
        ],
      ),
      // Phone first; on a desktop the editor keeps a readable width.
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final t in s.themes)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(t.name),
                          avatar: _Swatch(t.shown(s.showsLight)['green'], size: 14),
                          selected: t.name == s.themeName,
                          onSelected: (_) {
                            setState(() => _recipe = null);
                            _choose(t);
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<LookMode>(
                        key: const ValueKey('theme-mode'),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        segments: [for (final m in LookMode.values) ButtonSegment(value: m, label: Text(m.label))],
                        selected: {s.lookMode},
                        onSelectionChanged: (v) {
                          Haptics.tap();
                          s.setLookMode(v.first);
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ThemePreview(theme: _draft),
              PaletteBuilderCard(recipe: _recipe, onBuild: _buildPalette, pickColor: _pickColor),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Name'),
                      onChanged: (_) => setState(() => _dirty = true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('theme-save'),
                    onPressed: _dirty ? _save : null,
                    icon: const Icon(Icons.save),
                    label: Text(_starter ? 'Save copy' : 'Save'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton.icon(onPressed: _duplicate, icon: const Icon(Icons.copy), label: const Text('Duplicate')),
                  if (!_starter)
                    TextButton.icon(
                      onPressed: _delete,
                      icon: Icon(Icons.delete_outline, color: Neon.pink),
                      label: Text('Delete', style: TextStyle(color: Neon.pink)),
                    ),
                  const Spacer(),
                  if (starter)
                    const Flexible(
                      child: Text(
                        'Starter themes save as a copy',
                        textAlign: TextAlign.end,
                        style: TextStyle(color: Neon.dim, fontSize: 12),
                      ),
                    ),
                ],
              ),
              if (_starter && _profileEdited)
                Container(
                  key: const ValueKey('theme-offer-duplicate'),
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  decoration: BoxDecoration(
                    color: Neon.yellow.withValues(alpha: 0.1),
                    border: Border.all(color: Neon.yellow.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${s.themeName} is a starter theme: these changes stay in your settings, not in it.',
                          style: const TextStyle(color: Neon.dim, fontSize: 12),
                        ),
                      ),
                      TextButton(onPressed: _duplicate, child: const Text('Duplicate')),
                    ],
                  ),
                ),
              ThemeFeelCard(settings: s, draft: _draft, onDraft: _edit, set: _set, settle: _settle),
              _layout(),
              _behaviour(),
              _advanced(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color, {this.size = 28});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Neon.line),
    ),
  );
}

/// A small mock of the app in [theme]: a bar, a code line, layer chips and an active play button.
class _Preview extends StatelessWidget {
  const _Preview({required this.theme});
  final CawTheme theme;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    TextSpan tok(String s, String slot) => TextSpan(
      text: s,
      style: TextStyle(color: t[slot]),
    );
    return Container(
      decoration: BoxDecoration(
        color: t['bg'],
        border: Border.all(color: t['line']),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: t['panel'],
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'First loop',
                    style: TextStyle(color: t['text'], fontWeight: FontWeight.w700),
                  ),
                ),
                Text('140 BPM', style: Neon.code(size: 13, color: t['blue'])),
                const SizedBox(width: 8),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: t['green'],
                    boxShadow: t.glow
                        ? [BoxShadow(color: t['green'].withValues(alpha: 0.8), blurRadius: 12, spreadRadius: -2)]
                        : null,
                  ),
                  child: Icon(Icons.stop, size: 18, color: t['bg']),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text.rich(
              TextSpan(
                style: Neon.code(size: 13, color: t['text']),
                children: [
                  tok('// a kick\n', 'dim'),
                  tok('float ', 'pink'),
                  const TextSpan(text: 'decay = '),
                  tok('0.35f', 'yellow'),
                  const TextSpan(text: ';\n'),
                  const TextSpan(text: 'out = osc.'),
                  tok('sine', 'green'),
                  const TextSpan(text: '(freq) * '),
                  tok('env', 'blue'),
                  const TextSpan(text: '.next();'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              children: [
                for (var i = 1; i <= 4; i++)
                  Expanded(
                    child: Container(
                      height: 22,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: t['panelHi'],
                        border: Border.all(color: t['layer$i']),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      alignment: Alignment.center,
                      child: Text('Layer $i', style: TextStyle(color: t['layer$i'], fontSize: 11)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A colour picker with hue, saturation and brightness sliders and a hex field; no extra package needed.
class ColorPicker extends StatefulWidget {
  const ColorPicker({super.key, required this.color, required this.onChanged});
  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color);
  late final TextEditingController _hex = TextEditingController(text: CawTheme.hex(widget.color));

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor h) {
    setState(() => _hsv = h);
    _hex.text = CawTheme.hex(h.toColor());
    widget.onChanged(h.toColor());
  }

  Widget _slider(String label, double value, double max, ValueChanged<double> onChanged) => Row(
    children: [
      SizedBox(
        width: 28,
        child: Text(label, style: Neon.code(size: 13, color: Neon.dim)),
      ),
      Expanded(
        child: Slider(value: value, max: max, onChanged: onChanged),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      children: [
        _slider('H', _hsv.hue, 360, (v) => _set(_hsv.withHue(v))),
        _slider('S', _hsv.saturation, 1, (v) => _set(_hsv.withSaturation(v))),
        _slider('V', _hsv.value, 1, (v) => _set(_hsv.withValue(v))),
        Row(
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                controller: _hex,
                style: Neon.code(size: 14),
                decoration: const InputDecoration(labelText: '#RRGGBB'),
                onSubmitted: (v) {
                  final c = CawTheme.parseHex(v);
                  if (c != null) _set(HSVColor.fromColor(c));
                },
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
