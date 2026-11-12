// Bent notes in the piano roll (owner, 2026-11-10): the note itself is drawn bent, as a smoothed ribbon along its
// pitch, and the note tool selects, moves and stretches it where the ribbon is; the smoothing is display only; zoomed
// out, vibrato is a band; goldens at phone size zoomed in and out. Widget tests need CAW_LIB (the editor runs the
// pattern).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/note_expression.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

// At 1200 x 800: 44 px of keys, 28 px a step, rows 16 px; the roll scrolls so the note's row middle is at y = 140.
// The bent note rises 3 semitones (48 px) by its second step and holds there: its ribbon is at y = 92 from step 2 on.
double _x(double step) => 44 + step * 28;
const _row = 140.0, _ribbon = 92.0;
const _bent = '0 C3 8 1 bend 0:0 0.25:3 1:3\n';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  group('the drawn curve is smoothed, the stored one is not', () {
    const zigzag = [NotePoint(0, 0), NotePoint(0.25, 3), NotePoint(0.5, 0), NotePoint(0.75, 3), NotePoint(1, 0)];

    test('it passes through every point on its true value', () {
      for (final p in zigzag) {
        expect(displayCurveAt(zigzag, p.t, 200), closeTo(p.v, 1e-9), reason: 'point at ${p.t}');
      }
    });

    test('corners soften within a few pixels and nothing overshoots', () {
      // 200 px wide: 6 px is 0.03 of the note. Just before the peak the drawn line is above the straight one.
      expect(displayCurveAt(zigzag, 0.24, 200), greaterThan(NoteExpression.valueAt(zigzag, 0.24)));
      // Away from the corners it is the stored curve.
      expect(displayCurveAt(zigzag, 0.125, 200), NoteExpression.valueAt(zigzag, 0.125));
      for (var u = 0.0; u <= 1; u += 0.001) {
        final v = displayCurveAt(zigzag, u, 200);
        expect(v, inInclusiveRange(0, 3), reason: 'at $u');
      }
      // A step (two points at one time) stays a step: there is no room to soften it.
      const step = [NotePoint(0, 0), NotePoint(0.5, 0), NotePoint(0.5, 2), NotePoint(1, 2)];
      expect(displayCurveAt(step, 0.49, 200), NoteExpression.valueAt(step, 0.49));
      expect(displayCurveAt(const [], 0.5, 200, empty: 1), 1);
    });

    test('it leaves the stored points alone', () {
      final pts = [...zigzag];
      for (var u = 0.0; u <= 1; u += 0.01) {
        displayCurveAt(pts, u, 50);
      }
      expect(pts, zigzag);
    });
  });

  test('zoomed out, vibrato is drawn as a band; zoomed in, as a wave', () {
    const e = NoteExpression(vibDepth: 0.4, vibRate: 5.5);
    // A 1 s note: 5.5 cycles. At 40 px a cycle is 7 px (a band); at 400 px, 73 px (a wave).
    expect(drawsVibratoAsBand(e, 40, 1), isTrue);
    expect(drawsVibratoAsBand(e, 400, 1), isFalse);
    expect(drawsVibratoAsBand(const NoteExpression(), 40, 1), isFalse);
  });

  Future<(AppState, ModuleDoc)> open(WidgetTester tester, String body) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState();
    s.engine = Engine.create();
    s.project = s.demoProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n$body');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    return (s, m);
  }

  List<PatternNote> notes(ModuleDoc m) => PatternDoc.parse(m.source).doc!.notes;
  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(milliseconds: 400));
  // Waits out the double-tap window, so the next tap on a note doesn't delete it.
  Future<void> pause(WidgetTester tester) =>
      tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));

  testWidgets('a tap on the ribbon, away from the start row, selects the bent note', (tester) async {
    final (s, m) = await open(tester, _bent);
    final before = m.source;
    await tester.tapAt(Offset(_x(6), _ribbon));
    await settle(tester);
    expect(m.source, before, reason: 'nothing is drawn on the ribbon, and drawing it changes nothing');
    await pause(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await settle(tester);
    expect(notes(m), isEmpty, reason: 'the bent note was selected: ${m.source}');
    s.dispose();
  }, skip: skip);

  testWidgets('a drag on the ribbon moves the bent note in time and pitch', (tester) async {
    final (s, m) = await open(tester, _bent);
    final bend = notes(m).single.expr.bend;
    await tester.dragFrom(Offset(_x(5), _ribbon), const Offset(56, -16));
    await settle(tester);
    final n = notes(m).single;
    expect((n.at, n.len, n.pitch), (Steps(2), Steps(8), 49.0), reason: m.source);
    expect(n.expr.bend, bend, reason: 'a move keeps the curve');
    s.dispose();
  }, skip: skip);

  testWidgets('the ribbon\'s ends stretch the bent note, and its points keep their grid places', (tester) async {
    final (s, m) = await open(tester, _bent);
    final orig = notes(m).single;
    // The end zone, where the ribbon is (3 rows above the start row): two steps longer.
    await tester.dragFrom(Offset(_x(8) - 6, _ribbon), const Offset(56, 0));
    await settle(tester);
    var n = notes(m).single;
    expect((n.at, n.len), (Steps.zero, Steps(10)), reason: m.source);
    expect(n.expr.bend, orig.expr.rebased(0, 8, 0, 10).bend, reason: m.source);
    // Selected now: a drag from just outside the ribbon's end stretches it too.
    await pause(tester);
    await tester.dragFrom(Offset(_x(10) + 10, _ribbon), const Offset(56, 0));
    await settle(tester);
    n = notes(m).single;
    expect(n.len, Steps(12), reason: m.source);
    // The start zone, on the start row where the ribbon begins: the start moves and the end stays.
    await pause(tester);
    await tester.dragFrom(Offset(_x(0) + 6, _row), const Offset(28, 0));
    await settle(tester);
    n = notes(m).single;
    expect((n.at, n.end), (Steps(1), Steps(12)), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('golden: bent notes at phone size, zoomed in and out', (tester) async {
    final s = AppState();
    s.engine = Engine.create();
    s.project = s.demoProject();
    const body = '0 G3 4 0.9 bend 0:0 0.6:0~0.6 1:-5\n'
        '4 E3 6 0.8 bend 0:0~0.4 0.4:2 1:2 vib 0.4 8 0.3\n'
        '0 C3 3 1 bend 0:-2~-0.5 0.2:0 1:0\n'
        '4 A2 8 0.7 bend 0:0 0.25:3 0.5:0 0.75:3 1:0\n'
        '10 F2 2\n';
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n$body');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await pumpGolden(tester, Scaffold(body: PatternEditor(state: s, module: m)), goldenSizes['phone']!);
    // A tap on the zigzag's first peak, three rows above its start row, selects it (white outline).
    await tester.tapAt(const Offset(44 + 6 * 28, 250));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_bent_phone.png'));
    // Two fingers side by side pinch in, in empty grid: time zooms out and the vibrato becomes a band.
    final a = await tester.startGesture(const Offset(80, 560), pointer: 1);
    final b = await tester.startGesture(const Offset(380, 560), pointer: 2);
    for (var i = 0; i < 10; i++) {
      await b.moveBy(const Offset(-24, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_bent_zoomed_out_phone.png'));
    await tester.pump(const Duration(seconds: 1));
    expect(m.source, contains(body), reason: 'drawing and zooming leave the pattern alone');
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  }, skip: skip);
}
