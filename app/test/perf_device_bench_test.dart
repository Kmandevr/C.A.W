// Benchmarks an open device editor with full motion, for one simulated second at a 120 Hz display: how many frames
// it asks for, how many widgets rebuild and how many render objects repaint, stopped (no display data) and playing
// (display frames at 30 Hz). Prints BENCH lines; the frame counts are checked so they cannot grow back.
import 'package:caw/model/device_display.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';

class Bench {
  int frames = 0, builds = 0, painted = 0;
}

/// One simulated second in 120 frames of 8.33 ms; [onFrame] runs before each (it may set display data). A frame
/// counts when something asked for it (built, painted or a ticker wanted it); repaints are the render objects painted (Flutter's paint profiling).
Future<Bench> runSecond(WidgetTester tester, {void Function(int frame)? onFrame}) async {
  final b = Bench();
  w.debugOnRebuildDirtyWidget = (_, _) => b.builds++;
  debugProfilePaintsEnabled = true;
  FlutterTimeline.debugCollectionEnabled = true;
  FlutterTimeline.debugReset();
  var wanted = false; // the last frame asked for the next (a running Ticker does, every refresh)
  for (var i = 0; i < 120; i++) {
    onFrame?.call(i);
    final built = b.builds;
    await tester.pump(const Duration(microseconds: 8333));
    var painted = 0;
    for (final t in FlutterTimeline.debugCollect().timedBlocks) {
      if (t.name.startsWith('Render')) painted++;
    }
    FlutterTimeline.debugReset();
    if (wanted || painted > 0 || b.builds > built) b.frames++;
    wanted = SchedulerBinding.instance.hasScheduledFrame;
    b.painted += painted;
  }
  FlutterTimeline.debugCollectionEnabled = false;
  debugProfilePaintsEnabled = false;
  w.debugOnRebuildDirtyWidget = null;
  return b;
}

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
      final stopped = await runSecond(tester);
      final playing = await runSecond(tester, onFrame: (i) {
        if (i % 4 == 0) display.frame.value = fakeFrame(id, tick: i ~/ 4 + 1);
      });
      // ignore: avoid_print
      print('BENCH $id per second: stopped ${stopped.frames} frames, ${stopped.builds} builds, ${stopped.painted} '
          'repainted; playing ${playing.frames} frames, ${playing.builds} builds, ${playing.painted} repainted');
      // Motion runs at the display data's 30 Hz: a Ticker here asked for every one of the 120 frames.
      expect(stopped.frames, lessThanOrEqualTo(31));
      expect(playing.frames, lessThanOrEqualTo(62));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      s.dispose();
    });
  }
}
