// Reads the engine's meters only while something can change, so a stopped or hidden app costs no CPU or battery.
import 'dart:async';

/// About 30 reads a second while playing, a short settle after stopping so meters fall back, then nothing at all.
/// Nothing runs while the app is in the background. After [idleDelay] with nothing moving, [onIdle] runs once (the app
/// closes the audio device then; pressing Play reopens it).
class Poller {
  Poller({
    required this.poll,
    this.onIdle,
    this.interval = const Duration(milliseconds: 33),
    this.settle = const Duration(seconds: 1),
    this.idleDelay = const Duration(seconds: 30),
  });

  /// Reads the meters; returns whether anything is still moving (playing, or a meter above zero).
  final bool Function() poll;
  final void Function()? onIdle;
  final Duration settle, idleDelay;

  /// Time between reads; light mode doubles it.
  Duration interval;

  Timer? _tick, _idle;
  bool _visible = true;
  int _stillTicks = 0;

  /// Whether reads are currently scheduled (for tests and diagnostics).
  bool get running => _tick != null;

  /// Something may have changed (play, stop, a new project): read at full rate again.
  void wake() {
    _idle?.cancel();
    _idle = null;
    _stillTicks = 0;
    if (_visible && _tick == null) _tick = Timer(interval, _fire);
  }

  /// The app went to the background (false) or came back (true).
  void setVisible(bool visible) {
    _visible = visible;
    if (visible) {
      wake();
    } else {
      _tick?.cancel();
      _tick = null;
      _idle?.cancel();
      _idle = null;
    }
  }

  void _fire() {
    _tick = null;
    if (!_visible) return;
    final moving = poll();
    _stillTicks = moving ? 0 : _stillTicks + 1;
    if (_stillTicks * interval.inMicroseconds < settle.inMicroseconds) {
      _tick = Timer(interval, _fire);
    } else if (onIdle != null) {
      _idle = Timer(idleDelay, () {
        _idle = null;
        onIdle!();
      });
    }
  }

  void dispose() {
    _tick?.cancel();
    _idle?.cancel();
    _tick = _idle = null;
  }
}
