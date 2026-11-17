// Musical keys for the sample browser: parsing ("Am", "F# minor", "8A"), names, and the relative and compatible keys.

/// One of the 24 major and minor keys.
class MusicalKey {
  const MusicalKey(this.tonic, {this.minor = false}) : assert(tonic >= 0 && tonic < 12);

  /// Pitch class, 0 = C … 11 = B.
  final int tonic;
  final bool minor;

  static const _majorNames = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'];
  static const _minorNames = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'G#', 'A', 'Bb', 'B'];

  /// The tonic's usual spelling in this mode ("F#", "Bb").
  String get root => (minor ? _minorNames : _majorNames)[tonic];

  /// "Am", "C", "F#m".
  String get short => minor ? '${root}m' : root;

  /// "A minor", "C major".
  String get long => '$root ${minor ? 'minor' : 'major'}';

  /// The key-wheel (Camelot) code: 8A is A minor, 8B C major.
  String get camelot {
    // Camelot numbers step by fifths: C major is 8B, G major 9B, ...; A minor 8A.
    final major = minor ? (tonic + 3) % 12 : tonic;
    final n = ((major * 7) % 12 + 7) % 12 + 1;
    return '$n${minor ? 'A' : 'B'}';
  }

  /// A minor for C major and the other way round.
  MusicalKey get relative => minor ? MusicalKey((tonic + 3) % 12) : MusicalKey((tonic + 9) % 12, minor: true);

  /// The keys a DJ's key wheel calls compatible: this one, its relative, and the keys a fifth above and below in the
  /// same mode (neighbours on the wheel).
  List<MusicalKey> get compatible => [
        this,
        relative,
        MusicalKey((tonic + 7) % 12, minor: minor),
        MusicalKey((tonic + 5) % 12, minor: minor),
      ];

  /// A stable code for storage and filters: "9m" (A minor), "0" (C major).
  String get code => minor ? '${tonic}m' : '$tonic';

  static MusicalKey? fromCode(Object? code) {
    if (code is! String || code.isEmpty || code.length > 3) return null;
    final minor = code.endsWith('m');
    final t = int.tryParse(minor ? code.substring(0, code.length - 1) : code);
    return t == null || t < 0 || t > 11 ? null : MusicalKey(t, minor: minor);
  }

  @override
  bool operator ==(Object other) => other is MusicalKey && other.tonic == tonic && other.minor == minor;

  @override
  int get hashCode => tonic * 2 + (minor ? 1 : 0);

  @override
  String toString() => short;

  static const _letters = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};

  /// The pitch class of a note letter with an optional accidental ("F#", "Bb", "E♭"), or null.
  static int? pitchClass(String letter, [String accidental = '']) {
    final base = _letters[letter.toUpperCase()];
    if (base == null) return null;
    final shift = switch (accidental) {
      '' => 0,
      '#' || '♯' => 1,
      'b' || '♭' => -1,
      _ => null,
    };
    return shift == null ? null : (base + shift + 12) % 12;
  }

  static final _text = RegExp(r'^([A-Ga-g])\s*([#♯b♭]?)\s*(m|min|minor|maj|major|M|mi|ma)?$');
  static final _wheel = RegExp(r'^(1[0-2]|[1-9])\s*([ABab])$');
  static final _open = RegExp(r'^(1[0-2]|[1-9])\s*([mdMD])$');

  /// Reads a key as metadata writes it: "Am", "A minor", "F#m", "Gb", "C#maj", "Dbm" (ID3's TKEY), a key-wheel
  /// code ("8A", "12B") or Open Key ("1m", "1d"). "o" (off key) and anything else is null. Untrusted: at most 24
  /// characters are looked at.
  static MusicalKey? parse(String? text) {
    if (text == null) return null;
    final t = text.trim();
    if (t.isEmpty || t.length > 24) return null;
    final m = _text.firstMatch(t);
    if (m != null) {
      final pc = pitchClass(m.group(1)!, m.group(2) ?? '');
      if (pc == null) return null;
      final mode = m.group(3) ?? '';
      final minor = mode == 'm' || mode.toLowerCase().startsWith('min') || mode == 'mi';
      return MusicalKey(pc, minor: minor);
    }
    final w = _wheel.firstMatch(t);
    if (w != null) {
      final n = int.parse(w.group(1)!);
      final minor = w.group(2)!.toUpperCase() == 'A';
      // 8B = C major; each step is a fifth.
      final major = ((n - 8) * 7 % 12 + 12) % 12;
      return minor ? MusicalKey((major + 9) % 12, minor: true) : MusicalKey(major);
    }
    final o = _open.firstMatch(t);
    if (o != null) {
      // Open Key: 1d = C major, 1m = A minor, each step a fifth.
      final n = int.parse(o.group(1)!);
      final major = ((n - 1) * 7 % 12 + 12) % 12;
      return o.group(2)!.toLowerCase() == 'm' ? MusicalKey((major + 9) % 12, minor: true) : MusicalKey(major);
    }
    return null;
  }

  /// Every key, C major first, majors then minors.
  static final all = [for (var t = 0; t < 12; t++) MusicalKey(t), for (var t = 0; t < 12; t++) MusicalKey(t, minor: true)];
}
