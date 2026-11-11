// The C++ Library: the SDK, caw::lib, the built-in components and C.A.W's text formats, in the function Library's look.
import 'package:flutter/material.dart';

import '../../model/cpp_reference.dart';
import '../glass.dart';
import '../theme.dart';

/// Opens the Library as a sheet (the code stays visible above it); [onInsert] types into the code.
Future<void> showCppLibrarySheet(BuildContext context, {String query = '', required ValueChanged<String> onInsert}) =>
    showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Neon.panel,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, scroll) => CppLibraryView(
          query: query,
          scroll: scroll,
          autofocus: query.isEmpty,
          onInsert: (t) {
            Navigator.of(context).pop();
            onInsert(t);
          },
        ),
      ),
    );

/// One tile: an SDK or Library name with its members, a built-in component, or a text format.
class _Item {
  _Item.entry(this.group, CppRefEntry e)
      : title = e.qualified,
        detail = e.detail,
        doc = e.doc,
        example = e.example,
        insert = e.insert,
        builtin = null,
        format = null;
  _Item.builtin(CppBuiltin b)
      : group = b.instrument ? 'Built-in instruments' : 'Built-in effects',
        title = b.id,
        detail = b.name,
        doc = b.doc,
        example = '',
        insert = '"${b.id}"',
        builtin = b,
        format = null;
  _Item.format(TextFormatRef f)
      : group = 'Text formats',
        title = f.title,
        detail = f.detail,
        doc = f.doc,
        example = f.example,
        insert = null,
        builtin = null,
        format = f;

  final String group, title, detail, doc, example;
  final String? insert;
  final CppBuiltin? builtin;
  final TextFormatRef? format;
  final List<CppRefEntry> members = [];

  bool matches(String q) {
    bool has(String s) => s.toLowerCase().contains(q);
    return q.isEmpty ||
        has(title) ||
        has(detail) ||
        has(doc) ||
        has(group) ||
        members.any((m) => has(m.name) || has(m.doc)) ||
        (builtin?.knobs.any(has) ?? false) ||
        (format?.fields.any((f) => has(f.$1)) ?? false);
  }
}

/// Every Library item in order: the SDK and caw::lib by group (members folded into their type), then the
/// built-ins, then the text formats.
List<_Item> _items() {
  final out = <_Item>[];
  final byName = <String, _Item>{};
  for (final e in cppReference.where((e) => !e.member)) {
    final item = _Item.entry(e.group, e);
    out.add(item);
    byName[e.qualified] = item;
  }
  for (final e in cppReference.where((e) => e.member)) {
    final parent = byName[e.qualified.substring(0, e.qualified.lastIndexOf('::'))];
    if (parent != null) {
      parent.members.add(e);
    } else {
      out.add(_Item.entry(e.group, e));
    }
  }
  // Groups in the order they first appear; within a group, the order written.
  final groups = <String>[];
  for (final i in out) {
    if (!groups.contains(i.group)) groups.add(i.group);
  }
  out.sort((a, b) => groups.indexOf(a.group).compareTo(groups.indexOf(b.group)));
  return [
    ...out,
    for (final b in cppBuiltins.where((b) => b.instrument)) _Item.builtin(b),
    for (final b in cppBuiltins.where((b) => !b.instrument)) _Item.builtin(b),
    for (final f in textFormats) _Item.format(f),
  ];
}

class CppLibraryView extends StatefulWidget {
  const CppLibraryView({super.key, required this.onInsert, this.query = '', this.scroll, this.autofocus = false});
  final ValueChanged<String> onInsert;
  final String query;
  final ScrollController? scroll;
  final bool autofocus;

  @override
  State<CppLibraryView> createState() => _CppLibraryViewState();
}

class _CppLibraryViewState extends State<CppLibraryView> {
  late final TextEditingController _search = TextEditingController(text: widget.query);
  static final List<_Item> _all = _items();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final items = _all.where((i) => i.matches(q)).toList();
    final rows = <Widget>[];
    String? group;
    for (final i in items) {
      if (i.group != group) {
        group = i.group;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Text(group.toUpperCase(),
              style: const TextStyle(color: Neon.blue, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        ));
      }
      rows.add(_Tile(key: ValueKey(('lib', i.title, items.length == 1)), item: i, open: items.length == 1, onInsert: widget.onInsert));
    }
    if (rows.isEmpty) {
      rows.add(const Padding(padding: EdgeInsets.all(24), child: Text('Nothing matches.', style: TextStyle(color: Neon.dim))));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: SizedBox(
          height: 36,
          child: TextField(
            key: const ValueKey('library search'),
            controller: _search,
            autofocus: widget.autofocus,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search: Adsr, Svf, noteHz, kick, pattern…',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
      ),
      Expanded(child: ListView(controller: widget.scroll, padding: const EdgeInsets.only(bottom: 24), children: rows)),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.item, required this.open, required this.onInsert});
  final _Item item;
  final bool open;
  final ValueChanged<String> onInsert;

  Widget _code(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Neon.bg, borderRadius: BorderRadius.circular(6)),
        child: SelectableText(text, style: Neon.code(size: 12)),
      );

  Widget _field(String name, String doc, {VoidCallback? onTap}) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: name, style: Neon.code(size: 12, color: Neon.yellow)),
            TextSpan(text: ': $doc', style: const TextStyle(fontSize: 12.5)),
          ])),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final i = item;
    final first = i.doc.split('. ').first;
    final insert = i.insert;
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      initiallyExpanded: open,
      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
      title: Text.rich(TextSpan(children: [
        TextSpan(text: i.title, style: Neon.code(size: 13, color: Neon.text)),
        TextSpan(text: '  ${i.detail}', style: Neon.code(size: 11, color: Neon.dim)),
      ]), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(first.endsWith('.') ? first : '$first.',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.dim, fontSize: 12)),
      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(i.doc, style: const TextStyle(fontSize: 13)),
        if (i.detail.contains('(')) ...[
          const SizedBox(height: 6),
          Text(i.detail, style: Neon.code(size: 12, color: Neon.dim)),
        ],
        const SizedBox(height: 6),
        // A type's members: a tap types `.name`.
        for (final m in i.members) _field('.${m.name}', '${m.detail} — ${m.doc}', onTap: () => onInsert(m.insert)),
        if (i.builtin != null) _field('knobs', i.builtin!.knobs.join(', ')),
        for (final f in i.format?.fields ?? const <(String, String)>[]) _field(f.$1, f.$2),
        if (i.example.isNotEmpty) ...[const SizedBox(height: 6), _code(i.example)],
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          if (insert != null)
            FilledButton.tonal(
              key: ValueKey('insert ${i.title}'),
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => onInsert(insert),
              child: Text(i.builtin != null ? 'Insert id' : 'Insert'),
            ),
          if (i.example.isNotEmpty && i.format == null)
            OutlinedButton(
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => onInsert(i.example),
              child: const Text('Insert example'),
            ),
        ]),
      ],
    );
  }
}
