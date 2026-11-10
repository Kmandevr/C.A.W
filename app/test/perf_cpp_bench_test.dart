// Benchmarks the C++ Builder's instant completion list on a big file (about 5,000 lines): the work each keystroke
// does while the list is open. Prints a BENCH line (microseconds per keystroke).
import 'package:caw/model/cpp_completion.dart';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('instant completions on a 5,000-line file', () {
    final file = StringBuffer();
    for (var i = 0; i < 5000; i++) {
      file.writeln('  float value$i = gain_${i % 300} * lib::softClip(input[$i % frames], drive$i);');
    }
    final text = file.toString();
    const ctx = CppCompletionContext(prefix: 'val', trigger: '', qualifier: '');
    for (var i = 0; i < 5; i++) { staticCompletions(ctx, text); }
    // Each keystroke changes the text a little, as typing does (in the middle of the file).
    final half = text.length ~/ 2;
    final edits = [for (var i = 0; i < 30; i++) '${text.substring(0, half)} v$i ${text.substring(half)}'];
    final sw = Stopwatch()..start();
    var n = 0;
    for (final t in edits) {
      n += staticCompletions(ctx, t).length;
    }
    final perKey = sw.elapsedMicroseconds / 30;
    // ignore: avoid_print
    print('BENCH C++ instant completions, ${text.length} chars: ${perKey.toStringAsFixed(0)} us per keystroke ($n)');
    expect(staticCompletions(ctx, text).map((c) => c.label), contains('value10'));
  });

  test('the file words kept up to date by edits are the words a full scan finds', () {
    final r = Random(7);
    const alphabet = 'ab_9 x(;\n';
    final words = FileWords();
    var text = 'float gain = 0; int abc_1 = 2; x9abc\n';
    Set<String> scan(String t) => {for (final m in RegExp(r'[A-Za-z_][A-Za-z0-9_]{2,}').allMatches(t)) m.group(0)!};
    for (var i = 0; i < 2000; i++) {
      final at = r.nextInt(text.length + 1), cut = r.nextInt(4).clamp(0, text.length - at);
      final insert = String.fromCharCodes([for (var k = r.nextInt(4); k > 0; k--) alphabet.codeUnitAt(r.nextInt(alphabet.length))]);
      text = text.substring(0, at) + insert + text.substring(at + cut);
      expect(words.of(text).toSet(), scan(text), reason: 'after edit $i: "$text"');
    }
  });
}
