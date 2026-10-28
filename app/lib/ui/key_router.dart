// Routes hardware keys through the action system (keymap, Vim modes, counts, `:` commands, macros) and shows its badge.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../actions/actions.dart';
import '../actions/key_event.dart';
import '../actions/keymap.dart';
import '../actions/macro.dart';
import '../actions/vim.dart';
import '../model/app_state.dart';
import '../model/settings.dart';
import 'theme.dart';

/// Runs one action for a screen or editor; returns false when it doesn't do that action.
typedef ActionTarget = bool Function(String id, int count, String? arg);

class KeyRouter extends StatefulWidget {
  const KeyRouter(
      {super.key, required this.state, required this.screenArea, required this.onView, required this.child});
  final AppState state;

  /// The area of the screen showing (Builder, Arranger, Exporter) when no editor inside it has focus.
  final Area screenArea;
  final ValueChanged<int> onView;
  final Widget child;

  static KeyRouterState? of(BuildContext context) => context.findAncestorStateOfType<KeyRouterState>();

  @override
  State<KeyRouter> createState() => KeyRouterState();
}

class KeyRouterState extends State<KeyRouter> {
  final ActionRegistry registry = ActionRegistry.standard();
  late final Keymap _defaults = Keymap.defaults(registry);
  late final VimController vim;
  // Several editors can offer one area (the Builder's roll and a full-screen one): the focused one wins, else the newest.
  final Map<Area, List<({FocusNode focus, ActionTarget run})>> _targets = {};
  bool _keyboard = false; // the badge shows once a hardware key was pressed
  String? _toast;
  bool _toastError = false;
  List<KeyHint> _hints = const [];
  Timer? _toastTimer, _prefixTimer;
  int _layer = 0; // the Arranger's keyboard-selected layer

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    vim = VimController(registry: registry, keymap: Keymap.defaults(registry), handler: _handle);
    vim.onMacroRecorded = (_) => _saveKeymap();
    vim.addListener(_changed);
    _loadKeymap();
  }

  @override
  void dispose() {
    vim.removeListener(_changed);
    _toastTimer?.cancel();
    _prefixTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  File? get _keymapFile {
    final d = s.settings.dir;
    return d == null ? null : File('${d.path}${Platform.pathSeparator}keys.txt');
  }

  Future<void> _loadKeymap() async {
    try {
      final f = _keymapFile;
      if (f == null || !await f.exists()) return;
      final mine = Keymap.parse(await f.readAsString(), registry: registry);
      vim.keymap = mine.mergedOver(_defaults);
    } catch (_) {
      // A damaged keymap file falls back to the default keys.
    }
  }

  Future<void> _saveKeymap() async {
    final f = _keymapFile;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(vim.keymap.serialize(base: _defaults), flush: true);
    } catch (_) {
      _say('Could not save the macro', error: true);
    }
  }

  /// An editor or screen offers its actions while [focus] has focus (or always, for a screen's own area).
  void register(Area area, FocusNode focus, ActionTarget run) {
    unregister(area, focus);
    (_targets[area] ??= []).add((focus: focus, run: run));
  }

  void unregister(Area area, FocusNode focus) => _targets[area]?.removeWhere((t) => t.focus == focus);

  ({FocusNode focus, ActionTarget run})? _target(Area area) {
    final list = _targets[area];
    if (list == null || list.isEmpty) return null;
    return list.where((t) => t.focus.hasFocus).firstOrNull ?? list.last;
  }

  Area get _area {
    if (_targets[Area.pattern]?.any((t) => t.focus.hasFocus) ?? false) return Area.pattern;
    if (s.settings.vimCode && (_targets[Area.code]?.any((t) => t.focus.hasFocus) ?? false)) return Area.code;
    return widget.screenArea;
  }

  bool _editingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  static const _textKeys = {'Z', 'Y', 'A', 'C', 'V', 'X'};

  /// One key press. [area] is given by an editor that asks first (the piano roll); otherwise the focus decides.
  KeyEventResult handle(KeyEvent e, {Area? area}) {
    final chord = keyChordFromEvent(e, metaAsCtrl: defaultTargetPlatform == TargetPlatform.macOS);
    if (chord == null) return KeyEventResult.ignored;
    final a = area ?? _area;
    if (!vim.commandLineOpen && a != Area.code && _editingText()) {
      // A plain text field keeps typing and its own Ctrl shortcuts; only other shortcuts reach the actions.
      if (chord.plain && chord.key != 'Esc') return KeyEventResult.ignored;
      if (chord.ctrl && !chord.alt && _textKeys.contains(chord.key)) return KeyEventResult.ignored;
    }
    _keyboard = true;
    if (vim.area != a) vim.area = a;
    final r = vim.handleKey(chord);
    _show(r);
    _prefixTimer?.cancel();
    if (vim.pendingKeys.isNotEmpty) {
      // Vim's timeout: a prefix left alone for a second runs its own binding if it has one.
      _prefixTimer = Timer(const Duration(seconds: 1), () => _show(vim.flush()));
    }
    // Vim's normal mode in the code editor: unbound plain keys do nothing instead of typing.
    if (!r.handled && a == Area.code && vim.mode != VimMode.insert && !chord.ctrl && !chord.alt && !chord.meta) {
      return KeyEventResult.handled;
    }
    return r.handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _show(KeyResult r) {
    setState(() => _hints = r.hints);
    if (r.toast != null) _say(r.toast!, error: r.error);
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    _toastTimer?.cancel();
    setState(() {
      _toast = text;
      _toastError = error;
    });
    _toastTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // ---------- actions ----------

  FutureOr<void> _handle(String id, {int count = 1, String? arg}) {
    final def = registry[id];
    // An editor or screen that has the action runs it: the focused editor first, then the screen showing.
    for (final area in [_area, def?.area, widget.screenArea]) {
      final t = area == null ? null : _target(area);
      if (t != null && t.run(id, count, arg)) return null;
    }
    if (_global(id, count, arg)) return null;
    _say('${def?.name ?? id}: not available here', error: true);
  }

  bool _global(String id, int count, String? arg) {
    final p = s.project;
    void bpm(double d) => s.editProject((p) => p.bpm = (p.bpm + d * count).clamp(20, 400).toDouble());
    void master(double d) => s.editProject((p) => p.master = (p.master + d * count).clamp(0, 1).toDouble());
    final layers = p.layers;
    final layer = layers.isEmpty ? null : layers[_layer.clamp(0, layers.length - 1)];
    switch (id) {
      case 'transport.playstop':
        s.togglePlay();
      case 'project.save':
        s.flush();
      case 'view.actions':
        showActionList(context);
      case 'view.builder' || 'view.arranger' || 'view.exporter':
        widget.onView(const ['view.builder', 'view.arranger', 'view.exporter'].indexOf(id));
      case 'transport.tempoUp':
        bpm(1);
      case 'transport.tempoDown':
        bpm(-1);
      case 'transport.tempoUpFine':
        bpm(0.1);
      case 'transport.tempoDownFine':
        bpm(-0.1);
      case 'transport.bpm':
        final v = double.tryParse(arg ?? '');
        if (v == null) return false;
        s.editProject((p) => p.bpm = v.clamp(20, 400));
      case 'mixer.masterUp':
        master(0.05);
      case 'mixer.masterDown':
        master(-0.05);
      case 'engine.unmuteAll':
        s.clearOverload();
      case 'project.new':
        s.newProject();
      case 'project.duplicate':
        s.duplicateProject();
      case 'builder.live.toggle':
        s.settings.update((x) => x.liveUpdate = !x.liveUpdate);
        _say('Auto-update ${s.settings.liveUpdate ? 'on' : 'off'}');
      case 'builder.live.delay':
        final v = int.tryParse(arg ?? '');
        if (v == null) return false;
        s.settings.update((x) => x.liveDelayMs = v.clamp(100, 2000));
      case 'builder.swapTiming':
        s.settings.update((x) => x.swapTiming = SwapTiming.values[(x.swapTiming.index + 1) % SwapTiming.values.length]);
        _say('Swaps land: ${s.settings.swapTiming.name}');
      case 'arranger.layer.prev':
        _layer = (_layer - count).clamp(0, layers.isEmpty ? 0 : layers.length - 1);
        if (layer != null) _say(layers[_layer].name);
      case 'arranger.layer.next':
        _layer = (_layer + count).clamp(0, layers.isEmpty ? 0 : layers.length - 1);
        if (layer != null) _say(layers[_layer].name);
      case 'arranger.vol.up' || 'arranger.vol.down':
        if (layer == null) return false;
        final d = (id.endsWith('up') ? 0.05 : -0.05) * count;
        s.mixLayer(layer, volume: (layer.volume + d).clamp(0, 1).toDouble());
      case 'arranger.pan.left' || 'arranger.pan.right':
        if (layer == null) return false;
        final d = (id.endsWith('right') ? 0.1 : -0.1) * count;
        s.mixLayer(layer, pan: (layer.pan + d).clamp(-1, 1).toDouble());
      case 'arranger.layer.mute':
        if (layer == null) return false;
        s.mixLayer(layer, mute: !layer.mute);
      case 'arranger.layer.solo':
        if (layer == null) return false;
        s.mixLayer(layer, solo: !layer.solo);
      case 'arranger.layer.add':
        s.addLayer();
      case 'arranger.layer.delete':
        if (layer == null) return false;
        s.removeLayer(layer);
      case 'arranger.layer.moveUp' || 'arranger.layer.moveDown':
        if (layer == null) return false;
        final to = (_layer + (id.endsWith('Up') ? -1 : 1)).clamp(0, layers.length - 1);
        s.moveLayer(_layer, to);
        _layer = to;
      default:
        return false;
    }
    return true;
  }

  // ---------- UI ----------

  Future<void> showActionList(BuildContext context) async {
    final ref = await showDialog<ActionRef>(
      context: context,
      builder: (_) => _ActionList(registry: registry, keymap: vim.keymap, area: _area),
    );
    if (ref != null) _show(vim.run(ref));
  }

  @override
  Widget build(BuildContext context) {
    final badge = <Widget>[
      if (vim.recording) Text('● @${vim.recordingSlot}', style: const TextStyle(color: Neon.pink)),
      if (vim.mode != VimMode.normal) Text(vim.mode.name.toUpperCase(), style: const TextStyle(color: Neon.yellow)),
      if (vim.pendingKeys.isNotEmpty) Text(vim.pendingKeys, style: const TextStyle(color: Neon.blue)),
    ];
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => handle(e),
      child: Stack(children: [
        widget.child,
        if (_keyboard && (badge.isNotEmpty || _hints.isNotEmpty || _toast != null))
          Positioned(
            right: 12,
            bottom: 80,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Neon.panelHi.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _toastError ? Neon.pink : Neon.line),
                ),
                child: DefaultTextStyle(
                  style: Neon.code(size: 13),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                    for (final h in _hints.take(12)) Text('${h.keys}  ${h.label}'),
                    if (_toast != null) Text(_toast!, style: TextStyle(color: _toastError ? Neon.pink : Neon.text)),
                    if (badge.isNotEmpty)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final b in badge) Padding(padding: const EdgeInsets.only(left: 8), child: b),
                      ]),
                  ]),
                ),
              ),
            ),
          ),
        if (vim.commandLineOpen)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: Neon.panelHi,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Wrap(spacing: 12, children: [
                    for (final c in vim.completions.take(8))
                      Text('${c.keys} ${c.label}', style: Neon.code(size: 12, color: Neon.dim)),
                  ]),
                  Text('${vim.prompt}${vim.commandText}▏', style: Neon.code(size: 15)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Search every action, see its keys, and run it (the `?` key).
class _ActionList extends StatefulWidget {
  const _ActionList({required this.registry, required this.keymap, required this.area});
  final ActionRegistry registry;
  final Keymap keymap;
  final Area area;

  @override
  State<_ActionList> createState() => _ActionListState();
}

class _ActionListState extends State<_ActionList> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final found = widget.registry.search(_q).where((d) => !d.internal || d.id.startsWith('vim.')).toList();
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: TextField(
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Search actions'),
        onChanged: (v) => setState(() => _q = v),
        onSubmitted: (_) {
          if (found.isNotEmpty) Navigator.pop(context, ActionRef.action(found.first.id));
        },
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: ListView.builder(
          itemCount: found.length,
          itemBuilder: (context, i) {
            final d = found[i];
            final keys = widget.keymap.keysFor(d.area, ActionRef.action(d.id)).map((k) => k.format()).join(', ');
            return ListTile(
              dense: true,
              title: Text(d.name),
              subtitle: Text(d.area.label, style: const TextStyle(color: Neon.dim)),
              trailing: Text(keys, style: Neon.code(size: 12, color: Neon.yellow)),
              onTap: () => Navigator.pop(context, ActionRef.action(d.id)),
            );
          },
        ),
      ),
    );
  }
}
