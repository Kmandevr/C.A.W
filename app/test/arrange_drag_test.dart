// The REAPER-style arranger (#172): clips moved and copied between tracks, drops below the last track making a new
// track, instruments added like effects, track headers dragged, clip edges trimmed and empty clips drawn.
import 'dart:convert';

import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const synth = NativeComponentInfo(id: 'org.caw.synth.basic', name: 'Basic synth', role: 'instrument', builtin: true,
    ports: [
      ComponentPortInfo(id: 'notes', type: 'event', input: true, layout: 'none', channels: 0),
      ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
    ],
    parameters: [ComponentParameterInfo(id: 'cutoff', name: 'Cutoff', defaultValue: 2400, min: 20, max: 20000)]);
const saw = NativeComponentInfo(id: 'org.caw.synth.saw', name: 'Saw', role: 'instrument', builtin: true, ports: [
  ComponentPortInfo(id: 'notes', type: 'event', input: true, layout: 'none', channels: 0),
  ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
]);
const width = NativeComponentInfo(id: 'org.caw.stereo.width', name: 'Width', role: 'effect', builtin: true,
    parameters: [ComponentParameterInfo(id: 'width', name: 'Width', defaultValue: 1, min: 0, max: 2)]);

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Drag test', modules: [
      ModuleDoc(id: 'pat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 16)]),
      LayerDoc(id: 'f', name: 'Group', color: 1, isFolder: true),
      LayerDoc(id: 'b', name: 'Bass', color: 2, parentId: 'f'),
      LayerDoc(id: 'c', name: 'Lead', color: 3),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.componentCatalog.set(const [synth, saw, width]);
    s.nativeCatalog = const [synth, saw, width];
  });
  tearDown(() => s.dispose());

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);

  group('clips between tracks', () {
    test('a move keeps the clip and its pattern, at the new time', () {
      final clip = layer('a').clips.single;
      s.moveClipTo(layer('a'), clip, layer('c'), 32);
      expect(layer('a').clips, isEmpty);
      expect(layer('c').clips.single, same(clip));
      expect(clip.startSteps, 32);
      expect(clip.patternId, 'pat');
      expect(s.selectedLayerId, 'c');
    });

    test('a copy (REAPER Ctrl-drag) leaves the original and gets its own notes', () {
      final clip = layer('a').clips.single;
      final copy = s.moveClipTo(layer('a'), clip, layer('c'), 0, copy: true)!;
      expect(layer('a').clips.single, same(clip));
      expect(layer('c').clips.single, same(copy));
      expect(copy.patternId, isNot('pat'));
      expect(s.project.module(copy.patternId)!.source, s.project.module('pat')!.source);
    });

    test('dropped on a folder it goes on the first track inside; on an empty folder, on a new track inside', () {
      s.moveClipTo(layer('a'), layer('a').clips.single, layer('f'), 0);
      expect(layer('b').clips, hasLength(1));
      s.editProject((p) => p.layers.add(LayerDoc(id: 'g', name: 'Empty', color: 0, isFolder: true)));
      s.moveClipTo(layer('b'), layer('b').clips.single, layer('g'), 0);
      final made = s.project.layers.last;
      expect(made.parentId, 'g');
      expect(made.clips, hasLength(1));
    });

    test('below the last track: a new track named after the pattern', () {
      s.moveClipTo(layer('a'), layer('a').clips.single, null, 8);
      final made = s.project.layers.last;
      expect(made.name, 'Beat');
      expect(made.parentId, isNull);
      expect(made.clips.single.startSteps, 8);
    });

    test('a move is one undo step, new track and all', () async {
      s.starting = false; // as after a project opens
      s.history.reset(jsonEncode(s.project.toJson()));
      s.moveClipTo(layer('a'), layer('a').clips.single, null, 8);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(s.undo(), isTrue);
      expect(s.project.layers, hasLength(4));
      expect(s.project.layers.first.clips, hasLength(1));
      expect(s.canUndo, isFalse);
    });
  });

  group('drops below the last track', () {
    test('each kind makes a new track with it', () {
      s.project.midiFiles.add(MidiFileDoc(id: 'mf', name: 'Song.mid', parts: ['pat']));
      final pattern = s.dropOnNewTrack(const AssetDrag(AssetKind.pattern, 'pat', 'Beat'), atStep: 4)!;
      expect(pattern.clips.single.patternId, 'pat');
      final midi = s.dropOnNewTrack(const AssetDrag(AssetKind.midiFile, 'mf', 'Song.mid'), atStep: 0)!;
      expect(midi.clips.single.patternId, 'pat');
      final inst = s.dropOnNewTrack(const AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.basic', 'Basic synth',
          instrument: true))!;
      expect(inst.instrument?.id, 'org.caw.synth.basic');
      expect(inst.name, 'Basic synth');
      final fx = s.dropOnNewTrack(const AssetDrag(AssetKind.nativeEffect, 'org.caw.stereo.width', 'Width'))!;
      expect(fx.components.single.id, 'org.caw.stereo.width');
      expect(fx.instrument, isNull);
      expect(s.project.layers, hasLength(8));
    });

    test('something that cannot go on a track leaves no track', () {
      expect(s.dropOnNewTrack(const AssetDrag(AssetKind.pattern, 'missing', 'Gone')), isNull);
      expect(s.project.layers, hasLength(4));
    });
  });

  group('instruments like effects', () {
    test('an instrument replaces the old one; the UI is told to ask first', () {
      final a = layer('a');
      const drag = AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.basic', 'Basic synth', instrument: true);
      expect(s.replacesInstrument(a, drag), isFalse, reason: 'nothing plays it yet');
      s.dropAsset(a, drag);
      expect(s.instrumentName(a), 'Basic synth');
      expect(s.replacesInstrument(a, drag), isFalse, reason: 'the same instrument');
      const other = AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.saw', 'Saw', instrument: true);
      expect(s.replacesInstrument(a, other), isTrue);
      s.dropAsset(a, other);
      expect(a.instrument?.id, 'org.caw.synth.saw');
      expect(s.replacesInstrument(a, const AssetDrag(AssetKind.nativeEffect, 'org.caw.stereo.width', 'Width')), isFalse,
          reason: 'an effect joins the chain');
    });
  });

  group('tracks dragged', () {
    test('above, below and into a folder, with what is inside', () {
      expect(s.moveTrack(layer('c'), layer('a'), TrackDrop.above), isTrue);
      expect(s.project.layers.map((l) => l.id), ['c', 'a', 'f', 'b']);
      expect(s.moveTrack(layer('c'), layer('f'), TrackDrop.into), isTrue);
      expect(layer('c').parentId, 'f');
      expect(s.moveTrack(layer('f'), null, TrackDrop.below), isTrue);
      expect(s.project.layers.map((l) => l.id), ['a', 'f', 'b', 'c']);
      expect(s.moveTrack(layer('a'), layer('f'), TrackDrop.below), isTrue);
      expect(s.project.layers.map((l) => l.id), ['f', 'b', 'c', 'a']);
      expect(layer('a').parentId, isNull);
      expect(s.moveTrack(layer('f'), layer('b'), TrackDrop.above), isFalse, reason: 'not into itself');
      expect(s.moveTrack(layer('b'), layer('a'), TrackDrop.below), isTrue);
      expect(layer('b').parentId, isNull, reason: 'out of the folder');
    });
  });

  group('edit in place', () {
    test('the left edge trims and keeps the notes where they were', () {
      final a = layer('a');
      final clip = a.clips.single;
      s.trimClipStart(a, clip, 20);
      expect((clip.startSteps, clip.lengthSteps, clip.sourceOffsetSteps), (20, 12, 4));
      s.trimClipStart(a, clip, 0);
      expect((clip.startSteps, clip.lengthSteps, clip.sourceOffsetSteps), (16, 16, 0),
          reason: 'not before the source starts');
    });

    test('an empty clip gets its own blank pattern', () {
      final clip = s.addEmptyClip(layer('c'), 8, 32)!;
      final m = s.project.module(clip.patternId)!;
      expect(m.name, 'Pattern 1');
      expect(s.isPattern(m.id), isTrue);
      expect((clip.startSteps, clip.lengthSteps), (8, 32));
    });
  });

  group('ui', () {
    Future<void> pump(WidgetTester tester, {Size size = const Size(1400, 900), List<AssetDrag> drags = const []}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
        Wrap(children: [
          for (final d in drags) Draggable<AssetDrag>(data: d, feedback: const SizedBox(width: 10, height: 10),
            child: Padding(padding: const EdgeInsets.all(4), child: Text('drag ${d.name}'))),
        ]),
        Expanded(child: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))),
      ]))));
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1)); // saves and history settle
    }

    Offset laneOf(WidgetTester tester, String id, {double x = 300}) {
      final head = tester.getRect(find.byKey(ValueKey('track-header-$id')));
      return Offset(head.right + x, head.center.dy);
    }

    /// Below the last track, in the New track zone.
    Offset belowTracks(WidgetTester tester, {double x = 300}) {
      final head = tester.getRect(find.byKey(const ValueKey('track-header-c')));
      return Offset(head.right + x, head.bottom + 40);
    }

    Future<TestGesture> dragClip(WidgetTester tester, Offset to, {PointerDeviceKind kind = PointerDeviceKind.touch}) async {
      final from = tester.getCenter(find.byKey(const ValueKey('clip-c1')));
      final g = await tester.startGesture(from, kind: kind);
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(Offset.lerp(from, Offset(from.dx, to.dy), i / 8)!);
        await tester.pump();
      }
      return g;
    }

    testWidgets('a clip dragged down moves to the track under the finger, keeping its time, with a ghost', (tester) async {
      await pump(tester);
      final g = await dragClip(tester, laneOf(tester, 'c'));
      expect(find.byKey(const ValueKey('clip-drag-ghost')), findsOneWidget);
      expect(find.byKey(const ValueKey('lane-target-c')), findsOneWidget);
      expect(find.byKey(const ValueKey('clip-drag-copy')), findsNothing);
      await g.up();
      await settle(tester);
      expect(layer('a').clips, isEmpty);
      expect(layer('c').clips.single.id, 'c1');
      expect(layer('c').clips.single.startSteps, 16);
      expect(find.byKey(const ValueKey('clip-drag-ghost')), findsNothing);
    });

    testWidgets('Ctrl-drag copies (REAPER); Escape cancels a drag', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      var g = await dragClip(tester, laneOf(tester, 'c'), kind: PointerDeviceKind.mouse);
      expect(find.byKey(const ValueKey('clip-drag-copy')), findsOneWidget);
      await g.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(layer('a').clips.single.id, 'c1');
      expect(layer('c').clips, hasLength(1));
      expect(layer('c').clips.single.patternId, isNot('pat'));

      g = await dragClip(tester, laneOf(tester, 'b'), kind: PointerDeviceKind.mouse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('clip-drag-ghost')), findsNothing);
      await g.up();
      await settle(tester);
      expect(layer('a').clips.single.id, 'c1');
      expect(layer('b').clips, isEmpty);
    });

    testWidgets('on a phone a second finger during the drag makes it a copy', (tester) async {
      layer('a').clips.single.startSteps = 0; // on screen at phone width
      await pump(tester, size: const Size(412, 900));
      final g = await dragClip(tester, laneOf(tester, 'c', x: 100));
      final second = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('track-header-b'))));
      await tester.pump();
      expect(find.byKey(const ValueKey('clip-drag-copy')), findsOneWidget);
      await second.up();
      await g.up();
      await settle(tester);
      expect(layer('a').clips, hasLength(1));
      expect(layer('c').clips, hasLength(1));
    });

    testWidgets('a clip dragged onto a folder goes on its first track inside', (tester) async {
      await pump(tester);
      final g = await dragClip(tester, laneOf(tester, 'f'));
      expect(find.byKey(const ValueKey('lane-target-f')), findsOneWidget);
      await g.up();
      await settle(tester);
      expect(layer('b').clips.single.id, 'c1');
    });

    testWidgets('a clip dragged below the last track shows New track and goes on a new track', (tester) async {
      await pump(tester);
      final g = await dragClip(tester, belowTracks(tester));
      expect(find.text('New track'), findsOneWidget);
      await g.up();
      await settle(tester);
      expect(s.project.layers, hasLength(5));
      expect(s.project.layers.last.clips.single.id, 'c1');
      expect(s.project.layers.last.name, 'Beat');
    });

    const kinds = [
      AssetDrag(AssetKind.pattern, 'pat', 'Beat'),
      AssetDrag(AssetKind.midiFile, 'mf', 'Song.mid'),
      AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.basic', 'Basic synth', instrument: true),
      AssetDrag(AssetKind.nativeEffect, 'org.caw.stereo.width', 'Width'),
    ];
    for (final kind in kinds) {
      testWidgets('${kind.name} (${kind.kind.name}) dropped below the last track makes a track with it', (tester) async {
        s.project.midiFiles.add(MidiFileDoc(id: 'mf', name: 'Song.mid', parts: ['pat']));
        await pump(tester, drags: [kind]);
        final g = await tester.startGesture(tester.getCenter(find.text('drag ${kind.name}')));
        await g.moveTo(belowTracks(tester));
        await tester.pump();
        await g.moveTo(belowTracks(tester) + const Offset(2, 0));
        await tester.pump();
        expect(find.text('New track'), findsOneWidget, reason: 'the drop indicator');
        await g.up();
        await settle(tester);
        expect(s.project.layers, hasLength(5));
        final made = s.project.layers.last;
        expect(made.name, kind.name);
        switch (kind.kind) {
          case AssetKind.pattern || AssetKind.midiFile:
            expect(made.clips.single.patternId, 'pat');
            expect(made.clips.single.startSteps, greaterThan(0), reason: 'at the drop point');
          case AssetKind.nativeEffect:
            if (kind.instrument) {
              expect(made.instrument?.id, kind.id);
            } else {
              expect(made.components.single.id, kind.id);
            }
          case AssetKind.devicePreset || AssetKind.trackPreset:
            fail('presets are tested in user_presets_test.dart');
          case AssetKind.audioFile:
            fail('audio drops are tested in audio_clips_test.dart');
        }
      });
    }

    Future<void> dragHeader(WidgetTester tester, String id, Offset to, {bool touch = false}) async {
      final from = tester.getCenter(find.byKey(ValueKey('track-header-$id')));
      final g = await tester.startGesture(from, kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse);
      if (touch) await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 6)!);
        await tester.pump();
      }
      await g.up();
      await settle(tester);
    }

    /// The right-most third of [id]'s header, where a dragged track nests under it.
    Offset rightThird(WidgetTester tester, String id) {
      final r = tester.getRect(find.byKey(ValueKey('track-header-$id')));
      return Offset(r.right - r.width / 6, r.center.dy);
    }

    Future<void> doubleTap(WidgetTester tester, Finder f) async {
      await tester.tap(f);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('a header dragged up and down only reorders, even over a folder; its right third nests', (tester) async {
      await pump(tester);
      final a = tester.getRect(find.byKey(const ValueKey('track-header-a')));
      await dragHeader(tester, 'c', Offset(a.center.dx - 40, a.top + 4));
      expect(s.project.layers.map((l) => l.id), ['c', 'a', 'f', 'b']);
      // The middle of a folder's header no longer nests (owner, 2026-11-11): the lower half goes below it.
      final f = tester.getRect(find.byKey(const ValueKey('track-header-f')));
      await dragHeader(tester, 'c', Offset(f.center.dx - 40, f.bottom - 6));
      expect(layer('c').parentId, isNull);
      await dragHeader(tester, 'c', rightThird(tester, 'f'));
      expect(layer('c').parentId, 'f');
    });

    testWidgets('a long press picks a header up at once; let go in place it stays, no menu; a double tap opens it',
        (tester) async {
      await pump(tester, size: const Size(412, 900));
      final head = find.byKey(const ValueKey('track-header-c'));
      final g = await tester.startGesture(tester.getCenter(head));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('track-drag-ghost')), findsOneWidget, reason: 'lifted before it moves');
      await g.up();
      await settle(tester);
      expect(s.project.layers.map((l) => l.id), ['a', 'f', 'b', 'c']);
      expect(find.text('Rename'), findsNothing, reason: 'a long press opens no menu');

      final a = tester.getRect(find.byKey(const ValueKey('track-header-a')));
      await dragHeader(tester, 'c', Offset(a.center.dx - 60, a.top + 4), touch: true);
      expect(s.project.layers.first.id, 'c');

      await doubleTap(tester, find.byKey(const ValueKey('track-header-b')));
      expect(find.text('Rename'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-section-Track')), findsOneWidget, reason: 'grouped in sections');
    });

    testWidgets('nested in the right third of a plain track, that track becomes its parent and feeds on', (tester) async {
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      layer('a').instrument = ComponentUseDoc('org.caw.synth.basic');
      await pump(tester);
      final from = tester.getCenter(find.byKey(const ValueKey('track-header-c')));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, rightThird(tester, 'a'), i / 6)!);
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('track-drop-into')), findsOneWidget, reason: 'the parent lights up');
      expect(find.byKey(const ValueKey('track-drop-into-line')), findsOneWidget, reason: 'an indented line');
      await g.up();
      await settle(tester);
      final parent = layer('a');
      expect(parent.isFolder && parent.busEnabled, isTrue);
      expect(parent.instrument, isNull);
      expect(parent.clips, isEmpty);
      // What played on it moved to a first track inside, of the same name; the nested track follows.
      final own = s.project.layers[1];
      expect(own.parentId, 'a');
      expect(own.name, 'Drums');
      expect(own.instrument?.id, 'org.caw.synth.basic');
      expect(own.clips.single.id, 'c1');
      expect(layer('c').parentId, 'a');
      expect(s.project.layers.indexOf(layer('c')), 2);
      expect(routeTarget(s.project, layer('c')), 'a', reason: 'the child feeds its parent');
      expect(routeTarget(s.project, own), 'a');
      // One undo step takes it all back.
      expect(s.undo(), isTrue);
      expect(s.project.layers.map((l) => l.id), ['a', 'f', 'b', 'c']);
      expect(layer('a').isFolder, isFalse);
      expect(layer('a').clips.single.id, 'c1');
      expect(layer('c').parentId, isNull);
      await settle(tester);
      // Moved out again, it goes back to the master.
      s.redo();
      s.moveTrack(layer('c'), null, TrackDrop.below);
      expect(routeTarget(s.project, layer('c')), isNull);
      await settle(tester);
    });

    testWidgets('a track never nests into itself or a track inside it', (tester) async {
      await pump(tester);
      final from = tester.getCenter(find.byKey(const ValueKey('track-header-f')));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, rightThird(tester, 'b'), i / 6)!);
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('track-drop-into')), findsNothing);
      await g.moveTo(rightThird(tester, 'f'));
      await tester.pump();
      expect(find.byKey(const ValueKey('track-drop-into')), findsNothing, reason: 'nor into itself');
      await g.up();
      await settle(tester);
      expect(s.project.layers.map((l) => l.id), ['a', 'f', 'b', 'c']);
      expect(layer('f').parentId, isNull);
      expect(layer('b').isFolder, isFalse);
      expect(s.moveTrack(layer('f'), layer('b'), TrackDrop.into), isFalse, reason: 'the model refuses it too');
    });

    Future<TestGesture> liftClip(WidgetTester tester) async {
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('clip-c1'))));
      await tester.pump(const Duration(milliseconds: 600));
      return g;
    }

    final haptics = <String>[];
    void listenForHaptics(WidgetTester tester) {
      haptics.clear();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    testWidgets('a long press lifts a clip whole: onto another track, never before the start, one undo step',
        (tester) async {
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      listenForHaptics(tester);
      await pump(tester);
      final clip = tester.getRect(find.byKey(const ValueKey('clip-c1')));
      final g = await liftClip(tester);
      expect(find.byKey(const ValueKey('clip-drag-ghost')), findsOneWidget, reason: 'lifted before it moves');
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
      expect(find.text('Edit notes'), findsNothing, reason: 'a long press opens no menu now');
      // Down to Lead and far left, past the project's start.
      final to = Offset(clip.center.dx - 900, laneOf(tester, 'c').dy);
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(Offset.lerp(clip.center, to, i / 8)!);
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('lane-target-c')), findsOneWidget);
      await g.up();
      await settle(tester);
      expect(layer('a').clips, isEmpty);
      expect(layer('c').clips.single.id, 'c1');
      expect(layer('c').clips.single.startSteps, 0, reason: 'clamped at the start');
      expect(layer('c').clips.single.lengthSteps, 16, reason: 'picked up whole, never stretched');
      expect(s.undo(), isTrue);
      expect(layer('a').clips.single.startSteps, 16);
      expect(layer('c').clips, isEmpty);
      await settle(tester);
    });

    testWidgets('a lifted clip snaps to the grid; a resting second finger frees it', (tester) async {
      s.arrangementSnapSteps = 16;
      layer('a').clips.single.startSteps = 16;
      await pump(tester, size: const Size(900, 900));
      final clip = tester.getRect(find.byKey(const ValueKey('clip-c1')));
      final stepW = clip.width / 16;
      final g = await liftClip(tester);
      await g.moveBy(Offset(stepW * 3, 0));
      await tester.pump();
      final second = await tester.startGesture(laneOf(tester, 'c', x: 40));
      await tester.pump();
      expect(find.byKey(const ValueKey('clip-drag-copy')), findsNothing, reason: 'it frees, not copies');
      await g.moveBy(const Offset(1, 0));
      await tester.pump();
      await g.up();
      await second.up();
      await settle(tester);
      expect(layer('a').clips.single.startSteps, 19, reason: 'off the grid');
      // Without the second finger the same move snaps back to the bar.
      final g2 = await liftClip(tester);
      await g2.moveBy(Offset(stepW * 3, 0));
      await tester.pump();
      await g2.moveBy(const Offset(1, 0));
      await tester.pump();
      await g2.up();
      await settle(tester);
      expect(layer('a').clips.single.startSteps, 16);
    });

    testWidgets('a finger tap selects a clip in the next frame; a quick second tap opens its menu as well',
        (tester) async {
      await pump(tester);
      final clip = find.byKey(const ValueKey('clip-c1'));
      await tester.tap(clip);
      await tester.pump();
      expect(s.selectedClipIds, {'c1'}, reason: 'no double-tap wait (owner, 2026-11-11)');
      expect(find.text('Edit notes'), findsNothing);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(clip);
      await tester.pumpAndSettle();
      expect(find.text('Edit notes'), findsOneWidget, reason: 'the second tap adds the menu');
      expect(s.selectedClipIds, {'c1'});
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);

      // Two taps further apart than the double-tap time are two taps: the second opens no menu.
      await tester.tap(clip);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.tap(clip);
      await tester.pump();
      expect(find.text('Edit notes'), findsNothing);
      await settle(tester);
    });

    testWidgets('a double tap on a clip opens its menu, in sections; a right-click too', (tester) async {
      await pump(tester);
      await doubleTap(tester, find.byKey(const ValueKey('clip-c1')));
      expect(find.text('Edit notes'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-section-Clip')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-section-Edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-number-slider-length-(bars)')), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Edit notes'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('clip-c1')), buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('Edit notes'), findsOneWidget);
    });

    testWidgets("the track menu's volume takes a typed value and resets; the clip length applies on Enter",
        (tester) async {
      await pump(tester);
      await doubleTap(tester, find.byKey(const ValueKey('track-header-a')));
      expect(find.byKey(const ValueKey('menu-section-Mix')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-number-slider-volume')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('menu-number-field-volume')), '-6');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(layer('a').volume, closeTo(0.501, 0.001));
      await tester.tap(find.byKey(const ValueKey('menu-number-reset-volume')));
      await tester.pump();
      expect(layer('a').volume, closeTo(1.0, 1e-9));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await doubleTap(tester, find.byKey(const ValueKey('clip-c1')));
      await tester.enterText(find.byKey(const ValueKey('menu-number-field-length-(bars)')), '2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(layer('a').clips.single.lengthSteps, 32);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('the ring style lists the same entries; a number opens its editor over the ring', (tester) async {
      s.settings.longPressMenu = LongPressMenuStyle.ring;
      await pump(tester);
      await doubleTap(tester, find.byKey(const ValueKey('track-header-a')));
      expect(find.byKey(const ValueKey('long-press-ring')), findsOneWidget);
      await tester.tap(find.byTooltip('Pan'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-number-slider-pan')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('menu-number-field-pan')), 'L50');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(layer('a').pan, closeTo(-0.5, 1e-9));
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(find.byKey(const ValueKey('long-press-ring')), findsNothing, reason: 'the ring closes with it');
    });

    testWidgets('the left edge trims a clip; a double-tap in empty space draws a one-bar clip', (tester) async {
      await pump(tester);
      final edge = find.byKey(const ValueKey('clip-start-c1'));
      await tester.drag(edge, Offset(4 * 18.0 + 2, 0));
      await settle(tester);
      final clip = layer('a').clips.single;
      expect((clip.startSteps, clip.sourceOffsetSteps, clip.lengthSteps), (20, 4, 12));
      final empty = laneOf(tester, 'c', x: 200);
      await tester.tapAt(empty);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(empty);
      await settle(tester);
      expect(layer('c').clips, hasLength(1));
      expect(layer('c').clips.single.lengthSteps, s.project.stepsPerBar);
    });
  });

  group('FX chain', () {
    Future<void> pumpStack(WidgetTester tester, LayerDoc l) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 800,
          child: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: l))))));
      await tester.pump();
    }

    testWidgets('the instrument is the first slot; an empty slot adds one through the browser', (tester) async {
      final l = layer('c');
      await pumpStack(tester, l);
      expect(find.text('INSTRUMENT'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fx-add-instrument')));
      await tester.pumpAndSettle();
      expect(find.text('INSTRUMENTS'), findsOneWidget);
      expect(find.text('Width'), findsNothing);
      await tester.tap(find.text('Basic synth'));
      await tester.pumpAndSettle();
      expect(l.instrument?.id, 'org.caw.synth.basic');
      expect(find.text('INSTRUMENT · C++'), findsOneWidget);
      final inst = tester.getTopLeft(find.byKey(const ValueKey('fx-instrument-title'))).dy;
      expect(inst, lessThan(tester.getTopLeft(find.text('NATIVE EFFECTS · C++')).dy), reason: 'first in the chain');
      expect(find.byKey(const ValueKey('fx-instrument-bypass')), findsOneWidget);
      expect(find.byKey(const ValueKey('fx-instrument-replace')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('+ lists instruments beside effects, and a picked instrument takes the slot', (tester) async {
      final l = layer('c');
      await pumpStack(tester, l);
      await tester.tap(find.byTooltip('Add FX or instrument'));
      await tester.pumpAndSettle();
      expect(find.text('INSTRUMENTS'), findsOneWidget);
      expect(find.text('UTILITY'), findsOneWidget); // built-ins by category (EffectCatalog)
      expect(find.text('Width'), findsOneWidget);
      await tester.tap(find.text('Saw'));
      await tester.pumpAndSettle();
      expect(l.instrument?.id, 'org.caw.synth.saw');
      expect(find.text('INSTRUMENT · C++'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    test('the Files catalogue lets a built-in instrument be dragged, flagged as one', () {
      final asset = s.builtinAssets.firstWhere((a) => a.native!.id == 'org.caw.synth.basic');
      expect(asset.drag?.instrument, isTrue);
      expect(s.builtinAssets.firstWhere((a) => a.native!.id == 'org.caw.stereo.width').drag?.instrument, isFalse);
    });
  });
}
