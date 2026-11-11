// The Curve tool edits any note's pitch curve where it is drawn (owner, 2026-11-10, #170): a drag on a point moves
// it and a tap on the line adds one with no selection first, a double tap removes a point, the nearest point wins where
// curves overlap, a drag is one undo step, and a curve being drawn shows its start and the point's pitch. Needs
// CAW_LIB (the editor runs the pattern).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// At 1200 x 800: 44 px of keys, 28 px a step, rows 16 px; the roll scrolls so the top note's row middle is at y = 140.
// With E3 on top, C3's row middle is 4 rows lower, at 204.
double _x(double step) => 44 + step * 28;
const _c3 = 204.0;

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  Future<(AppState, ModuleDoc)> open(WidgetTester tester, String body) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState();
    s.engine = Engine.create();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n$body');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await tester.tap(find.byTooltip('Curve tool'));
    await tester.pump();
    return (s, m);
  }

  List<PatternNote> notes(ModuleDoc m) => PatternDoc.parse(m.source).doc!.notes;
  PatternNote at(ModuleDoc m, String name) =>
      notes(m).firstWhere((n) => n.pitch.round() == {'C3': 48, 'C#3': 49, 'E3': 52}[name]);
  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(milliseconds: 400));

  Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
    final g = await tester.startGesture(from);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(from + by * (i / 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(tester);
  }

  test('pitch labels', () {
    expect(bendLabel(2), '+2.0 st');
    expect(bendLabel(-1.5), '-1.5 st');
    expect(bendLabel(0), '0.0 st');
  });

  testWidgets('a drag on an unselected note\'s point moves it, and is one undo step', (tester) async {
    const body = '0 C3 8 1 bend 0:0 0.5:2 1:0\n4 E3 4\n';
    final (s, m) = await open(tester, body);
    // C3's middle point: half way along (step 4), 2 semitones up. Two rows further up: +4.
    await drag(tester, Offset(_x(4), _c3 - 32), const Offset(0, -32));
    expect(at(m, 'C3').expr.bend, const [NotePoint(0, 0), NotePoint(0.5, 4), NotePoint(1, 0)], reason: m.source);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(m.source.split('---').last.trim(), body.trim(), reason: 'one undo puts the whole drag back');
    s.dispose();
  }, skip: skip);

  testWidgets('a tap on an unselected note\'s line adds a point on it; a double tap on a point removes it',
      (tester) async {
    final (s, m) = await open(tester, '0 C3 8 1 bend 0:0 0.5:2 1:0\n4 E3 4\n');
    // A quarter of the way along, the line is at +1: a tap 6 px off it still lands on it.
    await tester.tapAt(Offset(_x(2), _c3 - 16 + 6));
    await settle(tester);
    expect(at(m, 'C3').expr.bend,
        const [NotePoint(0, 0), NotePoint(0.25, 1), NotePoint(0.5, 2), NotePoint(1, 0)], reason: m.source);
    // The point's double tap is timed by the wall clock (DateTime.now): the first tap was kept apart from it by real
    // time past the timeout, and its two taps go back to back, so a slow machine can't push them apart.
    await tester.runAsync(() => Future<void>.delayed(kDoubleTapTimeout + const Duration(milliseconds: 100)));
    await tester.tapAt(Offset(_x(4), _c3 - 32));
    await tester.tapAt(Offset(_x(4), _c3 - 32));
    await settle(tester);
    expect(at(m, 'C3').expr.bend, const [NotePoint(0, 0), NotePoint(0.25, 1), NotePoint(1, 0)], reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('where curves overlap the nearest point is grabbed', (tester) async {
    // C3's point at (step 4, +2) sits at y = 172; C#3's first point at step 4 sits on its row, at y = 188.
    final (s, m) = await open(tester, '0 C3 8 1 bend 0:0 0.5:2 1:0\n4 C#3 4 1 bend 0:0 1:0\n4 E3 4\n');
    await drag(tester, Offset(_x(4), 176), const Offset(0, -16));
    expect(at(m, 'C3').expr.bend[1], const NotePoint(0.5, 3), reason: m.source);
    expect(at(m, 'C#3').expr.bend, const [NotePoint(0, 0), NotePoint(1, 0)], reason: m.source);
    await drag(tester, Offset(_x(4), 185), const Offset(0, 16));
    expect(at(m, 'C#3').expr.bend.first, const NotePoint(0, -1), reason: m.source);
    expect(at(m, 'C3').expr.bend[1], const NotePoint(0.5, 3), reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('drawing a curve on a plain note shows its start and the point\'s pitch, then commits on release',
      (tester) async {
    final (s, m) = await open(tester, '0 C3 8\n4 E3 4\n');
    RollPaintStats.label = null;
    final g = await tester.startGesture(Offset(_x(4), _c3));
    await tester.pump();
    for (var i = 1; i <= 6; i++) {
      await g.moveBy(const Offset(0, -8)); // three semitones up in all
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(RollPaintStats.label, '+3.0 st');
    expect(RollPaintStats.anchor, isNotNull, reason: 'the curve\'s start is marked');
    expect(at(m, 'C3').expr.bend, isEmpty, reason: 'the model gets the curve on release');
    await g.up();
    await settle(tester);
    expect(at(m, 'C3').expr.bend, const [NotePoint(0, 0), NotePoint(0.5, 3)], reason: m.source);
    expect(RollPaintStats.label, isNull, reason: 'the label goes when the finger lifts');
    s.dispose();
  }, skip: skip);
}
