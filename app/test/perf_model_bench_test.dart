// Benchmarks the UI isolate's per-edit project work on a 16-track project: the engine JSON a sync or a live drag
// step builds, the undo snapshot and the undo restore. Prints BENCH lines (microseconds per call).
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perf_fixture.dart';

double _usPer(int runs, void Function() body) {
  for (var i = 0; i < 20; i++) { body(); }  // warm up the JIT
  final sw = Stopwatch()..start();
  for (var i = 0; i < runs; i++) { body(); }
  return sw.elapsedMicroseconds / runs;
}

void main() {
  test('project JSON costs on a 16-track project', () {
    final s = AppState();
    s.project = bigProject(s);
    s.starting = false;
    final line = s.project.modules.firstWhere((m) => m.id == 'pm8');
    final engineJson = s.project.toEngineJson();
    final snapshot = jsonEncode(s.project.toJson());
    var step = 0;
    final full = _usPer(200, () => s.project.toEngineJson(sourceOverrides: {line.id: '${line.source}${step++}'}));
    final live = _usPer(200, () => s.liveEngineJson(line.id, '${line.source}${step++}'));
    final snap = _usPer(200, () => jsonEncode(s.project.toJson()));
    final save = _usPer(100, () => const JsonEncoder.withIndent(' ').convert(s.project.toJson()));
    final toJson = _usPer(200, () => s.project.toJson());
    final restore = _usPer(50, () => ProjectDoc.fromJson(jsonDecode(snapshot) as Map<String, dynamic>));
    // ignore: avoid_print
    print('BENCH engine JSON ${engineJson.length} B: full ${full.toStringAsFixed(0)} us, live step '
        '${live.toStringAsFixed(0)} us; snapshot ${snapshot.length} B ${snap.toStringAsFixed(0)} us; '
        'restore ${restore.toStringAsFixed(0)} us; save encode ${save.toStringAsFixed(0)} us, toJson alone '
        '${toJson.toStringAsFixed(0)} us');
    // The live step sends exactly what a full build would.
    expect(s.liveEngineJson(line.id, 'x'), s.project.toEngineJson(
        voices: 32, swap: s.settings.swapTiming.name, sourceOverrides: {line.id: 'x'}));
    s.dispose();
  });
}
