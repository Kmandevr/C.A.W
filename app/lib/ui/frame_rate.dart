// The frame-rate setting at work: Auto (the screen's highest rate while anything moves, its lowest when still) or a cap.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../platform/display_rate.dart';

export '../platform/display_rate.dart' show DisplayRateDevice, FixedDisplayRate;

/// Makes a one-shot timer (tests pass a fake).
typedef IdleTimerFactory = Timer Function(Duration after, void Function() fire);

/// Asks the screen for a refresh rate (owner, 2026-11-12). The setting is a cap in Hz, or [auto] (0). One rate
/// applies to the whole app: playhead, meters and the music video preview draw at whatever the screen runs at.
///
/// Auto asks for the highest rate while frames are drawn and for the lowest once none has been drawn for
/// [idleAfter]; the next frame asks for the highest again. The only work per frame is [onFrame]'s timestamp. Every
/// change is a request: the system may keep another rate (battery saver, its own peak-rate setting), and the app
/// never asks again to override it.
class FrameRateController extends ChangeNotifier {
  FrameRateController({
    required this.device,
    Duration Function()? now,
    IdleTimerFactory? timer,
    this.idleAfter = const Duration(seconds: 1),
    this.wakeGuard = const Duration(milliseconds: 150),
  })  : _now = now ?? _realNow,
        _timer = timer ?? Timer.new;

  /// The app's controller (main.dart makes it; null in tests that don't need one). Settings sets its [cap].
  static FrameRateController? current;

  /// The caps offered where the screen has them (owner, 2026-11-12).
  static const caps = [60, 90, 120, 144, 240];

  /// The setting's value for Auto.
  static const auto = 0;

  /// How close a screen rate has to be to a cap to count as it (59.94 Hz is 60).
  static const tolerance = 1.5;

  final DisplayRateDevice device;
  final Duration idleAfter;

  /// Frames this soon after dropping to the lowest rate don't wake: changing the window's preferred mode can itself
  /// bring a frame (a new layout or the rate change), which would otherwise bounce straight back up. A real
  /// animation draws more frames and wakes on the first one after it.
  final Duration wakeGuard;
  final Duration Function() _now;
  final IdleTimerFactory _timer;

  static final _stopwatch = Stopwatch()..start();
  static Duration _realNow() => _stopwatch.elapsed;

  /// The screen's rates, ascending, once [start] has read them.
  List<double> get rates => _rates;
  List<double> _rates = const [];

  /// The setting: [auto] or a cap in Hz.
  int get cap => _cap;
  int _cap = auto;

  /// The rate last asked for (null: nothing asked yet; 0: no preference).
  double? get requested => _requested;
  double? _requested;

  /// True while Auto has dropped to the lowest rate.
  bool get idle => _idle;
  bool _idle = false;

  Duration _lastFrame = Duration.zero, _wentIdle = Duration.zero;
  Timer? _idleTimer;
  bool _attached = false;

  /// The choices the setting row offers for [rates]: Auto, then each cap the screen has. A platform that can't ask
  /// ([DisplayRateDevice.canRequest] false) offers Auto alone.
  static List<int> choicesFor(List<double> rates, {bool canRequest = true}) => [
        auto,
        if (canRequest)
          for (final c in caps)
            if (rates.any((r) => (r - c).abs() <= tolerance)) c,
      ];

  /// The choices for this screen.
  List<int> get choices => choicesFor(_rates, canRequest: device.canRequest);

  /// The rate a [cap] asks for on a screen with [rates]: the highest not above it, else the lowest.
  static double rateFor(int cap, List<double> rates) {
    if (rates.isEmpty) return 0;
    return rates.lastWhere((r) => r <= cap + tolerance, orElse: () => rates.first);
  }

  /// A choice's label.
  static String label(int cap) => cap == auto ? 'Auto' : '$cap Hz';

  /// Reads the screen's rates and asks for the setting's rate; [attach] hooks the frame callback first.
  Future<void> start({bool attach = true}) async {
    if (attach) _attach();
    _rates = List.unmodifiable(await device.supportedRates());
    _apply();
    notifyListeners();
  }

  void _attach() {
    if (_attached) return;
    _attached = true;
    // Persistent callbacks run for every frame drawn and can't be removed: [onFrame] returns at once unless Auto.
    SchedulerBinding.instance.addPersistentFrameCallback((_) => onFrame());
  }

  /// Sets the setting (Settings calls it whenever it applies itself, so an unchanged value does nothing).
  void setCap(int value) {
    final v = value == auto || caps.contains(value) ? value : auto;
    if (v == _cap) return;
    _cap = v;
    _apply();
    notifyListeners();
  }

  bool get _auto => _cap == auto && device.canRequest && _rates.length >= 2;

  void _apply() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _idle = false;
    if (!device.canRequest || _rates.isEmpty) return;
    if (_cap != auto) return _ask(rateFor(_cap, _rates));
    if (_rates.length < 2) return _ask(0); // one rate: nothing to choose, so no preference
    _lastFrame = _now();
    _ask(_rates.last);
    _armIdle(idleAfter);
  }

  /// A frame was drawn: under Auto, note when, and come back from idle at once.
  void onFrame() {
    if (!_auto) return;
    final t = _now();
    if (_idle && t - _wentIdle < wakeGuard) return;
    _lastFrame = t;
    if (_idle) {
      _idle = false;
      _ask(_rates.last);
    }
    if (_idleTimer == null) _armIdle(idleAfter);
  }

  void _armIdle(Duration after) => _idleTimer = _timer(after, _checkIdle);

  void _checkIdle() {
    _idleTimer = null;
    if (!_auto || _idle) return;
    final t = _now();
    final still = t - _lastFrame;
    if (still >= idleAfter) {
      _idle = true;
      _wentIdle = t;
      _ask(_rates.first);
    } else {
      _armIdle(idleAfter - still);
    }
  }

  void _ask(double hz) {
    if (hz == _requested) return;
    _requested = hz;
    unawaited(device.request(hz));
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _idleTimer = null;
    super.dispose();
  }
}
