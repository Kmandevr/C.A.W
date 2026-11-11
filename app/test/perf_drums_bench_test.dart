// Benchmarks the Drums editor (10392 parameters): frames asked for stopped and playing, widgets rebuilt and the wall time of a knob turn, a pad pick and a bank switch, full screen and inline. Prints BENCH lines; frame counts and rebuilds are checked so they cannot grow back.
import 'package:caw/model/device_display.dart';
import 'package:caw/model/drums.dart';
import 'package:caw/ui/devices/device_inline.dart';
import 'package:caw/ui/devices/drums/drums_pads.dart';
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
    DrumsSelection.reset();
  });
  tearDown(() {
    DeviceDisplaySource.current = source;
    Motion.setting = MotionLevel.full;
  });

  /// Wall time of [frames] frames, each after [step] (ms per frame).
  Future<double> timed(WidgetTester tester, int frames, Future<void> Function(int i) step) async {
    final w = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      await step(i);
      await tester.pump(const Duration(milliseconds: 16));
    }
    return w.elapsedMicroseconds / 1000 / frames;
  }

  testWidgets('the drums editor, stopped, playing, a knob, a pad and a bank', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = stateWith(drumsComponentId, make: PreviewState.new);
    Motion.setting = MotionLevel.full;
    display.frame.value = null;
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    }))));
    final open = Stopwatch()..start();
    openDevice(ctx, s, drumsComponentId);
    await tester.pump();
    final firstBuild = open.elapsedMicroseconds / 1000;
    for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 20)); }
    final stopped = await countFrames(tester, 120);
    final playing = await countFrames(tester, 120, onFrame: (i) async {
      if (i % 4 == 0) display.frame.value = drumsFrame(peaks: {0: (i % 16) / 16, 2: 0.5}, shown: 0);
    });
    final t = targetOf(s, drumsComponentId);
    Motion.setting = MotionLevel.off;
    await tester.pump();
    final knob = await countFrames(tester, 20, onFrame: (i) async => t.setLive('a1_body_decay', 0.2 + i * 0.05));
    final knobMs = await timed(tester, 20, (i) async => t.setLive('a1_body_decay', 1.2 - i * 0.05));
    t.commit();
    final sel = DrumsSelection.of(t);
    final padMs = await timed(tester, 16, (i) async => sel.select(t, i));
    final bankMs = await timed(tester, 8, (i) async => sel.bank.value = i % 4);
    // ignore: avoid_print
    print('BENCH org.caw.drums editor: first build ${firstBuild.toStringAsFixed(1)} ms; per second stopped $stopped; '
        'playing $playing; knob 20 steps: $knob, ${knobMs.toStringAsFixed(2)} ms a frame; pad pick '
        '${padMs.toStringAsFixed(2)} ms; bank switch ${bankMs.toStringAsFixed(2)} ms');
    expect(stopped.frames, lessThanOrEqualTo(31));
    expect(playing.frames, lessThanOrEqualTo(62));
    // A knob turn rebuilds what is on screen, not the 64 pads' 10392 knobs (the flagship's 140 knobs: about 1370).
    expect(knob.builds / 20, lessThan(1500));
    // Playing, the pads' lights and the hero repaint alone (live islands), not the page around them.
    expect(playing.painted / 30, lessThan(60));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    s.dispose();
  });

  testWidgets('the drums inline, playing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = stateWith(drumsComponentId, make: PreviewState.new);
    Motion.setting = MotionLevel.full;
    final t = targetOf(s, drumsComponentId);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DeviceInline(target: t)))));
    for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 20)); }
    final playing = await countFrames(tester, 120, onFrame: (i) async {
      if (i % 4 == 0) display.frame.value = drumsFrame(peaks: {0: (i % 16) / 16}, shown: 0);
    });
    // ignore: avoid_print
    print('BENCH org.caw.drums inline per second playing $playing');
    expect(playing.frames, lessThanOrEqualTo(62));
    // The pads' lights repaint from the frames; the grid itself doesn't rebuild for them.
    expect(playing.builds / 30, lessThan(20));
    expect(playing.painted / 30, lessThan(60));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    s.dispose();
  });

  testWidgets('baseline: the flagship editor, a knob turned the same way', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const id = 'org.caw.synth.flagship';
    final s = stateWith(id, make: PreviewState.new);
    Motion.setting = MotionLevel.off;
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    }))));
    openDevice(ctx, s, id);
    for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 20)); }
    final t = targetOf(s, id);
    final p = t.info!.parameters.first;
    final ms = await timed(tester, 20, (i) async => t.setLive(p.id, p.min + (p.max - p.min) * i / 20));
    t.commit();
    // ignore: avoid_print
    print('BENCH org.caw.synth.flagship knob (baseline): ${ms.toStringAsFixed(2)} ms a frame');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    s.dispose();
  });
}
