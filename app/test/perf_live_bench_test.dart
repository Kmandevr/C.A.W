// Benchmarks a piano-roll drag heard live on a 16-track project (needs CAW_LIB): 60 live pattern steps through the
// real engine, timing the whole round trip and the share spent on the UI isolate. Prints BENCH lines.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perf_fixture.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  test('60 live pattern steps on 16 tracks', () async {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = bigProject(s);
    s.starting = false;
    s.useAudioDevice = false;
    s.ready = true;
    addTearDown(s.dispose);
    s.info = await s.engine!.setProject(s.project.toEngineJson());
    s.engine!.play();
    final line = s.project.modules.firstWhere((m) => m.id == 'pm8');
    // No sound card here: each step, the audio a device would pull in 33 ms runs (it frees the swapped programs).
    Future<void> step(int i) async {
      await s.livePattern(line.id, '${line.source}${i % 16} C4 1 1\n');
      s.engine!.pullForTest(1600);
    }
    for (var i = 0; i < 10; i++) { await step(i); }
    var audio = 0;
    final pull = Stopwatch();
    final sw = Stopwatch()..start();
    for (var i = 0; i < 60; i++) {
      await s.livePattern(line.id, '${line.source}${i % 16} C4 1 1\n');
      pull.start();
      s.engine!.pullForTest(1600);
      pull.stop();
      audio++;
    }
    final perStep = (sw.elapsedMicroseconds - pull.elapsedMicroseconds) / audio;
    // ignore: avoid_print
    print('BENCH live step round trip ${perStep.toStringAsFixed(0)} us (audio pulls left out)');
    expect(s.engineError, isNull);
  }, skip: skip);
}
