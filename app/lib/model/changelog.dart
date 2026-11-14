// Reads the bundled CHANGELOG.md (the subset it uses: "## version" entries, "###" groups, "-" bullets nested by two
// spaces, **bold** and `code`) for Settings' What's new, and decides when the sheet shown once after an update is due.
import 'updates/release_version.dart';

/// A run of text, bold or code or plain.
class ChangelogSpan {
  const ChangelogSpan(this.text, {this.bold = false, this.code = false});
  final String text;
  final bool bold, code;

  @override
  bool operator ==(Object other) => other is ChangelogSpan && other.text == text && other.bold == bold && other.code == code;

  @override
  int get hashCode => Object.hash(text, bold, code);

  @override
  String toString() => bold ? '**$text**' : (code ? '`$text`' : text);
}

enum ChangelogKind { paragraph, subheading, bullet }

/// One block: a paragraph, a "###" subheading or a bullet ([depth] 0 for "- ", 1 for "  - " and so on).
class ChangelogLine {
  const ChangelogLine(this.kind, this.spans, {this.depth = 0});
  final ChangelogKind kind;
  final List<ChangelogSpan> spans;
  final int depth;

  String get text => spans.map((s) => s.text).join();
}

/// One `## version (note)` entry.
class ChangelogEntry {
  const ChangelogEntry({required this.version, required this.note, required this.lines});

  /// The heading without its "(…)" suffix: `1.0.1-alpha.1`.
  final String version;

  /// What the suffix said (a date, "not yet released"), or ''.
  final String note;
  final List<ChangelogLine> lines;
}

class Changelog {
  const Changelog({this.title = '', this.intro = const [], this.entries = const []});

  /// The "# " title, the lines before the first entry, and the entries newest first (as the file lists them).
  final String title;
  final List<ChangelogLine> intro;
  final List<ChangelogEntry> entries;

  /// Limits for the text read (it is bundled, but a damaged file still parses without running away).
  static const maxChars = 256 * 1024, maxLines = 4000, maxDepth = 3;

  static final _bullet = RegExp(r'^( *)[-*] +(.*)$');
  static final _heading = RegExp(r'^(#{1,3}) +(.*)$');
  static final _suffix = RegExp(r'^(.*?)\s*\(([^()]*)\)\s*$');

  /// The entry for [version] (its heading's version, the "(…)" suffix ignored), or null.
  ChangelogEntry? entryFor(String version) {
    final v = version.trim();
    return entries.where((e) => e.version == v).firstOrNull;
  }

  static Changelog parse(String source) {
    final text = source.length > maxChars ? source.substring(0, maxChars) : source;
    var title = '';
    final intro = <ChangelogLine>[];
    final entries = <ChangelogEntry>[];
    String? version;
    var note = '';
    var lines = intro;
    final paragraph = <String>[];

    void flush() {
      if (paragraph.isEmpty) return;
      lines.add(ChangelogLine(ChangelogKind.paragraph, parseSpans(paragraph.join(' '))));
      paragraph.clear();
    }

    void close() {
      flush();
      if (version != null) entries.add(ChangelogEntry(version: version, note: note, lines: List.unmodifiable(lines)));
    }

    for (final raw in text.split('\n').take(maxLines)) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      final h = _heading.firstMatch(line);
      if (h != null) {
        flush();
        final level = h[1]!.length, body = h[2]!.trim();
        if (level == 1) {
          if (version == null && title.isEmpty) title = body;
        } else if (level == 2) {
          close();
          final m = _suffix.firstMatch(body);
          version = (m?[1] ?? body).trim();
          note = (m?[2] ?? '').trim();
          lines = <ChangelogLine>[];
        } else {
          lines.add(ChangelogLine(ChangelogKind.subheading, parseSpans(body)));
        }
        continue;
      }
      final b = _bullet.firstMatch(line);
      if (b != null) {
        flush();
        final depth = (b[1]!.length ~/ 2).clamp(0, maxDepth);
        lines.add(ChangelogLine(ChangelogKind.bullet, parseSpans(b[2]!.trim()), depth: depth));
        continue;
      }
      // An indented line under a bullet continues it; anything else is paragraph text.
      if (line.startsWith(' ') && paragraph.isEmpty && lines.isNotEmpty && lines.last.kind == ChangelogKind.bullet) {
        final last = lines.removeLast();
        lines.add(ChangelogLine(ChangelogKind.bullet, parseSpans('${_source(last.spans)} ${line.trim()}'), depth: last.depth));
        continue;
      }
      paragraph.add(line.trim());
    }
    close();
    return Changelog(title: title, intro: List.unmodifiable(intro), entries: List.unmodifiable(entries));
  }

  static String _source(List<ChangelogSpan> spans) => spans.map((s) => s.toString()).join();

  /// Splits [text] at `**` (bold) and backticks (code); an unmatched marker stays as text.
  static List<ChangelogSpan> parseSpans(String text) {
    final out = <ChangelogSpan>[];
    final plain = StringBuffer();
    void put(ChangelogSpan s) {
      if (s.text.isEmpty) return;
      final last = out.isEmpty ? null : out.last;
      if (last != null && last.bold == s.bold && last.code == s.code) {
        out[out.length - 1] = ChangelogSpan(last.text + s.text, bold: s.bold, code: s.code);
      } else {
        out.add(s);
      }
    }

    void flushPlain() {
      put(ChangelogSpan(plain.toString()));
      plain.clear();
    }

    var i = 0;
    while (i < text.length) {
      if (text.startsWith('**', i)) {
        final end = text.indexOf('**', i + 2);
        if (end > i + 2) {
          flushPlain();
          for (final s in parseSpans(text.substring(i + 2, end))) {
            put(ChangelogSpan(s.text, bold: true, code: s.code));
          }
          i = end + 2;
          continue;
        }
      } else if (text[i] == '`') {
        final end = text.indexOf('`', i + 1);
        if (end > i + 1) {
          flushPlain();
          put(ChangelogSpan(text.substring(i + 1, end), code: true));
          i = end + 1;
          continue;
        }
      }
      plain.write(text[i]);
      i++;
    }
    flushPlain();
    return out;
  }
}

/// What to do about What's new at a launch.
enum WhatsNewDue {
  /// This version has been seen.
  none,

  /// Store this version without showing anything: a fresh install, a downgrade, or a version that doesn't read.
  record,

  /// Show this version's entry once, then store it.
  show,
}

/// [lastSeen] is the version stored at the last launch ('' when none was); [freshInstall] says the app has never
/// run before. A build from before What's new stored nothing, so an empty [lastSeen] that isn't a fresh install is
/// an update too.
WhatsNewDue whatsNewDue({required String lastSeen, required String current, required bool freshInstall}) {
  final seen = lastSeen.trim(), now = current.trim();
  if (seen == now) return WhatsNewDue.none;
  if (seen.isEmpty) return freshInstall ? WhatsNewDue.record : WhatsNewDue.show;
  final a = ReleaseVersion.tryParse(seen), b = ReleaseVersion.tryParse(now);
  if (a == null || b == null) return WhatsNewDue.record;
  return b > a ? WhatsNewDue.show : WhatsNewDue.record;
}
