// Desktop editing next to touch (owner, 2026-11-11): Ctrl+S saves and Alt+Up/Down moves a track; a mouse drag on
// empty space selects at once and the middle button pans; a click selects a clip at once and a double-click opens
// its notes; the roll's right-click menu, cursors and Esc; Arrange's clipboard keys; Files from the keyboard; a .mid
// opened by path; the loop bar's menu and tip; clip automation points by mouse. Touch keeps its gestures.
import 'dart:convert';
import 'dart:io';

import 'package:caw/actions/actions.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_edit.dart';
import 'package:caw/model/clip_loop_edit.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/midi_clips.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/clip_roll_parts.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/key_router.dart';
import 'package:caw/ui/midi_file_actions.dart';
import 'package:caw/ui/page_closer.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:caw/ui/pointer_input.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _riff = '---\nkind: pattern\nname: Riff\nlength: 16\n---\n0 C3 8 1\n8 E3 2 1\n';

ProjectDoc _arrangeProject() => ProjectDoc(id: 'p', name: 'Desktop test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _riff),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'c1', patternId: 'pat', startSteps: 0, lengthSteps: 16),
        ClipDoc(id: 'c2', patternId: 'pat', startSteps: 32, lengthSteps: 16),
      ]),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
      LayerDoc(id: 'c', name: 'Lead', color: 2),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = _arrangeProject();
    s.ready = true;
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() {
    s.dispose();
    PointerInput.reset();
    ClipClipboard.items = const [];
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);
  ClipDoc clip(String id) => s.project.layers.expand((l) => l.clips).firstWhere((c) => c.id == id);

  group('Arrange', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
    }

    Offset laneOf(WidgetTester tester, String id, {double x = 300}) {
      final head = tester.getRect(find.byKey(ValueKey('track-header-$id')));
      return Offset(head.right + x, head.center.dy);
    }

    Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('Ctrl+S saves without moving a track; Alt+Down and Alt+Up move it', (tester) async {
      await pump(tester);
      await ctrl(tester, LogicalKeyboardKey.keyS);
      expect([for (final l in s.project.layers) l.id], ['a', 'b', 'c']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect([for (final l in s.project.layers) l.id], ['b', 'a', 'c']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect([for (final l in s.project.layers) l.id], ['a', 'b', 'c']);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a mouse drag on empty space draws a time selection at once; a finger drag does not', (tester) async {
      await pump(tester);
      final from = laneOf(tester, 'b', x: 100);
      final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 4; i++) {
        await mouse.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(s.timeSelectionStart, isNotNull, reason: 'no hold with a mouse');
      expect(s.timeSelectionEnd! - s.timeSelectionStart!, greaterThan(0));
      final drawn = (s.timeSelectionStart, s.timeSelectionEnd);
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect((s.timeSelectionStart, s.timeSelectionEnd), drawn, reason: 'the click after it keeps the selection');

      s.clearTimeSelection();
      final finger = await tester.startGesture(from);
      for (var i = 0; i < 4; i++) {
        await finger.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await finger.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.timeSelectionStart, isNull, reason: 'a finger drag scrolls');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a middle-drag pans the arrangement and edits nothing', (tester) async {
      await pump(tester);
      final h = tester.state<ScrollableState>(find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.right).first);
      expect(h.position.pixels, 0);
      final g = await tester.startGesture(laneOf(tester, 'b', x: 600), kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton);
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(-40, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(h.position.pixels, closeTo(200, 1));
      expect(s.timeSelectionStart, isNull);
      expect(layer('b').clips, isEmpty);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a click selects a clip at once; a double-click opens its notes; a finger waits for the double tap',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('clip-c1')), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(s.selectedClipIds, {'c1'}, reason: 'no double-tap wait with a mouse');

      await tester.tap(find.byKey(const ValueKey('clip-c2')), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byKey(const ValueKey('clip-c2')), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('Edit notes'), findsNothing, reason: 'a double-click is not the menu');
      expect(find.byKey(const ValueKey('focus-panel')), findsOneWidget);
      expect(s.selectedClipId, 'c2');

      s.clearClipSelection();
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pump();
      expect(s.selectedClipIds, isEmpty, reason: 'a finger tap waits out the double tap');
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.selectedClipIds, {'c1'});
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a right-click opens the clip menu, which says Open in Build', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
          child: Scaffold(body: ListenableBuilder(listenable: s,
              builder: (_, _) => ArrangerScreen(state: s, onOpenPattern: () {}))))));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('clip-c1')), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Edit notes'), findsOneWidget);
      expect(find.text('Open in Build'), findsOneWidget);
      expect(find.text('Open in Sounds'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a click on a track header selects it at once', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('track-header-c')), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(s.selectedLayerId, 'c');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Ctrl+C / Ctrl+V paste at the edit cursor with their own notes; Ctrl+X cuts; Ctrl+A; Esc',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('clip-c1')), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await ctrl(tester, LogicalKeyboardKey.keyC);
      s.seekTo(64);
      final cursor = s.editStep;
      await ctrl(tester, LogicalKeyboardKey.keyV);
      final pasted = layer('a').clips.firstWhere((c) => c.startSteps == cursor);
      expect(pasted.lengthSteps, 16);
      expect(pasted.patternId, isNot('pat'), reason: 'a copy of the notes, not the same pattern');
      expect(s.project.module(pasted.patternId)!.source, _riff);
      expect(s.selectedClipIds, {pasted.id});
      expect(s.undo(), isTrue);
      expect(layer('a').clips, hasLength(2), reason: 'one undo step');

      await ctrl(tester, LogicalKeyboardKey.keyA);
      expect(s.selectedClipIds, {'c1', 'c2'});
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(s.selectedClipIds, isEmpty);

      await tester.tap(find.byKey(const ValueKey('clip-c2')), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await ctrl(tester, LogicalKeyboardKey.keyX);
      expect(layer('a').clips.map((c) => c.id), ['c1']);
      s.selectLayer(layer('c'));
      s.seekTo(16);
      final cursor2 = s.editStep;
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(layer('c').clips.single.startSteps, cursor2, reason: 'on the selected track');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a right-click on the empty area below the tracks opens the add-track menu', (tester) async {
      await pump(tester);
      final zone = find.byKey(const ValueKey('new-track-indicator-header'));
      final at = tester.getTopLeft(zone) + const Offset(10, 60);
      await tester.tapAt(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Empty track'), findsOneWidget);
      await tester.tap(find.text('Folder').last);
      await tester.pumpAndSettle();
      expect(s.project.layers.where((l) => l.isFolder), hasLength(1));
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('piano roll', () {
    const source = '---\nkind: pattern\nname: Riff\nlength: 8\n---\n0 C4 1 1\n5 E4 1 1\n';
    setUp(() {
      s.project = ProjectDoc(id: 'p', name: 'Roll test', modules: [ModuleDoc(id: 'pat', name: 'Riff', source: source)],
          layers: [LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', lengthSteps: 16)])]);
      s.history.reset(jsonEncode(s.project.toJson()));
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
          builder: (_, _) => PatternEditor(state: s, module: s.project.module('pat')!, layer: layer('a'),
              clip: clip('c1'))))));
      await tester.pump();
    }

    Finder loopPaint() => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ClipLoopPainter);
    // The roll's top-left (the loop painter covers it); a grid point at [step] on [pitch]'s row (28 px a step, 16 a
    // row, scrolled so the highest note, E4, sits four rows down).
    Offset at(WidgetTester tester, double step, int pitch) {
      final r = tester.getRect(loopPaint());
      final scrollY = (127 - 64 - 4) * 16.0;
      return Offset(r.left + 44 + step * 28, r.top + 20 + (127 - pitch) * 16 - scrollY + 8);
    }

    List<PatternNote> notes() => PatternDoc.parse(s.project.module('pat')!.source).doc!.notes;

    testWidgets('a right-click never draws: on a note it opens the note menu, whose Delete removes it', (tester) async {
      await pump(tester);
      await tester.tapAt(at(tester, 3.5, 60), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Paste'), findsOneWidget, reason: 'the grid menu on empty grid');
      expect(find.text('Select all'), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(notes(), hasLength(2), reason: 'a right-click draws no note');

      await tester.tapAt(at(tester, 0.5, 60), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsOneWidget);
      expect(find.text('Velocity 50%'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(notes().map((n) => n.pitch), [64]);
    });

    testWidgets('a mouse drag on empty grid draws a selection box at once (touch keeps the setting: scroll)',
        (tester) async {
      expect(s.settings.roll.emptyDrag, EmptyDrag.scroll);
      await pump(tester);
      final g = await tester.startGesture(at(tester, 4.4, 66), kind: PointerDeviceKind.mouse);
      await g.moveTo(at(tester, 6.5, 63));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump(const Duration(seconds: 1));
      expect(notes().map((n) => n.pitch), [60], reason: 'the box selected E4 and Delete removed it; nothing drawn');

      final f = await tester.startGesture(at(tester, 4.4, 66));
      await f.moveTo(at(tester, 6.5, 50));
      await tester.pump();
      await f.up();
      await tester.pump(const Duration(seconds: 1));
      expect(notes(), hasLength(1));
      final painter = tester.widget<CustomPaint>(loopPaint()).painter! as ClipLoopPainter;
      expect(painter.scrollY, isNot((127 - 64 - 4) * 16.0), reason: 'a finger drag scrolls');
    });

    testWidgets('a middle-drag pans and draws nothing', (tester) async {
      await pump(tester);
      final g = await tester.startGesture(at(tester, 3.5, 62), kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(0, 20));
        await tester.pump();
      }
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      expect(notes(), hasLength(2));
      final painter = tester.widget<CustomPaint>(loopPaint()).painter! as ClipLoopPainter;
      expect(painter.scrollY, closeTo((127 - 64 - 4) * 16.0 - 80, 0.5));
    });

    testWidgets('the mouse cursor: move on a note, resize at its end, crosshair for the Draw tool', (tester) async {
      await pump(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: at(tester, 3.5, 62));
      await tester.pump();
      MouseCursor? cursor() => RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
      await mouse.moveTo(at(tester, 3.5, 62) + const Offset(1, 0));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.precise);
      await mouse.moveTo(at(tester, 5.5, 64));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.move);
      await mouse.moveTo(at(tester, 5.95, 64));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.resizeLeftRight);
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the loop bar: a right-click menu (reset, loop off) and a hover tip with its length', (tester) async {
      s.setClipLoop(layer('a'), clip('c1'), 4);
      await pump(tester);
      final r = tester.getRect(loopPaint());
      final bar = Offset(r.left + 44 + 4 * 28.0 + 2, r.top + 200);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: bar - const Offset(100, 0));
      await tester.pump();
      await mouse.moveTo(bar);
      await tester.pump();
      expect(find.byKey(const ValueKey('roll-loop-tip')), findsOneWidget);
      expect(find.textContaining('Loop 1 beat'), findsOneWidget);
      await mouse.removePointer();
      await tester.pump();

      await tester.tapAt(bar, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to pattern length'));
      await tester.pumpAndSettle();
      expect(clip('c1').loopSteps, isNull);
      expect(clip('c1').loop, isTrue);

      final r2 = tester.getRect(loopPaint());
      await tester.tapAt(Offset(r2.left + 44 + 8 * 28.0 + 2, r2.top + 200), kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Loop off'));
      await tester.pumpAndSettle();
      expect(clip('c1').loop, isFalse);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('clip automation by mouse: double-click adds and removes, Delete removes the selected, right-click menu',
        (tester) async {
      layer('a').volume = 0.5;
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('clip-lane-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volume').last);
      await tester.pumpAndSettle();
      final key = 'clip|c1|${automationKey('track', 'volume', layerId: 'a')}';
      List<AutomationPointDoc> points() => clip('c1').automation.single.points;
      expect(points(), hasLength(2));
      final surface = find.byKey(ValueKey('lane-surface-$key'));
      final mid = tester.getRect(surface).topLeft + const Offset(2 * 28.0, 12);

      await tester.tapAt(mid, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(points(), hasLength(2), reason: 'a click adds nothing with a mouse');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tapAt(mid, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(mid, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(points(), hasLength(3), reason: 'a double-click adds a point');

      await tester.pump(const Duration(milliseconds: 500));
      final p1 = find.byKey(ValueKey('lane-point-$key-1'));
      await tester.tap(p1, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(p1, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(points(), hasLength(2), reason: 'a double-click on a point removes it');

      Future<void> doubleClickAdd() async {
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tapAt(mid, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(mid, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 500));
      }

      await doubleClickAdd();
      expect(points(), hasLength(3));
      await tester.tap(find.byKey(ValueKey('lane-point-$key-1')), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(points(), hasLength(2), reason: 'Delete removes the selected point');
      expect(layer('a').clips, hasLength(1), reason: 'and not the clip or the track');

      await doubleClickAdd();
      await tester.tap(find.byKey(ValueKey('lane-point-$key-1')), kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Reset curve'), findsOneWidget);
      await tester.tap(find.text('Delete point'));
      await tester.pumpAndSettle();
      expect([for (final p in points()) p.step], [0, 8]);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a finger keeps its lane gestures: a tap adds a point, a double tap on one removes it', (tester) async {
      layer('a').volume = 0.5;
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('clip-lane-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volume').last);
      await tester.pumpAndSettle();
      final key = 'clip|c1|${automationKey('track', 'volume', layerId: 'a')}';
      final surface = find.byKey(ValueKey('lane-surface-$key'));
      await tester.tapAt(tester.getRect(surface).topLeft + const Offset(2 * 28.0, 12));
      await tester.pump(const Duration(milliseconds: 400));
      expect(clip('c1').automation.single.points, hasLength(3));
      final p = find.byKey(ValueKey('lane-point-$key-1'));
      await tester.tap(p);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(p);
      await tester.pump(const Duration(milliseconds: 400));
      expect(clip('c1').automation.single.points, hasLength(2));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the full-screen roll is a closable page; Esc with nothing selected leaves it', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Full screen'));
      await tester.pumpAndSettle();
      final full = find.byWidgetPredicate((w) => w is PatternEditor && w.fullScreen);
      expect(full, findsOneWidget);
      expect(ModalRoute.of(tester.element(full))!.settings.name, closablePage.name);
      final focus = tester.widget<Focus>(find.descendant(of: full, matching: find.byWidgetPredicate(
          (w) => w is Focus && w.onKeyEvent != null && w.focusNode != null)).first);
      focus.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(full, findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Ctrl+S in the roll saves and does not move the cursor', (tester) async {
      await pump(tester);
      await tester.tapAt(at(tester, 3.5, 60), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(seconds: 1));
      final before = notes().length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(seconds: 1));
      expect(notes().length, before);
      expect(tester.takeException(), isNull);
    });
  });

  group('Files', () {
    testWidgets('arrows move the selection, Enter opens, F2 renames, Delete asks then deletes', (tester) async {
      s.project = ProjectDoc(id: 'f', name: 'Files keys', modules: [
        ModuleDoc(id: 'riff', name: 'Riff', source: '---\nkind: pattern\n---\n0 A2 1 1'),
        ModuleDoc(id: 'beat', name: 'Beat', source: '---\nkind: pattern\n---\nc4'),
      ], cppComponents: [CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz')]);
      s.info['riff'] = const ModuleInfo(ok: true, kind: 'pattern');
      s.info['beat'] = const ModuleInfo(ok: true, kind: 'pattern');
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sections = SectionController();
      addTearDown(sections.dispose);
      await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
          child: Scaffold(body: FileManagerScreen(state: s, onOpenBuilder: () {})))));
      await tester.pump();
      await tester.tap(find.text('Audio & MIDI').first);
      await tester.pump();
      await tester.tap(find.text('Patterns').last);
      await tester.pump();
      final first = find.byKey(const ValueKey('mod:beat')).evaluate().isNotEmpty &&
              tester.getTopLeft(find.byKey(const ValueKey('mod:beat'))).dx <
                  tester.getTopLeft(find.byKey(const ValueKey('mod:riff'))).dx
          ? 'beat'
          : 'riff';
      final second = first == 'beat' ? 'riff' : 'beat';
      await tester.tap(find.byKey(ValueKey('mod:$first')), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Used on no track').evaluate().isNotEmpty || find.text('Not used on any track').evaluate().isNotEmpty,
          isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Groove');
      await tester.tap(find.text('OK').evaluate().isNotEmpty ? find.text('OK') : find.text('Rename').last);
      await tester.pumpAndSettle();
      expect(s.project.module(second)!.name, 'Groove', reason: 'the arrow moved to the next item; F2 renamed it');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget, reason: 'asks first');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(s.project.module(first), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sections.activeBuildTab, BuildTab(BuildTabKind.pattern, second));
      await tester.pump(const Duration(seconds: 3));
    });
  });

  testWidgets('the middle button and Space+drag pan; a pan takes back the play Space started, once', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    const left = PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    expect(startsMousePan(const PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton)), isTrue);
    expect(startsMousePan(left), isFalse);
    expect(startsMousePan(const PointerDownEvent(kind: PointerDeviceKind.touch, buttons: kPrimaryButton)), isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    expect(startsMousePan(left), isTrue);
    var undone = 0;
    SpacePan.armUndo(() => undone++);
    SpacePan.claim();
    SpacePan.claim();
    expect(undone, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    expect(startsMousePan(left), isFalse);
  });

  testWidgets('a .mid opened by path becomes pattern clips', (tester) async {
    s.project = ProjectDoc(id: 'm', name: 'MIDI path', layers: [LayerDoc(id: 'a', name: 'Keys', color: 0)]);
    final doc = PatternDoc.parse(_riff).doc!;
    final bytes = patternToMidi(doc, bpm: 120, beatsPerBar: 4, name: 'Riff');
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    }))));
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('caw-mid');
      try {
        final f = File('${dir.path}/riff.mid');
        await f.writeAsBytes(bytes);
        await importMidiFromPath(context, s, f.path);
      } finally {
        await dir.delete(recursive: true);
      }
    });
    await tester.pump();
    expect(s.project.layers.expand((l) => l.clips), isNotEmpty);
    await tester.pump(const Duration(seconds: 5));
  });
}
