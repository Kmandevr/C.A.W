// The playhead between engine reads: runs on from the last read at the tempo, and settles onto each new read.
import 'dart:math' as math;

/// The engine's position is read about 30 times a second ([AppState]'s poller); the screen may draw 60 to 240
/// frames a second (the frame-rate setting). [at] gives the playhead for any moment: the last read moved on by the
/// time since it at [read]'s rate, wrapped over the loop exactly as the engine wraps it.
///
/// Each new read is compared with where the playhead was shown at that moment, across a loop wrap when that is
/// nearer. An error of up to [snapUs] of play (read jitter, a callback burst) fades out with time constant
/// [settleUs], slowly enough that the line never moves backwards; a bigger one (a seek, a jump back to the start)
/// snaps there and holds until the reads move on; a tempo change snaps too. Stopped or paused, [at] is the read
/// position exactly.
class PlayheadClock {
  /// An error bigger than this much play time snaps instead of settling.
  static const snapUs = 60000;

  /// The time constant a smaller error fades out with (longer than [snapUs], so the playhead never runs backwards).
  static const settleUs = 80000;

  /// How far past the last read the playhead runs on, if reads stop coming (a stalled poller holds the line).
  static const maxAheadUs = 100000;

  bool _playing = false;
  double _base = 0, _err = 0, _rate = 0; // steps at [_baseUs], shown minus engine then, steps per µs
  int _baseUs = 0;
  double _from = 0, _to = 0;
  bool _inLoop = false; // the last read was inside the wrap range: the line wraps at its ends
  double? _lastRead; // the last read's step while playing
  int _stillReads = 0; // reads in a row that didn't move

  /// Whether the last read was playing.
  bool get playing => _playing;

  /// Whether the line is running on between reads (playing and moving): only then does it need every frame.
  bool get running => _playing && _rate > 0;

  /// The error being settled, in steps (shown minus read, at the last read; tests).
  double get settling => _err;

  /// A read of the engine at [atUs]: the playhead [step] (already latency-compensated), whether it plays, its rate
  /// in steps per second at the tempo, and the range it wraps over, [from] to [to] (none when [to] is not above
  /// [from]).
  ///
  /// The line runs on only once the reads move: from a start it holds on the first read (a count-in, or the held
  /// start of a latency-compensated play, reads the same step), and two reads in a row that don't move hold it
  /// again. One unmoved read while running (two reads inside one audio burst) changes nothing.
  void read({
    required double step,
    required int atUs,
    required bool playing,
    required double stepsPerSecond,
    double from = 0,
    double to = 0,
  }) {
    final rate = stepsPerSecond.isFinite && stepsPerSecond > 0 ? stepsPerSecond / 1e6 : 0.0;
    final wasPlaying = _playing, oldRate = _rate;
    final shown = wasPlaying ? _unwrapped(atUs) : 0.0;
    _playing = playing;
    _from = from;
    _to = to;
    _inLoop = to > from && step >= from && step < to;
    final moved = _lastRead != null && step != _lastRead;
    _lastRead = playing ? step : null;
    if (!playing || rate == 0 || !wasPlaying) {
      _stillReads = 0;
      return _snap(step, atUs, 0);
    }
    if (!moved) {
      if (oldRate == 0 || ++_stillReads >= 2) _snap(step, atUs, 0);
      return;
    }
    _stillReads = 0;
    if (oldRate == 0 || (rate - oldRate).abs() > oldRate * 1e-3) return _snap(step, atUs, rate);
    // The engine's step nearest where the line was: across a loop wrap, either way, if that is nearer.
    var target = step;
    final span = to - from;
    if (_inLoop) {
      for (final t in [step + span, step - span]) {
        if ((t - shown).abs() < (target - shown).abs()) target = t;
      }
    }
    final err = shown - target;
    // A jump (a seek, back to the start): there at once, held until the next read shows it running on from there.
    if (err.abs() > rate * snapUs) return _snap(step, atUs, 0);
    _base = target;
    _baseUs = atUs;
    _err = err;
    _rate = rate;
    _normalize();
  }

  void _snap(double step, int atUs, double rate) {
    _base = step;
    _baseUs = atUs;
    _err = 0;
    _rate = rate;
  }

  // Keeps the base inside the loop after a wrap was taken across it (the error stays as it was).
  void _normalize() {
    if (!_inLoop) return;
    final span = _to - _from;
    while (_base >= _to) {
      _base -= span;
    }
    while (_base < _from) {
      _base += span;
    }
  }

  double _unwrapped(int nowUs) {
    if (!_playing || _rate == 0) return _base;
    final dt = (nowUs - _baseUs).clamp(0, maxAheadUs).toDouble();
    return _base + _rate * dt + (_err == 0 ? 0 : _err * math.exp(-dt / settleUs));
  }

  /// The playhead at [nowUs], in steps.
  double at(int nowUs) {
    final x = _unwrapped(nowUs);
    if (!_playing || !_inLoop) return x;
    // Inside the loop the line wraps at its end exactly as the engine does (and a line still settling just short of
    // the start shows at the end, where it is).
    final span = _to - _from;
    var w = x;
    while (w >= _to) {
      w -= span;
    }
    while (w < _from) {
      w += span;
    }
    return w;
  }
}
