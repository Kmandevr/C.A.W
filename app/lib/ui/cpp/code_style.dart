// The C++ editor's look: syntax colours from the Neon theme, and the squiggles drawn under problem ranges.
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/plaintext.dart';

import '../../model/cpp_diagnostics.dart';
import '../theme.dart';

/// Code text: the bundled mono at 12.5 sp (owner: 12-13 sp), plain colours (the highlighter runs in an isolate).
TextStyle cppCodeStyle() => TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.45, color: _plain(Neon.text));

Color _plain(Color c) => Color.from(alpha: c.a, red: c.r, green: c.g, blue: c.b);

/// Syntax colours for C++ (and the JSON manifest), matching the .caw editor's choices.
CodeHighlightTheme cppHighlightTheme() {
  TextStyle c(Color color, {bool bold = false, bool italic = false}) =>
      TextStyle(color: _plain(color), fontWeight: bold ? FontWeight.w600 : null, fontStyle: italic ? FontStyle.italic : null);
  final op = Neon.codeOperator;
  final str = Neon.codeString;
  return CodeHighlightTheme(
    languages: {
      'cpp': CodeHighlightThemeMode(mode: langCpp),
      'json': CodeHighlightThemeMode(mode: langJson),
      'plaintext': CodeHighlightThemeMode(mode: langPlaintext),
    },
    theme: {
      'root': c(Neon.text),
      'keyword': c(Neon.pink),
      'built_in': c(Neon.green),
      'type': c(Neon.blue),
      'literal': c(Neon.yellow),
      'number': c(Neon.yellow),
      'string': c(str),
      'char.escape_': c(str),
      'comment': c(Neon.dim, italic: true),
      'doctag': c(Neon.dim, bold: true),
      'meta': c(Neon.violet),
      'meta-keyword': c(Neon.violet),
      'meta-string': c(str),
      'title': c(Neon.green),
      'title.function': c(Neon.green),
      'title.class': c(Neon.blue),
      'params': c(Neon.text),
      'attr': c(Neon.blue),
      'operator': c(op),
      'punctuation': c(Neon.text),
    },
  );
}

/// The highlighter language of a file.
String languageOf(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 || dot < path.lastIndexOf('/') ? '' : path.substring(dot + 1).toLowerCase();
  if (ext == 'json') return 'json';
  return const {'cpp', 'cc', 'cxx', 'c', 'h', 'hpp', 'hh', 'hxx', 'inl', 'ipp'}.contains(ext) ? 'cpp' : 'plaintext';
}

/// One underline in a line: [start]..[end] (0-based, end exclusive).
class LineMark {
  const LineMark(this.start, this.end, this.severity);
  final int start, end;
  final CppSeverity severity;
}

/// Marks for one file: diagnostic ranges as 0-based columns on their first line. A diagnostic without a range
/// underlines the word at its column (or one character).
Map<int, List<LineMark>> marksFor(List<CppDiagnostic> diagnostics, String file, List<String> lines) {
  final out = <int, List<LineMark>>{};
  for (final d in diagnostics) {
    if (d.file != file) continue;
    final index = d.line - 1;
    if (index < 0 || index >= lines.length) continue;
    final text = lines[index];
    var start = ((d.startColumn ?? d.column) - 1).clamp(0, text.length);
    int end;
    if (d.endLine != null && d.endColumn != null) {
      end = d.endLine! > d.line ? text.length : (d.endColumn! - 1).clamp(start, text.length);
    } else {
      end = start;
      final word = RegExp(r'[A-Za-z0-9_]');
      while (end < text.length && word.hasMatch(text[end])) {
        end++;
      }
    }
    if (end <= start) {
      // Nothing to underline at the column (end of line, a space): the character before it, or the one there.
      if (start >= text.length && start > 0) start = text.length - 1;
      end = (start + 1).clamp(0, text.length);
    }
    if (end > start) (out[index] ??= []).add(LineMark(start, end, d.severity));
  }
  return out;
}

/// [span] with a wavy underline over each mark (pink for errors, yellow for warnings). The span tree is flattened
/// into runs with their merged styles, so the result paints the same apart from the underlines.
TextSpan decorateSpan(TextSpan span, List<LineMark> marks) {
  if (marks.isEmpty) return span;
  final runs = <(String, TextStyle?)>[];
  void walk(InlineSpan s, TextStyle? inherited) {
    if (s is! TextSpan) return;
    final style = inherited == null ? s.style : (s.style == null ? inherited : inherited.merge(s.style));
    if (s.text != null && s.text!.isNotEmpty) runs.add((s.text!, style));
    for (final c in s.children ?? const <InlineSpan>[]) {
      walk(c, style);
    }
  }

  for (final c in span.children ?? const <InlineSpan>[]) {
    walk(c, null);
  }
  if (span.text != null && span.text!.isNotEmpty) runs.insert(0, (span.text!, null));
  TextStyle squiggle(CppSeverity s) => TextStyle(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.wavy,
        decorationColor: _plain(s == CppSeverity.error ? Neon.pink : Neon.yellow),
        decorationThickness: 1.6,
      );
  CppSeverity? at(int i) {
    CppSeverity? found;
    for (final m in marks) {
      if (i >= m.start && i < m.end) {
        if (m.severity == CppSeverity.error) return CppSeverity.error;
        found = m.severity;
      }
    }
    return found;
  }

  final children = <TextSpan>[];
  var offset = 0;
  for (final (text, style) in runs) {
    var i = 0;
    while (i < text.length) {
      final sev = at(offset + i);
      var j = i + 1;
      while (j < text.length && at(offset + j) == sev) {
        j++;
      }
      final piece = text.substring(i, j);
      children.add(TextSpan(text: piece, style: sev == null ? style : (style ?? const TextStyle()).merge(squiggle(sev))));
      i = j;
    }
    offset += text.length;
  }
  return TextSpan(style: span.style, children: children);
}
