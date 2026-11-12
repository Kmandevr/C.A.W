// The key bindings editor: search every action, give it keys (pressed or typed), see what a key would clash with,
// remove keys and reset to the defaults. Changes save to keys.txt through the key router.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'panel_motion.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../actions/key_event.dart';
import '../actions/keymap.dart';
import '../actions/keys.dart';
import '../actions/macro.dart';
import 'theme.dart';

/// Every action with its keys. [keymap] is read on each change (the router can load a new one); [onSave] writes it.
class KeyBindingsPage extends StatefulWidget {
  const KeyBindingsPage({
    super.key,
    required this.registry,
    required this.keymap,
    required this.defaults,
    required this.onSave,
  });

  final ActionRegistry registry;
  final Keymap Function() keymap;
  final Keymap defaults;
  final Future<void> Function() onSave;

  @override
  State<KeyBindingsPage> createState() => _KeyBindingsPageState();
}

class _KeyBindingsPageState extends State<KeyBindingsPage> {
  String _q = '';

  Keymap get _k => widget.keymap();

  /// The keys an action has in its own area.
  List<KeySeq> _keys(ActionDef d) => _k.keysFor(d.area, ActionRef.action(d.id));

  String _nameOf(ActionRef r) => r.isMacro ? 'the macro "${r.id}"' : widget.registry[r.id]?.name ?? r.id;

  bool _isDefault(ActionDef d) {
    final mine = _keys(d).toSet(), theirs = widget.defaults.keysFor(d.area, ActionRef.action(d.id)).toSet();
    return mine.length == theirs.length && mine.containsAll(theirs);
  }

  Future<void> _changed() async {
    setState(() {});
    await widget.onSave();
  }

  Future<void> _edit(ActionDef d) async {
    final kept = <String>[];
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetAnimation(context), // in and out at the theme's pace
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        final ref = ActionRef.action(d.id);
        final keys = _keys(d);
        Future<void> after() async {
          setSheet(() {});
          await _changed();
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.name, style: Theme.of(context).textTheme.titleMedium),
              Text(
                [d.area.label, if (d.description.isNotEmpty) d.description].join(' · '),
                style: const TextStyle(color: Neon.dim),
              ),
              const SizedBox(height: 12),
              if (keys.isEmpty) const Text('No keys', style: TextStyle(color: Neon.dim)),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in keys)
                  InputChip(
                    key: ValueKey('key-${k.format()}'),
                    label: Text(k.format(), style: Neon.code(size: 13, color: Neon.yellow)),
                    deleteButtonTooltipMessage: 'Remove ${k.format()}',
                    onDeleted: () async {
                      _k.unbind(d.area, k);
                      await after();
                    },
                  ),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  key: const ValueKey('add-key'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a key'),
                  onPressed: () async {
                    final seq = await showDialog<KeySeq>(
                      context: context, animationStyle: dialogAnimation(context),
                      builder: (_) => KeyCaptureDialog(registry: widget.registry, keymap: _k, area: d.area, ref: ref),
                    );
                    if (seq == null) return;
                    _k.bind(d.area, seq, ref);
                    await after();
                  },
                ),
                if (!_isDefault(d))
                  OutlinedButton(
                    onPressed: () async {
                      for (final k in _keys(d)) {
                        _k.unbind(d.area, k);
                      }
                      kept.clear();
                      for (final k in widget.defaults.keysFor(d.area, ref)) {
                        // A default key another action has since been given stays with it.
                        final other = _k.bindingsIn(d.area)[k];
                        if (other != null && other != ref) {
                          kept.add('${k.format()} stays on ${_nameOf(other)}');
                        } else {
                          _k.bind(d.area, k, ref);
                        }
                      }
                      await after();
                    },
                    child: const Text('Reset to default'),
                  ),
              ]),
              for (final line in kept)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(line, style: const TextStyle(color: Neon.yellow, fontSize: 13)),
                ),
            ]),
          ),
        );
      }),
    );
  }

  Future<void> _resetAll() async {
    final ok = await showDialog<bool>(
      context: context, animationStyle: dialogAnimation(context),
      builder: (context) => AlertDialog(
        backgroundColor: Neon.panel,
        title: const Text('Reset every key?'),
        content: const Text('Every action gets its default keys back. Toolbars and long-press menus go back too; macros are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    _k.resetAll(widget.defaults);
    await _changed();
  }

  @override
  Widget build(BuildContext context) {
    final found = widget.registry.search(_q).where((d) => !d.internal).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Key bindings'),
        backgroundColor: Neon.panel,
        actions: [TextButton(onPressed: _resetAll, child: const Text('Reset all'))],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            key: const ValueKey('keys-search'),
            decoration: const InputDecoration(hintText: 'Search actions', prefixIcon: Icon(Icons.search), isDense: true),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: found.length,
            itemBuilder: (context, i) {
              final d = found[i];
              final keys = _keys(d).map((k) => k.format()).join(', ');
              return ListTile(
                dense: true,
                title: Text(d.name),
                subtitle: Text(d.area.label, style: const TextStyle(color: Neon.dim)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!_isDefault(d)) const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.edit, size: 14, color: Neon.blue, semanticLabel: 'changed'),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(keys.isEmpty ? '—' : keys, overflow: TextOverflow.ellipsis,
                        style: Neon.code(size: 12, color: keys.isEmpty ? Neon.dim : Neon.yellow)),
                  ),
                ]),
                onTap: () => _edit(d),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Asks for a key sequence for [ref] in [area]: press the keys (each press adds one, up to three), or type them
/// ("Ctrl+Shift+K", "G G") on a phone. Shows what the keys would clash with; a key already taken is replaced.
class KeyCaptureDialog extends StatefulWidget {
  const KeyCaptureDialog({super.key, required this.registry, required this.keymap, required this.area, required this.ref});
  final ActionRegistry registry;
  final Keymap keymap;
  final Area area;
  final ActionRef ref;

  @override
  State<KeyCaptureDialog> createState() => _KeyCaptureDialogState();
}

class _KeyCaptureDialogState extends State<KeyCaptureDialog> {
  final _focus = FocusNode(debugLabel: 'key capture');
  final _typed = TextEditingController();
  List<KeyChord> _pressed = [];
  String? _typeError;

  @override
  void dispose() {
    _focus.dispose();
    _typed.dispose();
    super.dispose();
  }

  KeySeq? get _seq {
    if (_typed.text.trim().isNotEmpty) return typedKeys(_typed.text);
    return _pressed.isEmpty ? null : KeySeq(_pressed);
  }

  /// Why [seq] could never run, or null: a plain digit first is always read as a count (`3D`).
  static String? _unusable(KeySeq seq) =>
      seq.chords.first.digit != null ? 'A plain digit is a count; use it with Ctrl or Alt' : null;

  String _name(ActionRef r) => r.isMacro ? 'the macro "${r.id}"' : widget.registry[r.id]?.name ?? r.id;

  String _describe(KeyConflict c) => switch (c.kind) {
        ConflictKind.taken => 'Replaces ${_name(c.existing)} on ${c.keys.format()}',
        ConflictKind.prefix => 'Clashes with ${c.keys.format()} (${_name(c.existing)}): one starts the other',
        ConflictKind.shadowsGlobal => 'Hides ${_name(c.existing)} here (a key for everywhere)',
        ConflictKind.shadowedByArea => '${c.area.label} uses it for ${_name(c.existing)} instead',
      };

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyRepeatEvent) return KeyEventResult.handled; // holding a key is one press
    // As the router reads keys: Cmd counts as Ctrl on macOS.
    final chord = keyChordFromEvent(e, metaAsCtrl: defaultTargetPlatform == TargetPlatform.macOS);
    if (chord == null) return e is KeyUpEvent ? KeyEventResult.ignored : KeyEventResult.handled;
    setState(() {
      _typed.clear();
      _typeError = null;
      _pressed = _pressed.length >= 3 ? [chord] : [..._pressed, chord];
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final seq = _seq;
    final unusable = seq == null ? null : _unusable(seq);
    final conflicts = seq == null ? const <KeyConflict>[] : widget.keymap.conflictsFor(widget.area, seq, ignoring: widget.ref);
    return AlertDialog(
      scrollable: true, // the on-screen keyboard leaves little room on a phone
      backgroundColor: Neon.panel,
      title: Text('Key for ${_name(widget.ref)}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: ListenableBuilder(
              listenable: _focus,
              builder: (context, _) => InkWell(
                key: const ValueKey('key-capture'),
                onTap: _focus.requestFocus,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _focus.hasFocus ? Neon.blue : Neon.line),
                  ),
                  child: Text(
                    _pressed.isNotEmpty && _typed.text.isEmpty
                        ? KeySeq(_pressed).format()
                        : _focus.hasFocus ? 'Press the keys' : 'Tap here, then press the keys',
                    style: Neon.code(size: 16, color: _pressed.isNotEmpty ? Neon.yellow : Neon.dim),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('key-typed'),
            controller: _typed,
            decoration: InputDecoration(
              isDense: true,
              labelText: 'Or type them',
              hintText: 'Ctrl+Shift+K, G G',
              errorText: _typeError,
            ),
            onChanged: (v) => setState(() {
              _pressed = [];
              _typeError = v.trim().isEmpty || typedKeys(v) != null ? null : 'Not a key';
            }),
          ),
          const SizedBox(height: 10),
          if (unusable != null) Text(unusable, style: const TextStyle(color: Neon.pink, fontSize: 13)),
          for (final c in conflicts)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_describe(c),
                  style: TextStyle(color: c.kind == ConflictKind.taken ? Neon.yellow : Neon.pink, fontSize: 13)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () => setState(() {
            _pressed = [];
            _typed.clear();
            _typeError = null;
            _focus.requestFocus();
          }),
          child: const Text('Clear'),
        ),
        FilledButton(
          key: const ValueKey('key-set'),
          onPressed: seq == null || unusable != null ? null : () => Navigator.pop(context, seq),
          child: const Text('Set'),
        ),
      ],
    );
  }
}

/// Typed keys as the keyboard sends them, or null when they aren't keys. Without Ctrl, Alt or Meta a shifted symbol
/// arrives as the symbol itself ("Shift+/" is "?"), so Shift is dropped from it; Shift with a plain digit types a
/// symbol instead and is refused.
KeySeq? typedKeys(String text) {
  final seq = KeySeq.tryParse(text);
  if (seq == null) return null;
  final out = <KeyChord>[];
  for (final c in seq.chords) {
    final symbol = c.key.length == 1 && c.key.toUpperCase() == c.key.toLowerCase();
    if (c.shift && symbol && !c.ctrl && !c.alt && !c.meta) {
      if (RegExp(r'^[0-9]$').hasMatch(c.key)) return null;
      out.add(KeyChord(c.key));
    } else {
      out.add(c);
    }
  }
  return KeySeq(out);
}
