// Tests the haptics helper: the on/off switch, the Strength scale, the rate limit, Android's channel (mocked) and its
// fallback, and the settings that drive them.
import 'dart:io';

import 'package:caw/model/settings.dart';
import 'package:caw/platform/haptics_device.dart';
import 'package:caw/ui/haptics.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder implements HapticsDevice {
  final played = <(HapticKind, double)>[];
  @override
  void play(HapticKind kind, double scale) => played.add((kind, scale));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Recorder rec;
  var t = Duration.zero;

  setUp(() {
    rec = _Recorder();
    Haptics.device = rec;
    Haptics.enabled = true;
    Haptics.strength = 0.5;
    Haptics.now = () => t;
    Haptics.reset();
    t = const Duration(seconds: 10);
  });

  tearDown(() {
    Haptics.device = const FlutterHaptics();
    Haptics.now = Haptics.realNow;
    Haptics.reset();
  });

  test('every semantic call plays its own kind', () {
    for (final call in [Haptics.tap, Haptics.tick, Haptics.grab, Haptics.drop, Haptics.threshold, Haptics.error]) {
      call();
      t += const Duration(milliseconds: 300);
    }
    expect(rec.played.map((p) => p.$1), [
      HapticKind.tap, HapticKind.tick, HapticKind.grab, HapticKind.drop, HapticKind.threshold, HapticKind.error,
    ]);
  });

  test('off plays nothing, and Motion.haptics is the same switch', () {
    Motion.haptics = false;
    expect(Haptics.enabled, isFalse);
    Haptics.tap();
    Motion.tick();
    expect(rec.played, isEmpty);
    Motion.haptics = true;
    Motion.tick();
    expect(rec.played.single.$1, HapticKind.tick);
  });

  test('a fast knob turn is rate-limited: ticks at most every 35 ms, and none right after a press', () {
    // 100 ticks over 1 s (one every 10 ms), as a quick turn through 100 notches would ask for.
    for (var i = 0; i < 100; i++) {
      Haptics.tick();
      t += const Duration(milliseconds: 10);
    }
    expect(rec.played.length, inInclusiveRange(20, 29));
    rec.played.clear();
    t += const Duration(seconds: 1);
    Haptics.tap();
    t += const Duration(milliseconds: 10);
    Haptics.tick();
    expect(rec.played.map((p) => p.$1), [HapticKind.tap], reason: 'the step a press causes is not a second buzz');
    t += const Duration(milliseconds: 10);
    Haptics.drop();
    expect(rec.played.last.$1, HapticKind.drop, reason: 'a drop is never swallowed by a recent tick');
  });

  test('Strength scales every kind: half at 0, the base at 0.5, 1.5 times at 1, never past 1', () {
    for (final k in HapticKind.values) {
      expect(Haptics.scaleFor(k, 0), closeTo(Haptics.baseScale[k]! * 0.5, 1e-9));
      expect(Haptics.scaleFor(k, 0.5), closeTo(Haptics.baseScale[k]!, 1e-9));
      expect(Haptics.scaleFor(k, 1), lessThanOrEqualTo(1.0));
    }
    Haptics.strength = 1;
    Haptics.tick();
    expect(rec.played.single.$2, closeTo(Haptics.baseScale[HapticKind.tick]! * 1.5, 1e-9));
  });

  test('Android sends the kind and scale over caw/haptics; a missing channel falls back to Flutter', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('caw/haptics');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final android = AndroidHaptics();
    android.play(HapticKind.tick, 0.45);
    await Future<void>.delayed(Duration.zero);
    expect(calls.single.method, 'play');
    expect(calls.single.arguments, {'kind': 'tick', 'scale': 0.45});

    // No handler: the first call fails and Flutter's own feedback plays from then on.
    messenger.setMockMethodCallHandler(channel, null);
    final platform = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') platform.add(call.arguments as String);
      return null;
    });
    final old = AndroidHaptics();
    old.play(HapticKind.tap, 0.5);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    old.play(HapticKind.grab, 0.5);
    await Future<void>.delayed(Duration.zero);
    expect(platform, ['HapticFeedbackType.selectionClick', 'HapticFeedbackType.lightImpact']);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('settings: haptics, strength, layout and the side panel share are saved, loaded, applied and clamped', () async {
    final dir = await Directory.systemTemp.createTemp('caw-haptics');
    addTearDown(() => dir.delete(recursive: true));
    final s = await Settings.open(base: dir);
    expect((s.haptics, s.hapticStrength, s.layoutMode), (true, 0.5, LayoutMode.auto));
    expect(s.focusPanelShare, closeTo(2 / 3, 1e-9));
    await s.update((s) {
      s.hapticStrength = 0.8;
      s.haptics = false;
      s.layoutMode = LayoutMode.desktop;
      s.focusPanelShare = 0.5;
    });
    expect((Haptics.enabled, Haptics.strength), (false, 0.8));
    final back = await Settings.open(base: dir);
    expect((back.haptics, back.hapticStrength, back.layoutMode, back.focusPanelShare), (false, 0.8, LayoutMode.desktop, 0.5));
    back.fromJson({'haptic_strength': 7, 'focus_panel_share': 0.01, 'layout_mode': 'tablet'});
    expect((back.hapticStrength, back.focusPanelShare, back.layoutMode), (1.0, Settings.minFocusPanelShare, LayoutMode.desktop));
    await back.update((s) => s.haptics = true);
  });
}
