// The piano roll's snapping: the magnet turns it on and off and its menu sets the time and value grids (saved),
// velocity and chance snap to the value grid, pitch points snap in time and to semitones, and a second finger frees
// a lane drag from the grid. Needs CAW_LIB (the editor runs the pattern).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

// At 1200 x 800: 44 px of keys, 28 px a step. The velocity lane is the bottom 56 px: a value v sits at
// y = 744 + 3 + (1 - v) * 50.
double _laneY(double v) => 747 + (1 - v) * 50;

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  test('the value grid is saved with the roll look; damage keeps the default (1/8)', () {
    expect(const RollLook().valueGrid, ValueGrid.eighth);
    final back = RollLook.fromJson(const RollLook().copyWith(valueGrid: ValueGrid.tenPercent).toJson());
    expect(back.valueGrid, ValueGrid.tenPercent);
    expect(RollLook.fromJson({'value_grid': 'nope'}).valueGrid, ValueGrid.eighth);
  });

  Future<(AppState, ModuleDoc)> open(WidgetTester tester, String body) async {
    tester.view.physicalSize = const Size(1200, 800);
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

  testWidgets('velocity snaps to the value grid; the magnet turns snapping off; its menu picks the grid',
      (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    await tester.tapAt(Offset(46, _laneY(0.53)));
    await settle(tester);
    expect(notes(m).single.vel, closeTo(0.5, 1e-9), reason: 'on the 1/8 grid: ${m.source}');
    // Off: the value lands where the finger is.
    await tester.tap(find.byKey(const ValueKey('roll-snap')));
    await tester.pump();
    await tester.tapAt(Offset(46, _laneY(0.53)));
    await settle(tester);
    expect(notes(m).single.vel, closeTo(0.53, 0.02), reason: m.source);
    expect(notes(m).single.vel, isNot(closeTo(0.5, 1e-6)));
    // Back on, and the menu sets a 10% value grid (saved in the settings) and a 1/8 time grid.
    await tester.tap(find.byKey(const ValueKey('roll-snap')));
    await tester.tap(find.byKey(const ValueKey('roll-snap-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10%'));
    await tester.pumpAndSettle();
    expect(s.settings.roll.valueGrid, ValueGrid.tenPercent);
    await tester.tapAt(const Offset(600, 100)); // closes the sheet
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(46, _laneY(0.53)));
    await settle(tester);
    expect(notes(m).single.vel, closeTo(0.5, 1e-9), reason: m.source);
    await tester.tapAt(Offset(46, _laneY(0.66)));
    await settle(tester);
    expect(notes(m).single.vel, closeTo(0.7, 1e-9), reason: m.source);
    await tester.tap(find.byKey(const ValueKey('roll-snap-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '1/8').first);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(600, 100));
    await tester.pumpAndSettle();
    expect(find.text('1/8'), findsOneWidget, reason: 'the magnet shows the time grid');
    s.dispose();
  }, skip: skip);

  testWidgets('a second finger frees a lane drag from the value grid', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    final g = await tester.startGesture(Offset(46, _laneY(0.9)), pointer: 1);
    await tester.pump();
    final rest = await tester.startGesture(const Offset(600, 300), pointer: 2);
    await tester.pump();
    await g.moveTo(Offset(46, _laneY(0.53)));
    await tester.pump();
    await g.up();
    await rest.up();
    await settle(tester);
    expect(notes(m).single.vel, closeTo(0.53, 0.02), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('a pitch point snaps to the time grid along the note, and to semitones', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    await tester.tap(find.byTooltip('Curve tool'));
    await tester.pump();
    // C3 sits 4 rows from the top: its row's middle is at y = 140.
    await tester.tapAt(const Offset(100, 140));
    await tester.pump(const Duration(milliseconds: 50));
    // 0.77 of the way along a 4-step note lands on 3/4 (the 1/16 grid), 2.8 rows up on 3 semitones.
    await tester.dragFrom(const Offset(130, 140), const Offset(0, -45));
    await settle(tester);
    final b = notes(m).single.expr.bend;
    expect(b.last.t, closeTo(0.75, 1e-9), reason: m.source);
    expect(b.last.v, 3, reason: m.source);
    // A tap on the curve's segment adds a point there, on the grid too: along a 4-step note the 1/16 grid is
    // quarters, so 0.36 of the way lands on 0.25.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.tapAt(Offset(44 + 0.36 * 111, 140 - 0.36 / 0.75 * 48));
    await settle(tester);
    final after = notes(m).single.expr.bend;
    expect(after, hasLength(3), reason: m.source);
    expect(after[1].t, closeTo(0.25, 1e-9), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('golden: the snap magnet and its menu on a phone', (tester) async {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n0 C3 4\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await pumpGolden(tester, Scaffold(body: PatternEditor(state: s, module: m)), goldenSizes['phone']!);
    await tester.tap(find.byKey(const ValueKey('roll-snap-menu')));
    await tester.pumpAndSettle();
    await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_snap_menu_phone.png'));
    s.dispose();
  }, skip: skip);
}
