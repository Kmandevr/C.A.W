// A drag on a device visual (a handle, a curve): claimed after a short rest, a sideways move or at once by a mouse (kit/touch_engage.dart), so a quick vertical swipe scrolls the page; elsewhere it scrolls.
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../motion.dart';
import '../kit/touch_engage.dart';

/// Pans on [child] that begin where [grabs] says yes (everywhere by default) are claimed once a finger rests a
/// moment or moves sideways (at once with a mouse); a quick vertical swipe and touches elsewhere go to the scroll.
/// Two quick taps in place call [onDoubleTap] (the reset), seen by a [Listener] whether or not the pan was claimed.
class GrabPan extends StatefulWidget {
  const GrabPan({super.key, required this.child, required this.onStart, required this.onUpdate, required this.onEnd,
    this.grabs, this.onDoubleTap});
  final Widget child;
  final bool Function(Offset local)? grabs;
  final void Function(Offset local) onStart;
  final void Function(Offset local, Offset delta) onUpdate;
  final VoidCallback onEnd;
  final VoidCallback? onDoubleTap;

  @override
  State<GrabPan> createState() => _GrabPanState();
}

class _GrabPanState extends State<GrabPan> {
  int? _pointer;
  Offset _down = Offset.zero;
  DateTime _downAt = DateTime(0);
  bool _moved = false;
  DateTime? _lastTap;
  Offset _lastTapAt = Offset.zero;

  // The gesture binding's sampling clock (the test's fake clock under test), as GrabGesture and ClickCounter read.
  static DateTime get _now => GestureBinding.instance.samplingClock.now();

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final now = _now;
    final tap = !_moved && now.difference(_downAt) < const Duration(milliseconds: 300);
    if (!tap) {
      _lastTap = null;
      return;
    }
    if (_lastTap != null && now.difference(_lastTap!) < const Duration(milliseconds: 350) &&
        (_down - _lastTapAt).distance < 24 && widget.onDoubleTap != null) {
      _lastTap = null;
      Motion.tick();
      widget.onDoubleTap!();
    } else {
      _lastTap = now;
      _lastTapAt = _down;
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (e) {
      if (_pointer != null) return;
      _pointer = e.pointer;
      _down = e.localPosition;
      _downAt = _now;
      _moved = false;
    },
    onPointerMove: (e) {
      if (e.pointer == _pointer && (e.localPosition - _down).distance >= 8) _moved = true;
    },
    onPointerUp: _up,
    onPointerCancel: (e) {
      if (e.pointer == _pointer) _pointer = null;
    },
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _GrabRecognizer: GestureRecognizerFactoryWithHandlers<_GrabRecognizer>(
          () => _GrabRecognizer(),
          (r) => r
            ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
            ..grabs = widget.grabs
            ..onStart = ((d) => widget.onStart(d.localPosition))
            ..onUpdate = ((d) => widget.onUpdate(d.localPosition, d.delta))
            ..onEnd = ((_) => widget.onEnd())
            ..onCancel = widget.onEnd,
        ),
      },
      child: widget.child,
    ),
  );
}

class _GrabRecognizer extends PanGestureRecognizer with EngageOnHold {
  bool Function(Offset local)? grabs;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (grabs?.call(event.localPosition) ?? true) engageOnDown(event); // touch_engage.dart
  }
}
