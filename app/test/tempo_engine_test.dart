// The tempo map and time signatures over dart:ffi (API 31, #207): needs CAW_LIB pointing at a desktop build of the
// engine library (CI sets it).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('the engine takes a tempo map and signatures and reports the position', () {
    final e = Engine.create();
    expect(e.setTempoMap(const [EngineTempoPoint(0, 120), EngineTempoPoint(8, 90, ramp: true)]), isTrue);
    expect(e.setTempoMap(const [EngineTempoPoint(2, 120)]), isFalse, reason: 'the first point must be at beat 0');
    expect(e.setTempoMap(const [EngineTempoPoint(0, 1200)]), isFalse, reason: 'BPM 1..999');
    expect(e.setTimeSignatures(const [EngineTimeSig(0, 6, 8), EngineTimeSig(6, 4, 4)]), isTrue);
    expect(e.setTimeSignatures(const [EngineTimeSig(0, 6, 8), EngineTimeSig(4, 4, 4)]), isFalse,
        reason: 'a change lands on a bar line');
    final p = e.position()!;
    expect(p.playing, isFalse);
    expect(p.frame, 0);
    expect(p.beat, 0);
    expect(p.bpm, 120);
    expect(p.bar, 0);
    expect((p.num, p.den), (6, 8));
    expect(e.setBpm(140), isTrue);
    expect(e.position()!.bpm, 140);
    e.dispose();
  }, skip: skip);

  test('MIDI export and import keep the tempo map and signatures', () async {
    final dir = await Directory.systemTemp.createTemp('caw_tempo');
    final path = '${dir.path}/song.mid';
    const pattern = '---\nkind: pattern\nlength: 4 bars\n---\n0 C4 1 1\n';
    expect(
        Engine.exportPatternSong(pattern, path,
            tempoMap: const [EngineTempoPoint(0, 120), EngineTempoPoint(8, 96), EngineTempoPoint(16, 150)],
            timeSignatures: const [EngineTimeSig(0, 4, 4), EngineTimeSig(8, 3, 4)]),
        isNull);
    final m = Engine.midiImport(await File(path).readAsBytes());
    expect(m.pattern, contains('kind: pattern'));
    expect([for (final t in m.tempoMap) (t.beat, t.bpm, t.ramp)], [(0.0, 120.0, false), (8.0, 96.0, false), (16.0, 150.0, false)]);
    expect([for (final s in m.timeSignatures) (s.bar, s.beat, s.num, s.den)], [(0, 0.0, 4, 4), (2, 8.0, 3, 4)]);
    await dir.delete(recursive: true);
  }, skip: skip);
}
