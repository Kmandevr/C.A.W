// When a touch on a device page's control is the control's and when it is the page's scroll: knobs turn with a sideways drag (or the old up-and-down drag after a hold), a visual's grab on a hold, a slow start or sideways motion; a quick vertical swipe scrolls. The mouse engages at once, as before.
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
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
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
      if (d.dx.abs() >= (gestureSettings?.touchSlop ?? kTouchSlop) / 2 && d.dx.abs() * 2 >= d.dy.abs()) _engage();
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

/// How knobs take a drag (owner, 2026-11-24): `sideways` (the default) turns a knob with a deliberate sideways drag at
/// once, and a hold first still takes any direction for fine moves, so an up-and-down swipe scrolls the page; off, the
/// old up-and-down drag after [touchEngageHold] ([EngageVerticalDrag]). Settings › Haptics and menus sets it.
abstract final class KnobDrag {
  static bool sideways = true;
}

/// A knob's pan: claimed at once by a mouse; by a finger on a deliberate sideways move (past half the touch slop
/// within about 27° of horizontal) at once, or, once it has rested [touchEngageHold] (or with a second finger), on any
/// move past the pan slop; a quick vertical swipe goes to the scroll. Like [EngageVerticalDragRecognizer] it never
/// wins on the hold alone, so a tap, a double-tap and a long-press (the knob's menu) still work.
class EngageKnobPanRecognizer extends PanGestureRecognizer {
  EngageKnobPanRecognizer({super.debugOwner});

  final Map<int, (DateTime, Offset)> _down = {};
  int? _pointer;
  Offset _at = Offset.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _down[event.pointer] = (_now(), event.position);
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    _pointer = event.pointer;
    if (event is PointerMoveEvent) _at = event.position;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) {
    final down = _down[_pointer];
    if (down == null || !waitsToEngage(pointerDeviceKind)) {
      return super.hasSufficientGlobalDistanceToAccept(pointerDeviceKind, deviceTouchSlop);
    }
    if (_down.length >= 2) return true;  // two fingers on the knob (its amount) are never the page's scroll
    final m = _at - down.$2;
    final slop = deviceTouchSlop ?? kTouchSlop;
    if (m.dx.abs() >= slop / 2 && m.dx.abs() * 2 >= m.dy.abs()) return true;  // a deliberate sideways move
    // A quick swipe is the page's scroll; after the hold any move past the touch slop is the knob's (as the
    // up-and-down drag's, so the scroll does not take it first).
    if (_now().difference(down.$1) < touchEngageHold) return false;
    return m.distance >= slop;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _down.clear();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'engage knob pan';
}

/// A knob's drag, as [KnobDrag] says: sideways, its handlers get a vertical delta made of both axes (right or up turns
/// it up: `dy - dx`), so a knob written for the up-and-down drag needs no change; otherwise [EngageVerticalDrag].
class EngageKnobDrag extends StatelessWidget {
  const EngageKnobDrag({super.key, required this.child, this.onStart, this.onUpdate, this.onEnd, this.onCancel});
  final Widget child;
  final GestureDragStartCallback? onStart;
  final GestureDragUpdateCallback? onUpdate;
  final GestureDragEndCallback? onEnd;
  final GestureDragCancelCallback? onCancel;

  static DragUpdateDetails folded(DragUpdateDetails d) {
    final dy = d.delta.dy - d.delta.dx;
    return DragUpdateDetails(
      sourceTimeStamp: d.sourceTimeStamp,
      delta: Offset(0, dy),
      primaryDelta: dy,
      globalPosition: d.globalPosition,
      localPosition: d.localPosition,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!KnobDrag.sideways) {
      return EngageVerticalDrag(onStart: onStart, onUpdate: onUpdate, onEnd: onEnd, onCancel: onCancel, child: child);
    }
    final update = onUpdate;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        if (onStart != null || onUpdate != null || onEnd != null)
          EngageKnobPanRecognizer: GestureRecognizerFactoryWithHandlers<EngageKnobPanRecognizer>(
            () => EngageKnobPanRecognizer(debugOwner: this),
            (r) => r
              ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
              ..onStart = onStart
              ..onUpdate = update == null ? null : (d) { update(folded(d)); }
              ..onEnd = onEnd
              ..onCancel = onCancel,
          ),
      },
      child: child,
    );
  }
}
