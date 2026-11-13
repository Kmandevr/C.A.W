// Routes hardware keys through the action system (keymap, Vim modes, counts, `:` commands, macros) and shows its badge.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../actions/hints.dart';
import '../actions/key_event.dart';
import '../actions/keymap.dart';
import '../actions/keys.dart';
import '../actions/macro.dart';
import '../actions/vim.dart';
import '../model/app_state.dart';
import '../model/automation_writer.dart';
import '../model/live_midi.dart';
import '../model/settings.dart';
import 'glass.dart';
import 'keyboard/key_area.dart';
import 'key_bindings.dart';
import 'panel_motion.dart';
import 'pointer_input.dart';
import 'theme.dart';
import 'volume_fader.dart';
import 'widgets.dart' show confirmTrackDelete;
import 'touch_quick_actions.dart';

/// Whether a focused text editor, rather than the global action router, should receive this key.
bool shouldDeferTextEditingKey({
  required bool editingText,
  required bool commandLineOpen,
  required Area area,
  required VimMode mode,
  required KeyChord chord,
}) {
  if (!editingText || commandLineOpen) return false;

  // Text editing/navigation keys belong to EditableText even in code-editor Vim normal mode.
  const textEditingKeys = {'Backspace', 'Delete', 'Left', 'Right', 'Up', 'Down', 'Home', 'End', 'Enter', 'Tab'};
  if (chord.plain && chord.key != 'Esc' &&
      (area != Area.code || mode == VimMode.insert || textEditingKeys.contains(chord.key))) {
    return true;
  }
  // Standard text-field shortcuts belong to EditableText in every area, including the code editor.
  return chord.ctrl && !chord.alt && const {'Z', 'Y', 'A', 'C', 'V', 'X'}.contains(chord.key);
}

/// Runs one action for a screen or editor; returns false when it doesn't do that action.
typedef ActionTarget = bool Function(String id, int count, String? arg);

class KeyRouter extends StatefulWidget {
  const KeyRouter(
      {super.key, required this.state, required this.screenArea, required this.onView, this.onExport, required this.child});
  final AppState state;

  /// The area of the screen showing (Build, Arrange) when no editor inside it has focus.
  final Area screenArea;

  /// Shows a section: 0 Build, 1 Arrange, 2 Files.
  final ValueChanged<int> onView;

  /// Opens the Export page (the project menu's Export…); null leaves `view.exporter` unhandled.
  final VoidCallback? onExport;
  final Widget child;

  static KeyRouterState? of(BuildContext context) => context.findAncestorStateOfType<KeyRouterState>();

  @override
  State<KeyRouter> createState() => KeyRouterState();
}

class KeyRouterState extends State<KeyRouter> implements KeyAreaHost {
  /// The router in force, for the app-level keyboard layer (pushed pages, menus, the focus ring and hint strip).
  static final ValueNotifier<KeyRouterState?> active = ValueNotifier(null);

  final ActionRegistry registry = ActionRegistry.standard();

  /// Ticks when what the hint strip shows may have changed (keys rebound, a setting).
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// The router's own focus node: the home screen's keys pass through it.
  final FocusNode rootNode = FocusNode(debugLabel: 'key-router');
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
  final TextEditingController _commandController = TextEditingController();

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    vim = VimController(registry: registry, keymap: Keymap.defaults(registry), handler: _handle);
    vim.onMacroRecorded = (_) => _saveKeymap();
    vim.addListener(_changed);
    _loadKeymap();
    KeyAreaHost.current = this;
    active.value = this;
    // A desktop has a keyboard: the hint strip's default is on there from the start.
    if (const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(defaultTargetPlatform)) {
      KeyAreaHost.keyboardSeen.value = true;
    }
  }

  @override
  void dispose() {
    vim.removeListener(_changed);
    if (KeyAreaHost.current == this) KeyAreaHost.current = null;
    if (active.value == this) active.value = null;
    rootNode.dispose();
    revision.dispose();
    _toastTimer?.cancel();
    _prefixTimer?.cancel();
    _commandController.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
    revision.value++;
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
      revision.value++;
    } catch (_) {
      // A damaged keymap file falls back to the default keys.
    }
  }

  Future<void> _saveKeymap() async {
    final f = _keymapFile;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      // Written whole to a temp file, then renamed over keys.txt, so a crash never leaves it half written.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(vim.keymap.serialize(base: _defaults), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      _say('Could not save the keys', error: true);
    }
  }

  /// Runs an action or macro from a toolbar button and shows its toast, like a key would.
  void runRef(ActionRef ref) => _show(vim.run(ref));

  /// The shipped keymap, for "reset to default".
  Keymap get defaults => _defaults;

  /// Saves the keymap (keys, toolbars, macros) to keys.txt after a change made outside the key router.
  Future<void> saveKeymap() => _saveKeymap();

  /// An editor or screen offers its actions while [focus] has focus (or always, for a screen's own area); a
  /// [KeyArea] offers its context's actions while the keyboard focus is inside it.
  @override
  void register(Area area, FocusNode focus, ActionTarget run) {
    unregister(area, focus);
    (_targets[area] ??= []).add((focus: focus, run: run));
  }

  @override
  void unregister(Area area, FocusNode focus) => _targets[area]?.removeWhere((t) => t.focus == focus);

  /// The targets that may run [area]'s actions: the focused ones (innermost first), then for a screen's own area
  /// the newest of the rest; a keyboard-focus context's unfocused areas only when none is focused (a `:` command).
  Iterable<ActionTarget> _targetsFor(Area area) sync* {
    final list = _targets[area];
    if (list == null || list.isEmpty) return;
    final focused = list.where((t) => t.focus.hasFocus).toList()..sort((a, b) => focusDepth(b.focus).compareTo(focusDepth(a.focus)));
    for (final t in focused) {
      yield t.run;
    }
    if (area.navigates && focused.isNotEmpty) return;
    for (final t in list.reversed) {
      if (!t.focus.hasFocus) yield t.run;
    }
  }

  /// Whether the keyboard focus is in the home screen under this router (not a pushed page, menu or sheet).
  bool get ownsFocus {
    final p = FocusManager.instance.primaryFocus;
    if (p == null || p == rootNode) return true;
    for (var n = p.parent; n != null; n = n.parent) {
      if (n == rootNode) return true;
    }
    return false;
  }

  /// The key context: the innermost focused editor or area, else the screen's area; on a pushed page outside every
  /// area, [Area.page].
  Area get _area {
    Area? best;
    var depth = -1;
    _targets.forEach((area, list) {
      if (area == Area.code && !s.settings.vimCode) return;
      for (final t in list) {
        if (!t.focus.hasFocus) continue;
        final d = focusDepth(t.focus);
        // The Builder and the code editor share a node: the code editor's Vim mode wins there.
        if (d > depth || (d == depth && area == Area.code)) {
          depth = d;
          best = area;
        }
      }
    });
    if (best != null) return best!;
    return ownsFocus ? widget.screenArea : Area.page;
  }

  /// The key context the hint strip shows.
  Area get contextArea => _area;

  /// The hint strip's entries for [area], from the keymap in force.
  List<KeyHint> hintsFor(Area area) => contextHints(registry, vim.keymap, area, vimKeys: s.settings.vimKeys);

  /// Whether the hint strip shows (Settings › Keys; by default once a keyboard is in use).
  bool get hintsOn => KeyAreaHost.hintsOn(s.settings.keyHints);

  /// The keymap in force.
  Keymap get keymap => vim.keymap;

  /// Whether Vim keys (H J K L as arrows) are on.
  bool get vimKeys => s.settings.vimKeys;

  /// One key press. [area] is given by an editor that asks first (the piano roll); otherwise the focus decides.
  KeyEventResult handle(KeyEvent e, {Area? area}) {
    // Holding Space (to pan with a mouse) must not play and pause over and over.
    if (e is KeyRepeatEvent && e.logicalKey == LogicalKeyboardKey.space && !focusIsInTextField()) {
      return KeyEventResult.handled;
    }
    final chord = keyChordFromEvent(e, metaAsCtrl: defaultTargetPlatform == TargetPlatform.macOS);
    if (chord == null) return KeyEventResult.ignored;
    return _handleChord(chord, area: area);
  }

  KeyEventResult _handleChord(KeyChord chord, {Area? area}) {
    final a = area ?? _area;
    if (shouldDeferTextEditingKey(
      editingText: focusIsInTextField(),
      commandLineOpen: vim.commandLineOpen,
      area: a,
      mode: vim.mode,
      chord: chord,
    )) {
      return KeyEventResult.ignored;
    }
    if (!_keyboard) KeyAreaHost.keyboardSeen.value = true;
    // Vim keys: H J K L are the arrows in a keyboard-focus context that doesn't bind the letter itself.
    if (s.settings.vimKeys && a.navigates && vim.pendingKeys.isEmpty && !vim.commandLineOpen) {
      final arrow = vimArrowFor(chord);
      if (arrow != null && vim.keymap.lookup(a, KeySeq.one(chord)) == null) chord = arrow;
    }
    // Enter, Esc and Tab that have nothing to do here go on to the focused widget (a button's press, a page's close).
    if (vim.pendingKeys.isEmpty && !vim.commandLineOpen && vim.mode == VimMode.normal) {
      final ref = vim.keymap.lookup(a, KeySeq.one(chord));
      if (ref != null && !ref.isMacro && !_focusMoveApplies(ref.id)) return KeyEventResult.ignored;
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
    if (!r.handled && a == Area.code && vim.mode != VimMode.insert && !chord.ctrl && !chord.alt && !chord.meta) {
      return KeyEventResult.handled;
    }
    return r.handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _show(KeyResult r) {
    setState(() => _hints = r.hints);
    if (r.toast != null) _say(r.toast!, error: r.error);
  }

  /// Shows [text] in the key badge's toast (a screen's action that did nothing says why).
  void toast(String text) => _say(text, error: true);

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
    // An editor or screen that has the action runs it: the focused editor first, then the screen showing (unless
    // the focus is on a page in front of it).
    final areas = {_area, ?def?.area, if (ownsFocus) widget.screenArea};
    for (final area in areas) {
      for (final run in _targetsFor(area)) {
        if (run(id, count, arg)) return null;
      }
    }
    if (_global(id, count, arg)) return null;
    _say('${def?.name ?? id}: not available here', error: true);
  }

  bool _global(String id, int count, String? arg) {
    final p = s.project;
    void bpm(double d) => s.editProject((p) => p.bpm = (p.bpm + d * count).clamp(20, 400).toDouble());
    void master(double d) => s.editProject((p) => p.master = (p.master + d * count).clamp(0.0, VolumeTaper.maxGain).toDouble());
    final layers = p.layers;
    final layer = layers.isEmpty ? null : layers[_layer.clamp(0, layers.length - 1)];
    switch (id) {
      case 'transport.playstop':
        s.togglePlay();
        // Space+drag pans with a mouse: a pan started while this Space is held takes the toggle back.
        if (SpacePan.held) SpacePan.armUndo(s.togglePlay);
      case 'transport.stop':
        s.stopPlayback();
      case 'transport.tap':
        s.tapTempo();
      case 'transport.record':
        LiveMidi.current?.toggleRecord();
      case 'transport.automate':
        final w = AutomationWriter.current;
        w?.setArmed(!w.armed);
      case 'view.liveKeys':
        final m = LiveMidi.current;
        if (m != null) m.keysOpen = !m.keysOpen;
      case 'edit.undo':
        if (!s.undo()) _say('Nothing to undo');
      case 'edit.redo':
        if (!s.redo()) _say('Nothing to redo');
      case 'project.save':
        s.flush();
      case 'view.actions':
        showActionList(context);
      case 'view.keys':
        showKeyBindings(context);
      case 'focus.next':
        _cycleAreas(1);
      case 'focus.prev':
        _cycleAreas(-1);
      case 'focus.in':
        if (!(KeyArea.ofNode(FocusManager.instance.primaryFocus)?.enter() ?? false)) return false;
      case 'focus.out':
        if (!_focusOut()) return false;
      case 'transport.toStart':
        s.backToStart();
      case 'transport.toProjectStart':
        s.backToStart(projectStart: true);
      case 'page.up' || 'page.down' || 'page.left' || 'page.right':
        final scope = FocusManager.instance.primaryFocus?.enclosingScope;
        if (scope == null) return false;
        final move = KeyMove.values.byName(id.substring(5));
        for (var i = 0; i < count; i++) {
          if (!moveFocusIn(scope, move)) return i > 0;
        }
      case 'page.activate':
        if (!activateFocused()) return false;
      case 'view.builder':
        widget.onView(0);
      case 'view.arranger':
        widget.onView(1);
      case 'view.exporter':
        if (widget.onExport == null) return false;
        widget.onExport!();
      case 'view.files':
        widget.onView(2);
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
        // 1 dB a press (from silence, up from -60 dB), at most 0 dB.
        final db = (layer.volume <= 0 ? -61.0 : VolumeTaper.db(layer.volume)) + (id.endsWith('up') ? 1.0 : -1.0) * count;
        s.mixLayer(layer, volume: db < -60 ? 0 : math.min(VolumeTaper.maxGain, math.pow(10, db / 20).toDouble()));
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
        if (s.settings.confirmDelete) {
          unawaited(confirmTrackDelete(context, s, layer).then((ok) { if (ok) s.removeLayer(layer); }));
        } else {
          s.removeLayer(layer);
        }
      case 'arranger.layer.moveUp' || 'arranger.layer.moveDown':
        if (layer == null) return false;
        final up = id.endsWith('Up');
        final to = (_layer + (up ? -1 : 1)).clamp(0, layers.length - 1);
        // moveLayer takes the index to insert before, so a move down inserts after the next track.
        if (to != _layer) s.moveLayer(_layer, up ? to : to + 1);
        _layer = to;
      default:
        return false;
    }
    return true;
  }

  // ---------- keyboard focus ----------

  /// Whether a focus move ([ActionRef] [id]) would do something here; when it wouldn't, its key goes on to the
  /// focused widget (Enter presses a button, Esc closes a page).
  bool _focusMoveApplies(String id) {
    final p = FocusManager.instance.primaryFocus;
    switch (id) {
      case 'focus.in':
        final a = KeyArea.ofNode(p);
        return a != null && keyItems(a.node).isNotEmpty;
      case 'focus.out':
        final a = KeyArea.around(p);
        if (a == null) return false;
        if (p != a.node) return true;
        return a.parent != null || _sectionBar(except: a) != null;
      default:
        return true;
    }
  }

  /// The section bar or rail, when it is on screen (and isn't [except]).
  FocusNode? _sectionBar({KeyAreaState? except}) {
    for (final t in _targets[Area.sections] ?? const <({FocusNode focus, ActionTarget run})>[]) {
      if (t.focus != except?.node && isShownNode(t.focus)) return t.focus;
    }
    return null;
  }

  /// Esc: from a control to its area, from an area to the area around it or the section bar.
  bool _focusOut() {
    final p = FocusManager.instance.primaryFocus;
    final a = KeyArea.around(p);
    if (a == null) return false;
    if (p != a.node) {
      a.node.requestFocus();
      return true;
    }
    final up = a.parent?.node ?? _sectionBar(except: a);
    if (up == null) return false;
    up.requestFocus();
    return true;
  }

  /// The areas on screen in front (this router's screens, or the page in front), in reading order.
  List<FocusNode> visibleAreas() {
    final nodes = <FocusNode>{};
    _targets.forEach((area, list) {
      for (final t in list) {
        if (isShownNode(t.focus)) nodes.add(t.focus);
      }
    });
    return readingOrder(nodes.toList());
  }

  /// Focuses the first area on screen in reading order (other than [except]): Enter on the section bar.
  void focusFirstArea({FocusNode? except}) {
    final first = visibleAreas().where((n) => n != except).firstOrNull;
    if (first != null) focusAndReveal(first);
  }

  /// Tab and Shift+Tab: the next or previous area of the screen in front, round and round.
  void _cycleAreas(int d) {
    final areas = visibleAreas();
    final p = FocusManager.instance.primaryFocus;
    if (areas.isEmpty) {
      d > 0 ? p?.nextFocus() : p?.previousFocus();
      return;
    }
    var i = -1;
    // The area holding the focus: the innermost listed node it is in.
    for (var n = p; n != null && i < 0; n = n.parent) {
      i = areas.indexOf(n);
    }
    final next = i < 0 ? (d > 0 ? 0 : areas.length - 1) : (i + d) % areas.length;
    focusAndReveal(areas[next]);
  }

  // ---------- UI ----------

  Future<void> showActionList(BuildContext context) async {
    final ref = await showDialog<ActionRef>(
      context: context, animationStyle: dialogAnimation(context),
      builder: (_) => _ActionList(registry: registry, keymap: vim.keymap, area: _area),
    );
    if (ref != null) _show(vim.run(ref)); // "Edit keys" returns view.keys, which opens the editor
  }

  /// The key bindings editor (Settings, the action list, or the "Key bindings" action). Each change saves keys.txt.
  Future<void> showKeyBindings(BuildContext context) => Navigator.of(context).push(panelRoute<void>(context,
        (_) => GlassPage(child: KeyBindingsPage(
          registry: registry,
          keymap: () => vim.keymap,
          defaults: _defaults,
          onSave: () async {
            _changed();
            await saveKeymap();
          },
        )),
      ));

  @override
  Widget build(BuildContext context) {
    final touchArea = _area;
    final isPhone = MediaQuery.sizeOf(context).shortestSide < 600;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final quickActionsBottom = viewInsets.bottom > 0 ? viewInsets.bottom + 8 : safeBottom + 8;
    final badge = <Widget>[
      if (vim.recording) Text('● @${vim.recordingSlot}', style: const TextStyle(color: Neon.pink)),
      if (vim.mode != VimMode.normal) Text(vim.mode.name.toUpperCase(), style: const TextStyle(color: Neon.yellow)),
      if (vim.pendingKeys.isNotEmpty) Text(vim.pendingKeys, style: const TextStyle(color: Neon.blue)),
    ];
    return Focus(
      focusNode: rootNode,
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
        if (isPhone && touchArea != Area.pattern && s.settings.quickActions)
          Positioned(
            left: 8,
            right: 8,
            bottom: quickActionsBottom,
            child: TouchQuickActions(
              area: touchArea,
              keymap: vim.keymap,
              defaults: _defaults,
              registry: registry,
              onRun: runRef,
              onSave: saveKeymap,
            ),
          ),
        if (vim.commandLineOpen)
          Positioned(
            left: 8,
            right: 8,
            bottom: viewInsets.bottom + 68,
            child: Material(
              color: Neon.panelHi,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Wrap(spacing: 12, children: [
                    for (final c in vim.completions.take(8))
                      ActionChip(
                        label: Text('${c.keys} · ${c.label}', style: Neon.code(size: 12)),
                        onPressed: () {
                          _commandController.text = c.keys;
                          _commandController.selection = TextSelection.collapsed(offset: c.keys.length);
                          vim.setCommandText(c.keys);
                          setState(() {});
                        },
                      ),
                  ]),
                  TextField(
                    autofocus: true,
                    key: const ValueKey('vim-command-line'),
                    controller: _commandController,
                    onChanged: vim.setCommandText,
                    onSubmitted: (_) {
                      _show(vim.submitCommand());
                      _commandController.clear();
                      setState(() {});
                    },
                    decoration: InputDecoration(
                      isDense: true,
                      prefixText: '${vim.prompt ?? ':'} ',
                      hintText: 'Type a command and press Enter',
                    ),
                  ),
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
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.keyboard),
          label: const Text('Edit keys'),
          onPressed: () => Navigator.pop(context, const ActionRef.action('view.keys')),
        ),
      ],
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
