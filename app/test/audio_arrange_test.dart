// Audio clips in Arrange: the waveform from cached peaks, select, move, trim the edges (the right past the file loops),
// fade corners, the curve dot, the gain handle, the menu, the arm button and the Clip tab's inspector.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/audio_clip_inspector.dart';
import 'package:caw/ui/arrange/audio_waveform.dart';
import 'package:caw/ui/arrange/focus_panel.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Audio arrange', bpm: 120, loopBars: 8, assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/vox.wav', name: 'vox', seconds: 4, channels: 1),
    ], layers: [
      LayerDoc(id: 't1', name: 'Vox', color: 0, input: AudioInputDoc(), audioClips: [
        AudioClipDoc(id: 'c1', assetId: 'a1', startSteps: 16, lengthSeconds: 2, offsetSeconds: 1),
      ]),
      LayerDoc(id: 't2', name: 'Gtr', color: 1, input: AudioInputDoc()),
    ]);

void main() {
  late AppState s;
  late FakeAudioIo io;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    io = FakeAudioIo();
    s.audioIo = io;
    WaveformCache.instance.clear();
  });
  tearDown(() => s.dispose());

  // Saves and the undo history settle on timers.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  }

  AudioClipDoc clip() => s.project.layers.expand((l) => l.audioClips).firstWhere((c) => c.id == 'c1');

  Future<void> pump(WidgetTester tester, {Size size = const Size(1400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pump();
  }

  double stepW(WidgetTester tester) => tester.getSize(find.byKey(const ValueKey('audio-clip-box-c1'))).width / 16;

  testWidgets('the clip draws its waveform from the peaks, cached per zoom level', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('audio-clip-c1')), findsOneWidget);
    expect(find.text('vox'), findsWidgets);
    await tester.pump();
    expect(WaveformCache.instance.cachedLevels, greaterThan(0));
    final levels = WaveformCache.instance.cachedLevels;
    await tester.pump();
    expect(WaveformCache.instance.cachedLevels, levels, reason: 'a repaint reads the cache');
    expect(find.text('Drop audio here, or arm the track and record'), findsNothing,
        reason: 'a track holds a clip: no hint (owner, 2026-11-11)');
    await settle(tester);
  });

  testWidgets('a tap selects it; dragging the body moves it on the grid', (tester) async {
    s.arrangementSnapSteps = 4;
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('audio-clip-c1')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(s.selectedClipIds, {'c1'});
    final w = stepW(tester);
    await tester.drag(find.byKey(const ValueKey('audio-clip-c1')), Offset(w * 8.6, 0));
    await tester.pumpAndSettle();
    expect(clip().startSteps, 24);
    await settle(tester);
  });

  testWidgets('the edges trim: left keeps the audio in place, right past the file loops it', (tester) async {
    await pump(tester);
    final w = stepW(tester);
    await tester.drag(find.byKey(const ValueKey('audio-start-c1')), Offset(w * 4, 0));
    await tester.pumpAndSettle();
    expect(clip().startSteps, 20);
    expect(clip().offsetSeconds, closeTo(1.5, 1e-9));
    await tester.drag(find.byKey(const ValueKey('audio-end-c1')), Offset(w * 40, 0));
    await tester.pumpAndSettle();
    expect(clip().loop, isTrue, reason: 'loop extend past the file\'s end');
    await settle(tester);
  });

  testWidgets('the selected clip\'s fade corners, curve dot and gain handle', (tester) async {
    await pump(tester);
    s.selectAudioClip(s.project.layers.first, clip());
    await tester.pump();
    final w = stepW(tester);
    // 4 steps at 120 BPM is half a second.
    await tester.drag(find.byKey(const ValueKey('audio-fade-in-c1')), Offset(w * 4, 0));
    await tester.pumpAndSettle();
    expect(clip().fadeIn, closeTo(0.5, 0.05));
    await tester.drag(find.byKey(const ValueKey('audio-fade-out-c1')), Offset(-w * 2, 0));
    await tester.pumpAndSettle();
    expect(clip().fadeOut, closeTo(0.25, 0.05));
    // The curve dot: up bends it towards Fast, a tap steps on.
    await tester.drag(find.byKey(const ValueKey('audio-curve-in-c1')), const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(clip().fadeInCurve, FadeCurve.fast);
    await tester.tap(find.byKey(const ValueKey('audio-curve-out-c1')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(clip().fadeOutCurve, FadeCurve.equalPower);
    // The gain handle: 8 px up is a dB louder.
    await tester.drag(find.byKey(const ValueKey('audio-gain-c1')), const Offset(0, -48));
    await tester.pumpAndSettle();
    expect(gainToDb(clip().gain), closeTo(6, 0.6));
    expect(find.byKey(const ValueKey('audio-gain-label-c1')), findsOneWidget);
    await settle(tester);
  });

  Future<void> doubleTap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> hold(WidgetTester tester, Finder f) async {
    await tester.longPress(f);
    await tester.pumpAndSettle();
  }

  testWidgets('a hold opens the menu (owner, 2026-11-12): reverse and split', (tester) async {
    s.pausedStep = 24;
    await pump(tester);
    // A tap selects in the next frame (no double-tap wait) and opens nothing.
    await tester.tap(find.byKey(const ValueKey('audio-clip-c1')));
    await tester.pump();
    expect(s.selectedClipIds, {'c1'});
    expect(find.text('Reverse'), findsNothing);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await hold(tester, find.byKey(const ValueKey('audio-clip-c1')));
    await tester.tap(find.text('Split at the playhead'));
    await tester.pumpAndSettle();
    expect(s.project.layers.first.audioClips, hasLength(2));
    await hold(tester, find.byKey(const ValueKey('audio-clip-c1')));
    await tester.tap(find.text('Reverse'));
    await tester.pumpAndSettle();
    expect(clip().reverse, isTrue);
    await settle(tester);
  });

  testWidgets('a double tap opens its editor, the Clip tab; a tap on the selected clip only selects', (tester) async {
    final sections = SectionController();
    addTearDown(sections.dispose);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections, child: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('audio-clip-c1')));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(s.selectedClipIds, {'c1'});
    expect(sections.focusedLayer, isNull, reason: 'the first tap only selects');
    await tester.tap(find.byKey(const ValueKey('audio-clip-c1')));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(sections.focusedLayer, isNull, reason: 'a tap on the selected clip only selects (owner, 2026-11-12)');
    await doubleTap(tester, find.byKey(const ValueKey('audio-clip-c1')));
    expect(sections.focusedLayer, 't1');
    expect(tester.widget<FocusPanel>(find.byType(FocusPanel)).tab, FocusTab.clip);
    await settle(tester);
  });

  testWidgets('a hold that moves lifts it whole onto another track, on the grid, never before the start', (tester) async {
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    s.arrangementSnapSteps = 4;
    await pump(tester);
    final box = tester.getRect(find.byKey(const ValueKey('audio-clip-c1')));
    final g = await tester.startGesture(box.center);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Duplicate'), findsOneWidget, reason: 'a hold opens the menu (owner, 2026-11-12)');
    final to = Offset(box.center.dx - 900, tester.getCenter(find.byKey(const ValueKey('track-header-t2'))).dy);
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(Offset.lerp(box.center, to, i / 8)!);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Duplicate'), findsNothing, reason: 'moving on closed it');
    await g.up();
    await settle(tester);
    expect(s.project.layers.first.audioClips, isEmpty);
    final moved = s.project.layers[1].audioClips.single;
    expect(moved.startSteps, 0, reason: 'clamped at the project start');
    expect(moved.lengthSeconds, 2, reason: 'picked up whole, never trimmed');
    expect(s.undo(), isTrue);
    expect(s.project.layers.first.audioClips.single.startSteps, 16);
    await settle(tester);

    // A short lift snaps to the grid.
    final b2 = tester.getRect(find.byKey(const ValueKey('audio-clip-c1')));
    final w = stepW(tester);
    final g2 = await tester.startGesture(b2.center);
    await tester.pump(const Duration(milliseconds: 600));
    await g2.moveBy(Offset(w * 4.7, 0));
    await tester.pump();
    await g2.moveBy(const Offset(1, 0));
    await tester.pump();
    await g2.up();
    await settle(tester);
    expect(clip().startSteps, 20);
  });

  testWidgets('the arm button arms the track; armed, its header shows the input meter', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('audio-arm-t2')));
    await tester.pumpAndSettle();
    expect(s.project.layers[1].input!.armed, isTrue);
    expect(find.byKey(const ValueKey('audio-input-meter-t2')), findsOneWidget);
    await settle(tester);
  });

  testWidgets('the inspector edits the clip: mode, reverse, pitch', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AudioClipInspector(state: s, layer: s.project.layers.first))));
    await tester.pump();
    await tester.tap(find.text('Musical'));
    await tester.pump();
    expect(clip().mode, AudioClipMode.musical);
    await tester.tap(find.byKey(const ValueKey('audio-pitch-up')));
    await tester.pump();
    expect(clip().pitch, 1);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('audio-reverse')), 100);
    await tester.tap(find.byKey(const ValueKey('audio-reverse')));
    await tester.pump();
    expect(clip().reverse, isTrue);
    await settle(tester);
  });
}
