// Touch feedback by meaning (tap, tick, grab, drop, threshold, error), with the on/off and Strength settings and a
// rate limit so a fast knob turn doesn't buzz.
import '../platform/haptics_device.dart';

export '../platform/haptics_device.dart' show FlutterHaptics, HapticKind, HapticsDevice;

/// The app's haptics (owner, 2026-11-10: "subtle everywhere", with a strength setting and an off switch). Settings
/// sets [enabled] and [strength]; `main.dart` sets [device] for the platform.
class Haptics {
  Haptics._();

  /// Off: nothing plays.
  static bool enabled = true;

  /// 0 (faintest) to 1 (strongest); 0.5 is the default and plays each kind at its base scale.
  static double strength = 0.5;

  /// Where feedback plays: Flutter's HapticFeedback until main.dart picks the platform's.
  static HapticsDevice device = const FlutterHaptics();

  /// The clock the rate limit reads (tests replace it).
  static Duration Function() now = realNow;
  static final _stopwatch = Stopwatch()..start();
  static Duration realNow() => _stopwatch.elapsed;

  /// A button, chip, toggle or menu item pressed.
  static void tap() => play(HapticKind.tap);

  /// A step: a snap, a detent, a knob's notch, a slider's division, a placed note.
  static void tick() => play(HapticKind.tick);

  /// A handle, grip, divider or item picked up.
  static void grab() => play(HapticKind.grab);

  /// What was dragged, put down (or a panel settling where it snapped).
  static void drop() => play(HapticKind.drop);

  /// A drag crossing the point where letting go does something (the bars' pull, a sheet's close).
  static void threshold() => play(HapticKind.threshold);

  /// Something refused.
  static void error() => play(HapticKind.error);

  /// The shortest time between two of a kind, so a fast knob turn plays at most about 28 ticks a second. A tick
  /// also waits this long after a tap, so a press isn't doubled by the step it causes.
  static const minGap = {
    HapticKind.tick: Duration(milliseconds: 35),
    HapticKind.tap: Duration(milliseconds: 40),
    HapticKind.grab: Duration(milliseconds: 80),
    HapticKind.drop: Duration(milliseconds: 80),
    HapticKind.threshold: Duration(milliseconds: 120),
    HapticKind.error: Duration(milliseconds: 200),
  };

  /// Each kind's scale at the default strength: light by design.
  static const baseScale = {
    HapticKind.tick: 0.45,
    HapticKind.tap: 0.5,
    HapticKind.grab: 0.6,
    HapticKind.drop: 0.55,
    HapticKind.threshold: 0.7,
    HapticKind.error: 0.8,
  };

  /// The scale [kind] plays at for [strength]: half the base at 0, the base at 0.5, one and a half times it at 1
  /// (Android's guidance: scales a ratio of 1.4 or more apart feel different).
  static double scaleFor(HapticKind kind, [double? at]) =>
      (baseScale[kind]! * (0.5 + (at ?? strength).clamp(0.0, 1.0))).clamp(0.0, 1.0);

  static final Map<HapticKind, Duration> _last = {};

  /// Plays [kind] unless haptics are off or it comes too soon; true when it played.
  static bool play(HapticKind kind) {
    if (!enabled) return false;
    final t = now();
    final last = _last[kind];
    if (last != null && t - last < minGap[kind]!) return false;
    final tap = _last[HapticKind.tap];
    if (kind == HapticKind.tick && tap != null && t - tap < minGap[HapticKind.tick]!) return false;
    _last[kind] = t;
    device.play(kind, scaleFor(kind));
    return true;
  }

  /// Forgets the rate limit's history (tests).
  static void reset() {
    _last.clear();
  }
}
