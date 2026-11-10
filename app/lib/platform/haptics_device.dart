// Where touch feedback is played: Android's haptics channel (fine vibrator primitives), else Flutter's HapticFeedback.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// The kinds of feedback the app gives (`lib/ui/haptics.dart` says when each is used).
enum HapticKind { tap, tick, grab, drop, threshold, error }

/// Plays one [HapticKind] at a strength [scale] from 0 to 1.
abstract class HapticsDevice {
  void play(HapticKind kind, double scale);
}

/// Flutter's own feedback (Windows, tests, and Android until its channel answers). It has no strength.
class FlutterHaptics implements HapticsDevice {
  const FlutterHaptics();

  @override
  void play(HapticKind kind, double scale) {
    unawaited(switch (kind) {
      HapticKind.tick || HapticKind.tap || HapticKind.drop => HapticFeedback.selectionClick(),
      HapticKind.grab || HapticKind.threshold => HapticFeedback.lightImpact(),
      HapticKind.error => HapticFeedback.mediumImpact(),
    });
  }
}

/// Android: `caw/haptics` (MainActivity, Haptics.kt) composes `VibrationEffect.Composition` primitives with the
/// scale where the vibrator supports them, and falls back to the system's touch feedback where it does not.
class AndroidHaptics implements HapticsDevice {
  AndroidHaptics({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/haptics');
  final MethodChannel _channel;

  /// After the channel fails once (an old build, a test), Flutter's feedback plays instead.
  HapticsDevice? _fallback;

  @override
  void play(HapticKind kind, double scale) {
    final f = _fallback;
    if (f != null) return f.play(kind, scale);
    _channel.invokeMethod<void>('play', {'kind': kind.name, 'scale': scale}).catchError((Object _) {
      _fallback = const FlutterHaptics();
      _fallback!.play(kind, scale);
    });
  }
}

/// The device for this platform.
HapticsDevice platformHapticsDevice() => Platform.isAndroid ? AndroidHaptics() : const FlutterHaptics();
