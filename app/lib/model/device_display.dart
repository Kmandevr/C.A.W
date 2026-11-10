// The seam for live display data from the engine (spectrum, gain reduction, levels) that device editors draw; empty for now.
import 'package:flutter/foundation.dart';

import 'device_target.dart';

/// One frame of what a device shows besides its parameters, read from the engine at the meter rate.
class DeviceDisplayFrame {
  const DeviceDisplayFrame({this.spectrum, this.gainReductionDb, this.inputDb, this.outputDb, this.values = const {}});

  /// Magnitudes 0..1, low to high on a log frequency axis from 20 Hz to 20 kHz (an EQ's analyser).
  final List<double>? spectrum;

  /// The gain reduction now, in dB (≤ 0): a compressor's or limiter's meter.
  final double? gainReductionDb;

  /// The input and output levels in dB.
  final double? inputDb, outputDb;

  /// Anything else by name (an LFO's phase, an envelope's stage), for the device's own editor.
  final Map<String, double> values;
}

/// Where editors get display frames. The engine's display call (`caw_engine_component_display`, being defined
/// on the engine side) plugs in here; until then [none] gives no frames and editors draw parameters only.
abstract class DeviceDisplaySource {
  const DeviceDisplaySource();

  /// Frames for [target] while an editor shows it; the editor stops listening when it closes.
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target);

  static const DeviceDisplaySource none = _NoDisplay();

  /// The source editors use; the app sets it once the engine offers display data.
  static DeviceDisplaySource current = none;
}

class _NoDisplay extends DeviceDisplaySource {
  const _NoDisplay();
  static final _empty = ValueNotifier<DeviceDisplayFrame?>(null);

  @override
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target) => _empty;
}
