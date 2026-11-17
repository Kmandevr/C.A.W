// The piano roll's glitches (#228, owner 2026-11-17) and its shading (#226): a tap lands in the drawn grid cell; a
// draw, a drop or a paste never stacks a note on one already there; the Erase tool swipes from empty grid; a tool
// picked mid-gesture applies; the shade starts at the clip's real end (a golden at phone size, 5-bar clip).
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/clip_roll_parts.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

PatternDoc _doc(String body) => PatternDoc.parse('---\nkind: pattern\n---\n$body').doc!;

void main() {
  late AppState s;
  var made = false;
  AppState state(String body, {int clipSteps = 16, int? loopSteps}) {
    final a = AppState(settings: Settings());
    a.project = ProjectDoc(id: 'p', name: 'Roll glitches', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: '---\nkind: pattern\nname: Riff\n---\n$body'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0,
          clips: [ClipDoc(id: 'c1', patternId: 'pat', lengthSteps: clipSteps, loopSteps: loopSteps)]),
    ]);
    a.ready = true;
    a.starting = false;
    a.history.reset(jsonEncode(a.project.toJson()));
    made = true;
    return a;
  }

  tearDown(() {
    if (made) s.dispose();
    made = false;
  });

  LayerDoc layer() => s.project.layers.first;
  ClipDoc clip() => layer().clips.first;
  // The clip's notes, less the one rowOf draws at step 10 to find a row.
  List<PatternNote> notes() =>
      PatternDoc.parse(s.project.module('pat')!.source).doc!.notes.where((n) => n.at != Steps(10)).toList();

  Future<void> pump(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => PatternEditor(state: s, module: s.project.module('pat')!, layer: layer(), clip: clip())))));
    await tester.pump();
  }

  // Long enough for a tapped note's preview (up to 4 s) and the double-tap window to run out.
  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(seconds: 5));

  // The grid's top-left on screen (the loop painter covers the roll), at the default 28 px a step.
  Offset grid(WidgetTester tester) {
    final r = tester.getRect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ClipLoopPainter));
    return r.topLeft + const Offset(44, 20);
  }

  double x(WidgetTester tester, double step) => grid(tester).dx + step * 28;

  // The y of [pitch]'s row middle: a tap on empty grid at step 10 shows which pitch that height is (that note stays;
  // [notes] leaves it out).
  Future<double> rowOf(WidgetTester tester, double pitch) async {
    final y = grid(tester).dy + 200;
    await tester.tapAt(Offset(x(tester, 10.5), y));
    await settle(tester);
    final drawn = PatternDoc.parse(s.project.module('pat')!.source).doc!.notes.firstWhere((n) => n.at == Steps(10));
    // Rows are 16 px; y was somewhere inside drawn's row.
    return y + (drawn.pitch - pitch) * 16;
  }

  group('model', () {
    test('a note drawn where one starts on that pitch comes back as that note, unchanged', () {
      final d = _doc('0 C4 0.25 1\n');
      final r = d.insert(Steps.zero, 60, Steps.one);
      expect(identical(r.doc, d), isTrue);
      expect(r.id, d.notes.single.id);
      expect(d.insert(Steps.zero, 62, Steps.one).doc.notes, hasLength(2), reason: 'another pitch is a chord');
    });

    test('a paste onto the notes it copied replaces them instead of stacking', () {
      final d = _doc('0 C4 1\n2 E4 1\n');
      final c = d.copy({for (final n in d.notes) n.id});
      final p = d.paste(c, Steps.zero);
      expect(p.doc.notes, hasLength(2));
      expect(p.doc.notes.map((n) => n.id).toSet(), p.ids);
      expect(d.paste(c, Steps.one).doc.notes, hasLength(4), reason: 'elsewhere it adds');
    });

    test('a drop merges a moved note with the one it lands on', () {
      final d = _doc('0 C4 1\n4 C4 2\n');
      final moved = d.move({d.notes.last.id}, Steps(-4), 0);
      final m = moved.mergeStacked({d.notes.last.id});
      expect(m.notes, hasLength(1));
      expect(m.notes.single.len, Steps(2), reason: 'the moved note stays');
    });
  });

  testWidgets('a tap lands in the drawn grid cell, not a coarser finger cell, on a phone', (tester) async {
    s = state('0 C4 1 1\n');
    await pump(tester);
    final y = await rowOf(tester, 64);
    // At 28 px a step the lines are a step apart; a tap at step 1.5 lands at 1 (the phone's finger cell, 2 steps,
    // used to put it at 0).
    await tester.tapAt(Offset(x(tester, 1.5), y));
    await settle(tester);
    expect(notes().map((n) => (n.at, n.pitch)), contains((Steps.one, 64.0)), reason: s.project.module('pat')!.source);
    await tester.tapAt(Offset(x(tester, 6.9), y + 16));
    await settle(tester);
    expect(notes().map((n) => (n.at, n.pitch)), contains((Steps(6), 63.0)));
  });

  testWidgets('a tap beside a short note on its pitch and cell takes it instead of stacking another', (tester) async {
    s = state('0 C4 0.25 1\n');
    await pump(tester);
    final y = await rowOf(tester, 60);
    await tester.tapAt(Offset(x(tester, 0.8), y));
    await settle(tester);
    expect(notes(), hasLength(1), reason: s.project.module('pat')!.source);
  });

  testWidgets('a note dragged onto another on its pitch replaces it: no stacked pair', (tester) async {
    s = state('0 C4 1 1\n4 C4 2 1\n');
    await pump(tester);
    final y = await rowOf(tester, 60);
    final g = await tester.startGesture(Offset(x(tester, 4.5), y));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(Offset(x(tester, 4.5 - i * 0.5), y));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(tester);
    expect(notes().map((n) => (n.at, n.len)), [(Steps.zero, Steps(2))], reason: s.project.module('pat')!.source);
  });

  testWidgets('the Erase tool swipes notes away from empty grid too', (tester) async {
    s = state('2 C4 1 1\n4 C4 1 1\n');
    await pump(tester);
    final y = await rowOf(tester, 60);
    await tester.tap(find.byTooltip('Erase tool').first);
    await tester.pump();
    final g = await tester.startGesture(Offset(x(tester, 0.5), y));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 12; i++) {
      await g.moveTo(Offset(x(tester, 0.5 + i * 0.5), y));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(tester);
    expect(notes(), isEmpty, reason: s.project.module('pat')!.source);
  });

  testWidgets('a tool picked while a tap is pending applies to the next touch, not to that one', (tester) async {
    s = state('4 C4 1 1\n');
    await pump(tester);
    final y = await rowOf(tester, 60);
    await tester.tap(find.byTooltip('Erase tool').first);
    await tester.pump();
    // A finger rests on empty grid (an Erase tap pending), Draw is picked with another finger, and the first lifts:
    // that touch was the Erase tool's, so nothing is drawn (it used to draw, as if Draw had been on when it began).
    final g = await tester.startGesture(Offset(x(tester, 8.5), y));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Draw tool').first);
    await tester.pump();
    await g.up();
    await settle(tester);
    expect(notes().map((n) => n.at), [Steps(4)], reason: s.project.module('pat')!.source);
    // The next tap draws.
    await tester.tapAt(Offset(x(tester, 8.5), y));
    await settle(tester);
    expect(notes().map((n) => n.at), [Steps(4), Steps(8)]);
  });

  testWidgets('a five-bar clip is shaded only past its end, at phone size', (tester) async {
    // Notes in the first bar only (the pattern's own length is one bar), the clip and its loop five bars.
    s = state('0 C4 4 1\n4 E4 4 1\n8 G4 4 1\n', clipSteps: 80, loopSteps: 80);
    await loadAppFonts(tester);
    await pump(tester);
    // Pinch out to see the whole clip: about 4 px a step.
    final mid = grid(tester) + const Offset(150, 200);
    final a = await tester.startGesture(mid - const Offset(140, 0));
    final b = await tester.startGesture(mid + const Offset(140, 0), pointer: 7);
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(mid - Offset(140 - i * 12.0, 0));
      await b.moveTo(mid + Offset(140 - i * 12.0, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    await expectLater(find.byType(PatternEditor), matchesGoldenFile('goldens/roll_clip_five_bars_phone.png'));
  });
}
