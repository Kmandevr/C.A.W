// The piano roll opened for a clip (owner, 2026-11-11): the loop-end bar dragged by finger (on the ruler, on the grid)
// and by mouse (with a resize cursor), one undo step; the clip's automation lanes added there and moved to the track.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/clip_roll_parts.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = '---\nkind: pattern\nname: Riff\nlength: 8\n---\n0 C4 1 1\n5 E4 1 1\n';

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'Clip roll test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _source),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', lengthSteps: 16)]),
    ]);
    s.ready = true;
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() => s.dispose());

  LayerDoc layer() => s.project.layers.first;
  ClipDoc clip() => layer().clips.first;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => PatternEditor(state: s, module: s.project.module('pat')!, layer: layer(), clip: clip())))));
    await tester.pump();
  }

  // The roll's top-left (the loop painter covers it) and the loop bar's x for [steps] at the default 28 px a step.
  Rect roll(WidgetTester tester) =>
      tester.getRect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ClipLoopPainter));
  double barX(WidgetTester tester, int steps) => roll(tester).left + 44 + steps * 28.0;

  testWidgets('a finger drags the loop bar on the ruler, on the grid; one undo step', (tester) async {
    await pump(tester);
    final r = roll(tester);
    expect((tester.widget(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ClipLoopPainter)) as CustomPaint)
        .painter, isA<ClipLoopPainter>().having((p) => p.label, 'label', '2 beats'));
    final g = await tester.startGesture(Offset(barX(tester, 8), r.top + 10), kind: PointerDeviceKind.touch);
    for (var i = 1; i <= 4; i++) {
      await g.moveBy(const Offset(-28.0 * 4.2 / 4, 0));
      await tester.pump();
    }
    expect(clip().loopSteps, isNull, reason: 'it applies when let go');
    await g.up();
    await tester.pump();
    expect(clip().loopSteps, 4, reason: 'snapped to the grid');
    expect(s.undo(), isTrue);
    await tester.pump();
    expect(clip().loopSteps, isNull);
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ClipLoopPainter), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a mouse over the bar shows a resize cursor and drags it down the grid', (tester) async {
    await pump(tester);
    final r = roll(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset(r.left + 300, r.top + 300));
    await tester.pump();
    await mouse.moveTo(Offset(barX(tester, 8) + 2, r.top + 200));
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.resizeColumn);
    await mouse.down(Offset(barX(tester, 8) + 2, r.top + 200));
    await mouse.moveBy(const Offset(28.0 * 4, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(1, 0));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(clip().loopSteps, 12);
    await mouse.moveTo(Offset(r.left + 300, r.top + 300));
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), isNot(SystemMouseCursors.resizeColumn));
    await mouse.removePointer();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the Automation picker adds a clip lane; its menu moves it to the track', (tester) async {
    layer().volume = 0.5;
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('clip-lane-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Volume').last);
    await tester.pumpAndSettle();
    final lane = clip().automation.single;
    expect(lane.target, 'volume');
    expect([for (final p in lane.points) p.step], [0, 8], reason: 'flat across the loop');
    final key = 'clip|c1|${automationKey('track', 'volume', layerId: 'a')}';
    expect(find.byKey(ValueKey('clip-lane-row-$key')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('clip-lane-menu-$key')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to track'));
    await tester.pumpAndSettle();
    expect(clip().automation, isEmpty);
    expect(layer().automation.single.target, 'volume');
    await tester.pump(const Duration(seconds: 1));
  });
}
