// Vim-style control: modes, counts, key sequences, the : command line, . repeat, and Alt+Q macro recording with @ replay.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'actions.dart';
import 'keymap.dart';
import 'keys.dart';
import 'macro.dart';

/// One entry in the key-hint popup or the command-line completion list.
class KeyHint {
  final String keys;
  final String label;
  const KeyHint(this.keys, this.label);

  @override
  String toString() => '$keys $label';
}

/// What a key press did. [handled] false means the key wasn't for us: the focused widget should get it.
class KeyResult {
  final bool handled;

  /// The keys that can follow after a prefix (empty when nothing is pending).
  final List<KeyHint> hints;

  /// A brief label for the toast ("Quantize", "Copy after ×3", or an error).
  final String? toast;

  /// True when [toast] reports a problem.
  final bool error;

  /// Completes when the actions started by this key have run; null if they finished synchronously.
  final Future<void>? done;

  const KeyResult({this.handled = true, this.hints = const [], this.toast, this.error = false, this.done});

  static const ignored = KeyResult(handled: false);
  static const ok = KeyResult();
}

enum _Await { none, recordSlot, replaySlot }

class _Change {
  final ActionRef ref;
  final int count;
  final String? arg;
  const _Change(this.ref, this.count, this.arg);
}

/// Turns key chords into actions for the current [area] and Vim [mode]. The app feeds it every key press that no
/// text field consumed, and listens for mode, recording and command-line changes (for the badge and the `:` bar).
///
/// Per key it does a couple of map lookups in the keymap's per-area index; completion is only computed while the
/// command line is open, and listeners are told only when the visible state changed.
class VimController extends ChangeNotifier {
  final ActionRegistry registry;
  Keymap _keymap;

  /// A project's own macros, looked up before the app's.
  MacroSet? projectMacros;

  /// Called after a recording is saved into [keymap]'s macros, so the app can save the keymap.
  void Function(Macro macro)? onMacroRecorded;

  late final MacroRunner runner;

  Area _area = Area.global;
  VimMode _mode = VimMode.normal;
  int? _count;
  final List<KeyChord> _prefix = [];
  _Await _await = _Await.none;
  int? _awaitCount;
  String? _prompt;
  ActionDef? _promptAction;
  int? _promptCount;
  String _text = '';
  String? _recording;
  List<MacroStep> _recorded = [];
  _Change? _lastChange;
  String? _lastReplay;
  String? _completionsFor;
  List<KeyHint> _completions = const [];

  VimController({
    required this.registry,
    required Keymap keymap,
    required ActionHandler handler,
    this.projectMacros,
    int maxSteps = 10000,
  }) : _keymap = keymap // ignore: prefer_initializing_formals
  {
    runner = MacroRunner(lookup: lookupMacro, handler: handler, registry: registry, maxSteps: maxSteps);
  }

  // ---- State for the UI ----

  Keymap get keymap => _keymap;
  set keymap(Keymap k) {
    _keymap = k;
    _clearPending();
  }

  Area get area => _area;

  /// Set by the app when focus moves to another screen or panel; clears any half-typed count or prefix.
  set area(Area a) => _change(() {
        _area = a;
        _clearPending();
      });

  VimMode get mode => _mode;
  set mode(VimMode m) => _change(() => _mode = m);

  /// Visual mode: movement should extend the selection.
  bool get selecting => _mode == VimMode.visual;

  bool get recording => _recording != null;
  String? get recordingSlot => _recording;

  /// Waiting for a slot name after Alt+Q or `@`.
  bool get awaitingSlot => _await != _Await.none;

  /// The open prompt's character (`:` or `/`), or null when no command line is showing.
  String? get prompt => _prompt;
  bool get commandLineOpen => _prompt != null;
  String get commandText => _text;

  /// The typed count and prefix keys, for the badge ("3", "C I").
  String get pendingKeys {
    if (_count == null && _prefix.isEmpty) return '';
    return [if (_count != null) '$_count', ..._prefix.map((c) => c.format())].join(' ');
  }

  /// Completion candidates for the first word of the `:` line; computed only while it is open.
  List<KeyHint> get completions {
    if (_prompt != ':') return const [];
    if (_completionsFor == _text) return _completions;
    _completionsFor = _text;
    final t = _text.trimLeft().toLowerCase();
    if (t.contains(' ')) return _completions = const [];
    final out = <KeyHint>[];
    final seen = <String>{};
    for (final d in registry.all) {
      if (d.internal) continue;
      final word = d.command ?? d.id;
      if (word.toLowerCase().startsWith(t) || d.name.toLowerCase().startsWith(t)) {
        if (seen.add(word)) out.add(KeyHint(word, d.argHint == null ? d.name : '${d.name} (${d.argHint})'));
      }
    }
    for (final m in [...?projectMacros?.all, ..._keymap.macros.all]) {
      if (m.name.toLowerCase().startsWith(t) && seen.add(m.name)) out.add(KeyHint(m.name, 'macro'));
    }
    out.sort((a, b) {
      final l = a.keys.length.compareTo(b.keys.length);
      return l != 0 ? l : a.keys.compareTo(b.keys);
    });
    return _completions = out.length > 30 ? out.sublist(0, 30) : out;
  }

  Macro? lookupMacro(String name) => projectMacros?[name] ?? _keymap.macros[name];

  String labelFor(ActionRef ref) => ref.isMacro ? ref.id : (registry[ref.id]?.name ?? ref.id);

  // ---- Keys ----

  static const _esc = KeyChord('Esc');

  /// Handles one key press.
  KeyResult handleKey(KeyChord key) {
    late KeyResult r;
    _change(() => r = _handle(key));
    return r;
  }

  /// Ends a pending prefix after a pause (Vim's timeout): runs the prefix's own binding if it has one.
  KeyResult flush() {
    late KeyResult r;
    _change(() {
      if (_prefix.isEmpty) {
        r = KeyResult.ok;
        _count = null;
        return;
      }
      final ref = _keymap.lookup(_area, KeySeq(_prefix));
      final count = _count;
      _clearPending();
      r = ref == null ? KeyResult.ok : _dispatch(ref, count);
    });
    return r;
  }

  /// Runs an action or macro from a toolbar button, menu entry or the action list, so `.` and recording see it.
  KeyResult run(ActionRef ref, {int? count, String? arg}) {
    late KeyResult r;
    _change(() => r = _dispatch(ref, count, arg: arg));
    return r;
  }

  KeyResult runAction(String id, {int? count, String? arg}) => run(ActionRef.action(id), count: count, arg: arg);

  KeyResult _handle(KeyChord key) {
    if (_prompt != null) return _promptKey(key);
    if (_await != _Await.none) return _slotKey(key);
    if (key == _esc && (_mode != VimMode.normal || _count != null || _prefix.isNotEmpty)) {
      _mode = VimMode.normal;
      _clearPending();
      return KeyResult.ok;
    }
    if (_mode == VimMode.insert) return KeyResult.ignored;

    final d = key.digit;
    if (d != null && _prefix.isEmpty && (d != 0 || _count != null)) {
      _count = math.min((_count ?? 0) * 10 + d, 99999);
      return KeyResult.ok;
    }

    _prefix.add(key);
    final seq = KeySeq(_prefix);
    if (_keymap.hasLonger(_area, seq)) {
      return KeyResult(hints: [
        for (final c in _keymap.continuations(_area, seq)) KeyHint(c.rest.format(), labelFor(c.ref)),
      ]);
    }
    final exact = _keymap.lookup(_area, seq);
    final count = _count;
    if (exact != null) {
      _clearPending();
      return _dispatch(exact, count);
    }
    if (_prefix.length > 1) {
      // A dead end: if the keys before this one run something on their own, run that, then this key afresh.
      final prior = KeySeq(_prefix.sublist(0, _prefix.length - 1));
      final ref = _keymap.lookup(_area, prior);
      _clearPending();
      if (ref == null) return KeyResult(toast: 'No action for ${seq.format()}', error: true);
      final first = _dispatch(ref, count);
      final second = _handle(key);
      return KeyResult(
        handled: true,
        hints: second.hints,
        toast: second.toast ?? first.toast,
        error: first.error || second.error,
        done: second.done ?? first.done,
      );
    }
    _clearPending();
    return KeyResult.ignored;
  }

  KeyResult _slotKey(KeyChord key) {
    final what = _await;
    final count = _awaitCount;
    _await = _Await.none;
    _awaitCount = null;
    if (key == _esc) return KeyResult.ok;
    var name = key.char;
    if (name == null || name == ' ') return KeyResult(toast: 'Not a slot name: ${key.format()}', error: true);
    if (what == _Await.recordSlot) {
      _recording = name;
      _recorded = [];
      return KeyResult(toast: 'Recording @$name');
    }
    if (name == '@') {
      if (_lastReplay == null) return const KeyResult(toast: 'No macro replayed yet', error: true);
      name = _lastReplay!;
    }
    _lastReplay = name;
    return _dispatch(ActionRef.macro(name), count);
  }

  // ---- Command line ----

  void _openPrompt(String p, ActionDef? def, int? count) {
    _prompt = p;
    _promptAction = def;
    _promptCount = count;
    _text = '';
    _completionsFor = null;
  }

  void _closePrompt() {
    _prompt = null;
    _promptAction = null;
    _promptCount = null;
    _text = '';
    _completionsFor = null;
    _completions = const [];
  }

  /// Opens the `:` line (also for a tap on a command button).
  void openCommandLine() => _change(() => _openPrompt(':', null, null));

  /// Replaces the command text (when the app uses its own text field for the bar).
  void setCommandText(String text) => _change(() => _text = text);

  void closeCommandLine() => _change(_closePrompt);

  /// Runs the command line's text and closes it.
  KeyResult submitCommand() {
    late KeyResult r;
    _change(() => r = _submit());
    return r;
  }

  KeyResult _promptKey(KeyChord key) {
    if (key == _esc) {
      _closePrompt();
      return KeyResult.ok;
    }
    if (key.plain && !key.shift && key.key == 'Enter') return _submit();
    if (key.plain && !key.shift && key.key == 'Backspace') {
      if (_text.isEmpty) {
        _closePrompt();
      } else {
        _text = _text.substring(0, _text.length - 1);
      }
      return KeyResult.ok;
    }
    if (key.plain && !key.shift && key.key == 'Tab') {
      final c = completions;
      if (c.isNotEmpty) _text = '${c.first.keys} ';
      return KeyResult.ok;
    }
    final ch = key.char;
    if (ch != null) _text += ch;
    return KeyResult.ok;
  }

  KeyResult _submit() {
    final p = _prompt;
    final def = _promptAction;
    final count = _promptCount;
    final text = _text.trim();
    _closePrompt();
    if (text.isEmpty) return KeyResult.ok;
    if (p != ':' && def != null) return _dispatch(ActionRef.action(def.id), count, arg: text);
    final words = text.split(RegExp(r'\s+'));
    // A short command name with a value comes first (`:grid 1/16` sets the grid rather than naming "Grid 1/16").
    if (words.length > 1) {
      final first = words.first.toLowerCase();
      for (final d in registry.matchCommand(first, area: _area)) {
        if (d.command != first || !d.takesArg) continue;
        return _dispatch(ActionRef.action(d.id), null, arg: words.skip(1).join(' '));
      }
    }
    for (var n = words.length; n >= 1; n--) {
      final cand = words.take(n).join(' ');
      final arg = n < words.length ? words.skip(n).join(' ') : null;
      final defs = registry.matchCommand(cand, area: _area);
      if (defs.isNotEmpty) {
        final d = defs.first;
        if (arg != null && !d.takesArg) return KeyResult(toast: '${d.name} takes no value', error: true);
        return _dispatch(ActionRef.action(d.id), null, arg: arg);
      }
      if (arg == null && lookupMacro(cand) != null) return _dispatch(ActionRef.macro(cand), null);
    }
    return KeyResult(toast: 'Not a command: ${words.first}', error: true);
  }

  // ---- Running ----

  KeyResult _dispatch(ActionRef ref, int? count, {String? arg}) {
    ActionDef? def;
    if (!ref.isMacro) {
      def = registry[ref.id];
      if (def == null) return KeyResult(toast: 'Unknown action ${ref.id}', error: true);
      if (def.internal) return _internal(def, count);
      if (def.prompt != null && arg == null) {
        _openPrompt(def.prompt!, def, count);
        return KeyResult.ok;
      }
    }
    final n = count ?? 1;
    final List<ActionCall> calls;
    try {
      calls = runner.expand(ref, count: n, arg: arg);
    } on MacroError catch (e) {
      return KeyResult(toast: e.message, error: true);
    }
    if (_recording != null) _recorded.add(MacroStep(ref, repeat: n, arg: arg));
    if (def == null || def.isChange) _lastChange = _Change(ref, n, arg);
    if (def?.setsMode != null) _mode = def!.setsMode!;
    final done = runner.runCalls(calls);
    String? toast;
    if (def == null || def.toast) {
      final b = StringBuffer(labelFor(ref));
      if (arg != null) b.write(' $arg');
      if (n > 1) b.write(' ×$n');
      toast = b.toString();
    }
    return KeyResult(toast: toast, done: done);
  }

  KeyResult _internal(ActionDef def, int? count) {
    switch (def.id) {
      case 'vim.commandLine':
        _openPrompt(':', null, null);
        return KeyResult.ok;
      case 'vim.repeat':
        final c = _lastChange;
        if (c == null) return const KeyResult(toast: 'Nothing to repeat', error: true);
        return _dispatch(c.ref, count ?? c.count, arg: c.arg);
      case 'vim.record':
        if (_recording != null) return _stopRecording();
        _await = _Await.recordSlot;
        return const KeyResult(hints: [KeyHint('a–z', 'record into this slot')]);
      case 'vim.replay':
        _await = _Await.replaySlot;
        _awaitCount = count;
        return KeyResult(hints: [
          if (_lastReplay != null) KeyHint('@', 'last: $_lastReplay'),
          for (final m in [...?projectMacros?.all, ..._keymap.macros.all])
            if (m.name.length == 1) KeyHint(m.name, '${m.steps.length} steps'),
        ]);
    }
    final m = def.setsMode;
    if (m != null) _mode = (m == VimMode.visual && _mode == VimMode.visual) ? VimMode.normal : m;
    return KeyResult.ok;
  }

  KeyResult _stopRecording() {
    final slot = _recording!;
    _recording = null;
    if (_recorded.isEmpty) return KeyResult(toast: 'Nothing recorded in @$slot');
    // A replay of this slot while recording it means "what the slot held before", so inline its old steps.
    final old = _keymap.macros[slot];
    final steps = <MacroStep>[];
    for (final s in _recorded) {
      if (s.ref.isMacro && s.ref.id == slot) {
        for (var k = 0; k < s.repeat; k++) {
          steps.addAll(old?.steps ?? const []);
        }
      } else {
        steps.add(s);
      }
    }
    _recorded = [];
    final macro = Macro(slot, steps);
    _keymap.macros.put(macro);
    onMacroRecorded?.call(macro);
    return KeyResult(toast: 'Recorded @$slot (${steps.length} steps)');
  }

  // ---- Helpers ----

  void _clearPending() {
    _count = null;
    _prefix.clear();
    _await = _Await.none;
    _awaitCount = null;
  }

  /// Runs [f] and notifies listeners only if something they show changed.
  void _change(void Function() f) {
    final before = _snapshot();
    f();
    if (_snapshot() != before) notifyListeners();
  }

  Object _snapshot() => (_area, _mode, _recording, _prompt, _text, _await, _count, _prefix.length);
}
