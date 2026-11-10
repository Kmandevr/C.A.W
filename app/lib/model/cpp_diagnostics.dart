// Clang's check output as editor marks: errors and warnings with file, line, column and the underlined range.
import 'dart:convert';

enum CppSeverity { error, warning }

/// One problem in a component's file. Lines and columns are 1-based, as Clang prints them; [endLine]/[endColumn]
/// is the end of the underlined range (exclusive), or null when Clang gave no range (the word at the column).
class CppDiagnostic {
  const CppDiagnostic({
    required this.file,
    required this.line,
    required this.column,
    required this.severity,
    required this.message,
    this.endLine,
    this.endColumn,
    this.startColumn,
  });

  final String file;
  final int line, column;
  final int? endLine, endColumn;
  /// Where the underlined range starts on [line] (it can start before [column]: `a + "x"` points at the `+`).
  final int? startColumn;
  final CppSeverity severity;
  final String message;

  bool get isError => severity == CppSeverity.error;

  @override
  bool operator ==(Object other) =>
      other is CppDiagnostic &&
      other.file == file &&
      other.line == line &&
      other.column == column &&
      other.endLine == endLine &&
      other.endColumn == endColumn &&
      other.startColumn == startColumn &&
      other.severity == severity &&
      other.message == message;

  @override
  int get hashCode => Object.hash(file, line, column, endLine, endColumn, startColumn, severity, message);

  @override
  String toString() => '$file:$line:$column: ${severity.name}: $message';
}

// file:line:col:{l:c-l:c}...: severity: message  (ranges appear with -fdiagnostics-print-source-range-info)
final _line = RegExp(r'^(.+?):(\d+):(\d+):((?:\{\d+:\d+-\d+:\d+\})*):?\s*(fatal error|error|warning|note|remark):\s*(.*)$');
final _range = RegExp(r'\{(\d+):(\d+)-(\d+):(\d+)\}');

/// Parses Clang's text diagnostics. Paths under [sourceDirectory] read as project paths (src/effect.cpp); notes and
/// remarks are left out; a diagnostic printed twice (a header checked through two sources) is kept once. The first
/// range on the diagnostic's own line is the one underlined.
List<CppDiagnostic> parseClangDiagnostics(String output, {String? sourceDirectory}) {
  final prefix = sourceDirectory == null ? null : (sourceDirectory.endsWith('/') ? sourceDirectory : '$sourceDirectory/');
  final seen = <CppDiagnostic>{};
  final result = <CppDiagnostic>[];
  for (final raw in const LineSplitter().convert(output)) {
    final m = _line.firstMatch(raw.trimRight());
    if (m == null) continue;
    final kind = m.group(5)!;
    if (kind == 'note' || kind == 'remark') continue;
    var file = m.group(1)!;
    if (prefix != null && file.startsWith(prefix)) file = file.substring(prefix.length);
    final line = int.parse(m.group(2)!), column = int.parse(m.group(3)!);
    int? endLine, endColumn, startColumn;
    for (final r in _range.allMatches(m.group(4)!)) {
      final rStartLine = int.parse(r.group(1)!), rStartColumn = int.parse(r.group(2)!);
      final rEndLine = int.parse(r.group(3)!), rEndColumn = int.parse(r.group(4)!);
      // The range that holds the diagnostic's column, else the first one.
      final holds = (rStartLine < line || (rStartLine == line && rStartColumn <= column)) &&
          (rEndLine > line || (rEndLine == line && rEndColumn >= column));
      if (endLine == null || holds) {
        endLine = rEndLine;
        endColumn = rEndColumn;
        startColumn = rStartLine == line ? rStartColumn : 1;
        if (holds) break;
      }
    }
    final d = CppDiagnostic(
      file: file,
      line: line,
      column: column,
      endLine: endLine,
      endColumn: endColumn,
      startColumn: startColumn,
      severity: kind == 'warning' ? CppSeverity.warning : CppSeverity.error,
      message: m.group(6)!.trim(),
    );
    if (seen.add(d)) result.add(d);
  }
  return result;
}

/// Problems grouped by file for the Problems list: files in [order] first (the component's own order), each
/// file's errors before its warnings, then by line.
Map<String, List<CppDiagnostic>> groupDiagnostics(Iterable<CppDiagnostic> diagnostics, {List<String> order = const []}) {
  final byFile = <String, List<CppDiagnostic>>{};
  for (final d in diagnostics) {
    (byFile[d.file] ??= []).add(d);
  }
  int rank(String f) {
    final i = order.indexOf(f);
    return i < 0 ? order.length : i;
  }

  final files = byFile.keys.toList()..sort((a, b) => rank(a) != rank(b) ? rank(a) - rank(b) : a.compareTo(b));
  return {
    for (final f in files)
      f: byFile[f]!
        ..sort((a, b) => a.severity != b.severity
            ? a.severity.index - b.severity.index
            : a.line != b.line
                ? a.line - b.line
                : a.column - b.column),
  };
}

/// The next error after [line]:[column] of [file] in reading order (files in [order]), wrapping round; null without
/// errors. Tapping the error count steps through them with this.
CppDiagnostic? nextError(List<CppDiagnostic> diagnostics, {String? file, int line = 0, int column = 0, List<String> order = const []}) {
  final errors = diagnostics.where((d) => d.isError).toList();
  if (errors.isEmpty) return null;
  int rank(String f) {
    final i = order.indexOf(f);
    return i < 0 ? order.length : i;
  }

  int cmp(CppDiagnostic a, String f, int l, int c) {
    if (a.file != f) return rank(a.file) != rank(f) ? rank(a.file) - rank(f) : a.file.compareTo(f);
    return a.line != l ? a.line - l : a.column - c;
  }

  errors.sort((a, b) => cmp(a, b.file, b.line, b.column));
  if (file == null) return errors.first;
  return errors.firstWhere((d) => cmp(d, file, line, column) > 0, orElse: () => errors.first);
}
