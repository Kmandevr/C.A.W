// The screen's refresh rates and asking for one: Android's display-rate channel; elsewhere the screen's own rate.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// What the frame-rate setting needs from the platform (`lib/ui/frame_rate.dart` decides what to ask for).
abstract class DisplayRateDevice {
  /// The refresh rates the screen offers at its current resolution, in Hz, ascending; empty when unknown.
  Future<List<double>> supportedRates();

  /// Whether [request] can change the rate here.
  bool get canRequest;

  /// Asks for the highest rate not above [hz] (0: no preference, the system chooses). Only a request: the system
  /// (battery saver, its own peak-rate setting) has the last word.
  Future<void> request(double hz);
}

/// Android: `caw/display` (MainActivity, DisplayRate.kt) lists `Display.getSupportedModes` at the current
/// resolution and sets the window's `preferredDisplayModeId` and `preferredRefreshRate`.
class AndroidDisplayRate implements DisplayRateDevice {
  AndroidDisplayRate({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/display');
  final MethodChannel _channel;

  /// After the channel fails once (an old build, a test), nothing more is asked.
  bool _failed = false;

  @override
  bool get canRequest => !_failed;

  @override
  Future<List<double>> supportedRates() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('rates');
      final list = r?['rates'];
      if (list is! List) return const [];
      return [for (final v in list.take(64)) if (v is num && v.isFinite && v > 0) v.toDouble()]..sort();
    } catch (_) {
      _failed = true;
      return const [];
    }
  }

  @override
  Future<void> request(double hz) async {
    if (_failed) return;
    try {
      await _channel.invokeMethod<Object?>('request', {'hz': hz});
    } catch (_) {
      _failed = true;
    }
  }
}

/// Windows and tests: Flutter draws at the monitor's rate and there is no request to make; the rate shown is the
/// one `dart:ui` reports for the first display (0 or none: unknown).
class FixedDisplayRate implements DisplayRateDevice {
  const FixedDisplayRate();

  @override
  bool get canRequest => false;

  @override
  Future<List<double>> supportedRates() async {
    final displays = ui.PlatformDispatcher.instance.displays;
    final hz = displays.isEmpty ? 0.0 : displays.first.refreshRate;
    return hz.isFinite && hz > 0 ? [hz] : const [];
  }

  @override
  Future<void> request(double hz) async {}
}

/// The device for this platform.
DisplayRateDevice platformDisplayRate() => Platform.isAndroid ? AndroidDisplayRate() : const FixedDisplayRate();
