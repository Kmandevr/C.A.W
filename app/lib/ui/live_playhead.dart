// Draws the playhead at the screen's rate while playing: a ticker that runs only during playback, off when stopped.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../model/app_state.dart';
import '../model/playhead_clock.dart' show PlayheadClock;

/// Builds [builder] on every engine read ([AppState.tick]) and, while the song plays and the line runs on
/// ([PlayheadClock.running]), on every frame as well, so a playhead drawn from [AppState.smoothPlayheadStep] moves at
/// the screen's rate (the frame-rate setting) instead of the reads' 30 a second. Stopped or holding (a count-in), the
/// ticker is off and no frame is asked for, so Auto's idle drop still comes;
/// in a sleeping section or a hidden tab ([TickerMode] off) it doesn't run either. [onFrame] runs first in each
/// frame (the arranger's smooth follow).
class PlayheadFrames extends StatefulWidget {
  const PlayheadFrames({super.key, required this.state, required this.builder, this.onFrame});
  final AppState state;
  final WidgetBuilder builder;
  final VoidCallback? onFrame;

  @override
  State<PlayheadFrames> createState() => _PlayheadFramesState();
}

class _PlayheadFramesState extends State<PlayheadFrames> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_frame);

  @override
  void initState() {
    super.initState();
    widget.state.tick.addListener(_read);
    _follow();
  }

  @override
  void didUpdateWidget(PlayheadFrames old) {
    super.didUpdateWidget(old);
    if (!identical(old.state, widget.state)) {
      old.state.tick.removeListener(_read);
      widget.state.tick.addListener(_read);
      _follow();
    }
  }

  @override
  void dispose() {
    widget.state.tick.removeListener(_read);
    _ticker.dispose();
    super.dispose();
  }

  // The ticker runs while the line runs on, and stops with it.
  void _follow() {
    final s = widget.state;
    final playing = s.meters.playing && s.meters.loopLength > 0 && s.playheadClock.running;
    if (playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _read() {
    _follow();
    if (mounted) setState(() {});
  }

  void _frame(Duration _) {
    widget.onFrame?.call();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
