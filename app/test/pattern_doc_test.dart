// Pattern model tests: exact steps, parse errors, round trips of the examples, comment keeping and every edit.
import 'package:caw/model/pattern_doc.dart';
import 'package:flutter_test/flutter_test.dart';

const acidLine = '''---
caw: 1
kind: pattern
name: Acid line
summary: One bar of A minor acid with two slides, a ratchet and a note that plays half the time
length: 16
---
// at = start in 16ths, len = length in 16ths, vel = 0..1
// extras: slide (glide into the next note), ratchet N (repeat N times), prob P (chance it plays)
// at  note  len  vel  extras
0      A1    2    1
2      A2    1    0.7
3      A1    1    0.8  slide
4      C2    2    0.9
6      A1    1    0.6  prob 0.5
8      E2    2    1    ratchet 2
10     G1    1    0.7
11     A1    1    0.8  slide
12     A2    2    0.9
14     G2    1    0.6
15     E2    1    0.8
''';

const chords = '''---
caw: 1
kind: pattern
name: Chords
summary: Four bars of A minor, F, C and G chords for any synth to play
length: 4 bars
---
// A chord is several notes joined by commas; each note gets its own voice.
// at  notes      len  vel
0      A3,C4,E4   16   0.8
16     F3,A3,C4   16   0.75
32     C3,E3,G3   16   0.8
48     G3,B3,D4   14   0.7
62     G3,B3,D4   1/2  0.5  ratchet 2
''';

// The docs/engine.md example: decimals, fractions, a header comment.
const docsExample = '''---
kind: pattern
name: Acid line
length: 16          # in 16ths, or `length: 2 bars`; without it, the whole bars its notes need
---
// at   note(s)    len   vel   extras
0       A1         2     1
3       A1         1     0.8   slide
4.5     C3,E3,G3   1/2   0.9   ratchet 2
13/3    E2         1     0.6   prob 0.5
''';

const head = '---\nkind: pattern\n---\n';

PatternDoc doc(String text) {
  final r = PatternDoc.parse(text);
  expect(r.error, isNull);
  return r.doc!;
}

PatternDoc body(String lines) => doc('$head$lines');

String bodyOf(PatternDoc d) => d.serialize().substring(head.length);

String err(String text) => PatternDoc.parse(text).error!;

int idAt(PatternDoc d, num at, String pitch) =>
    d.notes.firstWhere((n) => n.at.toDouble() == at && n.pitch == noteNumber(pitch)).id;

bool sameNotes(PatternDoc a, PatternDoc b) {
  final x = a.sortedNotes, y = b.sortedNotes;
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (!x[i].sameAs(y[i])) return false;
  }
  return true;
}

void main() {
  group('Steps', () {
    test('parses decimals and fractions exactly', () {
      expect(Steps.tryParse('4'), Steps(4));
      expect(Steps.tryParse('4.5'), Steps(9, 2));
      expect(Steps.tryParse('.5'), Steps(1, 2));
      expect(Steps.tryParse('13/3'), Steps(13, 3));
      expect(Steps.tryParse('4.5/2'), Steps(9, 4));
      expect(Steps.tryParse('-2'), Steps(-2));
      expect(Steps.tryParse('1e1'), Steps(10));
      for (final bad in ['', '.', 'x', '1/0', '1/', 'nan', 'Infinity']) {
        expect(Steps.tryParse(bad), isNull, reason: bad);
      }
    });

    test('normalises and does exact arithmetic', () {
      expect(Steps(6, -4), Steps(-3, 2));
      expect(Steps(13, 3) + Steps(1, 3), Steps(14, 3));
      expect(Steps(1, 3).times(3), Steps.one);
      expect(Steps(7, 2).floor(), 3);
      expect(Steps(-7, 2).floor(), -4);
      expect(Steps(7, 2).ceil(), 4);
      expect(Steps(13, 3).roundTo(Steps(1, 2)), Steps(9, 2));
      expect(Steps(5, 4).roundTo(Steps(1, 2)), Steps(3, 2));
      expect(Steps(13, 3).floorTo(Steps.one), Steps(4));
      expect(Steps.fromDouble(1 / 3), Steps(1, 3));
    });

    test('writes integers, short decimals, small fractions, then decimals', () {
      expect('${Steps(4)}', '4');
      expect('${Steps(9, 2)}', '4.5');
      expect('${Steps(1, 8)}', '0.125');
      expect('${Steps(13, 3)}', '13/3');
      expect('${Steps(1, 16)}', '1/16');
      expect('${Steps(1, 10000)}', '0.0001');
      expect('${Steps(1, 67)}', '0.015');
      expect('${Steps(-1, 2)}', '-0.5');
    });
  });

  test('note names follow the engine', () {
    expect(noteNumber('A1'), 33);
    expect(noteNumber('F#3'), 54);
    expect(noteNumber('Bb2'), 46);
    expect(noteNumber('C-1'), isNull);
    expect(noteNumber('H2'), isNull);
    expect(formatPitch(46), 'A#2');
    expect(formatPitch(12), 'C0');
    expect(formatPitch(127), 'G9');
    expect(formatPitch(5), '5');
    expect(formatPitch(60.5), '60.5');
    expect(formatPitch(181 / 3), '181/3');
  });

  group('parse', () {
    test('reads notes, chords and extras', () {
      final d = doc(docsExample);
      expect(d.notes.length, 6);
      final chord = d.notes.where((n) => n.line == 9).toList();
      expect(chord.map((n) => n.pitch), [48, 52, 55]);
      expect(chord.every((n) => n.at == Steps(9, 2) && n.len == Steps(1, 2) && n.ratchet == 2 && n.vel == 0.9), isTrue);
      final last = d.notes.last;
      expect(last.at, Steps(13, 3));
      expect(last.prob, 0.5);
      expect(d.notes[1].slide, isTrue);
      expect(d.notes.map((n) => n.id).toSet().length, 6);
      expect(d.headerSteps, 16);
      expect(d.name, 'Acid line');
    });

    test('defaults and comments', () {
      final d = body('0 60.5 1 // hi there\n1 C3,E3 1 ratchet 3 slide\n');
      expect(d.notes.first.pitch, 60.5);
      expect(d.notes.first.vel, 1);
      expect(d.notes.first.trailingComment, 'hi there');
      expect(d.notes[1].trailingComment, isNull);
      expect(d.notes[1].ratchet, 3);
      expect(d.notes[2].slide, isTrue);
    });

    test('errors carry line and column like the engine', () {
      expect(err('0 A1 1\n'), "line 1, col 1: a pattern's header needs 'kind: pattern'");
      expect(err('---\nkind: pattern\n'), "line 1, col 1: header starts with '---' but never ends with '---'");
      expect(err('---\nkind pattern\n---\n'), "line 2, col 1: header lines look like 'key: value'");
      expect(err('---\ncaw: 2\nkind: pattern\n---\n'), 'line 2, col 1: this app reads module format 1');
      expect(err('---\nkind: pattern\nlength: 2 beats\n---\n'),
          'line 3, col 9: length is a number of steps (16) or bars (4 bars)');
      expect(err('---\nkind: pattern\nlength: 2.5\n---\n'), 'line 3, col 9: length must be a whole number');
      expect(err('$head[kick] x...\n'), "line 4, col 1: kit rows ([kick] and so on) aren't supported yet");
      expect(err('${head}0 A1\n'), 'line 4, col 1: a note line is: at  note  length  [velocity]  [extras]');
      expect(err('$head  0 H1 1\n'), "line 4, col 5: expected a note such as C3, F#2 or 48, found 'H1'");
      expect(err('${head}0 C3,Q3 1\n'), "line 4, col 6: expected a note such as C3, F#2 or 48, found 'Q3'");
      expect(err('${head}0 200 1\n'), 'line 4, col 3: notes must be 0 to 127');
      expect(err('$head-1 A1 1\n'), 'line 4, col 1: the start (in steps) must be 0 to 4096');
      expect(err('${head}x A1 1\n'), "line 4, col 1: expected the start (in steps), found 'x'");
      expect(err('${head}0 A1 0\n'), 'line 4, col 6: the length (in steps) must be 0.001 to 4096');
      expect(err('${head}0 A1 1 2\n'), 'line 4, col 8: velocity must be 0 to 1');
      expect(
          err('${head}0 A1 1 1 wobble\n'), "line 4, col 10: unknown extra 'wobble' (try prob 0.5, ratchet 3 or slide)");
      expect(err('${head}0 A1 1 prob\n'), "line 4, col 8: 'prob' needs a number after it");
      expect(err('${head}0 A1 1 ratchet 2.5\n'), 'line 4, col 16: ratchet must be a whole number');
      expect(err('${head}0 A1 1 ratchet 9\n'), 'line 4, col 16: ratchet must be 1 to 8');
      final r = PatternDoc.parse('${head}0 A1 1 2\n');
      expect((r.ok, r.line, r.col), (false, 4, 8));
    });

    test('caps the note count', () {
      final lines = List.generate(2049, (i) => '$i C3,E3 1').join('\n');
      expect(err('$head$lines\n'), 'line 2052, col 1: a pattern holds at most 4096 notes');
    });
  });

  group('round trips', () {
    for (final (label, text) in [('acid-line', acidLine), ('chords', chords), ('docs example', docsExample)]) {
      test(label, () {
        final d = doc(text);
        expect(sameNotes(doc(d.serialize()), d), isTrue);
        expect(doc(d.serialize()).serialize(), d.serialize());
        // The docs example writes 13/3 after 4.5, so only it comes back reordered.
        if (text != docsExample) expect(d.serialize(), text);
      });
    }

    test('lines come back in time order, each as written', () {
      final lines = docsExample.split('\n');
      final sorted = [...lines.take(8), lines[9], lines[8], ...lines.skip(10)].join('\n');
      expect(doc(docsExample).serialize(), sorted);
      expect(doc(sorted).serialize(), sorted);
    });

    test('reformatted lines read back the same', () {
      var d = doc(chords);
      d = d.move(d.notes.map((n) => n.id).toSet(), Steps(1, 3), 0.5);
      final text = d.serialize();
      expect(text, contains('\n1/3    57.5,60.5,64.5  16   0.8\n'));
      expect(sameNotes(doc(text), d), isTrue);
      expect(doc(text).serialize(), text);
    });

    test('no final newline stays that way, out-of-order lines get sorted', () {
      final d = body('4 C3 1\n0 D3 1');
      expect(bodyOf(d), '0 D3 1\n4 C3 1');
    });
  });

  group('header', () {
    test('length rule mirrors the engine', () {
      expect(doc(acidLine).lengthSteps(4), 16);
      expect(doc(chords).lengthSteps(4), 64);
      expect(doc(chords).lengthSteps(3), 48);
      expect(body('17 C3 1\n').lengthSteps(4), 32);
      expect(body('0 C3 16\n').lengthSteps(4), 16);
      expect(doc(head).lengthSteps(4), 16);
      expect(body('0 C3 13/3\n').lastEnd, Steps(13, 3));
    });

    test('setters rewrite only their line', () {
      final d = doc(docsExample).setLength(bars: 2).setName('Renamed');
      final lines = d.serialize().split('\n');
      expect(lines[2], 'name: Renamed');
      expect(lines[3],
          'length: 2 bars          # in 16ths, or `length: 2 bars`; without it, the whole bars its notes need');
      expect(d.headerBars, 2);
      expect(d.headerSteps, isNull);
      expect(lines.skip(4).join('\n'), doc(docsExample).serialize().split('\n').skip(4).join('\n'));
    });

    test('setters add and remove lines', () {
      var d = doc(head).setName('New #1').setLength(steps: 12);
      expect(d.header, ['kind: pattern', 'name: New 1', 'length: 12']);
      expect(d.lengthSteps(4), 12);
      d = d.setLength();
      expect(d.header, ['kind: pattern', 'name: New 1']);
      expect(() => d.setLength(steps: 0), throwsRangeError);
      final b = PatternDoc.blank(name: 'Bass', bars: 1);
      expect(b.serialize(),
          '---\ncaw: 1\nkind: pattern\nname: Bass\nlength: 1 bar\n---\n// at  note(s)  len  vel  extras\n');
      expect(b.notes, isEmpty);
    });
  });

  group('comments', () {
    const text = '// top\n0 C3 1\n// about D\n4 D3 1  // dee\n// about E\n8 E3 1\n// end\n';

    test('anchored comments move with their note', () {
      final d = body(text);
      final moved = d.move({idAt(d, 4, 'D3')}, Steps(6), 0);
      expect(bodyOf(moved), '// top\n0 C3 1\n// about E\n8 E3 1\n// about D\n10  D3  1    1  // dee\n// end\n');
    });

    test('comments of a deleted line fall through to the next', () {
      final d = body(text);
      expect(bodyOf(d.delete({idAt(d, 4, 'D3')})), '// top\n0 C3 1\n// about D\n// about E\n8 E3 1\n// end\n');
      expect(bodyOf(d.delete({idAt(d, 8, 'E3')})), '// top\n0 C3 1\n// about D\n4 D3 1  // dee\n// about E\n// end\n');
      expect(bodyOf(d.delete(d.notes.map((n) => n.id).toSet())), '// top\n// about D\n// about E\n// end\n');
    });

    test('top comments stay on top when a note comes before them', () {
      final d = body(text).insert(Steps.zero, 40, Steps.one).doc;
      expect(bodyOf(d).split('\n').first, '// top');
    });
  });

  group('chords', () {
    test('a chord splits when one note moves and merges back verbatim', () {
      final d = doc(chords);
      final a3 = idAt(d, 0, 'A3');
      final apart = d.move({a3}, Steps(1), 0);
      expect(apart.serialize(), contains('0      C4,E4      16   0.8\n1      A3         16   0.8\n'));
      expect(apart.move({a3}, Steps(-1), 0).serialize(), chords);
    });

    test('equal notes on separate lines merge into one chord line', () {
      expect(bodyOf(body('0 C3 1 0.5\n0 E3 1 0.5\n0 G3 2 0.5\n')), '0  C3,E3  1  0.5\n0 G3 2 0.5\n');
    });

    test('lines with different trailing comments stay apart', () {
      expect(bodyOf(body('0 C3 1 // a\n0 E3 1 // b\n')), '0 C3 1 // a\n0 E3 1 // b\n');
    });

    test('inversions', () {
      final d = doc(chords);
      final first = d.notes.where((n) => n.at == Steps.zero).map((n) => n.id).toSet();
      final up = d.invertUp(first);
      expect(up.serialize(), contains('\n0      C4,E4,A4   16   0.8\n'));
      final down = d.invertDown(first);
      expect(down.serialize(), contains('\n0      E3,A3,C4   16   0.8\n'));
      expect(up.invertDown(first).serialize(), chords);
      // A wide chord goes up by octaves until it is on top.
      final w = body('0 C3,E4 1\n');
      expect(w.invertUp(w.notes.map((n) => n.id).toSet()).notes.last.pitch, 72);
      final single = body('0 C3 1\n');
      expect(single.invertUp({1}).notes.single.pitch, 60);
      expect(single.invertDown({1}).notes.single.pitch, 36);
      expect(body('0 G9 1\n').invertUp({1}).notes.single.pitch, 127);
    });
  });

  group('edits', () {
    test('insert clamps and gets a fresh id; delete', () {
      final d = body('0 C3 1\n');
      final r = d.insert(Steps(-2), 200, Steps.zero, vel: 1.5);
      final n = r.doc.byId(r.id!)!;
      expect((n.at, n.pitch, n.len, n.vel), (Steps.zero, 127.0, kMinNoteLength, 1.0));
      expect(r.id, isNot(1));
      expect(d.notes.length, 1);
      expect(r.doc.delete({1}).notes.single.id, r.id);
      expect(identical(r.doc.notes.first, d.notes.first), isTrue);
    });

    test('move clamps the selection as a block', () {
      final d = body('2 C3 1\n4 G9 1\n');
      final m = d.move({1, 2}, Steps(-5), 3);
      expect(m.notes.map((n) => n.at), [Steps.zero, Steps(2)]);
      expect(m.notes.map((n) => n.pitch), [48, 127]);
      expect(d.move({}, Steps.one, 1), same(d));
    });

    test('triplet starts stay exact through moves and quantize', () {
      var d = body('13/3 C3 1/3\n');
      for (var i = 0; i < 6; i++) {
        d = d.move({1}, Steps(1, 3), 0);
      }
      expect(d.notes.single.at, Steps(19, 3));
      expect(bodyOf(d), '19/3  C3  1/3  1\n');
      d = d.move({1}, Steps(-2), 0);
      expect(bodyOf(d), '13/3 C3 1/3\n');
      expect(body('4.4 C3 0.3\n').quantize({1}, Steps(1, 3)).notes.single.at, Steps(13, 3));
    });

    test('resize, set length, quantize lengths', () {
      final d = body('0 C3 1\n');
      expect(d.resize({1}, Steps(1, 2)).notes.single.len, Steps(3, 2));
      expect(d.resize({1}, Steps(-5)).notes.single.len, kMinNoteLength);
      expect(d.setNoteLength({1}, Steps(1, 3)).notes.single.len, Steps(1, 3));
      final q = body('0.9 C3 0.1\n').quantize({1}, Steps.one).notes.single;
      expect((q.at, q.len), (Steps.one, Steps.one));
      expect(body('1.2 C3 2.6\n').quantize({1}, Steps(1, 2)).notes.single.len, Steps(5, 2));
    });

    test('copyAfter, duplicate, copy and paste', () {
      final d = body('0 C3 2\n2 E3 1 // e\n');
      final r = d.copyAfter({1, 2});
      expect(r.ids.length, 2);
      expect(r.doc.notes.length, 4);
      expect(r.ids.map((id) => r.doc.byId(id)!.at).toList()..sort(), [Steps(3), Steps(5)]);
      expect(r.ids.every((id) => r.doc.byId(id)!.trailingComment == null), isTrue);
      final clip = d.copy({1, 2});
      expect(clip.notes.map((n) => n.at), [Steps.zero, Steps(2)]);
      expect(clip.span, Steps(3));
      final p = d.paste(clip, Steps(13, 3));
      expect(p.ids.map((id) => p.doc.byId(id)!.at), [Steps(13, 3), Steps(19, 3)]);
      expect(d.duplicate({2}, Steps(8)).doc.notes.last.at, Steps(10));
      expect(d.paste(clip, Steps(4096)).ids.length, 1);
      expect(d.copy({}).isEmpty, isTrue);
    });

    test('split and join', () {
      final d = body('0 C3 4 0.5 slide // c\n');
      final s = d.split({1}, Steps(4, 3));
      expect(s.ids.length, 2);
      final left = s.doc.byId(1)!, right = s.doc.notes.last;
      expect((left.len, left.slide, left.trailingComment), (Steps(4, 3), false, 'c'));
      expect((right.at, right.len, right.slide, right.vel), (Steps(4, 3), Steps(8, 3), true, 0.5));
      expect(d.split({1}, Steps(4)).doc.notes.length, 1);
      final j = s.doc.join(s.ids);
      expect(j.ids, {1});
      expect(j.doc.serialize(), d.serialize());
      final apart = body('0 C3 1\n2 C3 1\n2 D3 1\n');
      expect(apart.join({1, 2, 3}).doc.notes.length, 3);
      expect(body('0 C3 2\n1 C3 3\n').join({1, 2}).doc.notes.single.len, Steps(4));
    });

    test('legato', () {
      final d = body('0 C3,E3 1\n13/3 G3 1\n8 C3 1\n');
      final l = d.legato({1, 2, 3, 4});
      expect(l.notes.map((n) => n.len), [Steps(13, 3), Steps(13, 3), Steps(11, 3), Steps.one]);
    });

    test('velocity, prob, ratchet, slide', () {
      final d = body('0 C3 1 0.8\n1 D3 1 0.95 prob 0.6 ratchet 4 slide\n');
      expect(d.addVelocity({1}, 0.1).notes.first.vel, 0.9);
      expect(d.addVelocity({1, 2}, 0.1).notes.map((n) => n.vel), [0.9, 1.0]);
      expect(d.addVelocity({1}, -2).notes.first.vel, 0);
      expect(d.setVelocity({2}, 0.3333).notes.last.vel, 0.333);
      var p = d;
      final seen = <double>[];
      for (var i = 0; i < 5; i++) {
        p = p.cycleProb({1, 2});
        seen.add(p.notes.first.prob);
        expect(p.notes.last.prob, p.notes.first.prob);
      }
      expect(seen, [0.75, 0.5, 0.25, 1, 0.75]);
      expect(d.cycleProb({2}).notes.last.prob, 0.25);
      expect([
        for (var r = d, i = 0; i < 4; i++) (r = r.cycleRatchet({1})).notes.first.ratchet
      ], [
        2,
        3,
        4,
        1
      ]);
      expect(d.cycleRatchet({2}).notes.last.ratchet, 1);
      expect(d.toggleSlide({1, 2}).notes.every((n) => n.slide), isTrue);
      expect(d.toggleSlide({2}).notes.last.slide, isFalse);
      expect(bodyOf(d.cycleRatchet({1}).cycleProb({1})),
          '0  C3  1  0.8  ratchet 2  prob 0.75\n1 D3 1 0.95 prob 0.6 ratchet 4 slide\n');
    });

    test('selection rectangles and cursor jumps', () {
      final d = body('0 C3 4\n4 E3 2\n4 G3 2\n8 C4 1\n');
      expect(d.notesIn(Steps(3), Steps(5), 40, 60), {1, 2, 3});
      expect(d.notesIn(Steps(5), Steps(3), 52, 52), {2});
      expect(d.notesIn(Steps(4), Steps(4), 0, 127), {2, 3});
      expect(d.notesIn(Steps(6), Steps(8), 0, 127), isEmpty);
      expect(d.nextNoteFrom(Steps.zero, 48, 1), 2);
      expect(d.nextNoteFrom(Steps(4), 52, 1), 3);
      expect(d.nextNoteFrom(Steps(4), 55, 1), 4);
      expect(d.nextNoteFrom(Steps(8), 60, 1), isNull);
      expect(d.nextNoteFrom(Steps(4), 52, -1), 1);
      expect(d.nextNoteFrom(Steps(8), 0, -1), 3);
      expect(d.nextNoteFrom(Steps.zero, 48, -1), isNull);
    });

    test('edits leave the original doc alone', () {
      final d = doc(acidLine);
      final before = d.serialize();
      d.move({1}, Steps.one, 1).delete({2}).addVelocity({3}, -0.5);
      expect(d.serialize(), before);
    });
  });

  group('generators', () {
    const aMinor = (root: 9, scale: [0, 2, 3, 5, 7, 8, 10]);

    test('euclid spreads pulses evenly and rotates', () {
      final d = body('');
      final e = d.euclid(at: Steps.zero, pulses: 3, steps: 8, cell: Steps.one, pitch: 36);
      expect(e.doc.notes.map((n) => n.at.toDouble()), [0, 3, 6]);
      expect(e.ids.length, 3);
      final r = d.euclid(at: Steps(4), pulses: 3, steps: 8, cell: Steps.one, pitch: 36, rotate: 1);
      expect(r.doc.notes.map((n) => n.at.toDouble()), [5, 8, 11]);
    });

    test('random in key keeps to the key and the seed', () {
      final d = body('');
      final a = d.randomInKey(
          at: Steps.zero, span: Steps(16), cell: Steps.one, lo: 57, hi: 69, density: 0.6, key: aMinor, seed: 3);
      final b = d.randomInKey(
          at: Steps.zero, span: Steps(16), cell: Steps.one, lo: 57, hi: 69, density: 0.6, key: aMinor, seed: 3);
      expect(a.doc.serialize(), b.doc.serialize());
      expect(a.doc.notes, isNotEmpty);
      for (final n in a.doc.notes) {
        expect(aMinor.scale.contains((n.pitch.round() - 9) % 12), isTrue);
        expect(n.pitch, inInclusiveRange(57, 69));
      }
    });

    test('arpeggiate turns a chord into a run', () {
      final d = body('0 C3,E3,G3 4\n4 A3 1\n');
      final a = d.arpeggiate({1, 2, 3, 4}, Steps.one);
      expect(a.doc.notes.map((n) => (n.at.toDouble(), n.pitch)).toList(),
          [(4.0, 57.0), (0.0, 48.0), (1.0, 52.0), (2.0, 55.0), (3.0, 48.0)]);
      final ud = d.arpeggiate({1, 2, 3}, Steps.one, order: 'updown');
      expect(ud.doc.notes.where((n) => n.at < Steps(4)).map((n) => n.pitch), [48, 52, 55, 52]);
    });

    test('humanize stays near the note and is repeatable', () {
      final d = body('0 C3 1 0.8\n4 D3 1 0.8\n');
      final h = d.humanize({1, 2}, timing: 0.25, velocity: 0.1, seed: 5);
      expect(h.serialize(), d.humanize({1, 2}, timing: 0.25, velocity: 0.1, seed: 5).serialize());
      for (final n in h.notes) {
        expect(n.at.toDouble(), greaterThanOrEqualTo(0));
        expect(n.vel, inInclusiveRange(0.7, 0.9));
      }
      expect((h.notes[1].at.toDouble() - 4).abs(), lessThanOrEqualTo(0.25));
    });

    test('chord stamp follows the key', () {
      final d = body('0 A2 2\n');
      expect(d.chordStamp({1}, key: aMinor).doc.notes.map((n) => n.pitch), [45, 48, 52]); // A C E
      expect(d.chordStamp({1}).doc.notes.map((n) => n.pitch), [45, 49, 52]); // A C# E
      expect(d.chordStamp({1}, key: aMinor, seventh: true).doc.notes.length, 4);
      expect(body('0 C3,E3,G3 1\n').chordStamp({1, 2, 3}).doc.notes.length, 6, reason: 'no doubled pitches');
      expect(body('0 G9 1\n').chordStamp({1}).doc.notes.length, 1, reason: 'nothing past 127');
    });

    test('shape sets velocity or chance per note, and changes nothing when the values match', () {
      final d = body('0 C3 1 0.5\n4 D3 1 0.5\n');
      final v = d.shape({1, 2}, (n) => n.at.toDouble() / 4);
      expect(v.notes.map((n) => n.vel), [0, 1]);
      expect(d.shape({2}, (n) => 0.25, chance: true).notes[1].prob, 0.25);
      expect(identical(d.shape({1, 2}, (n) => 0.5), d), isTrue);
    });

    test('reverse and invert pitch', () {
      final d = body('0 C3 1\n2 D3 2\n');
      expect(d.reverse({1, 2}).notes.map((n) => n.at.toDouble()), [3, 0]);
      expect(d.invertPitch({1, 2}, 49).notes.map((n) => n.pitch), [50, 48]);
    });
  });
}
