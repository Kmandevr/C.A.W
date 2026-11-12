// The which-key hint strip's contents: the keys that work in a keyboard-focus context, read from the keymap.
import 'actions.dart';
import 'keymap.dart';
import 'keys.dart';
import 'macro.dart' show ActionRef;
import 'vim.dart' show KeyHint;

/// Vim keys (Settings › Keys): H J K L act as the arrows in the keyboard-focus contexts ([Area.navigates]).
const Map<String, String> vimArrows = {'H': 'Left', 'J': 'Down', 'K': 'Up', 'L': 'Right'};

/// [chord] as the arrow it stands for under Vim keys, or null (any modifiers carry over: Alt+K is Alt+Up).
KeyChord? vimArrowFor(KeyChord chord) {
  final to = vimArrows[chord.key];
  if (to == null) return null;
  return KeyChord(to, ctrl: chord.ctrl, shift: chord.shift, alt: chord.alt, meta: chord.meta);
}

const _arrowGlyphs = {'Up': '↑', 'Down': '↓', 'Left': '←', 'Right': '→'};
const _vimLetter = {'Left': 'H', 'Down': 'J', 'Up': 'K', 'Right': 'L'};

/// A key as the strip shows it: arrows as ↑ ↓ ← →, the rest as in the keymap ("Ctrl+D", "Space").
String shortKey(KeySeq keys) => keys.chords.map((c) {
      final g = _arrowGlyphs[c.key];
      if (g == null) return c.format();
      return KeyChord(g, ctrl: c.ctrl, shift: c.shift, alt: c.alt, meta: c.meta).format();
    }).join(' ');

/// The hints for [area]: each of its actions with up to two of its keys (with [vimKeys], an arrow's H J K L letter
/// too), in catalogue order, then the area moves every context shares (Tab, Esc) and the full list (?). Rebinding a
/// key changes the strip, since it reads [keymap].
List<KeyHint> contextHints(ActionRegistry registry, Keymap keymap, Area area, {bool vimKeys = false}) {
  final out = <KeyHint>[];
  void add(Area a, ActionDef d) {
    final ref = ActionRef.action(d.id);
    // The area's own keys; a global action's only where the area doesn't take that key for something else.
    final keys = [
      for (final k in keymap.keysFor(a, ref))
        if (a == area || keymap.lookup(area, k) == ref) k
    ];
    if (keys.isEmpty) return;
    final shown = <String>[];
    for (final k in keys.take(2)) {
      shown.add(shortKey(k));
      final arrow = k.length == 1 ? _vimLetter[k.chords.single.key] : null;
      if (vimKeys && area.navigates && arrow != null) {
        final c = k.chords.single;
        final letter = KeySeq.one(KeyChord(arrow, ctrl: c.ctrl, shift: c.shift, alt: c.alt, meta: c.meta));
        // Only when the area doesn't bind that letter itself (it would win over the arrow).
        if (keymap.lookup(area, letter) == null) shown.add(letter.format());
      }
    }
    out.add(KeyHint(shown.join(' '), d.name));
  }

  for (final d in registry.inArea(area)) {
    add(area, d);
  }
  if (area != Area.menu) {
    for (final id in const ['focus.next', 'focus.out', 'view.actions']) {
      final d = registry[id];
      if (d != null) add(Area.global, d);
    }
  }
  return out;
}
