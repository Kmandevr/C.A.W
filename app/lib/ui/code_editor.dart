// Code editor for modules: syntax highlighting, the symbol key row for phone typing, and jump-to-error.
import 'package:flutter/material.dart';

import 'theme.dart';

const _keywords = {'let', 'param', 'in', 'global', 'export', 'fn', 'on', 'off', 'slide', 'prob', 'ratchet'};
const _vars = {'t', 'sr', 'rate', 'bpm', 'beat', 'bar', 'step', 'pos', 'phase', 'time', 'seed', 'pi'};
const _builtins = {
  'sin', 'cos', 'tan', 'abs', 'floor', 'ceil', 'round', 'trunc', 'sqrt', 'exp', 'log', 'tanh', 'sign', 'fract', //
  'mtof', 'popcount', 'clz', 'ctz', 'bitrev', 'bswap', 'bits', 'float', 'min', 'max', 'pow', 'rotl', 'rotr', //
  'clamp', 'mix', 'hash', 'noise', 'sine', 'saw', 'square', 'tri', 'ad', 'lpf', 'hpf', 'bpf',
};

final _token = RegExp(r'//[^\n]*|/\*[\s\S]*?\*/|"[^"\n]*"?|0[xX][0-9a-fA-F]+|0[bB][01]+|\d*\.?\d+(?:[eE][+-]?\d+)?|'
    r'[A-G][#b]?\d\b|[A-Za-z_][A-Za-z0-9_]*|>>>|<<|>>|[-+*/%&|^~!<>=?:]+');
final _note = RegExp(r'^[A-G][#b]?\d$');

/// Colours one token of module code.
Color? tokenColor(String tok) {
  if (tok.startsWith('//') || tok.startsWith('/*')) return Neon.dim;
  if (tok.startsWith('"')) return const Color(0xFFFF9EE8); // tooltips in quotes: soft pink
  if (RegExp(r'^[0-9.]').hasMatch(tok)) return Neon.yellow;
  if (_keywords.contains(tok)) return Neon.pink;
  if (_vars.contains(tok)) return Neon.blue;
  if (_builtins.contains(tok)) return Neon.green;
  if (_note.hasMatch(tok)) return Neon.yellow;
  if (RegExp(r'^[-+*/%&|^~!<>=?:]').hasMatch(tok)) return const Color(0xFFB9B9FF);
  return null;
}

/// A text controller that paints module code with token colours; header lines are dimmed.
class CodeController extends TextEditingController {
  CodeController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? Neon.code();
    final spans = <TextSpan>[];
    final src = text;
    var headerEnd = 0;
    if (src.startsWith('---')) {
      final close = src.indexOf('\n---', 3);
      if (close > 0) {
        final lineEnd = src.indexOf('\n', close + 1);
        headerEnd = lineEnd < 0 ? src.length : lineEnd;
      }
    }
    if (headerEnd > 0) {
      spans.add(TextSpan(text: src.substring(0, headerEnd), style: base.copyWith(color: Neon.dim)));
    }
    var i = headerEnd;
    for (final m in _token.allMatches(src, headerEnd)) {
      if (m.start > i) spans.add(TextSpan(text: src.substring(i, m.start)));
      final c = tokenColor(m[0]!);
      spans.add(TextSpan(text: m[0], style: c == null ? null : TextStyle(color: c)));
      i = m.end;
    }
    if (i < src.length) spans.add(TextSpan(text: src.substring(i)));
    return TextSpan(style: base, children: spans);
  }

  /// Types [s] at the cursor, replacing any selection.
  void insert(String s) {
    final sel = selection.isValid ? selection : TextSelection.collapsed(offset: text.length);
    final next = text.replaceRange(sel.start, sel.end, s);
    value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: sel.start + s.length));
  }

  static final _wordChar = RegExp(r'[A-Za-z0-9_.]');

  /// Where the name being typed before the cursor starts (letters, digits, `_` and `.`).
  int _wordStart() {
    var i = selection.isValid ? selection.start : text.length;
    while (i > 0 && _wordChar.hasMatch(text[i - 1])) {
      i--;
    }
    return i;
  }

  /// The name being typed before the cursor, e.g. `env.ad` (empty when there is none).
  String get wordAtCursor =>
      selection.isValid && selection.isCollapsed ? text.substring(_wordStart(), selection.start) : '';

  /// Replaces the name being typed with [s]. A call's placeholder arguments come out selected, ready to type over.
  void completeWord(String s) {
    final start = _wordStart();
    final end = selection.isValid ? selection.end : text.length;
    final open = s.indexOf('(');
    final close = s.lastIndexOf(')');
    value = TextEditingValue(
      text: text.replaceRange(start, end, s),
      selection: open < 0 || close <= open + 1
          ? TextSelection.collapsed(offset: start + (open >= 0 && close == open + 1 ? close + 1 : s.length))
          : TextSelection(baseOffset: start + open + 1, extentOffset: start + close),
    );
  }

  /// Puts the cursor at a 1-based line and column (from an error message).
  void jumpTo(int line, int col) {
    var offset = 0;
    final lines = text.split('\n');
    for (var l = 1; l < line && l <= lines.length; l++) {
      offset += lines[l - 1].length + 1;
    }
    offset = (offset + col - 1).clamp(0, text.length);
    selection = TextSelection.collapsed(offset: offset);
  }
}

/// The faint example an empty module shows for its kind (generator, effect, pattern or library): a header and a
/// first line. It is only a hint; the file stays empty until you type.
String codeHint(String kind) => switch (kind) {
      'effect' => '---\nkind: effect\nname: My effect\n---\nin * 0.5',
      'pattern' => '---\nkind: pattern\nname: My pattern\nlength: 16\n---\n// at  note  len  vel\n0      A2    2    1',
      'library' => '---\nkind: library\nnamespace: mine\nname: My tools\n---\n/// Folds a signal back into -1..1.\n'
          'fn fold(x, amount) = sin(x * amount)',
      _ => '---\nkind: generator\nname: My sound\nmode: float\n---\nsine(mtof(A3)) * 0.5\n\n'
          '// or with no header, a bytebeat formula: t * (t >> 5 | t >> 8)',
    };

/// The editable code area. [hint] shows faintly while it is empty.
class CodeField extends StatelessWidget {
  const CodeField({super.key, required this.controller, required this.focus, required this.onChanged, this.hint});
  final CodeController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        focusNode: focus,
        onChanged: onChanged,
        maxLines: null,
        minLines: 8,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        textCapitalization: TextCapitalization.none,
        style: Neon.code(),
        cursorColor: Neon.green,
        decoration: InputDecoration(
          filled: true,
          fillColor: Color.lerp(Neon.bg, Neon.panel, 0.4),
          contentPadding: const EdgeInsets.all(12),
          hintText: hint,
          hintMaxLines: 12,
          hintStyle: Neon.code(color: Neon.dim.withValues(alpha: 0.55)),
        ),
      );
}

/// Buttons for the symbols bytebeat code needs most, which phone keyboards hide.
class SymbolRow extends StatelessWidget {
  const SymbolRow({super.key, required this.onInsert});
  final ValueChanged<String> onInsert;

  static const symbols = ['t', '>>', '<<', '&', '|', '^', '%', '(', ')', '?', ':', '~', '*', '+', '-', '/', '=', '255', 'let ', 'param '];

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 46,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: symbols.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, i) => Material(
            color: Neon.panelHi,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: () => onInsert(symbols[i]),
              child: Container(
                constraints: const BoxConstraints(minWidth: 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                child: Text(symbols[i].trim(), style: Neon.code(size: 16, color: tokenColor(symbols[i].trim()) ?? Neon.text)),
              ),
            ),
          ),
        ),
      );
}
