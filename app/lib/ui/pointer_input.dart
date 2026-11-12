// Mouse and touch told apart: a drag that starts at once with a mouse (a hold with a finger), hint words for the
// input in use ("click" or "tap"), the mouse wheel stepping a value with one undo step per burst, the middle-button and
// Space+drag pan, and a counter that tells a second tap or click from a first without holding the first back.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A mouse or a trackpad: a pointer with buttons, a wheel and hover.
bool isMousePointer(PointerDeviceKind kind) => kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

/// The input the person is using now, for words in tooltips and hints: the kind of the last pointer that went down
/// or hovered, else a guess from the platform (a mouse on Windows, Linux and macOS).
class PointerInput {
  PointerInput._();

  static PointerDeviceKind? _last;
  static bool _listening = false;

  static void _route(PointerEvent e) {
    if (e is PointerDownEvent || e is PointerHoverEvent) _last = e.kind;
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
  }

  /// True when the last pointer was a mouse or trackpad (or, before any, on a desktop platform).
  static bool get mouse {
    _listen();
    final k = _last;
    if (k != null) return isMousePointer(k);
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
      _ => false,
    };
  }

  /// "click" with a mouse, "tap" with a finger.
  static String get tap => mouse ? 'click' : 'tap';

  /// "Click" or "Tap", to start a sentence.
  static String get tapCap => mouse ? 'Click' : 'Tap';

  /// "right-click" with a mouse, "long-press" with a finger.
  static String get hold => mouse ? 'right-click' : 'long-press';

  /// "Right-click" or "Long-press", to start a sentence.
  static String get holdCap => mouse ? 'Right-click' : 'Long-press';

  /// Forgets the last pointer (tests).
  @visibleForTesting
  static void reset() => _last = null;
}

/// A [LongPressDraggable] whose drag starts at once with a mouse (after a few pixels of movement, so a click is
/// still a click) and after the hold with a finger, as before.
class HoldDraggable<T extends Object> extends LongPressDraggable<T> {
  const HoldDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.axis,
    super.childWhenDragging,
    super.feedbackOffset,
    super.dragAnchorStrategy,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDraggableCanceled,
    super.onDragEnd,
    super.onDragCompleted,
    super.hapticFeedbackOnStart,
    super.ignoringFeedbackSemantics,
    super.ignoringFeedbackPointer,
    super.delay,
    super.allowedButtonsFilter,
    super.hitTestBehavior,
    super.rootOverlay,
  });

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(GestureMultiDragStartCallback onStart) =>
      _HoldOrMouseRecognizer(delay: delay, allowedButtonsFilter: allowedButtonsFilter)
        ..onStart = (Offset position) {
          final result = onStart(position);
          if (result != null && hapticFeedbackOnStart) HapticFeedback.selectionClick();
          return result;
        };
}

/// The hold for touch and stylus pointers; a mouse's pointer starts its drag once it has moved [_mouseSlop].
class _HoldOrMouseRecognizer extends DelayedMultiDragGestureRecognizer {
  _HoldOrMouseRecognizer({super.delay, super.allowedButtonsFilter});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) => isMousePointer(event.kind)
      ? _MousePointerState(event.position, event.kind, gestureSettings)
      : super.createNewPointerState(event);
}

/// A mouse moves this far (logical pixels) before its drag starts: below it, the press is a click.
const double _mouseSlop = 4;

class _MousePointerState extends MultiDragPointerState {
  _MousePointerState(super.initialPosition, super.kind, super.gestureSettings);

  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distance > _mouseSlop) resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) => starter(initialPosition);
}

/// The mouse wheel over [child] steps a value: [onStep] gets +1 for a turn up (away from you), -1 for down, and
/// whether Shift is held (a fine step). A burst of turns ends [burstGap] after the last one, with [onEnd] (the commit
/// that makes the burst one undo step). [cursor] shows while the mouse is over it. Touch is unaffected: fingers send
/// no wheel events.
class WheelSteps extends StatefulWidget {
  const WheelSteps({super.key, required this.onStep, this.onEnd, this.cursor, this.enabled = true, required this.child});
  final void Function(int dir, bool fine) onStep;
  final VoidCallback? onEnd;
  final MouseCursor? cursor;
  final bool enabled;
  final Widget child;

  /// How long after the last wheel turn the burst ends.
  static const burstGap = Duration(milliseconds: 400);

  @override
  State<WheelSteps> createState() => _WheelStepsState();
}

class _WheelStepsState extends State<WheelSteps> {
  Timer? _burst;

  @override
  void dispose() {
    if (_burst != null) {
      _burst!.cancel();
      _burst = null;
      widget.onEnd?.call();
    }
    super.dispose();
  }

  void _signal(PointerSignalEvent e) {
    if (!widget.enabled || e is! PointerScrollEvent) return;
    final d = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
    if (d == 0) return;
    // Registered first (the innermost listener), so the page around it does not scroll as well.
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      if (!mounted) return;
      widget.onStep(d < 0 ? 1 : -1, HardwareKeyboard.instance.isShiftPressed);
      _burst?.cancel();
      _burst = Timer(WheelSteps.burstGap, () {
        _burst = null;
        if (mounted) widget.onEnd?.call();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.cursor == null || !widget.enabled
        ? widget.child
        : MouseRegion(cursor: widget.cursor!, child: widget.child);
    return Listener(onPointerSignal: _signal, child: child);
  }
}

/// A pan control's value after one wheel turn: 1% of its -1..1 travel (a fifth of that with Shift), clamped to -1..1.
double panWheelStep(double pan, int dir, bool fine) => (pan + dir * (fine ? 0.004 : 0.02)).clamp(-1.0, 1.0).toDouble();

/// A mouse press that pans the view instead of editing (owner, 2026-11-11): the middle button, or the left button
/// while Space is held. Touch and stylus never pan this way.
bool startsMousePan(PointerDownEvent e) {
  if (!isMousePointer(e.kind)) return false;
  if (e.buttons & kMiddleMouseButton != 0) return true;
  return e.buttons == kPrimaryMouseButton && SpacePan.held;
}

/// Space as a pan modifier. Space also plays and pauses on its key-down, so a Space+drag pan takes that press back:
/// the key router arms [armUndo] when Space runs play/pause, and the first pan while Space is still held calls it.
class SpacePan {
  SpacePan._();

  static VoidCallback? _undo;

  /// True while Space is down.
  static bool get held => HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.space);

  /// Space just ran [undo]'s opposite (play or pause); a pan before it is released takes it back.
  static void armUndo(VoidCallback undo) => _undo = undo;

  /// A Space+drag pan started: undoes what this Space press did, once.
  static void claim() {
    final u = _undo;
    _undo = null;
    if (u != null && held) u();
  }
}

/// Drags the views behind [h] and [v] by a mouse pan's movement (the content follows the pointer).
void panBy(Offset delta, {ScrollController? h, ScrollController? v}) {
  void move(ScrollController? c, double d) {
    if (c == null || !c.hasClients || d == 0) return;
    final p = c.positions.last;
    p.jumpTo((p.pixels - d).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble());
  }

  move(h, delta.dx);
  move(v, delta.dy);
}

/// Tells a second tap or click from a first, for a widget whose taps answer at once (owner, 2026-11-11: a tap
/// selects at once; a quick second tap adds the double tap's action, such as the menu). Feed it every press and lift
/// ([down] and [up], from a [Listener], which takes no part in the gesture arena) and ask [doubleClick],
/// [doubleTap] or [twice] in the tap's callback, which comes after the press.
///
/// A mouse's double-click is its second left click within [kDoubleTapTimeout] of the first press; a finger's (or
/// pen's) double tap is its second press within [kDoubleTapTimeout] of the first tap's lift, as Flutter's own double
/// tap counts it. Both land within [kDoubleTapSlop] of the first press, on the same [down] `target` (a widget shared
/// by several items names the item), and a third press starts again. A press with `anywhere` (a widget that moved
/// under the finger after the first tap, such as the focus view's pinned track) counts wherever it lands on that
/// target.
class ClickCounter {
  // When the window for a second press closes: a first click's press (a mouse) or a first tap's lift (a finger) plus
  // the double-tap time. The gesture binding's clock is the wall clock, and a test's fake clock under test.
  DateTime? _windowEnd;
  DateTime _downAt = DateTime(0);
  Offset _lastPos = Offset.zero, _local = Offset.zero;
  Object? _lastTarget;
  int? _pointer; // the counted finger press, until it lifts
  bool _mouse = false, _double = false;

  static DateTime get _now => GestureBinding.instance.samplingClock.now();

  /// Whether the last press was a mouse's.
  bool get mouse => _mouse;

  /// Whether the last press was a mouse's second click, soon enough after and close enough to the first.
  bool get doubleClick => _mouse && _double;

  /// Whether the last press was a finger's or pen's second tap, soon enough after and close enough to the first.
  bool get doubleTap => !_mouse && _double;

  /// A double-click or a double tap.
  bool get twice => _double;

  /// What the last press went to.
  Object? get lastTarget => _lastTarget;

  /// Where the last press went down, globally and in the [Listener]'s own coordinates.
  Offset get position => _lastPos;
  Offset get localPosition => _local;

  /// A press. With [anywhere] a second press on the same [target] counts wherever it lands (a track the first tap
  /// moved).
  void down(PointerDownEvent e, {Object? target, bool anywhere = false}) {
    final now = _now;
    _mouse = isMousePointer(e.kind);
    // Only the left button double-clicks; a right-click neither counts nor opens the window.
    final counts = !_mouse || e.buttons == kPrimaryMouseButton;
    final end = _windowEnd;
    _double = counts && end != null && !now.isAfter(end) && target == _lastTarget &&
        (anywhere || (e.position - _lastPos).distance <= kDoubleTapSlop);
    // A mouse's window opens at its first click; a finger's at its first tap's lift ([up]). A third press starts again.
    _windowEnd = _mouse && counts && !_double ? now.add(kDoubleTapTimeout) : null;
    _pointer = !_mouse && counts && !_double ? e.pointer : null;
    _lastPos = e.position;
    _local = e.localPosition;
    _lastTarget = target;
    _downAt = now;
    _lastPointer = e.pointer;
  }

  /// The pointer of the last press counted.
  int? get lastPointer => _lastPointer;
  int? _lastPointer;

  /// How near the first press a [secondHere] must land: a finger's second tap, not a neighbour's.
  static const herePx = 36.0;

  /// A press that lands where the first one did, inside the window, on something that isn't a target (what was under
  /// the first moved away): counted as the second press of [lastTarget] ([twice]). False, and nothing counted, when
  /// it doesn't.
  bool secondHere(PointerDownEvent e) {
    if (e.pointer == _lastPointer) return false;
    final end = _windowEnd;
    if (end == null || _now.isAfter(end) || (e.position - _lastPos).distance > herePx) return false;
    down(e, target: _lastTarget);
    return _double;
  }

  /// A lift: a finger's first tap (short, and not moved past the touch slop) opens the window for its second.
  void up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final now = _now;
    if ((e.position - _lastPos).distance <= kDoubleTapTouchSlop && now.difference(_downAt) < kLongPressTimeout) {
      _windowEnd = now.add(kDoubleTapTimeout);
    }
  }

  /// Forgets the presses so far: the next one is a first (a press that went to something else, such as a button).
  void reset() {
    _windowEnd = null;
    _pointer = null;
    _double = false;
  }
}
