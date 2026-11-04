// The piano roll's feel: both note ends stretch (a group by the same amount) with a ghost of the snapped length and a
// spring onto it, a second finger frees a drag from the grid, end zones reach outside narrow selected notes, a finger
// down on empty grid shows where its note lands, drags near the edge scroll, and new notes keep the last velocity.
// Needs CAW_LIB (the editor runs the pattern).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

// Geometry at 1200 x 800: 44 px of keys, 28 px a step; the toolbar (48) and ruler (20) above, rows 16 px, and the
// roll scrolls so the top note sits 4 rows down: its row's middle is at y = 140, and a row 4 semitones lower 64 px down.
const _c3 = 140.0;
double _x(double step) => 44 + step * 28;

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  test('note lengths read as fractions of a whole note', () {
    expect(noteLengthLabel(Steps(4)), '1/4');
    expect(noteLengthLabel(Steps(6)), '3/8');
    expect(noteLengthLabel(Steps(16)), '1');
    expect(noteLengthLabel(Steps(20)), '5/4');
    expect(noteLengthLabel(Steps(4, 3)), '1/12');
  });

  Future<(AppState, ModuleDoc)> open(WidgetTester tester, String body, {Size size = const Size(1200, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n$body');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    return (s, m);
  }

  List<PatternNote> notes(ModuleDoc m) => PatternDoc.parse(m.source).doc!.notes;
  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(milliseconds: 300));

  testWidgets('the end stretches onto the grid; the start moves and the end stays', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    // The end zone: a finger just inside the note's end, dragged 1.4 steps right, lands on step 5.
    await tester.dragFrom(Offset(_x(4) - 6, _c3), const Offset(40, 0));
    await settle(tester);
    expect((notes(m).single.at, notes(m).single.len), (Steps.zero, Steps(5)), reason: m.source);
    // The start zone, dragged two steps right: the start moves to 2 and the end stays at 5.
    await tester.dragFrom(Offset(_x(0) + 6, _c3), const Offset(56, 0));
    await settle(tester);
    expect((notes(m).single.at, notes(m).single.end), (Steps(2), Steps(5)), reason: m.source);
    // The middle still moves the note.
    await tester.dragFrom(Offset(_x(3.5), _c3), const Offset(28, 0));
    await settle(tester);
    expect((notes(m).single.at, notes(m).single.len), (Steps(3), Steps(3)), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('a selected group stretches by the same amount', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n0 E3 2\n');
    await tester.tap(find.byTooltip('Select tool'));
    await tester.pump();
    // The top note (E3) is on the row at y = 140 and C3 64 px below it.
    const e3 = _c3, c3 = _c3 + 64;
    await tester.dragFrom(Offset(_x(6), e3 - 20), Offset(_x(-0.2) - _x(6), c3 + 10 - (e3 - 20)));
    await tester.pump();
    await tester.tap(find.byTooltip('Draw tool'));
    await tester.pump();
    await tester.dragFrom(Offset(_x(4) - 6, c3), const Offset(56, 0));
    await settle(tester);
    expect([for (final n in notes(m)) n.len], [Steps(6), Steps(4)], reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('a second finger frees the drag from the grid while it rests', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    final drag = await tester.startGesture(Offset(_x(4) - 6, _c3), pointer: 1);
    await drag.moveBy(const Offset(20, 0));
    await drag.moveBy(const Offset(20, 0));
    await tester.pump();
    final rest = await tester.startGesture(const Offset(600, 400), pointer: 2);
    await tester.pump();
    await drag.moveBy(const Offset(2, 0));
    await drag.up();
    await rest.up();
    await settle(tester);
    final len = notes(m).single.len.toDouble();
    expect(len, closeTo(4 + 42 / 28, 0.01), reason: 'off the grid: ${m.source}');
    // Lifting the resting finger first snaps the drag back onto the grid.
    final again = await tester.startGesture(Offset(_x(len) - 6, _c3), pointer: 3);
    await again.moveBy(const Offset(20, 0));
    await again.moveBy(const Offset(10, 0));
    final hold = await tester.startGesture(const Offset(600, 400), pointer: 4);
    await tester.pump();
    await hold.up();
    await again.up();
    await settle(tester);
    expect(notes(m).single.len, Steps(7), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('a narrow selected note\'s end zone reaches outside it; beside an unselected one a tap draws',
      (tester) async {
    final (s, m) = await open(tester, '0 C3 1/4\n8 C3 1/4\n');
    // Select the first note with a tap, then grab 20 px right of its end and drag: it stretches.
    await tester.tapAt(Offset(_x(0.1), _c3));
    await tester.pump(const Duration(milliseconds: 400));
    // The double tap is timed by the wall clock: wait real time so the drag isn't a second tap.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.dragFrom(Offset(_x(0.25) + 20, _c3), const Offset(56, 0));
    await settle(tester);
    expect(notes(m).first.len, Steps(2), reason: m.source);
    // Beside the unselected second note, a tap draws a new note.
    await tester.tapAt(Offset(_x(8.25) + 30, _c3));
    await settle(tester);
    expect(notes(m), hasLength(3), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('taps right after a drawn note keep drawing (its outside end zone takes only drags)', (tester) async {
    final (s, m) = await open(tester, '');
    await tester.tapAt(const Offset(200, 300));
    await settle(tester);
    final first = notes(m).single;
    // Just past the new (selected) note's end, twice in quick succession: two more notes, the first one kept.
    final end = _x(first.end.toDouble());
    await tester.tapAt(Offset(end + 10, 300));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(Offset(end + 10 + 28 * first.len.toDouble(), 300));
    await settle(tester);
    expect(notes(m), hasLength(3), reason: m.source);
    expect(notes(m).first.at, first.at, reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('a held finger during the bypass does not open the extras; a pinch from a note still zooms',
      (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    final drag = await tester.startGesture(Offset(_x(2), _c3), pointer: 1);
    final rest = await tester.startGesture(const Offset(600, 400), pointer: 2);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.textContaining('Note at'), findsNothing);
    await drag.up();
    await rest.up();
    await settle(tester);
    // A pinch whose first finger lands on the note: the second finger moves first, so it zooms and edits nothing.
    final a = await tester.startGesture(Offset(_x(2), _c3), pointer: 3);
    final b = await tester.startGesture(Offset(_x(2) + 100, _c3), pointer: 4);
    await b.moveBy(const Offset(60, 0));
    await b.moveBy(const Offset(60, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await settle(tester);
    expect((notes(m).single.at, notes(m).single.len), (Steps.zero, Steps(4)), reason: m.source);
    // Zoomed in, a tap just past where the end was at 28 px a step lands on the note instead of drawing.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.tapAt(Offset(_x(4) + 6, _c3));
    await settle(tester);
    expect(notes(m), hasLength(1), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('a drag held at the right edge scrolls and keeps stretching', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    final g = await tester.startGesture(Offset(_x(4) - 6, _c3));
    await g.moveTo(const Offset(1190, _c3));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(tester);
    expect(notes(m).single.len.toDouble(), greaterThan((1190 - 44) / 28 + 4), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('a new note takes the last velocity set', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    // The velocity lane is the bottom 56 px; halfway up sets about half.
    await tester.tapAt(Offset(_x(0) + 2, 800 - 3 - 25));
    await settle(tester);
    final v = notes(m).single.vel;
    expect(v, closeTo(0.5, 0.05), reason: m.source);
    await tester.tapAt(Offset(_x(10), _c3));
    await settle(tester);
    expect(notes(m).last.vel, closeTo(v, 0.01), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('golden: a finger down on empty grid shows its note; a stretch shows the ghost and the length',
      (tester) async {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n0 C3 4\n8 E3 2\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await pumpGolden(tester, Scaffold(body: PatternEditor(state: s, module: m)), goldenSizes['phone']!);
    // The top note (E3, at step 8) is on the row at y = 140; C3 (steps 0 to 4) is 64 px below.
    const c3 = _c3 + 64;
    final down = await tester.startGesture(Offset(_x(5.5), c3 + 16 * 4));
    await tester.pump();
    await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_ghost_phone.png'));
    await down.cancel();
    await tester.pump();
    expect(notes(m), hasLength(2), reason: 'a cancelled touch draws nothing');
    final stretch = await tester.startGesture(Offset(_x(4) - 6, c3));
    await stretch.moveBy(const Offset(30, 0));
    await stretch.moveBy(const Offset(14, 0));
    await tester.pump();
    await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_stretch_phone.png'));
    await stretch.up();
    await settle(tester);
    expect(notes(m).first.len, Steps(6), reason: m.source);
    s.dispose();
  }, skip: skip);
}
