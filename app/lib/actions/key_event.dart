// Converts a Flutter KeyEvent into a KeyChord, the only part of the actions code that knows about Flutter.
import 'package:flutter/services.dart';

import 'keys.dart';

final Map<LogicalKeyboardKey, String> _named = {
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.insert: 'Insert',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.arrowUp: 'Up',
  LogicalKeyboardKey.arrowDown: 'Down',
  LogicalKeyboardKey.arrowLeft: 'Left',
  LogicalKeyboardKey.arrowRight: 'Right',
  LogicalKeyboardKey.contextMenu: 'Menu',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
};

final Set<LogicalKeyboardKey> _modifiers = {
  LogicalKeyboardKey.shift, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight, //
  LogicalKeyboardKey.control, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.alt, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.meta, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.capsLock, LogicalKeyboardKey.numLock, LogicalKeyboardKey.fn,
};

/// The chord for a key-down or key-repeat event, or null for key-up and modifier-only presses.
/// Modifiers default to the hardware keyboard's state; pass them to override (tests). [metaAsCtrl] lets
/// Cmd act as Ctrl on macOS.
KeyChord? keyChordFromEvent(KeyEvent event, {bool? ctrl, bool? shift, bool? alt, bool? meta, bool metaAsCtrl = false}) {
  if (event is KeyUpEvent) return null;
  final logical = event.logicalKey;
  if (_modifiers.contains(logical)) return null;
  var c = ctrl ?? HardwareKeyboard.instance.isControlPressed;
  final s = shift ?? HardwareKeyboard.instance.isShiftPressed;
  final a = alt ?? HardwareKeyboard.instance.isAltPressed;
  var m = meta ?? HardwareKeyboard.instance.isMetaPressed;
  if (metaAsCtrl && m) {
    c = true;
    m = false;
  }
  final name = _named[logical];
  if (name != null) return KeyChord(name, ctrl: c, shift: s, alt: a, meta: m);
  final label = logical.keyLabel;
  final isLetter = label.length == 1 && label.toUpperCase() != label.toLowerCase();
  final isDigit = label.length == 1 && label.codeUnitAt(0) >= 48 && label.codeUnitAt(0) <= 57;
  final typed = event.character;
  // Without Ctrl/Alt/Meta a shifted symbol is taken as typed ("@", "?", ":"), so it works on any layout.
  if (!c && !a && !m && typed != null && typed.length == 1 && typed.codeUnitAt(0) >= 0x21 && !isLetter) {
    if (!(isDigit && !s)) return KeyChord(typed);
  }
  if (label.length == 1) return KeyChord(label.toUpperCase(), ctrl: c, shift: s, alt: a, meta: m);
  return null;
}
