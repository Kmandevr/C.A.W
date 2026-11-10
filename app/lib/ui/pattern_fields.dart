// A pattern's header (`---` name, length `---`) kept out of its text and edited as small fields above the notes.
import 'package:flutter/material.dart';

import '../model/pattern_doc.dart';
import 'theme.dart';

/// A pattern's `---` header block (through its closing line's newline) and the note text after it. Without a
/// complete header the header is empty and the whole source is the body.
(String, String) splitPatternHeader(String source) {
  final lines = source.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') return ('', source);
  var offset = lines.first.length + 1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      final end = offset + lines[i].length;
      final cut = end < source.length ? end + 1 : end;
      return (source.substring(0, cut), source.substring(cut));
    }
    offset += lines[i].length + 1;
  }
  return ('', source);
}

/// The header a pattern gets when its text has none (a blank pattern's first notes).
String defaultPatternHeader(String name) =>
    '---\ncaw: 1\nkind: pattern\nname: ${name.replaceAll(RegExp(r'[#\r\n]'), '').trim()}\n---\n';

/// [body] under the pattern's own header (or a new one named [name]); an empty body without a header stays empty.
String joinPatternHeader(String source, String body, String name) {
  final header = splitPatternHeader(source).$1;
  if (header.isEmpty && body.isEmpty) return '';
  return (header.isEmpty ? defaultPatternHeader(name) : header) + body;
}

/// The header of [source] (or a new one) with its name or length changed; the notes are left as written.
/// [steps] and [bars] both null with [setLength] removes the length, so the notes decide it. Null when the
/// header can't be read (the text view shows the problem).
String? editPatternHeader(String source, String fallbackName, {String? name, bool setLength = false, int? steps, int? bars}) {
  final (header, body) = splitPatternHeader(source);
  final parsed = PatternDoc.parse(header.isEmpty ? defaultPatternHeader(fallbackName) : header).doc;
  if (parsed == null) return null;
  var doc = parsed;
  if (name != null) doc = doc.setName(name);
  if (setLength) doc = doc.setLength(steps: steps, bars: bars);
  final out = doc.serialize();
  return splitPatternHeader(out.endsWith('\n') ? out : '$out\n').$1 + body;
}

/// Name and length as two compact fields. [onRename] gets the new name (the module's and the header's).
class PatternFields extends StatefulWidget {
  const PatternFields({super.key, required this.source, required this.name, required this.stepsPerBar, required this.onSource,
      required this.onRename});
  /// The module's source now (read on each edit: typing in the text changes it without a rebuild here).
  final ValueGetter<String> source;
  final String name;
  final int stepsPerBar;
  final ValueChanged<String> onSource;
  final ValueChanged<String> onRename;

  @override
  State<PatternFields> createState() => _PatternFieldsState();
}

class _PatternFieldsState extends State<PatternFields> {
  late final _name = TextEditingController(text: widget.name);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commitName();
    });
  }

  @override
  void didUpdateWidget(PatternFields old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _name.text != widget.name) _name.text = widget.name;
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commitName() {
    final v = _name.text.replaceAll(RegExp(r'[#\r\n]'), '').trim();
    if (v.isEmpty || v == widget.name) {
      _name.text = widget.name;
      return;
    }
    widget.onRename(v);
    final next = editPatternHeader(widget.source(), v, name: v);
    if (next != null) widget.onSource(next);
    setState(() {});
  }

  void _length((int?, int?) v) {
    final next = editPatternHeader(widget.source(), widget.name, setLength: true, steps: v.$1, bars: v.$2);
    if (next != null) widget.onSource(next);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final header = splitPatternHeader(widget.source()).$1;
    final doc = header.isEmpty ? null : PatternDoc.parse(header).doc;
    final bars = doc?.headerBars, steps = doc?.headerSteps;
    final spb = widget.stepsPerBar;
    // Auto, whole bars, and the header's own value when it is something else (say 12 steps).
    final choices = <((int?, int?), String)>[
      ((null, null), 'Auto'),
      for (final b in const [1, 2, 4, 8, 16]) ((null, b), b == 1 ? '1 bar' : '$b bars'),
      if (bars != null && !const [1, 2, 4, 8, 16].contains(bars)) ((null, bars), '$bars bars'),
      if (steps != null) ((steps, null), steps % spb == 0 ? '${steps ~/ spb} bar${steps == spb ? '' : 's'} ($steps)' : '$steps steps'),
    ];
    final current = steps != null ? (steps, null) : (null, bars);
    final dense = const TextStyle(fontSize: 13);
    return Row(children: [
      Expanded(
        child: SizedBox(
          height: 34,
          child: TextField(
            key: const ValueKey('pattern name'),
            controller: _name,
            focusNode: _focus,
            style: dense,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _commitName(),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Name',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 118,
        height: 34,
        child: InputDecorator(
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Length',
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<(int?, int?)>(
              key: const ValueKey('pattern length'),
              value: current,
              isDense: true,
              isExpanded: true,
              style: (Theme.of(context).textTheme.bodyMedium ?? dense).copyWith(fontSize: 13, color: Neon.text),
              dropdownColor: Neon.panel,
              items: [for (final c in choices) DropdownMenuItem(value: c.$1, child: Text(c.$2))],
              onChanged: (v) {
                if (v != null && v != current) _length(v);
              },
            ),
          ),
        ),
      ),
    ]);
  }
}
