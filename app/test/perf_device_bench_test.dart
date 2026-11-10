// Benchmarks an open device editor with full motion, for one simulated second at a 120 Hz display: how many frames
// it asks for, how many widgets rebuild and how many render objects repaint, stopped (no display data) and playing
// (display frames at 30 Hz). Prints BENCH lines; the frame counts are checked so they cannot grow back.
import 'package:caw/model/device_display.dart';
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
      final playing = await countFrames(tester, 120, onFrame: (i) async {
        if (i % 4 == 0) display.frame.value = fakeFrame(id, tick: i ~/ 4 + 1);
      });
      // A knob turned: 20 live steps of the device's first parameter, one a frame.
      final t = targetOf(s, id);
      final p = t.info!.parameters.first;
      Motion.setting = MotionLevel.off; // count the knob's own work, not the motion
      await tester.pump();
      final knob = await countFrames(tester, 20, onFrame: (i) async => t.setLive(p.id, p.min + (p.max - p.min) * i / 20));
      t.commit();
      // ignore: avoid_print
      print('BENCH $id per second: stopped $stopped; playing $playing; knob 20 steps: $knob');
      // Motion runs at the display data's 30 Hz: a Ticker here asked for every one of the 120 frames.
      expect(stopped.frames, lessThanOrEqualTo(31));
      expect(playing.frames, lessThanOrEqualTo(62));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      s.dispose();
    });
  }
}
