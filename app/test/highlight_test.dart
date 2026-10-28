// Code editor tests: token colours and the symbol-row insert and jump-to-error helpers.
import 'package:caw/ui/code_editor.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tokens get their colours', () {
    expect(tokenColor('let'), Neon.pink);
    expect(tokenColor('t'), Neon.blue);
    expect(tokenColor('sine'), Neon.green);
    expect(tokenColor('255'), Neon.yellow);
    expect(tokenColor('C#4'), Neon.yellow);
    expect(tokenColor('// hi'), Neon.dim);
    expect(tokenColor('myName'), isNull);
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
}
