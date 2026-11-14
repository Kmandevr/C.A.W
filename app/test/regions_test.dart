// Regions with their contents (docs/reaper-flow.md, gap 2): a region moved or copied with the clips that start inside
// it (Alt drag, Ctrl drag or a second finger, Duplicate with clips), the marker and region list, and 1–0 jumps.
import 'package:caw/actions/actions.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_markers.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/key_router.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Regions', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: '---\nkind: pattern\nlength: 16\n---\n0 C3 4 1\n'),
      ModuleDoc(id: 'pat2', name: 'Hits', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'in1', patternId: 'pat', startSteps: 16, lengthSteps: 16),
        ClipDoc(id: 'out', patternId: 'pat', startSteps: 80, lengthSteps: 16),
      ]),
      LayerDoc(id: 'b', name: 'Drums', color: 1, clips: [
        ClipDoc(id: 'in2', patternId: 'pat2', startSteps: 32, lengthSteps: 32),
        ClipDoc(id: 'before', patternId: 'pat2', startSteps: 0, lengthSteps: 16),
      ]),
    ], markers: [
      MarkerDoc(id: 'r', name: 'Verse', startSteps: 16, endSteps: 64),
      MarkerDoc(id: 'm2', name: 'Drop', startSteps: 72),
      MarkerDoc(id: 'm1', name: 'Intro', startSteps: 0),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
  });
  tearDown(() => s.dispose());

  MarkerDoc region() => s.project.markers.firstWhere((m) => m.isRegion);
  ClipDoc clip(String id) => [for (final l in s.project.layers) ...l.clips].firstWhere((c) => c.id == id);

  test('the clips in a region are those that start inside it', () {
    expect(s.clipsInRegion(region()).map((c) => c.clip.id), unorderedEquals(['in1', 'in2']));
  });

  test('a region moved with its clips takes them by the same time', () {
    final moved = s.moveRegionWithClips(region(), 112);
    expect(identical(moved, region()), isTrue);
    expect((region().startSteps, region().endSteps), (112, 160));
    expect(clip('in1').startSteps, 112);
    expect(clip('in2').startSteps, 128);
    expect(clip('out').startSteps, 80);
    expect(clip('before').startSteps, 0);
  });

  test('a locked clip stays when its region moves', () {
    clip('in1').lock = true;
    s.moveRegionWithClips(region(), 112);
    expect(clip('in1').startSteps, 16);
    expect(clip('in2').startSteps, 128);
  });

  test('a copy makes a new region with copies of the clips, each with its own pattern', () {
    final copy = s.moveRegionWithClips(region(), 128, copy: true)!;
    expect(copy.name, 'Verse copy');
    expect((copy.startSteps, copy.endSteps), (128, 176));
    expect((region().startSteps, region().endSteps), (16, 64));
    final keys = s.project.layers.first.clips.where((c) => c.startSteps == 128).single;
    expect(keys.patternId, isNot('pat'));
    expect(s.project.module(keys.patternId)!.source, contains('0 C3 4 1'));
    expect(s.project.layers[1].clips.where((c) => c.startSteps == 144), hasLength(1));
    expect(s.clipsInRegion(copy), hasLength(2));
  });

  test('a move is kept inside the song', () {
    s.moveRegionWithClips(region(), -40);
    expect(region().startSteps, 0);
    expect(clip('in1').startSteps, 0);
  });

  test('1–0 jump to the markers in time order; regions are not numbered', () {
    s.seekTo(50);
    expect(s.jumpToMarkerNumber(2), isTrue);
    expect(s.playheadStep, 72);
    expect(s.jumpToMarkerNumber(1), isTrue);
    expect(s.playheadStep, 0);
    expect(s.jumpToMarkerNumber(3), isFalse);
  });

  group('on screen', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
        child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
    }

    testWidgets('keys 1 and 2 jump to the first and second marker', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(s.playheadStep, 72);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(s.playheadStep, 0);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a section held and moved takes its clips; a mouse drags it straight away', (tester) async {
      await pump(tester);
      final r = find.byKey(const ValueKey('section-r'));
      // A finger: hold, then move (the menu opens on the hold and closes as the move starts).
      final g = await tester.startGesture(tester.getCenter(r));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveBy(const Offset(20, 0));
      await tester.pump();
      await g.moveBy(const Offset(18.0 * 16 - 20, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('section-landing')), findsOneWidget);
      await g.up();
      await tester.pumpAndSettle();
      expect(region().startSteps, 32, reason: 'a bar later, snapped to the bar line');
      expect(clip('in1').startSteps, 32);
      // A mouse drags it back.
      final m = await tester.startGesture(tester.getCenter(r), kind: PointerDeviceKind.mouse);
      await m.moveBy(const Offset(-18.0 * 16, 0));
      await tester.pump();
      await m.up();
      await tester.pumpAndSettle();
      expect(region().startSteps, 16);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the list shows markers with their keys and sections with their clips; a tap jumps', (tester) async {
      await pump(tester);
      await tester.longPressAt(tester.getRect(find.byKey(const ValueKey('arrange-ruler'))).topLeft + const Offset(400, 6));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Markers and sections…'));
      await tester.pumpAndSettle();
      expect(find.text('Intro'), findsWidgets);
      expect(find.textContaining('2 clips'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('marker-row-m2')));
      await tester.pumpAndSettle();
      expect(s.playheadStep, 72);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
