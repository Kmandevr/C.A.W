// The loop range, markers and regions (docs/reaper-flow.md, gap 2): drawn and dragged on the ruler, saved in the
// project, the loop range sent to the engine (off by default, so older projects still loop the whole song).
import 'dart:convert';

import 'package:caw/actions/actions.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_markers.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/key_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Loop test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: '---\nkind: pattern\nlength: 16\n---\n0 C3 4 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', startSteps: 0, lengthSteps: 64)]),
    ]);

Map<String, dynamic> engineJson(AppState s) => jsonDecode(s.project.toEngineJson()) as Map<String, dynamic>;

ProjectDoc roundTrip(ProjectDoc p) => ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
  });
  tearDown(() => s.dispose());

  group('loop range', () {
    test('an older project has none: the engine loops the whole song', () {
      final old = ProjectDoc.fromJson(jsonDecode(jsonEncode(project().toJson())) as Map<String, dynamic>);
      expect(old.loopsRange, isFalse);
      s.project = old;
      expect(engineJson(s).containsKey('loop_range'), isFalse);
    });

    test('a drawn range goes to the engine while on, and is saved either way', () {
      s.setLoopRange(48, 16);
      expect((s.project.loopStartSteps, s.project.loopEndSteps, s.project.loopRange), (16, 48, true));
      var e = engineJson(s);
      expect((e['loop_range'], e['loop_start_steps'], e['loop_end_steps']), (true, 16, 48));
      s.toggleLoopRange();
      expect(engineJson(s).containsKey('loop_range'), isFalse);
      final back = roundTrip(s.project);
      expect((back.loopStartSteps, back.loopEndSteps, back.loopRange), (16, 48, false));
      s.toggleLoopRange();
      e = engineJson(s);
      expect(e['loop_range'], isTrue);
    });

    test('a range past the clips lengthens the song, so the engine gets there', () {
      s.setLoopRange(64, 128);
      expect(s.project.engineLoopSteps, 128);
      expect(engineJson(s)['loop_bars'], 8);
    });

    test('turned on with none drawn: the time selection, else four bars from the playhead', () {
      s.seekTo(20);
      s.toggleLoopRange();
      expect((s.project.loopStartSteps, s.project.loopEndSteps), (16, 80));
      final t = AppState(settings: Settings())..project = project();
      addTearDown(t.dispose);
      t.setTimeSelection(8, 24);
      t.toggleLoopRange();
      expect((t.project.loopStartSteps, t.project.loopEndSteps), (8, 24));
    });
  });

  group('markers and regions', () {
    test('are saved with their names, colours and spans; next and previous jump the playhead', () {
      final m = s.addMarker(32);
      final r = s.addMarker(0, end: 16);
      expect((m.name, m.isRegion, r.name, r.isRegion), ('Marker 1', false, 'Section 1', true));
      s.editMarker(m, name: 'Chorus', color: 6);
      final back = roundTrip(s.project);
      expect([for (final k in back.markers) (k.name, k.startSteps, k.endSteps, k.color)],
          [('Section 1', 0, 16, r.color), ('Chorus', 32, null, 6)], reason: 'sections, then markers');
      expect(engineJson(s).containsKey('markers'), isFalse, reason: 'the engine never sees them');
      s.seekTo(4);
      expect(s.jumpToMarker(next: true), isTrue);
      expect(s.playheadStep, 32);
      expect(s.jumpToMarker(next: true), isFalse);
      expect(s.jumpToMarker(next: false), isTrue);
      expect(s.playheadStep, 0);
    });

    test('a region moves with its length; delete removes it', () {
      final r = s.addMarker(0, end: 16);
      s.moveMarker(r, 40);
      expect((r.startSteps, r.endSteps), (40, 56));
      s.removeMarker(r);
      expect(s.project.markers, isEmpty);
    });

    test('adding a marker is one undo step', () async {
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      s.addMarker(8);
      s.setLoopRange(0, 16);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(s.undo(), isTrue);
      expect(s.project.markers, hasLength(1));
      expect(s.project.hasLoopRange, isFalse);
      expect(s.undo(), isTrue);
      expect(s.project.markers, isEmpty);
    });
  });

  group('ruler', () {
    Future<void> pump(WidgetTester tester, {Size size = const Size(1400, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
        child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
    }

    /// The ruler's point at [step] (zoom 18 px a step), in its top half or its bottom half.
    Offset at(WidgetTester tester, int step, {bool bottom = false}) {
      final r = tester.getRect(find.byKey(const ValueKey('arrange-ruler')));
      return Offset(r.left + step * 18 + 1, bottom ? r.bottom - 6 : r.top + 6);
    }

    testWidgets('a drag along the ruler sets the loop range; its handle moves an end; R toggles it', (tester) async {
      await pump(tester);
      await tester.dragFrom(at(tester, 4), Offset(12 * 18.0, 0));
      await tester.pumpAndSettle();
      expect((s.project.loopStartSteps, s.project.loopEndSteps, s.project.loopRange), (4, 16, true));
      expect(find.byKey(const ValueKey('ruler-loop')), findsOneWidget);
      await tester.dragFrom(at(tester, 16), const Offset(8 * 18.0, 0));
      await tester.pumpAndSettle();
      expect((s.project.loopStartSteps, s.project.loopEndSteps), (4, 24));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pumpAndSettle();
      expect(s.project.loopRange, isFalse);
      await tester.tap(find.byKey(const ValueKey('arrange-loop')));
      await tester.pumpAndSettle();
      expect(s.project.loopRange, isTrue);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a hold on the ruler adds a marker to the section bar; a tap on it jumps; hold and move moves it',
        (tester) async {
      await pump(tester);
      await tester.longPressAt(at(tester, 16, bottom: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add marker'));
      await tester.pumpAndSettle();
      final m = s.project.markers.single;
      expect(m.startSteps, 16);
      s.seekTo(0);
      final flag = find.byKey(ValueKey('marker-${m.id}'));
      await tester.tap(flag);
      await tester.pumpAndSettle();
      expect(s.playheadStep, 16);
      final g = await tester.startGesture(tester.getTopLeft(flag) + const Offset(4, 4));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveBy(const Offset(8 * 18.0, 0));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(m.startSteps, 24);
      await tester.longPressAt(at(tester, 40, bottom: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add section'));
      await tester.pumpAndSettle();
      final r = s.project.markers.firstWhere((k) => k.isRegion);
      expect((r.startSteps, r.endSteps), (32, 96), reason: 'four bars from the bar pressed');
      expect(find.byKey(ValueKey('section-${r.id}')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('on a phone the section bar and the ruler are taller, for a finger', (tester) async {
      await pump(tester, size: const Size(412, 900));
      expect(tester.getSize(find.byKey(const ValueKey('arrange-ruler'))).height, greaterThanOrEqualTo(24));
      expect(tester.getSize(find.byKey(const ValueKey('arrange-sections'))).height, greaterThanOrEqualTo(24));
    });
  });
}
