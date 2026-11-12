// Tests the playhead between engine reads (PlayheadClock) with a fake clock: running on between reads, settling onto
// the next read without running backwards, loop wraps, seeks, a held start, and stop.
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/playhead_clock.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/live_playhead.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 120 BPM: 8 sixteenth steps a second, 0.008 steps a millisecond. Reads every 33 ms.
  const sps = 8.0;
  const ms = 1000; // µs
  late PlayheadClock c;
  late int now;

  void read(double step, {bool playing = true, double from = 0, double to = 64}) =>
      c.read(step: step, atUs: now, playing: playing, stepsPerSecond: sps, from: from, to: to);

  // Starts playing at [step], with one moving read so the line runs.
  void start(double step, {double from = 0, double to = 64}) {
    read(step, from: from, to: to);
    now += 33 * ms;
    read(step + 0.264, from: from, to: to);
  }

  setUp(() {
    c = PlayheadClock();
    now = 1000000;
  });

  test('between reads it runs on at the tempo from the last read', () {
    start(10);
    final at = c.at(now);
    expect(at, closeTo(10.264, 1e-9));
    expect(c.at(now + 8 * ms), closeTo(10.264 + 0.064, 1e-9), reason: 'a 120 Hz frame later');
    expect(c.at(now + 25 * ms), closeTo(10.264 + 0.2, 1e-9));
    // Reads that stop coming: it runs on at most 100 ms, then holds.
    expect(c.at(now + 500 * ms), closeTo(10.264 + 0.8, 1e-9));
  });

  test('the first read holds; it runs once the reads move (a count-in or a compensated start)', () {
    read(4);
    expect(c.at(now + 20 * ms), 4);
    now += 33 * ms;
    read(4);
    expect(c.at(now + 20 * ms), 4, reason: 'still not moving');
    now += 33 * ms;
    read(4.1);
    expect(c.at(now), 4.1);
    expect(c.at(now + 10 * ms), closeTo(4.18, 1e-9));
  });

  test('the next read is settled onto gently, never running backwards', () {
    start(10);
    // The engine is 4 ms behind where the line ran (jitter): the line is ahead by 0.032 steps.
    final before = c.at(now + 33 * ms);
    now += 33 * ms;
    read(10.264 + 0.264 - 0.032);
    expect(c.at(now), closeTo(before, 1e-9), reason: 'no jump at the read');
    expect(c.settling, closeTo(0.032, 1e-9));
    var last = c.at(now);
    for (var t = 1; t <= 400; t++) {
      final x = c.at(now + t * ms);
      expect(x, greaterThanOrEqualTo(last), reason: 'never backwards ($t ms)');
      last = x;
    }
    // Settled: 100 ms on, the line is where the engine is (to within a hundredth of a step).
    expect(c.at(now + 100 * ms), closeTo(10.496 + 0.8, 0.01));
    // The largest gentle error, the snap limit, still never runs backwards.
    final d = PlayheadClock();
    d.read(step: 0, atUs: 0, playing: true, stepsPerSecond: sps, to: 64);
    d.read(step: 0.264, atUs: 33 * ms, playing: true, stepsPerSecond: sps, to: 64);
    d.read(step: 0.528 - 0.008 * 59, atUs: 66 * ms, playing: true, stepsPerSecond: sps, to: 64);
    var prev = d.at(66 * ms);
    for (var t = 67; t < 166; t++) {
      expect(d.at(t * ms), greaterThanOrEqualTo(prev));
      prev = d.at(t * ms);
    }
  });

  test('a loop wrap is exact: the line wraps at the end and the read after it is no jump', () {
    // A loop from 16 to 32.
    start(31.6, from: 16, to: 32);
    expect(c.at(now), closeTo(31.864, 1e-9));
    expect(c.at(now + 16 * ms), closeTo(31.992, 1e-9));
    expect(c.at(now + 18 * ms), closeTo(16.008, 1e-9), reason: 'past the end it is the loop start, exactly');
    expect(c.at(now + 25 * ms), closeTo(16.064, 1e-9));
    final shown = c.at(now + 33 * ms);
    now += 33 * ms;
    read(16.128); // the engine wrapped too
    expect(c.at(now), closeTo(shown, 1e-9));
    expect(c.settling.abs(), lessThan(1e-9));
    // The read after that keeps the error small, inside the loop.
    now += 33 * ms;
    read(16.392 + 0.004);
    expect(c.at(now), inInclusiveRange(16, 32));
    expect(c.settling.abs(), lessThan(0.01));
  });

  test('a seek or a jump back to the start snaps there, then runs on from it', () {
    start(40);
    now += 33 * ms;
    read(0); // back to the start
    expect(c.at(now), 0);
    expect(c.at(now + 20 * ms), 0, reason: 'held until the reads show it running');
    now += 33 * ms;
    read(0.264);
    expect(c.at(now), 0.264);
    expect(c.at(now + 10 * ms), closeTo(0.344, 1e-9));
    // A seek forwards.
    now += 33 * ms;
    read(20);
    expect(c.at(now), 20);
  });

  test('stop and pause show the read position exactly, without running on', () {
    start(12);
    now += 33 * ms;
    read(0, playing: false);
    expect(c.playing, isFalse);
    expect(c.at(now), 0);
    expect(c.at(now + 500 * ms), 0);
    // Paused at 12.5, then playing again from there.
    read(12.5, playing: false);
    expect(c.at(now + 30 * ms), 12.5);
    read(12.5);
    expect(c.at(now + 30 * ms), 12.5);
  });

  test('a tempo change snaps to the read at the new rate', () {
    start(8);
    now += 33 * ms;
    c.read(step: 8.6, atUs: now, playing: true, stepsPerSecond: 16, to: 64);
    expect(c.at(now), 8.6);
  });

  testWidgets('PlayheadFrames draws every frame while playing, from the clock, and asks for none when stopped',
      (tester) async {
    var clock = 0;
    final s = AppState(settings: Settings(), clockUs: () => clock);
    final drawn = <double>[];
    await tester.pumpWidget(PlayheadFrames(state: s, builder: (_) {
      drawn.add(s.smoothPlayheadStep);
      return const SizedBox();
    }));
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'stopped: no frames');
    // Playing: two moving reads (8 steps a second at 120 BPM), then frames between reads move the line on.
    s.meters = const EngineMeters(playing: true, position: 0, loopLength: 64);
    s.playheadClock.read(step: 0, atUs: clock, playing: true, stepsPerSecond: 8, to: 64);
    clock += 33000;
    s.playheadClock.read(step: 0.264, atUs: clock, playing: true, stepsPerSecond: 8, to: 64);
    s.tick.value++;
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue, reason: 'the ticker runs while playing');
    drawn.clear();
    for (var i = 1; i <= 3; i++) {
      clock += 8000;
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(drawn, hasLength(3), reason: 'one build per frame, between reads');
    expect(drawn.last, closeTo(0.264 + 0.192, 1e-9));
    // Stopped: the ticker stops, so no more frames are asked for (Auto's idle drop can come).
    s.meters = const EngineMeters();
    s.tick.value++;
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    s.dispose();
  });
}
