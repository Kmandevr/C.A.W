// The tempo map, time signatures, sections and markers (#207): bounded parsing, v2 → v3 loading, round trips, the
// beat↔seconds and bar maths against the shared vectors, the engine interface, and section moves with their contents.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_markers.dart';
import 'package:caw/model/arrange_tempo.dart';
import 'package:caw/model/midi_clips.dart';
import 'package:caw/model/midi_file.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/tempo_map.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared vectors: the engine's file once it lands, else the app's own from the same formula.
Map<String, dynamic> vectors() {
  for (final path in ['../engine/tests/references/tempo_vectors.json', 'test/fixtures/tempo_vectors.json']) {
    final f = File(path);
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  throw StateError('no tempo vectors');
}

ProjectDoc roundTrip(ProjectDoc p) => ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

/// Records what the app hands the engine (the binding's stand-in).
class FakeTempoEngine implements TempoEngine {
  final maps = <List<TempoPoint>>[];
  final sigs = <List<TimeSignature>>[];
  @override
  bool setTempoMap(List<TempoPoint> points) {
    maps.add(points);
    return true;
  }

  @override
  bool setTimeSignatures(List<TimeSignature> signatures) {
    sigs.add(signatures);
    return true;
  }
}

void main() {
  group('maths against the vectors', () {
    final v = vectors();
    for (final c in (v['tempo'] as List).cast<Map<String, dynamic>>()) {
      test('beat↔seconds: ${c['name']}', () {
        final map = tempoMapFromJson(c['tempo_map'], fallbackBpm: 120, maxBeat: 1e9)!;
        final m = TempoMath(map);
        for (final pair in (c['beat_seconds'] as List).cast<List>()) {
          final beat = (pair[0] as num).toDouble(), sec = (pair[1] as num).toDouble();
          expect(m.secondsAt(beat), closeTo(sec, 1e-9), reason: 'seconds at beat $beat');
          expect(m.beatAt(sec), closeTo(beat, 1e-9), reason: 'beat at $sec s');
        }
      });
    }
    for (final c in (v['bars'] as List).cast<Map<String, dynamic>>()) {
      test('bar.beat: ${c['name']}', () {
        final sigs = timeSignaturesFromJson(c['time_signatures'], fallbackNum: 4, maxBar: 1 << 20)!;
        for (final (i, s) in (c['time_signatures'] as List).indexed) {
          expect(sigs[i].beat, closeTo(((s as Map)['beat'] as num).toDouble(), 1e-12));
        }
        final b = BarMath(sigs);
        for (final row in (c['bar_beat'] as List).cast<List>()) {
          final beat = (row[0] as num).toDouble();
          final at = b.barBeatAt(beat);
          expect(at.bar, row[1], reason: 'bar at beat $beat');
          expect(at.beat, closeTo((row[2] as num).toDouble(), 1e-9), reason: 'beat in the bar at $beat');
          expect(b.beatOf(at.bar, at.beat), closeTo(beat, 1e-9));
        }
      });
    }

    test('a ramp is linear in BPM over beats, and the closed form matches the contract', () {
      final m = TempoMath(const [TempoPoint(0, 120), TempoPoint(32, 96, ramp: true)]);
      expect(m.bpmAt(16), closeTo(108, 1e-12));
      expect(m.bpmAt(40), 96);
      // t = 60·Δbeat/(bpm1 − bpm0)·ln(bpm1/bpm0)
      expect(m.secondsAt(32), closeTo(60 * 32 / (96 - 120) * math.log(96 / 120), 1e-9));
    });
  });

  group('parsing is bounded', () {
    test('tempo points: limits, sorting, one a beat, a point at 0', () {
      final raw = [
        {'beat': 8, 'bpm': 5000, 'ramp': true},
        {'beat': 4, 'bpm': 0.1},
        {'beat': -1, 'bpm': 100},
        {'beat': double.nan, 'bpm': 100},
        {'beat': 4, 'bpm': 90},
        'junk',
        {'beat': 2e9, 'bpm': 100},
      ];
      final map = tempoMapFromJson(raw, fallbackBpm: 133, maxBeat: 1e6)!;
      expect(map, const [TempoPoint(0, 133), TempoPoint(4, 90), TempoPoint(8, 999, ramp: true)]);
      expect(tempoMapFromJson('nope', fallbackBpm: 120, maxBeat: 1), isNull);
      final many = [for (var i = 0; i < 10000; i++) {'beat': i, 'bpm': 100 + i % 50}];
      expect(tempoMapFromJson(many, fallbackBpm: 120, maxBeat: 1e6)!.length, kMaxTempoPoints);
      // The first point never ramps.
      expect(tempoMapFromJson([{'beat': 0, 'bpm': 90, 'ramp': true}], fallbackBpm: 1, maxBeat: 9)!.single.ramp, isFalse);
    });

    test('signatures: num 1–32, den a power of two to 32, the first at bar 0, beats recomputed', () {
      final raw = [
        {'bar': 4, 'beat': 999, 'num': 3, 'den': 4},
        {'bar': 2, 'num': 33, 'den': 4},
        {'bar': 3, 'num': 5, 'den': 3},
        {'bar': 6, 'num': 2.5, 'den': 4},
        {'bar': 8, 'num': 7, 'den': 8},
      ];
      final sigs = timeSignaturesFromJson(raw, fallbackNum: 4, maxBar: 1000)!;
      expect(sigs, const [TimeSignature(0, 0, 4, 4), TimeSignature(4, 16, 3, 4), TimeSignature(8, 28, 7, 8)]);
      final many = [for (var i = 0; i < 5000; i++) {'bar': i, 'num': 2 + i % 2, 'den': 4}];
      expect(timeSignaturesFromJson(many, fallbackNum: 4, maxBar: 1 << 20)!.length, kMaxTimeSignatures);
      // A change that repeats the one before it changes nothing and goes.
      expect(timeSignaturesFromJson([{'bar': 0, 'num': 3, 'den': 4}, {'bar': 2, 'num': 3, 'den': 4}],
          fallbackNum: 4, maxBar: 9)!.length, 1);
    });

    test('sections and markers: limits, names cut to 64, sections kept apart', () {
      final raw = ProjectDoc(id: 'p', name: 'x').toJson()
        ..['sections'] = [
          for (var i = 0; i < 300; i++) {'id': 's$i', 'name': 'N' * 100, 'color': 3, 'start': i * 4, 'end': i * 4 + 4},
          {'id': 'bad', 'name': 'x', 'start': 9, 'end': 3},
        ]
        ..['markers'] = [for (var i = 0; i < 1500; i++) {'id': 'm$i', 'name': 'M', 'beat': i}];
      final p = ProjectDoc.fromJson(raw);
      expect(p.sections.length, kMaxSections);
      expect(p.sections.first.name.length, 64);
      expect(p.markers.where((m) => !m.isRegion).length, kMaxMarkers);
    });
  });

  group('the project format', () {
    test('goes up to v3 and round-trips the map, signatures, sections and markers', () {
      final p = ProjectDoc(id: 'p', name: 'Song', bpm: 120,
          tempoMap: const [TempoPoint(0, 120), TempoPoint(32, 96, ramp: true)],
          timeSignatures: const [TimeSignature(0, 0, 4, 4), TimeSignature(8, 0, 3, 4)],
          markers: [
            MarkerDoc(id: 's1', name: 'Verse', startSteps: 0, endSteps: 128, color: 3),
            MarkerDoc(id: 'm1', name: 'Drop', startSteps: 256),
          ]);
      final j = p.toJson();
      expect(j['caw_app_project'], 3);
      expect(j['bpm'], 120, reason: 'older readers still find the starting tempo');
      expect(j['tempo_map'], [
        {'beat': 0.0, 'bpm': 120.0, 'ramp': false},
        {'beat': 32.0, 'bpm': 96.0, 'ramp': true},
      ]);
      expect(j['time_signatures'], [
        {'bar': 0, 'beat': 0.0, 'num': 4, 'den': 4},
        {'bar': 8, 'beat': 32.0, 'num': 3, 'den': 4},
      ]);
      expect(j['sections'], [{'id': 's1', 'name': 'Verse', 'color': 3, 'start': 0.0, 'end': 32.0}]);
      expect((j['markers'] as List).single, containsPair('beat', 64.0));
      final back = roundTrip(p);
      expect(back.tempoMap, p.tempoMap);
      expect(back.timeSignatures, p.timeSignatures);
      expect([for (final m in back.markers) (m.id, m.startSteps, m.endSteps)], [('s1', 0, 128), ('m1', 256, null)]);
    });

    test('a v2 project loads as one tempo in its own meter, its regions as sections', () {
      final p = ProjectDoc.fromJson({
        'caw_app_project': 2, 'id': 'old', 'name': 'Old', 'bpm': 97.5, 'beats_per_bar': 3,
        'markers': [
          {'id': 'r1', 'name': 'A', 'start_steps': 0, 'end_steps': 48, 'color': 2},
          {'id': 'r2', 'name': 'B', 'start_steps': 32, 'end_steps': 96},
          {'id': 'r3', 'name': 'C', 'start_steps': 40, 'end_steps': 90},
          {'id': 'k', 'name': 'Hit', 'start_steps': 12},
        ],
      });
      expect(p.tempoMap, const [TempoPoint(0, 97.5)]);
      expect(p.timeSignatures, const [TimeSignature(0, 0, 3, 4)]);
      expect(p.plainTempo, isTrue);
      // Overlapping regions are kept apart: B starts where A ends; C has no room left and becomes a marker.
      expect([for (final s in p.sections) (s.id, s.startSteps, s.endSteps)], [('r1', 0, 48), ('r2', 48, 96)]);
      expect({for (final m in p.markers) if (!m.isRegion) m.id}, {'r3', 'k'});
    });

    test('a newer format is refused', () {
      expect(() => ProjectDoc.fromJson({'caw_app_project': 4, 'id': 'x'}), throwsA(isA<NewerProjectFormat>()));
    });

    test('bpm and beatsPerBar are the first tempo point and signature', () {
      final p = ProjectDoc(id: 'p', name: 'x', bpm: 100, tempoMap: const [TempoPoint(0, 100), TempoPoint(8, 140)]);
      p.bpm = 110;
      expect(p.tempoMap, const [TempoPoint(0, 110), TempoPoint(8, 140)]);
      p.beatsPerBar = 6;
      expect(p.timeSignatures.single, const TimeSignature(0, 0, 6, 4));
      p.timeSignatures = const [TimeSignature(0, 0, 6, 8)];
      expect((p.beatsPerBar, p.stepsPerBar), (3, 12));
    });

    test('the song seconds and the playhead follow the map', () {
      final p = ProjectDoc(id: 'p', name: 'x', bpm: 120, loopBars: 16, tempoMap: const [TempoPoint(0, 120), TempoPoint(16, 60)]);
      // 16 beats at 120 (8 s) then 48 beats at 60 (48 s): the 16-bar loop takes 56 s.
      expect(p.engineLoopSteps, 256);
      expect(p.songSeconds, closeTo(56, 1e-9));
      // Halfway through in time (28 s) is 8 s + 20 beats at 60: beat 36, step 144.
      expect(p.stepAtLoopFraction(0.5), closeTo(144, 1e-9));
    });
  });

  group('the engine interface', () {
    late AppState s;
    setUp(() => s = AppState(settings: Settings()));
    tearDown(() => s.dispose());

    test('a plain project sends nothing past the JSON; a map is sent, and dropping it sends the plain one once', () {
      final fake = FakeTempoEngine();
      s.tempoEngine = fake;
      s.project = ProjectDoc(id: 'p', name: 'x', bpm: 120);
      s.pushTempo();
      expect(fake.maps, isEmpty);
      s.addTempoPoint(16, bpm: 90);
      s.pushTempo();
      expect(fake.maps.last, const [TempoPoint(0, 120), TempoPoint(16, 90)]);
      expect(fake.sigs.last, const [TimeSignature(0, 0, 4, 4)]);
      s.pushTempo();
      expect(fake.maps, hasLength(2), reason: 'a map goes with every sync, as the JSON\'s bpm may replace it');
      s.removeTempoPoint(1);
      s.pushTempo();
      expect(fake.maps.last, const [TempoPoint(0, 120)]);
      s.pushTempo();
      expect(fake.maps, hasLength(3));
    });
  });

  group('tempo and signature edits', () {
    late AppState s;
    setUp(() {
      s = AppState(settings: Settings());
      s.project = ProjectDoc(id: 'p', name: 'x', bpm: 120);
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
    });
    tearDown(() => s.dispose());

    test('add, move, ramp and delete a point, each one undo step', () async {
      final i = s.addTempoPoint(16, bpm: 90);
      expect(i, 1);
      s.endUndoStep();
      s.moveTempoPoint(1, beat: 20, bpm: 100.04);
      s.moveTempoPoint(1, beat: 24, bpm: 80);
      s.endUndoStep();
      expect(s.project.tempoMap[1], const TempoPoint(24, 80));
      s.setTempoRamp(1, true);
      expect(s.project.tempoMap[1].ramp, isTrue);
      s.moveTempoPoint(0, beat: 5);
      expect(s.project.tempoMap[0].beat, 0, reason: 'the first point stays at the start');
      s.removeTempoPoint(0);
      expect(s.project.tempoMap, hasLength(2), reason: 'the first point never goes');
      s.removeTempoPoint(1);
      expect(s.project.tempoMap, hasLength(1));
      s.undo();
      expect(s.project.tempoMap[1].ramp, isTrue);
      s.undo();
      expect(s.project.tempoMap[1].ramp, isFalse);
      s.undo();
      expect(s.project.tempoMap[1], const TempoPoint(16, 90), reason: 'the whole drag is one step');
    });

    test('a signature change lands on a bar and moves the bars after it', () {
      s.setTimeSignature(8, 3, 4);
      expect(s.project.bars.beatOfBar(9), 35);
      expect(s.project.bars.label(35), '10.1');
      s.setTimeSignature(8, 4, 4);
      expect(s.project.timeSignatures, hasLength(1), reason: 'the same as before it: no change');
      s.setTimeSignature(8, 7, 8);
      s.removeTimeSignature(8);
      expect(s.project.timeSignatures, hasLength(1));
      s.setTimeSignature(2, 40, 4);
      expect(s.project.timeSignatures, hasLength(1), reason: 'out of range');
    });
  });

  group('sections take their contents', () {
    late AppState s;
    ProjectDoc project() => ProjectDoc(id: 'p', name: 'Sections', bpm: 120,
        tempoMap: const [TempoPoint(0, 120), TempoPoint(32, 96, ramp: true), TempoPoint(48, 96)],
        timeSignatures: const [TimeSignature(0, 0, 4, 4), TimeSignature(8, 0, 3, 4), TimeSignature(12, 0, 4, 4)],
        modules: [ModuleDoc(id: 'pat', name: 'Riff', source: '---\nkind: pattern\nlength: 16\n---\n0 C3 4 1\n')],
        automation: [
          ProjectAutomationLaneDoc(targetType: 'instrument', target: 'cutoff', layerId: 'a', points: [
            AutomationPointDoc(step: 8, value: 0.1),
            AutomationPointDoc(step: 140, value: 0.5),
            AutomationPointDoc(step: 260, value: 0.9),
          ]),
        ],
        layers: [
          LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
            ClipDoc(id: 'v', patternId: 'pat', startSteps: 0, lengthSteps: 16),
            ClipDoc(id: 'c', patternId: 'pat', startSteps: 128, lengthSteps: 16),
          ]),
        ],
        markers: [
          MarkerDoc(id: 'verse', name: 'Verse', startSteps: 0, endSteps: 128),
          // The chorus: bars 8–11, in 3/4 from bar 8, ramping from 120 down to 96 by its end.
          MarkerDoc(id: 'chorus', name: 'Chorus', startSteps: 128, endSteps: 176),
          MarkerDoc(id: 'out', name: 'Outro', startSteps: 400, endSteps: 464),
        ]);
    setUp(() {
      s = AppState(settings: Settings());
      s.project = project();
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
    });
    tearDown(() => s.dispose());

    MarkerDoc section(String id) => s.project.markers.firstWhere((m) => m.id == id);
    ClipDoc clip(String id) => s.project.layers.first.clips.firstWhere((c) => c.id == id);

    test('a move takes clips, automation, tempo and signatures, as one undo step', () {
      final before = jsonEncode(s.project.toJson());
      expect(s.moveSection(section('chorus'), 256), isNotNull);
      expect((section('chorus').startSteps, section('chorus').endSteps), (256, 304));
      expect(clip('c').startSteps, 256);
      expect(clip('v').startSteps, 0);
      expect([for (final q in s.project.automation.single.points) q.step], [8, 268], reason: 'what was where it lands gives way');
      // At its new place the chorus starts in 3/4 and goes back to what was there after it.
      final bars = s.project.bars;
      expect(bars.signatureAt(64).label, '3/4');
      expect(bars.signatureAt(76).label, '4/4');
      // Its old place has the music after it: no 3/4 left at beat 32.
      expect(bars.signatureAt(33).label, '4/4');
      s.undo();
      expect(jsonEncode(s.project.toJson()), before);
    });

    test('a move never lands on another section', () {
      expect(s.moveSection(section('chorus'), 380), isNull);
      expect(section('chorus').startSteps, 128);
    });

    test('a copy goes to the first free place after it, with copies of all of it', () {
      final copy = s.copySection(section('verse'))!;
      expect((copy.startSteps, copy.endSteps), (176, 304), reason: 'past the chorus, before the outro');
      expect(copy.name, 'Verse copy');
      expect(s.project.layers.first.clips.where((c) => c.startSteps == 176), hasLength(1));
      expect(section('verse').startSteps, 0);
    });

    test('a delete takes its clips, automation and tempo changes; undo brings them back', () {
      s.deleteSection(section('chorus'));
      expect(s.project.markers.any((m) => m.id == 'chorus'), isFalse);
      expect(s.project.layers.first.clips.map((c) => c.id), ['v']);
      expect([for (final q in s.project.automation.single.points) q.step], [8, 260]);
      expect(s.project.tempoMap.where((t) => t.ramp), isEmpty);
      s.undo();
      expect(section('chorus').startSteps, 128);
      expect(s.project.tempoMap, hasLength(3));
    });

    test('a new section fits between the others', () {
      final made = s.addMarker(180, end: 600);
      expect((made.startSteps, made.endSteps), (180, 400));
      final inside = s.addMarker(10, end: 20);
      expect(inside.isRegion, isFalse, reason: 'no room inside the verse: a marker');
    });
  });

  group('MIDI files carry the map', () {
    MidiFile file() => MidiFile(ppq: 960, tempos: const [MidiTempo(0, 120), MidiTempo(3840, 90)], meters: const [
      MidiMeter(0, 4, 4), MidiMeter(8 * 960, 6, 8),
    ], tracks: [MidiTrack(name: 'Keys', notes: [MidiNote(key: 60, velocity: 100, on: 0, off: 480)])]);

    test('tempo and time signature meta events are written as the standard says, and read back', () {
      final bytes = writeMidiFile(file());
      bool has(List<int> seq) {
        for (var i = 0; i + seq.length <= bytes.length; i++) {
          var ok = true;
          for (var k = 0; k < seq.length && ok; k++) {
            ok = bytes[i + k] == seq[k];
          }
          if (ok) return true;
        }
        return false;
      }
      // FF 51 03 tttttt: microseconds a quarter note (500000 at 120, 666667 at 90).
      expect(has([0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]), isTrue);
      expect(has([0xFF, 0x51, 0x03, 0x0A, 0x2C, 0x2B]), isTrue);
      // FF 58 04 nn dd cc bb: 6/8 is 6 and 2^3.
      expect(has([0xFF, 0x58, 0x04, 0x06, 0x03, 24, 8]), isTrue);
      final back = readMidiFile(bytes);
      expect([for (final m in back.meters) (m.tick, m.numerator, m.denominator)], [(0, 4, 4), (7680, 6, 8)]);
      expect(midiTempoMap(back)!.map((t) => (t.beat, t.bpm.toStringAsFixed(3))), [(0.0, '120.000'), (4.0, '90.000')]);
      expect(midiSignatures(back), const [TimeSignature(0, 0, 4, 4), TimeSignature(2, 8, 6, 8)]);
    });

    test('an import adopting the tempo takes the whole map and the signatures', () {
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = ProjectDoc(id: 'p', name: 'x', bpm: 140);
      final m = midiImport(Uint8List.fromList(writeMidiFile(file())), beatsPerBar: 4, adoptMeter: true);
      final message = placeMidiImport(s, m, adoptTempo: true);
      expect(message, contains('with its changes'));
      expect(s.project.tempoMap.map((t) => (t.beat, t.bpm)), [(0.0, 120.0), (4.0, 90.0)]);
      expect(s.project.timeSignatures.last, const TimeSignature(2, 8, 6, 8));
    });
  });
}
