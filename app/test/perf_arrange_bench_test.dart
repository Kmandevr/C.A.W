// Benchmarks the arranger body on a 16-track project with 8 clips a track (notes drawn in the clips) and an audio
// track of four long clips (waveforms): a second of playback, a sideways scroll, a vertical scroll and a two-finger
// time zoom, at a 120 Hz display. Counts frames, widget rebuilds and render objects painted, times each frame's
// build, layout and paint and the screen's raster, and asserts ceilings so they can't grow back. Prints BENCH lines.
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/audio_waveform.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'perf_fixture.dart';
import 'perf_util.dart';

void main() {
  testWidgets('arranger: play, scroll and zoom 16 tracks of clips and an audio track', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    WaveformCache.instance.clear();
    var clock = 0;
    final s = AppState(settings: Settings(), clockUs: () => clock);
    s.audioIo = FakeAudioIo()..seconds['/abs/loop.wav'] = 64;
    final p = bigProject(s);
    p.assets.add(AudioAssetDoc(id: 'a1', path: '/abs/loop.wav', name: 'loop', seconds: 64, channels: 2));
    p.layers.insert(1, LayerDoc(id: 'audio', name: 'Audio', color: 3, input: AudioInputDoc(), audioClips: [
      for (var c = 0; c < 4; c++)
        AudioClipDoc(id: 'ac$c', assetId: 'a1', startSteps: c * 128.0, lengthSeconds: 16, offsetSeconds: c * 4.0),
    ]));
    s.project = p;
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // the waveforms' peaks are in
    final lanes = tester.getCenter(find.byType(ArrangerScreen)) + const Offset(60, 0);

    // A second of playback at 120 Hz: an engine read every 33 ms (the poller's, as AppState makes it) moves the
    // playhead on, and the line runs on between reads at the screen's rate.
    final playing = await countFrames(tester, 120, onFrame: (i) async {
      clock = i * 8333;
      if (i % 4 != 0) return;
      s.meters = EngineMeters(playing: true, loopLength: 1 << 20, position: i * 1000, cpu: 0.2);
      s.playheadClock.read(step: i * 8333 * 8 / 1e6, atUs: clock, playing: true, stepsPerSecond: 8, to: 4096);
      s.tick.value++;
    });
    final playRaster = await rasterMs(tester);
    s.meters = const EngineMeters();
    s.playheadClock.read(step: 8, atUs: clock, playing: false, stepsPerSecond: 8, to: 4096);
    s.tick.value++;
    await tester.pump(const Duration(seconds: 2));

    // A scroll frame as a fling makes it: the position moves (a drag on the lanes would grab a clip).
    // The longest scroller on that axis: the timeline sideways, the tracks up and down.
    ScrollPosition scroller(Axis axis) => tester.stateList<ScrollableState>(find.byType(Scrollable))
        .where((st) => axisDirectionToAxis(st.axisDirection) == axis)
        .map((st) => st.position)
        .reduce((a, b) => a.maxScrollExtent >= b.maxScrollExtent ? a : b);
    Future<FrameCount> scroll(Axis axis, double by) async {
      final p = scroller(axis);
      final c = await countFrames(tester, 30, onFrame: (_) async => p.jumpTo(p.pixels + by));
      await tester.pump(const Duration(seconds: 2));
      return c;
    }

    final sideways = await scroll(Axis.horizontal, 12);
    final scrollRaster = await rasterMs(tester);
    final vertical = await scroll(Axis.vertical, 10);
    final a = await tester.startGesture(lanes - const Offset(40, 0), pointer: 7);
    final b = await tester.startGesture(lanes + const Offset(40, 0), pointer: 8);
    await tester.pump(const Duration(milliseconds: 20));
    final zoom = await countFrames(tester, 30, onFrame: (_) async {
      await a.moveBy(const Offset(-3, 0));
      await b.moveBy(const Offset(3, 0));
    });
    final zoomRaster = await rasterMs(tester);
    await a.up();
    await b.up();
    // The frame the pinch ends in: the lanes laid out once at the new zoom.
    final release = await countFrames(tester, 2);
    await tester.pump(const Duration(seconds: 2));
    String ms(double v) => v.toStringAsFixed(2);
    // ignore: avoid_print
    print('BENCH arranger 120 frames playing: $playing; raster ${ms(playRaster)} ms');
    // ignore: avoid_print
    print('BENCH arranger 30 frames: sideways scroll $sideways (raster ${ms(scrollRaster)} ms); '
        'vertical scroll $vertical; pinch zoom $zoom (raster ${ms(zoomRaster)} ms); pinch release $release');
    // Ceilings (B5 of the beta readiness plan): counts are exact in the test VM; times get room for a busy machine.
    expect(playing.builds, lessThanOrEqualTo(_ceil.playBuilds));
    expect(playing.painted, lessThanOrEqualTo(_ceil.playPainted));
    expect(sideways.painted, lessThanOrEqualTo(_ceil.scrollPainted));
    expect(vertical.painted, lessThanOrEqualTo(_ceil.verticalPainted));
    expect(zoom.builds, lessThanOrEqualTo(_ceil.zoomBuilds));
    expect(zoom.painted, lessThanOrEqualTo(_ceil.zoomPainted));
    expect(playing.frameMs, lessThan(_ceil.playMs));
    expect(zoom.frameMs, lessThan(_ceil.zoomMs));
    s.dispose();
  });
}

/// The ceilings the arranger bench asserts (measured numbers in docs/performance.md, with room above them).
const _ceil = (
  playBuilds: 260,
  playPainted: 720,
  scrollPainted: 450,
  verticalPainted: 0,
  zoomBuilds: 6500,
  zoomPainted: 8000,
  playMs: 40.0,
  zoomMs: 200.0,
);
