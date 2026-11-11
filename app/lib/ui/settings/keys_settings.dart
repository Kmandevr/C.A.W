// Settings › Keys and shortcuts: the key bindings editor, Vim keys in the code editor, and the symbol key row.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../glass.dart';
import '../theme.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class KeysSettings extends StatelessWidget {
  const KeysSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (deps.onEditKeys != null)
        settingAction('keys.bindings', icon: Icons.keyboard_alt_outlined, iconColor: Neon.yellow,
            onTap: () => deps.onEditKeys!(context)),
      settingSwitch('keys.vim', s.vimCode, (v) => s.update((x) => x.vimCode = v), icon: Icons.keyboard),
      settingAction('keys.keyRow',
          icon: Icons.space_bar, iconColor: Neon.yellow,
          subtitle: s.editor.keyRow.map((k) => k.trim()).join('  '),
          onTap: () => showGlassSheet<void>(
                context: context,
                backgroundColor: Neon.panel,
                isScrollControlled: true,
                builder: (_) => _KeyRowEditor(settings: s),
              )),
    ]);
  }
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

