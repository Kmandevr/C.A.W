// Arrange's edit animations (owner, 2026-11-11): clips and tracks that an edit adds, deletes, moves, nests or
// resizes glide, open and close instead of jumping. Drag ghosts and snapping are not edits and stay as they are.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../motion.dart';

/// Clips whose next change comes straight from the finger (a trim, a stretch, a move on the pinned track): the clip
/// is already drawn where it lands, so it doesn't glide there again. The clip adds its id just before it commits.
final Set<String> directClipEdits = {};

/// A clip's place in its lane. A move glides to the new place (clips), a new length or height to the new size
/// (lengths); a clip an edit added grows in from a little smaller ([appear]). Zooming ([scale] changes) never glides.
class ClipSlot extends StatefulWidget {
  const ClipSlot({super.key, required this.id, required this.rect, required this.scale, required this.child,
    this.appear = false});
  final String id;
  final Rect rect;

  /// What sets pixels per step and the track height: a change in it is a zoom, drawn at once.
  final Object scale;
  final bool appear;
  final Widget child;

  @override
  State<ClipSlot> createState() => _ClipSlotState();
}

class _ClipSlotState extends State<ClipSlot> with SingleTickerProviderStateMixin {
  Duration _glide = Duration.zero;
  Curve _curve = EditMotion.curve;
  AnimationController? _in;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_in != null || !widget.appear) return;
    final d = EditMotion.of(context, EditMotionKind.clips);
    if (d == null) return;
    _in = AnimationController(vsync: this, duration: d)..forward();
  }

  @override
  void didUpdateWidget(ClipSlot old) {
    super.didUpdateWidget(old);
    final direct = directClipEdits.remove(widget.id);
    if (old.rect == widget.rect) return;
    if (direct || old.scale != widget.scale) {
      _glide = Duration.zero;
      return;
    }
    final kind = old.rect.topLeft != widget.rect.topLeft ? EditMotionKind.clips : EditMotionKind.lengths;
    // A move alone (the same size somewhere else) is a short, snappy slide (owner, 2026-11-11).
    if (old.rect.size == widget.rect.size) {
      _glide = EditMotion.nudge(context, kind) ?? Duration.zero;
      _curve = EditMotion.nudgeCurve;
      return;
    }
    _glide = EditMotion.fadeOnly(context) ? Duration.zero : EditMotion.of(context, kind) ?? Duration.zero;
    _curve = EditMotion.curve;
  }

  @override
  void dispose() {
    _in?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var child = widget.child;
    final appear = _in;
    if (appear != null && EditMotion.feel.enter != MotionTransition.standard) {
      child = EditMotion.transition(appear, child, fadeOnly: EditMotion.fadeOnly(context)); // the theme's entrance
    } else if (appear != null) {
      final t = CurvedAnimation(parent: appear, curve: EditMotion.curve);
      child = FadeTransition(opacity: CurvedAnimation(parent: appear, curve: Curves.easeOut), child: EditMotion.fadeOnly(context)
          ? child
          : ScaleTransition(scale: Tween(begin: 0.82, end: 1.0).animate(t), alignment: Alignment.centerLeft, child: child));
    }
    return AnimatedPositioned.fromRect(rect: widget.rect, duration: _glide, curve: _curve, child: child);
  }
}

/// A deleted clip on its way out: it shrinks and fades where it was, then [onDone] drops it.
class LeavingClip extends StatefulWidget {
  const LeavingClip({super.key, required this.rect, required this.color, required this.name,
    required this.duration, required this.onDone});
  final Rect rect;
  final Color color;
  final String name;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<LeavingClip> createState() => _LeavingClipState();
}

class _LeavingClipState extends State<LeavingClip> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.duration)
    ..forward().whenComplete(() { if (mounted) widget.onDone(); });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = CurvedAnimation(parent: _c, curve: EditMotion.exitCurve);
    final box = Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: widget.color.withValues(alpha: 0.25),
        border: Border.all(color: widget.color)),
      padding: const EdgeInsets.fromLTRB(13, 4, 6, 3),
      alignment: Alignment.topLeft,
      child: Text(widget.name, maxLines: 1, overflow: TextOverflow.clip,
        style: TextStyle(color: widget.color, fontSize: 10, fontWeight: FontWeight.w800)));
    if (EditMotion.feel.exit != MotionTransition.standard) {
      // The theme's exit kind, run backwards from shown to gone.
      return Positioned.fromRect(rect: widget.rect, child: IgnorePointer(child: KeyedSubtree(
          key: const ValueKey('clip-leaving'),
          child: EditMotion.transition(ReverseAnimation(_c), box, enter: false, fadeOnly: EditMotion.fadeOnly(context)))));
    }
    return Positioned.fromRect(rect: widget.rect, child: IgnorePointer(child: FadeTransition(
      key: const ValueKey('clip-leaving'),
      opacity: Tween(begin: 1.0, end: 0.0).animate(t),
      child: EditMotion.fadeOnly(context) ? box
          : ScaleTransition(scale: Tween(begin: 1.0, end: 0.6).animate(t), child: box))));
  }
}

/// One track's row (its header side or its lane side): when an edit moves it (a track added, deleted, reordered or
/// nested above it, lanes opened) it glides from where it was, so the rows under a new track slide open for it and
/// close over a deleted one; a track an edit added fades and grows in. Where each
/// row stood is kept in [memory], by [id]; a change of [epoch] (the track height) moves rows without a glide.
class TrackRowMotion extends StatefulWidget {
  const TrackRowMotion({super.key, required this.id, required this.memory, required this.epoch, required this.child,
    this.appear = false});
  final String id;
  final Map<String, (double, Object)> memory;
  final Object epoch;
  final bool appear;
  final Widget child;

  @override
  State<TrackRowMotion> createState() => _TrackRowMotionState();
}

class _TrackRowMotionState extends State<TrackRowMotion> with TickerProviderStateMixin {
  AnimationController? _slide, _in;
  double _from = 0;

  /// Smaller moves are a spacer or lane being dragged by the finger, which must follow it at once.
  static const _least = 20.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_in != null || !widget.appear) return;
    final d = EditMotion.of(context, EditMotionKind.tracks);
    if (d == null) return;
    _in = AnimationController(vsync: this, duration: d)..forward();
  }

  void _measure(Duration _) {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.parentData is! BoxParentData) return;
    final y = (box.parentData! as BoxParentData).offset.dy;
    final before = widget.memory[widget.id];
    widget.memory[widget.id] = (y, widget.epoch);
    if (before == null || before.$2 != widget.epoch || (before.$1 - y).abs() < _least) return;
    final d = EditMotion.of(context, EditMotionKind.tracks);
    if (d == null || EditMotion.fadeOnly(context)) return;
    // From where it shows now (a glide already under way included) to its new place.
    final shown = before.$1 + (_slide == null ? 0 : _from * (1 - EditMotion.curve.transform(_slide!.value)));
    _from = shown - y;
    (_slide ??= AnimationController(vsync: this)..addListener(() => setState(() {})))
      ..duration = d
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _slide?.dispose();
    _in?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_measure);
    final s = _slide;
    final dy = s == null || !s.isAnimating ? 0.0 : _from * (1 - EditMotion.curve.transform(s.value));
    Widget child = widget.child;
    final appear = _in;
    if (appear != null) {
      child = FadeTransition(opacity: CurvedAnimation(parent: appear, curve: Curves.easeOut), child: EditMotion.fadeOnly(context)
          ? child
          : ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: appear,
              curve: EditMotion.curve)), alignment: Alignment.centerLeft, child: child));
    }
    // Its own layer, so a glide moves a picture instead of repainting the tracks.
    return RepaintBoundary(child: Transform.translate(offset: Offset(0, dy), child: child));
  }
}
