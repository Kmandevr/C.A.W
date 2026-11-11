// Track headers that shrink, collapse and open editors (owner, 2026-11-11): collapse states and per-track heights
// (drag, menu, folder chevron, pinch), upright meters, indentation, header and clip gestures, the one empty hint,
// clip edges that never scale the notes, and following the playhead.
import 'dart:convert';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/focus_panel.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/follow_gate.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Headers', modules: [
      ModuleDoc(id: 'pat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n4 E2 1 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 16)]),
      LayerDoc(id: 'f', name: 'Group', color: 1, isFolder: true),
      LayerDoc(id: 'b', name: 'Bass', color: 2, parentId: 'f'),
      LayerDoc(id: 'c', name: 'Lead', color: 3),
    ]);

void main() {
  late AppState s;
  late SectionController sections;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = _project();
    sections = SectionController();
  });
  tearDown(() {
    s.dispose();
    sections.dispose();
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);
  Finder header(String id) => find.byKey(ValueKey('track-header-$id'));

  Future<void> pump(WidgetTester tester, {Size size = const Size(412, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
        child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  }

  void undoable() {
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  }

  double h(WidgetTester tester, String id) => tester.getSize(header(id)).height;

  group('collapse and height', () {
    test('collapse and height are saved, and an old project reads as normal at the default height', () {
      final l = LayerDoc(id: 'x', name: 'X', color: 0, collapse: TrackCollapse.compact, height: 90);
      final back = LayerDoc.fromJson(jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>);
      expect(back.collapse, TrackCollapse.compact);
      expect(back.height, 90);
      final plain = LayerDoc.fromJson({'id': 'y', 'name': 'Y', 'color': 0, 'height': 9999});
      expect(plain.collapse, TrackCollapse.normal);
      expect(plain.height, LayerDoc.maxHeight, reason: 'clamped');
      expect(LayerDoc(id: 'z', name: 'Z', color: 0).toJson().containsKey('collapse'), isFalse);
    });

    test('rowSnap: thin, compact, then a normal row of the dragged height', () {
      expect(trackRowSnap(4), (TrackCollapse.thin, LayerDoc.thinHeight));
      expect(trackRowSnap(26), (TrackCollapse.compact, LayerDoc.compactHeight));
      expect(trackRowSnap(70), (TrackCollapse.normal, 70.0));
    });

    testWidgets('the bottom edge resizes one track, snapping through compact and thin; undo takes it back',
        (tester) async {
      undoable();
      await pump(tester);
      final h0 = h(tester, 'a');
      await tester.drag(find.byKey(const ValueKey('track-height-grip-a')), const Offset(0, 30));
      await settle(tester);
      expect(layer('a').height, closeTo(h0 + 30, 1.5));
      expect(h(tester, 'c'), h0, reason: 'only that track');
      expect(s.settings.trackHeight, 0, reason: 'the default stays');
      // Up past the shortest normal row: compact, then thin.
      await tester.drag(find.byKey(const ValueKey('track-height-grip-a')), Offset(0, -(h0 + 30 - 26)));
      await settle(tester);
      expect(layer('a').collapse, TrackCollapse.compact);
      expect(h(tester, 'a'), LayerDoc.compactHeight);
      await tester.drag(find.byKey(const ValueKey('track-height-grip-a')), const Offset(0, -20));
      await settle(tester);
      expect(layer('a').collapse, TrackCollapse.thin);
      expect(h(tester, 'a'), LayerDoc.thinHeight);
      expect(find.byKey(const ValueKey('thin-track-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('thin-clip-c1')), findsOneWidget, reason: 'its clips are thin bars');
      s.undo();
      await settle(tester);
      expect(layer('a').collapse, TrackCollapse.compact);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the track menu Collapse ▸ Compact, Thin, Normal, and Default height', (tester) async {
      layer('c').height = 100;
      await pump(tester);
      Future<void> menu(String item) async {
        // On the name, clear of M and S.
        final r = tester.getRect(header('c'));
        final at = Offset(r.left + 40, r.top + (r.height < 28 ? r.height / 2 : 14));
        await tester.longPressAt(at);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text(item), 200, scrollable: find.descendant(
            of: find.byKey(const ValueKey('long-press-menu')), matching: find.byType(Scrollable)).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await settle(tester);
      }
      expect(h(tester, 'c'), 100);
      await menu('Compact');
      expect(layer('c').collapse, TrackCollapse.compact);
      expect(h(tester, 'c'), LayerDoc.compactHeight);
      await menu('Thin');
      expect(h(tester, 'c'), LayerDoc.thinHeight);
      await menu('Normal');
      expect(h(tester, 'c'), 100, reason: 'back to its own height');
      await menu('Default height');
      expect(layer('c').height, isNull);
      expect(h(tester, 'c'), h(tester, 'a'));
    });

    testWidgets("a folder's chevron draws its tracks as thin bars and opens them back to their own states",
        (tester) async {
      layer('b').collapse = TrackCollapse.compact;
      await pump(tester);
      expect(h(tester, 'b'), LayerDoc.compactHeight);
      await tester.tap(find.byKey(const ValueKey('folder-chevron-f')));
      await settle(tester);
      expect(h(tester, 'b'), LayerDoc.thinHeight);
      expect(layer('b').collapse, TrackCollapse.compact, reason: 'its own state is kept');
      await tester.tap(find.byKey(const ValueKey('folder-chevron-f')));
      await settle(tester);
      expect(h(tester, 'b'), LayerDoc.compactHeight);
    });

    testWidgets('a vertical pinch on a header resizes that track only', (tester) async {
      await pump(tester);
      final h0 = h(tester, 'c');
      final at = tester.getCenter(header('c'));
      final g1 = await tester.startGesture(at - const Offset(0, 10), kind: PointerDeviceKind.touch);
      final g2 = await tester.startGesture(at + const Offset(0, 30), kind: PointerDeviceKind.touch);
      await g1.moveBy(const Offset(0, -20));
      await g2.moveBy(const Offset(0, 20));
      await tester.pump();
      await g1.up();
      await g2.up();
      await settle(tester);
      expect(layer('c').height, closeTo(h0 * 2, 2));
      expect(h(tester, 'a'), h0);
      expect(s.settings.trackHeight, 0);
    });

    testWidgets('a collapse glides to its height; with motion off it lands at once', (tester) async {
      await pump(tester);
      final h0 = h(tester, 'c');
      s.setTrackCollapse([layer('c')], TrackCollapse.thin);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = h(tester, 'c');
      expect(mid, lessThan(h0));
      expect(mid, greaterThan(LayerDoc.thinHeight));
      await settle(tester);
      expect(h(tester, 'c'), LayerDoc.thinHeight);

      final kinds = EditMotion.kinds;
      EditMotion.kinds = {};
      addTearDown(() => EditMotion.kinds = kinds);
      s.setTrackCollapse([layer('c')], TrackCollapse.normal);
      await tester.pump();
      await tester.pump();
      expect(h(tester, 'c'), h0);
      await settle(tester);
    });
  });

  group('the header', () {
    testWidgets('a compact row hides M and S at a phone\'s narrowest width until the track is selected',
        (tester) async {
      s.settings.headerWidth = Settings.minHeaderWidth;
      layer('c').collapse = TrackCollapse.compact;
      layer('a').collapse = TrackCollapse.compact;
      await pump(tester);
      Finder mute(String id) => find.descendant(of: header(id), matching: find.text('M'));
      expect(mute('c'), findsNothing);
      s.selectLayer(layer('c'));
      await settle(tester);
      expect(mute('c'), findsOneWidget);
      expect(mute('a'), findsNothing);
      // A wider header shows them on every compact row.
      s.settings.headerWidth = 200;
      s.selectLayer(layer('b'));
      await settle(tester);
      expect(mute('a'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow header stands the meter upright', (tester) async {
      s.settings.headerWidth = 200;
      await pump(tester);
      expect(find.byKey(const ValueKey('upright-meter-c')), findsNothing);
      s.settings.headerWidth = 110;
      s.selectLayer(layer('a'));
      await settle(tester);
      expect(find.byKey(const ValueKey('upright-meter-c')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('upright-meter-c'))).width, lessThan(10));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a nested track is indented by its depth, with a guide in its folder\'s colour', (tester) async {
      await pump(tester);
      final top = tester.getTopLeft(find.descendant(of: header('c'), matching: find.text('Lead'))).dx;
      final nested = tester.getTopLeft(find.descendant(of: header('b'), matching: find.text('Bass'))).dx;
      expect(nested - top, closeTo(folderIndent(1), 0.5));
      expect(find.byKey(const ValueKey('folder-guide-b-0')), findsOneWidget);
    });

    testWidgets('a double tap opens the focus view on its effects', (tester) async {
      await pump(tester, size: const Size(1200, 800));
      await tester.tap(header('c'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('focus-tab-mixer')));
      await tester.pumpAndSettle();
      await tester.tap(header('c'));
      await tester.pumpAndSettle(); // closes
      await tester.pump(kDoubleTapTimeout);
      await tester.tap(header('c'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(header('c'));
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'c');
      expect(tester.widget<FocusPanel>(find.byType(FocusPanel)).tab, FocusTab.fx);
    });

    testWidgets('a hold let go without moving opens the menu; a hold that moves reorders', (tester) async {
      await pump(tester);
      await tester.longPress(header('c'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-menu')), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      final to = tester.getRect(header('a'));
      final g = await tester.startGesture(tester.getCenter(header('c')), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(tester.getCenter(header('c')), Offset(to.center.dx - 40, to.top + 4), i / 6)!);
        await tester.pump();
      }
      await g.up();
      await settle(tester);
      expect(s.project.layers.first.id, 'c');
      expect(find.byKey(const ValueKey('long-press-menu')), findsNothing);
    });
  });

  group('clips', () {
    testWidgets('a tap on the selected clip opens its notes; a double tap still opens its menu', (tester) async {
      await pump(tester, size: const Size(1200, 800));
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(s.selectedClipIds, {'c1'});
      expect(sections.focusedLayer, isNull, reason: 'the first tap selects');
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'a');
      expect(tester.widget<FocusPanel>(find.byType(FocusPanel)).tab, FocusTab.clip);
      // A double tap on it opens the menu instead.
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pumpAndSettle();
      expect(find.text('Edit notes'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('an edge drag changes the width, never the notes\' scale', (tester) async {
      await pump(tester, size: const Size(1200, 800));
      final body = find.byKey(const ValueKey('clip-body-c1'));
      final shown = find.descendant(of: body, matching: find.byType(Material)).first;
      final w0 = tester.getSize(shown).width;
      final note0 = tester.getRect(find.byKey(const ValueKey('clip-preview-c1')));
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-end-c1'))));
      await g.moveBy(const Offset(20, 0));
      await g.moveBy(Offset(w0 * 0.5, 0));
      await tester.pump();
      expect(tester.getSize(shown).width, greaterThan(w0 * 1.3), reason: 'wider while dragged');
      final note1 = tester.getRect(find.byKey(const ValueKey('clip-preview-c1')));
      expect(note1.left, note0.left, reason: 'the notes keep their place');
      expect(note1.width, greaterThan(note0.width), reason: 'more of the clip shows, at the same scale');
      expect(find.ancestor(of: body, matching: find.byWidgetPredicate((w) => w is Transform &&
          w.transform.getMaxScaleOnAxis() != 1)), findsNothing, reason: 'no scale');
      await g.up();
      await settle(tester);
    });

    testWidgets('one hint while no track holds a clip, centred below the ruler; it goes with the first clip',
        (tester) async {
      layer('a').clips.clear();
      await pump(tester);
      final hint = find.byKey(const ValueKey('arrange-hint'));
      expect(hint, findsOneWidget);
      final view = tester.getRect(find.byType(ArrangerScreen));
      expect(tester.getCenter(hint).dy, inInclusiveRange(view.top + view.height * 0.35, view.top + view.height * 0.7));
      s.addEmptyClip(layer('c'), 0, 16);
      await settle(tester);
      expect(hint, findsNothing);
    });
  });

  group('following the playhead', () {
    void play(double step) {
      final loop = s.project.engineLoopSteps;
      s.meters = EngineMeters(playing: true, position: (step / loop * 100000).round(), loopLength: 100000);
      s.tick.value++;
    }

    ScrollPosition hScroll(WidgetTester tester) => tester.state<ScrollableState>(find.byWidgetPredicate((w) =>
        w is Scrollable && w.axisDirection == AxisDirection.right).first).position;

    testWidgets('a selection or a finger pauses it; it resumes after the quiet spell', (tester) async {
      s.project.loopBars = 400;
      await pump(tester, size: const Size(800, 600));
      play(1);
      await tester.pump();
      play(600);
      await tester.pump();
      expect(hScroll(tester).pixels, greaterThan(0), reason: 'it follows');
      final at = hScroll(tester).pixels;
      // A time selection: paused for the delay.
      s.setTimeSelection(0, 16);
      play(1200);
      await tester.pump();
      expect(hScroll(tester).pixels, at);
      await tester.pump(const Duration(milliseconds: 2600));
      play(1201);
      await tester.pump();
      expect(hScroll(tester).pixels, greaterThan(at), reason: 'resumed after 2.5 s');
      // A finger down: never while it is there.
      final now = hScroll(tester).pixels;
      final g = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(seconds: 5));
      play(2400);
      await tester.pump();
      expect(hScroll(tester).pixels, now);
      await g.up();
      await tester.pump(const Duration(seconds: 3));
      play(2401);
      await tester.pump();
      expect(hScroll(tester).pixels, greaterThan(now));
    });

    testWidgets('Smooth keeps the playhead a third in', (tester) async {
      s.project.loopBars = 400;
      s.settings.followSmooth = true;
      await pump(tester, size: const Size(800, 600));
      play(1);
      await tester.pump();
      play(800);
      await tester.pump();
      final p1 = hScroll(tester).pixels;
      play(1000);
      await tester.pump();
      final p2 = hScroll(tester).pixels;
      final view = hScroll(tester).viewportDimension;
      // Pixels per step from the two places; the playhead's x in the view is a third in both times.
      final stepW = (p2 - p1) / 200;
      expect(stepW, greaterThan(0));
      expect(800 * stepW - p1, closeTo(view / 3, 1));
      expect(1000 * stepW - p2, closeTo(view / 3, 1));
    });

    testWidgets('the gate: off never follows; the delay is the setting; Never waits for the next Play', (tester) async {
      final settings = Settings();
      final gate = FollowGate(settings);
      expect(gate.allows(playing: true), isTrue);
      settings.followPlayhead = false;
      expect(gate.allows(playing: true), isFalse);
      settings.followPlayhead = true;
      gate.hold();
      expect(gate.allows(playing: true), isFalse);
      gate.release();
      expect(gate.allows(playing: true), isFalse, reason: 'the quiet spell');
      settings.followResume = 0;
      gate.touch();
      expect(gate.allows(playing: true), isFalse);
      expect(gate.allows(playing: false), isFalse);
      expect(gate.allows(playing: true), isTrue, reason: 'a new Play');
      expect((Settings()..fromJson({'follow_resume': 4.5})).followResume, 4.5);
      expect((Settings()..fromJson({'follow_resume': 0})).followResume, 0);
    });

    testWidgets('a different delay is respected', (tester) async {
      s.project.loopBars = 400;
      s.settings.followResume = 5;
      await pump(tester, size: const Size(800, 600));
      play(1);
      await tester.pump();
      s.setTimeSelection(0, 16);
      play(1200);
      await tester.pump(const Duration(milliseconds: 3000));
      play(1201);
      await tester.pump();
      expect(hScroll(tester).pixels, 0, reason: 'not yet after 3 s');
      await tester.pump(const Duration(milliseconds: 2100));
      play(1202);
      await tester.pump();
      expect(hScroll(tester).pixels, greaterThan(0));
    });
  });
}
