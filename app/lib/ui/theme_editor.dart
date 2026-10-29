// Settings page (theme, density, live coding, licences) and the theme editor with live preview, import and export.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../model/settings.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.settings});
  final Settings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('Settings'), backgroundColor: Neon.panel),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            const Heading('Look'),
            ListTile(
              leading: Icon(Icons.palette, color: Neon.pink),
              title: const Text('Theme'),
              subtitle: Text(settings.themeName, style: TextStyle(color: Neon.dim)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ThemeEditor(settings: settings))),
            ),
            ListTile(
              leading: Icon(Icons.density_medium, color: Neon.blue),
              title: const Text('Density'),
              subtitle: Text(settings.compact ? 'Compact: more on screen' : 'Comfortable: 48 dp touch targets',
                  style: TextStyle(color: Neon.dim)),
              trailing: SegmentedButton<Density>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: Density.comfortable, label: Text('Comfortable')),
                  ButtonSegment(value: Density.compact, label: Text('Compact')),
                ],
                selected: {settings.density},
                onSelectionChanged: (v) => settings.update((s) => s.density = v.first),
              ),
            ),
            SwitchListTile(
              secondary: Icon(Icons.speed, color: Neon.green),
              title: const Text('Light mode'),
              subtitle: Text('For slow devices: no glow or scopes, slower meters, 4 voices per pattern layer, '
                  'and auto-update waits while playing', style: TextStyle(color: Neon.dim)),
              value: settings.lightMode,
              onChanged: (v) => settings.update((s) => s.lightMode = v),
            ),
            SwitchListTile(
              secondary: Icon(Icons.auto_mode, color: Neon.blue),
              title: const Text('Turn light mode on when the sound stutters'),
              value: settings.lightAuto,
              onChanged: (v) => settings.update((s) => s.lightAuto = v),
            ),
            const Heading('Live coding'),
            SwitchListTile(
              secondary: Icon(Icons.bolt, color: Neon.green),
              title: const Text('Auto-update'),
              subtitle: Text('Code swaps in by itself after you stop typing', style: TextStyle(color: Neon.dim)),
              value: settings.liveUpdate,
              onChanged: (v) => settings.update((s) => s.liveUpdate = v),
            ),
            ListTile(
              enabled: settings.liveUpdate,
              leading: Icon(Icons.timer_outlined, color: Neon.yellow),
              title: Text('Delay: ${settings.liveDelayMs} ms', style: Neon.code(size: 14)),
              subtitle: Slider(
                min: 100,
                max: 2000,
                divisions: 38,
                value: settings.liveDelayMs.clamp(100, 2000).toDouble(),
                onChanged: settings.liveUpdate
                    ? (v) {
                        settings.liveDelayMs = v.round();
                        settings.preview(null); // shows the value; saved when the drag ends
                      }
                    : null,
                onChangeEnd: (v) => settings.update((s) => s.liveDelayMs = v.round()),
              ),
            ),
            ListTile(
              leading: Icon(Icons.av_timer, color: Neon.blue),
              title: const Text('Swap timing'),
              subtitle: Text('When new code takes over the playing sound', style: TextStyle(color: Neon.dim)),
              trailing: SegmentedButton<SwapTiming>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: SwapTiming.now, label: Text('Now')),
                  ButtonSegment(value: SwapTiming.beat, label: Text('Beat')),
                  ButtonSegment(value: SwapTiming.bar, label: Text('Bar')),
                ],
                selected: {settings.swapTiming},
                onSelectionChanged: (v) => settings.update((s) => s.swapTiming = v.first),
              ),
            ),
            SwitchListTile(
              secondary: Icon(Icons.keyboard, color: Neon.yellow),
              title: const Text('Vim keys in the code editor'),
              subtitle: Text('With a keyboard: WASD moves, I types, Esc stops typing', style: TextStyle(color: Neon.dim)),
              value: settings.vimCode,
              onChanged: (v) => settings.update((s) => s.vimCode = v),
            ),
            const Heading('Code editor'),
            ..._editorSettings(context, settings),
            const Heading('Piano roll'),
            ..._rollSettings(settings),
            const Heading('About'),
            ListTile(
              leading: Icon(Icons.description_outlined, color: Neon.dim),
              title: const Text('Licences'),
              subtitle: Text('Including JetBrains Mono (SIL Open Font License 1.1)', style: TextStyle(color: Neon.dim)),
              onTap: () => showLicensePage(context: context, applicationName: 'C.A.W'),
            ),
          ]),
        ),
      );
}

/// Pick a theme, change its colours with a live preview, and save, duplicate, export or import it.
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

  Settings get s => widget.settings;

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

  void _choose(CawTheme t) {
    setState(() {
      _draft = t;
      _name.text = t.name;
      _dirty = false;
    });
    s.update((x) {
      x.preview(null);
      x.themeName = t.name;
    });
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final name = _name.text.trim().isEmpty ? _draft.name : _name.text.trim();
    final replacing = s.isStarter(s.themeName) ? null : s.themeName;
    final saved = await s.saveTheme(_draft.copyWith(name: name), replacing: replacing);
    if (!mounted) return;
    setState(() {
      _draft = saved;
      _name.text = saved.name;
      _dirty = false;
    });
    _say('Saved theme "${saved.name}"');
  }

  Future<void> _duplicate() async {
    final copy = await s.saveTheme(_draft.copyWith(name: s.freeName('${_draft.name} copy')));
    if (!mounted) return;
    _choose(copy);
  }

  Future<void> _delete() async {
    await s.deleteTheme(s.themeName);
    if (mounted) _choose(s.theme);
  }

  Future<void> _export() async {
    try {
      final saved = await FilePicker.saveFile(
          fileName: '${_draft.name}.theme', bytes: utf8.encode(_draft.toFile()), mimeType: 'text/plain');
      if (mounted) _say(saved == null ? 'Not exported (picker closed).' : 'Exported ${_draft.name}.theme');
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
      _choose(saved);
      _say('Imported "${saved.name}"');
    } catch (e) {
      if (mounted) _say(e is FormatException ? 'Not a theme: ${e.message}' : 'Could not import: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final starter = s.isStarter(s.themeName) && !_dirty;
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
            label: Text(s.isStarter(s.themeName) ? 'Save copy' : 'Save'),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          TextButton.icon(onPressed: _duplicate, icon: const Icon(Icons.copy), label: const Text('Duplicate')),
          if (!s.isStarter(s.themeName))
            TextButton.icon(
              onPressed: _delete,
              icon: Icon(Icons.delete_outline, color: Neon.pink),
              label: Text('Delete', style: TextStyle(color: Neon.pink)),
            ),
          const Spacer(),
          if (starter) Text('Starter themes save as a copy', style: TextStyle(color: Neon.dim, fontSize: 12)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Glow'),
          subtitle:
              Text('A soft glow on active things (off is lighter on slow phones)', style: TextStyle(color: Neon.dim)),
          value: _draft.glow,
          onChanged: (v) => _edit(_draft.copyWith(glow: v)),
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
              tok('param ', 'pink'),
              const TextSpan(text: 'decay = '),
              tok('0.35', 'yellow'),
              const TextSpan(text: '\n'),
              tok('sine', 'green'),
              const TextSpan(text: '(mtof(A1)) * ad('),
              tok('step', 'blue'),
              const TextSpan(text: ' % 4 == 0)'),
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

/// The roll's sizes, look and touch choices; sliders show the value while dragging and save when let go.
List<Widget> _rollSettings(Settings settings) {
  final r = settings.roll;
  Widget slider(String label, IconData icon, double value, double min, double max, String Function(double) show,
      RollLook Function(double) set) {
    return ListTile(
      leading: Icon(icon, color: Neon.blue),
      title: Text('$label: ${show(value)}', style: Neon.code(size: 14)),
      subtitle: Slider(
        min: min,
        max: max,
        value: value.clamp(min, max),
        onChanged: (v) {
          settings.roll = set(v);
          settings.preview(null);
        },
        onChangeEnd: (v) => settings.update((s) => s.roll = set(v)),
      ),
    );
  }

  String px(double v) => '${v.round()} px';
  return [
    slider('Row height', Icons.height, r.rowHeight, 10, 40, px, (v) => r.copyWith(rowHeight: v.roundToDouble())),
    slider('Velocity lane', Icons.equalizer, r.velocityLane, 32, 160, px,
        (v) => r.copyWith(velocityLane: v.roundToDouble())),
    slider('Chance lane', Icons.casino_outlined, r.chanceLane, 24, 120, px,
        (v) => r.copyWith(chanceLane: v.roundToDouble())),
    slider('Grid lines', Icons.grid_4x4, r.gridStrength, 0.2, 2, (v) => '${(v * 100).round()}%',
        (v) => r.copyWith(gridStrength: (v * 10).round() / 10)),
    slider('Grab zone', Icons.pan_tool_alt_outlined, r.grab, 6, 40, px, (v) => r.copyWith(grab: v.roundToDouble())),
    slider('Hold for extras', Icons.touch_app_outlined, r.holdMs.toDouble(), 250, 1500, (v) => '${v.round()} ms',
        (v) => r.copyWith(holdMs: (v / 50).round() * 50)),
    ListTile(
      leading: Icon(Icons.piano, color: Neon.yellow),
      title: const Text('Key names'),
      subtitle: SegmentedButton<KeyLabels>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: KeyLabels.none, label: Text('None')),
          ButtonSegment(value: KeyLabels.octaves, label: Text('C')),
          ButtonSegment(value: KeyLabels.all, label: Text('All')),
        ],
        selected: {r.keyLabels},
        onSelectionChanged: (v) => settings.update((s) => s.roll = s.roll.copyWith(keyLabels: v.first)),
      ),
    ),
    ListTile(
      leading: Icon(Icons.swipe, color: Neon.green),
      title: const Text('Drag on empty grid (draw tool; a tap still draws)'),
      subtitle: SegmentedButton<EmptyDrag>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: EmptyDrag.scroll, label: Text('Scroll')),
          ButtonSegment(value: EmptyDrag.select, label: Text('Select')),
          ButtonSegment(value: EmptyDrag.draw, label: Text('Draw')),
        ],
        selected: {r.emptyDrag},
        onSelectionChanged: (v) => settings.update((s) => s.roll = s.roll.copyWith(emptyDrag: v.first)),
      ),
    ),
  ];
}

/// The code editor's key row, chips, buttons and Controls panel.
List<Widget> _editorSettings(BuildContext context, Settings settings) {
  final e = settings.editor;
  Widget toggle(String title, String? sub, IconData icon, bool value, EditorLook Function(bool) set) => SwitchListTile(
        secondary: Icon(icon, color: Neon.blue),
        title: Text(title),
        subtitle: sub == null ? null : Text(sub, style: TextStyle(color: Neon.dim)),
        value: value,
        onChanged: (v) => settings.update((s) => s.editor = set(v)),
      );
  return [
    ListTile(
      leading: Icon(Icons.keyboard_alt_outlined, color: Neon.yellow),
      title: const Text('Key row'),
      subtitle: Text(e.keyRow.map((k) => k.trim()).join('  '),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: Neon.code(size: 12, color: Neon.dim)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Neon.panel,
        isScrollControlled: true,
        builder: (_) => _KeyRowEditor(settings: settings),
      ),
    ),
    toggle('Completion chips', 'Function names above the keyboard as you type', Icons.auto_awesome, e.chips,
        (v) => e.copyWith(chips: v)),
    if (e.chips)
      ListTile(
        leading: Icon(Icons.text_fields, color: Neon.blue),
        title: Text('After ${e.chipLetters} letter${e.chipLetters == 1 ? '' : 's'}, up to ${e.chipCount} chips',
            style: Neon.code(size: 14)),
        subtitle: Row(children: [
          Expanded(
            child: Slider(
              min: 1,
              max: 4,
              divisions: 3,
              value: e.chipLetters.toDouble(),
              onChanged: (v) => settings.update((s) => s.editor = s.editor.copyWith(chipLetters: v.round())),
            ),
          ),
          Expanded(
            child: Slider(
              min: 3,
              max: 16,
              divisions: 13,
              value: e.chipCount.toDouble(),
              onChanged: (v) => settings.update((s) => s.editor = s.editor.copyWith(chipCount: v.round())),
            ),
          ),
        ]),
      ),
    toggle('Library button', 'F1 still opens it', Icons.menu_book, e.libraryButton, (v) => e.copyWith(libraryButton: v)),
    toggle('Solo preview button', 'Also in the module\'s ⋮ menu when hidden', Icons.hearing, e.soloButton,
        (v) => e.copyWith(soloButton: v)),
    toggle('Scope', 'Light mode hides it too', Icons.show_chart, e.scope, (v) => e.copyWith(scope: v)),
    toggle('Run bar on top', 'The key row and Run above the code instead of by the keyboard', Icons.vertical_align_top,
        e.barOnTop, (v) => e.copyWith(barOnTop: v)),
    toggle('Compact controls', 'Denser slider rows; tap a header to fold its group', Icons.density_small,
        e.compactControls, (v) => e.copyWith(compactControls: v)),
  ];
}

/// Edits the symbol key row: add keys, drag to reorder, remove, or go back to the default.
class _KeyRowEditor extends StatefulWidget {
  const _KeyRowEditor({required this.settings});
  final Settings settings;

  @override
  State<_KeyRowEditor> createState() => _KeyRowEditorState();
}

class _KeyRowEditorState extends State<_KeyRowEditor> {
  late List<String> _keys = List.of(widget.settings.editor.keyRow);
  // A stable id per row, so dragging keeps each row's widget (two keys may be the same text).
  late List<int> _ids = List.generate(_keys.length, (i) => i);
  late int _nextId = _keys.length;
  final _add = TextEditingController();

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  void _save() => widget.settings.update((s) => s.editor = s.editor.copyWith(keyRow: _keys));

  void _addKey() {
    // A trailing space is kept, so a key like "let " types the space too.
    final k = _add.text;
    if (k.trim().isEmpty || _keys.length >= 64) return; // the row holds at most 64 keys
    setState(() {
      _keys.add(k);
      _ids.add(_nextId++);
    });
    _add.clear();
    _save();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(children: [
                  const Expanded(child: Text('Key row', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _keys = List.of(EditorLook.defaultKeyRow);
                        _ids = List.generate(_keys.length, (i) => _nextId++);
                      });
                      _save();
                    },
                    child: const Text('Default'),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _add,
                      maxLength: 16,
                      style: Neon.code(size: 15),
                      decoration: const InputDecoration(hintText: 'New key, e.g. sine( or "let "'),
                      onSubmitted: (_) => _addKey(),
                    ),
                  ),
                  IconButton(tooltip: 'Add', onPressed: _addKey, icon: const Icon(Icons.add)),
                ]),
              ),
              Expanded(
                child: ReorderableListView(
                  onReorderItem: (from, to) {
                    setState(() {
                      _keys.insert(to, _keys.removeAt(from));
                      _ids.insert(to, _ids.removeAt(from));
                    });
                    _save();
                  },
                  children: [
                    for (var i = 0; i < _keys.length; i++)
                      ListTile(
                        key: ValueKey(_ids[i]),
                        title: Text(_keys[i].endsWith(' ') ? '${_keys[i].trim()} ␣' : _keys[i], style: Neon.code(size: 15)),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() {
                              _keys.removeAt(i);
                              _ids.removeAt(i);
                            });
                            _save();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ]),
          ),
        ),
      );
}
