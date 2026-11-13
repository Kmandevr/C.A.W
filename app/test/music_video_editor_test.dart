// The music video editor's widgets on a phone-sized screen: the shot lane (select, drag, trim, cut markers, add,
// split, undo and redo, keyboard shortcuts) and the shot list (expand, layout, views, effects), and auto-cut's flow.
import 'dart:async';

import 'package:caw/actions/actions.dart';
import 'package:caw/actions/keymap.dart';
import 'package:caw/actions/keys.dart';
import 'package:caw/actions/macro.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/music_video.dart';
import 'package:caw/model/music_video_autocut.dart';
import 'package:caw/model/music_video_edit.dart';
import 'package:caw/model/music_video_scene.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/music_video/video_editor.dart';
import 'package:caw/ui/music_video/video_editor_page.dart';
import 'package:caw/ui/music_video/video_preview.dart';
import 'package:caw/ui/page_closer.dart';
import 'package:caw/ui/music_video/video_setup_sheet.dart';
import 'package:caw/ui/music_video/video_shot_lane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _beat = '---\ncaw: 1\nkind: pattern\nname: Beat\nlength: 1 bar\n---\n0 C2 1 1\n4 D2 1 0.8\n8 C2 1 1\n12 D2 1 0.8\n';

ProjectDoc _song() => ProjectDoc(id: 'p', name: 'Edit test', bpm: 120, loopBars: 16, modules: [
      ModuleDoc(id: 'beat', name: 'Beat', source: _beat),
    ], layers: [
      LayerDoc(id: 'drums', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'beat', lengthSteps: 256)]),
    ]);

VideoScene _scene() => buildVideoScene(_song(), colorOf: (_) => 0xff40ffc0);

Future<List<VideoCut>> _here(VideoScene scene, AutoCutSettings settings, MusicVideoOptions options,
        {required double start, required double end, List<double>? loudness}) async =>
    autoCut(scene, settings, options, start: start, end: end, loudness: loudness);

class _Host {
  int changed = 0, saved = 0;
}

Future<(MusicVideoDoc, _Host)> _pump(WidgetTester tester, {List<VideoCut>? cuts, AutoCutRunner? runner,
    double end = 256}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
  final doc = MusicVideoDoc(timeline: VideoTimeline(cuts), snap: VideoSnap.bar);
  final host = _Host();
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: Padding(
    padding: const EdgeInsets.all(12),
    child: StatefulBuilder(builder: (context, setState) => MusicVideoEditor(
      doc: doc, scene: _scene(), start: 0, end: end, aspect: 9 / 16, runner: runner ?? _here,
      onChanged: () => host.changed++, onSave: () => host.saved++)),
  )))));
  await tester.pump();
  return (doc, host);
}

Finder _key(String k) => find.byKey(ValueKey(k));

/// Taps [k] after scrolling it into view (the toolbar scrolls sideways on a narrow phone).
Future<void> _tapKey(WidgetTester tester, String k) async {
  await tester.ensureVisible(_key(k));
  await tester.pumpAndSettle();
  await tester.tap(_key(k));
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetMusicVideoSheet);
  testWidgets('the lane: tap selects, a drag moves by whole bars, a trim and a cut marker resize, undo and redo',
      (tester) async {
    final (doc, host) = await _pump(tester, cuts: [
      VideoCut(id: 's1', start: 0, length: 32),
      VideoCut(id: 's2', start: 32, length: 32, layout: VideoLayout.single(VideoShot.mixer)),
      VideoCut(id: 's3', start: 128, length: 32),
    ]);
    final t = doc.timeline;
    final lane = tester.state<ShotLaneState>(find.byType(ShotLane));
    final px = lane.pxPerStep;
    expect(px, greaterThan(0));

    // Tap selects s3; a drag of about 1.4 bars moves it by one whole bar (snap: bar).
    await tester.tap(_key('video-lane-shot-s3'));
    await tester.pump();
    final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
    expect(editor.selected, 's3');
    await tester.drag(_key('video-lane-shot-s3'), Offset(16 * 1.4 * px, 0), touchSlopX: 0);
    await tester.pumpAndSettle();
    expect(t.byId('s3')!.start, 144);
    expect(t.byId('s3')!.length, 32);
    expect(host.saved, 1);

    // The cut marker between s1 and s2 moves the cut: s1 ends and s2 starts a bar later.
    final marker = tester.getCenter(_key('video-lane-cut-1'));
    await tester.dragFrom(marker, Offset(16 * px, 0), touchSlopX: 0);
    await tester.pumpAndSettle();
    expect((t.byId('s1')!.end, t.byId('s2')!.start, t.byId('s2')!.end), (48.0, 48.0, 64.0));

    // The chosen shot's right edge trims it.
    await tester.tap(_key('video-lane-shot-s3'));
    await tester.pump();
    final box = tester.getRect(_key('video-lane-shot-s3'));
    await tester.dragFrom(Offset(box.right - 4, box.center.dy), Offset(16 * px, 0), touchSlopX: 0);
    await tester.pumpAndSettle();
    expect((t.byId('s3')!.start, t.byId('s3')!.end), (144.0, 192.0));

    // Undo three times returns to the start; redo once moves s3 again.
    for (var i = 0; i < 3; i++) {
      await _tapKey(tester, 'video-undo');
    }
    expect([for (final c in t.cuts) (c.start, c.end)], [(0.0, 32.0), (32.0, 64.0), (128.0, 160.0)]);
    await _tapKey(tester, 'video-redo');
    expect(t.byId('s3')!.start, 144);
    await tester.pumpAndSettle();
  });

  testWidgets('the cursor, Add, Split, Duplicate and Delete, from the toolbar and the keyboard', (tester) async {
    final (doc, _) = await _pump(tester);
    final t = doc.timeline;
    expect(find.textContaining('No shots yet'), findsOneWidget);
    final lane = tester.state<ShotLaneState>(find.byType(ShotLane));
    final ruler = tester.getTopLeft(_key('video-lane-ruler'));

    // Tap the ruler at bar 3 for the cursor, then Add puts a bar-long shot there.
    await tester.tapAt(ruler + Offset(8 + 32 * lane.pxPerStep + 2, 8));
    await tester.pump();
    final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
    expect(editor.cursor, 32);
    await _tapKey(tester, 'video-add');
    expect([for (final c in t.cuts) (c.start, c.length)], [(32.0, 16.0)]);
    expect(find.textContaining('No shots yet'), findsNothing);
    expect(find.byKey(ValueKey('video-shot-row-${t.cuts.single.id}')), findsOneWidget);

    // The keyboard: Ctrl+D duplicates the chosen shot after it; Delete removes it; Ctrl+Z brings it back.
    await tester.tap(_key('video-lane-shot-${t.cuts.single.id}'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect([for (final c in t.cuts) c.start], [32, 48]);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(t.cuts.length, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(t.cuts.length, 2);

    // Split at a cursor inside a shot (snap: beat).
    doc.snap = VideoSnap.beat;
    editor.select(t.cuts.first.id);
    editor.setCursor(40);
    await tester.pump();
    await _tapKey(tester, 'video-split');
    expect([for (final c in t.cuts) (c.start, c.end)], [(32.0, 40.0), (40.0, 48.0), (48.0, 64.0)]);
  });

  testWidgets('the list: a row opens its editor; layout, panel view, effects and transition change the shot',
      (tester) async {
    final (doc, host) = await _pump(tester, cuts: [VideoCut(id: 's1', start: 0, length: 64)]);
    final c = doc.timeline.cuts.single;
    expect(find.text('1.1 → 5.1 · 4 bars · cut'), findsOneWidget);
    await tester.tap(_key('video-shot-s1'));
    await tester.pumpAndSettle();
    expect(_key('video-layout-bigStrip'), findsOneWidget);

    Future<void> tap(String k) async {
      await tester.ensureVisible(_key(k));
      await tester.pumpAndSettle();
      await tester.tap(_key(k));
      await tester.pumpAndSettle();
    }

    await tap('video-layout-bigStrip');
    expect(c.layout.preset, VideoLayoutPreset.bigStrip);
    expect([for (final p in c.layout.panels) p.view], [VideoShot.flythrough, VideoShot.mixer]);

    // Choose the strip and make it falling notes, with all 88 keys.
    await tap('video-layout-panel-1');
    await tap('video-panel-view-falling');
    expect(c.layout.panels[1].view, VideoShot.falling);
    await tap('video-falling-88');
    expect(c.layout.panels[1].fullKeyboard, isTrue);
    await tap('video-falling-track-drums');
    expect(c.layout.panels[1].hiddenTracks, {'drums'});

    // Drag the divider up: the big view gets smaller.
    await tester.ensureVisible(_key('video-layout-divider-0'));
    await tester.pumpAndSettle();
    final divider = tester.getCenter(_key('video-layout-divider-0'));
    await tester.dragFrom(divider, const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(c.layout.split, lessThan(0.76));

    // A look for the panel.
    await tap('video-look-palette-warm');
    expect(c.layout.panels[1].look.palette, VideoPalette.warm);

    // Add a glow that follows the beat, bypass it, then remove it.
    await tap('video-fx-add');
    await tester.tap(find.text('Glow').last);
    await tester.pumpAndSettle();
    expect(c.effects.single.kind, VideoEffectKind.glow);
    await tap('video-fx-drive-0-beat');
    expect(c.effects.single.drive, VideoDrive.beat);
    await tap('video-fx-on-0');
    expect(c.effects.single.on, isFalse);
    await tap('video-fx-remove-0');
    expect(c.effects, isEmpty);

    // Crossfade in; the layout animates from the shot before.
    await tap('video-transition-crossfade');
    expect((c.transition.name, c.transitionSteps), ('crossfade', 4.0));
    await tap('video-layout-change-true');
    expect(c.animateLayout, isTrue);
    expect(host.saved, greaterThan(8));
    // Collapse the row.
    await tap('video-shot-s1');
    expect(_key('video-layout-bigStrip'), findsNothing);
  });

  testWidgets('auto-cut fills the lane, then asks before it replaces edits or fills only the empty space',
      (tester) async {
    final (doc, _) = await _pump(tester);
    final t = doc.timeline;
    await tester.tap(_key('video-autocut'));
    await tester.pumpAndSettle();
    expect(find.text('AUTO-CUT'), findsOneWidget);
    await tester.tap(_key('autocut-bursts')); // off
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('autocut-run'));
    await tester.tap(_key('autocut-run'));
    await tester.pumpAndSettle();
    expect(t.cuts.first.start, 0);
    expect(t.cuts.last.end, 256);
    expect(doc.autoCut.bursts, isFalse);
    final first = t.cuts.length;
    expect(first, greaterThan(1));

    // Edit: delete the second shot, leaving a gap; auto-cut asks, and Fill keeps the first shot as it was.
    final kept = t.cuts.first.id;
    final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
    editor.select(t.cuts[1].id);
    editor.delete();
    await tester.pumpAndSettle();
    await tester.tap(_key('video-autocut'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('autocut-run'));
    await tester.tap(_key('autocut-run'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your shots?'), findsOneWidget);
    await tester.tap(_key('video-autocut-fill'));
    await tester.pumpAndSettle();
    expect(t.gaps(0, 256), isEmpty);
    expect(t.cuts.first.id, kept);
    expect(find.textContaining('filled the empty space'), findsOneWidget);
  });

  testWidgets('the setup sheet shows the lane, and edits save with the project and come back', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = _song()
      ..musicVideo = MusicVideoDoc(timeline: VideoTimeline([VideoCut(id: 's1', start: 0, length: 64,
          layout: VideoLayout.single(VideoShot.falling))])).toJson();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MusicVideoPanel(state: s))));
    await tester.pump();
    expect(find.byType(ShotLane), findsOneWidget);
    expect(find.textContaining('from the lane'), findsOneWidget);
    final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
    editor.select('s1');
    editor.delete();
    await tester.pump();
    expect(s.project.musicVideo!['shots'], isEmpty);
    expect(find.textContaining('cut by the'), findsOneWidget); // the director again
    await tester.pump(const Duration(seconds: 1)); // the project's save
  });

  group('review fixes', () {
    testWidgets('a shot past the range end: its Length and Start steppers are off, and nothing throws', (tester) async {
      final (doc, _) = await _pump(tester, end: 128, cuts: [VideoCut(id: 's1', start: 0, length: 32),
          VideoCut(id: 's2', start: 192, length: 32)]);
      await _tapKey(tester, 'video-shot-s2');
      for (final k in ['video-length-up', 'video-length-down', 'video-start-up', 'video-start-down']) {
        expect(tester.widget<IconButton>(_key(k)).onPressed, isNull, reason: k);
      }
      expect(find.textContaining('outside the range'), findsOneWidget);
      expect((doc.timeline.byId('s2')!.start, doc.timeline.byId('s2')!.length), (192.0, 32.0));
    });

    testWidgets('an edit that changes nothing leaves no undo step', (tester) async {
      final (doc, _) = await _pump(tester, cuts: [VideoCut(id: 's1', start: 0, length: 64)]);
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
      editor.setCursor(16); // inside s1: Add can't
      await tester.pump();
      editor.add();
      await tester.pump();
      expect(editor.canUndo, isFalse);
      editor.select('s1');
      editor.nudge(-1); // at the range's start already
      await tester.pump();
      expect(editor.canUndo, isFalse);
      expect(doc.timeline.cuts.length, 1);
      // A real change still makes one, and an empty edit after it keeps redo.
      editor.nudge(1);
      await tester.pump();
      expect(editor.canUndo, isTrue);
      editor.undo();
      await tester.pump();
      expect(editor.canRedo, isTrue);
      editor.nudge(-1);
      await tester.pump();
      expect(editor.canRedo, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('auto-cut Replace replaces only the range; shots outside it stay', (tester) async {
      final (doc, _) = await _pump(tester, end: 128, cuts: [VideoCut(id: 's9', start: 192, length: 32)]);
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
      await editor.runAutoCut(AutoCutSettings(), AutoCutMode.replace);
      await tester.pumpAndSettle();
      final t = doc.timeline;
      expect(t.byId('s9'), isNotNull);
      expect(t.cuts.where((c) => c.start < 128).last.end, 128);
      expect(t.cuts.first.start, 0);
    });

    testWidgets('a failing auto-cut clears busy and says why on one line', (tester) async {
      Future<List<VideoCut>> boom(VideoScene scene, AutoCutSettings settings, MusicVideoOptions options,
              {required double start, required double end, List<double>? loudness}) =>
          Future.error(StateError('no isolate'));
      final (doc, _) = await _pump(tester, runner: boom);
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
      await editor.runAutoCut(AutoCutSettings(), AutoCutMode.replace);
      await tester.pumpAndSettle();
      expect(editor.busy, isFalse);
      expect(find.textContaining('Auto-cut failed: no isolate'), findsOneWidget);
      expect(tester.widget<TextButton>(_key('video-autocut')).onPressed, isNotNull);
      expect(doc.timeline.isEmpty, isTrue);
    });

    testWidgets("while auto-cut runs, keys and lane gestures don't edit", (tester) async {
      final gate = Completer<List<VideoCut>>();
      Future<List<VideoCut>> slow(VideoScene scene, AutoCutSettings settings, MusicVideoOptions options,
              {required double start, required double end, List<double>? loudness}) =>
          gate.future;
      final (doc, _) = await _pump(tester, runner: slow, cuts: [VideoCut(id: 's1', start: 0, length: 32),
          VideoCut(id: 's2', start: 64, length: 32)]);
      final t = doc.timeline;
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
      await tester.tap(_key('video-lane-shot-s2'));
      await tester.pump();
      expect(editor.selected, 's2');
      final run = editor.runAutoCut(AutoCutSettings(interval: false, bursts: false, tracks: false, loudness: false),
          AutoCutMode.fillGaps);
      await tester.pump();
      expect(editor.busy, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect([for (final c in t.cuts) c.start], [0, 64]);
      final lane = tester.state<ShotLaneState>(find.byType(ShotLane));
      await tester.drag(_key('video-lane-shot-s2'), Offset(32 * lane.pxPerStep, 0), touchSlopX: 0, warnIfMissed: false);
      await tester.pump();
      expect(t.byId('s2')!.start, 64);
      gate.complete(const []);
      await run;
      await tester.pumpAndSettle();
      expect(editor.busy, isFalse);
    });
  });

  group("owner's follow-ups", () {
    testWidgets('Strobe warns once about photosensitivity, and the list marks it', (tester) async {
      final settings = Settings();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      final doc = MusicVideoDoc(timeline: VideoTimeline([VideoCut(id: 's1', start: 0, length: 64)]));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MusicVideoEditor(
          doc: doc, scene: _scene(), start: 0, end: 256, aspect: 9 / 16, runner: _here, settings: settings,
          onChanged: () {}, onSave: () {})))));
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
      final fx = doc.timeline.cuts.single.effects;
      final first = editor.addEffect(fx, VideoEffectKind.strobe);
      await tester.pumpAndSettle();
      expect(find.text('Strobe flashes the whole frame'), findsOneWidget);
      await tester.tap(_key('video-strobe-ok'));
      await tester.pumpAndSettle();
      await first;
      expect(fx.single.kind, VideoEffectKind.strobe);
      expect(settings.strobeWarned, isTrue);
      expect(find.textContaining('⚠ Strobe'), findsOneWidget);
      // The second time it doesn't ask.
      await editor.addEffect(fx, VideoEffectKind.strobe);
      await tester.pumpAndSettle();
      expect(find.text('Strobe flashes the whole frame'), findsNothing);
      expect(fx.length, 2);
      // Other effects never ask.
      final fresh = Settings();
      expect(fresh.strobeWarned, isFalse);
      await editor.addEffect(fx, VideoEffectKind.glow);
      await tester.pumpAndSettle();
      expect(fx.length, 3);
    });

    testWidgets("an effect's target: the whole shot or one panel of the layout", (tester) async {
      final (doc, _) = await _pump(tester, cuts: [VideoCut(id: 's1', start: 0, length: 64,
          layout: VideoLayout(preset: VideoLayoutPreset.bigStrip), effects: [VideoEffect(kind: VideoEffectKind.glow)])]);
      await _tapKey(tester, 'video-shot-s1');
      await _tapKey(tester, 'video-fx-target-0-1');
      expect(doc.timeline.cuts.single.effects.single.panel, 1);
      await _tapKey(tester, 'video-fx-target-0--1');
      expect(doc.timeline.cuts.single.effects.single.panel, isNull);
    });

    testWidgets("the editor's keys are catalogue actions in their own context", (tester) async {
      final ids = {for (final d in ActionRegistry.standard().inArea(Area.video)) d.id};
      expect(ids, containsAll(['video.add', 'video.split', 'video.duplicate', 'video.delete', 'video.undo',
          'video.redo', 'video.nudgeLeft', 'video.nudgeRight', 'video.previous', 'video.following', 'video.autocut',
          'video.fullScreen']));
      final km = Keymap.defaults(ActionRegistry.standard());
      expect(km.lookup(Area.video, KeySeq.parse('S')), const ActionRef.action('video.split'));
      expect(km.lookup(Area.video, KeySeq.parse('Ctrl+S')), const ActionRef.action('project.save'));
      // The editor runs them (here through its key context alone, as with no key router).
      final (doc, _) = await _pump(tester, cuts: [VideoCut(id: 's1', start: 0, length: 64)]);
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
      expect(editor.runAction('video.following'), isTrue);
      expect(editor.selected, 's1');
      editor.setCursor(32);
      await tester.pump();
      expect(editor.runAction('video.split'), isTrue);
      await tester.pumpAndSettle();
      expect(doc.timeline.cuts.length, 2);
    });

    testWidgets('full screen: a closable page with the preview over the lane and list; Back closes it', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = _song();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MusicVideoPanel(state: s))));
      await tester.pump();
      // A new video with notes includes Falling notes.
      expect(s.project.musicVideo, isNull);
      await _tapKey(tester, 'video-editor-full-screen');
      expect(find.text('MUSIC VIDEO EDITOR'), findsOneWidget);
      final route = ModalRoute.of(tester.element(find.byType(MusicVideoEditorPage)))!;
      expect(route.settings.name, closablePage.name);
      final page = tester.getRect(find.byType(MusicVideoEditorPage));
      expect(page.width, closeTo(1080 / 2.6, 1));
      // Phone: the preview above the lane.
      expect(tester.getTopLeft(find.byType(MusicVideoPreview).last).dy,
          lessThan(tester.getTopLeft(find.byType(ShotLane).last).dy));
      // An edit there shows in the sheet after it closes.
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor).last);
      editor.add();
      await tester.pumpAndSettle();
      await tester.tap(_key('video-editor-close'));
      await tester.pumpAndSettle();
      expect(find.text('MUSIC VIDEO EDITOR'), findsNothing);
      expect(_key('video-shot-row-s1'), findsOneWidget); // the sheet's list shows the shot made full screen
      expect((s.project.musicVideo!['shots'] as List).length, 1);
      expect((s.project.musicVideo!['options'] as Map)['shots'], contains('falling'));
      // Back closes it too.
      await _tapKey(tester, 'video-editor-full-screen');
      expect(find.text('MUSIC VIDEO EDITOR'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('MUSIC VIDEO EDITOR'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('full screen on a wide screen: the preview and lane beside the shot list', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = _song();
      final doc = MusicVideoDoc(timeline: VideoTimeline([VideoCut(id: 's1', start: 0, length: 64)]));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MusicVideoEditorPage(state: s, doc: doc, runner: _here))));
      await tester.pump();
      final lane = tester.getRect(find.byType(ShotLane));
      final row = tester.getRect(_key('video-shot-s1'));
      expect(row.left, greaterThan(lane.right)); // the list sits to the right
      expect(tester.getTopLeft(find.byType(MusicVideoPreview)).dy, lessThan(lane.top));
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
