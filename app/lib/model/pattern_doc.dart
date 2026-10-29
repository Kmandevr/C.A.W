// Pattern text as an editable model: exact step times, notes and chords, edits, and write-back that keeps comments.
//
// The text format is the engine's (`engine/src/pattern.cpp`, docs/engine.md "Patterns"); parse() mirrors its rules and
// error messages. Design choices:
// - Times are exact rationals ([Steps]), so triplets such as 13/3 survive any number of edits.
// - A [PatternDoc] is immutable: every edit returns a new doc (cheap: one list of immutable notes, while the header
//   and the parsed source are shared), so undo is a list of earlier docs. Unchanged notes are the same objects in
//   every copy. Edits never re-parse or re-serialize: the doc is the source of truth while editing, and serialize()
//   runs only when saving or syncing to the engine (light on low-end devices).
// - serialize() writes a note line exactly as it was read while its notes are unchanged; only changed or new lines are
//   reformatted, in the column layout of the file's first note line. Lines come out in time order (stable).
// - Comment and blank lines above the first note stay at the top of the body. Every other comment line is anchored
//   above the note line that followed it, moves with that line's first note, and falls through to the next surviving
//   line when its own line's notes are all deleted (or to the end of the file).
// - A trailing comment belongs to the first note of its line.
import 'dart:math' as math;

/// The engine's limits (engine/src/pattern.h).
const int kPatternMaxSteps = 4096;
const int kPatternMaxNotes = 4096;
const int kPatternMaxRatchet = 8;

/// The shortest note an edit makes: 1/32 of a step (1/512 bar in 4/4).
final Steps kMinNoteLength = Steps(1, 32);

/// An exact, normalised rational number of 16th steps.
class Steps implements Comparable<Steps> {
  factory Steps(int numerator, [int denominator = 1]) {
    if (denominator == 0) throw ArgumentError.value(denominator, 'denominator', 'must not be 0');
    if (denominator < 0) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final g = _gcd(numerator.abs(), denominator);
    return Steps._(numerator ~/ g, denominator ~/ g);
  }

  const Steps._(this.numerator, this.denominator);

  static const zero = Steps._(0, 1);
  static const one = Steps._(1, 1);

  final int numerator, denominator;

  static final _decimal = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$');

  /// Parses the engine's spellings: `4`, `4.5`, `.5`, `13/3`, `4.5/2`; null if it isn't a finite number.
  static Steps? tryParse(String s) {
    final slash = s.indexOf('/');
    if (slash >= 0) {
      final a = tryParse(s.substring(0, slash)), b = tryParse(s.substring(slash + 1));
      if (a == null || b == null || b.numerator == 0) return null;
      return a / b;
    }
    final m = _decimal.firstMatch(s);
    if (m != null) {
      final whole = m.group(2)!, frac = m.group(3) ?? '';
      if (whole.isEmpty && frac.isEmpty) return null;
      if (whole.length + frac.length <= 15) {
        final n = int.parse('0$whole$frac');
        return Steps(m.group(1) == '-' ? -n : n, math.pow(10, frac.length).toInt());
      }
    }
    final v = double.tryParse(s);
    if (v == null || !v.isFinite) return null;
    return Steps.fromDouble(v);
  }

  /// The closest fraction with a denominator up to [maxDenominator].
  static Steps fromDouble(double v, {int maxDenominator = 1 << 20}) {
    if (!v.isFinite) throw ArgumentError.value(v, 'v', 'must be finite');
    final x = v.abs();
    var h0 = 0, h1 = 1, k0 = 1, k1 = 0;
    var f = x;
    for (var i = 0; i < 64; i++) {
      final a = f.floor();
      final h2 = a * h1 + h0, k2 = a * k1 + k0;
      if (k2 > maxDenominator) break;
      h0 = h1;
      h1 = h2;
      k0 = k1;
      k1 = k2;
      final r = f - a;
      if (r < 1e-12 || (h1 / k1 - x).abs() < 1e-15 * math.max(1, x)) break;
      f = 1 / r;
    }
    if (k1 == 0) return Steps(v.round());
    return Steps(v < 0 ? -h1 : h1, k1);
  }

  double toDouble() => numerator / denominator;
  bool get isInteger => denominator == 1;

  Steps operator +(Steps o) =>
      Steps(numerator * o.denominator + o.numerator * denominator, denominator * o.denominator);
  Steps operator -(Steps o) =>
      Steps(numerator * o.denominator - o.numerator * denominator, denominator * o.denominator);
  Steps operator *(Steps o) => Steps(numerator * o.numerator, denominator * o.denominator);
  Steps operator /(Steps o) => Steps(numerator * o.denominator, denominator * o.numerator);
  Steps operator -() => Steps._(-numerator, denominator);
  Steps times(int k) => Steps(numerator * k, denominator);

  bool operator <(Steps o) => compareTo(o) < 0;
  bool operator <=(Steps o) => compareTo(o) <= 0;
  bool operator >(Steps o) => compareTo(o) > 0;
  bool operator >=(Steps o) => compareTo(o) >= 0;

  @override
  int compareTo(Steps o) => (numerator * o.denominator).compareTo(o.numerator * denominator);

  @override
  bool operator ==(Object other) => other is Steps && other.numerator == numerator && other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  int floor() => (numerator - numerator % denominator) ~/ denominator;
  int ceil() => -Steps._(-numerator, denominator).floor();

  /// The nearest multiple of [grid] (halves round up).
  Steps roundTo(Steps grid) => grid.times((this / grid + Steps(1, 2)).floor());

  /// The multiple of [grid] at or below this.
  Steps floorTo(Steps grid) => grid.times((this / grid).floor());

  Steps clamp(Steps lo, Steps hi) => this < lo ? lo : (this > hi ? hi : this);

  static Steps max(Steps a, Steps b) => a >= b ? a : b;
  static Steps min(Steps a, Steps b) => a <= b ? a : b;

  /// Integers plainly (`4`); short exact decimals (`4.5`, `0.125`); other fractions up to /64 as `13/3`; exact
  /// decimals up to 9 places; anything else rounded to 1/1000.
  @override
  String toString() {
    if (denominator == 1) return '$numerator';
    if (1000 % denominator == 0) return _decimalString(3);
    if (denominator <= 64) return '$numerator/$denominator';
    if (1000000000 % denominator == 0) return _decimalString(9);
    return _trimZeros(toDouble().toStringAsFixed(3));
  }

  String _decimalString(int places) {
    final scale = math.pow(10, places).toInt();
    final scaled = numerator * (scale ~/ denominator);
    final sign = scaled < 0 ? '-' : '';
    final a = scaled.abs();
    return _trimZeros('$sign${a ~/ scale}.${(a % scale).toString().padLeft(places, '0')}');
  }
}

int _gcd(int a, int b) {
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return a == 0 ? 1 : a;
}

String _trimZeros(String s) {
  if (!s.contains('.')) return s;
  s = s.replaceFirst(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s == '-0' ? '0' : s;
}

const List<String> _noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// A note name (`A1`, `F#3`, `Bb2`) as a MIDI number, by the engine's rule (compile.cpp noteNumber); null if not one.
double? noteNumber(String s) {
  if (s.length < 2) return null;
  const base = [9, 11, 0, 2, 4, 5, 7]; // A..G
  final c = s.codeUnitAt(0) - 0x41;
  if (c < 0 || c > 6) return null;
  var n = base[c];
  var i = 1;
  if (s[i] == '#') {
    n++;
    i++;
  } else if (s[i] == 'b') {
    n--;
    i++;
  }
  if (i + 1 != s.length) return null;
  final d = s.codeUnitAt(i) - 0x30;
  if (d < 0 || d > 9) return null;
  return ((d + 1) * 12 + n).toDouble();
}

/// A number written minimally: `1`, `0.8`, `0.333`.
String formatNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return v.toString();
}

/// A pitch as the engine reads it: sharps names for whole notes 12..127 (C0..G9), else a number, microtones as a
/// short decimal or an exact fraction (`181/3`) when one up to /64 matches.
String formatPitch(double p) {
  if (p == p.roundToDouble()) {
    final n = p.toInt();
    if (n >= 12 && n <= 127) return '${_noteNames[n % 12]}${n ~/ 12 - 1}';
    return '$n';
  }
  final s = p.toString();
  final dot = s.indexOf('.');
  if (!s.contains('e') && dot >= 0 && s.length - dot - 1 <= 4) return s;
  for (var den = 2; den <= 64; den++) {
    final r = (p * den).round();
    if (r / den == p) return '$r/$den';
  }
  return s;
}

const Object _keep = Object();

/// One note. A chord line becomes one note per pitch with the same [line].
class PatternNote {
  const PatternNote({
    required this.id,
    required this.at,
    required this.len,
    required this.pitch,
    this.vel = 1,
    this.prob = 1,
    this.ratchet = 1,
    this.slide = false,
    this.trailingComment,
    this.line,
  });

  final int id; // stable for the doc's life; never reused
  final Steps at, len; // 16th steps
  final double pitch; // MIDI number, fractions are microtones
  final double vel, prob; // 0..1
  final int ratchet; // 1..8
  final bool slide;
  final String? trailingComment; // the text after `//` on the note's line, trimmed; only on a line's first note
  final int? line; // the source line it was read from; null for notes made by edits

  Steps get end => at + len;

  PatternNote copyWith({
    int? id,
    Steps? at,
    Steps? len,
    double? pitch,
    double? vel,
    double? prob,
    int? ratchet,
    bool? slide,
    Object? trailingComment = _keep,
    Object? line = _keep,
  }) =>
      PatternNote(
        id: id ?? this.id,
        at: at ?? this.at,
        len: len ?? this.len,
        pitch: pitch ?? this.pitch,
        vel: vel ?? this.vel,
        prob: prob ?? this.prob,
        ratchet: ratchet ?? this.ratchet,
        slide: slide ?? this.slide,
        trailingComment: identical(trailingComment, _keep) ? this.trailingComment : trailingComment as String?,
        line: identical(line, _keep) ? this.line : line as int?,
      );

  /// Same start, length, velocity and extras: notes that can share one chord line.
  bool sameShape(PatternNote o) =>
      at == o.at && len == o.len && vel == o.vel && prob == o.prob && ratchet == o.ratchet && slide == o.slide;

  /// Same musical content and comment, ignoring [id] and [line].
  bool sameAs(PatternNote o) => sameShape(o) && pitch == o.pitch && trailingComment == o.trailingComment;

  @override
  String toString() =>
      'PatternNote($id: $at ${formatPitch(pitch)} $len vel ${formatNumber(vel)}${prob != 1 ? ' prob $prob' : ''}'
      '${ratchet != 1 ? ' ratchet $ratchet' : ''}${slide ? ' slide' : ''}${trailingComment != null ? ' // $trailingComment' : ''})';
}

/// Notes cut or copied, with starts relative to the earliest one.
class PatternClip {
  const PatternClip(this.notes, this.span);

  final List<PatternNote> notes;
  final Steps span; // from the earliest start to the latest end

  bool get isEmpty => notes.isEmpty;
}

/// The result of [PatternDoc.parse]: a doc, or an error with its line and column (1-based).
class PatternParse {
  const PatternParse._(this.doc, this.error, this.line, this.col);

  final PatternDoc? doc;
  final String? error; // `line L, col C: message`, as the engine words it
  final int line, col;

  bool get ok => doc != null;
}

class _PatternError {
  _PatternError(this.line, this.col, this.message);

  final int line, col;
  final String message;
}

class _Word {
  _Word(this.text, this.col);

  final String text;
  final int col; // 1-based
}

bool _isSpace(int c) => c == 32 || (c >= 9 && c <= 13);

String _trim(String s) {
  var a = 0, b = s.length;
  while (a < b && _isSpace(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && _isSpace(s.codeUnitAt(b - 1))) {
    b--;
  }
  return s.substring(a, b);
}

List<_Word> _words(String line) {
  final out = <_Word>[];
  var i = 0;
  while (i < line.length) {
    while (i < line.length && _isSpace(line.codeUnitAt(i))) {
      i++;
    }
    if (i >= line.length) break;
    final start = i;
    while (i < line.length && !_isSpace(line.codeUnitAt(i))) {
      i++;
    }
    out.add(_Word(line.substring(start, i), start + 1));
  }
  return out;
}

// The engine's plain number: a decimal, or a fraction of two numbers.
double? _number(String s) {
  final slash = s.indexOf('/');
  if (slash >= 0) {
    final a = _number(s.substring(0, slash)), b = _number(s.substring(slash + 1));
    if (a == null || b == null || b == 0) return null;
    return a / b;
  }
  if (s.isEmpty || _isSpace(s.codeUnitAt(0)) || _isSpace(s.codeUnitAt(s.length - 1))) return null;
  final v = double.tryParse(s);
  return v != null && v.isFinite ? v : null;
}

double _needNumber(_Word w, int line, String what, double lo, double hi, String range) {
  final v = _number(w.text);
  if (v == null) throw _PatternError(line, w.col, "expected $what, found '${w.text}'");
  if (v < lo || v > hi) throw _PatternError(line, w.col, '$what must be $range');
  return v;
}

Steps _needSteps(_Word w, int line, String what, double lo, String range) {
  final v = Steps.tryParse(w.text);
  if (v == null) throw _PatternError(line, w.col, "expected $what, found '${w.text}'");
  final d = v.toDouble();
  if (d < lo || d > kPatternMaxSteps) throw _PatternError(line, w.col, '$what must be $range');
  return v;
}

// What one parse shares with every doc edited from it.
class _Source {
  _Source();

  String open = '---', close = '---';
  final List<String> top = []; // comment and blank lines above the first note line
  final Map<int, List<String>> anchored = {}; // comment lines above note line N
  final List<int> order = []; // note lines in source order
  final List<String> tail = []; // lines after the last note line
  final Map<int, String> lineText = {}; // note line N as written
  final Map<int, String> lineSig = {}; // what note line N held, to tell when it is unchanged
  int indent = 0;
  List<int> widths = [7, 11, 5, 5]; // at, notes, len and vel columns
  bool endsWithNewline = true;
}

/// A pattern module's text as notes. Immutable: edits return a new doc.
class PatternDoc {
  PatternDoc._(this.header, this.notes, this._nextId, this._src);

  /// The lines between the header's `---` lines, as written.
  final List<String> header;

  /// The notes in written order (a chord's notes in the order they were written); serialize() sorts by time.
  final List<PatternNote> notes;

  final int _nextId;
  final _Source _src;

  /// A new pattern with no notes.
  static PatternDoc blank({String name = 'Pattern', int? steps, int? bars}) {
    final doc = parse('---\ncaw: 1\nkind: pattern\nname: Pattern\n---\n// at  note(s)  len  vel  extras\n').doc!;
    return doc.setName(name).setLength(steps: steps, bars: bars);
  }

  /// Reads pattern text by the engine's rules. User errors come back in the result, never as exceptions.
  static PatternParse parse(String source) {
    try {
      return PatternParse._(_parse(source), null, 0, 0);
    } on _PatternError catch (e) {
      return PatternParse._(null, 'line ${e.line}, col ${e.col}: ${e.message}', e.line, e.col);
    }
  }

  static PatternDoc _parse(String source) {
    final src = _Source();
    final lines = source.split('\n');
    src.endsWithNewline = source.endsWith('\n');
    if (src.endsWithNewline) lines.removeLast();
    final header = <String>[];
    var isPattern = false;
    var bodyStart = 0;
    if (lines.isNotEmpty && _trim(lines[0]) == '---') {
      src.open = lines[0];
      var i = 1;
      for (;; i++) {
        if (i >= lines.length) throw _PatternError(1, 1, "header starts with '---' but never ends with '---'");
        final raw = lines[i];
        if (_trim(raw) == '---') break;
        header.add(raw);
        final h = _headerEntry(raw);
        if (h == null) continue;
        final lineNo = i + 1;
        if (h.key == null) throw _PatternError(lineNo, 1, "header lines look like 'key: value'");
        if (h.key == 'caw' && h.value != '1') throw _PatternError(lineNo, 1, 'this app reads module format 1');
        if (h.key == 'kind') isPattern = h.value == 'pattern';
        if (h.key == 'length') _parseLength(raw, h.value, lineNo);
      }
      src.close = lines[i];
      bodyStart = i + 1;
    }
    if (!isPattern) throw _PatternError(1, 1, "a pattern's header needs 'kind: pattern'");

    final notes = <PatternNote>[];
    var pending = <String>[];
    var id = 1;
    for (var i = bodyStart; i < lines.length; i++) {
      final raw = lines[i], lineNo = i + 1;
      final cut = raw.indexOf('//');
      final w = _words(cut >= 0 ? raw.substring(0, cut) : raw);
      if (w.isEmpty) {
        pending.add(raw);
        continue;
      }
      if (w[0].text.startsWith('[')) {
        throw _PatternError(lineNo, w[0].col, "kit rows ([kick] and so on) aren't supported yet");
      }
      if (w.length < 3) {
        throw _PatternError(lineNo, w[0].col, 'a note line is: at  note  length  [velocity]  [extras]');
      }
      final at = _needSteps(w[0], lineNo, 'the start (in steps)', 0, '0 to 4096');
      final chord = _pitches(w[1], lineNo);
      final len = _needSteps(w[2], lineNo, 'the length (in steps)', 1e-3, '0.001 to 4096');
      var vel = 1.0, prob = 1.0, ratchet = 1, slide = false;
      var k = 3;
      if (k < w.length && _number(w[k].text) != null) vel = _needNumber(w[k++], lineNo, 'velocity', 0, 1, '0 to 1');
      while (k < w.length) {
        final x = w[k++];
        if (x.text == 'slide') {
          slide = true;
        } else if (x.text == 'prob' || x.text == 'ratchet') {
          if (k >= w.length) throw _PatternError(lineNo, x.col, "'${x.text}' needs a number after it");
          if (x.text == 'prob') {
            prob = _needNumber(w[k++], lineNo, 'prob', 0, 1, '0 to 1');
          } else {
            final rv = _needNumber(w[k], lineNo, 'ratchet', 1, kPatternMaxRatchet.toDouble(), '1 to 8');
            if (rv != rv.floorToDouble()) throw _PatternError(lineNo, w[k].col, 'ratchet must be a whole number');
            ratchet = rv.toInt();
            k++;
          }
        } else {
          throw _PatternError(lineNo, x.col, "unknown extra '${x.text}' (try prob 0.5, ratchet 3 or slide)");
        }
      }
      final comment = cut >= 0 ? _trim(raw.substring(cut + 2)) : null;
      final group = <PatternNote>[];
      for (final pitch in chord) {
        if (notes.length >= kPatternMaxNotes) {
          throw _PatternError(lineNo, w[0].col, 'a pattern holds at most 4096 notes');
        }
        final n = PatternNote(
          id: id++,
          at: at,
          len: len,
          pitch: pitch,
          vel: vel,
          prob: prob,
          ratchet: ratchet,
          slide: slide,
          trailingComment: group.isEmpty ? comment : null,
          line: lineNo,
        );
        group.add(n);
        notes.add(n);
      }
      if (src.order.isEmpty) {
        src.top.addAll(pending);
        src.indent = w[0].col - 1;
        for (var c = 0; c < 4 && c + 1 < w.length; c++) {
          src.widths[c] = w[c + 1].col - w[c].col;
        }
      } else if (pending.isNotEmpty) {
        src.anchored[lineNo] = pending;
      }
      pending = <String>[];
      src.order.add(lineNo);
      src.lineText[lineNo] = raw;
      src.lineSig[lineNo] = _sig(group);
    }
    src.tail.addAll(pending);
    return PatternDoc._(List.unmodifiable(header), List.unmodifiable(notes), id, src);
  }

  static List<double> _pitches(_Word w, int line) {
    final out = <double>[];
    var start = 0;
    while (start <= w.text.length) {
      var comma = w.text.indexOf(',', start);
      if (comma < 0) comma = w.text.length;
      final part = w.text.substring(start, comma);
      final v = noteNumber(part) ?? _number(part);
      if (v == null) throw _PatternError(line, w.col + start, "expected a note such as C3, F#2 or 48, found '$part'");
      if (v < 0 || v > 127) throw _PatternError(line, w.col + start, 'notes must be 0 to 127');
      out.add(v);
      start = comma + 1;
    }
    return out;
  }

  // Returns (steps, bars), one of them 0.
  static (int, int) _parseLength(String raw, String value, int lineNo) {
    final w = _words(value);
    final col = raw.indexOf(value) + 1;
    final bars = w.length == 2 && (w[1].text == 'bars' || w[1].text == 'bar');
    if (w.isEmpty || w.length > 2 || (w.length == 2 && !bars)) {
      throw _PatternError(lineNo, col, 'length is a number of steps (16) or bars (4 bars)');
    }
    final n = _needNumber(
        w[0], lineNo, 'length', 1, bars ? 256 : kPatternMaxSteps.toDouble(), bars ? '1 to 256' : '1 to 4096');
    if (n != n.floorToDouble()) throw _PatternError(lineNo, col, 'length must be a whole number');
    return bars ? (0, n.toInt()) : (n.toInt(), 0);
  }

  // A header line as key and value after the engine strips `#` comments; null for an empty line, key null without ':'.
  static ({String? key, String value})? _headerEntry(String raw) {
    var l = _trim(raw);
    final hash = l.indexOf('#');
    if (hash >= 0) l = _trim(l.substring(0, hash));
    if (l.isEmpty) return null;
    final colon = l.indexOf(':');
    if (colon < 0) return (key: null, value: l);
    return (key: _trim(l.substring(0, colon)), value: _trim(l.substring(colon + 1)));
  }

  String? _headerValue(String key) {
    String? v;
    for (final raw in header) {
      final h = _headerEntry(raw);
      if (h != null && h.key == key) v = h.value;
    }
    return v;
  }

  // Header accessors.

  String get name => _headerValue('name') ?? '';
  String get summary => _headerValue('summary') ?? '';

  /// `length: N` in the header, else null.
  int? get headerSteps => _headerLength(false);

  /// `length: N bars` in the header, else null.
  int? get headerBars => _headerLength(true);

  int? _headerLength(bool bars) {
    for (final raw in header.reversed) {
      final h = _headerEntry(raw);
      if (h == null || h.key != 'length') continue;
      try {
        final (s, b) = _parseLength(raw, h.value, 0);
        return bars ? (b > 0 ? b : null) : (s > 0 ? s : null);
      } on _PatternError {
        return null;
      }
    }
    return null;
  }

  /// The loop length in steps, by the engine's rule: the header's length, else the whole bars that cover the notes.
  int lengthSteps(int beatsPerBar) {
    final bar = math.max(1, beatsPerBar) * 4;
    var s = headerSteps ?? 0;
    final b = headerBars ?? 0;
    if (b > 0) s = b * bar;
    if (s <= 0) s = math.max(1, (lastEnd / Steps(bar)).ceil()) * bar;
    return math.min(s, kPatternMaxSteps);
  }

  /// Where the last note ends.
  Steps get lastEnd => notes.fold(Steps.zero, (m, n) => Steps.max(m, n.end));

  /// Rewrites the `name:` line (or adds one after `kind:`). `#` and line breaks are dropped: the engine would cut them.
  PatternDoc setName(String value) =>
      _setHeader('name', value.replaceAll(RegExp(r'[#\r\n]'), '').trim(), const ['caw', 'kind']);

  /// Rewrites the `length:` line as steps or bars (or adds it); both null removes it, so the notes decide.
  PatternDoc setLength({int? steps, int? bars}) {
    if (steps != null && bars != null) throw ArgumentError('give steps or bars, not both');
    if (steps != null && (steps < 1 || steps > kPatternMaxSteps)) throw RangeError.range(steps, 1, kPatternMaxSteps);
    if (bars != null && (bars < 1 || bars > 256)) throw RangeError.range(bars, 1, 256);
    final value = steps != null ? '$steps' : (bars != null ? (bars == 1 ? '1 bar' : '$bars bars') : null);
    return _setHeader('length', value, const ['caw', 'kind', 'name', 'summary']);
  }

  PatternDoc _setHeader(String key, String? value, List<String> after) {
    int indexOf(List<String> lines, String k) {
      for (var i = lines.length - 1; i >= 0; i--) {
        if (_headerEntry(lines[i])?.key == k) return i;
      }
      return -1;
    }

    final lines = [...header];
    final i = indexOf(lines, key);
    if (i >= 0) {
      if (value == null) {
        lines.removeAt(i);
      } else {
        // Keep the key's spelling and anything after the value (spacing and a `#` comment).
        final raw = lines[i];
        final colon = raw.indexOf(':');
        final rest = raw.substring(colon + 1);
        final hash = rest.indexOf('#');
        final valuePart = hash >= 0 ? rest.substring(0, hash) : rest;
        final valueEnd = colon + 1 + valuePart.trimRight().length;
        final tail = valuePart.trim().isEmpty ? (hash >= 0 ? ' ${rest.substring(hash)}' : '') : raw.substring(valueEnd);
        lines[i] = '${raw.substring(0, colon + 1)} $value$tail';
      }
    } else if (value != null) {
      var at = lines.length;
      var found = -1;
      for (final k in after) {
        found = math.max(found, indexOf(lines, k));
      }
      if (found >= 0) at = found + 1;
      lines.insert(at, '$key: $value');
    }
    return PatternDoc._(List.unmodifiable(lines), notes, _nextId, _src);
  }

  // Writing.

  static String _sig(List<PatternNote> g) {
    final a = g.first;
    final c = g.map((n) => n.trailingComment).firstWhere((c) => c != null, orElse: () => null);
    return '${a.at.numerator}/${a.at.denominator} ${a.len.numerator}/${a.len.denominator} ${a.vel} ${a.prob} '
        '${a.ratchet} ${a.slide} ${g.map((n) => n.pitch).join(',')} ${c == null ? '-' : '// $c'}';
  }

  /// The notes sorted by start, stable (a chord keeps its written order).
  List<PatternNote> get sortedNotes {
    final idx = List.generate(notes.length, (i) => i);
    idx.sort((a, b) {
      final c = notes[a].at.compareTo(notes[b].at);
      return c != 0 ? c : a - b;
    });
    return [for (final i in idx) notes[i]];
  }

  /// The pattern as text: header and comments kept, unchanged note lines as written, others rewritten.
  String serialize() {
    // Group notes into lines: consecutive notes (by time) with the same shape and at most one trailing comment.
    final groups = <List<PatternNote>>[];
    String? groupComment;
    for (final n in sortedNotes) {
      final g = groups.isEmpty ? null : groups.last;
      if (g != null &&
          g.first.sameShape(n) &&
          (n.trailingComment == null || groupComment == null || n.trailingComment == groupComment)) {
        g.add(n);
        groupComment ??= n.trailingComment;
      } else {
        groups.add([n]);
        groupComment = n.trailingComment;
      }
    }
    // Comments anchored to a line with no notes left fall through to the next surviving line.
    final alive = {
      for (final n in notes)
        if (n.line != null) n.line!
    };
    final before = <int, List<String>>{};
    var carry = <String>[];
    for (final l in _src.order) {
      carry.addAll(_src.anchored[l] ?? const []);
      if (alive.contains(l)) {
        before[l] = carry;
        carry = <String>[];
      }
    }
    final out = <String>[_src.open, ...header, _src.close, ..._src.top];
    for (final g in groups) {
      for (final n in g) {
        final c = n.line == null ? null : before.remove(n.line);
        if (c != null) out.addAll(c);
      }
      final l = g.first.line;
      final verbatim = l != null && g.every((n) => n.line == l) && _src.lineSig[l] == _sig(g);
      out.add(verbatim ? _src.lineText[l]! : _format(g));
    }
    out
      ..addAll(carry)
      ..addAll(_src.tail);
    final text = out.join('\n');
    return _src.endsWithNewline ? '$text\n' : text;
  }

  String _format(List<PatternNote> g) {
    final a = g.first;
    final fields = [
      a.at.toString(),
      g.map((n) => formatPitch(n.pitch)).join(','),
      a.len.toString(),
      formatNumber(a.vel)
    ];
    final extras = [
      if (a.ratchet != 1) 'ratchet ${a.ratchet}',
      if (a.prob != 1) 'prob ${formatNumber(a.prob)}',
      if (a.slide) 'slide',
    ];
    final comment = g.map((n) => n.trailingComment).firstWhere((c) => c != null, orElse: () => null);
    final b = StringBuffer(' ' * _src.indent);
    for (var i = 0; i < fields.length; i++) {
      final last = i == fields.length - 1 && extras.isEmpty;
      b.write(last ? fields[i] : fields[i].padRight(math.max(_src.widths[i], fields[i].length + 2)));
    }
    b.write(extras.join('  '));
    if (comment != null) b.write(comment.isEmpty ? '  //' : '  // $comment');
    return b.toString();
  }

  // Edits. Each returns a new doc; ids of untouched notes never change.

  PatternDoc _withNotes(List<PatternNote> notes, [int? nextId]) =>
      PatternDoc._(header, List.unmodifiable(notes), nextId ?? _nextId, _src);

  PatternDoc _map(Set<int> sel, PatternNote Function(PatternNote n) f) =>
      sel.isEmpty ? this : _withNotes([for (final n in notes) sel.contains(n.id) ? f(n) : n]);

  List<PatternNote> _selected(Set<int> sel) => [
        for (final n in notes)
          if (sel.contains(n.id)) n
      ];

  PatternNote? byId(int id) {
    for (final n in notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  static double _round3(double v) => (v * 1000).round() / 1000;

  /// Adds a note (start, pitch and length clamped to the engine's ranges); id null when the pattern is full.
  ({PatternDoc doc, int? id}) insert(Steps at, double pitch, Steps len, {double vel = 1}) {
    if (notes.length >= kPatternMaxNotes) return (doc: this, id: null);
    final n = PatternNote(
      id: _nextId,
      at: at.clamp(Steps.zero, Steps(kPatternMaxSteps)),
      len: len.clamp(kMinNoteLength, Steps(kPatternMaxSteps)),
      pitch: pitch.clamp(0, 127).toDouble(),
      vel: _round3(vel.clamp(0, 1).toDouble()),
    );
    return (doc: _withNotes([...notes, n], _nextId + 1), id: n.id);
  }

  PatternDoc delete(Set<int> sel) => sel.isEmpty
      ? this
      : _withNotes([
          for (final n in notes)
            if (!sel.contains(n.id)) n
        ]);

  /// Moves the selection as a block; the deltas are clamped so every note stays at 0..4096 steps and pitch 0..127.
  PatternDoc move(Set<int> sel, Steps dTime, double dPitch) {
    final s = _selected(sel);
    if (s.isEmpty) return this;
    var minAt = s.first.at, maxAt = s.first.at;
    var lo = s.first.pitch, hi = s.first.pitch;
    for (final n in s) {
      minAt = Steps.min(minAt, n.at);
      maxAt = Steps.max(maxAt, n.at);
      lo = math.min(lo, n.pitch);
      hi = math.max(hi, n.pitch);
    }
    final dt = dTime.clamp(-minAt, Steps(kPatternMaxSteps) - maxAt);
    final dp = dPitch.clamp(-lo, 127 - hi).toDouble();
    return _map(sel, (n) => n.copyWith(at: n.at + dt, pitch: n.pitch + dp));
  }

  /// Changes lengths by [dLen], each at least [kMinNoteLength] (1/32 step) and at most 4096.
  PatternDoc resize(Set<int> sel, Steps dLen) =>
      _map(sel, (n) => n.copyWith(len: (n.len + dLen).clamp(kMinNoteLength, Steps(kPatternMaxSteps))));

  /// Sets lengths exactly (clamped like [resize]).
  PatternDoc setNoteLength(Set<int> sel, Steps len) =>
      _map(sel, (n) => n.copyWith(len: len.clamp(kMinNoteLength, Steps(kPatternMaxSteps))));

  /// The selection as a clip, starts relative to its earliest note.
  PatternClip copy(Set<int> sel) {
    final s = _selected(sel);
    if (s.isEmpty) return PatternClip(const [], Steps.zero);
    final start = s.map((n) => n.at).reduce(Steps.min);
    final end = s.map((n) => n.end).reduce(Steps.max);
    return PatternClip(
      List.unmodifiable([for (final n in s) n.copyWith(id: 0, at: n.at - start, trailingComment: null, line: null)]),
      end - start,
    );
  }

  /// Adds a clip's notes starting at [at] and returns their ids. Notes past 4096 steps or past the note limit are
  /// dropped. Copies carry no trailing comments.
  ({PatternDoc doc, Set<int> ids}) paste(PatternClip clip, Steps at) {
    final out = [...notes];
    final ids = <int>{};
    var id = _nextId;
    for (final c in clip.notes) {
      final t = at + c.at;
      if (t > Steps(kPatternMaxSteps) || t < Steps.zero || out.length >= kPatternMaxNotes) continue;
      out.add(c.copyWith(id: id, at: t, trailingComment: null, line: null));
      ids.add(id++);
    }
    return (doc: _withNotes(out, id), ids: ids);
  }

  /// Copies the selection [offset] later.
  ({PatternDoc doc, Set<int> ids}) duplicate(Set<int> sel, Steps offset) {
    final s = _selected(sel);
    if (s.isEmpty) return (doc: this, ids: <int>{});
    return paste(copy(sel), s.map((n) => n.at).reduce(Steps.min) + offset);
  }

  /// The E key: copies the selection to start where it ends.
  ({PatternDoc doc, Set<int> ids}) copyAfter(Set<int> sel) => duplicate(sel, copy(sel).span);

  /// Chord inversion up, per start time in the selection: the lowest note goes up by octaves to just above the
  /// highest (a single note goes up an octave). A chord whose new note would pass 127 stays as it is.
  PatternDoc invertUp(Set<int> sel) => _invert(sel, true);

  /// Chord inversion down: the highest note goes down by octaves to just below the lowest (a single note: -12).
  PatternDoc invertDown(Set<int> sel) => _invert(sel, false);

  PatternDoc _invert(Set<int> sel, bool up) {
    final byStart = <Steps, List<PatternNote>>{};
    for (final n in _selected(sel)) {
      byStart.putIfAbsent(n.at, () => []).add(n);
    }
    var out = [...notes];
    for (final g in byStart.values) {
      final lo = g.map((n) => n.pitch).reduce(math.min), hi = g.map((n) => n.pitch).reduce(math.max);
      final mover = g.firstWhere((n) => n.pitch == (up ? lo : hi));
      var p = mover.pitch + (up ? 12 : -12);
      if (g.length > 1) {
        while (up ? p <= hi : p >= lo) {
          p += up ? 12 : -12;
        }
      }
      if (p < 0 || p > 127) continue;
      // The moved note is written last (up) or first (down) in its chord, so the line reads low to high.
      out.removeWhere((n) => n.id == mover.id);
      final members = [
        for (var i = 0; i < out.length; i++)
          if (g.any((m) => m.id == out[i].id)) i
      ];
      final moved = mover.copyWith(pitch: p);
      if (members.isEmpty) {
        out.add(moved);
      } else {
        out.insert(up ? members.last + 1 : members.first, moved);
      }
    }
    return _withNotes(out);
  }

  /// Starts to the nearest [grid] line; lengths to the nearest multiple of [grid], at least one grid.
  PatternDoc quantize(Set<int> sel, Steps grid) => _map(
        sel,
        (n) => n.copyWith(
          at: n.at.roundTo(grid).clamp(Steps.zero, Steps(kPatternMaxSteps).floorTo(grid)),
          len: Steps.max(grid, n.len.roundTo(grid)).clamp(kMinNoteLength, Steps(kPatternMaxSteps)),
        ),
      );

  /// Cuts each selected note that spans [time] into two. The left part keeps the id and the comment and loses
  /// `slide`; ids holds both parts of every note cut.
  ({PatternDoc doc, Set<int> ids}) split(Set<int> sel, Steps time) {
    final out = <PatternNote>[];
    final ids = <int>{};
    var id = _nextId;
    for (final n in notes) {
      if (!sel.contains(n.id) || n.at >= time || n.end <= time || out.length + 1 >= kPatternMaxNotes) {
        out.add(n);
        continue;
      }
      out.add(n.copyWith(len: time - n.at, slide: false));
      out.add(n.copyWith(id: id, at: time, len: n.end - time, trailingComment: null, line: null));
      ids.addAll([n.id, id++]);
    }
    return (doc: _withNotes(out, id), ids: ids);
  }

  /// Joins selected notes of the same pitch that touch or overlap into one (the first keeps its id; the last's
  /// `slide` carries over). ids holds the notes left.
  ({PatternDoc doc, Set<int> ids}) join(Set<int> sel) {
    final byPitch = <double, List<PatternNote>>{};
    for (final n in _selected(sel)) {
      byPitch.putIfAbsent(n.pitch, () => []).add(n);
    }
    final replace = <int, PatternNote>{};
    final gone = <int>{};
    for (final g in byPitch.values) {
      g.sort((a, b) => a.at.compareTo(b.at));
      var cur = g.first;
      for (final n in g.skip(1)) {
        if (n.at <= cur.end) {
          cur = cur.copyWith(len: Steps.max(cur.end, n.end) - cur.at, slide: n.slide);
          gone.add(n.id);
        } else {
          replace[cur.id] = cur;
          cur = n;
        }
      }
      replace[cur.id] = cur;
    }
    final out = [
      for (final n in notes)
        if (!gone.contains(n.id)) replace[n.id] ?? n
    ];
    return (
      doc: _withNotes(out),
      ids: {
        for (final n in _selected(sel))
          if (!gone.contains(n.id)) n.id
      }
    );
  }

  /// Each selected note lasts until the next later start in the selection (the last ones keep their length).
  PatternDoc legato(Set<int> sel) {
    final starts = _selected(sel).map((n) => n.at).toSet().toList()..sort();
    return _map(sel, (n) {
      for (final t in starts) {
        if (t > n.at) return n.copyWith(len: t - n.at);
      }
      return n;
    });
  }

  /// Sets each selected note's velocity, or chance, from [f] of the note (the Curve tool's shapes). Returns this
  /// same doc when no value changes, so a gesture that changes nothing makes no undo step.
  PatternDoc shape(Set<int> sel, double Function(PatternNote n) f, {bool chance = false}) {
    double v(PatternNote n) => _round3(f(n).clamp(0, 1).toDouble());
    if (_selected(sel).every((n) => v(n) == (chance ? n.prob : n.vel))) return this;
    return _map(sel, (n) => chance ? n.copyWith(prob: v(n)) : n.copyWith(vel: v(n)));
  }

  PatternDoc setVelocity(Set<int> sel, double vel) =>
      _map(sel, (n) => n.copyWith(vel: _round3(vel.clamp(0, 1).toDouble())));

  PatternDoc addVelocity(Set<int> sel, double delta) =>
      _map(sel, (n) => n.copyWith(vel: _round3((n.vel + delta).clamp(0, 1).toDouble())));

  static const List<double> probSteps = [1, 0.75, 0.5, 0.25];

  /// Steps the first selected note's prob along 1, 0.75, 0.5, 0.25 (and back to 1); every selected note gets it.
  PatternDoc cycleProb(Set<int> sel) {
    final s = _selected(sel);
    if (s.isEmpty) return this;
    final i = probSteps.indexWhere((p) => p <= s.first.prob + 1e-9);
    final next = i < 0 ? 1.0 : probSteps[(i + 1) % probSteps.length];
    return _map(sel, (n) => n.copyWith(prob: next));
  }

  /// Steps the first selected note's ratchet along 1..4 (and back to 1); every selected note gets it.
  PatternDoc cycleRatchet(Set<int> sel) {
    final s = _selected(sel);
    if (s.isEmpty) return this;
    final r = s.first.ratchet;
    final next = r >= 4 ? 1 : r + 1;
    return _map(sel, (n) => n.copyWith(ratchet: next));
  }

  /// Slide on for every selected note, or off when they all have it.
  PatternDoc toggleSlide(Set<int> sel) {
    final on = !_selected(sel).every((n) => n.slide);
    return _map(sel, (n) => n.copyWith(slide: on));
  }

  PatternDoc setProb(Set<int> sel, double prob) => _map(sel, (n) => n.copyWith(prob: _round3(prob.clamp(0, 1).toDouble())));
  PatternDoc setRatchet(Set<int> sel, int ratchet) => _map(sel, (n) => n.copyWith(ratchet: ratchet.clamp(1, 8)));
  PatternDoc setSlide(Set<int> sel, bool slide) => _map(sel, (n) => n.copyWith(slide: slide));

  // Queries.

  /// Notes that sound during [t0, t1) (or at t0 when t0 == t1) with pitch in [p0, p1]; bounds may come in any order.
  Set<int> notesIn(Steps t0, Steps t1, double p0, double p1) {
    final a = Steps.min(t0, t1), b = Steps.max(t0, t1);
    final lo = math.min(p0, p1), hi = math.max(p0, p1);
    return {
      for (final n in notes)
        if (n.pitch >= lo && n.pitch <= hi && (a == b ? n.at <= a && n.end > a : n.at < b && n.end > a)) n.id,
    };
  }

  /// The note after (direction > 0) or before (direction < 0) the cursor, ordered by start and then pitch.
  int? nextNoteFrom(Steps time, double pitch, int direction) {
    int cmp(PatternNote n) {
      final c = n.at.compareTo(time);
      return c != 0 ? c : n.pitch.compareTo(pitch);
    }

    PatternNote? best;
    for (final n in notes) {
      final c = cmp(n);
      if (direction > 0 ? c <= 0 : c >= 0) continue;
      if (best == null) {
        best = n;
        continue;
      }
      final d = n.at.compareTo(best.at);
      final closer =
          d != 0 ? (direction > 0 ? d < 0 : d > 0) : (direction > 0 ? n.pitch < best.pitch : n.pitch > best.pitch);
      if (closer) best = n;
    }
    return best?.id;
  }

  // ---------- generators (roll.gen.*) ----------

  /// Adds notes, each clamped like [insert]; stops at the note limit. Returns the new notes' ids.
  ({PatternDoc doc, Set<int> ids}) _addAll(Iterable<({Steps at, double pitch, Steps len, double vel})> add,
      {Set<int> remove = const {}}) {
    final out = [
      for (final n in notes)
        if (!remove.contains(n.id)) n
    ];
    final ids = <int>{};
    var id = _nextId;
    for (final a in add) {
      if (out.length >= kPatternMaxNotes || a.at >= Steps(kPatternMaxSteps)) continue;
      out.add(PatternNote(
        id: id,
        at: a.at.clamp(Steps.zero, Steps(kPatternMaxSteps)),
        len: a.len.clamp(kMinNoteLength, Steps(kPatternMaxSteps)),
        pitch: a.pitch.clamp(0, 127).toDouble(),
        vel: _round3(a.vel.clamp(0, 1).toDouble()),
      ));
      ids.add(id++);
    }
    return (doc: _withNotes(out, id), ids: ids);
  }

  /// A Euclidean rhythm: [pulses] hits spread as evenly as they go over [steps] cells of [cell] each, from [at],
  /// turned [rotate] cells later. Each hit is a note of one cell at [pitch].
  ({PatternDoc doc, Set<int> ids}) euclid(
      {required Steps at, required int pulses, required int steps, required Steps cell, required double pitch,
      int rotate = 0, double vel = 1}) {
    final n = steps.clamp(1, 64), k = pulses.clamp(0, n);
    return _addAll([
      for (var i = 0; i < n; i++)
        if (((i - rotate) % n * k) % n < k) (at: at + cell.times(i), pitch: pitch, len: cell, vel: vel)
    ]);
  }

  /// Random notes in [key] (every pitch when null): each [cell] from [at] over [span] gets a note with chance
  /// [density], at a pitch from [lo] to [hi]. The same [seed] gives the same notes.
  ({PatternDoc doc, Set<int> ids}) randomInKey(
      {required Steps at, required Steps span, required Steps cell, required int lo, required int hi,
      required double density, ({int root, List<int> scale})? key, int seed = 1}) {
    final r = math.Random(seed);
    final pitches = [
      for (var p = math.min(lo, hi); p <= math.max(lo, hi); p++)
        if (key == null || key.scale.contains((p - key.root) % 12)) p
    ];
    if (pitches.isEmpty || cell <= Steps.zero) return (doc: this, ids: <int>{});
    final cells = (span / cell).floor().clamp(0, kPatternMaxNotes);
    return _addAll([
      for (var i = 0; i < cells; i++)
        if (r.nextDouble() < density)
          (at: at + cell.times(i), pitch: pitches[r.nextInt(pitches.length)].toDouble(), len: cell, vel: 0.6 + 0.4 * r.nextDouble())
    ]);
  }

  /// Turns each chord in the selection (notes starting together) into a run of its notes, one every [rate], over the
  /// chord's length: up, down, or up then down. Single notes stay.
  ({PatternDoc doc, Set<int> ids}) arpeggiate(Set<int> sel, Steps rate, {String order = 'up'}) {
    final chords = <Steps, List<PatternNote>>{};
    for (final n in _selected(sel)) {
      (chords[n.at] ??= []).add(n);
    }
    final remove = <int>{};
    final add = <({Steps at, double pitch, Steps len, double vel})>[];
    if (rate <= Steps.zero) return (doc: this, ids: <int>{});
    for (final c in chords.values) {
      if (c.length < 2) continue;
      c.sort((a, b) => a.pitch.compareTo(b.pitch));
      final run = switch (order) {
        'down' => c.reversed.toList(),
        'updown' => [...c, ...c.reversed.skip(1).take(c.length - 2)],
        _ => c,
      };
      final len = c.map((n) => n.len).reduce(Steps.max), start = c.first.at;
      final count = math.max(1, (len / rate).ceil()).clamp(1, kPatternMaxNotes);
      for (var i = 0; i < count; i++) {
        final t = start + rate.times(i), n = run[i % run.length];
        add.add((at: t, pitch: n.pitch, len: Steps.min(rate, start + len - t), vel: n.vel));
      }
      remove.addAll(c.map((n) => n.id));
    }
    return _addAll(add, remove: remove);
  }

  /// Nudges each selected note's start by up to [timing] steps either way (to 1/96 of a step, never before 0) and
  /// its velocity by up to [velocity]. The same [seed] gives the same result.
  PatternDoc humanize(Set<int> sel, {double timing = 0.1, double velocity = 0.1, int seed = 1}) {
    final r = math.Random(seed);
    return _map(sel, (n) {
      final dt = Steps.fromDouble((r.nextDouble() * 2 - 1) * timing, maxDenominator: 96);
      final dv = (r.nextDouble() * 2 - 1) * velocity;
      return n.copyWith(
          at: (n.at + dt).clamp(Steps.zero, Steps(kPatternMaxSteps)), vel: _round3((n.vel + dv).clamp(0.05, 1).toDouble()));
    });
  }

  /// Stacks a chord on each selected note: the 3rd and 5th above it in [key] (and the 7th with [seventh]), or a
  /// major triad when there is no key. A pitch past 127 or one already sounding at that start is left out. Returns
  /// the added notes' ids.
  ({PatternDoc doc, Set<int> ids}) chordStamp(Set<int> sel, {({int root, List<int> scale})? key, bool seventh = false}) {
    double above(double p, int degrees) {
      if (key == null) return p + const [0, 0, 4, 0, 7, 0, 11][degrees];
      final scale = key.scale;
      // Walk up the scale from the note (a note outside the key starts from the scale note below it).
      var q = p.round();
      var walked = 0;
      while (walked < degrees && q < 128) {
        q++;
        if (scale.contains((q - key.root) % 12)) walked++;
      }
      return q.toDouble();
    }

    final taken = {for (final n in notes) (n.at, n.pitch)};
    final add = <({Steps at, double pitch, Steps len, double vel})>[];
    for (final n in _selected(sel)) {
      for (final d in [2, 4, if (seventh) 6]) {
        final p = above(n.pitch, d);
        if (p > 127 || !taken.add((n.at, p))) continue;
        add.add((at: n.at, pitch: p, len: n.len, vel: n.vel));
      }
    }
    return _addAll(add);
  }

  /// Mirrors the selection in time inside its own span, so the last note comes first.
  PatternDoc reverse(Set<int> sel) {
    final s = _selected(sel);
    if (s.isEmpty) return this;
    final start = s.map((n) => n.at).reduce(Steps.min), end = s.map((n) => n.end).reduce(Steps.max);
    return _map(sel, (n) => n.copyWith(at: start + end - n.end));
  }

  /// Mirrors the selection's pitches around [center].
  PatternDoc invertPitch(Set<int> sel, double center) =>
      _map(sel, (n) => n.copyWith(pitch: (2 * center - n.pitch).clamp(0, 127).toDouble()));
}
