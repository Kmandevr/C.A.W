// Goldens of the new audio screens at phone and desktop size: Arrange with audio tracks (an armed one, a selected clip
// with fades and gain), the Clip tab's audio inspector, the input sheet and Settings › Audio's input part; batch
// 1.0.4's stretch notch mid-drag and the sample editor with Slice to MIDI's lines.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sample_edit.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/audio_clip_inspector.dart';
import 'package:caw/ui/arrange/audio_input_ui.dart';
import 'package:caw/ui/arrange/audio_waveform.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/settings/audio_input_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'golden_util.dart';

ProjectDoc project() => ProjectDoc(id: 'g', name: 'Audio', bpm: 120, loopBars: 8, assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/vox.wav', name: 'Vocal take', seconds: 6, channels: 1, sourceRate: 48000),
      AudioAssetDoc(id: 'a2', path: '/abs/loop.wav', name: 'Drum loop 120bpm', seconds: 2, channels: 2, bpm: 120),
      AudioAssetDoc(id: 'a3', path: '/abs/vox2.wav', name: 'Vocal take 2', seconds: 6, channels: 1),
    ], layers: [
      LayerDoc(id: 'v', name: 'Vocal', color: 0, volume: 1, input: AudioInputDoc(armed: true), audioClips: [
        AudioClipDoc(id: 'c1', assetId: 'a1', startSteps: 8, lengthSeconds: 4, offsetSeconds: 0.5, fadeIn: 0.4,
            fadeInCurve: FadeCurve.equalPower, fadeOut: 0.8, fadeOutCurve: FadeCurve.slow, gain: 1.4, takes: ['a3', 'a1']),
      ]),
      LayerDoc(id: 'd', name: 'Drums', color: 2, volume: 1, input: AudioInputDoc(), audioClips: [
        AudioClipDoc(id: 'c2', assetId: 'a2', startSteps: 0, lengthSteps: 32, mode: AudioClipMode.musical, sourceBpm: 120,
            loop: true),
        AudioClipDoc(id: 'c3', assetId: 'a2', startSteps: 48, lengthSeconds: 2, reverse: true, mute: true),
      ]),
      LayerDoc(id: 'k', name: 'Keys', color: 4),
    ]);

void main() {
  late AppState s;
  late AudioRecorder rec;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.audioIo = FakeAudioIo();
    rec = AudioRecorder(s, prefs: AudioInputPrefs());
    WaveformCache.instance.clear();
    Motion.setting = MotionLevel.off;
  });
  tearDown(() {
    rec.dispose();
    s.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }

  // Batch 1.0.4: a stretched clip's notch mid-drag (its readout showing), and the sample editor with Slice to MIDI's
  // lines, at phone size.
  testWidgets('stretch notch mid-drag, phone', (tester) async {
    final drums = s.project.layers[1];
    // On screen at the phone's zoom: the loop moves out of the way, the reversed clip comes to the start.
    drums.audioClips.first.startSteps = 40;
    final clip = drums.audioClips.last
      ..stretchRatio = 1.5
      ..startSteps = 1
      ..lengthSeconds = 1.2
      ..mute = false;
    s.selectAudioClip(drums, clip);
    await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))),
        goldenSizes['phone']!);
    await settle(tester);
    final notch = find.byKey(const ValueKey('audio-stretch-c3'));
    final g = await tester.startGesture(tester.getCenter(notch));
    await g.moveBy(const Offset(20, 0));
    await g.moveBy(const Offset(18, 0));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/stretch_notch_phone.png'));
    await g.up();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('sample editor with slices, phone', (tester) async {
    final layer = s.project.layers.first;
    final an = FakeAudioAnalysis()..cuts = [1.0, 1.6, 2.4, 3.1, 3.9];
    s.audioAnalysis = an;
    await pumpGolden(tester, Scaffold(body: AudioClipInspector(state: s, layer: layer)), goldenSizes['phone']!);
    await settle(tester);
    final slice = find.byKey(const ValueKey('sample-tool-slice'));
    await tester.ensureVisible(slice);
    await tester.tap(slice);
    await settle(tester);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 200));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/sample_editor_phone.png'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final e in {'phone': goldenSizes['phone']!, 'desktop': goldenSizes['desktop']!}.entries) {
    testWidgets('arrange with audio, ${e.key}', (tester) async {
      s.selectAudioClip(s.project.layers.first, s.project.layers.first.audioClips.first);
      await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))),
          e.value);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/arrange_${e.key}.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('clip inspector and input settings, ${e.key}', (tester) async {
      final layer = s.project.layers.first;
      await pumpGolden(tester, Scaffold(body: Row(children: [
        Expanded(child: AudioClipInspector(state: s, layer: layer)),
        if (e.key == 'desktop') ...[
          Expanded(child: SingleChildScrollView(child: AudioInputSettings(recorder: rec))),
          Expanded(child: AudioInputPanel(state: s, layer: layer)),
        ],
      ])), e.value);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/inspector_${e.key}.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
