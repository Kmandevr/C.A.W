// The device shell's seam for per-FX-slot auto gain and output meters: the engine side plugs in here; with nothing plugged in the ear icon, the footer meter and the collapsed rows' level stay hidden.
import 'package:flutter/foundation.dart';

import 'device_target.dart';

/// What the engine offers per device slot: its output level and its auto gain (a trim that keeps the device's output
/// as loud as its input). The device shell (header, footer, FX chain rows) reads it through [current]; the engine's
/// implementation is set once the C API has it. Every method is cheap and called from the UI thread only.
abstract class DeviceSlotAudio {
  const DeviceSlotAudio();

  /// The engine's implementation, or null (the default): the shell then shows no meter and no ear icon.
  static DeviceSlotAudio? current;

  /// Bumped when a device's auto gain is switched, so headers and menus showing it rebuild.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  /// Whether the engine meters each slot's output ([outputPeak]).
  bool get hasMeter;

  /// Whether the engine has per-slot auto gain ([autoGain], [setAutoGain], [autoGainTrimDb]).
  bool get hasAutoGain;

  /// [t]'s output peak since the last call (linear, the louder side; 1.0 is 0 dBFS), or null when the engine has no
  /// reading for it (not playing it, not loaded). Polled about 30 times a second while a meter is on screen.
  double? outputPeak(DeviceTarget t);

  /// Whether [t]'s auto gain is on (the per-device switch).
  bool autoGain(DeviceTarget t);

  /// Switches [t]'s auto gain; the implementation keeps it with the device (and its undo) as it sees fit.
  void setAutoGain(DeviceTarget t, bool on);

  /// The trim auto gain applies to [t] now, in dB (null while it is off or has no reading yet).
  double? autoGainTrimDb(DeviceTarget t);

  /// Whether the shell can show [t]'s meter now.
  static bool meterFor(DeviceTarget t) => current?.hasMeter ?? false;

  /// Whether the shell shows [t]'s ear icon now.
  static bool autoGainFor(DeviceTarget t) => current?.hasAutoGain ?? false;

  /// Switches [t]'s auto gain through [current] and tells the shell.
  static void toggleAutoGain(DeviceTarget t) {
    final a = current;
    if (a == null || !a.hasAutoGain) return;
    a.setAutoGain(t, !a.autoGain(t));
    changes.value++;
  }
}
