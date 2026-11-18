// Better track automation (#230): curved segments (the model, its JSON and the engine's), the lane tools (pencil,
// line, shapes, eraser), select and transform, copy and paste, Automate from a knob, the picker and clip-follow.
import 'dart:convert';

import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/automation_curve.dart';
import 'package:caw/model/automation_edit.dart';
import 'package:caw/model/automation_writer.dart' show AutomationTarget;
import 'package:caw/model/clip_automation.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/automate_control.dart';
import 'package:caw/ui/arrange/knob.dart';
import 'package:caw/ui/arrange/lane_tools.dart';
import 'package:caw/ui/arrange/track_lanes.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _chorus = NativeComponentInfo(id: 'org.caw.chorus', name: 'Chorus', role: 'effect', builtin: true, parameters: [
  ComponentParameterInfo(id: 'mix', name: 'Mix', defaultValue: 0.5, min: 0, max: 1),
  ComponentParameterInfo(id: 'rate', name: 'Rate', defaultValue: 1, min: 0, max: 8),
]);

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Lane tools', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 1 bar\n---\n0 C4 4 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, components: [ComponentUseDoc('org.caw.chorus', {'mix': 0.25})], clips: [
        ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 16),
      ]),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
    ]);

AutomationPointDoc _p(double step, double value, [AutomationCurve curve = AutomationCurve.linear, double tension = 0]) =>
    AutomationPointDoc(step: step, value: value, curve: curve, tension: tension);

void main() {
  group('curves', () {
    test('the closed forms hit the engine\'s exact references', () {
      expect(curveShape(AutomationCurve.slow, 0, 0.5), 0.28125);
      expect(curveShape(AutomationCurve.fast, 0, 0.5), 0.71875);
      expect(curveShape(AutomationCurve.slow, 1, 0.5), 0.0625);
      expect(curveShape(AutomationCurve.fast, 1, 0.5), 0.9375);
      expect(curveShape(AutomationCurve.slow, -1, 0.5), 0.5, reason: 'tension -1 is a straight line');
      expect(curveShape(AutomationCurve.sCurve, 0, 0.25), 0.140625);
      expect(curveShape(AutomationCurve.sCurve, 0, 0.75), 0.859375);
      expect(curveShape(AutomationCurve.step, 0, 0.99), 0);
      // The same bits the engine's params_test records (IEEE-754 double, no fused multiply-add).
      expect(curveShape(AutomationCurve.slow, 0.25, 0.3), 0.11153846153846153);
      expect(laneValueAt([_p(0, 0, AutomationCurve.slow), _p(4, 8, AutomationCurve.step), _p(8, 0)], 2, 0), 2.25);
      expect(laneValueAt([_p(0, 0, AutomationCurve.slow), _p(4, 8, AutomationCurve.step), _p(8, 0)], 7.9, 0), 8);
      // Linear stays the old expression.
      final pts = [_p(0, 0.1), _p(3, 0.7)];
      expect(laneValueAt(pts, 1.3, 0), 0.1 + (0.7 - 0.1) * (1.3 / 3));
    });

    test('a point\'s curve round-trips, a linear one writes what it always did, and a load is bounded', () {
      final p = _p(4, 0.5, AutomationCurve.fast, 0.25);
      expect(p.toJson(), {'step': 4.0, 'value': 0.5, 'curve': 'fast', 'tension': 0.25});
      final back = AutomationPointDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect((back.curve, back.tension), (AutomationCurve.fast, 0.25));
      expect(_p(1, 2).toJson(), {'step': 1.0, 'value': 2.0});
      AutomationPointDoc read(Map<String, dynamic> j) => AutomationPointDoc.fromJson(j);
      expect(read({'step': 0, 'value': 0, 'curve': 'spiral', 'tension': 0.5}).curve, AutomationCurve.linear);
      expect(read({'step': 0, 'value': 0, 'curve': 's', 'tension': 9}).tension, 1);
      expect(read({'step': 0, 'value': 0, 'curve': 'slow', 'tension': 'x'}).tension, 0);
      expect(read({'step': 0, 'value': 0, 'curve': 'step', 'tension': 0.5}).tension, 0, reason: 'a step has no bend');
      final lane = AutomationLaneDoc.fromJson({'target': 'pan', 'height': 9999, 'points': [p.toJson()]});
      expect(lane.height, kMaxLaneHeight);
      expect(lane.points.single.curve, AutomationCurve.fast);
    });

    test('the engine JSON carries curves and leaves the lane heights out', () {
      final project = _project();
      project.layers.first.automation.add(AutomationLaneDoc(target: 'volume', height: 80,
          points: [_p(0, 0.2, AutomationCurve.sCurve, -0.5), _p(16, 1)]));
      project.automation.add(ProjectAutomationLaneDoc(targetType: 'component', target: 'mix', layerId: 'a', component: 0,
          height: 70, points: [_p(0, 0, AutomationCurve.step), _p(8, 1)]));
      final j = jsonDecode(project.toEngineJson()) as Map<String, dynamic>;
      final track = ((j['layers'] as List).first as Map)['automation'] as List;
      expect((track.single as Map)['points'][0], {'step': 0.0, 'value': 0.2, 'curve': 's', 'tension': -0.5});
      expect((track.single as Map).containsKey('height'), isFalse);
      final lane = (j['automation'] as List).single as Map;
      expect(lane['points'][0]['curve'], 'step');
      expect(lane.containsKey('height'), isFalse);
    });

    test('a clip lane unrolls with its curves; a bent segment cut by the loop is followed in pieces', () {
      final clip = ClipDoc(id: 'c', patternId: 'pat', startSteps: 8, lengthSteps: 12, loop: true);
      final local = [_p(0, 0, AutomationCurve.slow), _p(8, 1, AutomationCurve.step), _p(10, 0.5)];
      final span = clipLaneSpan(clip, local, 10);
      final merged = mergeClipLanes(const [], 0.3, [span]);
      // Inside the first pass the curve plays as written.
      expect(laneValueAt(merged, 12, 0), closeTo(laneValueAt(local, 4, 0), 1e-12));
      expect(laneValueAt(merged, 17, 0), 1, reason: 'the step holds');
      // The second pass is cut at 2 steps of 10, inside the slow segment: straight pieces along the curve.
      expect(laneValueAt(merged, 19, 0), closeTo(laneValueAt(local, 1, 0), 0.01));
      expect(merged.where((p) => p.curve == AutomationCurve.slow), isNotEmpty);
    });

    test('bending: sideways right is fast, left slow, near 0 straight; an S keeps its shape', () {
      final p = _p(0, 0);
      withBend(p, 0.6);
      expect(p.curve, AutomationCurve.fast);
      expect(p.tension, closeTo(0.2, 1e-12));
      expect(bendOf(p), closeTo(0.6, 1e-12));
      withBend(p, -1);
      expect((p.curve, p.tension), (AutomationCurve.slow, 1.0));
      withBend(p, 0.01);
      expect(p.curve, AutomationCurve.linear);
      final s = _p(0, 0, AutomationCurve.sCurve);
      withBend(s, 1);
      expect((s.curve, s.tension), (AutomationCurve.sCurve, 1.0));
    });
  });

  group('tool maths', () {
    test('the pencil thins its stroke; the line is two points', () {
      final stroke = [for (var i = 0; i <= 40; i++) (i / 4, i < 20 ? 0.2 : 0.8)];
      final pts = pencilPoints(stroke);
      expect(pts.length, lessThan(8));
      expect(pts.first.step, 0);
      expect(pts.last.step, 10);
      expect(linePoints((8, 0.9), (2, 0.1)).map((p) => (p.step, p.value)), [(2.0, 0.1), (8.0, 0.9)]);
    });

    test('shapes at the grid rate: a sine of curved quarters, a stepped square, a saw that drops, a seeded random', () {
      final sine = shapePoints(LaneShape.sine, 0, 8, 4, 0.5, 0.25);
      expect(sine.map((p) => p.step), [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(sine[1].value, 0.75);
      expect(sine[0].curve, AutomationCurve.fast);
      expect(sine[1].curve, AutomationCurve.slow);
      final square = shapePoints(LaneShape.square, 0, 8, 4, 0.5, 0.25);
      expect(square.take(4).map((p) => (p.step, p.value, p.curve)), [
        (0.0, 0.75, AutomationCurve.step), (2.0, 0.25, AutomationCurve.step),
        (4.0, 0.75, AutomationCurve.step), (6.0, 0.25, AutomationCurve.step),
      ]);
      final saw = shapePoints(LaneShape.saw, 0, 8, 4, 0.5, 0.25);
      expect(laneValueAt(saw, 3.99, 0), closeTo(0.75, 0.01));
      expect(laneValueAt(saw, 4, 0), 0.25, reason: 'it drops back at the cycle');
      final a = shapePoints(LaneShape.random, 0, 16, 4, 0.5, 0.4, seed: 7);
      final b = shapePoints(LaneShape.random, 0, 16, 4, 0.5, 0.4, seed: 7);
      expect(a.map((p) => p.value), b.map((p) => p.value));
      expect(a.every((p) => p.value >= 0.1 && p.value <= 0.9), isTrue);
      expect(shapePoints(LaneShape.random, 0, 16, 4, 0.5, 0.4, seed: 8).map((p) => p.value), isNot(a.map((p) => p.value)));
    });

    test('the eraser removes what it swept; replaceSpan puts drawn points over what was there', () {
      final pts = [_p(0, 0), _p(4, 1), _p(8, 0), _p(12, 1)];
      expect(erasePoints(pts, 3, 9).map((p) => p.step), [0, 12]);
      final next = replaceSpan(pts, [_p(3, 0.5), _p(9, 0.5)]);
      expect(next.map((p) => p.step), [0, 3, 9, 12]);
    });

    test('move, scale and tilt change only the selection; the rest is kept exactly', () {
      final pts = [_p(0, 0.1), _p(4, 0.4), _p(8, 0.8), _p(12, 0.3)];
      final moved = moveSelection(pts, {1, 2}, 1, 0.1);
      expect(moved.points.map((p) => p.step), [0, 5, 9, 12]);
      expect(moved.points[1].value, closeTo(0.5, 1e-12));
      expect(moved.points[0].value, 0.1);
      expect(moved.selected, {1, 2});
      final scaled = scaleSelection(pts, {1, 2}, 0.4, 0.5);
      expect(scaled.points[2].value, closeTo(0.6, 1e-12));
      expect(scaled.points[1].value, closeTo(0.4, 1e-12));
      final tilted = tiltSelection(pts, {1, 2}, 4, 8, 0.2, 0);
      expect(tilted.points[1].value, closeTo(0.6, 1e-12));
      expect(tilted.points[2].value, closeTo(0.8, 1e-12));
      // Moved over another point, that one gives way.
      expect(moveSelection(pts, {0, 1}, 5, 0).points.map((p) => p.step), [5, 9, 12]);
    });

    test('copy and paste: heights and curves, at a step, over what the lane had there', () {
      final pts = [_p(0, 0, AutomationCurve.fast), _p(4, 1), _p(20, 0.5)];
      final c = AutomationClipboard.of(pts, {0, 1})!;
      expect(c.length, 4);
      final r = c.pasteInto(pts, 10, toValue: (f) => f * 2);
      expect(r.points.map((p) => (p.step, p.value)), [(0.0, 0.0), (4.0, 1.0), (10.0, 0.0), (14.0, 2.0), (20.0, 0.5)]);
      expect(r.points[2].curve, AutomationCurve.fast);
      expect(r.selected, {2, 3});
    });
  });

  group('the app', () {
    late AppState s;
    LayerDoc keys() => s.project.layers.first;

    setUp(() {
      s = AppState(settings: Settings());
      s.componentCatalog.set(const [_chorus]);
      s.project = _project();
    });
    tearDown(() => s.dispose());

    test('Automate makes the lane armed and shown with a point at the cursor, remembers it, and reveals it', () {
      s.pausedStep = 6;
      const t = AutomationTarget('component', 'mix', layerId: 'a', component: 0);
      expect(s.automate(t), t.key);
      final lane = s.project.automation.single;
      expect(lane.armed, isTrue);
      expect(keys().showLanes, isTrue);
      expect(lane.points.map((p) => (p.step, p.value)), contains((6.0, 0.25)));
      expect(s.project.recentAutomation.first, t.key);
      expect(s.automationReveal.value, t.key);
      expect(s.undoAutomation(), isTrue);
      expect(s.project.automation, isEmpty, reason: 'one automation undo step');
      // A lane already there is only revealed.
      s.automate(const AutomationTarget('track', 'pan', layerId: 'a'));
      final before = keys().automation.single.points.length;
      s.automationReveal.value = null;
      s.automate(const AutomationTarget('track', 'pan', layerId: 'a'));
      expect(keys().automation.single.points.length, before);
      expect(s.automationReveal.value, automationKey('track', 'pan', layerId: 'a'));
    });

    test('a device knob names its lane; the master\'s and a modulator\'s have none', () {
      final a = ControlAutomation.of(DeviceTarget(s, 'a', 0), 'rate')!;
      expect(a.target.key, automationKey('component', 'rate', layerId: 'a', component: 0));
      expect(ControlAutomation.of(DeviceTarget(s, '__master', 0), 'rate'), isNull);
    });

    test('Automation follows clips: a moved clip takes the points over it along (off: they stay)', () {
      s.addAutomationLane(keys(), 'pan');
      final lane = keys().automation.single;
      lane.points = [_p(0, 0), _p(20, 0.5, AutomationCurve.slow), _p(28, -0.5), _p(44, 0.2)];
      final clip = keys().clips.single;
      s.moveClip(keys(), clip, 20);
      expect(lane.points.map((p) => p.step), [0, 20, 28, 44], reason: 'off by default');
      s.moveClip(keys(), clip, 16);
      s.editProject((p) => p.automationFollowsClips = true);
      s.moveClip(keys(), clip, 24);
      expect(lane.points.map((p) => p.step), [0, 28, 36, 44]);
      expect(lane.points[1].curve, AutomationCurve.slow);
      expect(ProjectDoc.fromJson(s.project.toJson()).automationFollowsClips, isTrue);
    });
  });

  group('lanes on screen', () {
    late AppState s;
    late SectionController sections;
    LayerDoc keys() => s.project.layers.first;
    final pan = automationKey('track', 'pan', layerId: 'a');

    setUp(() {
      s = AppState(settings: Settings());
      s.componentCatalog.set(const [_chorus]);
      s.project = _project();
      sections = SectionController();
    });
    tearDown(() {
      s.dispose();
      sections.dispose();
    });

    Future<void> pumpArranger(WidgetTester tester, {Size size = const Size(1200, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
    }

    /// The pan lane open with [points], and where step [step] at value-height [f] (0 bottom, 1 top) is on screen.
    Future<Offset Function(double step, double f)> panLane(WidgetTester tester, List<AutomationPointDoc> points) async {
      s.addAutomationLane(keys(), 'pan');
      keys().automation.single.points = points;
      s.setLanesShown(keys(), true);
      await pumpArranger(tester);
      await tester.pump(const Duration(milliseconds: 500));
      final row = tester.getRect(find.byKey(ValueKey('lane-row-$pan')));
      final stepW = tester.widget<LaneRow>(find.byKey(ValueKey('lane-row-$pan'))).stepW;
      return (step, f) => Offset(row.left + step * stepW, row.top + 5 + (1 - f) * (row.height - 10));
    }

    List<AutomationPointDoc> pts() => keys().automation.single.points;

    testWidgets('the pencil draws a thinned stroke as one undo step', (tester) async {
      final at = await panLane(tester, [_p(0, 0), _p(64, 0)]);
      laneToolOf(s).value = (tool: LaneTool.pencil, shape: LaneShape.sine);
      await tester.pump();
      final g = await tester.startGesture(at(4, 0.2));
      for (var i = 1; i <= 20; i++) {
        await g.moveTo(at(4 + i * 0.5, i < 10 ? 0.2 : 0.9));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(pts().length, greaterThan(3));
      expect(pts().where((p) => p.step > 3.5 && p.step < 14.5).length, greaterThanOrEqualTo(2));
      expect(pts().any((p) => p.value > 0.5), isTrue);
      expect(s.undoAutomation(), isTrue);
      expect(pts().length, 2, reason: 'the stroke was one automation undo step');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the line, a shape and the eraser', (tester) async {
      final at = await panLane(tester, [_p(0, 0), _p(64, 0)]);
      laneToolOf(s).value = (tool: LaneTool.line, shape: LaneShape.sine);
      await tester.pump();
      await tester.dragFrom(at(4, 0), at(12, 1) - at(4, 0));
      await tester.pump();
      expect(pts().map((p) => (p.step, p.value)), containsAllInOrder([(4.0, -1.0), (12.0, 1.0)]));
      laneToolOf(s).value = (tool: LaneTool.shape, shape: LaneShape.square);
      await tester.pump();
      await tester.dragFrom(at(16, 0.5), at(24, 0.75) - at(16, 0.5));
      await tester.pump();
      final square = [for (final p in pts()) if (p.step >= 16 && p.step < 24) p];
      expect(square, hasLength(16), reason: 'two points a step at the 1/16 grid');
      expect(square.first.curve, AutomationCurve.step);
      laneToolOf(s).value = (tool: LaneTool.eraser, shape: LaneShape.square);
      await tester.pump();
      await tester.dragFrom(at(15.5, 0.5), at(30, 0.5) - at(15.5, 0.5));
      await tester.pump();
      expect(pts().where((p) => p.step >= 16 && p.step < 30), isEmpty);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the tool row: Automate opens the picker, and the narrow tool button lists every tool', (tester) async {
      await panLane(tester, [_p(0, 0)]);
      await tester.tap(find.byKey(const ValueKey('lane-tool-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eraser'));
      await tester.pumpAndSettle();
      expect(laneToolOf(s).value.tool, LaneTool.eraser);
      await tester.tap(find.byKey(const ValueKey('lane-tool-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Random'));
      await tester.pumpAndSettle();
      expect(laneToolOf(s).value, (tool: LaneTool.shape, shape: LaneShape.random));
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the picker: search, add flat at the value now, and Recent at the top', (tester) async {
      s.setLanesShown(keys(), true);
      await pumpArranger(tester);
      await tester.tap(find.byKey(const ValueKey('lane-add-a')));
      await tester.pumpAndSettle();
      expect(find.text('CHORUS · 1'), findsOneWidget, reason: 'grouped by device');
      await tester.enterText(find.byKey(const ValueKey('auto-pick-search')), 'mi');
      await tester.pumpAndSettle();
      expect(find.text('Rate'), findsNothing);
      await tester.tap(find.text('Mix'));
      await tester.pumpAndSettle();
      final lane = s.project.automation.single;
      expect(lane.points.every((p) => p.value == 0.25), isTrue, reason: 'flat at its value now');
      expect(lane.armed, isTrue);
      await tester.tap(find.byKey(const ValueKey('lane-add-a')));
      await tester.pumpAndSettle();
      expect(find.text('RECENT'), findsOneWidget);
      expect(find.byKey(ValueKey('auto-pick-recent-${lane.key}')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a mouse box selects; the box moves, scales and tilts; copy and paste at the playhead', (tester) async {
      final at = await panLane(tester, [_p(0, 0), _p(8, 0), _p(12, 0.5), _p(32, 0), _p(64, 0)]);
      final mouse = await tester.startGesture(at(6, 1) + const Offset(0, 2), kind: PointerDeviceKind.mouse);
      await mouse.moveTo(at(10, 0.5));
      await tester.pump();
      await mouse.moveTo(at(14, 0) + const Offset(0, -2));
      await tester.pump();
      await mouse.up();
      await tester.pump();
      final box = find.byKey(ValueKey('lane-box-$pan'));
      expect(box, findsOneWidget);
      // The body drags both down by the same height.
      await tester.drag(box, const Offset(0, 8));
      await tester.pump();
      expect(pts()[1].value, lessThan(0));
      expect(pts()[2].value - pts()[1].value, closeTo(0.5, 1e-9));
      expect(pts()[0].value, 0, reason: 'the rest stays');
      final before = (pts()[1].value, pts()[2].value);
      // The top edge scales them about the bottom edge.
      await tester.drag(find.byKey(ValueKey('lane-box-scaleTop-top-$pan')), const Offset(0, -10));
      await tester.pump();
      expect(pts()[1].value, closeTo(before.$1, 1e-9), reason: 'the lowest stays');
      expect(pts()[2].value, greaterThan(before.$2));
      // A corner tilts: the left end moves, the right stays.
      final right = pts()[2].value;
      await tester.drag(find.byKey(ValueKey('lane-box-tiltLeft-top-$pan')), const Offset(0, -6));
      await tester.pump();
      expect(pts()[2].value, closeTo(right, 1e-9));
      // Copy, then paste at the edit cursor (step 40).
      await tester.tapAt(at(20, 0.9), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy 2 points'));
      await tester.pumpAndSettle();
      s.pausedStep = 40;
      await tester.tapAt(at(20, 0.9), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste at playhead'));
      await tester.pumpAndSettle();
      expect(pts().map((p) => p.step), containsAllInOrder([40.0, 44.0]));
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a finger\'s long-press drag on empty space draws the box', (tester) async {
      final at = await panLane(tester, [_p(0, 0), _p(8, 0), _p(12, 0.5), _p(64, 0)]);
      final g = await tester.startGesture(at(6, 1));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await g.moveTo(at(14, 0));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(find.byKey(ValueKey('lane-box-$pan')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a segment\'s handle bends sideways, and its menu sets the curve', (tester) async {
      await panLane(tester, [_p(0, -1), _p(32, 1)]);
      final handle = find.byKey(ValueKey('lane-segment-$pan-0'));
      await tester.drag(handle, const Offset(60, 0));
      await tester.pump();
      expect(pts()[0].curve, AutomationCurve.fast);
      expect(pts()[1].value, 1, reason: 'a sideways drag doesn\'t move it');
      expect(s.undoAutomation(), isTrue);
      expect(pts()[0].curve, AutomationCurve.linear, reason: 'the bend was one undo step');
      await tester.pump();
      await tester.tapAt(tester.getCenter(handle), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Step'));
      await tester.pumpAndSettle();
      expect(pts()[0].curve, AutomationCurve.step);
      await tester.tapAt(tester.getCenter(find.byKey(ValueKey('lane-segment-$pan-0'))), buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset curves'));
      await tester.pumpAndSettle();
      expect(pts()[0].curve, AutomationCurve.linear);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a lane\'s height drags from its header\'s bottom edge and is saved', (tester) async {
      await panLane(tester, [_p(0, 0)]);
      await tester.drag(find.byKey(ValueKey('lane-height-$pan')), const Offset(0, 40));
      await tester.pump();
      expect(keys().automation.single.height, kArrangeLaneHeight + 40);
      expect(tester.getSize(find.byKey(ValueKey('lane-row-$pan'))).height, kArrangeLaneHeight + 40);
      expect(AutomationLaneDoc.fromJson(keys().automation.single.toJson()).height, kArrangeLaneHeight + 40);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('hold a knob, Automate: the lane opens under its track and scrolls into view', (tester) async {
      s.setLanesShown(keys(), false);
      tester.view.physicalSize = const Size(600, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: Knob(key: const ValueKey('k'),
          value: 0.25, min: 0, max: 1, label: 'Mix', onChanged: (_) {},
          automation: ControlAutomation.of(DeviceTarget(s, 'a', 0), 'mix'))))));
      await tester.longPress(find.byKey(const ValueKey('k')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automate'));
      await tester.pumpAndSettle();
      final lane = s.project.automation.single;
      expect((lane.target, lane.component, lane.armed), ('mix', 0, true));
      expect(keys().showLanes, isTrue);
      expect(s.automationReveal.value, lane.key);
      // In the arranger, the lane row scrolls itself into view and clears the request.
      await pumpArranger(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(ValueKey('lane-row-${lane.key}')), findsOneWidget);
      expect(s.automationReveal.value, isNull);
      await tester.pump(const Duration(seconds: 2));
    });

    /// The arranger's sideways scroll (the timeline) and its up-and-down one (the tracks).
    ScrollPosition hScroll(WidgetTester tester) => tester.state<ScrollableState>(find.ancestor(
        of: find.byKey(ValueKey('lane-row-$pan')),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right)).first).position;

    /// Zoomed in once and scrolled 90 px along, then where step [step] at height [f] of the pan lane is on screen now.
    Future<Offset Function(double step, double f)> zoomedAndScrolled(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('arrange-zoom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      hScroll(tester).jumpTo(90);
      await tester.pumpAndSettle();
      final row = tester.getRect(find.byKey(ValueKey('lane-row-$pan')));
      final stepW = tester.widget<LaneRow>(find.byKey(ValueKey('lane-row-$pan'))).stepW;
      expect(stepW, greaterThan(18), reason: 'zoomed in');
      return (step, f) => Offset(row.left + step * stepW, row.top + 5 + (1 - f) * (row.height - 10));
    }

    /// A finger's drag as a phone sends it: down, then many small moves (each under the scroll's slop), then up.
    Future<void> fingerDrag(WidgetTester tester, Offset from, Offset to, {int moves = 30}) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 1; i <= moves; i++) {
        await g.moveTo(Offset.lerp(from, to, i / moves)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
    }

    testWidgets('a finger drags a point in time and value, zoomed in and scrolled, without scrolling the view (#241)',
        (tester) async {
      await panLane(tester, [_p(0, 0), _p(12, 0), _p(64, 0)]);
      s.arrangementSnapSteps = 4;
      final at = await zoomedAndScrolled(tester);
      final x0 = hScroll(tester).pixels;
      expect(x0, 90);
      // Right two bars' worth of steps less a bit, and up: snaps to the grid of 4.
      await fingerDrag(tester, at(12, 0.5), at(19.2, 0.9));
      expect(hScroll(tester).pixels, x0, reason: 'the point took the drag, not the timeline');
      expect(pts()[1].step, 20, reason: 'it moved right, onto the arranger\'s snap (4 steps)');
      expect(pts()[1].value, closeTo(0.8, 0.02), reason: 'and up, following the finger');
      expect(s.undoAutomation(), isTrue);
      expect((pts()[1].step, pts()[1].value), (12.0, 0.0), reason: 'the drag was one undo step');
      await tester.pump(kDoubleTapTimeout);
      // Straight down and left, each on its own: the up-and-down scroll doesn't take it either.
      await fingerDrag(tester, at(12, 0.5), at(12, 0.1));
      expect(pts()[1].value, closeTo(-0.8, 0.02));
      expect(pts()[1].step, 12);
      await tester.pump(kDoubleTapTimeout);
      final b = at(12, 0.1);
      await fingerDrag(tester, b, b - Offset(at(4, 0).dx - at(0, 0).dx, 0));
      expect(pts()[1].step, 8);
      expect(pts()[1].value, closeTo(-0.8, 0.02));
      expect(hScroll(tester).pixels, x0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Shift moves a dragged point a fifth as far, off the grid; a tap still selects it (#241)',
        (tester) async {
      await panLane(tester, [_p(0, 0), _p(12, 0), _p(64, 0)]);
      s.arrangementSnapSteps = 4;
      final at = await zoomedAndScrolled(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await fingerDrag(tester, at(12, 0.5), at(17, 0.5));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(pts()[1].step, closeTo(13, 0.05), reason: 'five steps of finger, one of point, unsnapped');
      await tester.pump(kDoubleTapTimeout);
      // A tap (no move) changes nothing and leaves no undo step behind it: one undo still takes back the drag.
      final before = pts()[1].step;
      await tester.tapAt(at(before, 0.5));
      await tester.pump(kDoubleTapTimeout);
      expect(pts()[1].step, before);
      expect(s.undoAutomation(), isTrue);
      expect(pts()[1].step, 12);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a finger\'s drag off any point still scrolls the timeline (#241)', (tester) async {
      await panLane(tester, [_p(0, 0), _p(12, 0), _p(64, 0)]);
      final at = await zoomedAndScrolled(tester);
      final x0 = hScroll(tester).pixels;
      await fingerDrag(tester, at(30, 0.5), at(22, 0.5));
      expect(hScroll(tester).pixels, greaterThan(x0 + 40), reason: 'empty lane: the view scrolls');
      expect(pts().map((p) => (p.step, p.value)), [(0.0, 0.0), (12.0, 0.0), (64.0, 0.0)]);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the focus view\'s Automation tab shows and edits the lanes under the track, both ways (#241)',
        (tester) async {
      final mix = AutomationTarget('component', 'mix', layerId: 'a', component: 0);
      s.addAutomationLane(keys(), 'pan');
      keys().automation.single.points = [_p(0, 0), _p(400, 0), _p(800, 0)];
      s.addLaneFor(keys(), mix);
      s.setLanesShown(keys(), true);
      await pumpArranger(tester);
      sections.focusLayer('a');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('focus-tab-automation')));
      await tester.pumpAndSettle();
      final tab = find.byKey(const ValueKey('automation-tab-a'));
      // Every lane under the track, the device's parameter too, in the same order.
      for (final key in [pan, mix.key]) {
        expect(find.descendant(of: tab, matching: find.byKey(ValueKey('automation-tab-lane-$key'))), findsOneWidget);
        expect(find.byKey(ValueKey('lane-row-$key')), findsOneWidget, reason: 'and under the track');
      }
      expect(find.descendant(of: tab, matching: find.text('CHORUS · MIX')), findsOneWidget);
      // A finger drags the pan lane's middle point up in the tab (the whole song fits its width): the lane under the track has it.
      final row = find.byKey(ValueKey('automation-tab-row-$pan'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      final r = tester.getRect(row);
      final stepW = tester.widget<LaneRow>(row).stepW;
      Offset at(double step, double f) => Offset(r.left + step * stepW, r.top + 5 + (1 - f) * (r.height - 10));
      await fingerDrag(tester, at(400, 0.5), at(400, 0.9));
      expect(pts()[1].value, closeTo(0.8, 0.03));
      expect(identical(s.project.layers.first.automation.single.points, pts()), isTrue);
      final arranged = tester.widget<LaneRow>(find.byKey(ValueKey('lane-row-$pan'))).lane;
      expect(arranged.points[1].value, pts()[1].value, reason: 'the arranger\'s lane draws the same point');
      // An edit under the track (a point added to the device's lane) shows in the tab's sliders.
      final mixLane = s.project.automation.single;
      final before = mixLane.points.length;
      arranged.state.addProjectAutomationPoint(mixLane, 16, 0.9);
      await tester.pumpAndSettle();
      expect(mixLane.points.length, before + 1);
      expect(tester.widget<LaneRow>(find.byKey(ValueKey('automation-tab-row-${mix.key}'))).lane.points.length,
          before + 1);
      // The tab's Automate is the arranger's picker: it adds a lane under the track.
      final add = find.descendant(of: tab, matching: find.byKey(const ValueKey('lane-add-a')));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('CHORUS · 1'), findsOneWidget, reason: 'the #230 picker, grouped by device');
      await tester.tap(find.text('Rate'));
      await tester.pumpAndSettle();
      final rate = AutomationTarget('component', 'rate', layerId: 'a', component: 0).key;
      expect(find.byKey(ValueKey('lane-row-$rate')), findsOneWidget);
      expect(find.descendant(of: tab, matching: find.byKey(ValueKey('automation-tab-lane-$rate'))), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Delete, Ctrl+A and Ctrl+C work on the lane\'s focus', (tester) async {
      final at = await panLane(tester, [_p(0, 0), _p(8, 0.5), _p(64, 0)]);
      await tester.tapAt(at(8, 0.75), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byKey(ValueKey('lane-box-$pan')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(pts(), isEmpty);
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
