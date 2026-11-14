// Batch 1.0.4 (#208, #90) in the UI: the stretch notch (and edges still trimming), the Follows tempo switch's rule,
// each sample editor tool and handle as one undo step, Slice to MIDI's live preview and confirm, the ways in (a
// double tap, a tap in Files), and a clip at bar 9999 laid out relative to the view's origin.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/drums.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sample_edit.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/audio_clip_inspector.dart';
import 'package:caw/ui/arrange/audio_waveform.dart';
import 'package:caw/ui/arrange/timeline_window.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Editor', bpm: 120, loopBars: 8, assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/beat.wav', name: 'beat', seconds: 4, channels: 2, sourceRate: 44100),
    ], layers: [
      LayerDoc(id: 't1', name: 'Beat', color: 0, input: AudioInputDoc(), audioClips: [
        AudioClipDoc(id: 'c1', assetId: 'a1', startSteps: 16, lengthSeconds: 2, offsetSeconds: 0.5),
      ]),
    ]);

void main() {
  late AppState s;
  late FakeAudioAnalysis an;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.audioIo = FakeAudioIo();
    an = FakeAudioAnalysis();
    s.audioAnalysis = an;
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    WaveformCache.instance.clear();
    Motion.setting = MotionLevel.off;
  });
  tearDown(() {
    Motion.setting = MotionLevel.full;
    s.dispose();
  });

  LayerDoc track() => s.project.layers.first;
  AudioClipDoc clip() => s.project.layers.expand((l) => l.audioClips).firstWhere((c) => c.id == 'c1');

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  Future<void> arranger(WidgetTester tester, {SectionController? sections, Size size = const Size(1400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget body = Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)));
    if (sections != null) body = SectionScope(controller: sections, child: body);
    await tester.pumpWidget(MaterialApp(home: body));
    await tester.pump();
  }

  Future<void> inspector(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => AudioClipInspector(state: s, layer: track())))));
    await settle(tester);
  }

  /// Undoes the last step and checks the clip is as [before] (its project JSON).
  Future<void> undoTo(WidgetTester tester, String before) async {
    await tester.pump(const Duration(seconds: 1));
    expect(s.undo(), isTrue);
    await tester.pump();
    expect(jsonEncode(clip().toJson()), before);
    await tester.pump(const Duration(seconds: 1));
  }

  /// Taps a tool of the editor's row (it scrolls sideways on a phone).
  Future<void> tool(WidgetTester tester, String name) async {
    final f = find.byKey(ValueKey('sample-tool-$name'));
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
  }

  double stepW(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('audio-clip-box-c1'))).width / clip().lengthAt(120);

  testWidgets('the notch stretches with a live readout; the edge still trims', (tester) async {
    await arranger(tester);
    s.selectAudioClip(track(), clip());
    await tester.pump();
    final w = stepW(tester);
    final notch = find.byKey(const ValueKey('audio-stretch-c1'));
    expect(notch, findsOneWidget);
    final before = jsonEncode(clip().toJson());
    final g = await tester.startGesture(tester.getCenter(notch));
    await g.moveBy(const Offset(20, 0));
    await g.moveBy(Offset(w * 8 - 20, 0));
    await tester.pump();
    expect(find.byKey(const ValueKey('audio-stretch-readout-c1')), findsOneWidget);
    expect(find.text('3.00 s · ×1.50'), findsOneWidget);
    await g.up();
    await tester.pump();
    expect(clip().stretchRatio, closeTo(1.5, 1e-9));
    expect(clip().lengthSeconds, closeTo(3, 1e-9));
    expect(find.byKey(const ValueKey('audio-stretch-readout-c1')), findsNothing);
    await undoTo(tester, before);
    // The right edge trims (the stretch stays 1).
    await tester.drag(find.byKey(const ValueKey('audio-end-c1')), Offset(-w * 4, 0));
    await tester.pump();
    expect(clip().stretchRatio, 1);
    expect(clip().lengthSeconds, closeTo(1.5, 1e-9));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a clip that follows the tempo has no notch', (tester) async {
    clip()
      ..sourceBpm = 120
      ..mode = AudioClipMode.musical;
    await arranger(tester);
    expect(find.byKey(const ValueKey('audio-stretch-c1')), findsNothing);
  });

  testWidgets('Follows tempo is off with its reason until the tempo is known; Detect fills it', (tester) async {
    await inspector(tester);
    final sw = find.descendant(of: find.byKey(const ValueKey('audio-follows-tempo')), matching: find.byType(Switch));
    expect(tester.widget<Switch>(sw).onChanged, isNull);
    expect(find.text('Set the clip\'s tempo first: it isn\'t known yet.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-tempo-detect')));
    await tester.tap(find.byKey(const ValueKey('audio-tempo-detect')));
    await settle(tester);
    expect(clip().sourceBpm, 120);
    expect(find.textContaining('Detected 120.0 BPM'), findsOneWidget);
    expect(tester.widget<Switch>(sw).onChanged, isNotNull);
    // Typed in instead.
    await tester.tap(find.byKey(const ValueKey('audio-tempo')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('audio-tempo-field')), '93.5');
    await tester.tap(find.byKey(const ValueKey('audio-tempo-ok')));
    await settle(tester);
    expect(clip().sourceBpm, 93.5);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pitch is semitones and cents', (tester) async {
    await inspector(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-pitch-up')));
    await tester.tap(find.byKey(const ValueKey('audio-pitch-up')));
    await tester.pump();
    expect(clip().pitchCents, 100);
    final cents = find.byKey(const ValueKey('audio-cents-slider'));
    await tester.ensureVisible(cents);
    await tester.drag(cents, const Offset(400, 0));
    await tester.pump();
    expect(clip().pitchCents, 150);
    expect(clip().lengthSeconds, 2, reason: 'pitch never changes the length');
    await tester.pump(const Duration(seconds: 1));
  });

  group('the sample editor\'s tools, each one undo step', () {
    testWidgets('Normalise', (tester) async {
      await inspector(tester);
      final before = jsonEncode(clip().toJson());
      an.peakLevel = 0.5;
      await tool(tester, 'normalise');
      await settle(tester);
      expect(gainToDb(clip().gain), closeTo(6.02, 0.01));
      expect(find.byKey(const ValueKey('sample-note')), findsOneWidget);
      await undoTo(tester, before);
    });

    testWidgets('Reverse', (tester) async {
      await inspector(tester);
      final before = jsonEncode(clip().toJson());
      await tool(tester, 'reverse');
      await tester.pump();
      expect(clip().reverse, isTrue);
      await undoTo(tester, before);
    });

    testWidgets('Gain', (tester) async {
      await inspector(tester);
      final before = jsonEncode(clip().toJson());
      await tool(tester, 'gain');
      await settle(tester);
      await tester.drag(find.byKey(const ValueKey('sample-gain-slider')), const Offset(-100, 0));
      await tester.pump();
      expect(clip().gain, lessThan(1));
      await undoTo(tester, before);
      await tool(tester, 'gain');
      await settle(tester);
      expect(find.byKey(const ValueKey('sample-gain-slider')), findsNothing, reason: 'the panel closes again');
    });

    testWidgets('Trim', (tester) async {
      await inspector(tester);
      final before = jsonEncode(clip().toJson());
      an.peakAt = (a, b) => b > 1.0 && a < 2.0 ? 0.8 : 0.0;
      await tool(tester, 'trim');
      await settle(tester);
      expect(clip().offsetSeconds, closeTo(1.0, 0.04));
      expect(clip().lengthSeconds, closeTo(1.0, 0.07));
      await undoTo(tester, before);
    });

    testWidgets('trim edge, fade, curve and loop handles', (tester) async {
      await inspector(tester);
      final wave = tester.getSize(find.byKey(const ValueKey('sample-editor-wave')));
      final pxPerSec = wave.width / 4;
      var before = jsonEncode(clip().toJson());
      await tester.drag(find.byKey(const ValueKey('sample-trimLeft-c1')), Offset(pxPerSec * 0.5, 0));
      await tester.pump();
      expect(clip().offsetSeconds, closeTo(1.0, 0.03));
      expect(clip().lengthSeconds, closeTo(1.5, 0.03));
      await undoTo(tester, before);

      before = jsonEncode(clip().toJson());
      await tester.drag(find.byKey(const ValueKey('sample-fadeIn-c1')), Offset(pxPerSec * 0.4, 0));
      await tester.pump();
      expect(clip().fadeIn, closeTo(0.4, 0.03));
      await undoTo(tester, before);

      s.setAudioFades(track(), clip(), fadeOut: 0.5);
      await tester.pump(const Duration(seconds: 1));
      before = jsonEncode(clip().toJson());
      await tester.drag(find.byKey(const ValueKey('sample-curveOut-c1')), const Offset(0, -30));
      await tester.pump();
      expect(clip().fadeOutCurve, isNot(FadeCurve.linear));
      await undoTo(tester, before);

      before = jsonEncode(clip().toJson());
      await tester.drag(find.byKey(const ValueKey('sample-loopEnd-c1')), Offset(-pxPerSec, 0));
      await tester.pump();
      expect(clip().loop, isTrue);
      expect(clip().loopEnd, closeTo(3, 0.03));
      await undoTo(tester, before);
    });
  });

  testWidgets('Slice to MIDI: the lines follow the sensitivity, and confirming makes a drums track in one step',
      (tester) async {
    an.cuts = [0.75, 1.0, 1.5, 2.0];
    await inspector(tester);
    final project = jsonEncode(s.project.toJson());
    await tool(tester, 'slice');
    await settle(tester);
    expect(find.text('4 slices on drum pads'), findsOneWidget, reason: 'sensitivity 0.5: 3 of the 4 cuts in the clip');
    await tester.drag(find.byKey(const ValueKey('sample-slice-sensitivity')), const Offset(400, 0));
    await settle(tester);
    expect(find.text('5 slices on drum pads'), findsOneWidget);
    expect(an.sensitivities.last, 1);
    await tester.tap(find.byKey(const ValueKey('sample-slice-make')));
    await settle(tester);
    final made = s.project.layers[1];
    expect(made.instrument!.id, drumsComponentId);
    expect(made.clips.single.startSteps, 16);
    expect(find.byKey(const ValueKey('sample-slice-make')), findsNothing, reason: 'the panel closes');
    await tester.pump(const Duration(seconds: 1));
    expect(s.undo(), isTrue);
    expect(jsonEncode(s.project.toJson()), project);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a double tap of an audio clip opens the Clip tab with the sample editor', (tester) async {
    await arranger(tester);
    final body = find.byKey(const ValueKey('audio-clip-c1'));
    await tester.tap(body);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(body);
    await settle(tester);
    expect(find.byKey(const ValueKey('sample-editor-c1')), findsOneWidget);
  });

  testWidgets('a tap on an audio file in Files opens its clip in the sample editor', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sections = SectionController();
    addTearDown(sections.dispose);
    sections.show(Section.files);
    await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
        child: Scaffold(body: FileManagerScreen(state: s, folder: 'audio/files', onOpenBuilder: () {})))));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('aud:a1')));
    await tester.pump();
    expect(sections.current, Section.arrange);
    expect(sections.focusedLayer, 't1');
    expect(sections.takeClipTab(), isTrue);
    expect(s.selectedClipId, 'c1');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('#90: a clip at bar 9999 is placed relative to the view and lines up exactly', (tester) async {
    const far = 9998.0 * 16;
    s.project = ProjectDoc(id: 'p', name: 'Long', bpm: 120, assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/beat.wav', name: 'beat', seconds: 4, channels: 2, sourceRate: 44100),
    ], layers: [
      LayerDoc(id: 't1', name: 'Beat', color: 0, input: AudioInputDoc(), audioClips: [
        AudioClipDoc(id: 'early', assetId: 'a1', startSteps: 0, lengthSeconds: 1),
        AudioClipDoc(id: 'c1', assetId: 'a1', startSteps: far, lengthSeconds: 1),
        AudioClipDoc(id: 'c2', assetId: 'a1', startSteps: far + 16, lengthSeconds: 1),
      ]),
    ]);
    await arranger(tester);
    await tester.pump();
    expect(find.byKey(const ValueKey('audio-clip-box-c1')), findsNothing, reason: 'out of view: not built');
    final w = tester.getSize(find.byKey(const ValueKey('audio-clip-box-early'))).width / 8;
    // The lanes' scroll view: the horizontal one with the most to scroll.
    final lanes = tester.stateList<ScrollableState>(find.byType(Scrollable))
        .where((st) => st.position.axis == Axis.horizontal)
        .reduce((a, b) => a.position.maxScrollExtent >= b.position.maxScrollExtent ? a : b);
    final before = tester.getTopLeft(find.byKey(const ValueKey('audio-clip-box-early'))).dx;
    lanes.position.jumpTo(far * w - 100);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('audio-clip-box-early')), findsNothing, reason: 'far out of view: not built');
    final a = tester.getTopLeft(find.byKey(const ValueKey('audio-clip-box-c1'))).dx;
    final b = tester.getTopLeft(find.byKey(const ValueKey('audio-clip-box-c2'))).dx;
    expect(a, closeTo(before + 100, 1e-6), reason: 'bar 9999 lands where the scroll puts it');
    expect(b - a, closeTo(16 * w, 1e-6));
    // Laid out relative to the window's origin: small numbers.
    final slot = tester.widget<Positioned>(find.ancestor(of: find.byKey(const ValueKey('audio-view-c1')),
        matching: find.byType(Positioned)).first);
    expect(slot.left!.abs(), lessThan(5000));
    final win = TimelineWindow.around(lanes.position.pixels, lanes.position.viewportDimension, w);
    expect(win.x(far, w), closeTo(slot.left!, 1e-9), reason: 'a fresh window after the jump');
    expect(win.shows(far, far + 8), isTrue);
    expect(win.shows(0, 8), isFalse);
    // A small scroll inside the window doesn't move it (no lane rebuilds).
    lanes.position.jumpTo(lanes.position.pixels + 40);
    await tester.pump();
    final again = tester.widget<Positioned>(find.ancestor(of: find.byKey(const ValueKey('audio-view-c1')),
        matching: find.byType(Positioned)).first);
    expect(again.left, slot.left);
  });
}
