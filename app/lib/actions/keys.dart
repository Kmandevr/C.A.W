// Key chords and key sequences as plain values: parse and format "Ctrl+Shift+W", "Alt+1", "Space", "X X".

/// One key press with its modifiers. [key] is canonical: letters upper case ("W"), digits and symbols as typed
/// ("3", "?", "@", "="), and named keys ("Space", "Enter", "Esc", "Up", "F10", "Menu"...).
///
/// A symbol that needs Shift on the keyboard ("?", "@", ":", "+") is stored without Shift, so "?" is the same
/// chord on every layout; letters, digits and named keys keep Shift ("Shift+A", "Shift+Tab").
class KeyChord {
  final String key;
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;

  const KeyChord(this.key, {this.ctrl = false, this.shift = false, this.alt = false, this.meta = false});

  /// Named keys in their canonical spelling.
  static const named = [
    'Space', 'Enter', 'Esc', 'Tab', 'Backspace', 'Delete', 'Insert', 'Home', 'End', 'PageUp', 'PageDown', //
    'Up', 'Down', 'Left', 'Right', 'Menu',
  ];

  static const _aliases = {
    'escape': 'Esc',
    'return': 'Enter',
    'del': 'Delete',
    'ins': 'Insert',
    'pgup': 'PageUp',
    'pgdn': 'PageDown',
    'pagedown': 'PageDown',
    'pageup': 'PageUp',
    'arrowup': 'Up',
    'arrowdown': 'Down',
    'arrowleft': 'Left',
    'arrowright': 'Right',
    '↑': 'Up',
    '↓': 'Down',
    '←': 'Left',
    '→': 'Right',
    'contextmenu': 'Menu',
    'apps': 'Menu',
    'plus': '+',
    'minus': '-',
  };

  /// The canonical spelling of a key name, or null if it isn't a key.
  static String? canonicalKey(String raw) {
    if (raw.isEmpty) return null;
    if (raw.length == 1) {
      final alias = _aliases[raw];
      if (alias != null) return alias;
      return raw.toUpperCase();
    }
    final lower = raw.toLowerCase();
    final alias = _aliases[lower];
    if (alias != null) return alias;
    for (final n in named) {
      if (n.toLowerCase() == lower) return n;
    }
    final f = RegExp(r'^f([1-9]|1[0-9]|2[0-4])$').firstMatch(lower);
    if (f != null) return 'F${f.group(1)}';
    return null;
  }

  /// Parses "Ctrl+Shift+W", "Alt+1", "?", "Ctrl++" or "Shift+F10". Throws [FormatException] on bad input.
  static KeyChord parse(String text) {
    final s = text.trim();
    String keyPart;
    String modPart;
    if (s == '+') {
      keyPart = '+';
      modPart = '';
    } else if (s.endsWith('++')) {
      keyPart = '+';
      modPart = s.substring(0, s.length - 2);
    } else {
      final i = s.lastIndexOf('+');
      keyPart = s.substring(i + 1);
      modPart = i < 0 ? '' : s.substring(0, i);
    }
    final key = canonicalKey(keyPart);
    if (key == null) throw FormatException('Unknown key "$keyPart"', text);
    var ctrl = false, shift = false, alt = false, meta = false;
    if (modPart.isNotEmpty) {
      for (final m in modPart.split('+')) {
        switch (m.trim().toLowerCase()) {
          case 'ctrl' || 'control':
            ctrl = true;
          case 'shift':
            shift = true;
          case 'alt' || 'option' || 'opt':
            alt = true;
          case 'meta' || 'cmd' || 'command' || 'super' || 'win':
            meta = true;
          default:
            throw FormatException('Unknown modifier "$m"', text);
        }
      }
    }
    return KeyChord(key, ctrl: ctrl, shift: shift, alt: alt, meta: meta);
  }

  static KeyChord? tryParse(String text) {
    try {
      return parse(text);
    } on FormatException {
      return null;
    }
  }

  /// No Ctrl, Alt or Meta held.
  bool get plain => !ctrl && !alt && !meta;

  /// The character this chord types in a text line, or null (letters are lower case unless Shift is held).
  String? get char {
    if (!plain) return null;
    if (key == 'Space') return ' ';
    if (key.length != 1) return null;
    final lower = key.toLowerCase();
    if (lower != key) return shift ? key : lower;
    return key;
  }

  /// A digit typed with no modifiers, or null.
  int? get digit {
    if (!plain || shift || key.length != 1) return null;
    final c = key.codeUnitAt(0) - 48;
    return c >= 0 && c <= 9 ? c : null;
  }

  String format() {
    final b = StringBuffer();
    if (ctrl) b.write('Ctrl+');
    if (shift) b.write('Shift+');
    if (alt) b.write('Alt+');
    if (meta) b.write('Meta+');
    b.write(key);
    return b.toString();
  }

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.key == key &&
      other.ctrl == ctrl &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, ctrl, shift, alt, meta);
}

/// One or more chords pressed in turn, written with spaces: "X X", "C I W", "Ctrl+Shift+E".
class KeySeq {
  final List<KeyChord> chords;

  KeySeq(Iterable<KeyChord> chords) : chords = List.unmodifiable(chords);
  KeySeq.one(KeyChord chord) : chords = List.unmodifiable([chord]);

  static KeySeq parse(String text) {
    final parts = text.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) throw FormatException('No keys', text);
    return KeySeq(parts.map(KeyChord.parse));
  }

  static KeySeq? tryParse(String text) {
    try {
      return parse(text);
    } on FormatException {
      return null;
    }
  }

  int get length => chords.length;

  /// True if [prefix] is this sequence or its start.
  bool startsWith(KeySeq prefix) {
    if (prefix.length > length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (chords[i] != prefix.chords[i]) return false;
    }
    return true;
  }

  KeySeq append(KeyChord chord) => KeySeq([...chords, chord]);

  String format() => chords.map((c) => c.format()).join(' ');

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) {
    if (other is! KeySeq || other.length != length) return false;
    for (var i = 0; i < length; i++) {
      if (other.chords[i] != chords[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(chords);
}
