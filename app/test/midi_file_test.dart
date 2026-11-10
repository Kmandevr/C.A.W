// Tests Standard MIDI File import and export: hand-built files (running status, velocity-0 note-offs, overlaps,
// sysex and meta skipping, bend ranges, MPE), malformed and truncated input failing closed, round trips through
// pattern clips, and placing imported clips in a project.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/midi_clips.dart';
import 'package:caw/model/midi_file.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> u16(int v) => [v >> 8 & 0xFF, v & 0xFF];
List<int> u32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
List<int> header(int format, int tracks, int division) => [...'MThd'.codeUnits, ...u32(6), ...u16(format), ...u16(tracks), ...u16(division)];
List<int> track(List<int> body) => [...'MTrk'.codeUnits, ...u32(body.length), ...body];
Uint8List smf(int format, int division, List<List<int>> tracks) =>
    Uint8List.fromList([...header(format, tracks.length, division), for (final t in tracks) ...track(t)]);
const eot = [0x00, 0xFF, 0x2F, 0x00];

PatternDoc doc(String source) {
  final r = PatternDoc.parse(source);
  expect(r.error, isNull);
  return r.doc!;
}

void main() {
  group('reading', () {
    test('format 0: running status, velocity-0 note-offs, tempo, meter, sysex and other meta skipped', () {
      final f = readMidiFile(smf(0, 96, [
        [
          0x00, 0xFF, 0x03, 0x04, ...'Lead'.codeUnits, // track name
          0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, // 500000 us = 120 BPM
          0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08, // 3/4
          0x00, 0xF0, 0x03, 0x7E, 0x7F, 0xF7, // sysex
          0x00, 0xFF, 0x01, 0x02, 0x68, 0x69, // text
          0x00, 0x90, 60, 100, // note on
          0x00, 64, 90, // running status: another note on
          0x60, 60, 0, // a quarter later: note on velocity 0 = off (running status)
          0x30, 0x80, 64, 0x40, // an eighth after that: note off
          ...eot,
        ],
      ]));
      expect(f.format, 0);
      expect(f.ppq, 96);
      expect(f.firstBpm, closeTo(120, 1e-9));
      expect((f.meterNumerator, f.meterDenominator), (3, 4));
      final t = f.tracks.single;
      expect(t.name, 'Lead');
      expect([for (final n in t.notes) (n.key, n.velocity, n.on, n.off)], [(60, 100, 0, 96), (64, 90, 0, 144)]);
    });

    test('meta and sysex cancel running status', () {
      expect(
          () => readMidiFile(smf(0, 96, [
                [0x00, 0x90, 60, 100, 0x00, 0xFF, 0x01, 0x00, 0x10, 60, 0, ...eot],
              ])),
          throwsA(isA<MidiFileException>().having((e) => e.message, 'message', contains('running status'))));
    });

    test('overlapping notes of one key: the first note-off ends the earliest note', () {
      final f = readMidiFile(smf(0, 4, [
        [0x00, 0x90, 60, 100, 0x01, 0x90, 60, 80, 0x02, 0x80, 60, 0, 0x03, 0x80, 60, 0, ...eot],
      ]));
      expect([for (final n in f.tracks.single.notes) (n.velocity, n.on, n.off)], [(100, 0, 3), (80, 1, 6)]);
    });

    test('a note left sounding ends with its track; all-notes-off ends every note on the channel', () {
      final f = readMidiFile(smf(0, 4, [
        [0x00, 0x90, 60, 100, 0x00, 0x91, 62, 100, 0x04, 0xB1, 123, 0, 0x04, 0xFF, 0x2F, 0x00],
      ]));
      expect([for (final n in f.tracks.single.notes) (n.key, n.off)], [(60, 8), (62, 4)]);
    });

    test('pitch bend inside a note, with the range set by RPN 0', () {
      final f = readMidiFile(smf(0, 96, [
        [
          0x00, 0xB0, 101, 0, 0x00, 0xB0, 100, 0, 0x00, 0xB0, 6, 12, // range 12 semitones
          0x00, 0xE0, 0x00, 0x50, // +12 * (0x2800 - 8192) / 8192 = +3 semitones... 0x50 << 7 = 10240: +3
          0x00, 0x90, 60, 100,
          0x30, 0xE0, 0x00, 0x40, // back to centre halfway
          0x30, 0x80, 60, 0,
          ...eot,
        ],
      ]));
      final n = f.tracks.single.notes.single;
      expect([for (final p in n.bend) (p.tick, p.value)], [(0, 3.0), (48, 0.0)]);
      final m = midiImport(smf(0, 96, [
        [0x00, 0xB0, 101, 0, 0x00, 0xB0, 100, 0, 0x00, 0xB0, 6, 12, 0x00, 0xE0, 0x00, 0x50, 0x00, 0x90, 60, 100,
          0x30, 0xE0, 0x00, 0x40, 0x30, 0x80, 60, 0, ...eot],
      ]), beatsPerBar: 4);
      final note = doc(m.clips.single.source).notes.single;
      expect(note.pitch, 63, reason: 'the bend sounding at the start is the pitch');
      expect(NoteExpression.valueAt(note.expr.bend, 0.25), closeTo(0, 1e-9));
      expect(NoteExpression.valueAt(note.expr.bend, 0.75), closeTo(-3, 1e-9), reason: 'a jump after a long gap holds');
    });

    test('SMPTE time is read as if at 120 BPM', () {
      // 25 fps, 40 ticks per frame: 1000 ticks a second, a quarter note (half a second) is 500 ticks.
      final f = readMidiFile(smf(0, (256 - 25) << 8 | 40, [
        [0x00, 0x90, 60, 100, 0x83, 0x74, 0x80, 60, 0, ...eot], // 500 ticks
      ]));
      final n = f.tracks.single.notes.single;
      expect(n.off * 1.0 / f.ppq, 1.0, reason: 'one quarter note');
    });
  });

  group('malformed files fail closed', () {
    final valid = smf(1, 96, [
      [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, ...eot],
      [0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0, 0x00, 0xE0, 0, 0x40, 0x00, 0xF0, 0x01, 0xF7, ...eot],
    ]);

    void fails(List<int> bytes, String reason) => expect(() => readMidiFile(Uint8List.fromList(bytes)),
        throwsA(isA<MidiFileException>().having((e) => e.message, 'message', contains(reason))));

    test('wrong or missing header', () {
      fails([], 'no MThd');
      fails('RIFF0000WAVEfmt '.codeUnits, 'no MThd');
      fails([...'MThd'.codeUnits, ...u32(60), 0, 1, 0, 1, 0, 96], 'header is cut off');
      fails(header(3, 1, 96), 'unknown MIDI file format 3');
      fails(header(1, 0, 96), 'no tracks');
      fails([...header(0, 1, 0), ...track(eot)], 'time division is 0');
      fails([...header(0, 1, 0xE300), ...track(eot)], 'SMPTE');
    });

    test('truncated tracks and events', () {
      fails(valid.sublist(0, valid.length - 3), 'cut off');
      fails([...header(0, 2, 96), ...track(eot)], 'says it has 2 tracks but holds 1');
      fails(smf(0, 96, [[0x00, 0x90, 60]]), 'ends in the middle of an event');
      fails(smf(0, 96, [[0x00, 60, 100]]), 'running status');
      fails(smf(0, 96, [[0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x90, 60, 100]]), 'longer than 4 bytes');
      fails(smf(0, 96, [[0x00, 0x90, 0x90, 100]]), 'status byte');
      fails(smf(0, 96, [[0x00, 0xFF, 0x01, 0x7F, 0x41]]), 'meta event runs past');
      fails(smf(0, 96, [[0x00, 0xF0, 0x7F, 0x41]]), 'system exclusive');
      fails(smf(0, 96, [[0x00, 0xF8]]), 'no place in a MIDI file');
    });

    test('a file over 16 MB is refused before it is read', () {
      final big = Uint8List(kMaxMidiFileBytes + 1)..setAll(0, valid);
      fails(big, 'bigger than 16 MB');
    });

    test('too many events', () {
      // Running-status note-offs, 3 bytes an event after the first.
      final body = <int>[0x00, 0x80, 60, 0];
      for (var i = 0; i < kMaxMidiEvents; i++) {
        body.addAll([0x00, 60, 0]);
      }
      fails(smf(0, 96, [body]), 'more than $kMaxMidiEvents events');
    });

    test('every truncation and random corruption of a valid file throws only MidiFileException', () {
      for (var cut = 0; cut < valid.length; cut++) {
        try {
          readMidiFile(valid.sublist(0, cut));
        } on MidiFileException {
          // expected for most cuts
        }
      }
      final rnd = math.Random(7);
      for (var i = 0; i < 3000; i++) {
        final b = Uint8List.fromList(valid);
        for (var k = 0; k < 1 + rnd.nextInt(4); k++) {
          b[14 + rnd.nextInt(b.length - 14)] = rnd.nextInt(256);
        }
        try {
          final f = readMidiFile(b);
          midiImport(b, beatsPerBar: 4);
          expect(f.tracks, isNotEmpty);
        } on MidiFileException {
          // fine: refused with a message
        }
      }
    });
  });

  group('import as clips', () {
    test('format 1: one clip per track, split by channel, conductor track skipped; meter only when asked', () {
      final bytes = smf(1, 96, [
        [0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0, 0x00, 0xFF, 0x58, 0x04, 0x06, 0x03, 0x18, 0x08, ...eot], // 100 BPM, 6/8
        [0x00, 0xFF, 0x03, 0x04, ...'Bass'.codeUnits, 0x00, 0x90, 36, 127, 0x83, 0x00, 0x80, 36, 0, ...eot],
        [0x00, 0xFF, 0x03, 0x05, ...'Drums'.codeUnits, 0x00, 0x99, 36, 100, 0x18, 0x89, 36, 0, 0x00, 0x90, 72, 64, 0x18, 0x80, 72, 0, ...eot],
      ]);
      final m = midiImport(bytes, beatsPerBar: 4);
      expect(m.bpm, closeTo(100, 1e-9));
      expect(m.beatsPerBar, 3);
      expect([for (final c in m.clips) (c.name, c.notes)], [('Bass', 1), ('Drums · ch 1', 1), ('Drums · ch 10', 1)]);
      final bass = doc(m.clips.first.source);
      expect(bass.notes.single.at, Steps.zero);
      expect(bass.notes.single.len, Steps(16), reason: '384 ticks at 96 per quarter: 4 quarters');
      expect(bass.notes.single.vel, 1);
      expect(bass.headerBars, 1, reason: 'a 4/4 bar');
      expect(doc(midiImport(bytes, beatsPerBar: 4, adoptMeter: true).clips.first.source).headerBars, 2,
          reason: '16 steps in 3/4 bars');
    });

    test('a file with no notes imports nothing', () {
      final m = midiImport(smf(0, 96, [eot]), beatsPerBar: 4);
      expect(m.clips, isEmpty);
      final s = AppState()..project = ProjectDoc(id: 'p', name: 'T');
      expect(placeMidiImport(s, m), contains('no notes'));
      expect(s.project.modules, isEmpty);
    });
  });

  group('round trips', () {
    const header = '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 2 bars\n---\n';

    void sameNotes(PatternDoc a, PatternDoc b) {
      expect(b.notes.length, a.notes.length);
      final x = [...a.notes]..sort((p, q) => p.at != q.at ? p.at.compareTo(q.at) : p.pitch.compareTo(q.pitch));
      final y = [...b.notes]..sort((p, q) => p.at != q.at ? p.at.compareTo(q.at) : p.pitch.compareTo(q.pitch));
      for (var i = 0; i < x.length; i++) {
        expect(y[i].at, x[i].at, reason: 'note $i start');
        expect(y[i].len, x[i].len, reason: 'note $i length');
        expect(y[i].pitch, closeTo(x[i].pitch, 0.001), reason: 'note $i pitch');
        expect(y[i].vel, closeTo(x[i].vel, 0.5 / 127 + 0.001), reason: 'note $i velocity');
        for (final u in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]) {
          expect(NoteExpression.valueAt(y[i].expr.bend, u), closeTo(NoteExpression.valueAt(x[i].expr.bend, u), 0.03),
              reason: 'note $i bend at $u');
          expect(NoteExpression.valueAt(y[i].expr.press, u), closeTo(NoteExpression.valueAt(x[i].expr.press, u), 0.02),
              reason: 'note $i pressure at $u');
          expect(NoteExpression.valueAt(y[i].expr.timbre, u), closeTo(NoteExpression.valueAt(x[i].expr.timbre, u), 0.02),
              reason: 'note $i timbre at $u');
        }
      }
    }

    test('plain notes: chords, triplets, overlaps of one key, velocities', () {
      final a = doc('$header'
          '0      C4,E4,G4  4    0.8\n'
          '4      A3        1/3  1\n'
          '13/3   A3        1/3  0.5\n'
          '14/3   A3        1/3  0.25\n'
          '8      D4        4    0.6\n'
          '10     D4        4    0.7\n'
          '31     G2        1    0.01\n');
      final bytes = patternToMidi(a, bpm: 128, beatsPerBar: 4);
      final f = readMidiFile(bytes);
      expect(f.mpe, isFalse);
      expect(f.firstBpm, closeTo(128, 0.01));
      expect(f.tracks.last.notes.every((n) => n.channel == 0), isTrue);
      final m = midiImport(bytes, beatsPerBar: 4);
      expect(m.clips.single.name, 'Riff');
      final b = doc(m.clips.single.source);
      expect(b.headerBars, 2);
      sameNotes(a, b);
    });

    test('per-note bend, microtones, pressure and timbre go out as MPE and come back', () {
      final a = doc('$header'
          '0   C4      4  0.9  bend 0:0 1:2\n'
          '0   E4      4  0.7  press 0:0.2 0.5:1 1:0.4  timbre 0:1 1:0\n'
          '4   121/2   2  0.5\n'
          '8   G3      8  1    bend 0:0 0.5:-7 1:12\n'
          '8   C3      8  1\n');
      final bytes = patternToMidi(a, bpm: 120, beatsPerBar: 4);
      final f = readMidiFile(bytes);
      expect(f.mpe, isTrue);
      final channels = [for (final n in f.tracks.last.notes) n.channel];
      expect(channels.every((c) => c >= 1 && c <= 15), isTrue, reason: 'member channels 2-16');
      expect(channels.sublist(0, 2).toSet().length, 2, reason: 'notes at one time get channels of their own');
      final m = midiImport(bytes, beatsPerBar: 4);
      expect(m.clips.length, 1, reason: 'an MPE track stays one clip');
      sameNotes(a, doc(m.clips.single.source));
    });

    test('ratchets export as their hits; a clip exports what it plays (offset, length, looping)', () {
      final a = doc('---\ncaw: 1\nkind: pattern\nname: Hat\nlength: 1 bar\n---\n'
          '0   F#2  4  1  ratchet 4\n'
          '8   C4   4  0.5\n');
      final hits = readMidiFile(patternToMidi(a, bpm: 120, beatsPerBar: 4)).tracks.last.notes;
      expect([for (final n in hits) (n.key, n.on, n.off)],
          [(42, 0, 240), (42, 240, 480), (42, 480, 720), (42, 720, 960), (60, 1920, 2880)]);
      // From step 10 of the 16-step pattern for 24 steps, looping: C4's tail, then the pattern from its start.
      final clip = ClipDoc(id: 'c', patternId: 'm', sourceOffsetSteps: 10, lengthSteps: 24);
      final notes = readMidiFile(patternToMidi(a, bpm: 120, beatsPerBar: 4, clip: clip)).tracks.last.notes;
      expect([for (final n in notes) (n.key, n.on ~/ 240, n.off ~/ 240)],
          [(60, 0, 2), (42, 6, 7), (42, 7, 8), (42, 8, 9), (42, 9, 10), (60, 14, 18), (42, 22, 23), (42, 23, 24)]);
      final once = ClipDoc(id: 'c', patternId: 'm', sourceOffsetSteps: 10, lengthSteps: 24, loop: false);
      expect(readMidiFile(patternToMidi(a, bpm: 120, beatsPerBar: 4, clip: once)).tracks.last.notes.length, 1);
    });
  });

  group('the project', () {
    ProjectDoc project() => ProjectDoc(id: 'p', name: 'T', bpm: 140)
      ..layers.addAll([LayerDoc(id: 'L1', name: 'Keys', color: 0), LayerDoc(id: 'L2', name: 'Bass', color: 1)]);

    Uint8List twoTracks(int usPerQuarter) => smf(1, 96, [
          [0x00, 0xFF, 0x51, 0x03, ...u32(usPerQuarter).sublist(1), ...eot],
          [0x00, 0xFF, 0x03, 0x01, 0x41, 0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0, ...eot],
          [0x00, 0xFF, 0x03, 0x01, 0x42, 0x00, 0x90, 48, 100, 0x60, 0x80, 48, 0, ...eot],
        ]);

    test('an empty project takes the file\'s tempo; several parts go on new tracks from the start', () {
      final s = AppState()..project = project();
      expect(projectHasNoClips(s.project), isTrue);
      final m = midiImport(twoTracks(600000), beatsPerBar: 4); // 100 BPM
      final msg = placeMidiImport(s, m, layer: s.project.layers.first, adoptTempo: true);
      expect(msg, contains('2 clips'));
      expect(s.project.bpm, 100);
      expect(s.project.layers.length, 4);
      expect([for (final l in s.project.layers.skip(2)) (l.name, l.clips.single.startSteps)], [('A', 0), ('B', 0)]);
      expect(s.project.module(s.project.layers.last.clips.single.patternId)!.source, contains('C3'));
    });

    test('a project with clips keeps its tempo; one part goes on the given track after its clips', () {
      final s = AppState()..project = project();
      final keys = s.project.layers.first;
      final existing = ModuleDoc(id: 'mx', name: 'A', source: PatternDoc.blank(name: 'A', bars: 1).serialize());
      s.project.modules.add(existing);
      keys.clips.add(ClipDoc(id: 'c0', patternId: 'mx', lengthSteps: 16));
      expect(projectHasNoClips(s.project), isFalse);
      final one = smf(0, 96, [
        [0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0, 0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0, ...eot],
      ]);
      final msg = placeMidiImport(s, midiImport(one, beatsPerBar: 4, name: 'A'), layer: keys);
      expect(msg, contains('kept the project\'s tempo'));
      expect(s.project.bpm, 140);
      expect(keys.clips.length, 2);
      expect(keys.clips.last.startSteps, 16);
      expect(s.project.module(keys.clips.last.patternId)!.name, 'A 2', reason: 'module names stay unique');
      // And the clip exports back.
      final back = readMidiFile(clipToMidi(s.project, keys.clips.last)!);
      expect(back.firstBpm, closeTo(140, 0.01));
      expect([for (final n in back.tracks.last.notes) (n.key, n.on, n.off)], [(60, 0, 960)]);
    });
  });
}
