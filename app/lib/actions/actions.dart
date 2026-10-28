// Action definitions and the registry: every command the app can run, with its id, name, area and default keys.
import 'dart:async';

import 'catalogue.dart';

/// The Vim-style mode: Normal runs actions, Insert types text, Visual makes movement extend the selection.
enum VimMode { normal, insert, visual }

/// Where an action or key binding applies, like Reaper's sections. [code] is the code editor's Vim mode.
enum Area {
  global('global', 'Global'),
  builder('builder', 'Builder'),
  pattern('roll', 'Pattern editor'),
  arranger('arranger', 'Arranger'),
  exporter('exporter', 'Exporter'),
  code('code', 'Code editor (Vim)');

  /// The name used in keymap files.
  final String fileName;
  final String label;
  const Area(this.fileName, this.label);

  /// Reads an area name from a keymap file ("roll" or "pattern" both mean [pattern]).
  static Area? parse(String name) {
    final n = name.toLowerCase();
    if (n == 'pattern') return Area.pattern;
    for (final a in Area.values) {
      if (a.fileName == n) return a;
    }
    return null;
  }
}

/// Runs one action. [count] comes from a Vim count or a macro step's repeat; [arg] from a `:` command.
typedef ActionHandler = FutureOr<void> Function(String actionId, {int count, String? arg});

/// One command the app can run. The registry holds definitions only; the app runs them through an [ActionHandler].
class ActionDef {
  final String id;
  final String name;
  final String description;
  final Area area;

  /// Default keys in [area], each a key sequence ("Ctrl+W", "X X").
  final List<String> defaultKeys;

  /// Changes the project or text, so `.` can repeat it.
  final bool isChange;

  /// Accepts a value from the command line (`:bpm 140`).
  final bool takesArg;

  /// Short command-line name (`bpm` for `:bpm 140`); every action is also a command by its id and name.
  final String? command;

  /// Example value shown in completion ("140", "now|beat|bar").
  final String? argHint;

  /// The Vim mode to switch to after running (Insert after `i`, Visual after `v`).
  final VimMode? setsMode;

  /// Opens a one-line prompt with this character (`/` search) and runs the action with the typed text as its arg.
  final String? prompt;

  /// Shows a toast when run (off for plain movement, which would be noise).
  final bool toast;

  /// Run by the Vim controller itself (modes, `:`, `.`, recording, replay), never sent to the handler.
  final bool internal;

  const ActionDef(
    this.id,
    this.name,
    this.area, {
    this.description = '',
    this.defaultKeys = const [],
    this.isChange = false,
    this.takesArg = false,
    this.command,
    this.argHint,
    this.setsMode,
    this.prompt,
    this.toast = true,
    this.internal = false,
  });
}

/// All known actions, looked up by id, area, command name or a search of names and descriptions.
class ActionRegistry {
  final Map<String, ActionDef> _byId = {};
  Map<String, List<ActionDef>>? _commands;

  ActionRegistry([Iterable<ActionDef> defs = const []]) {
    defs.forEach(register);
  }

  /// The full catalogue from docs/actions.md.
  factory ActionRegistry.standard() => ActionRegistry(standardActions);

  void register(ActionDef def) {
    if (_byId.containsKey(def.id)) throw ArgumentError('Action "${def.id}" is already registered');
    _byId[def.id] = def;
    _commands = null;
  }

  ActionDef? lookup(String id) => _byId[id];
  ActionDef? operator [](String id) => _byId[id];
  bool contains(String id) => _byId.containsKey(id);

  Iterable<ActionDef> get all => _byId.values;

  List<ActionDef> inArea(Area area) => [
        for (final d in _byId.values)
          if (d.area == area) d
      ];

  /// Actions whose command name, id or name (case-insensitive) is [word]; current area first, then global, then the
  /// rest.
  List<ActionDef> matchCommand(String word, {Area? area}) {
    final index = _commands ??= _buildCommands();
    final found = [...?index[word.toLowerCase()]];
    int rank(ActionDef d) => d.area == area ? 0 : (d.area == Area.global ? 1 : 2);
    found.sort((a, b) => rank(a).compareTo(rank(b)));
    return found;
  }

  Map<String, List<ActionDef>> _buildCommands() {
    final m = <String, List<ActionDef>>{};
    for (final d in _byId.values) {
      for (final k in {if (d.command != null) d.command!, d.id.toLowerCase(), d.name.toLowerCase()}) {
        (m[k] ??= []).add(d);
      }
    }
    return m;
  }

  /// Every action whose name, description, id or command contains all words of [query]; name matches first.
  List<ActionDef> search(String query, {Area? area}) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final out = <ActionDef>[];
    for (final d in _byId.values) {
      if (area != null && d.area != area) continue;
      final hay = '${d.name} ${d.description} ${d.id} ${d.command ?? ''}'.toLowerCase();
      if (words.every(hay.contains)) out.add(d);
    }
    final q = words.join(' ');
    int rank(ActionDef d) => d.name.toLowerCase().startsWith(q) ? 0 : (d.name.toLowerCase().contains(q) ? 1 : 2);
    out.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });
    return out;
  }
}
