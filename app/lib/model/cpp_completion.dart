// Completion for the C++ Builder: an instant list (keywords, SDK names, the file's own words) and Clang's results.
import 'cpp_reference.dart';

class CppCompletion {
  const CppCompletion(this.label, {this.detail = '', String? insert, this.fromClang = false}) : insert = insert ?? label;

  final String label;
  final String detail; // shown dim on the right: a type, a range, a signature
  final String insert;
  final bool fromClang;

  @override
  bool operator ==(Object other) => other is CppCompletion && other.label == label && other.detail == detail;
  @override
  int get hashCode => Object.hash(label, detail);
}

/// Where the cursor is for completion: the word being typed and what comes before it.
class CppCompletionContext {
  const CppCompletionContext({required this.prefix, required this.trigger, required this.qualifier});

  /// The identifier part already typed before the cursor (may be empty after a trigger).
  final String prefix;

  /// '.', '->', '::' right before [prefix], or '' for a plain word.
  final String trigger;

  /// The word before a '::' (`caw`, `lib`), or before a '.'/'->' (the object), else ''.
  final String qualifier;

  bool get afterMember => trigger == '.' || trigger == '->';

  /// [line] is the text of the cursor's line, [column] the cursor's 0-based offset in it.
  static CppCompletionContext at(String line, int column) {
    final before = line.substring(0, column.clamp(0, line.length));
    final word = RegExp(r'[A-Za-z_][A-Za-z0-9_]*$').firstMatch(before)?.group(0) ?? '';
    final rest = before.substring(0, before.length - word.length);
    var trigger = '';
    for (final t in const ['::', '->', '.']) {
      if (rest.endsWith(t)) {
        trigger = t;
        break;
      }
    }
    var qualifier = '';
    if (trigger.isNotEmpty) {
      qualifier = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*(\]|\))?$').firstMatch(rest.substring(0, rest.length - trigger.length))?.group(1) ?? '';
    }
    // Inside a // comment or a string literal there's nothing to complete.
    final quotes = RegExp('"').allMatches(before).length;
    if (before.contains('//') || quotes.isOdd) return const CppCompletionContext(prefix: '', trigger: 'none', qualifier: '');
    return CppCompletionContext(prefix: word, trigger: trigger, qualifier: qualifier);
  }

  /// Whether completion opens on its own: right after a trigger, or after a pause in a word of 2+ letters.
  bool get opensAutomatically => trigger != 'none' && (trigger.isNotEmpty || prefix.length >= 2);
}

final _identifier = RegExp(r'[A-Za-z_][A-Za-z0-9_]{2,}');

final _fileWords = FileWords();

/// The words (identifiers of three or more characters) of the file being edited, kept up to date by the edit
/// instead of scanned again (#174): a keystroke re-reads only the changed span, widened to whole words, not the
/// whole file (a 5,000-line file took 6 ms a keystroke).
class FileWords {
  String _text = '';
  final Map<String, int> _counts = {};

  static bool _part(int c) => c == 95 || (c >= 48 && c <= 57) || ((c | 32) >= 97 && (c | 32) <= 122);

  void _count(String text, int from, int to, int by) {
    for (final m in _identifier.allMatches(text.substring(from, to))) {
      final w = m.group(0)!;
      final n = (_counts[w] ?? 0) + by;
      if (n <= 0) {
        _counts.remove(w);
      } else {
        _counts[w] = n;
      }
    }
  }

  /// Every distinct word of [text].
  Iterable<String> of(String text) {
    final old = _text;
    if (identical(old, text)) return _counts.keys;
    final m = old.length < text.length ? old.length : text.length;
    var p = 0;
    while (p < m && old.codeUnitAt(p) == text.codeUnitAt(p)) {
      p++;
    }
    var q = 0;
    while (q < m - p && old.codeUnitAt(old.length - 1 - q) == text.codeUnitAt(text.length - 1 - q)) {
      q++;
    }
    // Widen the changed span to whole words; the text around it is the same in both.
    var from = p;
    while (from > 0 && _part(old.codeUnitAt(from - 1))) {
      from--;
    }
    var oldEnd = old.length - q, newEnd = text.length - q;
    while (oldEnd < old.length && _part(old.codeUnitAt(oldEnd))) {
      oldEnd++;
      newEnd++;
    }
    _count(old, from, oldEnd, -1);
    _count(text, from, newEnd, 1);
    _text = text;
    return _counts.keys;
  }
}

/// The instant list for [context]: SDK names (members after a dot, a namespace's names after `ns::`), keywords
/// and the identifiers of [fileText], filtered by the typed prefix; at most [limit].
/// [knobs] are the effect's built parameters (id with range and unit), offered with that detail.
List<CppCompletion> staticCompletions(CppCompletionContext context, String fileText,
    {int limit = 40, List<CppCompletion> knobs = const []}) {
  if (context.trigger == 'none') return const [];
  final prefix = context.prefix;
  final lower = prefix.toLowerCase();
  bool matches(String name) => name.startsWith(prefix) || (lower.isNotEmpty && name.toLowerCase().startsWith(lower));
  final out = <CppCompletion>[];
  final seen = <String>{};
  void add(CppCompletion c) {
    if (c.label == prefix || !matches(c.label) || !seen.add(c.label)) return;
    out.add(c);
  }

  if (!context.afterMember && context.trigger != '::') knobs.forEach(add);
  if (context.afterMember) {
    for (final e in cppReference.where((e) => e.member)) {
      add(CppCompletion(e.name, detail: e.detail));
    }
  } else if (context.trigger == '::') {
    // caw:: lists caw's names (not caw::lib's members), lib:: the Library, a type:: its members.
    for (final e in cppReference) {
      final parts = e.qualified.split('::');
      final at = parts.lastIndexOf(context.qualifier);
      if (at < 0 || at != parts.length - 2) continue;
      add(CppCompletion(parts.last, detail: e.detail));
    }
    if (context.qualifier == 'caw') add(const CppCompletion('lib', detail: 'namespace'));
  } else {
    for (final e in cppReference.where((e) => (!e.member && e.qualified.split('::').length == 2) || e.qualified == 'CAW_EXPORT_COMPONENT')) {
      add(CppCompletion(e.qualified, detail: e.detail));
    }
    for (final k in cppKeywords) {
      add(CppCompletion(k, detail: k.startsWith('std::') ? 'std' : 'keyword'));
    }
  }
  if (!context.afterMember || out.length < 4) {
    for (final w in _fileWords.of(fileText)) {
      if (w != prefix && matches(w) && seen.add(w)) out.add(CppCompletion(w)); // add(), without a throwaway object
    }
  }
  out.sort((a, b) {
    final ea = a.label.startsWith(prefix) ? 0 : 1, eb = b.label.startsWith(prefix) ? 0 : 1;
    if (ea != eb) return ea - eb;
    final da = a.detail.isEmpty ? 1 : 0, db = b.detail.isEmpty ? 1 : 0; // known names before plain words
    if (da != db) return da - db;
    final dl = a.label.length - b.label.length;
    return dl != 0 ? dl : a.label.compareTo(b.label); // ties in a fixed order, whatever order the words came in
  });
  return out.take(limit).toList();
}

final _completionLine = RegExp(r'^COMPLETION: (\S+)(?: : (.*))?$');
final _resultType = RegExp(r'\[#([^#]*)#\]');

/// Clang's `-code-completion-at` output: `COMPLETION: name : [#type#]name(<#args#>)` lines, filtered by [prefix].
/// Constructors, destructors and operators are left out.
List<CppCompletion> parseClangCompletions(String output, {String prefix = '', int limit = 40}) {
  final out = <CppCompletion>[];
  final seen = <String>{};
  for (final raw in output.split('\n')) {
    final m = _completionLine.firstMatch(raw.trimRight());
    if (m == null) continue;
    final name = m.group(1)!;
    if (name.startsWith('~') || name.startsWith('operator') || name.contains('(') || name == 'Pattern') continue;
    if (prefix.isNotEmpty && !name.toLowerCase().startsWith(prefix.toLowerCase())) continue;
    final pattern = m.group(2) ?? '';
    if (pattern.endsWith('::') && pattern.startsWith(name)) continue; // the class's own name for qualification
    final type = _resultType.firstMatch(pattern)?.group(1) ?? '';
    final args = pattern.contains('(')
        ? '(${RegExp(r'<#([^#]*)#>').allMatches(pattern).map((a) => a.group(1)).join(', ')})'
        : '';
    final detail = [type, if (args.isNotEmpty) args].where((s) => s.isNotEmpty).join(' ');
    if (!seen.add('$name$args')) continue;
    out.add(CppCompletion(name, detail: detail, insert: name, fromClang: true));
    if (out.length >= limit) break;
  }
  return out;
}

/// Clang's results first (they know the code), then the instant ones it didn't give; SDK details (a knob's
/// range) stay with their names.
List<CppCompletion> mergeCompletions(List<CppCompletion> clang, List<CppCompletion> instant, {int limit = 40}) {
  final names = {for (final c in clang) c.label};
  return [...clang, ...instant.where((c) => !names.contains(c.label))].take(limit).toList();
}
