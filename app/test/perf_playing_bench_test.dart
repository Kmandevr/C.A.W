// Benchmarks 1.1.0's device pages while the song plays, for one simulated second at a 120 Hz display: the frames they
// ask for (motion held to 60 a second, meters to 30), the widgets rebuilt and render objects repainted, then the ⋯
// menu opened and closed over a playing page. Prints BENCH lines; the counts are asserted so they cannot grow back.
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_slot_audio.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/ui/capped_ticker.dart';
import 'package:caw/ui/crow.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/parrot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'perf_util.dart';

/// A slot meter that always has a level, so the footer's meter runs as it does while the song plays.
class _LoudSlots extends DeviceSlotAudio {
  int reads = 0;
  @override
  bool get hasMeter => true;
  @override
  bool get hasAutoGain => true;
  @override
  double? outputPeak(DeviceTarget t) {
    reads++;
    return 0.5;
  }

  @override
  bool autoGain(DeviceTarget t) => false;
  @override
  void setAutoGain(DeviceTarget t, bool v) {}
  @override
  double? autoGainTrimDb(DeviceTarget t) => null;
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
    DeviceSlotAudio.current = null;
    Motion.setting = MotionLevel.full;
  });

  // Flock's birds, Rook's pads, Chirp's note line, the Limiter's loudness area and Raven (the flagship).
  for (final id in ['org.caw.flock', 'org.caw.drums', 'org.caw.pitchfix', 'org.caw.limiter', 'org.caw.synth.flagship']) {
    testWidgets('$id page while playing, and its ⋯ menu', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final slots = _LoudSlots();
      DeviceSlotAudio.current = slots;
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
      s.sounding.value = true; // the engine plays (the poller says so in the app)
      final frame = id == 'org.caw.drums' ? (int i) => drumsFrame(peaks: {i % 16: 0.8}, note: 36 + i % 16, count: i)
          : (int i) => fakeFrame(id, tick: i);
      final playing = await countFrames(tester, 120, onFrame: (i) async {
        if (i % 4 == 0) display.frame.value = frame(i ~/ 4 + 1);
      });
      // The ⋯ menu over the playing page: opened, held a third of a second, closed with a tap outside it (half a
      // second in all).
      final menu = await countFrames(tester, 60, onFrame: (i) async {
        if (i % 4 == 0) display.frame.value = frame(100 + i ~/ 4);
        if (i == 0) await tester.tap(find.byKey(const ValueKey('device-more')).first);
        if (i == 40) await tester.tapAt(const Offset(4, 840)); // outside the menu: it closes
      });
      s.sounding.value = false;
      // ignore: avoid_print
      print('BENCH $id per second: stopped $stopped; playing $playing; menu 0.5 s $menu; meter reads ${slots.reads}');
      final c = _ceilings[id]!;
      expect(stopped.frames, lessThanOrEqualTo(1)); // still: nothing asks for frames (the battery rule)
      // Playing: motion at most 60 frames a second (MotionClock.maxHz), else the 30 display frames; never the
      // screen's 120 (1.1.1).
      expect(playing.frames, lessThanOrEqualTo(MotionClock.maxHz.round() + 2));
      expect(playing.painted, lessThanOrEqualTo(c.painted));
      expect(playing.builds, lessThanOrEqualTo(c.builds));
      // The menu's own animation asks for frames while it moves; the page under it does not rebuild for it.
      expect(menu.builds, lessThanOrEqualTo(c.menuBuilds));
      expect(menu.painted, lessThanOrEqualTo(c.menuPainted));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      s.dispose();
    });
  }

  testWidgets('a capped ticker ticks at most its rate and asks for no frames between', (tester) async {
    final ticks = <Duration>[];
    final t = CappedTicker(ticks.add, maxHz: 30);
    addTearDown(t.dispose);
    t.start();
    final c = await countFrames(tester, 120);
    t.stop();
    expect(ticks.length, inInclusiveRange(29, 31)); // one simulated second at 120 Hz
    expect(c.frames, lessThanOrEqualTo(31));
    expect(ticks[1] - ticks[0], greaterThanOrEqualTo(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
  });

  testWidgets('the crow loader draws at most 30 frames a second, and none with Motion Off', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Center(child: CrowLoader())));
    final full = await countFrames(tester, 120);
    expect(full.frames, lessThanOrEqualTo(31));
    expect(full.painted, lessThanOrEqualTo(31 * 2)); // its boundary and its painter, nothing around it
    Motion.setting = MotionLevel.off;
    await tester.pumpWidget(const MaterialApp(home: Center(child: CrowLoader(key: ValueKey('off')))));
    await tester.pump();
    final off = await countFrames(tester, 120);
    expect(off.frames, 0);
  });

  testWidgets('Parrot steps at most 20 times a second and keeps the app under it when it turns off', (tester) async {
    final key = GlobalKey();
    Widget app(bool on) => MaterialApp(home: ParrotGlow(on: on, child: SizedBox.expand(key: key)));
    await tester.pumpWidget(app(true));
    final c = await countFrames(tester, 120);
    expect(c.frames, lessThanOrEqualTo(21));
    final before = key.currentContext;
    await tester.pumpWidget(app(false));
    expect(identical(key.currentContext, before), isTrue); // the same element: nothing rebuilt from scratch
    final off = await countFrames(tester, 120);
    expect(off.frames, 0);
  });
}

/// Each page's ceilings in the playing second and the menu's half second, about 10 % over what 1.1.1 measured
/// (docs/performance.md, "Playback spikes and UI load (1.1.1)"). Before 1.1.1, a page with a slot meter asked for
/// 119 frames a second even stopped, Flock's playing second repainted 14,940 render objects (its motion relaid out
/// the page) and the menu's half second 17,700 to 24,700 (the ⋯ button's ripple repainted the whole page).
const _ceilings = <String, ({int painted, int builds, int menuPainted, int menuBuilds})>{
  'org.caw.flock': (painted: 6600, builds: 270, menuPainted: 19500, menuBuilds: 770),
  'org.caw.drums': (painted: 1200, builds: 40, menuPainted: 16800, menuBuilds: 650),
  'org.caw.pitchfix': (painted: 780, builds: 70, menuPainted: 16600, menuBuilds: 670),
  'org.caw.limiter': (painted: 800, builds: 530, menuPainted: 16600, menuBuilds: 900),
  'org.caw.synth.flagship': (painted: 40, builds: 40, menuPainted: 16200, menuBuilds: 640),
};
