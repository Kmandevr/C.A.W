// Touch editing in the piano roll (owner, 2026-11-11): paste lands after the copy and chains; a long-press box adds to
// the selection, undo takes it back and a double tap on empty grid clears it; the ratchet brush; the ratchet ramp;
// Vibrato; curve tension handles; edit animations. The widget tests need CAW_LIB (the editor runs the pattern).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// At 1200 x 800: 44 px of keys, 28 px a step, rows 16 px; the top note's row middle is at y = 140.
double _x(double step) => 44 + step * 28;
const _top = 140.0;

PatternDoc _doc(String body) => PatternDoc.parse('---\nkind: pattern\n---\n$body').doc!;

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  group('model', () {
    test('copy after lands on the grid line at or after the selection\'s end, so copies chain', () {
      final d = _doc('0 C3 2.5\n');
      final a = d.copyAfter({d.notes.single.id}, grid: Steps.one);
      expect(a.doc.byId(a.ids.single)!.at, Steps(3));
      final b = a.doc.copyAfter(a.ids, grid: Steps.one);
      expect(b.doc.byId(b.ids.single)!.at, Steps(6));
      expect(d.copyAfter({d.notes.single.id}).doc.notes.last.at, Steps(5, 2), reason: 'no grid: exactly at the end');
    });

    test('a ratchet ramp writes the repeats out with rising or falling velocities, curves and chance kept', () {
      final d = _doc('0 C3 4 0.8 prob 0.5 ratchet 4 slide bend 0:0 1:2\n8 E3 2\n');
      final c3 = d.notes.first.id, e3 = d.notes.last.id;
      final up = d.ratchetRamp({c3, e3}, ramp: RatchetRamp.fadeIn, depth: 0.75);
      final hits = up.doc.notes.where((n) => n.pitch == 48).toList()..sort((a, b) => a.at.compareTo(b.at));
      expect(hits.map((n) => n.at), [Steps.zero, Steps.one, Steps(2), Steps(3)]);
      expect(hits.map((n) => n.len).toSet(), {Steps.one});
      expect(hits.map((n) => n.vel), [0.2, 0.4, 0.6, 0.8]);
      expect(hits.every((n) => n.ratchet == 1 && n.prob == 0.5 && n.expr.bend.length == 2), isTrue);
      expect(hits.map((n) => n.slide), [true, false, false, false]);
      expect(up.ids, containsAll([e3, ...hits.map((n) => n.id)]), reason: 'the notes that replace the selection');
      final down = d.ratchetRamp({c3}, ramp: RatchetRamp.fadeOut, depth: 0.75);
      expect((down.doc.notes.where((n) => n.pitch == 48).toList()..sort((a, b) => a.at.compareTo(b.at))).map((n) => n.vel),
          [0.8, 0.6, 0.4, 0.2]);
      // Round trip through the text.
      final again = PatternDoc.parse(up.doc.serialize()).doc!;
      expect(again.notes.where((n) => n.pitch == 48), hasLength(4));
    });

    test('vibrato keeps the bend and clamps to the engine\'s ranges', () {
      final d = _doc('0 C3 4 1 bend 0:0 1:2\n');
      final v = d.setVibrato({d.notes.single.id}, depth: 0.3, rate: 40, fade: 0.25).notes.single.expr;
      expect((v.vibDepth, v.vibRate, v.vibFade), (0.3, 30.0, 0.25));
      expect(v.bend, const [NotePoint(0, 0), NotePoint(1, 2)]);
    });

    test('tension handles sit on each rising or falling segment; a handle\'s height gives the bend', () {
      const pts = [NotePoint(0, 0), NotePoint(0.5, 4), NotePoint(0.75, 4), NotePoint(1, 0)];
      final hs = curveHandles(pts, 200);
      expect(hs.map((h) => h.seg), [0, 2], reason: 'the flat segment has none');
      expect(hs.first.u, 0.25);
      expect(hs.first.v, 2);
      expect(tensionThrough(0, 4, 2), 0);
      expect(tensionThrough(0, 4, 0.5), closeTo(0.79, 1e-9)); // late rise: 0.5^(4^k) = 1/8
      expect(tensionThrough(0, 4, 3.5), lessThan(0));
      expect(curveHandles(pts, 20), isEmpty, reason: 'too narrow to hold a handle');
    });
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
  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    final entry = find.ancestor(of: find.text(item), matching: find.byWidgetPredicate((w) => w is PopupMenuEntry)).first;
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  Future<void> wait(WidgetTester tester) => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));

  testWidgets('paste lands right after the copy, on the grid; the paste becomes the selection and pastes chain; it animates',
      (tester) async {
    final (s, m) = await open(tester, '0 C3 2.5\n');
    await tester.tapAt(Offset(_x(1), _top)); // selects it
    await settle(tester);
    await tester.tap(find.text('Copy (1)'));
    await tester.pump();
    await tester.tap(find.text('Paste'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(RollPaintStats.edits, greaterThan(0), reason: 'the pasted note pops in');
    await settle(tester);
    expect(RollPaintStats.edits, 0, reason: 'and settles');
    await tester.tap(find.text('Paste'));
    await settle(tester);
    expect(notes(m).map((n) => n.at), [Steps.zero, Steps(3), Steps(6)], reason: m.source);
    expect(find.text('Copy (1)'), findsOneWidget, reason: 'the last paste is the selection');
    // With edit animations off for notes, nothing animates.
    EditMotion.kinds = {...EditMotionKind.values}..remove(EditMotionKind.notes);
    addTearDown(() => EditMotion.kinds = {...EditMotionKind.values});
    await tester.tap(find.text('Paste'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(RollPaintStats.edits, 0);
    await settle(tester);
    expect(notes(m).map((n) => n.at).last, Steps(9));
    s.dispose();
  }, skip: skip);

  testWidgets('a long press on empty grid draws a box that adds to the selection; undo unselects; a double tap clears',
      (tester) async {
    // G3 on top (y = 140), E3 three rows down (188), C3 seven rows down (252).
    final (s, m) = await open(tester, '0 C3 2\n4 E3 2\n8 G3 2\n');
    await tester.tapAt(Offset(_x(9), _top));
    await settle(tester);
    expect(find.text('Copy (1)'), findsOneWidget);
    final g = await tester.startGesture(Offset(_x(3), 205));
    await tester.pump(const Duration(milliseconds: 400)); // the hold starts the box
    for (var i = 1; i <= 6; i++) {
      await g.moveTo(Offset(_x(3) + (_x(7) - _x(3)) * i / 6, 205 - 30 * i / 6));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(tester);
    expect(find.text('Copy (2)'), findsOneWidget, reason: 'E3 joins G3');
    expect(notes(m), hasLength(3), reason: 'the hold drew no note');
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Copy (1)'), findsOneWidget, reason: 'undo takes the box back');
    // With the Select tool a single tap on empty grid keeps the selection; a double tap clears it.
    await tester.tap(find.byTooltip('Select tool'));
    await tester.pump();
    await wait(tester);
    await tester.tapAt(Offset(_x(14), 300));
    await settle(tester);
    expect(find.text('Copy (1)'), findsOneWidget);
    await wait(tester);
    await tester.tapAt(Offset(_x(14), 300));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(Offset(_x(14), 300));
    await settle(tester);
    expect(find.textContaining('Copy ('), findsNothing);
    s.dispose();
  }, skip: skip);

  testWidgets('the ratchet brush sets the notes a drag passes, by how far up it goes, as one undo step', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n4 C3 4\n');
    await menu(tester, 'Ratchet brush');
    final g = await tester.startGesture(Offset(_x(1), _top));
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset(_x(1) + (_x(6) - _x(1)) * i / 10, _top - 50 * i / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Ratchet 3'), findsOneWidget);
    await g.up();
    await settle(tester);
    expect(notes(m).map((n) => n.ratchet), [3, 3], reason: m.source);
    await tester.tap(find.byTooltip('Undo'));
    await settle(tester);
    expect(notes(m).map((n) => n.ratchet), [1, 1], reason: m.source);
    s.dispose();
  }, skip: skip);

  testWidgets('Vibrato sets the notes\' own vibrato at a synced rate, keeps their bend, and is one undo step',
      (tester) async {
    final (s, m) = await open(tester, '0 C3 8 1 bend 0:0 1:2\n');
    await menu(tester, 'Vibrato…');
    expect(find.byKey(const ValueKey('vibrato-preview')), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '1/8'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    await settle(tester);
    final e = notes(m).single.expr;
    expect(e.vibDepth, 0.3, reason: m.source);
    expect(e.vibRate, closeTo(s.project.bpm / 30, 0.001), reason: 'an 1/8 cycle at the tempo');
    expect(e.bend, const [NotePoint(0, 0), NotePoint(1, 2)]);
    await tester.tap(find.byTooltip('Undo'));
    await settle(tester);
    expect(notes(m).single.expr.vibDepth, 0);
    s.dispose();
  }, skip: skip);

  testWidgets('a curve\'s tension handle bends its segment through the finger; one undo step', (tester) async {
    final (s, m) = await open(tester, '0 C3 8 1 bend 0:0 1:4\n');
    // Select the ribbon (Draw tool), then the Curve tool shows the handle at the segment's middle: (x0 + w/2, +2).
    await tester.tapAt(Offset(_x(0.8), _top - 0.4 * 16));
    await settle(tester);
    await tester.tap(find.byTooltip('Curve tool'));
    await tester.pump();
    const w = 8 * 28 - 1.0;
    final at = Offset(44 + w / 2, _top - 2 * 16);
    final g = await tester.startGesture(at);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(at + Offset(0, 24 * i / 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(RollPaintStats.label, startsWith('curve +0.7'));
    await g.up();
    await settle(tester);
    final b = notes(m).single.expr.bend;
    expect(b, hasLength(2), reason: m.source);
    expect(b.first.k, closeTo(0.79, 1e-9), reason: m.source);
    await tester.tap(find.byTooltip('Undo'));
    await settle(tester);
    expect(notes(m).single.expr.bend.first.k, 0);
    s.dispose();
  }, skip: skip);
}
