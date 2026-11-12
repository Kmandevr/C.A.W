// Tests the frame-rate setting: saving and migrating it, the choices a screen's rates allow, Auto's idle drop with a
// fake clock, timer and display, a fixed cap, Android's channel (mocked), and the Settings row.
import 'dart:async';
import 'dart:io';

import 'package:caw/model/settings.dart';
import 'package:caw/platform/display_rate.dart';
import 'package:caw/ui/frame_rate.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDisplay implements DisplayRateDevice {
  _FakeDisplay(this.rates, {this.canRequest = true});
  final List<double> rates;
  @override
  final bool canRequest;
  final asked = <double>[];
  @override
  Future<List<double>> supportedRates() async => rates;
  @override
  Future<void> request(double hz) async => asked.add(hz);
}

/// One-shot timers fired by hand: [fireDue] runs those due by [now].
class _FakeTimers {
  Duration now = Duration.zero;
  final pending = <(Duration, void Function(), _FakeTimer)>[];

  Timer make(Duration after, void Function() fire) {
    final t = _FakeTimer();
    pending.add((now + after, fire, t));
    return t;
  }

  void advance(Duration d) {
    now += d;
    for (final p in [...pending]) {
      if (p.$1 <= now && p.$3.isActive) {
        pending.remove(p);
        p.$3.isActive = false;
        p.$2();
      }
    }
    pending.removeWhere((p) => !p.$3.isActive);
  }
}

class _FakeTimer implements Timer {
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
  @override
  int get tick => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('setting', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw_frame_rate'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('Auto by default; a cap is saved and loaded back', () async {
      final s = await Settings.open(base: dir);
      expect(s.frameRate, FrameRateController.auto);
      await s.update((x) => x.frameRate = 120);
      final back = await Settings.open(base: dir);
      expect(back.frameRate, 120);
    });

    test('a file from before the setting, or with an unknown value, is Auto', () {
      final s = Settings()..fromJson({'theme': 'Neon'});
      expect(s.frameRate, FrameRateController.auto);
      for (final bad in [75, -1, 'fast', 1e9, null]) {
        final t = Settings()..fromJson({'frame_rate': bad});
        expect(t.frameRate, FrameRateController.auto, reason: '$bad');
      }
      expect((Settings()..fromJson({'frame_rate': 90})).frameRate, 90);
      expect(Settings().toJson()['frame_rate'], 0);
    });

    test('applying the settings sets the controller\'s cap', () async {
      final display = _FakeDisplay([60, 120]);
      final c = FrameRateController(device: display);
      FrameRateController.current = c;
      addTearDown(() => FrameRateController.current = null);
      await c.start(attach: false);
      final s = Settings();
      await s.update((x) => x.frameRate = 60);
      expect(c.cap, 60);
      expect(display.asked.last, 60);
      c.dispose();
    });
  });

  test('choices: Auto and only the caps the screen has', () {
    expect(FrameRateController.choicesFor([60, 120]), [0, 60, 120]);
    expect(FrameRateController.choicesFor([59.94, 90.0]), [0, 60, 90]);
    expect(FrameRateController.choicesFor([48, 60, 96, 120, 144, 240]), [0, 60, 120, 144, 240]);
    expect(FrameRateController.choicesFor([]), [0]);
    expect(FrameRateController.choicesFor([60, 120], canRequest: false), [0], reason: 'Windows: no cap');
    expect(FrameRateController.rateFor(90, [60, 120]), 60);
    expect(FrameRateController.rateFor(240, [60, 120]), 120);
    expect(FrameRateController.rateFor(60, [90, 120]), 90, reason: 'none at or under the cap: the lowest');
  });

  group('Auto', () {
    late _FakeDisplay display;
    late _FakeTimers timers;
    late FrameRateController c;

    setUp(() async {
      display = _FakeDisplay([60, 120]);
      timers = _FakeTimers();
      c = FrameRateController(device: display, now: () => timers.now, timer: timers.make);
      await c.start(attach: false);
    });
    tearDown(() => c.dispose());

    test('asks for the highest rate, drops to the lowest after a still second, and comes back on a frame', () {
      expect(display.asked, [120]);
      timers.advance(const Duration(milliseconds: 500));
      c.onFrame();
      timers.advance(const Duration(milliseconds: 600));
      expect(c.idle, isFalse, reason: 'a frame 600 ms ago');
      expect(display.asked, [120]);
      timers.advance(const Duration(milliseconds: 400));
      expect(c.idle, isTrue);
      expect(display.asked, [120, 60]);
      timers.advance(const Duration(milliseconds: 50));
      c.onFrame();
      expect(display.asked, [120, 60], reason: 'a frame right after the drop is the drop\'s own');
      timers.advance(const Duration(milliseconds: 200));
      c.onFrame();
      expect(c.idle, isFalse);
      expect(display.asked, [120, 60, 120]);
      // Frames keep it up; each asks nothing more.
      for (var i = 0; i < 30; i++) {
        timers.advance(const Duration(milliseconds: 8));
        c.onFrame();
      }
      expect(display.asked, [120, 60, 120]);
      timers.advance(const Duration(seconds: 1));
      expect(display.asked, [120, 60, 120, 60]);
    });

    test('a cap asks once and stops the idle drop; Auto again picks it back up', () {
      c.setCap(60);
      expect(display.asked.last, 60);
      timers.advance(const Duration(seconds: 5));
      c.onFrame();
      timers.advance(const Duration(seconds: 5));
      expect(display.asked, [120, 60]);
      expect(timers.pending, isEmpty);
      c.setCap(FrameRateController.auto);
      expect(display.asked.last, 120);
      timers.advance(const Duration(seconds: 1));
      expect(display.asked.last, 60);
    });
  });

  test('a one-rate screen or a platform that cannot ask: no idle timer', () async {
    final timers = _FakeTimers();
    final one = FrameRateController(device: _FakeDisplay([60]), now: () => timers.now, timer: timers.make);
    await one.start(attach: false);
    one.onFrame();
    expect(timers.pending, isEmpty);
    final fixed = _FakeDisplay([60, 144], canRequest: false);
    final win = FrameRateController(device: fixed, now: () => timers.now, timer: timers.make);
    await win.start(attach: false);
    win.onFrame();
    win.setCap(60);
    expect(fixed.asked, isEmpty);
    expect(timers.pending, isEmpty);
  });

  test('Android: the channel lists rates and passes requests; a failing channel stops asking', () async {
    const channel = MethodChannel('caw/display');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'rates' ? {'rates': [120.0, 60.0, double.nan], 'current': 120.0} : {'modeId': 2, 'hz': 60.0};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final d = AndroidDisplayRate();
    expect(await d.supportedRates(), [60.0, 120.0]);
    await d.request(60);
    expect(calls.last.arguments, {'hz': 60.0});

    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'x'));
    final broken = AndroidDisplayRate();
    expect(await broken.supportedRates(), isEmpty);
    expect(broken.canRequest, isFalse);
  });

  testWidgets('the Settings row offers the screen\'s caps and sets the setting', (tester) async {
    final display = _FakeDisplay([60, 120]);
    final c = FrameRateController(device: display);
    FrameRateController.current = c;
    addTearDown(() {
      FrameRateController.current = null;
      c.dispose();
    });
    await c.start(attach: false);
    final s = Settings();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: SettingsPage(settings: s, onEditKeys: (_) async {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('section-performance')));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('setting-performance.frameRate'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Auto')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('this screen: 60, 120 Hz')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dropdown-performance.frameRate')));
    await tester.pumpAndSettle();
    expect(find.text('90 Hz'), findsNothing, reason: 'not on this screen');
    expect(find.text('144 Hz'), findsNothing);
    await tester.tap(find.text('120 Hz').last);
    await tester.pumpAndSettle();
    expect(s.frameRate, 120);
    expect(c.cap, 120);
    expect(display.asked.last, 120);
    expect(find.descendant(of: row, matching: find.textContaining('At most 120 Hz')), findsOneWidget);
  });
}
