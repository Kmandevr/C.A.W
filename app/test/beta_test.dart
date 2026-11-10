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
}
