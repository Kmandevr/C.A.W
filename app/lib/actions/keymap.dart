// Keymaps: key bindings, toolbars, long-press menus and macros per area, with the readable file format and conflicts.
import 'actions.dart';
import 'catalogue.dart';
import 'keys.dart';
import 'macro.dart';

/// Why a key can't simply be bound: already [taken] in the area, a [prefix] clash with a longer or shorter sequence,
/// [shadowsGlobal] (the area key hides a global one), or [shadowedByArea] (a global key that an area overrides).
enum ConflictKind { taken, prefix, shadowsGlobal, shadowedByArea }

class KeyConflict {
  final Area area;
  final KeySeq keys;
  final ActionRef existing;
  final ConflictKind kind;

  const KeyConflict(this.area, this.keys, this.existing, this.kind);

  String describe() => switch (kind) {
        ConflictKind.taken => '${keys.format()} already runs ${existing.format()} in ${area.label}',
        ConflictKind.prefix => '${keys.format()} clashes with ${existing.format()} in ${area.label}',
        ConflictKind.shadowsGlobal => '${keys.format()} hides the global ${existing.format()}',
        ConflictKind.shadowedByArea => '${keys.format()} runs ${existing.format()} in ${area.label} instead',
      };

  @override
  String toString() => describe();
}

/// One possible next key after a prefix, for the key-hint popup.
class KeyContinuation {
  final KeySeq keys;
  final KeySeq rest;
  final ActionRef ref;
  const KeyContinuation(this.keys, this.rest, this.ref);
}

/// Lookup tables for one area with the global bindings folded in, so a key press is a map lookup.
class _AreaIndex {
  final Map<KeySeq, ActionRef> exact = {};
  final Map<KeySeq, List<KeySeq>> longer = {};
}

/// Bindings per area, toolbars, long-press menu entries and the app's macros. A parsed user file is partial: apply it
/// with [mergedOver] on top of [Keymap.defaults].
class Keymap {
  String name;
  final Map<Area, Map<KeySeq, ActionRef>> _bindings = {};
  final Map<Area, Set<KeySeq>> _removed = {};
  final Map<Area, List<ActionRef>> toolbars = {};
  final Map<Area, List<ActionRef>> menus = {};
  final MacroSet macros;
  final Map<Area, _AreaIndex> _index = {};

  Keymap({this.name = 'My keys', MacroSet? macros}) : macros = macros ?? MacroSet();

  /// The shipped keymap: every action's default keys in its area, and the default toolbars.
  factory Keymap.defaults(ActionRegistry registry) {
    final k = Keymap(name: 'Default');
    for (final d in registry.all) {
      for (final keys in d.defaultKeys) {
        k.bind(d.area, KeySeq.parse(keys), ActionRef.action(d.id));
      }
    }
    standardToolbars.forEach((area, ids) {
      k.toolbars[area] = [
        for (final id in ids)
          if (registry.contains(id)) ActionRef.action(id)
      ];
    });
    return k;
  }

  Keymap copy() {
    final k = Keymap(name: name, macros: macros.copy());
    _bindings.forEach((a, m) => k._bindings[a] = Map.of(m));
    _removed.forEach((a, s) => k._removed[a] = Set.of(s));
    toolbars.forEach((a, l) => k.toolbars[a] = List.of(l));
    menus.forEach((a, l) => k.menus[a] = List.of(l));
    return k;
  }

  // ---- Bindings ----

  Map<KeySeq, ActionRef> bindingsIn(Area area) => Map.unmodifiable(_bindings[area] ?? const {});

  /// Keys this partial keymap removes from the defaults (`-` lines).
  Set<KeySeq> removedIn(Area area) => Set.unmodifiable(_removed[area] ?? const {});

  void bind(Area area, KeySeq keys, ActionRef ref) {
    (_bindings[area] ??= {})[keys] = ref;
    _removed[area]?.remove(keys);
    _invalidate(area);
  }

  /// Removes a binding. [record] keeps a `-` line so merging over defaults removes it too.
  void unbind(Area area, KeySeq keys, {bool record = false}) {
    _bindings[area]?.remove(keys);
    if (record) (_removed[area] ??= {}).add(keys);
    _invalidate(area);
  }

  /// Puts an area's bindings, toolbar and menu back to [defaults].
  void resetArea(Area area, Keymap defaults) {
    _bindings[area] = Map.of(defaults._bindings[area] ?? const {});
    _removed.remove(area);
    _setOrRemove(toolbars, area, defaults.toolbars[area]);
    _setOrRemove(menus, area, defaults.menus[area]);
    _invalidate(area);
  }

  /// Puts every area back to [defaults]; macros are kept.
  void resetAll(Keymap defaults) {
    for (final a in Area.values) {
      resetArea(a, defaults);
    }
  }

  static void _setOrRemove(Map<Area, List<ActionRef>> m, Area area, List<ActionRef>? v) {
    if (v == null) {
      m.remove(area);
    } else {
      m[area] = List.of(v);
    }
  }

  void _invalidate(Area area) {
    if (area == Area.global) {
      _index.clear();
    } else {
      _index.remove(area);
    }
  }

  _AreaIndex _indexFor(Area area) => _index[area] ??= _build(area);

  _AreaIndex _build(Area area) {
    final ix = _AreaIndex();
    if (area != Area.global) ix.exact.addAll(_bindings[Area.global] ?? const {});
    ix.exact.addAll(_bindings[area] ?? const {});
    for (final seq in ix.exact.keys) {
      for (var n = 1; n < seq.length; n++) {
        (ix.longer[KeySeq(seq.chords.take(n))] ??= []).add(seq);
      }
    }
    return ix;
  }

  /// What [keys] runs in [area]: the area's own binding, else the global one.
  ActionRef? lookup(Area area, KeySeq keys) => _indexFor(area).exact[keys];

  /// True if a longer sequence in [area] (or global) starts with [prefix].
  bool hasLonger(Area area, KeySeq prefix) => _indexFor(area).longer.containsKey(prefix);

  /// The sequences that can follow [prefix] in [area], for key hints.
  List<KeyContinuation> continuations(Area area, KeySeq prefix) {
    final ix = _indexFor(area);
    return [
      for (final seq in ix.longer[prefix] ?? const <KeySeq>[])
        KeyContinuation(seq, KeySeq(seq.chords.skip(prefix.length)), ix.exact[seq]!),
    ];
  }

  /// Every key sequence bound to [ref] in [area] (not counting global).
  List<KeySeq> keysFor(Area area, ActionRef ref) => [
        for (final e in (_bindings[area] ?? const <KeySeq, ActionRef>{}).entries)
          if (e.value == ref) e.key,
      ];

  /// What would get in the way of binding [keys] in [area] (for the warning in the action list).
  List<KeyConflict> conflictsFor(Area area, KeySeq keys, {ActionRef? ignoring}) {
    final out = <KeyConflict>[];
    final own = _bindings[area] ?? const <KeySeq, ActionRef>{};
    for (final e in own.entries) {
      if (e.value == ignoring) continue;
      if (e.key == keys) {
        out.add(KeyConflict(area, e.key, e.value, ConflictKind.taken));
      } else if (e.key.startsWith(keys) || keys.startsWith(e.key)) {
        out.add(KeyConflict(area, e.key, e.value, ConflictKind.prefix));
      }
    }
    if (area != Area.global) {
      final g = _bindings[Area.global]?[keys];
      if (g != null && g != ignoring) out.add(KeyConflict(Area.global, keys, g, ConflictKind.shadowsGlobal));
    } else {
      for (final a in Area.values) {
        if (a == Area.global) continue;
        final r = _bindings[a]?[keys];
        if (r != null && r != ignoring) out.add(KeyConflict(a, keys, r, ConflictKind.shadowedByArea));
      }
    }
    return out;
  }

  /// Problems in the whole keymap: prefix clashes inside an area (global included) and area keys hiding global ones.
  List<KeyConflict> conflicts({bool includeShadows = true}) {
    final out = <KeyConflict>[];
    final global = _bindings[Area.global] ?? const <KeySeq, ActionRef>{};
    for (final area in Area.values) {
      final own = _bindings[area] ?? const <KeySeq, ActionRef>{};
      final ix = _indexFor(area);
      for (final e in own.entries) {
        for (var n = 1; n < e.key.length; n++) {
          final p = KeySeq(e.key.chords.take(n));
          final r = ix.exact[p];
          if (r != null) out.add(KeyConflict(area, e.key, r, ConflictKind.prefix));
        }
        if (includeShadows && area != Area.global && global.containsKey(e.key)) {
          out.add(KeyConflict(area, e.key, global[e.key]!, ConflictKind.shadowsGlobal));
        }
      }
      if (area != Area.global) {
        // A global sequence whose prefix the area binds can never be reached in that area.
        for (final e in global.entries) {
          if (own.containsKey(e.key)) continue;
          for (var n = 1; n < e.key.length; n++) {
            final r = own[KeySeq(e.key.chords.take(n))];
            if (r != null) out.add(KeyConflict(area, e.key, r, ConflictKind.prefix));
          }
        }
      }
    }
    return out;
  }

  // ---- Merging ----

  /// This (partial) keymap applied over [base]: bindings per key, `-` removals, whole toolbars and menus per area,
  /// macros by name. The result is a full keymap named after this one.
  Keymap mergedOver(Keymap base) {
    final k = base.copy()..name = name;
    k._removed.clear();
    _removed.forEach((a, keys) {
      for (final s in keys) {
        k.unbind(a, s);
      }
    });
    _bindings.forEach((a, m) => m.forEach((s, r) => k.bind(a, s, r)));
    toolbars.forEach((a, l) => k.toolbars[a] = List.of(l));
    menus.forEach((a, l) => k.menus[a] = List.of(l));
    for (final m in macros.all) {
      k.macros.put(m);
    }
    return k;
  }

  // ---- File format ----

  /// Reads a keymap file (`kind: keymap`). Bad or unknown lines are skipped and listed in [warnings]; a missing or
  /// wrong header throws [FormatException].
  static Keymap parse(String text, {ActionRegistry? registry, List<String>? warnings}) {
    final warn = warnings ?? <String>[];
    final lines = text.split('\n');
    var i = 0;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length || lines[i].trim() != '---') throw const FormatException('A keymap starts with a --- header');
    i++;
    String? kind;
    var name = 'My keys';
    for (; i < lines.length && lines[i].trim() != '---'; i++) {
      final c = lines[i].indexOf(':');
      if (c < 0) continue;
      final key = lines[i].substring(0, c).trim();
      final value = lines[i].substring(c + 1).trim();
      if (key == 'kind') kind = value;
      if (key == 'name') name = value;
    }
    if (i >= lines.length) throw const FormatException('The keymap header is not closed with ---');
    if (kind != 'keymap') throw FormatException('Not a keymap (kind: ${kind ?? 'missing'})');
    final k = Keymap(name: name);

    void checkRef(ActionRef r, int lineNo) {
      if (registry != null && !r.isMacro && !registry.contains(r.id)) {
        warn.add('Line $lineNo: unknown action ${r.id}');
      }
    }

    bool other(String t, int lineNo) {
      final sp = t.indexOf(RegExp(r'\s'));
      if (sp < 0) return false;
      final first = t.substring(0, sp);
      final rest = t.substring(sp).trim();
      if (first == 'toolbar' || first == 'menu') {
        final sp2 = rest.indexOf(RegExp(r'\s'));
        final area = Area.parse(sp2 < 0 ? rest : rest.substring(0, sp2));
        if (area == null || sp2 < 0) {
          warn.add('Line $lineNo: expected "$first <area> <action>"');
          return true;
        }
        final target = first == 'toolbar' ? k.toolbars : k.menus;
        final list = target[area] ??= [];
        final item = rest.substring(sp2).trim();
        if (item == '-') return true;
        try {
          final r = ActionRef.parse(item);
          checkRef(r, lineNo);
          list.add(r);
        } on FormatException {
          warn.add('Line $lineNo: bad action "$item"');
        }
        return true;
      }
      final area = Area.parse(first);
      if (area == null) {
        warn.add('Line $lineNo: unknown area "$first"');
        return true;
      }
      String refText;
      String keysText;
      if (rest.endsWith('"') && rest.contains('macro "')) {
        final m = rest.lastIndexOf('macro "');
        refText = rest.substring(m);
        keysText = rest.substring(0, m);
      } else {
        final sp2 = rest.lastIndexOf(RegExp(r'\s'));
        if (sp2 < 0) {
          warn.add('Line $lineNo: expected "<area> <keys> <action>"');
          return true;
        }
        refText = rest.substring(sp2 + 1);
        keysText = rest.substring(0, sp2);
      }
      final keys = KeySeq.tryParse(keysText);
      if (keys == null) {
        warn.add('Line $lineNo: bad keys "${keysText.trim()}"');
        return true;
      }
      if (refText == '-') {
        k.unbind(area, keys, record: true);
        return true;
      }
      try {
        final r = ActionRef.parse(refText);
        checkRef(r, lineNo);
        final old = k._bindings[area]?[keys];
        if (old != null && old != r) {
          warn.add('Line $lineNo: ${keys.format()} in ${area.fileName} was ${old.format()}; now ${r.format()}');
        }
        k.bind(area, keys, r);
      } on FormatException {
        warn.add('Line $lineNo: bad action "$refText"');
      }
      return true;
    }

    MacroSet.parseBlocks(lines, i + 1, k.macros, warn, other: other);
    for (final m in k.macros.all) {
      for (final s in m.steps) {
        if (registry != null && !s.ref.isMacro && !registry.contains(s.ref.id)) {
          warn.add('Macro "${m.name}": unknown action ${s.ref.id}');
        }
      }
    }
    return k;
  }

  static String _row(String a, String b, String c) => '${a.padRight(11)} ${b.padRight(15)} $c'.trimRight();

  /// Writes the readable file. With [base], writes only what differs from it (a user keymap over the defaults).
  String serialize({Keymap? base}) {
    final out = ['---', 'kind: keymap', 'name: $name', '---', _row('# area', 'keys', 'action')];
    for (final area in Area.values) {
      final own = _bindings[area] ?? const <KeySeq, ActionRef>{};
      final from = base?._bindings[area] ?? const <KeySeq, ActionRef>{};
      for (final e in own.entries) {
        if (base != null && from[e.key] == e.value) continue;
        out.add(_row(area.fileName, e.key.format(), e.value.format()));
      }
      final removed = base == null ? (_removed[area] ?? const <KeySeq>{}) : from.keys.where((s) => !own.containsKey(s));
      for (final s in removed) {
        out.add(_row(area.fileName, s.format(), '-'));
      }
    }
    final lists = <String>[];
    for (final (word, mine, theirs) in [('toolbar', toolbars, base?.toolbars), ('menu', menus, base?.menus)]) {
      for (final area in Area.values) {
        final l = mine[area];
        if (l == null) continue;
        if (base != null && _sameList(l, theirs?[area] ?? const [])) continue;
        if (l.isEmpty) lists.add(_row(word, area.fileName, '-'));
        for (final r in l) {
          lists.add(_row(word, area.fileName, r.format()));
        }
      }
    }
    if (lists.isNotEmpty) out.addAll(['', '# toolbars and long-press menus, in order', ...lists]);
    for (final m in macros.all) {
      if (base != null && base.macros[m.name] == m) continue;
      out.addAll(['', m.format()]);
    }
    return '${out.join('\n')}\n';
  }

  static bool _sameList(List<ActionRef> a, List<ActionRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
