// Panels that leave as they came (owner, 2026-11-11: everything that animates in animates out): a child that slides
// and fades in, and when it goes (null) slides and fades back out before it is removed, in the panels edit-motion
// kind; a fade alone with Reduced motion, at once with Off.
import 'package:flutter/widgets.dart';

import 'motion.dart';

class Presence extends StatefulWidget {
  const Presence({super.key, required this.child, this.from = const Offset(0, 0.1)});

  /// What shows; null takes the last one out.
  final Widget? child;

  /// Where it slides from and back to, as a fraction of its own size.
  final Offset from;

  @override
  State<Presence> createState() => _PresenceState();
}

class _PresenceState extends State<Presence> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.panel)
    ..addStatusListener((st) {
      if (st == AnimationStatus.dismissed && widget.child == null && mounted) setState(() => _last = null);
    });
  Widget? _last;

  Duration? get _duration => EditMotion.scaled(Motion.of(context), EditMotionKind.panels, Motion.panel);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_last != null || widget.child == null) return;
    _last = widget.child;
    _show();
  }

  void _show() {
    final d = _duration;
    if (d == null) {
      _c.value = 1;
    } else {
      _c.duration = d;
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(Presence old) {
    super.didUpdateWidget(old);
    final child = widget.child;
    if (child != null) {
      final was = _last;
      _last = child;
      if (was == null || _c.status == AnimationStatus.reverse || _c.isDismissed) _show();
      return;
    }
    if (_last == null) return;
    final d = _duration;
    if (d == null) {
      _c.value = 0;
      _last = null;
    } else {
      _c.duration = d;
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _last;
    if (child == null) return const SizedBox.shrink();
    final leaving = widget.child == null;
    final t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: EditMotion.exitCurve.flipped);
    Widget shown = FadeTransition(opacity: t, child: child);
    if (Motion.of(context) == MotionLevel.full) {
      shown = SlideTransition(position: Tween(begin: widget.from, end: Offset.zero).animate(t), child: shown);
    }
    // On its way out it takes no touches.
    return IgnorePointer(ignoring: leaving, child: shown);
  }
}
