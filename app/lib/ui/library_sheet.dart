// In-app help: the function library sheet (search, docs, insert) and the completion chips above the keyboard.
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import 'theme.dart';

/// Opens the library: every function with its docs and example, searchable, each one a tap away from the code.
Future<void> showLibrarySheet(
  BuildContext context, {
  required Library library,
  String query = '',
  required void Function(String text) onInsert,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Neon.panel,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => _LibraryView(
        library: library,
        query: query,
        scroll: scroll,
        onInsert: (t) {
          Navigator.of(context).pop();
          onInsert(t);
        },
      ),
    ),
  );
}

class _LibraryView extends StatefulWidget {
  const _LibraryView({required this.library, required this.query, required this.scroll, required this.onInsert});
  final Library library;
  final String query;
  final ScrollController scroll;
  final void Function(String) onInsert;

  @override
  State<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<_LibraryView> {
  late final TextEditingController _search = TextEditingController(text: widget.query);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(LibraryFn f, String q) =>
      q.isEmpty ||
      f.name.toLowerCase().contains(q) ||
      f.category.toLowerCase().contains(q) ||
      f.doc.toLowerCase().contains(q);

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final fns = widget.library.functions.where((f) => _matches(f, q)).toList();
    final constants = widget.library.constants.where((c) => q.isEmpty || c.contains(q)).toList();
    final rows = <Widget>[];
    String? category;
    for (final f in fns) {
      if (f.category != category) {
        category = f.category;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              category.toUpperCase(),
              style: const TextStyle(color: Neon.blue, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2),
            ),
          ),
        );
      }
      rows.add(_FunctionTile(
          key: ValueKey((f.name, fns.length == 1)), fn: f, onInsert: widget.onInsert, open: fns.length == 1));
    }
    if (constants.isNotEmpty) {
      rows.add(
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(
            'CONSTANTS',
            style: TextStyle(color: Neon.blue, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2),
          ),
        ),
      );
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in constants)
                ActionChip(
                  label: Text(c, style: Neon.code(size: 13)),
                  onPressed: () => widget.onInsert(c),
                ),
            ],
          ),
        ),
      );
    }
    if (rows.isEmpty) {
      rows.add(
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nothing matches.', style: TextStyle(color: Neon.dim)),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: TextField(
            controller: _search,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search functions: adsr, kick, delay, scale…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: ListView(controller: widget.scroll, padding: const EdgeInsets.only(bottom: 24), children: rows),
        ),
      ],
    );
  }
}

class _FunctionTile extends StatelessWidget {
  const _FunctionTile({super.key, required this.fn, required this.onInsert, required this.open});
  final LibraryFn fn;
  final void Function(String) onInsert;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final first = fn.doc.split('. ').first;
    return ExpansionTile(
      initiallyExpanded: open,
      title: Text(fn.signature, style: Neon.code(size: 14, color: Neon.text)),
      subtitle: Text(first.endsWith('.') ? first : '$first.', style: const TextStyle(color: Neon.dim, fontSize: 13)),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(fn.doc),
        const SizedBox(height: 8),
        for (final a in fn.args)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: a.name,
                    style: Neon.code(size: 13, color: Neon.yellow),
                  ),
                  TextSpan(text: a.optional ? ' (optional): ' : ': '),
                  TextSpan(text: a.doc),
                ],
              ),
            ),
          ),
        if (fn.example.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Neon.bg, borderRadius: BorderRadius.circular(6)),
            child: SelectableText(fn.example, style: Neon.code(size: 13)),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonal(onPressed: () => onInsert(fn.callText), child: const Text('Insert call')),
            if (fn.example.isNotEmpty)
              OutlinedButton(onPressed: () => onInsert(fn.example), child: const Text('Insert example')),
          ],
        ),
      ],
    );
  }
}

/// Names that complete the word being typed; a tap finishes it (a function comes with its arguments to type over).
class CompletionChips extends StatelessWidget {
  const CompletionChips({super.key, required this.library, required this.word, required this.onPick});
  final Library library;
  final String word;
  final void Function(String text) onPick;

  @override
  Widget build(BuildContext context) {
    final names = library.complete(word);
    if (names.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final n in names)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: library.find(n)?.signature ?? n,
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(n, style: Neon.code(size: 13)),
                  onPressed: () => onPick(library.find(n)?.callText ?? n),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
