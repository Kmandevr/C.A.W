import 'package:flutter/material.dart';

import '../actions/actions.dart';
import '../actions/keymap.dart';
import '../actions/macro.dart';
import 'theme.dart';

/// A touch-first strip of direct actions. It deliberately does not synthesize keyboard chords.
class TouchQuickActions extends StatelessWidget {
  const TouchQuickActions({
    super.key,
    required this.area,
    required this.keymap,
    required this.defaults,
    required this.registry,
    required this.onRun,
    required this.onSave,
  });

  final Area area;
  final Keymap keymap;
  final Keymap defaults;
  final ActionRegistry registry;
  final ValueChanged<ActionRef> onRun;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final items = keymap.toolbars[area] ?? const <ActionRef>[];
    return Material(
      color: Neon.panelHi.withValues(alpha: 0.98),
      borderRadius: BorderRadius.circular(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final ref in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
              child: Tooltip(
                message: _name(ref),
                child: TextButton(
                  onPressed: () => onRun(ref),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    foregroundColor: Neon.text,
                  ),
                  child: Text(_shortName(ref), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
            child: IconButton(
              tooltip: 'Customize quick actions',
              onPressed: () => _edit(context),
              icon: const Icon(Icons.tune),
              color: Neon.blue,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ),
        ]),
      ),
    );
  }

  String _name(ActionRef ref) =>
      ref.isMacro ? 'Macro: ${ref.id}' : (registry[ref.id]?.name ?? ref.id);

  String _shortName(ActionRef ref) {
    final name = _name(ref);
    return name.length > 18 ? '${name.substring(0, 17)}…' : name;
  }

  Future<void> _edit(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (_) => _QuickActionEditor(
        area: area,
        keymap: keymap,
        defaults: defaults,
        registry: registry,
        onSave: onSave,
      ),
    );
  }
}

class _QuickActionEditor extends StatefulWidget {
  const _QuickActionEditor({
    required this.area,
    required this.keymap,
    required this.defaults,
    required this.registry,
    required this.onSave,
  });

  final Area area;
  final Keymap keymap;
  final Keymap defaults;
  final ActionRegistry registry;
  final Future<void> Function() onSave;

  @override
  State<_QuickActionEditor> createState() => _QuickActionEditorState();
}

class _QuickActionEditorState extends State<_QuickActionEditor> {
  late List<ActionRef> _items = List.of(
    widget.keymap.toolbars[widget.area] ?? const <ActionRef>[],
  );
  Future<void> _saving = Future.value();

  Future<void> _save() {
    widget.keymap.toolbars[widget.area] = List.of(_items);
    return _saving = _saving.then((_) => widget.onSave());
  }

  Future<void> _add() async {
    final choices = <ActionRef>[
      for (final action in widget.registry.all)
        if ((action.area == widget.area || action.area == Area.global) &&
            !action.internal &&
            !action.takesArg)
          ActionRef.action(action.id),
      for (final name in widget.keymap.macros.names) ActionRef.macro(name),
    ].where((ref) => !_items.contains(ref)).toList();

    final picked = await showModalBottomSheet<ActionRef>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (_) => _QuickActionPicker(choices: choices, registry: widget.registry),
    );
    if (picked == null || !mounted) return;
    setState(() => _items.add(picked));
    await _save();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${widget.area.label} quick actions',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    setState(() => _items = List.of(
                          widget.defaults.toolbars[widget.area] ?? const <ActionRef>[],
                        ));
                    await _save();
                  },
                  child: const Text('Default'),
                ),
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ]),
            ),
            Expanded(
              child: ReorderableListView(
                onReorderItem: (from, to) {
                  setState(() => _items.insert(to, _items.removeAt(from)));
                  _save();
                },
                children: [
                  for (final ref in _items)
                    ListTile(
                      key: ValueKey(ref),
                      leading: Icon(ref.isMacro ? Icons.playlist_play : Icons.bolt, color: Neon.blue),
                      title: Text(ref.isMacro ? 'Macro: ${ref.id}' : (widget.registry[ref.id]?.name ?? ref.id)),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          setState(() => _items.remove(ref));
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

class _QuickActionPicker extends StatefulWidget {
  const _QuickActionPicker({required this.choices, required this.registry});
  final List<ActionRef> choices;
  final ActionRegistry registry;

  @override
  State<_QuickActionPicker> createState() => _QuickActionPickerState();
}

class _QuickActionPickerState extends State<_QuickActionPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final found = widget.choices.where((ref) {
      final name = ref.isMacro ? ref.id : (widget.registry[ref.id]?.name ?? ref.id);
      return name.toLowerCase().contains(q) || ref.id.toLowerCase().contains(q);
    }).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Find an action or macro',
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: found.length,
              itemBuilder: (context, index) {
                final ref = found[index];
                final name = ref.isMacro
                    ? 'Macro: ${ref.id}'
                    : (widget.registry[ref.id]?.name ?? ref.id);
                return ListTile(
                  minTileHeight: 56,
                  title: Text(name),
                  subtitle: Text(ref.isMacro ? 'Macro' : (widget.registry[ref.id]?.area.label ?? 'Action')),
                  onTap: () => Navigator.pop(context, ref),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
