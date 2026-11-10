// A drag a device visual claims at once (a handle, a curve), so the page's scroll doesn't take it; elsewhere it scrolls.
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../motion.dart';

/// Pans on [child] that begin where [grabs] says yes (everywhere by default) are claimed on touch-down; others go
/// to the scroll as usual. Two quick taps in place call [onDoubleTap] (the reset), since a claimed touch can't
/// also be a double-tap gesture.
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
  Offset _down = Offset.zero, _at = Offset.zero;
  DateTime _downAt = DateTime(0);
  DateTime? _lastTap;
  Offset _lastTapAt = Offset.zero;

  void _end() {
    widget.onEnd();
    final now = DateTime.now();
    final tap = (_at - _down).distance < 8 && now.difference(_downAt) < const Duration(milliseconds: 300);
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
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      _GrabRecognizer: GestureRecognizerFactoryWithHandlers<_GrabRecognizer>(
        () => _GrabRecognizer(),
        (r) => r
          ..grabs = widget.grabs
          ..onStart = (d) {
            _down = _at = d.localPosition;
            _downAt = DateTime.now();
            widget.onStart(d.localPosition);
          }
          ..onUpdate = (d) {
            _at = d.localPosition;
            widget.onUpdate(d.localPosition, d.delta);
          }
          ..onEnd = ((_) => _end())
          ..onCancel = widget.onEnd,
      ),
    },
    child: widget.child,
  );
}

class _GrabRecognizer extends PanGestureRecognizer {
  bool Function(Offset local)? grabs;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (grabs?.call(event.localPosition) ?? true) resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}
