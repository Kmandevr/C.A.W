// Clips stored as MIDI (#216): every expression feature survives text -> MIDI -> text exactly, the MIDI is a plain
// .mid other programs read, and reading stored MIDI is bounded (untrusted input).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/model/clip_midi.dart';
import 'package:caw/model/midi_file.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pattern with every feature the text holds: chords, off-grid and exact-fraction times, microtones, decimal and
/// fractional velocities, chance, ratchets, slides, bend/pressure/timbre curves with shapes, vibrato (with a rate
/// and no depth too), comments everywhere, header comments and unknown header lines.
const kEverything = '''---
caw: 1
kind: pattern
name: Every Feature   # a header comment
summary: all of it
length: 2 bars
x-note: kept
---
// at  note(s)  len  vel  extras

// a chord
0     C4,E4,G4   4    0.8
4     D4         1/3  1/3   ratchet 3  prob 0.75  // trailing
13/3  60.5       2/3  0.123456789  slide
5     G4         1    1    bend 0:0 0.5:2~0.3 1:-1.25  vib 0.3 5.5 0.25
  // indented comment above a bent note
6.125 A4         0.03125  0   press 0:0.2 1:0.9~-0.5  timbre 0:0.1 0.25:0.7 1:0.3
7     181/3      1    0.5  bend 0:0 1:12  //
8     B3         1/97 1    vib 0 7.5 timbre 0:0.5
8     B3         1/96 1    ratchet 8 prob 0.1 slide
9     C5         2147483.5  1
100   C2         1    1
0     F2         1    0.25 // out of order, starts at 0
// a tail comment

''';

PatternDoc _doc(String s) {
  final p = PatternDoc.parse(s);
  expect(p.ok, isTrue, reason: p.error);
  return p.doc!;
}

void _sameNotes(PatternDoc a, PatternDoc b) {
  final x = a.sortedNotes, y = b.sortedNotes;
  expect(y.length, x.length);
  for (var i = 0; i < x.length; i++) {
    expect(y[i].sameAs(x[i]), isTrue, reason: 'note $i: ${x[i]} became ${y[i]}');
  }
}

void main() {
  test('every expression feature survives text -> MIDI -> text exactly', () {
    final old = _doc(kEverything);
    final midi = clipMidiFromDoc(old);
    final back = clipMidiToDoc(midi);
    _sameNotes(old, back);
    expect(back.header, old.header);
    expect(back.commentLayout().top, old.commentLayout().top);
    expect(back.commentLayout().before, old.commentLayout().before);
    expect(back.commentLayout().tail, old.commentLayout().tail);
    // The text from MIDI is a fixed point: it reads as the same notes and makes the same MIDI, byte for byte.
    final text = back.serialize();
    final again = _doc(text);
    _sameNotes(old, again);
    expect(again.serialize(), text);
    expect(clipMidiFromDoc(again), midi);
    expect(clipMidiFromText(text), midi);
    expect(clipTextFromMidi(midi), text);
    // The text keeps the comments and header as written.
    expect(text, contains('name: Every Feature   # a header comment'));
    expect(text, contains('x-note: kept'));
    expect(text, contains('  // indented comment above a bent note'));
    expect(text, contains('// trailing'));
    expect(text, contains('1/97'));
    expect(text.endsWith('// a tail comment\n\n'), isTrue);
  });

  test('a stored clip is a format 0 .mid any program reads: its notes, ratchet repeats and MPE', () {
    final midi = clipMidiFromDoc(_doc(kEverything));
    expect(String.fromCharCodes(midi.sublist(0, 4)), 'MThd');
    expect(midi[9], 0, reason: 'format 0');
    final f = readMidiFile(midi);
    expect(f.tracks, hasLength(1));
    expect(f.ppq, 960);
    expect(f.mpe, isTrue, reason: 'bent notes make it MPE');
    // 13 notes, the 3-ratchet one heard three times and the 8-ratchet one eight.
    expect(f.tracks.single.notes, hasLength(13 + 2 + 7));
    expect(f.tracks.single.name, 'Every Feature');
  });

  test('a bend of three octaves either way round-trips exactly; the MIDI picks a member bend range that holds it', () {
    final old = _doc('---\nkind: pattern\nname: Wide\n---\n0 C4 4 1 bend 0:0 0.3:36~0.4 0.7:-36 1:-35.875\n4 E4 2 1 bend 0:-36 1:36\n');
    final midi = clipMidiFromDoc(old);
    _sameNotes(old, clipMidiToDoc(midi));
    expect(clipMidiToDoc(midi).sortedNotes.first.expr.bend.map((p) => (p.t, p.v, p.k)),
        [(0.0, 0.0, 0.0), (0.3, 36.0, 0.4), (0.7, -36.0, 0.0), (1.0, -35.875, 0.0)]);
    // Other programs hear it too: the member channels' range (RPN 0) is 48 semitones, so +-36 fits the 14-bit bends.
    final f = readMidiFile(midi);
    final bends = [for (final n in f.tracks.single.notes) ...n.bend.map((p) => p.value)];
    expect(bends.reduce(math.max), closeTo(36, 0.01));
    expect(bends.reduce(math.min), closeTo(-36, 0.01));
    // The stored value has no range of its own: the record keeps the curve's numbers (pattern_doc's maxBend is the
    // only limit), and the member range goes up to 96 semitones (#226), which the MIDI layer holds.
    final wide = readMidiFile(writeMidiFile(MidiFile(tracks: [
      MidiTrack(notes: [MidiNote(key: 60, velocity: 100, on: 0, off: 960, bend: [MidiPoint(0, 0), MidiPoint(480, 96), MidiPoint(900, -96)])]),
    ])));
    expect(wide.tracks.last.notes.single.bend.map((p) => p.value.round()), [0, 96, -96]);
  });

  test('a ratchet of 64 round-trips (the byte holds 1..64)', () {
    final old = _doc('---\nkind: pattern\nname: P\n---\n0 C4 4 1 ratchet 64\n4 D4 1 1 ratchet 12\n');
    final back = clipMidiToDoc(clipMidiFromDoc(old));
    _sameNotes(old, back);
    expect(back.notes.map((n) => n.ratchet), [64, 12]);
  });

  test('plain notes need no C.A.W events of their own', () {
    final midi = clipMidiFromText('---\nkind: pattern\nname: P\n---\n0 C4 1 1\n1 D4 1 1\n2 E4 2 1\n')!;
    final f = readMidiFile(midi);
    final notes = f.tracks.single.marks.where((m) => m.type == 0x7F && m.data.first == 2);
    expect(notes, isEmpty);
    expect(f.tracks.single.notes.map((n) => (n.key, n.on, n.off, n.velocity)),
        [(60, 0, 240, 127), (62, 240, 480, 127), (64, 480, 960, 127)]);
    expect(midi.length, lessThan(120));
  });

  test('random patterns round-trip exactly', () {
    final r = math.Random(216);
    String num(int places) => (r.nextInt(math.pow(10, places).toInt()) / math.pow(10, places)).toString();
    for (var round = 0; round < 60; round++) {
      final b = StringBuffer('---\nkind: pattern\nname: R$round\n---\n');
      for (var i = 0; i < r.nextInt(40); i++) {
        final at = r.nextBool() ? '${r.nextInt(64)}' : '${r.nextInt(200)}/${1 + r.nextInt(100)}';
        final pitch = r.nextInt(4) == 0 ? '${r.nextInt(1270) / 10}' : '${r.nextInt(128)}';
        final len = r.nextBool() ? '${1 + r.nextInt(8)}' : '${1 + r.nextInt(50)}/${1 + r.nextInt(30)}';
        b.write('$at $pitch $len ${num(r.nextInt(4))}');
        if (r.nextInt(3) == 0) b.write(' ratchet ${1 + r.nextInt(8)}');
        if (r.nextInt(3) == 0) b.write(' prob ${num(2)}');
        if (r.nextInt(4) == 0) b.write(' slide');
        if (r.nextInt(3) == 0) b.write(' bend 0:${r.nextInt(9) - 4} ${num(2)}:${num(3)}~${num(1)} 1:${-r.nextInt(48)}');
        if (r.nextInt(4) == 0) b.write(' vib ${num(2)} ${1 + r.nextInt(20)}');
        if (r.nextInt(4) == 0) b.write(' press 0:${num(2)} 1:${num(2)}');
        if (r.nextInt(4) == 0) b.write(' timbre 0:${num(3)}');
        if (r.nextInt(5) == 0) b.write(' // c$i');
        b.write('\n');
        if (r.nextInt(6) == 0) b.write('// above ${i + 1}\n');
      }
      final old = _doc(b.toString());
      final midi = clipMidiFromDoc(old);
      final back = clipMidiToDoc(midi);
      _sameNotes(old, back);
      // The text from MIDI is a fixed point from the first round on (a comment's place in a chord line can settle).
      final text = back.serialize();
      final midi1 = clipMidiFromText(text)!;
      expect(clipTextFromMidi(midi1), text, reason: b.toString());
      expect(clipMidiFromText(clipTextFromMidi(midi1)), midi1);
    }
  });

  test('a plain .mid (no C.A.W events) reads as imported notes', () {
    final bytes = writeMidiFile(MidiFile(tracks: [
      MidiTrack(name: 'Bass', notes: [MidiNote(key: 36, velocity: 100, on: 0, off: 480), MidiNote(key: 43, velocity: 127, on: 480, off: 960)]),
    ]));
    final d = clipMidiToDoc(bytes);
    expect(d.name, 'Bass');
    expect(d.sortedNotes.map((n) => (n.at, n.pitch, n.len, n.vel)),
        [(Steps.zero, 36.0, Steps(2), 0.787), (Steps(2), 43.0, Steps(2), 1.0)]);
  });

  test('reading stored MIDI is bounded and fails closed', () {
    final good = clipMidiFromDoc(_doc(kEverything));
    // Every truncation and many single-byte corruptions throw a MIDI error, never anything else.
    for (var cut = 0; cut < good.length; cut += 3) {
      try {
        clipMidiToDoc(Uint8List.sublistView(good, 0, cut));
      } on MidiFileException {
        // expected
      }
    }
    final r = math.Random(5);
    for (var i = 0; i < 3000; i++) {
      final bad = Uint8List.fromList(good);
      for (var k = 0; k < 1 + r.nextInt(3); k++) {
        bad[r.nextInt(bad.length)] = r.nextInt(256);
      }
      try {
        clipMidiToDoc(bad);
      } on MidiFileException {
        // expected
      }
    }
    List<int> caw(List<int> payload) => [0xFF, 0x7F, kCawMeta.length + payload.length, ...kCawMeta, ...payload];
    Uint8List file(List<int> events) {
      final body = [...events, 0x00, 0xFF, 0x2F, 0x00];
      return Uint8List.fromList([...ascii.encode('MThd'), 0, 0, 0, 6, 0, 0, 0, 1, 0x03, 0xC0,
        ...ascii.encode('MTrk'), 0, 0, body.length >> 8, body.length & 0xFF, ...body]);
    }

    // A varint of ten bytes, a count past the event, a newer clip format, a comment holding a note line.
    expect(() => clipMidiToDoc(file([0, ...caw([1, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])])),
        throwsA(isA<MidiFileException>()));
    expect(() => clipMidiToDoc(file([0, ...caw([1, 1, 0, 100, 3, 0x61])])), throwsA(isA<MidiFileException>()));
    expect(() => clipMidiToDoc(file([0, ...caw([1, 9, 0, 0])])), throwsA(isA<MidiFileException>()));
    final note = utf8.encode('0 C4 1 1');
    expect(() => clipMidiToDoc(file([0, ...caw([1, 1, 0, 1, 13, ...utf8.encode('kind: pattern')]), 0, 0xFF, 0x01, note.length, ...note])),
        throwsA(isA<MidiFileException>()));
    // A header that doesn't make a pattern.
    expect(() => clipMidiToDoc(file([0, ...caw([1, 1, 0, 1, 7, ...utf8.encode('kind: x')])])), throwsA(isA<MidiFileException>()));
  });
}
