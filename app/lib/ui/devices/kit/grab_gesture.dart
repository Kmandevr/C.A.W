// The one gesture surface every hero visual uses: grab (one finger drags, two pinch), tap, double-tap, long-press, right-click and the mouse wheel.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'feel.dart';

/// A drag or pinch on a hero visual. [pointers] is how many fingers are down; [scale] is the pinch's spread since
/// it started (1 with one finger).
class GrabUpdate {
  const GrabUpdate(this.local, this.delta, this.scale, this.pointers);
  final Offset local, delta;
  final double scale;
  final int pointers;
}

/// Touches that begin where [grabs] says yes (everywhere by default) are claimed at once, so the page's scroll
/// doesn't take them; others scroll as usual. Taps, double-taps and long-presses are seen anywhere on [child].
/// A second finger during a grab turns it into a pinch ([onStart] again with two pointers). A pinch also slows
/// single-finger drags elsewhere ([DeviceFingers.fine]).
class GrabGesture extends StatefulWidget {
  const GrabGesture({super.key, required this.child, this.grabs, this.onStart, this.onUpdate, this.onEnd, this.onTap,
    this.onDoubleTap, this.onLongPress, this.onSecondaryTap, this.onScroll});
  final Widget child;
  final bool Function(Offset local)? grabs;
  final void Function(Offset local, int pointers)? onStart;
  final void Function(GrabUpdate u)? onUpdate;
  final VoidCallback? onEnd;
  final void Function(Offset local)? onTap, onDoubleTap, onLongPress;

  /// A right-click (a mouse's secondary button); null runs [onLongPress] there, so a right-click opens what a
  /// long-press does.
  final void Function(Offset local)? onSecondaryTap;

  /// The mouse wheel over [child] (a desktop's Q or fine value): [dy] in wheel pixels, down positive.
  final void Function(Offset local, double dy)? onScroll;

  @override
  State<GrabGesture> createState() => _GrabGestureState();
}

class _GrabGestureState extends State<GrabGesture> {
  int? _pointer;
  Offset _down = Offset.zero;
  DateTime _downAt = DateTime(0);
  bool _moved = false;
  Timer? _press;
  DateTime? _lastTap;
  Offset _lastTapAt = Offset.zero;
  bool _grabbing = false;
  int? _secondary; // a right button down

  @override
  void dispose() {
    _press?.cancel();
    super.dispose();
  }

  // The gesture binding's sampling clock: the wall clock in the app, the test's fake clock under test, so a busy
  // machine can't split a double tap (ClickCounter in pointer_input.dart reads the same clock).
  static DateTime get _now => GestureBinding.instance.samplingClock.now();

  void _pointerDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
      _secondary = e.pointer;
      return;
    }
    if (_pointer != null) {
      _press?.cancel(); // a second finger: no tap or long press
      _moved = true;
      return;
    }
    _pointer = e.pointer;
    _down = e.localPosition;
    _downAt = _now;
    _moved = false;
    _press?.cancel();
    if (widget.onLongPress != null) {
      _press = Timer(const Duration(milliseconds: 480), () {
        if (_pointer != null && !_moved) {
          _moved = true; // no tap after it
          DeviceFeel.tap();
          widget.onLongPress!(_down);
        }
      });
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (e.pointer == _pointer && (e.localPosition - _down).distance > 8) {
      _moved = true;
      _press?.cancel();
    }
  }

  void _pointerUp(PointerUpEvent e) {
    if (e.pointer == _secondary) {
      _secondary = null;
      final menu = widget.onSecondaryTap ?? widget.onLongPress;
      if (menu != null) {
        DeviceFeel.tap();
        menu(e.localPosition);
      }
      return;
    }
    if (e.pointer != _pointer) return;
    _pointer = null;
    _press?.cancel();
    final now = _now;
    if (_moved || now.difference(_downAt) > const Duration(milliseconds: 300)) {
      _lastTap = null;
      return;
    }
    if (_lastTap != null && now.difference(_lastTap!) < const Duration(milliseconds: 350) &&
        (_down - _lastTapAt).distance < 24 && widget.onDoubleTap != null) {
      _lastTap = null;
      DeviceFeel.tap();
      widget.onDoubleTap!(_down);
      return;
    }
    _lastTap = now;
    _lastTapAt = _down;
    widget.onTap?.call(_down);
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: _pointerDown,
    onPointerMove: _pointerMove,
    onPointerUp: _pointerUp,
    onPointerCancel: (e) {
      if (e.pointer == _secondary) _secondary = null;
      if (e.pointer == _pointer) _pointer = null;
      _press?.cancel();
    },
    onPointerSignal: widget.onScroll == null ? null : (s) {
      if (s is PointerScrollEvent) {
        GestureBinding.instance.pointerSignalResolver.register(s, (s) {
          widget.onScroll!(s.localPosition, (s as PointerScrollEvent).scrollDelta.dy);
        });
      }
    },
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _GrabScaleRecognizer: GestureRecognizerFactoryWithHandlers<_GrabScaleRecognizer>(
          () => _GrabScaleRecognizer(),
          (r) => r
            ..grabs = widget.grabs
            ..onStart = (d) {
              _grabbing = true;
              if (d.pointerCount == 1) DeviceFeel.grab();
              widget.onStart?.call(d.localFocalPoint, d.pointerCount);
            }
            ..onUpdate = (d) {
              widget.onUpdate?.call(GrabUpdate(d.localFocalPoint, d.focalPointDelta, d.pointerCount >= 2 ? d.scale : 1,
                  d.pointerCount));
            }
            ..onEnd = (_) {
              if (!_grabbing) return;
              _grabbing = false;
              DeviceFeel.release();
              widget.onEnd?.call();
            },
        ),
      },
      child: widget.child,
    ),
  );
}

class _GrabScaleRecognizer extends ScaleGestureRecognizer {
  bool Function(Offset local)? grabs;
  int _tracked = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final local = event.localPosition;
    if (_tracked == 0 && !(grabs?.call(local) ?? true)) return; // left to the scroll
    _tracked++;
    super.addAllowedPointer(event);
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _tracked = 0;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    if (_tracked > 0) _tracked--;
  }
}
