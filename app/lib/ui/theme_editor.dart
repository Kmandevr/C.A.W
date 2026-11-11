// The theme editor (Settings › Look › Theme): pick a theme (a whole profile), edit its colours, look, layout and
// behaviour with a live preview, and save, duplicate, import or export it.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../model/settings.dart';
import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';
import 'widgets.dart';

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
          fileName: '${t.name}.theme', bytes: utf8.encode(t.toFile()), mimeType: 'text/plain');
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

  // The rows, in Settings' style.
  Text _sub(String text) => Text(text, style: const TextStyle(color: Neon.dim, fontSize: 12));

  Widget _switch(String key, String title, String subtitle, bool value, void Function(Settings, bool) set) =>
      SwitchListTile(
        key: ValueKey('theme-$key'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Text(title),
        subtitle: _sub(subtitle),
        value: value,
        onChanged: (v) => _set((x) => set(x, v)),
      );

  Widget _choice<T>(String key, String title, T value, List<(T, String)> choices, void Function(Settings, T) set,
          {String? subtitle}) =>
      ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Text(title),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (subtitle != null) _sub(subtitle),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<T>(
              key: ValueKey('theme-$key'),
              showSelectedIcon: false,
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              segments: [for (final (v, label) in choices) ButtonSegment(value: v, label: Text(label))],
              selected: {value},
              onSelectionChanged: (v) => _set((x) => set(x, v.first)),
            ),
          ),
        ]),
      );

  /// A slider: shown while it moves ([Settings.adjust]), saved when let go; a double-tap puts back [reset].
  Widget _slider(String key, String title, double value, double min, double max, String Function(double) show,
          void Function(Settings, double) set, double reset, {int? divisions}) =>
      ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Row(children: [
          Expanded(child: Text(title)),
          Text(show(value), style: Neon.code(size: 12, color: Neon.yellow)),
        ]),
        subtitle: ResetOnDoubleTap(
          onReset: () => _set((x) => set(x, reset)),
          child: Slider(
            key: ValueKey('theme-$key'),
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (v) => s.adjust((x) => set(x, v)),
            onChangeEnd: (_) {
              s.save();
              Haptics.tick();
              setState(() => _profileEdited = true);
            },
          ),
        ),
      );

  String _pct(double v) => '${(v * 100).round()}%';
  String _px(double v) => v == 0 ? 'Default' : '${v.round()} px';

  List<Widget> _look() => [
        const Heading('Look'),
        SwitchListTile(
          key: const ValueKey('theme-glow'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: const Text('Glow'),
          subtitle: _sub('A soft glow on active things (off is lighter on slow phones)'),
          value: _draft.glow,
          onChanged: (v) => _edit(_draft.copyWith(glow: v)),
        ),
        _slider('glowStrength', 'Glow strength', s.glowStrength, 0, Settings.maxGlowStrength, _pct,
            (x, v) => x.glowStrength = (v * 20).round() / 20, 1, divisions: 40),
        _choice<UiFont>('font', 'Font', s.uiFont, [for (final f in UiFont.values) (f, f.label)],
            (x, v) => x.uiFont = v, subtitle: 'The app\'s text; code always uses JetBrains Mono'),
        _slider('textScale', 'Text size', s.textScale, Settings.minTextScale, Settings.maxTextScale, _pct,
            (x, v) => x.textScale = (v * 20).round() / 20, 1, divisions: 9),
        _slider('roundness', 'Corner roundness', s.roundness, 0, Settings.maxRoundness,
            (v) => v == 0 ? 'Square' : _pct(v), (x, v) => x.roundness = (v * 10).round() / 10, 1, divisions: 20),
        _switch('glass', 'Glass', 'See-through panels, tracks and controls over a soft background', s.glass,
            (x, v) => x.glass = v),
        _choice<Density>('density', 'Density', s.density,
            const [(Density.comfortable, 'Roomy'), (Density.compact, 'Compact')], (x, v) => x.density = v),
      ];

  List<Widget> _layout() {
    final dock = s.dockLayouts.keys.where((k) => !k.endsWith('_floating')).length;
    final e = s.editor;
    return [
      const Heading('Layout'),
      _slider('trackHeight', 'Track height', s.trackHeight == 0 ? Settings.minTrackHeight - 4 : s.trackHeight,
          Settings.minTrackHeight - 4, Settings.maxTrackHeight, (v) => _px(v < Settings.minTrackHeight ? 0 : v),
          (x, v) => x.trackHeight = v < Settings.minTrackHeight ? 0 : v.roundToDouble(), 0),
      _slider('headerWidth', 'Track header width', s.headerWidth == 0 ? Settings.minHeaderWidth - 8 : s.headerWidth,
          Settings.minHeaderWidth - 8, Settings.maxHeaderWidth, (v) => _px(v < Settings.minHeaderWidth ? 0 : v),
          (x, v) => x.headerWidth = v < Settings.minHeaderWidth ? 0 : v.roundToDouble(), 0),
      _slider('trackGap', 'Gap between tracks', s.trackGap, 0, Settings.maxTrackGap, (v) => '${v.round()} px',
          (x, v) => x.trackGap = v.roundToDouble(), 6, divisions: 24),
      _slider('focusShare', 'Focus panel width', s.focusPanelShare, Settings.minFocusPanelShare,
          Settings.maxFocusPanelShare, _pct, (x, v) => x.focusPanelShare = v, Settings.defaultFocusPanelShare),
      ListTile(
        key: const ValueKey('theme-dock'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: const Text('Docked panels'),
        subtitle: _sub(dock == 0
            ? 'The presets on every screen shape; arrange the panels and the theme keeps them'
            : 'Kept for $dock screen shape${dock == 1 ? '' : 's'} (phone, landscape, desktop) as you arranged them'),
        trailing: dock == 0
            ? null
            : TextButton(onPressed: () => _set((x) => x.dockLayouts = {}), child: const Text('Presets')),
      ),
      ListTile(
        key: const ValueKey('theme-toolbars'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: const Text('Toolbars'),
        subtitle: _sub([
          'Key row: ${e.keyRow.length} keys',
          e.soloButton ? 'Solo shown' : 'Solo hidden',
          e.scope ? 'scope shown' : 'scope hidden',
          e.barOnTop ? 'Run bar on top' : 'Run bar below',
        ].join(' · ')),
      ),
    ];
  }

  List<Widget> _behaviour() => [
        const Heading('Behaviour'),
        _choice<LongPressMenuStyle>('longPress', 'Long-press menus', s.longPressMenu,
            const [(LongPressMenuStyle.list, 'List'), (LongPressMenuStyle.ring, 'Ring')], (x, v) => x.longPressMenu = v),
        _switch('haptics', 'Haptics', 'A light touch on presses, steps, snaps, grabs and drops', s.haptics,
            (x, v) => x.haptics = v),
        _slider('hapticStrength', 'Haptic strength', s.hapticStrength, 0, 1, _pct, (x, v) => x.hapticStrength = v,
            0.5, divisions: 10),
        _choice<MotionLevel>('motion', 'Motion', s.motion,
            const [(MotionLevel.full, 'Full'), (MotionLevel.reduced, 'Reduced'), (MotionLevel.off, 'Off')],
            (x, v) => x.motion = v,
            subtitle: 'Off keeps drag ghosts, snapping and press feedback'),
        _choice<EditMotionStyle>('editStyle', 'Edit animations', s.editMotionStyle,
            [for (final v in EditMotionStyle.values) (v, v.label)], (x, v) => x.editMotionStyle = v),
        for (final k in EditMotionKind.values)
          _switch('edit-${k.name}', 'Animate ${k.name}', k.label, s.editMotionKinds.contains(k),
              (x, v) => x.editMotionKinds = v ? {...x.editMotionKinds, k} : ({...x.editMotionKinds}..remove(k))),
        _switch('snap', 'Snap to grid', 'Whether the piano roll opens with snapping on', s.rollSnap,
            (x, v) => x.rollSnap = v),
        _choice<int>('grid', 'Grid', s.rollGrid, [for (final g in Settings.rollGrids) (g, '1/$g')],
            (x, v) => x.rollGrid = v),
        _choice<ValueGrid>('valueGrid', 'Value grid', s.roll.valueGrid, [for (final g in ValueGrid.values) (g, g.label)],
            (x, v) => x.roll = x.roll.copyWith(valueGrid: v)),
      ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: s, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final starter = _starter && !_dirty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Theme'),
        backgroundColor: Neon.panel,
        actions: [
          IconButton(tooltip: 'Import a theme file', icon: const Icon(Icons.file_open), onPressed: _import),
          IconButton(tooltip: 'Export this theme', icon: const Icon(Icons.ios_share), onPressed: _export),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in s.themes)
            ChoiceChip(
              label: Text(t.name),
              avatar: _Swatch(t['green'], size: 14),
              selected: t.name == s.themeName,
              onSelected: (_) => _choose(t),
            ),
        ]),
        const SizedBox(height: 12),
        _Preview(theme: _draft),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() => _dirty = true),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _dirty ? _save : null,
            icon: const Icon(Icons.save),
            label: Text(_starter ? 'Save copy' : 'Save'),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          TextButton.icon(onPressed: _duplicate, icon: const Icon(Icons.copy), label: const Text('Duplicate')),
          if (!_starter)
            TextButton.icon(
              onPressed: _delete,
              icon: Icon(Icons.delete_outline, color: Neon.pink),
              label: Text('Delete', style: TextStyle(color: Neon.pink)),
            ),
          const Spacer(),
          if (starter) Text('Starter themes save as a copy', style: TextStyle(color: Neon.dim, fontSize: 12)),
        ]),
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
            child: Row(children: [
              Expanded(
                child: _sub('${s.themeName} is a starter theme: these changes stay in your settings, not in it.'),
              ),
              TextButton(onPressed: _duplicate, child: const Text('Duplicate')),
            ]),
          ),
        const Heading('Colours'),
        for (final e in CawTheme.slots.entries) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
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
              onChanged: (c) => _edit(_draft.withColor(e.key, c)),
            ),
        ],
        ..._look(),
        ..._layout(),
        ..._behaviour(),
      ]),
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
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Neon.line)),
      );
}

/// A small mock of the app in [theme]: a bar, a code line, layer chips and an active play button.
class _Preview extends StatelessWidget {
  const _Preview({required this.theme});
  final CawTheme theme;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    TextSpan tok(String s, String slot) => TextSpan(text: s, style: TextStyle(color: t[slot]));
    return Container(
      decoration:
          BoxDecoration(color: t['bg'], border: Border.all(color: t['line']), borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: t['panel'],
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: Text('First loop', style: TextStyle(color: t['text'], fontWeight: FontWeight.w700)),
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
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text.rich(
            TextSpan(style: Neon.code(size: 13, color: t['text']), children: [
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
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Row(children: [
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
          ]),
        ),
      ]),
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

  Widget _slider(String label, double value, double max, ValueChanged<double> onChanged) => Row(children: [
        SizedBox(width: 28, child: Text(label, style: Neon.code(size: 13, color: Neon.dim))),
        Expanded(child: Slider(value: value, max: max, onChanged: onChanged)),
      ]);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(children: [
          _slider('H', _hsv.hue, 360, (v) => _set(_hsv.withHue(v))),
          _slider('S', _hsv.saturation, 1, (v) => _set(_hsv.withSaturation(v))),
          _slider('V', _hsv.value, 1, (v) => _set(_hsv.withValue(v))),
          Row(children: [
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
          ]),
        ]),
      );
}

