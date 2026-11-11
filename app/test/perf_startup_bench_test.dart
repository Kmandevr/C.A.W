// Benchmarks the storage work at startup with 20 saved 16-track projects: listing them (every file decoded for its
// name) and opening one. Reports the wall time and the UI isolate's longest stall (the largest gap between 1 ms
// timer ticks while the work runs), which is what a user feels as a frozen first frame. Prints BENCH lines.
import 'dart:async';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perf_fixture.dart';

/// The work's wall time, the UI isolate's longest stall and its time blocked in all (each tick's lateness summed).
Future<(int wallUs, int stallUs, int busyUs)> _measure(Future<void> Function() work) async {
  final sw = Stopwatch()..start();
  var last = 0, stall = 0, busy = 0;
  void gap(int now) {
    final g = now - last;
    if (g > stall) stall = g;
    if (g > 1500) busy += g - 1000;
    last = now;
  }
  final t = Timer.periodic(const Duration(milliseconds: 1), (_) => gap(sw.elapsedMicroseconds));
  await work();
  gap(sw.elapsedMicroseconds);
  t.cancel();
  return (sw.elapsedMicroseconds, stall, busy);
}

void main() {
  test('listing and opening saved projects', () async {
    final root = await Directory.systemTemp.createTemp('caw-perf');
    addTearDown(() => root.delete(recursive: true));
    final storage = ProjectStorage(root);
    final s = AppState(settings: Settings());
    for (var i = 0; i < 20; i++) {
      final p = bigProject(s, notes: 1000); // about 0.4 MB each, long patterns
      p.name = 'Song $i';
      await storage.save(p);
    }
    final id = (await storage.list()).first.id;
    for (var i = 0; i < 3; i++) { await storage.list(); await storage.load(id); } // warm up
    final list = await _measure(() => storage.list());
    final open = await _measure(() => storage.load(id));
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    // ignore: avoid_print
    print('BENCH 20 saved projects: list ${ms(list.$1)} ms (UI blocked ${ms(list.$3)} ms, longest ${ms(list.$2)}); '
        'open one ${ms(open.$1)} ms (UI blocked ${ms(open.$3)} ms, longest ${ms(open.$2)})');
    expect((await storage.list()).length, 20);
    s.dispose();
  });
}
