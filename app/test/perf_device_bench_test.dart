// Benchmarks an open device editor with full motion, for one simulated second at a 120 Hz display: how many frames
// it asks for, how many widgets rebuild and how many render objects repaint, stopped (no display data) and playing
// (display frames at 30 Hz), each frame's build, layout and paint time and the screen's raster; then 20 live steps
// of a value and of a knob. Prints BENCH lines; the counts are asserted so they cannot grow back.
import 'package:caw/engine/component_info.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/ui/devices/device_controls.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'perf_util.dart';

void main() {
  final display = FakeDisplay();
  late DeviceDisplaySource source;
  setUp(() {
    source = DeviceDisplaySource.current;
    DeviceDisplaySource.current = display;
  });
  tearDown(() {
    DeviceDisplaySource.current = source;
    Motion.setting = MotionLevel.full;
  });

  for (final id in ['org.caw.eq', 'org.caw.compressor', 'org.caw.delay.pingpong', 'org.caw.phaser',
    'org.caw.synth.flagship']) {
    testWidgets('$id editor, stopped and playing', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = stateWith(id, make: PreviewState.new);
      Motion.setting = MotionLevel.full;
      display.frame.value = null;
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      }))));
      openDevice(ctx, s, id);
      for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 20)); }
      final stopped = await countFrames(tester, 120);
      // A finger held on the editor (beside its controls) lets the motion move with the song stopped.
      final finger = await tester.startGesture(const Offset(2, 420));
      final touched = await countFrames(tester, 120);
      await finger.up();
      await tester.pump();
      s.sounding.value = true; // the engine plays (the poller says so in the app)
      final playing = await countFrames(tester, 120, onFrame: (i) async {
        if (i % 4 == 0) display.frame.value = fakeFrame(id, tick: i ~/ 4 + 1);
      });
      final raster = await rasterMs(tester);
      s.sounding.value = false;
      await tester.pump();
      // A value moved: 20 live steps of the device's first parameter, one a frame; then a knob turned, the first
      // knob on the page (the editor's own visuals that show its value rebuild with it, the rest doesn't).
      final t = targetOf(s, id);
      final p = t.info!.parameters.first;
      Motion.setting = MotionLevel.off; // count the knob's own work, not the motion
      await tester.pump();
      Future<FrameCount> turn(ComponentParameterInfo p) async {
        final c = await countFrames(tester, 20, onFrame: (i) async => t.setLive(p.id, p.min + (p.max - p.min) * i / 20));
        t.commit();
        await tester.pump(const Duration(seconds: 1));
        return c;
      }
      final first = await turn(p);
      final knobId = tester.widgetList<DeviceKnob>(find.byType(DeviceKnob)).first.paramId;
      final knob = await turn(t.param(knobId)!);
      // ignore: avoid_print
      print('BENCH $id per second: stopped $stopped; touched $touched; playing $playing (raster ${raster.toStringAsFixed(2)} ms); '
          'first parameter 20 steps: $first; knob $knobId 20 steps: $knob');
      // Motion runs on every frame while the engine sounds or a finger is down (beta plan B3) and repaints its own
      // visual alone (B4); stopped, silent and untouched it asks for none (the battery rule). The display data
      // still comes at 30 Hz. Ceilings (B5): the counts are exact in the test VM.
      final c = _ceilings[id]!;
      expect(stopped.frames, 0);
      expect(touched.frames, c.motion ? greaterThanOrEqualTo(119) : lessThanOrEqualTo(1));
      expect(playing.frames, lessThanOrEqualTo(c.motion ? 121 : 31));
      expect(stopped.painted, lessThanOrEqualTo(c.stoppedPainted));
      expect(playing.painted, lessThanOrEqualTo(c.playingPainted));
      expect(knob.builds, lessThanOrEqualTo(c.knobBuilds));
      expect(first.builds, lessThanOrEqualTo(c.firstBuilds));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      s.dispose();
    });
  }
}

/// Each editor's ceilings: whether it has motion, render objects painted in the stopped and playing second, and
/// widgets rebuilt by 20 steps of its first parameter and of its first knob (measured in docs/performance.md).
const _ceilings = <String, ({bool motion, int stoppedPainted, int playingPainted, int firstBuilds, int knobBuilds})>{
  'org.caw.eq': (motion: false, stoppedPainted: 10, playingPainted: 830, firstBuilds: 12400, knobBuilds: 3800),
  'org.caw.compressor': (motion: false, stoppedPainted: 10, playingPainted: 500, firstBuilds: 1200, knobBuilds: 1200),
  'org.caw.delay.pingpong': (motion: true, stoppedPainted: 10, playingPainted: 1560, firstBuilds: 7950, knobBuilds: 1720),
  'org.caw.phaser': (motion: true, stoppedPainted: 10, playingPainted: 1520, firstBuilds: 2050, knobBuilds: 1220),
  'org.caw.synth.flagship': (motion: true, stoppedPainted: 10, playingPainted: 270, firstBuilds: 16100, knobBuilds: 1240),
};
