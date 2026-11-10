// Clip editing (docs/reaper-flow.md, gap 1): split at the playhead (S), glue, duplicate, delete, several clips moved
// together, the marquee and Select mode, the clip bar and the Properties sheet, each action one undo step.
import 'dart:convert';

import 'package:caw/actions/actions.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_edit.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/key_router.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// A 16-step pattern: a long note from 0 to 8 and a short one at 8.
const _source = '---\nkind: pattern\nname: Riff\nlength: 16\n---\n0 C3 8 1\n8 E3 2 1\n';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Clip edit test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _source),
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
    s.project = project();
  });
  tearDown(() => s.dispose());

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);
  ClipDoc clip(String id) => s.project.layers.expand((l) => l.clips).firstWhere((c) => c.id == id);
  PatternDoc patternOf(ClipDoc c) => PatternDoc.parse(s.project.module(c.patternId)!.runSource).doc!;

  group('split', () {
    test('at the playhead: the right part gets its own pattern without the note crossing the cut (REAPER)', () {
      s.selectClip(layer('a'), clip('c1'));
      s.seekTo(4);
      expect(s.splitClips(), isTrue);
      final left = clip('c1');
      expect(left.lengthSteps, 4);
      expect(left.patternId, 'pat');
      final right = layer('a').clips.firstWhere((c) => c.startSteps == 4);
      expect(right.lengthSteps, 12);
      expect(right.patternId, isNot('pat'), reason: 'REAPER never pools the parts of a split');
      final notes = patternOf(right).notes;
      expect(notes, hasLength(1), reason: 'the C3 started before the cut, so its note-on stays on the left');
      expect(notes.single.pitch, 52);
      expect(notes.single.at, Steps(4));
      expect(patternOf(right).lengthSteps(4), 12);
      expect(s.selectedClipIds, {right.id});
    });

    test('with nothing selected it splits every clip under the playhead; locked clips stay whole', () {
      s.editProject((p) => layer('b').clips.add(ClipDoc(id: 'b1', patternId: 'pat', startSteps: 0, lengthSteps: 16, lock: true)));
      s.clearClipSelection();
      expect(s.splitClips(at: 6), isTrue);
      expect(layer('a').clips, hasLength(3));
      expect(layer('b').clips.single.lengthSteps, 16);
      expect(s.splitClips(at: 20), isFalse, reason: 'nothing under step 20');
    });

    test('a split is one undo step, even straight after another edit', () async {
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      s.editProject((p) => p.bpm = 100);
      s.splitClips(at: 8);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(s.undo(), isTrue);
      expect(layer('a').clips, hasLength(2));
      expect(s.project.bpm, 100);
      expect(s.undo(), isTrue);
      expect(s.project.bpm, 140);
    });
  });

  test('glue joins the selected clips on a track into one, notes in place', () {
    s.selectClip(layer('a'), clip('c1'));
    s.toggleClipSelection(layer('a'), clip('c2'));
    expect(s.glueSelected(), isTrue);
    final glued = layer('a').clips.single;
    expect((glued.startSteps, glued.lengthSteps, glued.loop), (0, 48, false));
    final notes = patternOf(glued).sortedNotes;
    expect([for (final n in notes) (n.at, n.pitch)],
        [(Steps(0), 48.0), (Steps(8), 52.0), (Steps(32), 48.0), (Steps(40), 52.0)]);
    expect(s.selectedClipIds, {glued.id});
  });

  test('glue plays what played: a looping clip repeats, a trimmed one keeps its window, a muted one adds nothing', () {
    s.editProject((p) {
      clip('c1').lengthSteps = 24; // loops: the long note again at 16
      clip('c2').mute = true;
      layer('a').clips.add(ClipDoc(id: 'c3', patternId: 'pat', startSteps: 52, lengthSteps: 4, sourceOffsetSteps: 6));
    });
    s.selectClipsInBox([for (final c in layer('a').clips) (layer: layer('a'), clip: c)]);
    expect(s.glueSelected(), isTrue);
    final notes = patternOf(layer('a').clips.single).sortedNotes;
    // c1: 0 C3 8, 8 E3 2, 16 C3 8; c3 (from 52, source 6..10): the C3's tail 52..54, E3 at 54.
    expect([for (final n in notes) (n.at.toDouble(), n.len.toDouble(), n.pitch)],
        [(0.0, 8.0, 48.0), (8.0, 2.0, 52.0), (16.0, 8.0, 48.0), (52.0, 2.0, 48.0), (54.0, 2.0, 52.0)]);
  });

  test('duplicate copies the selection as a block after it, with its own notes', () {
    s.selectClipsInBox([(layer: layer('a'), clip: clip('c1')), (layer: layer('a'), clip: clip('c2'))]);
    expect(s.duplicateSelected(), isTrue);
    final starts = [for (final c in layer('a').clips) c.startSteps]..sort();
    expect(starts, [0, 32, 48, 80]);
    expect(s.selectedClips.map((c) => c.clip.startSteps).toList()..sort(), [48, 80]);
    expect(s.selectedClips.every((c) => c.clip.patternId != 'pat'), isTrue);
  });

  test('delete removes the selected clips but not locked ones', () {
    s.editProject((_) => clip('c2').lock = true);
    s.selectClipsInBox([(layer: layer('a'), clip: clip('c1')), (layer: layer('a'), clip: clip('c2'))]);
    expect(s.deleteSelected(), isTrue);
    expect(layer('a').clips.single.id, 'c2');
  });

  test('several selected clips move together by time and tracks; copies have their own notes', () {
    s.selectClipsInBox([(layer: layer('a'), clip: clip('c1')), (layer: layer('a'), clip: clip('c2'))]);
    s.moveSelectedClips(layer('a'), clip('c1'), layer('b'), 8);
    expect(layer('a').clips, isEmpty);
    expect([for (final c in layer('b').clips) c.startSteps], [8, 40]);
    // Two tracks further down would leave the tracks: they stay on theirs.
    s.moveSelectedClips(layer('b'), clip('c1'), layer('c'), 8, copy: true);
    expect(layer('b').clips, hasLength(2));
    expect(layer('c').clips, hasLength(2));
    expect(layer('c').clips.every((c) => c.patternId != 'pat'), isTrue);
    s.selectClipsInBox([(layer: layer('b'), clip: clip('c1'))]);
    s.toggleClipSelection(layer('c'), layer('c').clips.first);
    s.moveSelectedClips(layer('b'), clip('c1'), layer('c'), 8);
    expect(layer('b').clips.map((c) => c.id), ['c1', 'c2'], reason: 'the Lead clip would go off the end: none move');
    expect(layer('c').clips, hasLength(2));
  });

  test('properties: name, colour, mute and lock are saved; a muted clip stays arranged but plays nothing', () {
    s.setClipProperties(layer('a'), clip('c1'), name: ' Verse riff ', color: 3, mute: true, lock: true, loop: false);
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(s.project.toJson())) as Map<String, dynamic>);
    final c = back.layers.first.clips.first;
    expect((c.name, c.color, c.mute, c.lock, c.loop), ('Verse riff', 3, true, true, false));
    expect(s.clipName(clip('c1')), 'Verse riff');
    final engine = jsonDecode(s.project.toEngineJson()) as Map<String, dynamic>;
    final clips = ((engine['layers'] as List).first as Map)['clips'] as List;
    expect(clips, hasLength(2));
    expect((clips.first as Map)['mute'], isTrue);
    s.setClipProperties(layer('a'), clip('c1'), color: -1);
    expect(clip('c1').color, isNull);
  });

  test('Shift-click selects the range: clips on the tracks between, overlapping the time between', () {
    s.editProject((p) => layer('c').clips.add(ClipDoc(id: 'l1', patternId: 'pat', startSteps: 16, lengthSteps: 8)));
    s.selectClip(layer('a'), clip('c1'));
    s.selectClipRange(layer('c'), clip('l1'));
    expect(s.selectedClipIds, {'c1', 'l1'});
  });

  group('ui', () {
    Future<void> pump(WidgetTester tester, {Size size = const Size(1400, 900)}) async {
      tester.view.physicalSize = size;
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

    testWidgets('a selected clip shows the clip bar in the wide toolbar; S splits at the playhead', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('clip-bar')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(s.selectedClipIds, {'c1'});
      expect(find.byKey(const ValueKey('clip-bar')), findsOneWidget);
      s.seekTo(4);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(layer('a').clips, hasLength(3));
      expect(clip('c1').lengthSteps, 4);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Ctrl-click adds a clip; G glues; F2 opens Properties, where the name is typed', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey('clip-c2')), kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.selectedClipIds, {'c1', 'c2'});
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();
      final glued = layer('a').clips.single;
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clip-properties')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('clip-prop-name')), 'Hook');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.tap(find.byKey(const ValueKey('clip-prop-mute')));
      await tester.pumpAndSettle();
      expect((glued.name, glued.mute), ('Hook', true));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a right-drag in empty lane space draws a marquee that selects the clips it touches', (tester) async {
      await pump(tester);
      final head = tester.getRect(find.byKey(const ValueKey('track-header-c')));
      final g = await tester.startGesture(Offset(head.right + 900, head.center.dy),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.moveTo(laneOf(tester, 'a', x: 5));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(s.selectedClipIds, {'c1', 'c2'});
    });

    testWidgets('phone: the clip bar docks at the bottom; Select mode taps add clips and the bar deletes them',
        (tester) async {
      // Both on a phone's screen.
      clip('c1').lengthSteps = 4;
      clip('c2')..startSteps = 6..lengthSteps = 4;
      await pump(tester, size: const Size(412, 900));
      await tester.tap(find.byKey(const ValueKey('clip-c1')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byKey(const ValueKey('clip-bar')));
      expect(bar.bottom, greaterThan(800), reason: 'docked near the bottom, in reach of the thumb');
      await tester.tap(find.byKey(const ValueKey('clip-bar-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('clip-c2')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(s.selectedClipIds, {'c1', 'c2'});
      await tester.tap(find.byKey(const ValueKey('clip-bar-delete')));
      await tester.pumpAndSettle();
      expect(layer('a').clips, isEmpty);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
