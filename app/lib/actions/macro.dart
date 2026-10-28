// Macros: named lists of action steps with repeats, their text form, and the runner that expands and runs them.
import 'dart:async';

import 'actions.dart';

/// What a key, toolbar button, menu entry or macro step runs: an action by id, or a macro by name.
class ActionRef {
  final String id;
  final bool isMacro;

  const ActionRef.action(this.id) : isMacro = false;
  const ActionRef.macro(String name)
      : id = name,
        isMacro = true;

  static final _macroRe = RegExp(r'^macro\s+"([^"]*)"$');

  /// Reads `roll.notes.up` or `macro "Run of four"`. Throws [FormatException].
  static ActionRef parse(String text) {
    final t = text.trim();
    final m = _macroRe.firstMatch(t);
    if (m != null) return ActionRef.macro(m.group(1)!);
    if (t.isEmpty || t.contains(RegExp(r'\s')) || t.contains('"')) throw FormatException('Bad action', text);
    return ActionRef.action(t);
  }

  String format() => isMacro ? 'macro "$id"' : id;

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) => other is ActionRef && other.id == id && other.isMacro == isMacro;

  @override
  int get hashCode => Object.hash(id, isMacro);
}

/// One macro step: run [ref] [repeat] times, with an optional command-line value.
class MacroStep {
  final ActionRef ref;
  final int repeat;
  final String? arg;

  const MacroStep(this.ref, {this.repeat = 1, this.arg});

  static final _repeatRe = RegExp(r'\s\*\s*(\d+)$');

  /// Reads `roll.select.copyafter * 3`, `transport.bpm 140` or `macro "Other" * 2`.
  static MacroStep parse(String text) {
    var t = text.trim();
    var repeat = 1;
    final r = _repeatRe.firstMatch(t);
    if (r != null) {
      repeat = int.parse(r.group(1)!);
      if (repeat < 1) throw FormatException('Repeat must be at least 1', text);
      t = t.substring(0, r.start).trim();
    }
    if (t.startsWith('macro ')) return MacroStep(ActionRef.parse(t), repeat: repeat);
    final sp = t.indexOf(RegExp(r'\s'));
    final id = sp < 0 ? t : t.substring(0, sp);
    final arg = sp < 0 ? null : t.substring(sp).trim();
    return MacroStep(ActionRef.parse(id), repeat: repeat, arg: arg);
  }

  String format() {
    final b = StringBuffer(ref.format());
    if (arg != null && arg!.isNotEmpty) b.write(' $arg');
    if (repeat != 1) b.write(' * $repeat');
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
        if (ref.isMacro) 'macro': ref.id else 'action': ref.id,
        if (repeat != 1) 'repeat': repeat,
        if (arg != null) 'arg': arg,
      };

  factory MacroStep.fromJson(Map<String, dynamic> j) => MacroStep(
        j['macro'] != null ? ActionRef.macro(j['macro'] as String) : ActionRef.action(j['action'] as String),
        repeat: (j['repeat'] as num?)?.toInt() ?? 1,
        arg: j['arg'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is MacroStep && other.ref == ref && other.repeat == repeat && other.arg == arg;

  @override
  int get hashCode => Object.hash(ref, repeat, arg);
}

/// A named list of steps run in order. A macro is itself something you can bind, put on a toolbar or call.
class Macro {
  final String name;
  final List<MacroStep> steps;

  Macro(this.name, Iterable<MacroStep> steps) : steps = List.unmodifiable(steps);

  /// The `macro "Name"` block of a keymap or macro file.
  String format() => ['macro "$name"', for (final s in steps) '  ${s.format()}'].join('\n');

  Map<String, dynamic> toJson() => {
        'name': name,
        'steps': [for (final s in steps) s.toJson()]
      };

  factory Macro.fromJson(Map<String, dynamic> j) => Macro(
        j['name'] as String,
        [for (final s in (j['steps'] as List? ?? const [])) MacroStep.fromJson(s as Map<String, dynamic>)],
      );

  @override
  bool operator ==(Object other) {
    if (other is! Macro || other.name != name || other.steps.length != steps.length) return false;
    for (var i = 0; i < steps.length; i++) {
      if (other.steps[i] != steps[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(name, Object.hashAll(steps));
}

/// A set of macros by name: the app's own (in the keymap) or a project's.
class MacroSet {
  final Map<String, Macro> _byName = {};

  MacroSet([Iterable<Macro> macros = const []]) {
    for (final m in macros) {
      _byName[m.name] = m;
    }
  }

  /// [first]'s macros, then [later]'s, which win on a name clash (a project's macros after the app's).
  factory MacroSet.merged(MacroSet first, MacroSet? later) => MacroSet([...first.all, ...?later?.all]);

  Macro? operator [](String name) => _byName[name];
  bool contains(String name) => _byName.containsKey(name);
  Iterable<Macro> get all => _byName.values;
  Iterable<String> get names => _byName.keys;
  bool get isEmpty => _byName.isEmpty;

  void put(Macro m) => _byName[m.name] = m;
  Macro? remove(String name) => _byName.remove(name);
  MacroSet copy() => MacroSet(all);

  /// Reads macro blocks; an optional `kind: macros` header is skipped. Bad lines go to [warnings].
  static MacroSet parse(String text, {List<String>? warnings}) {
    final lines = text.split('\n');
    var i = 0;
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      i = 1;
      while (i < lines.length && lines[i].trim() != '---') {
        final kv = lines[i].split(':');
        if (kv.length >= 2 && kv[0].trim() == 'kind' && kv[1].trim() != 'macros') {
          throw FormatException('Not a macro file (kind: ${kv[1].trim()})');
        }
        i++;
      }
      i++;
    }
    final set = MacroSet();
    parseBlocks(lines, i, set, warnings ?? []);
    return set;
  }

  static final _headRe = RegExp(r'^macro\s+"([^"]*)"\s*$');

  /// Parses `macro "Name"` blocks from [lines] starting at [start] into [into]; other lines are reported.
  static void parseBlocks(List<String> lines, int start, MacroSet into, List<String> warnings,
      {bool Function(String line, int lineNo)? other}) {
    String? name;
    var steps = <MacroStep>[];
    void close() {
      if (name != null) {
        if (into.contains(name!)) warnings.add('Macro "$name" is defined twice; the last one wins');
        into.put(Macro(name!, steps));
      }
      name = null;
      steps = [];
    }

    for (var i = start; i < lines.length; i++) {
      final raw = lines[i].replaceAll('\r', '');
      final t = raw.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final indented = raw.startsWith(' ') || raw.startsWith('\t');
      if (indented && name != null) {
        try {
          steps.add(MacroStep.parse(t));
        } on FormatException catch (e) {
          warnings.add('Line ${i + 1}: ${e.message}');
        }
        continue;
      }
      close();
      final h = _headRe.firstMatch(t);
      if (h != null) {
        name = h.group(1);
      } else if (other == null || !other(t, i + 1)) {
        warnings.add('Line ${i + 1}: not understood: $t');
      }
    }
    close();
  }

  String format() => [for (final m in all) m.format()].join('\n\n');

  List<Map<String, dynamic>> toJson() => [for (final m in all) m.toJson()];

  factory MacroSet.fromJson(List<dynamic> j) =>
      MacroSet([for (final m in j) Macro.fromJson(m as Map<String, dynamic>)]);
}

/// A macro that calls itself, a missing macro or action, or more steps than the cap.
class MacroError implements Exception {
  final String message;
  const MacroError(this.message);

  @override
  String toString() => message;
}

/// One call on the handler.
class ActionCall {
  final String actionId;
  final int count;
  final String? arg;

  const ActionCall(this.actionId, {this.count = 1, this.arg});

  @override
  bool operator ==(Object other) =>
      other is ActionCall && other.actionId == actionId && other.count == count && other.arg == arg;

  @override
  int get hashCode => Object.hash(actionId, count, arg);

  @override
  String toString() => 'ActionCall($actionId, count: $count, arg: $arg)';
}

/// Expands macros into handler calls and runs calls one after another, waiting for each async handler.
///
/// A step that runs an action becomes one call with `count` = its repeat; a step that runs a macro expands that
/// macro repeat times. The total of all counts is capped at [maxSteps].
class MacroRunner {
  /// Finds a macro by name (for example a project's macros, then the app's).
  final Macro? Function(String name) lookup;
  final ActionHandler handler;
  final ActionRegistry? registry;
  final int maxSteps;

  Future<void>? _busy;

  MacroRunner({required this.lookup, required this.handler, this.registry, this.maxSteps = 10000});

  /// A runner over one fixed set of macros.
  MacroRunner.forSet(MacroSet macros, {required ActionHandler handler, ActionRegistry? registry, int maxSteps = 10000})
      : this(lookup: (n) => macros[n], handler: handler, registry: registry, maxSteps: maxSteps);

  /// The calls [ref] makes when run [count] times. Throws [MacroError].
  List<ActionCall> expand(ActionRef ref, {int count = 1, String? arg}) {
    final out = <ActionCall>[];
    var total = 0;
    void add(ActionCall c) {
      total += c.count;
      if (total > maxSteps) throw MacroError('Too many steps (over $maxSteps)');
      out.add(c);
    }

    void walk(ActionRef r, int n, String? a, List<String> stack) {
      if (!r.isMacro) {
        if (registry != null && !registry!.contains(r.id)) throw MacroError('Unknown action "${r.id}"');
        add(ActionCall(r.id, count: n, arg: a));
        return;
      }
      if (stack.contains(r.id)) {
        final path = [...stack.sublist(stack.indexOf(r.id)), r.id].map((s) => '"$s"').join(' → ');
        throw MacroError(stack.last == r.id ? 'Macro "${r.id}" calls itself' : 'Macros call each other: $path');
      }
      final m = lookup(r.id);
      if (m == null) throw MacroError('No macro "${r.id}"');
      if (n < 1) return;
      final start = out.length;
      for (final s in m.steps) {
        walk(s.ref, s.repeat, s.arg, [...stack, r.id]);
      }
      final once = out.sublist(start);
      if (once.isEmpty) return;
      for (var k = 1; k < n; k++) {
        once.forEach(add);
      }
    }

    walk(ref, count, arg, const []);
    return out;
  }

  /// Checks that a macro expands without error; returns the error message or null.
  String? check(String name) {
    try {
      expand(ActionRef.macro(name));
      return null;
    } on MacroError catch (e) {
      return e.message;
    }
  }

  /// Expands and runs [ref]. Throws [MacroError] before running anything if the expansion fails.
  Future<void>? run(ActionRef ref, {int count = 1, String? arg}) => runCalls(expand(ref, count: count, arg: arg));

  /// Runs [calls] in order after anything still running. Returns null when everything finished synchronously.
  Future<void>? runCalls(List<ActionCall> calls) {
    if (calls.isEmpty) return _busy;
    final busy = _busy;
    final Future<void>? f = busy == null ? _from(calls, 0) : busy.then((_) => _from(calls, 0) ?? Future<void>.value());
    if (f == null) return null;
    late final Future<void> tracked;
    tracked = f.whenComplete(() {
      if (identical(_busy, tracked)) _busy = null;
    });
    _busy = tracked;
    return tracked;
  }

  Future<void>? _from(List<ActionCall> calls, int i) {
    for (; i < calls.length; i++) {
      final c = calls[i];
      final r = handler(c.actionId, count: c.count, arg: c.arg);
      if (r is Future<void>) {
        final next = i + 1;
        return r.then((_) => _from(calls, next) ?? Future<void>.value());
      }
    }
    return null;
  }
}
