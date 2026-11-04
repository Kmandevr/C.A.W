// Tests the motion rules: the motion setting, distance-aware settle times, the overshoot curve, snapping maths and
// saving the motion, haptics and glow settings.
import 'dart:io';

import 'package:caw/model/settings.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    Motion.setting = MotionLevel.full;
    Motion.haptics = true;
    Motion.minimalProfile = false;
    Neon.performanceMode = PerformanceMode.balanced.index;
    Neon.light = false;
    Neon.showScopes = true;
  });

  group('settle duration', () {
    test('grows logarithmically with distance, between 80 and 240 ms', () {
      expect(Motion.settle(0), const Duration(milliseconds: 80));
      expect(Motion.settle(8).inMilliseconds, 120);
      expect(Motion.settle(64).inMilliseconds, inInclusiveRange(206, 207));
      expect(Motion.settle(100000), const Duration(milliseconds: 240));
      expect(Motion.settle(-8), Motion.settle(8));
    });

    test('a longer move is faster in pixels per millisecond', () {
      double speed(double d) => d / Motion.settle(d).inMicroseconds;
      expect(speed(16), lessThan(speed(64)));
      expect(speed(64), lessThan(speed(256)));
    });
  });

  group('overshoot', () {
    test('is at most 2 px, or 4% when that is smaller', () {
      expect(Motion.overshoot(0), 0);
      expect(Motion.overshoot(10), closeTo(0.04, 1e-12)); // 4% of 10 px is 0.4 px
      expect(Motion.overshoot(100), closeTo(0.02, 1e-12)); // 2 px of 100 px
      expect(Motion.overshoot(100) * 100, closeTo(2, 1e-9));
    });

    test('the curve starts at 0, ends at 1 and peaks exactly at 1 + amount', () {
      for (final amount in [0.0, 0.01, 0.02, 0.04]) {
        final c = OvershootCurve(amount);
        expect(c.transform(0), closeTo(0, 1e-12));
        expect(c.transform(1), closeTo(1, 1e-12));
        var peak = 0.0;
        for (var i = 0; i <= 2000; i++) {
          final v = c.transform(i / 2000);
          if (v > peak) peak = v;
        }
        expect(peak, closeTo(1 + amount, 1e-6), reason: 'amount $amount');
      }
    });

    test('with no overshoot the curve never passes the end', () {
      final c = OvershootCurve(0);
      for (var i = 0; i <= 100; i++) {
        expect(c.transform(i / 100), lessThanOrEqualTo(1 + 1e-12));
      }
    });
  });

  group('motion level', () {
    test('Minimal turns motion off, and the system setting caps it at Reduced', () {
      expect(Motion.effective(), MotionLevel.full);
      expect(Motion.effective(systemReduce: true), MotionLevel.reduced);
      Motion.setting = MotionLevel.off;
      expect(Motion.effective(systemReduce: true), MotionLevel.off);
      Motion.setting = MotionLevel.full;
      Motion.minimalProfile = true;
      expect(Motion.effective(), MotionLevel.off);
    });

    test('Reduced keeps fades but not movement; Off keeps neither', () {
      const d = Duration(milliseconds: 160);
      expect(Motion.move(d, MotionLevel.full), d);
      expect(Motion.move(d, MotionLevel.reduced), Duration.zero);
      expect(Motion.fade(d, MotionLevel.reduced), d);
      expect(Motion.fade(d, MotionLevel.off), Duration.zero);
      expect(Motion.settleCurve(50, MotionLevel.reduced), Curves.linear);
      expect(Motion.settleCurve(50, MotionLevel.full), isA<OvershootCurve>());
    });

    testWidgets('of(context) follows the platform disable-animations flag', (tester) async {
      MotionLevel? seen;
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(builder: (context) {
          seen = Motion.of(context);
          return const SizedBox();
        }),
      ));
      expect(seen, MotionLevel.reduced);
    });
  });

  group('snap', () {
    test('rounds to the grid, and a zero grid leaves the value alone', () {
      expect(Snap.to(13, 8), 16);
      expect(Snap.to(11.9, 8), 8);
      expect(Snap.to(-5, 4), -4);
      expect(Snap.to(13.3, 0), 13.3);
    });

    test('nearness is 1 on a grid line and 0 at the reach', () {
      expect(Snap.nearness(16, 8, 4), 1);
      expect(Snap.nearness(18, 8, 4), closeTo(0.5, 1e-12));
      expect(Snap.nearness(20, 8, 4), 0);
      expect(Snap.nearness(20, 0, 4), 0);
    });
  });

  group('settings', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw_motion'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('defaults: full motion, haptics on, subtle glow', () async {
      final s = await Settings.open(base: dir);
      expect(s.motion, MotionLevel.full);
      expect(s.haptics, isTrue);
      expect(s.reactiveGlow, 0.35);
    });

    test('motion, haptics and glow are saved, loaded and applied', () async {
      final s = await Settings.open(base: dir);
      await s.update((x) {
        x.motion = MotionLevel.reduced;
        x.haptics = false;
        x.reactiveGlow = 0.8;
      });
      expect(Motion.setting, MotionLevel.reduced);
      expect(Motion.haptics, isFalse);
      Motion.setting = MotionLevel.full;
      Motion.haptics = true;
      final back = await Settings.open(base: dir);
      expect(back.motion, MotionLevel.reduced);
      expect(back.haptics, isFalse);
      expect(back.reactiveGlow, 0.8);
      expect(Motion.setting, MotionLevel.reduced);
    });

    test('the Minimal profile turns motion off', () async {
      final s = await Settings.open(base: dir);
      await s.update((x) => x.performanceMode = PerformanceMode.minimal);
      expect(Motion.effective(), MotionLevel.off);
    });

    test('a damaged glow value falls back to the default, and out-of-range values are clamped', () async {
      final s = Settings();
      s.fromJson({'reactive_glow': 'loud', 'motion': 'wobbly'});
      expect(s.reactiveGlow, 0.35);
      expect(s.motion, MotionLevel.full);
      s.fromJson({'reactive_glow': 7});
      expect(s.reactiveGlow, 1.0);
    });

    test('adjust shows a change without saving it', () async {
      final s = await Settings.open(base: dir);
      s.adjust((x) => x.reactiveGlow = 0.1);
      expect(s.reactiveGlow, 0.1);
      expect(File('${dir.path}${Platform.pathSeparator}settings.json').existsSync(), isFalse);
      await s.save();
      expect((await Settings.open(base: dir)).reactiveGlow, 0.1);
    });
  });
}
