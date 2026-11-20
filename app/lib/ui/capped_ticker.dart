// A ticker held to a top rate: between its ticks it is stopped, so it asks for no frames, and a timer starts it for the next.
import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Calls [onTick] on frames, at most [maxHz] times a second (1.1.1: device visuals, meters, the crow loader and
/// Parrot drew on every frame the screen ran, up to 120 or 240 a second, and each such frame is a whole frame's
/// raster and GPU work). After each tick its ticker stops, so it schedules no frames, and a [Timer] starts it again
/// one interval later; the next frame drawn after that ticks. [onTick] gets the time since [start] from the
/// frames' timestamps (deterministic in tests). Made from [vsync], it is muted with its [TickerMode] as any
/// ticker (off screen it asks for nothing). [maxHz] 0 or less ticks on every frame.
class CappedTicker {
  CappedTicker(this.onTick, {required this.maxHz, TickerProvider? vsync, String? debugLabel}) {
    _ticker = vsync?.createTicker(_tick) ?? Ticker(_tick, debugLabel: debugLabel);
  }

  final void Function(Duration elapsed) onTick;
  final double maxHz;
  late final Ticker _ticker;
  Timer? _wake;
  Duration? _origin; // the first tick's frame time
  bool _running = false, _disposed = false;

  /// The shortest time between two ticks.
  Duration get interval => maxHz > 0 ? Duration(microseconds: (1e6 / maxHz).round()) : Duration.zero;

  /// Started and not stopped (it may be waiting between ticks).
  bool get isActive => _running;

  /// Waiting between two ticks: no frame asked for.
  bool get waiting => _running && !_ticker.isActive;

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _origin = null;
    _ticker.start();
  }

  void stop() {
    _running = false;
    _wake?.cancel();
    _wake = null;
    if (_ticker.isActive) _ticker.stop();
  }

  void _tick(Duration _) {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final elapsed = now - (_origin ??= now);
    onTick(elapsed);
    final step = interval;
    if (step == Duration.zero || !_running || _disposed) return;
    _ticker.stop();
    _wake?.cancel();
    // A little early, so the frame after the interval is the one that ticks.
    _wake = Timer(step - const Duration(milliseconds: 1), () {
      _wake = null;
      if (_running && !_disposed && !_ticker.isActive) _ticker.start();
    });
  }

  void dispose() {
    _disposed = true;
    _running = false;
    _wake?.cancel();
    _wake = null;
    _ticker.dispose();
  }
}
