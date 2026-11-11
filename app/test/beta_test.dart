// Tests the open-beta pieces: the shown version matches pubspec.yaml, and the problem report keeps recent errors
// without growing forever.
import 'dart:io';

import 'package:caw/model/problem_log.dart';
import 'package:caw/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version users see is pubspec.yaml\'s', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.substring(8).trim().split('+').first, appVersion);
  });

  test('the problem report carries the version and the last 20 errors', () {
    ProblemLog.clear();
    for (var i = 0; i < 25; i++) {
      ProblemLog.add(StateError('boom $i'), StackTrace.current);
    }
    expect(ProblemLog.entries, hasLength(20));
    final r = ProblemLog.report();
    expect(r, contains('C.A.W $appVersion'));
    expect(r, contains('boom 24'));
    expect(r, isNot(contains('boom 4\n')));
    ProblemLog.clear();
  });

  test('a split-debug-info trace keeps its header, which decoding it needs, and 8 frames', () {
    ProblemLog.clear();
    final trace = StackTrace.fromString([
      '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***',
      'pid: 1, tid: 2, name 1.ui',
      "build_id: 'abc'",
      'isolate_dso_base: 7000000000, vm_dso_base: 7000000000',
      'isolate_instructions: 7000001000, vm_instructions: 7000002000',
      for (var i = 0; i < 12; i++) '#${'$i'.padLeft(2, '0')} abs 70000${i}000 virt 00${i}000 _kDartIsolateSnapshotInstructions+0x$i',
    ].join('\n'));
    ProblemLog.add(StateError('boom'), trace);
    final entry = ProblemLog.entries.single;
    expect(entry, contains("build_id: 'abc'"));
    expect(entry, contains('isolate_dso_base'));
    expect(entry, contains('#07 '));
    expect(entry, isNot(contains('#08 ')));
    ProblemLog.clear();
  });
}
