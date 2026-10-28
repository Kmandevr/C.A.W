// Code editor tests: token colours, the symbol-row insert, jump-to-error and completion helpers.
import 'package:caw/engine/engine.dart';
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
    expect(tokenColor('global'), Neon.pink);
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

  test('completion replaces the word being typed and selects the arguments', () {
    final c = CodeController(text: 'x * env.ad');
    c.selection = const TextSelection.collapsed(offset: 10);
    expect(c.wordAtCursor, 'env.ad');
    c.completeWord('env.adsr(gate, a, d, s, r)');
    expect(c.text, 'x * env.adsr(gate, a, d, s, r)');
    expect(c.text.substring(c.selection.start, c.selection.end), 'gate, a, d, s, r');
    final n = CodeController(text: 'noi');
    n.selection = const TextSelection.collapsed(offset: 3);
    n.completeWord('noise()');
    expect(n.selection.baseOffset, 7);
  });

  test('the library completes names and the part after a dot', () {
    const lib = Library([
      LibraryFn(name: 'env.adsr', args: [(name: 'gate', doc: '', optional: false), (name: 'a', doc: '', optional: true)]),
      LibraryFn(name: 'saw'),
    ], ['scale.minor']);
    expect(lib.complete('env'), ['env.adsr']);
    expect(lib.complete('ads'), ['env.adsr']);
    expect(lib.complete('scale.m'), ['scale.minor']);
    expect(lib.complete('s'), isEmpty);
    expect(lib.find('env.adsr')!.signature, 'env.adsr(gate, a?)');
    expect(lib.find('env.adsr')!.callText, 'env.adsr(gate)');
  });
}
