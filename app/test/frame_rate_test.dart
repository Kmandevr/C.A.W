// Tests the frame-rate setting: saving and migrating it, the choices a screen's rates allow, Auto's idle drop with a
// fake clock, timer and display, a fixed cap, the performance profiles' caps, Android's channel (mocked), and the
// Settings row.
import 'dart:async';
import 'dart:io';

import 'package:caw/model/settings.dart';
import 'package:caw/platform/display_rate.dart';
import 'package:caw/ui/frame_rate.dart';
import 'package:caw/ui/settings/display_diagnostics.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A screen: [rates] at one resolution (the active mode the lowest), or any [DisplayInfo].
class _FakeDisplay implements DisplayRateDevice {
  _FakeDisplay(List<double> rates, {this.canRequest = true})
    : info = DisplayInfo(
        modes: [for (final r in rates) DisplayMode(1080, 2340, r)],
        active: rates.isEmpty ? null : DisplayMode(1080, 2340, rates.first),
      );
  _FakeDisplay.info(this.info) : canRequest = true;
  DisplayInfo info;
  @override
  final bool canRequest;
  final asked = <double>[];
  @override
  Future<DisplayInfo> read() async => info;
  @override
  Future<void> request(double hz) async => asked.add(hz);
}

// The Galaxy S22+'s panel (Samsung: FHD+ 2340×1080, up to 120 Hz) as One UI may list it. Which modes it lists in each
// Motion smoothness setting is not checked on a device, so each plausible list is a case of its own.
const _fhd = DisplayMode(1080, 2340, 60), _fhd120 = DisplayMode(1080, 2340, 120);
const _qhd = DisplayMode(1440, 3120, 60), _qhd120 = DisplayMode(1440, 3120, 120);

DisplayInfo _s22({
  List<DisplayMode> modes = const [_fhd, _fhd120],
  DisplayMode active = _fhd120,
  List<double> alternatives = const [],
  double current = 0,
  bool powerSave = false,
  int thermal = 0,
}) => DisplayInfo(
  modes: modes,
  active: active,
  alternatives: alternatives,
  currentHz: current,
  powerSave: powerSave,
  thermal: thermal,
  maker: 'samsung',
);

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

  group('profile caps (owner, 2026-11-12)', () {
    late _FakeDisplay display;
    late _FakeTimers timers;
    late FrameRateController c;

    setUp(() async {
      display = _FakeDisplay([30, 60, 120]);
      timers = _FakeTimers();
      c = FrameRateController(device: display, now: () => timers.now, timer: timers.make);
      FrameRateController.current = c;
      await c.start(attach: false);
    });
    tearDown(() {
      FrameRateController.current = null;
      c.dispose();
    });

    test('the profiles set the cap: Lightweight 60, Minimal 30, Full and Balanced none', () async {
      final s = Settings();
      final caps = <PerformanceMode, int>{};
      for (final m in PerformanceMode.values) {
        await s.update((x) => x.performanceMode = m);
        caps[m] = c.profileCap;
      }
      expect(caps, {PerformanceMode.fullExperience: 0, PerformanceMode.balanced: 0, PerformanceMode.lightweight: 60,
          PerformanceMode.minimal: 30});
    });

    test('under Auto it caps the moving rate and the idle drop stays', () {
      c.setProfileCap(60);
      expect(display.asked.last, 60);
      expect(c.effectiveCap, 60);
      timers.advance(const Duration(seconds: 1));
      expect(c.idle, isTrue);
      expect(display.asked.last, 30, reason: 'still: the lowest');
      timers.advance(const Duration(milliseconds: 300));
      c.onFrame();
      expect(display.asked.last, 60, reason: 'moving again: the cap, not the screen\'s highest');
      c.setProfileCap(0);
      expect(display.asked.last, 120);
    });

    test('with a fixed setting, the lower of the two', () {
      c.setCap(120);
      c.setProfileCap(60);
      expect(c.effectiveCap, 60);
      expect(display.asked.last, 60);
      expect(c.profileCaps, isTrue);
      c.setProfileCap(30);
      expect(display.asked.last, 30);
      c.setCap(60);
      c.setProfileCap(60);
      expect(c.profileCaps, isFalse, reason: 'the setting already asks for 60');
      expect(display.asked.last, 60);
      c.setProfileCap(0);
      c.setCap(120);
      expect(display.asked.last, 120);
    });
  });

  testWidgets('the Frame rate row says when the profile caps it', (tester) async {
    final display = _FakeDisplay([60, 120]);
    final timers = _FakeTimers();
    final c = FrameRateController(device: display, now: () => timers.now, timer: timers.make);
    FrameRateController.current = c;
    addTearDown(() {
      FrameRateController.current = null;
      c.dispose();
    });
    await c.start(attach: false);
    final s = Settings();
    await s.update((x) => x.performanceMode = PerformanceMode.lightweight);
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
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining(
          '60 Hz (Lightweight) while anything moves; Balanced or Full Experience allow 120 Hz',
        ),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.text('Auto · 60 Hz')), findsOneWidget);
    expect(display.asked.last, 60);
    await s.update((x) => x.performanceMode = PerformanceMode.balanced);
    await tester.pumpAndSettle();
    expect(find.descendant(of: row, matching: find.textContaining('Lightweight')), findsNothing);
    expect(display.asked.last, 120);
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

  test('Android: the channel lists modes and passes requests; a failing channel stops asking', () async {
    const channel = MethodChannel('caw/display');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'info'
          ? {
              'modes': [
                {'w': 1080, 'h': 2340, 'hz': 120.0},
                {'w': 1080, 'h': 2340, 'hz': 60.0},
                {'w': 1440, 'h': 3120, 'hz': 60.0},
                {'w': 1080, 'h': 2340, 'hz': double.nan},
                'junk',
                {'w': -1, 'h': 2, 'hz': 90.0},
              ],
              'active': {'w': 1080, 'h': 2340, 'hz': 60.0},
              'alternatives': [120.0],
              'current': 60.0,
              'powerSave': true,
              'thermal': 3,
              'maker': 'samsung',
            }
          : {'modeId': 2, 'hz': 60.0};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final d = AndroidDisplayRate();
    final info = await d.read();
    expect(info.rates, [60.0, 120.0], reason: 'the active resolution only, NaN and junk skipped');
    expect(info.modes, hasLength(3));
    expect(info.currentHz, 60);
    expect(info.powerSave, isTrue);
    expect(info.hot, isTrue);
    expect(info.samsung, isTrue);
    await d.request(60);
    expect(calls.last.arguments, {'hz': 60.0, 'modeId': 0}, reason: 'no mode ids in this answer');

    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'x'));
    final broken = AndroidDisplayRate();
    expect((await broken.read()).rates, isEmpty);
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

  group('Galaxy S22+ (owner\'s bug, 2026-11-13: "this phone supports 120 but it says it\'s capped at 60")', () {
    late _FakeTimers timers;
    FrameRateController make(DisplayInfo info, {int profileCap = 0}) {
      timers = _FakeTimers();
      return FrameRateController(device: _FakeDisplay.info(info), now: () => timers.now, timer: timers.make)
        ..setProfileCap(profileCap);
    }

    FrameRateStatus status(
      FrameRateController c, [
      PerformanceMode m = PerformanceMode.balanced,
      bool bySelf = false,
    ]) => c.status(profile: m.label, profileBySelf: bySelf);

    test('Adaptive, 60 and 120 at FHD+: Auto asks for 120 and says nothing holds it', () async {
      for (final active in [_fhd, _fhd120]) {
        final c = make(_s22(active: active));
        await c.start(attach: false);
        expect(c.rates, [60, 120]);
        expect((c.device as _FakeDisplay).asked.first, 120, reason: 'active $active');
        expect(status(c).autoLabel, 'Auto');
        expect(status(c).subtitle, contains('Up to 120 Hz while anything moves, 60 Hz when still'));
        c.dispose();
      }
    });

    test('60 and 120 at each resolution: the current one\'s rates, 120 either way', () async {
      for (final active in [_fhd, _qhd, _qhd120]) {
        final c = make(_s22(modes: const [_fhd, _fhd120, _qhd, _qhd120], active: active));
        await c.start(attach: false);
        expect(c.rates, [60, 120], reason: 'active $active');
        expect(c.info.fasterElsewhere, isNull);
        expect((c.device as _FakeDisplay).asked.first, 120);
        c.dispose();
      }
    });

    test('120 only at another resolution: 60 here, and the row says where 120 is', () async {
      final c = make(_s22(modes: const [_fhd, _fhd120, _qhd], active: _qhd));
      await c.start(attach: false);
      expect(c.rates, [60]);
      final s = status(c);
      expect(s.subtitle, contains('120 Hz is offered only at 1080×2340'));
      expect(s.autoLabel, 'Auto · 60 Hz');
      expect(s.limit, 'resolution');
      c.dispose();
    });

    test('Adaptive listing only the active mode: its alternatives still give 120', () async {
      final c = make(_s22(modes: const [_fhd], active: _fhd, alternatives: const [120]));
      await c.start(attach: false);
      expect(c.rates, [60, 120]);
      expect((c.device as _FakeDisplay).asked.first, 120);
      c.dispose();
    });

    test('read while idle at 60: the current rate never limits the rates', () async {
      final c = make(_s22(active: _fhd, current: 60));
      await c.start(attach: false);
      expect(c.rates, [60, 120]);
      timers.advance(const Duration(seconds: 2));
      expect(c.idle, isTrue);
      expect(status(c).autoLabel, 'Auto', reason: 'idle: 60 is the app\'s own drop');
      c.dispose();
    });

    test('Standard: only 60 listed, and the row names Motion smoothness', () async {
      final c = make(_s22(modes: const [_fhd], active: _fhd));
      await c.start(attach: false);
      final s = status(c);
      expect(s.autoLabel, 'Auto · 60 Hz');
      expect(s.limit, 'Motion smoothness');
      expect(s.subtitle, contains('Motion smoothness is probably Standard; Adaptive allows 120 Hz'));
      c.dispose();
    });

    test('battery saver: named as the reason', () async {
      final c = make(_s22(modes: const [_fhd], active: _fhd, powerSave: true));
      await c.start(attach: false);
      expect(status(c).limit, 'battery saver');
      expect(status(c).subtitle, contains('60 Hz: battery saver is on and the phone offers no more'));
      c.dispose();
    });

    test('120 listed but the screen held at 60 while moving: says so, with the likely reason', () async {
      for (final (info, why) in [
        (_s22(current: 60), 'check Samsung\'s Motion smoothness'),
        (_s22(current: 60, powerSave: true), 'battery saver'),
        (_s22(current: 60, thermal: DisplayInfo.severe), 'the phone is hot'),
      ]) {
        final c = make(info);
        await c.start(attach: false);
        final s = status(c);
        expect(s.subtitle, contains('Asked for 120 Hz, the screen runs at 60 Hz: $why'));
        expect(s.autoLabel, 'Auto · 60 Hz');
        expect(s.limit, why);
        c.dispose();
      }
      final ok = make(_s22(current: 120));
      await ok.start(attach: false);
      expect(status(ok).autoLabel, 'Auto');
      ok.dispose();
    });

    test(
      'each profile: Full and Balanced 120, Lightweight 60 and says so, Minimal the lowest the screen has',
      () async {
        final s = Settings();
        final c = make(_s22());
        FrameRateController.current = c;
        addTearDown(() => FrameRateController.current = null);
        await c.start(attach: false);
        final got = <PerformanceMode, (double, String)>{};
        for (final m in PerformanceMode.values) {
          await s.update((x) => x.performanceMode = m);
          got[m] = (c.movingRate, status(c, m).limit ?? '');
        }
        expect(got, {
          PerformanceMode.fullExperience: (120.0, ''),
          PerformanceMode.balanced: (120.0, ''),
          PerformanceMode.lightweight: (60.0, 'Lightweight'),
          PerformanceMode.minimal: (60.0, 'Minimal'),
        });
        expect(status(c, PerformanceMode.minimal).subtitle, contains('Balanced or Full Experience allow 120 Hz'));
        c.dispose();
      },
    );

    test('Lightweight turned on by an overload says so; choosing a profile clears it, and it is saved', () async {
      final c = make(_s22(), profileCap: 60);
      await c.start(attach: false);
      expect(
        status(c, PerformanceMode.lightweight, true).subtitle,
        startsWith('60 Hz (Lightweight, turned on by itself after an audio overload) while anything moves'),
      );
      final s = Settings()
        ..performanceMode = PerformanceMode.lightweight
        ..lightBySelf = true;
      final back = Settings()..fromJson(s.toJson());
      expect(back.lightBySelf, isTrue);
      expect((Settings()..fromJson({...s.toJson(), 'performance_mode': 'balanced'})).lightBySelf, isFalse);
      c.dispose();
    });

    test('a fixed 120 cap on the S22+: 120, and 60 under Lightweight with the reason', () async {
      final c = make(_s22());
      await c.start(attach: false);
      c.setCap(120);
      expect(status(c).subtitle, startsWith('At most 120 Hz everywhere'));
      c.setProfileCap(60);
      expect(
        status(c, PerformanceMode.lightweight).subtitle,
        startsWith(
          'At most 60 Hz (Lightweight) everywhere, playback included; Balanced or Full Experience allow 120 Hz',
        ),
      );
      c.dispose();
    });

    test('Standard turned to Adaptive: a refresh picks 120 up', () async {
      final c = make(_s22(modes: const [_fhd], active: _fhd));
      final d = c.device as _FakeDisplay;
      await c.start(attach: false);
      expect(c.rates, [60]);
      d.info = _s22();
      await c.refresh();
      expect(c.rates, [60, 120]);
      expect(d.asked.last, 120);
      c.dispose();
    });
  });

  group('LTPO/VRR: every mode reports 60, 120 only among its alternatives (owner, 2026-11-13)', () {
    for (final (name, alts, idle) in [
      ('alternatives [120]', const [120.0], 60.0),
      ('alternatives [48, 96, 120]', const [48.0, 96.0, 120.0], 48.0),
    ]) {
      test('one mode at 1080×2340@60, $name: Auto asks for 120 by rate and the row says so', () async {
        final m = DisplayMode(1080, 2340, 60, id: 1, alternatives: alts);
        final info = DisplayInfo(modes: [m], active: m, currentHz: 120, maker: 'samsung');
        final timers = _FakeTimers();
        final d = _FakeDisplay.info(info);
        final c = FrameRateController(device: d, now: () => timers.now, timer: timers.make);
        await c.start(attach: false);
        expect(c.rates.last, 120);
        expect(c.choices, contains(120));
        expect(d.asked.first, 120);
        expect(info.modeFor(120), 0, reason: 'no mode has 120 of its own: preferredRefreshRate alone');
        expect(info.modeFor(60), 1);
        final s = c.status(profile: 'Balanced');
        expect(s.autoLabel, 'Auto');
        expect(s.subtitle, startsWith('Up to 120 Hz while anything moves, ${idle.round()} Hz when still'));
        expect(s.subtitle, isNot(contains('offers no more')));
        timers.advance(const Duration(seconds: 2));
        expect(d.asked.last, idle);
        c.dispose();
      });
    }

    test('Android: the request names mode 0 for an alternative-only rate, the mode\'s id otherwise', () async {
      const channel = MethodChannel('caw/display');
      final calls = <MethodCall>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'info'
            ? {
                'modes': [
                  {'id': 1, 'w': 1080, 'h': 2340, 'hz': 60.0, 'alt': [48.0, 96.0, 120.0]},
                ],
                'active': {'id': 1, 'w': 1080, 'h': 2340, 'hz': 60.0, 'alt': [48.0, 96.0, 120.0]},
                'current': 60.0,
                'maker': 'samsung',
              }
            : {'modeId': 0, 'hz': 120.0};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final d = AndroidDisplayRate();
      final c = FrameRateController(device: d, timer: _FakeTimers().make);
      await c.start(attach: false);
      expect(c.rates, [48, 60, 96, 120]);
      expect(calls.last.arguments, {'hz': 120.0, 'modeId': 0});
      await d.request(60);
      expect(calls.last.arguments, {'hz': 60.0, 'modeId': 1});
      await d.request(0);
      expect(calls.last.arguments, {'hz': 0.0, 'modeId': 0});
      c.dispose();
    });

    testWidgets('Engine diagnostics\' Display modes block shows the raw read and copies it', (tester) async {
      const m = DisplayMode(1080, 2340, 60, id: 1, alternatives: [48, 96, 120]);
      final d = _FakeDisplay.info(const DisplayInfo(
          modes: [m, DisplayMode(1440, 3088, 60, id: 2)], active: m, currentHz: 60, powerSave: true, thermal: 1,
          maker: 'samsung'));
      final c = FrameRateController(device: d, timer: _FakeTimers().make);
      addTearDown(c.dispose);
      await c.start(attach: false);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: Scaffold(body: DisplayModesPanel(controller: c))));
      await tester.pumpAndSettle();
      final text = (tester.widget<SelectableText>(find.byKey(const ValueKey('display-modes-text')))).data!;
      for (final line in [
        'Display modes (2):',
        '#1 1080×2340 @ 60 Hz (alternatives 48, 96, 120 Hz)  [active]',
        '#2 1440×3088 @ 60 Hz',
        'Current rate: 60 Hz',
        'Asked for: 120 Hz',
        'Rates offered here: 48, 60, 96, 120 Hz',
        'Battery saver: on',
        'Thermal status: 1',
        'Manufacturer: samsung',
      ]) {
        expect(text, contains(line));
      }
      await tester.tap(find.byKey(const ValueKey('display-modes-copy')));
      await tester.pumpAndSettle();
      expect(copied, text);
      await tester.pump(const Duration(seconds: 5)); // the snack bar's own timer
    });
  });
}
