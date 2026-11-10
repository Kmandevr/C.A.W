// Shared touch feedback (owner, 2026-11-10: "anytime you touch or drag or do anything there should be feedback"):
// a pressed scale and glow for buttons, and grips that grow and light when grabbed, with haptics on grab and drop.
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';

/// How far a pressed control shrinks with Full motion (Reduced and Off keep only the glow).
const pressedScale = 0.92;

/// A control that dips and glows while a finger (or mouse button) is down on it. It only listens, so it never takes
/// a tap or a drag from what it wraps; a finger that moves off (a scroll starting) lets it go.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.enabled = true, this.glow, this.circle = false, this.radius = 10});
  final Widget child;
  final bool enabled;

  /// The glow's colour (the accent when null).
  final Color? glow;

  /// A round glow (play, record) instead of a rounded rectangle with [radius].
  final bool circle;
  final double radius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  Offset _at = Offset.zero;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final pressed = _down && widget.enabled;
    final color = widget.glow ?? Neon.green;
    final glow = DecoratedBox(
      decoration: BoxDecoration(
        shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circle ? null : BorderRadius.circular(widget.radius),
        boxShadow: pressed ? [BoxShadow(color: color.withValues(alpha: 0.32), blurRadius: 12, spreadRadius: 1)] : null,
      ),
      child: widget.child,
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _at = e.position;
        _set(true);
      },
      onPointerMove: (e) {
        if (_down && (e.position - _at).distance > 12) _set(false);
      },
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        key: const ValueKey('pressable'),
        scale: pressed && level == MotionLevel.full ? pressedScale : 1,
        duration: Motion.fade(Motion.small, level),
        curve: Curves.easeOut,
        child: glow,
      ),
    );
  }
}

/// Grab feedback for a drag handle's state: [grabbed] and [hovered] for its look, a haptic grab when a drag starts,
/// a drop when it ends, and a tick for each snap point crossed ([snapped]).
mixin GrabFeedback<T extends StatefulWidget> on State<T> {
  bool grabbed = false, hovered = false;

  void grab() {
    Haptics.grab();
    setState(() => grabbed = true);
  }

  void release({bool dropped = true}) {
    if (dropped) Haptics.drop();
    if (mounted) setState(() => grabbed = false);
  }

  void hover(bool on) {
    if (hovered != on) setState(() => hovered = on);
  }

  void snapped() => Haptics.tick();
}

/// A grip's mark: a short line across [axis] (a vertical line for a sideways drag) that grows and lights when
/// hovered or grabbed, and glows when [hot] (at a snap point, or past a threshold).
class GripMark extends StatelessWidget {
  const GripMark({super.key, required this.axis, this.grabbed = false, this.hovered = false, this.hot = false,
      this.length = 28, this.color, this.restColor, this.restThickness = 3});

  /// The drag's direction: [Axis.horizontal] draws an upright line.
  final Axis axis;
  final bool grabbed, hovered, hot;
  final double length;

  /// The lit colour (the accent when null).
  final Color? color;

  /// At rest: the colour (a faint grey when null) and the thickness, so each grip keeps its own quiet look.
  final Color? restColor;
  final double restThickness;

  @override
  Widget build(BuildContext context) {
    final lit = color ?? Neon.blue;
    final sideways = axis == Axis.horizontal;
    final long = grabbed ? length * 2 : hovered ? length * 1.4 : length;
    final thick = grabbed ? 4.0 : hovered ? 3.0 : restThickness;
    return AnimatedContainer(
      duration: Motion.fade(Motion.small, Motion.of(context)),
      curve: Curves.easeOut,
      width: sideways ? thick : long,
      height: sideways ? long : thick,
      decoration: BoxDecoration(
        color: grabbed || hovered
            ? (hot ? Neon.green : lit).withValues(alpha: 0.95)
            : restColor ?? Neon.dim.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(2),
        boxShadow: grabbed ? [BoxShadow(color: (hot ? Neon.green : lit).withValues(alpha: 0.45), blurRadius: 8)] : null,
      ),
    );
  }
}

/// A drag edge along [axis]: hover lights it (a resize cursor with a mouse), a drag grabs it (it grows, with a
/// haptic grab) and letting go drops it. [onDrag] gets the distance moved since the drag started.
class DragEdge extends StatefulWidget {
  const DragEdge({super.key, required this.axis, required this.onStart, required this.onDrag, required this.onEnd,
      this.onReset, this.hot = false, this.label = 'Resize', this.thickness = 18});
  final Axis axis;
  final VoidCallback onStart;
  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;

  /// Double-tap: back to the default size.
  final VoidCallback? onReset;

  /// At a snap point: the mark glows.
  final bool hot;
  final String label;

  /// The grab zone's size across the edge.
  final double thickness;

  @override
  State<DragEdge> createState() => _DragEdgeState();
}

class _DragEdgeState extends State<DragEdge> with GrabFeedback {
  double _moved = 0;

  @override
  Widget build(BuildContext context) {
    final sideways = widget.axis == Axis.horizontal;
    void start(DragStartDetails _) {
      _moved = 0;
      grab();
      widget.onStart();
    }

    void update(double d) {
      _moved += d;
      widget.onDrag(_moved);
    }

    void end([Object? _]) {
      release();
      widget.onEnd();
    }

    return Semantics(
      label: widget.label,
      child: MouseRegion(
        cursor: sideways ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        onEnter: (_) => hover(true),
        onExit: (_) => hover(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onDoubleTap: widget.onReset,
          onHorizontalDragStart: sideways ? start : null,
          onHorizontalDragUpdate: sideways ? (d) => update(d.delta.dx) : null,
          onHorizontalDragEnd: sideways ? end : null,
          onHorizontalDragCancel: sideways ? end : null,
          onVerticalDragStart: sideways ? null : start,
          onVerticalDragUpdate: sideways ? null : (d) => update(d.delta.dy),
          onVerticalDragEnd: sideways ? null : end,
          onVerticalDragCancel: sideways ? null : end,
          child: SizedBox(
            width: sideways ? widget.thickness : null,
            height: sideways ? null : widget.thickness,
            child: Center(child: GripMark(axis: widget.axis, grabbed: grabbed, hovered: hovered, hot: widget.hot)),
          ),
        ),
      ),
    );
  }
}
