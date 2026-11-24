// When a touch on a device page's control is the control's and when it is the page's scroll: a short hold, a slow start or sideways motion engages the control; a quick vertical swipe scrolls. The mouse engages at once, as before.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// How long a finger rests on a control before it is the control's: Flutter's [kPressTimeout] (100 ms), the
/// press delay a scrolling container gives its children on Android and iOS, so a swipe that moves past the touch
/// slop sooner than this belongs to the scroll.
const Duration touchEngageHold = kPressTimeout;

/// Whether a pointer of [kind] waits for [touchEngageHold] before a control takes it: fingers and pens do; a
/// mouse or trackpad engages at once (a desktop's drag is never a scroll).
bool waitsToEngage(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus || kind == PointerDeviceKind.invertedStylus;

// The gesture binding's sampling clock: the wall clock in the app, the test's fake clock under test.
DateTime _now() => GestureBinding.instance.samplingClock.now();

/// A vertical drag (a knob's) that a finger engages only after resting [touchEngageHold] on the control: a drag
/// that starts slowly (or with two fingers on the control) is the control's at the usual slop, and one that crosses
/// the slop sooner is left to the page's scroll (with no scroll around it the control still gets it, as the arena's last member). It never wins on the
/// hold alone, so a tap, a double-tap and a long-press on the same control still work.
class EngageVerticalDragRecognizer extends VerticalDragGestureRecognizer {
  EngageVerticalDragRecognizer({super.debugOwner});

  final Map<int, DateTime> _downAt = {};
  int? _pointer; // the pointer of the event being handled

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downAt[event.pointer] = _now();
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    _pointer = event.pointer;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) {
    final down = _downAt[_pointer];
    // Two fingers on the control (a knob's amount) are never the page's scroll.
    if (waitsToEngage(pointerDeviceKind) && down != null && _downAt.length < 2 &&
        _now().difference(down) < touchEngageHold) {
      return false;
    }
    return super.hasSufficientGlobalDistanceToAccept(pointerDeviceKind, deviceTouchSlop);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _downAt.clear();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'engage vertical drag';
}

/// [child] with a vertical drag through [EngageVerticalDragRecognizer]: what a knob's `onVerticalDrag…` callbacks
/// become, so the page under it still scrolls on a swipe.
class EngageVerticalDrag extends StatelessWidget {
  const EngageVerticalDrag({super.key, required this.child, this.onStart, this.onUpdate, this.onEnd, this.onCancel});
  final Widget child;
  final GestureDragStartCallback? onStart;
  final GestureDragUpdateCallback? onUpdate;
  final GestureDragEndCallback? onEnd;
  final GestureDragCancelCallback? onCancel;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          if (onStart != null || onUpdate != null || onEnd != null)
            EngageVerticalDragRecognizer: GestureRecognizerFactoryWithHandlers<EngageVerticalDragRecognizer>(
              () => EngageVerticalDragRecognizer(debugOwner: this),
              (r) => r
                ..onStart = onStart
                ..onUpdate = onUpdate
                ..onEnd = onEnd
                ..onCancel = onCancel,
            ),
        },
        child: child,
      );
}

/// For a visual's grab (a pan or a pinch) that used to claim a touch on contact: a finger is claimed once it has
/// rested [touchEngageHold], moved sideways past half the touch slop at more than about 27° from vertical (a scroll
/// swipe runs closer to vertical than that), or been joined by a second finger (a pinch); a quick vertical swipe before then is left to the scroll.
/// A mouse is claimed at once. Call [engageOnDown] from `addAllowedPointer` after `super`.
mixin EngageOnHold on OneSequenceGestureRecognizer {
  Timer? _hold;
  int? _first;
  Offset _from = Offset.zero;
  bool _waiting = false;

  /// [event] is now tracked: claim it at once, or wait for the hold, the sideways move or a second finger.
  void engageOnDown(PointerDownEvent event) {
    if (_waiting || !waitsToEngage(event.kind)) {
      _engage();
      return;
    }
    _first = event.pointer;
    _from = event.position;
    _waiting = true;
    _hold?.cancel();
    _hold = Timer(touchEngageHold, _engage);
  }

  void _engage() {
    _hold?.cancel();
    _hold = null;
    _waiting = false;
    resolve(GestureDisposition.accepted);
  }

  void _stopWaiting() {
    _hold?.cancel();
    _hold = null;
    _waiting = false;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_waiting && event is PointerMoveEvent && event.pointer == _first) {
      final d = event.position - _from;
      if (d.dx.abs() >= kTouchSlop / 2 && d.dx.abs() * 2 >= d.dy.abs()) _engage();
    }
    super.handleEvent(event);
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == _first) _stopWaiting();
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _stopWaiting();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void dispose() {
    _stopWaiting();
    super.dispose();
  }
}
