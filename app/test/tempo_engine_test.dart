// The tempo map and time signatures over dart:ffi (API 31, #207): needs CAW_LIB pointing at a desktop build of the
// engine library (CI sets it).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/tempo_map.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('the engine takes a tempo map and signatures and reports the position', () {
    final e = Engine.create();
    expect(e.setTempoMap(const [TempoPoint(0, 120), TempoPoint(8, 90, ramp: true)]), isTrue);
    expect(e.setTempoMap(const [TempoPoint(2, 120)]), isFalse, reason: 'the first point must be at beat 0');
    expect(e.setTempoMap(const [TempoPoint(0, 1200)]), isFalse, reason: 'BPM 1..999');
    expect(e.setTimeSignatures(const [TimeSignature(0, 0, 6, 8), TimeSignature(0, 6, 4, 4)]), isTrue);
    expect(e.setTimeSignatures(const [TimeSignature(0, 0, 6, 8), TimeSignature(0, 4, 4, 4)]), isFalse,
        reason: 'a change lands on a bar line');
    e.pullForTest(256);  // the audio thread takes them: the position is on the map it plays
    final p = e.position()!;
    expect(p.playing, isFalse);
    expect(p.frame, 0);
    expect(p.beat, 0);
    expect(p.bpm, 120);
    expect(p.bar, 0);
    expect((p.num, p.den), (6, 8));
    expect(e.setBpm(140), isTrue);
    expect(e.position()!.bpm, 120, reason: 'not yet played by the audio thread');
    e.pullForTest(256);
    expect(e.position()!.bpm, 140);
    e.dispose();
  }, skip: skip);

  test('a project with a tempo map syncs it in its JSON, and the meters read the step on it', () async {
    final e = Engine.create();
    final p = ProjectDoc(id: 'p', name: 'T', modules: [], layers: []);
    p.tempoMap = const [TempoPoint(0, 120), TempoPoint(8, 60, ramp: true)];
    p.timeSignatures = const [TimeSignature(0, 0, 3, 4), TimeSignature(2, 6, 6, 8)];
    final json = p.toEngineJson();
    expect(json, contains('"tempo_map"'));
    await e.setProject(json);
    e.pullForTest(256);
    final pos = e.position()!;
    expect((pos.num, pos.den), (3, 4));
    expect(pos.bpm, 120);
    expect(e.meters().step, 0);
    // A plain project leaves the map out of the JSON, as before.
    expect(ProjectDoc(id: 'q', name: 'Q', modules: [], layers: []).toEngineJson(), isNot(contains('tempo_map')));
    e.dispose();
  }, skip: skip);

  test('the count-in is whole bars of the signature: a 6/8 bar is six eighths', () async {
    final e = Engine.create();
    final p = ProjectDoc(id: 'p', name: 'T', modules: [], layers: []);
    p.bpm = 120;
    p.timeSignatures = const [TimeSignature(0, 0, 6, 8)];
    await e.setProject(p.toEngineJson());
    e.playCountInBars(0, 1);  // six clicks of an eighth at 120 BPM: 6 × 12000 samples at 48 kHz
    e.pullForTest(70000);
    expect(e.meters().playing, isFalse, reason: 'still counting in');
    e.pullForTest(4000);
    expect(e.meters().playing, isTrue);
    e.dispose();
  }, skip: skip);
}
