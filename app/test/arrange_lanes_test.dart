// Arrange, REAPER-style (#174): MIDI notes drawn inside clips from cached pictures, folders nested to any depth, and
// each track's automation lanes under it behind an arrow.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/clip_preview.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/ui/arrange/track_color.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 1 bar\n---\n0 C4 4 1\n4 E4 4 1 bend 0:0 1:2\n8 G4 8 1\n';

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Lanes test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _source),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'c1', patternId: 'pat', startSteps: 0, lengthSteps: 32),
        ClipDoc(id: 'c2', patternId: 'pat', startSteps: 32, lengthSteps: 16, sourceOffsetSteps: 4),
      ]),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
    ]);

void main() {
  late AppState s;
  late SectionController sections;

  setUp(() {
    ClipPictureCache.instance.clear();
    s = AppState(settings: Settings());
    s.project = _project();
    sections = SectionController();
  });

  tearDown(() {
    s.dispose();
    sections.dispose();
  });

  Future<void> pumpArranger(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
        child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
    await tester.pump();
  }

  group('MIDI notes in clips', () {
    test('the test pattern parses, bend included', () {
      final doc = PatternDoc.parse(_source).doc!;
      expect(doc.notes, hasLength(3));
      expect(doc.notes[1].expr.bend, isNotEmpty);
    });

    test('a picture is recorded once per pattern and zoom, and again only on an edit or a zoom', () {
      final cache = ClipPictureCache();
      MidiClipPreview preview(String source, double stepW) => MidiClipPreview(patternId: 'pat', source: source,
          runSource: source, beatsPerBar: 4, sourceOffsetSteps: 0, loop: true, stepW: stepW, top: 0,
          color: Colors.white, cache: cache);
      void paint(MidiClipPreview p) {
        final recorder = ui.PictureRecorder();
        p.paint(Canvas(recorder), const Size(400, 40));
        recorder.endRecording().dispose();
      }

      paint(preview(_source, 10));
      paint(preview(_source, 10));
      expect(cache.recorded, 1, reason: 'the second paint reuses the picture');
      paint(preview(_source, 12));
      expect(cache.recorded, 2, reason: 'a zoom records one');
      paint(preview(_source.replaceFirst('8 G4 8 1', '8 A4 8 1'), 12));
      expect(cache.recorded, 3, reason: 'an edit records one');
      paint(preview(_source, 1));
      expect(preview(_source, 1).density(40), isTrue, reason: 'zoomed out shows the density view');
      expect(cache.length, 3, reason: 'the edit replaced its zoom''s picture');
    });

    test('the waveform painter draws peaks', () {
      final peaks = Float32List.fromList([for (var i = 0; i < 64; i++) ...[-0.5, 0.5]]);
      final recorder = ui.PictureRecorder();
      WaveformClipPreview(peaks: peaks, stepsPerBucket: 0.5, stepW: 8, color: Colors.white)
          .paint(Canvas(recorder), const Size(200, 40));
      recorder.endRecording().dispose();
    });

    testWidgets('each clip draws its notes, and a rebuild reuses the cached picture', (tester) async {
      await pumpArranger(tester, const Size(412, 900));
      expect(find.byKey(const ValueKey('clip-preview-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('clip-preview-c2')), findsOneWidget);
      // Both clips share the pattern: one picture.
      final recorded = ClipPictureCache.instance.recorded;
      expect(recorded, 1);
      s.selectClip(s.project.layers.first, s.project.layers.first.clips.first);
      await tester.pump();
      expect(ClipPictureCache.instance.recorded, recorded, reason: 'a selection does not redraw the notes');
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('folders nest to any depth', () {
    // outer > mid > inner > Keys; Bass at the top level.
    void nest() {
      s.addFolder();
      final outer = s.project.layers.last..name = 'Outer';
      s.addFolder(parentId: outer.id);
      final mid = s.project.layers.last..name = 'Mid';
      s.addFolder(parentId: mid.id);
      final inner = s.project.layers.firstWhere((l) => l.parentId == mid.id)..name = 'Inner';
      expect(s.moveTrack(s.project.layers.firstWhere((l) => l.id == 'a'), inner, TrackDrop.into), isTrue);
    }

    LayerDoc named(String n) => s.project.layers.firstWhere((l) => l.name == n);

    test('three levels: order, depth, a cycle refused, collapse hides the whole subtree', () {
      nest();
      expect(s.project.layers.map((l) => l.name), ['Bass', 'Outer', 'Mid', 'Inner', 'Keys']);
      expect([for (final l in s.project.layers) s.folderDepth(l)], [0, 0, 1, 2, 3]);
      expect(s.isInside(named('Keys'), named('Outer').id), isTrue);
      // A folder can't go inside itself or its own folders.
      expect(s.moveTrack(named('Outer'), named('Inner'), TrackDrop.into), isFalse);
      // The engine gets every parent as it is.
      final engine = (jsonDecode(s.project.toEngineJson()) as Map<String, dynamic>)['layers'] as List;
      expect([for (final l in engine) (l as Map)['parent']],
          [null, null, named('Outer').id, named('Mid').id, named('Inner').id]);
      // Colours shade down the tree from the top folder.
      expect(trackColor(s, named('Keys')), isNot(trackColor(s, named('Outer'))));
      s.setFolderCollapsed(named('Mid'), true);
      expect(s.visibleLayers.map((l) => l.name), ['Bass', 'Outer', 'Mid']);
      s.setFolderCollapsed(named('Mid'), false);
      s.setFolderCollapsed(named('Outer'), true);
      expect(s.visibleLayers.map((l) => l.name), ['Bass', 'Outer']);
      s.setFolderCollapsed(named('Outer'), false);
      expect(s.visibleLayers, hasLength(5));
    });

    test('out of a folder one level at a time; dropped beside a track it joins that track\'s folder', () {
      nest();
      expect(s.moveTrack(named('Keys'), named('Inner'), TrackDrop.below), isTrue);
      expect(named('Keys').parentId, named('Mid').id);
      expect(s.moveTrack(named('Bass'), named('Keys'), TrackDrop.above), isTrue);
      expect(named('Bass').parentId, named('Mid').id);
      expect(s.folderDepth(named('Bass')), 2);
    });

    testWidgets('headers indent per level with a guide per folder; collapse and expand from the arrow', (tester) async {
      nest();
      await pumpArranger(tester, const Size(412, 900));
      double nameX(String n) => tester.getTopLeft(find.text(n)).dx;
      expect(nameX('Mid'), greaterThan(nameX('Outer')));
      expect(nameX('Inner'), greaterThan(nameX('Mid')));
      expect(find.byKey(const ValueKey('folder-guide-a-2')), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(ValueKey('track-header-${named('Mid').id}')),
          matching: find.byIcon(Icons.expand_more)));
      await tester.pump();
      expect(find.text('Inner'), findsNothing);
      expect(find.text('Keys'), findsNothing);
      await tester.tap(find.descendant(of: find.byKey(ValueKey('track-header-${named('Mid').id}')),
          matching: find.byIcon(Icons.chevron_right)));
      await tester.pump();
      expect(find.text('Inner'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a header dragged into the middle of a folder three levels down goes inside it', (tester) async {
      nest();
      await pumpArranger(tester, const Size(1200, 900));
      final from = tester.getCenter(find.byKey(const ValueKey('track-header-b')));
      final to = tester.getCenter(find.byKey(ValueKey('track-header-${named('Inner').id}')));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 6)!);
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('track-drop-into')), findsOneWidget);
      await g.up();
      await tester.pumpAndSettle();
      expect(named('Bass').parentId, named('Inner').id);
      expect(s.folderDepth(named('Bass')), 3);
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
