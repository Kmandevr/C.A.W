// Keeps the last errors the app hit (uncaught Dart and Flutter errors), so "Report a problem" can include them.
// Nothing leaves the device unless the user copies the report.
import 'dart:collection';
import 'dart:io';

import '../version.dart';

class ProblemLog {
  ProblemLog._();

  static const _max = 20;
  static final _entries = ListQueue<String>();

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
  }

  static void clear() => _entries.clear();

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
