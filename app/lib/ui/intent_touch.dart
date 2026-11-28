// A finger or button down anywhere on a track's controls is play-ahead intent (PlayAheadIntent): the track is held live from the down to the up, with nothing drawn.
import 'package:flutter/widgets.dart';

import '../model/play_ahead_intent.dart';

/// [child] with every pointer down on it holding [layerId] live in play-ahead until that pointer is up again.
/// It draws nothing and takes no gesture (a plain [Listener]), so the controls under it work as before.
class IntentTouch extends StatefulWidget {
  const IntentTouch({super.key, required this.intent, required this.layerId, required this.child});
  final PlayAheadIntent intent;
  final String? layerId;  // null (the master): nothing to hold
  final Widget child;

  @override
  State<IntentTouch> createState() => _IntentTouchState();
}

class _IntentTouchState extends State<IntentTouch> {
  final Set<int> _down = {};

  void _sync() {
    final id = widget.layerId;
    widget.intent.holdSet(this, _down.isEmpty || id == null ? const {} : {id});
  }

  @override
  void didUpdateWidget(IntentTouch old) {
    super.didUpdateWidget(old);
    if (!identical(old.intent, widget.intent)) old.intent.release(this);
    _sync();
  }

  @override
  void dispose() {
    widget.intent.release(this);
    super.dispose();
  }

  void _up(PointerEvent e) {
    if (_down.remove(e.pointer)) _sync();
  }

  @override
  Widget build(BuildContext context) => Listener(
      onPointerDown: (e) {
        if (_down.add(e.pointer)) _sync();
      },
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.child);
}
