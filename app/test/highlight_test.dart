// Pattern text editor tests: token colours, the symbol-row insert and jump-to-error.
import 'package:caw/ui/code_editor.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tokens get their colours', () {
    expect(tokenColor('slide'), Neon.pink);
    expect(tokenColor('ratchet'), Neon.pink);
    expect(tokenColor('255'), Neon.yellow);
    expect(tokenColor('C#4'), Neon.yellow);
    expect(tokenColor('// hi'), Neon.dim);
    expect(tokenColor('myName'), isNull);
    expect(tokenColor('let'), isNull, reason: 'no .caw keywords any more (#160)');
    expect(tokenColor('"a tip"'), isNotNull);
  });

  test('insert replaces the selection and jumpTo finds line and column', () {
    final c = CodeController(text: 'abc\ndef');
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 2);
    c.insert('>>');
    expect(c.text, 'a>>c\ndef');
    expect(c.selection.baseOffset, 3);
    c.jumpTo(2, 3);
    expect(c.selection.baseOffset, 7);
  });

  test('an empty pattern hints at its header and first note', () {
    expect(patternHint, startsWith('---\nkind: pattern\n'));
  });
}
