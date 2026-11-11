// A pattern's header kept out of its text: splitting, joining and editing it, and the Builder's name, summary and length fields.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/pattern_screen.dart';
import 'package:caw/ui/pattern_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _src = '---\ncaw: 1\nkind: pattern\nname: Line   # the lead\nlength: 2 bars\n---\n// at note len\n0 A1 2\n';

void main() {
  test('the header splits off the notes and joins back unchanged', () {
    final (header, body) = splitPatternHeader(_src);
    expect(header, '---\ncaw: 1\nkind: pattern\nname: Line   # the lead\nlength: 2 bars\n---\n');
    expect(body, '// at note len\n0 A1 2\n');
    expect(joinPatternHeader(_src, body, 'x'), _src);
    // No header (a blank pattern): the notes get one named after the module; an empty text stays empty.
    expect(splitPatternHeader('0 A1 2'), ('', '0 A1 2'));
    expect(joinPatternHeader('', '0 A1 2', 'Riff'), '---\ncaw: 1\nkind: pattern\nname: Riff\n---\n0 A1 2');
    expect(joinPatternHeader('', '', 'Riff'), '');
    // An unterminated header is all text, so the problem shows.
    expect(splitPatternHeader('---\nkind: pattern\n0 A1'), ('', '---\nkind: pattern\n0 A1'));
  });

  test('name and length edit the header in place and leave the notes as written', () {
    final renamed = editPatternHeader(_src, 'x', name: 'Bass')!;
    expect(renamed, contains('name: Bass   # the lead\n'));
    expect(splitPatternHeader(renamed).$2, '// at note len\n0 A1 2\n');
    final auto = editPatternHeader(_src, 'x', setLength: true)!;
    expect(auto, isNot(contains('length')));
    final four = editPatternHeader(auto, 'x', setLength: true, bars: 4)!;
    expect(four, contains('length: 4 bars\n'));
    expect(editPatternHeader('0 A1 2', 'Riff', setLength: true, bars: 1), '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 1 bar\n---\n0 A1 2');
  });

  test('the summary is added after the name, rewritten in place and removed when empty (#169)', () {
    final added = editPatternHeader(_src, 'x', summary: 'Lead line # two bars')!;
    expect(added, contains('name: Line   # the lead\nsummary: Lead line   two bars\nlength: 2 bars\n'));
    final changed = editPatternHeader(added, 'x', summary: 'Bass')!;
    expect(changed, contains('summary: Bass\n'));
    expect(editPatternHeader(changed, 'x', summary: ''), _src);
  });

  testWidgets("the Builder's text view hides a pattern's header; typing keeps it and the fields edit it", (tester) async {
    final state = AppState(settings: Settings());
    final m = ModuleDoc(id: 'p1', name: 'Line', source: _src);
    state.project = ProjectDoc(id: 'p', name: 'P', modules: [m]);
    state.selectModule(m.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternScreen(state: state))));
    await tester.tap(find.text('Text'));
    await tester.pump();
    final field = tester.widget<TextField>(find.byWidgetPredicate((w) => w is TextField && w.maxLines == null));
    expect(field.controller!.text, '// at note len\n0 A1 2\n');
    await tester.enterText(find.byWidget(field), '0 C3 1\n');
    expect(m.source, startsWith('---\ncaw: 1\nkind: pattern\nname: Line'));
    expect(m.source, endsWith('---\n0 C3 1\n'));
    await tester.enterText(find.byKey(const ValueKey('pattern name')), 'Bass');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(m.name, 'Bass');
    expect(m.source, contains('name: Bass'));
    expect(m.source, endsWith('---\n0 C3 1\n'));
    await tester.enterText(find.byKey(const ValueKey('pattern summary')), 'The bass line');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(m.source, contains('# the lead\nsummary: The bass line\nlength'));
    expect(m.source, endsWith('---\n0 C3 1\n'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
