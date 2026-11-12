// Keeps the last errors the app hit (uncaught Dart and Flutter errors), so "Report a problem" can include them.
// It also counts each error's type and C.A.W source line for the anonymous telemetry report and the feedback form's
// error log (beta readiness plan H2 `errors`): never the message, which can quote a file or a path.
import 'dart:collection';
import 'dart:io';

import '../version.dart';

class ProblemLog {
  ProblemLog._();

  static const _max = 20;
  static final _entries = ListQueue<String>();
  static final _recent = ListQueue<({String type, String where})>();

  /// Called with each error's type and relative source line (the telemetry day's counts); null when unused.
  static void Function(String type, String where)? onError;

  /// The newest errors last.
  static List<String> get entries => List.unmodifiable(_entries);

  static void add(Object error, StackTrace? stack) {
    final all = (stack?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    // Release builds split their debug info out (CI's --split-debug-info): a trace is then addresses after a header
    // (build id, load bases) that `flutter symbolize` needs, so the header is kept with the first 8 frames.
    final header = all.isNotEmpty && all.first.startsWith('***') ? all.takeWhile((l) => !l.startsWith('#')).length : 0;
    final lines = all.take(header + 8).join('\n');
    // An error's text can quote a file's contents or long paths: each entry is cut short.
    var text = '$error';
    if (text.length > 500) text = '${text.substring(0, 500)}…';
    _entries.addLast('${DateTime.now().toUtc().toIso8601String()} $text${lines.isEmpty ? '' : '\n$lines'}');
    while (_entries.length > _max) {
      _entries.removeFirst();
    }
    final where = sourceLine(stack?.toString() ?? '');
    if (where == null) return; // no frame in C.A.W's code that can be named without a path
    final type = errorType(error);
    _recent.addLast((type: type, where: where));
    while (_recent.length > _max) {
      _recent.removeFirst();
    }
    onError?.call(type, where);
  }

  static void clear() {
    _entries.clear();
    _recent.clear();
  }

  /// The error's type as H2's `errors[].type`: the runtime type's name with any generic arguments dropped.
  static String errorType(Object error) {
    final t = error.runtimeType.toString().split('<').first;
    return RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]{0,79}$').hasMatch(t) ? t : 'Error';
  }

  /// The first frame of [trace] in C.A.W's own code as a relative location (H2 update 2026-11-12):
  /// `package:caw/ui/shell.dart:120`, or `lib/…:line` cut from a file URI under an app's `lib/` folder. Frames
  /// in the SDK or packages, and paths that can't be made relative, are skipped; null when none is left.
  static String? sourceLine(String trace) {
    for (final m in RegExp(r'\(([^()\s]+?):(\d+)(?::\d+)?\)').allMatches(trace)) {
      final file = m.group(1)!, line = m.group(2)!;
      String? rel;
      if (file.startsWith('package:caw/')) {
        rel = file;
      } else if (file.startsWith('file://')) {
        final i = file.lastIndexOf('/app/lib/');
        if (i >= 0) rel = file.substring(i + 5);
      }
      if (rel == null || rel.contains('..')) continue;
      if (!RegExp(r'^(package:caw/|lib/)[A-Za-z0-9_][A-Za-z0-9_./-]*\.dart$').hasMatch(rel)) continue;
      return '$rel:$line';
    }
    return null;
  }

  /// The recent errors as H2's `errors` (type, where, count), for the feedback form's "Attach recent error log".
  static List<Map<String, Object?>> recentErrors() {
    final counts = <({String type, String where}), int>{};
    for (final e in _recent) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    return [for (final e in counts.entries) {'type': e.key.type, 'where': e.key.where, 'count': e.value}];
  }

  /// A plain-text report for an issue: the version, the platform and the recent errors. No project content, names or
  /// paths beyond what an error message itself contains.
  static String report() {
    final b = StringBuffer()
      ..writeln('C.A.W $appVersion')
      ..writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('Processors: ${Platform.numberOfProcessors}')
      ..writeln()
      ..writeln('What happened, and what did you expect?')
      ..writeln()
      ..writeln();
    if (_entries.isNotEmpty) {
      b.writeln('Recent errors (newest last):');
      for (final e in _entries) {
        b.writeln(e);
      }
    }
    return b.toString();
  }
}
