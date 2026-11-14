// Arrange's tempo lane, signature flags and section bar (#207, owner 2026-11-13): the lane shows only with a tempo
// change, its points drag, ramp and delete; flags show each signature change and the ruler's bars follow them; a
// section's tap jumps, double tap loops, hold opens its menu (rename, colour, copy, delete), each one undo step.
import 'dart:convert';

import 'package:caw/actions/actions.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_markers.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/tempo_map.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/key_router.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Tempo', bpm: 120, modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: '---\nkind: pattern\nlength: 16\n---\n0 C3 4 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'v1', patternId: 'pat', startSteps: 0, lengthSteps: 16),
        ClipDoc(id: 'c1', patternId: 'pat', startSteps: 64, lengthSteps: 16),
      ]),
    ], markers: [
      MarkerDoc(id: 'verse', name: 'Verse', startSteps: 0, endSteps: 64, color: 2),
      MarkerDoc(id: 'chorus', name: 'Chorus', startSteps: 64, endSteps: 128, color: 4),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() => s.dispose());

  Future<void> pump(WidgetTester tester, {Size size = const Size(1400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
      child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
    await tester.pump();
  }

  /// A point on the ruler at [step] (18 px a step), in its bottom half.
  Offset ruler(WidgetTester tester, int step) {
    final r = tester.getRect(find.byKey(const ValueKey('arrange-ruler')));
    return Offset(r.left + step * 18 + 2, r.bottom - 4);
  }

  group('tempo lane', () {
    testWidgets('hidden until a tempo change; added from the ruler, it grows in, and goes with the last change',
        (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('arrange-tempo')), findsNothing);
      await tester.longPressAt(ruler(tester, 32));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add tempo change'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = tester.getSize(find.byKey(const ValueKey('arrange-tempo'))).height;
      await tester.pumpAndSettle();
      expect(s.project.tempoMap, const [TempoPoint(0, 120), TempoPoint(8, 120)]);
      final lane = tester.getRect(find.byKey(const ValueKey('arrange-tempo')));
      expect(lane.height, 32);
      expect(lane.top, tester.getRect(find.byKey(const ValueKey('arrange-ruler'))).bottom,
          reason: 'right under the ruler');
      expect(mid, 32, reason: 'laid out whole while it grows; the clip shows it growing');
      expect(find.byKey(const ValueKey('tempo-lane-header')), findsOneWidget);
      // Its point's hold menu deletes it; the lane goes.
      await tester.longPress(find.byKey(const ValueKey('tempo-point-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(s.project.tempoMap, hasLength(1));
      expect(find.byKey(const ValueKey('arrange-tempo')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a point drags up and down (one undo step), ramps from its menu, and a double tap deletes it',
        (tester) async {
      s.project.tempoMap = const [TempoPoint(0, 120), TempoPoint(8, 100)];
      s.history.reset(jsonEncode(s.project.toJson()));
      await pump(tester);
      final point = find.byKey(const ValueKey('tempo-point-1'));
      final before = tester.getCenter(point);
      // Up a third of the lane: the scale is 96–124 (the range with room), 32 px with 6 px pads.
      await tester.dragFrom(before, const Offset(0, -30));
      await tester.pumpAndSettle();
      final moved = s.project.tempoMap[1];
      expect(moved.beat, 8, reason: 'an up-and-down drag keeps its beat');
      expect(moved.bpm, greaterThan(100));
      expect(moved.bpm, moved.bpm.roundToDouble(), reason: 'whole BPM without Shift');
      s.endUndoStep();
      expect(s.undo(), isTrue);
      expect(s.project.tempoMap[1].bpm, 100, reason: 'the whole drag is one undo step');
      await tester.pumpAndSettle();
      await tester.longPress(point);
      await tester.pumpAndSettle();
      expect(find.text('Stepped'), findsOneWidget);
      await tester.tap(find.text('Ramped'));
      await tester.pumpAndSettle();
      expect(s.project.tempoMap[1].ramp, isTrue);
      await tester.tap(point);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(point);
      await tester.pumpAndSettle();
      expect(s.project.tempoMap, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a tap on the lane adds a point there', (tester) async {
      s.project.tempoMap = const [TempoPoint(0, 120), TempoPoint(8, 100)];
      await pump(tester);
      final lane = tester.getRect(find.byKey(const ValueKey('arrange-tempo')));
      await tester.tapAt(Offset(lane.left + 64 * 18, lane.center.dy));
      await tester.pumpAndSettle();
      expect(s.project.tempoMap.map((t) => t.beat), [0, 8, 16]);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the transport\'s readout follows the map', (tester) async {
      s.project.tempoMap = const [TempoPoint(0, 120), TempoPoint(8, 90)];
      s.project.timeSignatures = const [TimeSignature(0, 0, 4, 4), TimeSignature(2, 0, 3, 4)];
      s.seekTo(40);  // beat 10: bar 3 (in 3/4 from beat 8), its second beat
      expect(s.project.tempo.bpmAt(s.playheadStep / 4), 90);
      expect(s.project.bars.label(s.playheadStep / 4), '3.3');
    });
  });

  group('time signatures', () {
    testWidgets('a change from the ruler adds a flag, and the bar numbers follow it', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('sig-flag-0')), findsNothing, reason: 'plain 4/4 shows no flag');
      await tester.longPressAt(ruler(tester, 32));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Time signature…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sig-num')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sig-ok')));
      await tester.pumpAndSettle();
      expect(s.project.timeSignatures, const [TimeSignature(0, 0, 4, 4), TimeSignature(2, 8, 3, 4)]);
      expect(find.byKey(const ValueKey('sig-flag-2')), findsOneWidget);
      expect(find.text('3/4'), findsOneWidget);
      // The flag's hold menu removes it.
      await tester.longPress(find.byKey(const ValueKey('sig-flag-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(s.project.timeSignatures, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('section bar', () {
    /// Near the left end of section [id]'s block (a long one runs off the view).
    Offset sec(WidgetTester tester, String id) => tester.getTopLeft(find.byKey(ValueKey('section-$id'))) + const Offset(20, 8);

    testWidgets('a tap jumps to a section; a double tap loops it', (tester) async {
      await pump(tester);
      s.seekTo(10);
      await tester.tapAt(sec(tester, 'chorus'));
      await tester.pump();
      expect(s.playheadStep, 64);
      expect(s.project.loopRange, isFalse);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(sec(tester, 'chorus'));
      await tester.pumpAndSettle();
      expect((s.project.loopStartSteps, s.project.loopEndSteps, s.project.loopRange), (64, 128, true));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the hold menu renames, colours, copies and deletes, each one undo step', (tester) async {
      s.project.tempoMap = const [TempoPoint(0, 120), TempoPoint(16, 90)];
      await pump(tester);
      Future<void> menu(String id, String action) async {
        await tester.longPressAt(sec(tester, id));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }
      await menu('chorus', 'Rename');
      await tester.enterText(find.byKey(const ValueKey('marker-name')), 'Hook');
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      expect(find.text('Hook'), findsOneWidget);
      await menu('chorus', 'Colour');
      expect(s.project.markers.firstWhere((m) => m.id == 'chorus').color, 5);
      await menu('chorus', 'Copy');
      final copy = s.project.sections.last;
      expect((copy.name, copy.startSteps, copy.endSteps), ('Hook copy', 128, 192));
      expect(s.project.layers.first.clips.where((c) => c.startSteps == 128), hasLength(1));
      expect(s.project.tempo.bpmAt(32), 90, reason: 'the copy plays at the tempo of what it copied');
      await menu('chorus', 'Delete');
      expect(s.project.markers.any((m) => m.id == 'chorus'), isFalse);
      expect(s.project.layers.first.clips.map((c) => c.id), isNot(contains('c1')),
          reason: 'its clips go with it');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('section-chorus')), findsNothing, reason: 'it faded out');
      expect(s.undo(), isTrue);
      await tester.pumpAndSettle();
      expect(s.project.layers.first.clips.map((c) => c.id), contains('c1'));
      expect(find.byKey(const ValueKey('section-chorus')), findsOneWidget);
      expect(s.undo(), isTrue);
      expect(s.project.sections, hasLength(2), reason: 'the copy was one step');
      await tester.pumpAndSettle(const Duration(seconds: 1));
    });

    testWidgets('a hold on an empty part of the bar adds a section in the room there', (tester) async {
      s.project.markers.removeWhere((m) => m.id == 'verse');
      await pump(tester);
      final bar = tester.getRect(find.byKey(const ValueKey('arrange-sections')));
      await tester.longPressAt(Offset(bar.left + 20 * 18, bar.center.dy));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add section'));
      await tester.pumpAndSettle();
      final made = s.project.sections.first;
      expect((made.name, made.startSteps, made.endSteps), ('Section 2', 16, 64),
          reason: 'four bars from the bar held, cut where the chorus starts');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('with motion off a deleted section goes at once', (tester) async {
      s.settings.motion = MotionLevel.off;
      Motion.setting = MotionLevel.off;
      addTearDown(() => Motion.setting = MotionLevel.full);
      await pump(tester);
      s.deleteSection(s.project.sections.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(find.byKey(const ValueKey('section-verse')), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 1));
    });
  });
}
