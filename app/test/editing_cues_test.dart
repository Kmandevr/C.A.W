// Editing cues (owner, 2026-11-12): the piano roll's edit cursor and ruler (a tap moves the song's cursor, a drag draws
// the song's loop), a loop handle dragged onto the other end removing the loop (Arrange and the roll; undo brings it
// back), a dragged or trimmed clip's guide lines and bar.beat tag, motion Off, and holds that open a menu or move.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_edit.dart';
import 'package:caw/model/arrange_markers.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/clip_preview.dart';
import 'package:caw/ui/arrange/edit_cues.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/key_router.dart';
import 'package:caw/actions/actions.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Cues', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: '---\nkind: pattern\nlength: 16\n---\n0 C3 4 1\n4 E3 4 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 16)]),
      LayerDoc(id: 'b', name: 'Bass', color: 2, clips: [ClipDoc(id: 'c2', patternId: 'pat', startSteps: 48, lengthSteps: 16)]),
      LayerDoc(id: 'c', name: 'Lead', color: 3),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() {
    Motion.setting = MotionLevel.full;
    s.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // saves and history settle
  }

  group('Arrange', () {
    Future<void> pump(WidgetTester tester, {Size size = const Size(1400, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
        child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
    }

    Rect ruler(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('arrange-ruler')));

    /// The ruler's top half at [step] (zoom 18 px a step).
    Offset at(WidgetTester tester, int step) => Offset(ruler(tester).left + step * 18 + 1, ruler(tester).top + 6);

    ClipGuidePainter? guides(WidgetTester tester) {
      final f = find.byKey(const ValueKey('clip-drag-guides'));
      return f.evaluate().isEmpty ? null : tester.widget<CustomPaint>(f).painter! as ClipGuidePainter;
    }

    double guideOpacity(WidgetTester tester) => tester.widget<FadeTransition>(find.ancestor(
        of: find.byKey(const ValueKey('clip-drag-guides')), matching: find.byType(FadeTransition)).first).opacity.value;

    testWidgets('a loop handle dragged onto the other end turns the loop off and removes it; undo restores it',
        (tester) async {
      s.setLoopRange(4, 16);
      await pump(tester);
      expect(find.byKey(const ValueKey('ruler-loop')), findsOneWidget);
      // The end handle onto the start.
      await tester.dragFrom(at(tester, 16), const Offset(-12 * 18.0, 0));
      await tester.pump();
      expect(s.project.loopRange, isFalse);
      expect(s.project.hasLoopRange, isFalse, reason: 'its markers are gone');
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(const ValueKey('ruler-loop')), findsOneWidget, reason: 'it fades out');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ruler-loop')), findsNothing);
      expect(s.undo(), isTrue);
      await tester.pumpAndSettle();
      expect((s.project.loopStartSteps, s.project.loopEndSteps, s.project.loopRange), (4, 16, true));
      expect(find.byKey(const ValueKey('ruler-loop')), findsOneWidget);
      // The start handle onto the end does the same.
      await tester.dragFrom(at(tester, 4), const Offset(12 * 18.0, 0));
      await tester.pumpAndSettle();
      expect(s.project.hasLoopRange, isFalse);
      await settle(tester);
    });

    testWidgets('motion Off: the collapsed loop goes at once', (tester) async {
      Motion.setting = MotionLevel.off;
      s.setLoopRange(4, 16);
      await pump(tester);
      await tester.dragFrom(at(tester, 16), const Offset(-12 * 18.0, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('ruler-loop')), findsNothing);
      await settle(tester);
    });

    testWidgets('a moved clip shows two guides at its start and end and its start as bar.beat; they fade out after',
        (tester) async {
      await pump(tester);
      expect(guides(tester), isNull);
      final clip = tester.getRect(find.byKey(const ValueKey('clip-c1')));
      final g = await tester.startGesture(clip.center, kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(10, 0));
      await g.moveBy(const Offset(4 * 18.0 - 10, 0));
      await tester.pump();
      var p = guides(tester)!;
      expect((p.guide.start, p.guide.end), (20, 36));
      expect(p.startX, 20 * 18.0, reason: 'at the clip\'s new start, in the lanes\' pixels');
      expect(p.endX, 36 * 18.0);
      expect(p.guide.color, isNot(Neon.blue), reason: 'in the clip\'s colour');
      expect(p.label, '2.2');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 200));
      expect(guideOpacity(tester), 1, reason: 'faded in');
      // The lines run from the ruler's top down past the last track.
      final box = tester.getRect(find.byKey(const ValueKey('clip-drag-guides')));
      expect(box.top, lessThanOrEqualTo(ruler(tester).top));
      expect(box.bottom, greaterThan(tester.getRect(find.byKey(const ValueKey('track-header-c'))).bottom));
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(guides(tester), isNotNull, reason: 'fading out');
      expect(guideOpacity(tester), lessThan(1));
      await tester.pumpAndSettle();
      expect(guides(tester), isNull);
      expect(s.project.layers.first.clips.single.startSteps, 20);

      // Several selected clips: the selection's first start and last end, moved together.
      s.selectClip(s.project.layers[0], s.project.layers[0].clips.single);
      s.toggleClipSelection(s.project.layers[1], s.project.layers[1].clips.single);
      await tester.pump();
      final g2 = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-c1'))),
          kind: PointerDeviceKind.mouse);
      await g2.moveBy(const Offset(10, 0));
      await g2.moveBy(const Offset(2 * 18.0 - 10, 0));
      await tester.pump();
      p = guides(tester)!;
      expect((p.guide.start, p.guide.end), (22, 66));
      await g2.up();
      await settle(tester);
      expect(guides(tester), isNull);
    });

    testWidgets('an edge trim shows the guides too, where the clip will start and end', (tester) async {
      await pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-end-c1'))),
          kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(4 * 18.0, 0));
      await tester.pump();
      expect((guides(tester)!.guide.start, guides(tester)!.guide.end), (16, 36));
      await g.up();
      await settle(tester);
      expect(guides(tester), isNull);
      final g2 = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-start-c1'))),
          kind: PointerDeviceKind.mouse);
      await g2.moveBy(const Offset(4 * 18.0, 0));
      await tester.pump();
      expect((guides(tester)!.guide.start, guides(tester)!.guide.end), (20, 36));
      await g2.up();
      await settle(tester);
    });

    testWidgets('motion Off: the guides show and go at once', (tester) async {
      Motion.setting = MotionLevel.off;
      await pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-c1'))),
          kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(10, 0));
      await g.moveBy(const Offset(18, 0));
      await tester.pump();
      expect(guideOpacity(tester), 1);
      await g.up();
      await tester.pump();
      expect(guides(tester), isNull);
      await settle(tester);
    });

    testWidgets('a finger that moves before the hold fires moves the clip and never opens the menu', (tester) async {
      await pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-c1'))));
      await g.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byKey(const ValueKey('long-press-menu')), findsNothing);
      await g.up();
      await settle(tester);
      expect(find.byKey(const ValueKey('long-press-menu')), findsNothing);
      expect(s.project.layers.first.clips.single.startSteps, greaterThan(16));
    });

    testWidgets('a held clip\'s menu closes with Esc, a tap outside or a choice; it is a real menu', (tester) async {
      await pump(tester);
      await tester.longPress(find.byKey(const ValueKey('clip-c1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-menu')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-menu')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('clip-c1')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-menu')), findsNothing, reason: 'a tap outside closes it');
      await tester.longPress(find.byKey(const ValueKey('clip-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate independently'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-menu')), findsNothing);
      expect(s.project.layers.first.clips, hasLength(2), reason: 'the choice ran');
      await settle(tester);
    });

    testWidgets('golden: a dragged clip\'s guides and bar.beat tag at phone size', (tester) async {
      s.project.layers.first.clips.single
        ..startSteps = 2
        ..lengthSteps = 6;
      await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))),
          goldenSizes['phone']!);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-c1'))),
          kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(10, 0));
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(goldenScreen, matchesGoldenFile('goldens/arrange_drag_guides_phone.png'));
      await g.up();
      await settle(tester);
    });
  });

  group('piano roll', () {
    LayerDoc layer() => s.project.layers.first;
    ClipDoc clip() => layer().clips.first;

    Future<void> pump(WidgetTester tester, {Size size = const Size(900, 800)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
          builder: (_, _) => PatternEditor(state: s, module: s.project.module('pat')!, layer: layer(), clip: clip())))));
      await tester.pump();
    }

    RollPlayheadPainter head(WidgetTester tester) =>
        tester.widget<CustomPaint>(find.byKey(const ValueKey('roll-playhead'))).painter! as RollPlayheadPainter;

    /// The roll's ruler at its step [step] (the clip starts at song step 16), in the ruler's top half.
    Offset at(WidgetTester tester, double step) {
      final box = tester.getRect(find.byKey(const ValueKey('roll-playhead')));
      final h = head(tester);
      return Offset(box.left + h.left + step * h.pxPerStep - h.scrollX, box.top + 5);
    }

    testWidgets('it shows the edit cursor stopped, across the whole roll, as Arrange does', (tester) async {
      s.seekTo(20);
      await pump(tester);
      expect(head(tester).stopped, isTrue);
      expect(head(tester).step, 4, reason: 'song step 20 is the clip\'s step 4');
      final box = tester.getRect(find.byKey(const ValueKey('roll-playhead')));
      expect(head(tester).bottom, box.height, reason: 'down the whole roll, the lanes too');
    });

    testWidgets('a tap on the ruler moves the cursor there, on the grid', (tester) async {
      await pump(tester);
      await tester.tapAt(at(tester, 6.3));
      await tester.pumpAndSettle();
      expect(s.pausedStep, 22, reason: 'the clip\'s step 6 is the song\'s 22');
      expect(head(tester).step, 6);
      expect(s.project.hasLoopRange, isFalse, reason: 'a tap draws no loop');
      await settle(tester);
    });

    testWidgets('a drag along the ruler draws the song\'s loop and turns it on; a handle onto the other end removes it',
        (tester) async {
      await pump(tester);
      await tester.timedDragFrom(at(tester, 2), Offset(8 * head(tester).pxPerStep, 0), const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect((s.project.loopStartSteps, s.project.loopEndSteps, s.project.loopRange), (18, 26, true));
      expect(find.byKey(const ValueKey('ruler-loop')), findsOneWidget);
      // Arrange's loop and the roll's are one: the end handle moves it.
      await tester.timedDragFrom(at(tester, 10), Offset(2 * head(tester).pxPerStep, 0), const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect((s.project.loopStartSteps, s.project.loopEndSteps), (18, 28));
      // The start handle dragged onto the end: off and removed; undo brings it back.
      await tester.timedDragFrom(at(tester, 2), Offset(10 * head(tester).pxPerStep, 0), const Duration(milliseconds: 300));
      await tester.pump();
      expect(s.project.hasLoopRange, isFalse);
      expect(s.project.loopRange, isFalse);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ruler-loop')), findsNothing);
      expect(s.undo(), isTrue);
      await tester.pumpAndSettle();
      expect((s.project.loopStartSteps, s.project.loopEndSteps, s.project.loopRange), (18, 28, true));
      expect(find.byKey(const ValueKey('ruler-loop')), findsOneWidget);
      await settle(tester);
    });

    testWidgets('motion Off: the removed loop goes at once', (tester) async {
      Motion.setting = MotionLevel.off;
      s.setLoopRange(18, 26);
      await pump(tester);
      expect(find.byKey(const ValueKey('ruler-loop')), findsOneWidget);
      await tester.timedDragFrom(at(tester, 10), Offset(-8 * head(tester).pxPerStep, 0), const Duration(milliseconds: 300));
      await tester.pump();
      expect(s.project.hasLoopRange, isFalse);
      expect(find.byKey(const ValueKey('ruler-loop')), findsNothing);
      await settle(tester);
    });

    testWidgets('golden: the song\'s loop on the roll\'s ruler and the edit cursor at phone size', (tester) async {
      s.setLoopRange(18, 26);
      s.seekTo(22);
      await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s,
          builder: (_, _) => PatternEditor(state: s, module: s.project.module('pat')!, layer: layer(), clip: clip()))),
          goldenSizes['phone']!);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_ruler_loop_phone.png'));
      await settle(tester);
    });
  });

  group('note lines in clips (owner, 2026-11-12: "Thin note lines")', () {
    // A dense pattern: chords over three octaves, every step.
    final dense = StringBuffer('---\nkind: pattern\nlength: 64\n---\n');
    for (var i = 0; i < 64; i++) {
      for (final p in [36, 43, 48, 52, 55, 60, 64, 67, 72]) {
        dense.writeln('$i ${['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'][p % 12]}${p ~/ 12 - 1} 1 1');
      }
    }

    test('the layout keeps lines between 1 and 2 px with a gap, whatever the height and range', () {
      for (final h in [6.0, 10.0, 14.0, 22.0, 40.0, 60.0, 120.0]) {
        for (final range in [0.0, 1.0, 5.0, 12.0, 24.0, 48.0, 100.0]) {
          final l = noteLineLayout(60, 60 + range, h);
          expect(l.thickness, inInclusiveRange(kNoteLineMin, kNoteLineMax), reason: 'h $h range $range');
          final lines = ((range + 1) / l.perLine).ceil();
          if (lines > 1 && h >= lines * (kNoteLineMax + kNoteLineGap)) {
            expect(l.row, greaterThanOrEqualTo(l.thickness + kNoteLineGap - 1e-9), reason: 'h $h range $range');
          }
          expect(l.top + l.row * (lines - 1) + l.thickness, lessThanOrEqualTo(h + 1e-6), reason: 'fits the clip');
        }
      }
    });

    test('zoomed far out, no note line is thicker than the maximum; drums draw small ticks', () {
      final cache = ClipPictureCache();
      final p = cache.parsed('pat', dense.toString(), dense.toString(), 4);
      expect(p.doc!.notes, isNotEmpty);
      for (final stepW in [0.02, 0.1, 0.5, 2.0, 8.0, 24.0]) {
        for (final drums in [false, true]) {
          final spy = _SpyCanvas();
          ClipPictureCache.paintNotes(spy, p, stepW, 40, Colors.white, drums: drums);
          expect(spy.paths, hasLength(1), reason: 'one batched path a pattern');
          var contours = 0;
          for (final m in spy.paths.single.computeMetrics()) {
            contours++;
            final b = m.extractPath(0, m.length).getBounds();
            expect(b.height, lessThanOrEqualTo((drums ? kDrumTickHeight : kNoteLineMax) + 1e-6),
                reason: 'stepW $stepW drums $drums: a ${b.height} px tall mark');
            if (drums) expect(b.width, lessThanOrEqualTo(kNoteLineMax + 1e-6));
          }
          expect(contours, p.doc!.notes.length);
        }
      }
    });

    Future<void> goldenAt(WidgetTester tester, int bars, String name) async {
      s.project = ProjectDoc(id: 'p', name: 'Lines', modules: [
        ModuleDoc(id: 'pat', name: 'Chords', source: dense.toString()),
        ModuleDoc(id: 'lead', name: 'Lead', source: '---\nkind: pattern\nlength: 16\n---\n0 C4 2 1\n2 E4 2 1\n4 G4 4 1\n8 B4 2 1\n10 D5 6 1\n'),
        ModuleDoc(id: 'beat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n4 D2 1 1\n8 C2 1 1\n10 F#2 1 1\n12 D2 1 1\n14 F#2 1 1\n'),
      ], layers: [
        LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', startSteps: 0, lengthSteps: bars * 16)]),
        LayerDoc(id: 'b', name: 'Lead', color: 2, clips: [ClipDoc(id: 'c2', patternId: 'lead', startSteps: 0, lengthSteps: bars * 16)]),
        LayerDoc(id: 'd', name: 'Drums', color: 4, instrument: ComponentUseDoc('org.caw.drums'),
            clips: [ClipDoc(id: 'c3', patternId: 'beat', startSteps: 0, lengthSteps: bars * 16)]),
      ]);
      await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))),
          goldenSizes['phone']!);
      await tester.tap(find.byKey(const ValueKey('arrange-zoom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('arrange-zoom-fit')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/$name'));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('golden: zoomed out (64 bars) the clips show thin note lines and drum ticks, at phone size',
        (tester) => goldenAt(tester, 64, 'arrange_notes_zoomed_out_phone.png'));

    testWidgets('golden: a mid zoom (4 bars), at phone size',
        (tester) => goldenAt(tester, 4, 'arrange_notes_mid_zoom_phone.png'));
  });
}

/// Records the paths a painter draws.
class _SpyCanvas implements Canvas {
  final paths = <Path>[];
  @override
  void drawPath(Path path, Paint paint) => paths.add(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
