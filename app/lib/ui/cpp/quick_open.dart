// Build's quick switcher (Ctrl+P, or the search button on phones): find a file, pattern, module or symbol and open it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';

/// One thing the switcher can open: [title] is matched, [detail] says where it is.
class QuickItem {
  const QuickItem(this.id, this.title, this.detail, this.icon, this.color, this.open, {this.group = 'Files'});
  final String id, title, detail, group;
  final IconData icon;
  final Color color;
  final VoidCallback open;
}

/// How well [query] matches [text]: null when its letters don't all appear in order, else higher for a match that is
/// contiguous, at a word start or at the start.
int? quickScore(String query, String text) {
  final q = query.toLowerCase().replaceAll(' ', '');
  if (q.isEmpty) return 0;
  final t = text.toLowerCase();
  final at = t.indexOf(q);
  if (at >= 0) return 1000 - at * 2 - (t.length - q.length) ~/ 4 + (at == 0 || !_word(t.codeUnitAt(at - 1)) ? 200 : 0);
  var score = 0, ti = 0, run = 0;
  for (final c in q.codeUnits) {
    var found = false;
    while (ti < t.length) {
      final here = t.codeUnitAt(ti++);
      if (here == c) {
        found = true;
        run++;
        score += 10 + run * 4 + (ti == 1 || !_word(t.codeUnitAt(ti - 2)) ? 15 : 0);
        break;
      }
      run = 0;
    }
    if (!found) return null;
  }
  return score - t.length ~/ 4;
}

bool _word(int c) => (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;

/// The items matching [query], best first ([items]' order when the query is empty).
List<QuickItem> quickFilter(List<QuickItem> items, String query) {
  if (query.trim().isEmpty) return items;
  final scored = <(QuickItem, int)>[];
  for (final i in items) {
    final a = quickScore(query, i.title);
    final b = quickScore(query, '${i.detail} ${i.title}');
    final s = a == null ? (b == null ? null : b - 50) : (b == null ? a : (a > b ? a : b));
    if (s != null) scored.add((i, s));
  }
  scored.sort((x, y) => y.$2.compareTo(x.$2));
  return [for (final s in scored) s.$1];
}

/// Opens the switcher: a sheet with the keyboard up on a phone, a box near the top on a wide screen.
Future<void> showQuickOpen(BuildContext context, List<QuickItem> items) async {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  QuickItem? picked;
  void pick(BuildContext c, QuickItem i) {
    picked = i;
    Navigator.pop(c);
  }

  if (wide) {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (c) => Align(
        alignment: const Alignment(0, -0.75),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
          child: GlassOverlay(radius: 12, child: QuickOpenList(items: items, onPick: (i) => pick(c, i))),
        ),
      ),
    );
  } else {
    final h = MediaQuery.sizeOf(context).height;
    await showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: SizedBox(height: h * 0.55, child: QuickOpenList(items: items, onPick: (i) => pick(c, i))),
      ),
    );
  }
  picked?.open();
}

/// The search field and the matching items; Enter opens the first, arrows move.
class QuickOpenList extends StatefulWidget {
  const QuickOpenList({super.key, required this.items, required this.onPick});
  final List<QuickItem> items;
  final ValueChanged<QuickItem> onPick;

  @override
  State<QuickOpenList> createState() => _QuickOpenListState();
}

class _QuickOpenListState extends State<QuickOpenList> {
  final _query = TextEditingController();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _pick(QuickItem i) {
    Haptics.tap();
    widget.onPick(i);
  }

  @override
  Widget build(BuildContext context) {
    final shown = quickFilter(widget.items, _query.text);
    final sel = shown.isEmpty ? 0 : _selected.clamp(0, shown.length - 1);
    return Material(
      color: Colors.transparent,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(() => _selected = sel + 1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(() => _selected = sel > 0 ? sel - 1 : 0),
            },
            child: TextField(
              key: const ValueKey('quick open field'),
              controller: _query,
              autofocus: true,
              style: Neon.code(size: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: 'Find a file, pattern, module or symbol',
                hintStyle: const TextStyle(fontSize: 13, color: Neon.dim),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (_) => setState(() => _selected = 0),
              onSubmitted: (_) {
                if (shown.isNotEmpty) _pick(shown[sel]);
              },
            ),
          ),
        ),
        Flexible(
          child: shown.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nothing matches.', style: TextStyle(fontSize: 12.5, color: Neon.dim)),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: shown.length,
                  itemBuilder: (context, n) {
                    final i = shown[n];
                    final heading = _query.text.trim().isEmpty && (n == 0 || shown[n - 1].group != i.group);
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                      if (heading)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
                          child: Text(i.group.toUpperCase(),
                              style: const TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w700, color: Neon.dim)),
                        ),
                      InkWell(
                        key: ValueKey('quick ${i.id}'),
                        onTap: () => _pick(i),
                        child: Container(
                          color: n == sel ? Neon.blue.withValues(alpha: 0.16) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          child: Row(children: [
                            Icon(i.icon, size: 16, color: i.color),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(i.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Neon.code(size: 12.5)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(i.detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 11, color: Neon.dim)),
                            ),
                          ]),
                        ),
                      ),
                    ]);
                  },
                ),
        ),
      ]),
    );
  }
}

/// The classes, structs and functions defined in C++ [text], with their 0-based lines: the switcher's symbols.
List<({String name, String kind, int line})> cppOutline(String text) {
  final out = <({String name, String kind, int line})>[];
  final type = RegExp(r'^\s*(?:template\s*<[^>]*>\s*)?(class|struct)\s+([A-Za-z_]\w*)\b(?![^;{]*;)');
  final fn = RegExp(r'^\s*(?:[\w:<>,\*&~]+\s+)+?([A-Za-z_~][\w:]*)\s*\([^;]*\)\s*(?:const\s*)?(?:noexcept\s*)?(?:override\s*)?(?:final\s*)?\{?\s*$');
  const notNames = {'if', 'for', 'while', 'switch', 'return', 'else', 'do', 'sizeof', 'catch'};
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final t = type.firstMatch(l);
    if (t != null) {
      out.add((name: t.group(2)!, kind: t.group(1)!, line: i));
      continue;
    }
    final f = fn.firstMatch(l);
    if (f != null && !notNames.contains(f.group(1)) && !l.trimLeft().startsWith('//')) {
      // A definition: the body opens on this line or the next.
      final opens = l.trimRight().endsWith('{') || (i + 1 < lines.length && lines[i + 1].trimLeft().startsWith('{'));
      if (opens) out.add((name: f.group(1)!, kind: 'function', line: i));
    }
  }
  return out;
}
