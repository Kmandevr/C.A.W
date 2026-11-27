// Fractional keys: base-62 strings that order a list's children, with a key between any two neighbours.
import 'ids.dart';

/// Base-62 fractional keys. A key is read as a fraction 0.d1d2d3… in base 62, with the digits `0-9A-Za-z` in
/// ASCII order, so plain string comparison is numeric comparison. A key is never empty and never ends in `0`
/// (`V` and `V0` would be the same fraction with no key between them), so there is always room between two keys.
abstract final class FractionalKeys {
  static const String digits = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  static int _digit(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
    if (codeUnit >= 0x41 && codeUnit <= 0x5a) return codeUnit - 0x41 + 10;
    if (codeUnit >= 0x61 && codeUnit <= 0x7a) return codeUnit - 0x61 + 36;
    return -1;
  }

  /// Whether [key] is a well-formed key of at most [maxLength] characters.
  static bool isValid(String key, {int maxLength = 1024}) {
    if (key.isEmpty || key.length > maxLength) return false;
    for (var i = 0; i < key.length; i++) {
      if (_digit(key.codeUnitAt(i)) < 0) return false;
    }
    return key.codeUnitAt(key.length - 1) != 0x30;
  }

  /// A key strictly between [a] and [b]; a null [a] means "before everything", a null [b] "after everything".
  /// Throws [ArgumentError] when a key is malformed or [a] is not below [b].
  ///
  /// Appending (a null [b]) or prepending (a null [a]) again and again grows the key by one character about every
  /// 61 inserts. Inserting again and again at one gap between two fixed keys grows it about every 6 inserts, as any
  /// fractional index does.
  static String between(String? a, String? b) {
    if (a != null && !isValid(a, maxLength: 1 << 30)) throw ArgumentError.value(a, 'a', 'Not a fractional key');
    if (b != null && !isValid(b, maxLength: 1 << 30)) throw ArgumentError.value(b, 'b', 'Not a fractional key');
    if (a != null && b != null && a.compareTo(b) >= 0) throw ArgumentError('$a is not below $b');
    if (a == null && b == null) return 'V';
    if (b == null) return _after(a!);
    if (a == null) return _before(b);
    return _mid(a, b);
  }

  /// The host's tie-break when an insert's key equals a sibling's: [key] with [author]'s short id appended, so
  /// concurrent inserts at one position stay unique and ordered the same everywhere.
  ///
  /// Assumption: the short id's trailing `0`s are dropped (a key may not end in `0`), and an id left empty becomes
  /// `1`. The result sorts just after [key] and before any sibling that does not start with [key].
  static String withSuffix(String key, String author) {
    var s = AuthorIds.short(author);
    var end = s.length;
    while (end > 0 && s.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    s = end == 0 ? '1' : s.substring(0, end);
    return '$key$s';
  }

  // Increments the first digit that isn't `z`, dropping the rest; all `z`s get a `1` appended.
  static String _after(String a) {
    for (var i = 0; i < a.length; i++) {
      final d = _digit(a.codeUnitAt(i));
      if (d < 61) return '${a.substring(0, i)}${digits[d + 1]}';
    }
    return '${a}1';
  }

  // Decrements the first digit that isn't `0`; a key whose first non-`0` digit is its final `1` gets `0z` there.
  static String _before(String b) {
    for (var i = 0; i < b.length; i++) {
      final d = _digit(b.codeUnitAt(i));
      if (d == 0) continue;
      final prefix = b.substring(0, i);
      if (d > 1) return '$prefix${digits[d - 1]}';
      if (i < b.length - 1) return '${prefix}1';
      return '${prefix}0z';
    }
    throw StateError('unreachable: a valid key has a non-zero digit');
  }

  // A key between a and b (a < b, b not empty; a may be empty, meaning 0).
  static String _mid(String a, String b) {
    var n = 0;
    while (n < b.length && (n < a.length ? a.codeUnitAt(n) : 0x30) == b.codeUnitAt(n)) {
      n++;
    }
    final prefix = b.substring(0, n);
    final da = n < a.length ? _digit(a.codeUnitAt(n)) : 0;
    final db = _digit(b.codeUnitAt(n));
    if (db - da > 1) return '$prefix${digits[(da + db) >> 1]}';
    // Neighbouring digits: a proper prefix of b is below b and above a.
    if (b.length > n + 1) return '$prefix${digits[db]}';
    // b ends here: keep a's digit and go above the rest of a.
    final rest = n + 1 < a.length ? a.substring(n + 1) : '';
    return '$prefix${digits[da]}${rest.isEmpty ? 'V' : _after(rest)}';
  }
}
