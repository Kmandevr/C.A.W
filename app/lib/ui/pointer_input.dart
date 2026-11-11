// Mouse and touch told apart: a drag that starts at once with a mouse (a hold with a finger), hint words for the
// input in use ("click" or "tap"), and the mouse wheel stepping a value with one undo step per burst.
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
