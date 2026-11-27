// The pattern editor's toolbar: the keymap's actions as buttons, the snap menu, and the editor for the toolbar's own list.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../actions/keymap.dart';
import '../../actions/macro.dart';
import '../../model/settings.dart';
import '../key_router.dart';
import '../theme.dart';
import '../glass.dart';
import '../frame/frame_widgets.dart' show ScrollFade;
import '../haptics.dart';

/// Grid resolutions as fractions of a whole note (1 = a bar of 4/4), from 1 down to 1/128.
const rollResolutions = [1, 2, 4, 8, 16, 32, 64, 128];

/// Icons for actions that sit well on a toolbar; any other action shows its name.
const Map<String, IconData> _actionIcons = {
  'roll.tool.draw': Icons.edit,
  'roll.tool.select': Icons.highlight_alt,
  'roll.tool.erase': Icons.auto_fix_normal,
  'roll.tool.curve': Icons.gesture,
  'roll.tool.ratchet': Icons.view_week_outlined,
  'edit.undo': Icons.undo,
  'edit.redo': Icons.redo,
  'roll.grid.triplets': Icons.looks_3_outlined,
  'roll.grid.snap': Icons.grid_on,
  'roll.grid.adaptive': Icons.lock_outline,
  'roll.view.switch': Icons.apps,
  'roll.view.zoomIn': Icons.zoom_in,
  'roll.view.zoomOut': Icons.zoom_out,
  'roll.view.fit': Icons.fit_screen,
  'roll.view.velocityLane': Icons.equalizer,
  'roll.view.extrasLanes': Icons.casino_outlined,
  'roll.notes.delete': Icons.delete_outline,
  'roll.notes.extras': Icons.tune,
  'roll.edit.copy': Icons.content_copy,
  'roll.edit.paste': Icons.content_paste,
  'roll.edit.duplicate': Icons.copy_all,
  'roll.notes.quantize': Icons.straighten,
  'roll.gen.euclid': Icons.blur_circular,
  'roll.gen.random': Icons.shuffle,
  'roll.gen.arpeggiate': Icons.stairs_outlined,
  'roll.gen.humanize': Icons.waves,
  'roll.gen.chordStamp': Icons.library_music_outlined,
  'roll.gen.legato': Icons.linear_scale,
  'roll.gen.connect': Icons.timeline,
  'roll.gen.tremolo': Icons.graphic_eq,
  'roll.gen.vibrato': Icons.waves_outlined,
  'roll.notes.quantizeSheet': Icons.align_horizontal_left,
  'roll.step.toggle': Icons.piano,
  'roll.step.rest': Icons.space_bar,
  'roll.gen.reverse': Icons.swap_horiz,
  'roll.gen.invertPitch': Icons.swap_vert,
  'transport.playstop': Icons.play_arrow,
  'transport.stop': Icons.stop,
};

/// Actions the roll can't run yet; they stay in the keymap but don't show on its toolbar.
const Set<String> _notBuilt = {};

/// The roll's toolbar: the keymap's pattern toolbar (the user's own actions and macros, in their order), then the
/// full-screen switch and the ⋮ menu, which always stay.
class RollToolbar extends StatelessWidget {
  const RollToolbar({
    super.key,
    required this.items,
    required this.registry,
    required this.keymap,
    required this.isOn,
    required this.isEnabled,
    required this.selectedCount,
    required this.canPaste,
    required this.onCopy,
    required this.onPaste,
    required this.onRun,
    required this.snap,
    required this.onSnap,
    required this.fullScreen,
    required this.onFullScreen,
    required this.onMenu,
    required this.velLane,
    required this.extrasLane,
    required this.stepInput,
    required this.hearNotes,
    required this.canCustomise,
    required this.zoomBar,
    required this.onZoom,
  });
  final bool zoomBar;
  final VoidCallback onZoom;
  final List<ActionRef> items;
  final ActionRegistry registry;
  final Keymap? keymap;
  final bool Function(String id) isOn, isEnabled;
  final int selectedCount;
  final bool canPaste;
  final VoidCallback onCopy, onPaste;
  final ValueChanged<ActionRef> onRun;
  final bool fullScreen, velLane, extrasLane, canCustomise, hearNotes, stepInput;
  final VoidCallback onFullScreen;
  final ValueChanged<String> onMenu;
  final ({bool on, int res, bool triplet, bool fixed, ValueGrid value}) snap;
  final ValueChanged<String> onSnap;

  String _tip(ActionRef r) {
    final name = r.isMacro ? 'Macro: ${r.id}' : (registry[r.id]?.name ?? r.id);
    final keys = keymap?.keysFor(Area.pattern, r).map((k) => k.format()).join(', ') ?? '';
    return keys.isEmpty ? name : '$name ($keys)';
  }

  Widget _item(ActionRef r) {
    if (!r.isMacro && r.id == 'roll.grid.menu') return _SnapButton(snap: snap, onSnap: onSnap, tip: _tip(r));
    final icon = r.isMacro ? null : _actionIcons[r.id];
    final enabled = r.isMacro || isEnabled(r.id);
    if (icon != null) {
      return IconButton(
        tooltip: _tip(r),
        onPressed: enabled
            ? () {
                Haptics.tap();
                onRun(r);
              }
            : null,
        icon: Icon(icon, color: isOn(r.id) ? Neon.yellow : Neon.dim),
      );
    }
    final label = r.isMacro ? '▶ ${r.id}' : (registry[r.id]?.name ?? r.id);
    return Tooltip(
      message: _tip(r),
      child: TextButton(
        onPressed: enabled ? () => onRun(r) : null,
        child: Text(label, style: TextStyle(color: isOn(r.id) ? Neon.yellow : Neon.text)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The tools scroll with a fade where there are more; ⋯ (generators, lanes, MIDI import) stays pinned at the end so
    // it is never hidden past the edge, and on a phone the buttons are a little narrower so the snap fits too.
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 480;
      return IconButtonTheme(
        data: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: Size(narrow ? 40 : 48, 48),
            padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap)),
        child: SizedBox(
      height: 48,
      child: Row(children: [
        Expanded(child: ScrollFade(child: SingleChildScrollView(key: const ValueKey('roll-toolbar'), scrollDirection: Axis.horizontal,
          child: Row(children: [
        for (final r in items)
          if (r.isMacro || !_notBuilt.contains(r.id)) _item(r),
        if (selectedCount > 0) ...[
          TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.content_copy),
            label: Text('Copy ($selectedCount)'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
          TextButton.icon(
            onPressed: canPaste ? onPaste : null,
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ],
        IconButton(
          key: const ValueKey('roll-zoom'),
          tooltip: 'Zoom (or pinch; Ctrl + wheel)',
          onPressed: onZoom,
          icon: Icon(Icons.zoom_in, color: zoomBar ? Neon.blue : Neon.dim),
        ),
        IconButton(
          tooltip: 'Full screen',
          onPressed: onFullScreen,
          icon: Icon(fullScreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Neon.dim),
        ),
        ])))),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: Neon.dim),
          onSelected: onMenu,
          // Sections with headers, the most used first (owner, 2026-11-11).
          itemBuilder: (_) => [
            rollMenuHead('Notes'),
            const PopupMenuItem(value: 'note', child: Text('Note extras… (I, or hold a note)')),
            const PopupMenuItem(value: 'run:roll.notes.quantizeSheet', child: Text('Quantize…')),
            const PopupMenuItem(value: 'run:roll.gen.tremolo', child: Text('Tremolo…')),
            const PopupMenuItem(value: 'run:roll.gen.vibrato', child: Text('Vibrato…')),
            rollMenuHead('Tools'),
            CheckedPopupMenuItem(value: 'run:roll.tool.ratchet', checked: isOn('roll.tool.ratchet'),
                child: const Text('Ratchet brush')),
            CheckedPopupMenuItem(value: 'run:roll.step.toggle', checked: stepInput, child: const Text('Step input')),
            CheckedPopupMenuItem(value: 'hear', checked: hearNotes, child: const Text('Hear notes')),
            rollMenuHead('Lanes'),
            CheckedPopupMenuItem(value: 'vel', checked: velLane, child: const Text('Velocity lane (Alt+V)')),
            CheckedPopupMenuItem(value: 'extras', checked: extrasLane, child: const Text('Chance lane (Alt+X)')),
            rollMenuHead('Generate'),
            for (final id in const [
              'roll.gen.euclid',
              'roll.gen.random',
              'roll.gen.arpeggiate',
              'roll.gen.chordStamp',
              'roll.gen.humanize',
              'roll.gen.legato',
              'roll.gen.connect',
              'roll.gen.reverse',
              'roll.gen.invertPitch',
            ])
              PopupMenuItem(value: 'run:$id', child: Text(registry[id]?.name ?? id)),
            rollMenuHead('MIDI files'),
            const PopupMenuItem(value: 'import', child: Text('Import MIDI file…')),
            const PopupMenuItem(value: 'mid', child: Text('Export as MIDI (.mid)')),
            const PopupMenuItem(value: 'midi2', child: Text('Export as MIDI 2.0 clip (.midi2)')),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'toolbar', enabled: canCustomise, child: const Text('Customise toolbar…')),
          ],
        ),
      ]),
    ));
    });
  }
}

/// A section's header in a menu: small caps, not a choice.
PopupMenuItem<String> rollMenuHead(String text) => PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(text.toUpperCase(),
          style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: Neon.dim)),
    );

/// The snap magnet with its time grid: a tap turns snapping on or off for notes and every curve; the ▾ menu holds
/// the time grid, triplets, adaptive and the value grid, in a sheet (owner, 2026-11-04).
class _SnapButton extends StatelessWidget {
  const _SnapButton({required this.snap, required this.onSnap, required this.tip});
  final ({bool on, int res, bool triplet, bool fixed, ValueGrid value}) snap;
  final ValueChanged<String> onSnap;
  final String tip;

  /// A compact sheet of chip rows (a menu of every choice would be taller than a phone).
  void _open(BuildContext context) {
    var now = snap;
    showGlassSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      builder: (_) => StatefulBuilder(builder: (context, set) {
        void pick(String v) {
          onSnap(v);
          set(() => now = switch (v) {
                'toggle' => (on: !now.on, res: now.res, triplet: now.triplet, fixed: now.fixed, value: now.value),
                'triplets' => (on: now.on, res: now.res, triplet: !now.triplet, fixed: now.fixed, value: now.value),
                'adaptive' => (on: now.on, res: now.res, triplet: now.triplet, fixed: !now.fixed, value: now.value),
                _ when v.startsWith('res:') =>
                  (on: now.on, res: int.parse(v.substring(4)), triplet: now.triplet, fixed: now.fixed, value: now.value),
                _ => (on: now.on, res: now.res, triplet: now.triplet, fixed: now.fixed,
                    value: ValueGrid.values.byName(v.substring(6))),
              });
        }

        Widget title(String t) => Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(t, style: const TextStyle(color: Neon.dim, fontSize: 11, letterSpacing: 1.3)),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Snap (N)'),
                subtitle: const Text('Notes and every curve. Shift or a second finger skips it for one drag.'),
                value: now.on,
                onChanged: (_) => pick('toggle'),
              ),
              title('TIME GRID'),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final x in rollResolutions)
                  ChoiceChip(label: Text(x == 1 ? '1 bar' : '1/$x'), selected: now.res == x, onSelected: (_) => pick('res:$x')),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                FilterChip(label: const Text('Triplets'), selected: now.triplet, onSelected: (_) => pick('triplets')),
                FilterChip(label: const Text('Adaptive'), selected: !now.fixed, onSelected: (_) => pick('adaptive')),
              ]),
              title('VALUE GRID · volume, timbre, velocity, chance'),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final g in ValueGrid.values)
                  ChoiceChip(label: Text(g.label), selected: now.value == g, onSelected: (_) => pick('value:${g.name}')),
              ]),
            ]),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = snap.on ? Neon.yellow : Neon.dim;
    final grid = '${snap.res == 1 ? '1' : '1/${snap.res}'}${snap.triplet ? 'T' : ''}';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
        message: tip,
        child: InkWell(
          key: const ValueKey('roll-snap'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => onSnap('toggle'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                CustomPaint(size: const Size(18, 18), painter: _MagnetPainter(c)),
                const SizedBox(width: 4),
                Text(grid, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ),
      IconButton(
        key: const ValueKey('roll-snap-menu'),
        tooltip: 'Snap and grid settings',
        icon: const Icon(Icons.arrow_drop_down, color: Neon.dim),
        onPressed: () => _open(context),
      ),
    ]);
  }
}

/// A horseshoe magnet: Material has no magnet icon.
class _MagnetPainter extends CustomPainter {
  _MagnetPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, t = w * 0.26;
    final body = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = t;
    // An upside-down U: two legs down from an arch, with light tips.
    final r = (w - t) / 2;
    final path = Path()
      ..moveTo(t / 2, h)
      ..lineTo(t / 2, h * 0.45 + r * 0.2)
      ..arcToPoint(Offset(w - t / 2, h * 0.45 + r * 0.2), radius: Radius.circular(r))
      ..lineTo(w - t / 2, h);
    canvas.drawPath(path, body);
    final tip = Paint()..color = Neon.text;
    canvas.drawRect(Rect.fromLTWH(0, h - t * 0.9, t, t * 0.9), tip);
    canvas.drawRect(Rect.fromLTWH(w - t, h - t * 0.9, t, t * 0.9), tip);
  }

  @override
  bool shouldRepaint(_MagnetPainter o) => o.color != color;
}

/// Edits the roll's toolbar: reorder, remove, add any action or macro, or go back to the default.
class RollToolbarEditor extends StatefulWidget {
  const RollToolbarEditor({super.key, required this.router});
  final KeyRouterState router;

  @override
  State<RollToolbarEditor> createState() => _ToolbarEditorState();
}

class _ToolbarEditorState extends State<RollToolbarEditor> {
  Keymap get _k => widget.router.vim.keymap;
  late List<ActionRef> _items = List.of(_k.toolbars[Area.pattern] ?? const []);
  Future<void> _saving = Future.value();

  /// Saves one after another, so quick edits never write keys.txt at the same time.
  Future<void> _save() {
    _k.toolbars[Area.pattern] = List.of(_items);
    return _saving = _saving.then((_) => widget.router.saveKeymap());
  }

  Future<void> _add() async {
    final reg = widget.router.registry;
    final choices = [
      for (final d in reg.all)
        if ((d.area == Area.pattern || d.area == Area.global) && !d.internal && !d.takesArg) ActionRef.action(d.id),
      for (final m in _k.macros.names) ActionRef.macro(m),
    ].where((r) => !_items.contains(r)).toList();
    final picked = await showGlassSheet<ActionRef>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (ctx) => _ActionPicker(choices: choices, registry: reg),
    );
    if (picked == null) return;
    setState(() => _items.add(picked));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.router.registry;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(children: [
              const Expanded(child: Text('Roll toolbar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              TextButton(
                onPressed: () async {
                  setState(() => _items = List.of(widget.router.defaults.toolbars[Area.pattern] ?? const []));
                  await _save();
                },
                child: const Text('Default'),
              ),
              FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add')),
            ]),
          ),
          Expanded(
            child: ReorderableListView(
              onReorderItem: (from, to) {
                setState(() => _items.insert(to, _items.removeAt(from)));
                _save();
              },
              children: [
                for (final r in _items)
                  ListTile(
                    key: ValueKey(r),
                    leading: Icon(r.isMacro ? Icons.playlist_play : (_actionIcons[r.id] ?? Icons.label_outline),
                        color: Neon.blue),
                    title: Text(r.isMacro ? 'Macro: ${r.id}' : (reg[r.id]?.name ?? r.id)),
                    subtitle: _notBuilt.contains(r.id) ? const Text('Not built yet, hidden') : null,
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() => _items.remove(r));
                        _save();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// A searchable list of actions and macros to put on the toolbar.
class _ActionPicker extends StatefulWidget {
  const _ActionPicker({required this.choices, required this.registry});
  final List<ActionRef> choices;
  final ActionRegistry registry;

  @override
  State<_ActionPicker> createState() => _ActionPickerState();
}

class _ActionPickerState extends State<_ActionPicker> {
  String _q = '';

  String _name(ActionRef r) => r.isMacro ? 'Macro: ${r.id}' : (widget.registry[r.id]?.name ?? r.id);

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final found = widget.choices.where((r) => q.isEmpty || _name(r).toLowerCase().contains(q) || r.id.contains(q)).toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Find an action or macro'),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: ListView(children: [
                for (final r in found)
                  ListTile(
                    leading: Icon(r.isMacro ? Icons.playlist_play : (_actionIcons[r.id] ?? Icons.label_outline),
                        color: Neon.blue),
                    title: Text(_name(r)),
                    subtitle: r.isMacro ? null : Text(r.id, style: Neon.code(size: 11)),
                    onTap: () => Navigator.pop(context, r),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
