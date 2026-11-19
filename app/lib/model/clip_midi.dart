// A MIDI clip as it is stored (project format v5, #216): a format 0 Standard MIDI File whose notes any MIDI program
// plays, plus C.A.W's own events for what MIDI 1.0 can't hold exactly. The pattern text is a view of it.
//
// The file (960 ticks a quarter note, so 240 a step; no tempo or meter, as a clip has neither):
// - Track Name (FF 03): the pattern's name.
// - The notes, one loop of the pattern with every note whole: a note-on and note-off each (each ratchet repeat its own
//   note), MPE when any note bends, has pressure or timbre, or is a microtone (lib/model/midi_file.dart writes it;
//   the curves sampled every 1/128 note, vibrato timed at 120 BPM).
// - Text events (FF 01): the text view's comment and blank lines, each just before the note it stands above.
// - C.A.W events: sequencer-specific meta events (FF 7F) that start with the MMA's non-commercial manufacturer ID 7D
//   and "CAW" ([kCawMeta]), then a type byte:
//   - 1 header: format 1, flags (1: the text ends with a line break), then the text's header lines (name, summary,
//     length and any others, as written);
//   - 4 body: ends the header's Text events (the comments above every note);
//   - 2 note, just before a note's note-on: what that note's MIDI doesn't say exactly (below);
//   - 3 repeat, just before a ratchet repeat's note-on: that note is a repeat, not a note of its own;
//   - 0 gap: a filler that only carries time past the 28-bit delta limit.
//   A note record is a flags number, then the fields its flags name, in this order: 1 start and 2 length (exact
//   rational steps), 4 pitch, 8 velocity, 16 chance, 32 ratchet (a byte 1..64, kPatternMaxRatchet), 64 slide (no field), 128 expression
//   (a byte of 1 bend, 2 pressure, 4 timbre, 8 vibrato; each curve a count and its points' time, value and shape; the
//   vibrato's depth, rate and fade-in), 256 a trailing comment. A note without a record, or a field its record
//   leaves out, reads from its MIDI as an imported file's note does ([patternNoteOfMidi]; a ratchet note's length is
//   its first repeat's times the ratchet).
// Numbers: an unsigned LEB128 varint of at most 9 bytes; a signed one zigzag; a rational a signed numerator and a
// denominator of at least 1; a real number a byte e (0..15) and a signed m for m / 10^e, or 255 and an IEEE double
// (big-endian); a string a byte count and UTF-8.
//
// Writing tries the short form (records only where the MIDI differs), reads it back, and if anything differs writes
// every note's record in full, so a stored clip always reads back to the same notes, comments and header.
// Reading is bounded (untrusted input): the file's limits (16 MB, events, notes, 4-byte delta times), varints of at
// most 9 bytes, counts and strings within their event, and the result must parse as a pattern.
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'midi_clips.dart';
import 'midi_file.dart';
import 'pattern_doc.dart';

/// Ticks a quarter note in a stored clip, and a step's.
const int kClipPpq = kMidiExportPpq, _tps = kClipPpq ~/ 4;

const int _header = 1, _note = 2, _repeat = 3, _body = 4;
const int _format = 1;

// Note record flags.
const int _fAt = 1, _fLen = 2, _fPitch = 4, _fVel = 8, _fProb = 16, _fRatchet = 32, _fSlide = 64, _fExpr = 128,
    _fComment = 256, _fAll = 511;

/// Why a stored clip couldn't be read.
class ClipMidiException extends MidiFileException {
  const ClipMidiException(super.message);
}

// ---------------------------------------------------------------------------------------------------------------
// Writing

/// [doc] as a stored clip's MIDI. Reading it back ([clipMidiToDoc]) gives the same header, notes (in time order)
/// and comments.
Uint8List clipMidiFromDoc(PatternDoc doc) {
  final short = _write(doc, full: false);
  if (_same(doc, _tryRead(short))) return short;
  final full = _write(doc, full: true);
  if (!_same(doc, _tryRead(full))) throw StateError('a clip did not survive its own MIDI');
  return full;
}

/// Pattern text as a stored clip's MIDI; null when it doesn't parse.
Uint8List? clipMidiFromText(String text) {
  final hit = _fromText[text];
  if (hit != null) {
    _fromText.remove(text);
    return _fromText[text] = hit;
  }
  final doc = PatternDoc.parse(text).doc;
  if (doc == null) return null;
  final bytes = clipMidiFromDoc(doc);
  _remember(_fromText, text, bytes);
  return bytes;
}

/// A stored clip as pattern text (its view). Throws a [MidiFileException] for MIDI it can't read.
String clipTextFromMidi(Uint8List bytes, {String? key}) {
  final k = key ?? base64.encode(bytes);
  final hit = _toText[k];
  if (hit != null) {
    _toText.remove(k);
    return _toText[k] = hit;
  }
  final text = clipMidiToDoc(bytes).serialize();
  _remember(_toText, k, text);
  return text;
}

// Recent conversions both ways (an undo step re-reads every clip of the project; most haven't changed).
final LinkedHashMap<String, Uint8List> _fromText = LinkedHashMap();
final LinkedHashMap<String, String> _toText = LinkedHashMap();
void _remember<T>(LinkedHashMap<String, T> m, String k, T v) {
  m[k] = v;
  while (m.length > 512) {
    m.remove(m.keys.first);
  }
}

Uint8List _write(PatternDoc doc, {required bool full}) {
  final sorted = doc.sortedNotes;
  final layout = doc.commentLayout();
  final notes = <MidiNote>[];
  for (final (i, n) in sorted.indexed) {
    final r = n.ratchet.clamp(1, kPatternMaxRatchet);
    final part = n.len / Steps(r);
    final texts = [for (final c in layout.before[i]) _text(c)];
    for (var q = 0; q < r; q++) {
      final hit = n.at + part * Steps(q);
      final on = _tick(hit), off = math.max(on + 1, _tick(hit + part));
      final m = midiNoteOfPattern(n, part, on, off, startTick: hit.toDouble() * _tps, tps: _tps, bpm: 120);
      List<List<int>> lead;
      if (q > 0) {
        lead = [_caw(_repeat, const [])];
      } else {
        final rec = _record(n, m, full: full);
        lead = [...texts, if (rec != null) _caw(_note, rec)];
      }
      notes.add(MidiNote(key: m.key, velocity: m.velocity, on: m.on, off: m.off, bend: m.bend, pressure: m.pressure,
          timbre: m.timbre, lead: lead));
    }
  }
  final head = _Out()
    ..byte(_format)
    ..uint(doc.endsWithNewline ? 1 : 0)
    ..uint(doc.header.length);
  for (final h in doc.header) {
    head.string(h);
  }
  final end = notes.fold(0, (e, n) => math.max(e, n.off));
  return writeMidiFile(
    MidiFile(ppq: kClipPpq, tracks: [
      MidiTrack(
        name: doc.name,
        notes: notes,
        endTick: end,
        head: [_caw(_header, head.bytes), for (final c in layout.top) _text(c), _caw(_body, const [])],
        tail: [for (final c in layout.tail) _text(c)],
      ),
    ]),
    conductor: false,
  );
}

/// The nearest tick (halves round up).
int _tick(Steps s) => (s * Steps(_tps) + Steps(1, 2)).floor();

List<int> _text(String s) {
  final b = utf8.encode(s);
  return [0xFF, 0x01, ..._vlq(b.length), ...b];
}

List<int> _caw(int type, List<int> payload) {
  final n = kCawMeta.length + 1 + payload.length;
  return [0xFF, 0x7F, ..._vlq(n), ...kCawMeta, type, ...payload];
}

List<int> _vlq(int v) {
  final b = <int>[v & 0x7F];
  while ((v >>= 7) > 0) {
    b.insert(0, 0x80 | (v & 0x7F));
  }
  return b;
}

/// What [n]'s record holds: the fields its MIDI ([m]) would read back differently, or all of them when [full]; null
/// when it needs none.
List<int>? _record(PatternNote n, MidiNote m, {required bool full}) {
  final read = patternNoteOfMidi(m, kClipPpq);
  final r = n.ratchet.clamp(1, kPatternMaxRatchet);
  var flags = 0;
  if (full) {
    flags = _fAll & ~(_fSlide | _fComment);
  } else {
    if (read.at != n.at) flags |= _fAt;
    if (read.len * Steps(r) != n.len) flags |= _fLen;
    // A bent note's MIDI pitch reads back through a 14-bit bend: its exact pitch always goes in the record.
    if (read.pitch != n.pitch || !n.expr.isEmpty || n.pitch != n.pitch.roundToDouble()) flags |= _fPitch;
    if (read.vel != n.vel) flags |= _fVel;
    if (n.prob != 1) flags |= _fProb;
    if (r != 1) flags |= _fRatchet;
    if (read.expr != n.expr) flags |= _fExpr;
  }
  if (n.slide) flags |= _fSlide;
  if (n.trailingComment != null) flags |= _fComment;
  if (flags == 0) return null;
  final o = _Out()..uint(flags);
  if (flags & _fAt != 0) o.steps(n.at);
  if (flags & _fLen != 0) o.steps(n.len);
  if (flags & _fPitch != 0) o.real(n.pitch);
  if (flags & _fVel != 0) o.real(n.vel);
  if (flags & _fProb != 0) o.real(n.prob);
  if (flags & _fRatchet != 0) o.byte(r);
  if (flags & _fExpr != 0) {
    final x = n.expr;
    final parts = (x.bend.isEmpty ? 0 : 1) | (x.press.isEmpty ? 0 : 2) | (x.timbre.isEmpty ? 0 : 4) |
        (x.vibDepth != 0 || x.vibRate != 5 || x.vibFade != 0 ? 8 : 0);
    o.byte(parts);
    for (final c in [x.bend, x.press, x.timbre]) {
      if (c.isEmpty) continue;
      o.uint(c.length);
      for (final p in c) {
        o
          ..real(p.t)
          ..real(p.v)
          ..real(p.k);
      }
    }
    if (parts & 8 != 0) {
      o
        ..real(x.vibDepth)
        ..real(x.vibRate)
        ..real(x.vibFade);
    }
  }
  if (flags & _fComment != 0) o.string(n.trailingComment!);
  return o.bytes;
}

class _Out {
  final List<int> bytes = [];
  void byte(int b) => bytes.add(b & 0xFF);
  void uint(int v) {
    if (v < 0) throw ArgumentError.value(v, 'v', 'must not be negative');
    do {
      final b = v & 0x7F;
      v >>= 7;
      bytes.add(v > 0 ? b | 0x80 : b);
    } while (v > 0);
  }

  void sint(int v) => uint(v >= 0 ? v << 1 : ((-v) << 1) - 1);
  void steps(Steps s) {
    sint(s.numerator);
    uint(s.denominator);
  }

  void string(String s) {
    final b = utf8.encode(s);
    uint(b.length);
    bytes.addAll(b);
  }

  /// m / 10^e when that is exactly [v] (decimals as written stay short), else the double's 8 bytes.
  void real(double v) {
    if (v.isFinite && !(v == 0 && v.isNegative)) {
      for (var e = 0; e <= 15; e++) {
        final scaled = v * _pow10[e];
        if (scaled.abs() >= 9007199254740992) break;
        final m = scaled.roundToDouble();
        if (m / _pow10[e] == v) {
          byte(e);
          sint(m.toInt());
          return;
        }
      }
    }
    byte(255);
    final d = ByteData(8)..setFloat64(0, v);
    bytes.addAll(d.buffer.asUint8List());
  }
}

final List<double> _pow10 = [for (var e = 0; e <= 15; e++) math.pow(10, e).toDouble()];

// ---------------------------------------------------------------------------------------------------------------
// Reading

PatternDoc? _tryRead(Uint8List bytes) {
  try {
    return clipMidiToDoc(bytes);
  } on FormatException {
    return null;
  }
}

/// A stored clip's MIDI as a pattern. Throws a [MidiFileException] for MIDI it can't read or that doesn't make a
/// pattern. A file without C.A.W's events (a plain .mid) reads as an imported one's notes would, one line each.
PatternDoc clipMidiToDoc(Uint8List bytes) {
  final f = readMidiFile(bytes);
  final track = f.tracks.where((t) => t.marks.any((m) => m.type == 0x7F && m.data.isNotEmpty && m.data[0] == _header))
          .firstOrNull ??
      f.tracks.where((t) => t.notes.isNotEmpty).firstOrNull ??
      f.tracks.first;
  final notes = [...track.notes]..sort((a, b) => a.seq.compareTo(b.seq));
  var header = <String>['caw: 1', 'kind: pattern', 'name: ${track.name.isEmpty ? 'MIDI' : track.name}'];
  var newline = true, sawHeader = false, inBody = true;
  final top = <String>[], tail = <String>[];
  final out = <PatternNote>[];
  final before = <List<String>>[];
  var pending = <String>[];
  Uint8List? record;
  var repeat = false;
  var mark = 0;
  final marks = track.marks;

  void take(MidiMark m) {
    if (m.type == 0x01) {
      final s = utf8.decode(m.data, allowMalformed: true);
      (inBody ? pending : top).add(s);
      return;
    }
    if (m.data.isEmpty) throw const ClipMidiException('a C.A.W event has no type');
    final type = m.data[0];
    final r = _In(m.data, 1);
    switch (type) {
      case _header:
        if (sawHeader || out.isNotEmpty) throw const ClipMidiException('the clip has a second header');
        sawHeader = true;
        inBody = false;
        final format = r.byte();
        if (format != _format) throw ClipMidiException('the clip was stored by a newer C.A.W (clip format $format)');
        newline = r.uint() & 1 != 0;
        final count = r.count(1);
        header = [for (var i = 0; i < count; i++) r.string()];
        r.end();
      case _body:
        inBody = true;
      case _note:
        record = Uint8List.sublistView(m.data, 1);
      case _repeat:
        repeat = true;
      default:
        break; // a gap, or a later C.A.W event this one doesn't know: time only
    }
  }

  for (final n in notes) {
    while (mark < marks.length && marks[mark].notesBefore <= n.seq) {
      take(marks[mark++]);
    }
    final rec = record, rep = repeat;
    record = null;
    repeat = false;
    if (rep) continue; // a ratchet's repeat: its note already has it
    final p = _note1(n, rec, out.length + 1);
    out.add(p);
    before.add(pending);
    pending = <String>[];
  }
  while (mark < marks.length) {
    take(marks[mark++]);
  }
  tail.addAll(pending);
  final PatternDoc doc;
  try {
    doc = PatternDoc.assemble(header: header, notes: out, top: top, before: before, tail: tail, endsWithNewline: newline);
  } on ArgumentError catch (e) {
    throw ClipMidiException('the clip\'s text doesn\'t fit a pattern: ${e.message}');
  }
  final check = PatternDoc.parse(doc.serialize());
  if (!check.ok) throw ClipMidiException('the clip doesn\'t make a pattern (${check.error})');
  return doc;
}

PatternNote _note1(MidiNote m, Uint8List? rec, int id) {
  final read = patternNoteOfMidi(m, kClipPpq, id: id);
  if (rec == null) return read;
  final r = _In(rec, 0);
  final flags = r.uint();
  if (flags & ~_fAll != 0) throw const ClipMidiException('a note record has flags this C.A.W doesn\'t know');
  final at = flags & _fAt != 0 ? r.steps() : read.at;
  Steps? len = flags & _fLen != 0 ? r.steps() : null;
  final pitch = flags & _fPitch != 0 ? r.real() : read.pitch;
  final vel = flags & _fVel != 0 ? r.real() : read.vel;
  final prob = flags & _fProb != 0 ? r.real() : 1.0;
  var ratchet = 1;
  if (flags & _fRatchet != 0) {
    ratchet = r.byte();
    if (ratchet < 1 || ratchet > kPatternMaxRatchet) throw const ClipMidiException('a ratchet must be 1 to $kPatternMaxRatchet');
  }
  len ??= read.len * Steps(ratchet);
  var expr = read.expr;
  if (flags & _fExpr != 0) {
    final parts = r.byte();
    if (parts & ~15 != 0) throw const ClipMidiException('a note\'s expression has parts this C.A.W doesn\'t know');
    List<NotePoint> curve(int bit) {
      if (parts & bit == 0) return const [];
      final n = r.count(3);
      return List.unmodifiable([for (var i = 0; i < n; i++) NotePoint(r.real(), r.real(), r.real())]);
    }

    final bend = curve(1), press = curve(2), timbre = curve(4);
    var depth = 0.0, rate = 5.0, fade = 0.0;
    if (parts & 8 != 0) {
      depth = r.real();
      rate = r.real();
      fade = r.real();
    }
    expr = NoteExpression(bend: bend, press: press, timbre: timbre, vibDepth: depth, vibRate: rate, vibFade: fade);
  }
  final comment = flags & _fComment != 0 ? r.string() : null;
  r.end();
  return PatternNote(id: id, at: at, len: len, pitch: pitch, vel: vel, prob: prob, ratchet: ratchet,
      slide: flags & _fSlide != 0, expr: expr, trailingComment: comment);
}

/// A bounded reader of a C.A.W event's payload.
class _In {
  _In(this.d, this.pos);
  final Uint8List d;
  int pos;

  Never _fail(String what) => throw ClipMidiException('a C.A.W event $what');

  int byte() {
    if (pos >= d.length) _fail('ends early');
    return d[pos++];
  }

  int uint() {
    var v = 0;
    for (var i = 0; i < 9; i++) {
      final b = byte();
      v |= (b & 0x7F) << (7 * i);
      if (b & 0x80 == 0) return v;
    }
    _fail('has a number longer than 9 bytes');
  }

  int sint() {
    final z = uint();
    return z & 1 == 0 ? z >> 1 : -((z + 1) >> 1);
  }

  /// A count of items at least [size] bytes each, which must fit in what is left.
  int count(int size) {
    final n = uint();
    if (n > (d.length - pos) ~/ size) _fail('counts more than it holds');
    return n;
  }

  Steps steps() {
    final n = sint(), den = uint();
    if (den == 0) _fail('has a time over 0');
    return Steps(n, den);
  }

  double real() {
    final e = byte();
    if (e == 255) {
      if (d.length - pos < 8) _fail('ends early');
      final v = ByteData.sublistView(d, pos, pos + 8).getFloat64(0);
      pos += 8;
      if (!v.isFinite) _fail('has a number that isn\'t finite');
      return v;
    }
    if (e > 15) _fail('has an unknown number form');
    return sint() / _pow10[e];
  }

  String string() {
    final n = count(1);
    final s = utf8.decode(Uint8List.sublistView(d, pos, pos + n), allowMalformed: true);
    pos += n;
    return s;
  }

  void end() {
    if (pos != d.length) _fail('has bytes after its fields');
  }
}

/// Whether two docs hold the same header, notes (in time order, every field) and comments: what a stored clip keeps.
bool _same(PatternDoc a, PatternDoc? b) {
  if (b == null || a.endsWithNewline != b.endsWithNewline || !_list(a.header, b.header)) return false;
  final x = a.sortedNotes, y = b.sortedNotes;
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (!x[i].sameAs(y[i])) return false;
  }
  final p = a.commentLayout(), q = b.commentLayout();
  if (!_list(p.top, q.top) || !_list(p.tail, q.tail)) return false;
  for (var i = 0; i < x.length; i++) {
    if (!_list(p.before[i], q.before[i])) return false;
  }
  return true;
}

bool _list(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
