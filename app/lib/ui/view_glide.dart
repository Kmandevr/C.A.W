// A view that moves on its own glides there (owner, 2026-11-11): a page-follow step, back to the start, a jump to a
// marker. One controller per view, a duration by distance, the theme's curve; a touch stops it, a new target
// retargets it from where it is, and with motion off it jumps.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'motion.dart';

/// Glides a scroll view to a place. Drive it with [to]; [stop] when the user touches the view.
class ViewGlide {
  ViewGlide(TickerProvider vsync) : _c = AnimationController(vsync: vsync) {
    _c.addListener(_frame);
  }

  final AnimationController _c;
  ScrollPosition? _pos;
  double _from = 0, _to = 0;

  /// The shortest and longest glide; between them it grows with the distance, up to a screen's width.
  static const shortest = Duration(milliseconds: 150), longest = Duration(milliseconds: 350);

  /// Whether a glide is under way.
  bool get active => _c.isAnimating;

  /// Where the glide under way ends.
  double get target => _to;

  /// How long a glide over [distance] pixels in a view [view] wide takes, before the theme's pace.
  static Duration durationFor(double distance, double view) {
    final f = (distance / math.max(1.0, view)).clamp(0.0, 1.0);
    return shortest + (longest - shortest) * f;
  }

  /// Glides [controller]'s view to [pixels] (clamped to its extent), from where it shows now.
  void to(ScrollController controller, double pixels, {required MotionLevel level}) {
    if (!controller.hasClients) return;
    final p = controller.positions.last;
    final target = pixels.clamp(p.minScrollExtent, p.maxScrollExtent).toDouble();
    if (level != MotionLevel.full) {
      stop();
      p.jumpTo(target);
      return;
    }
    if ((target - p.pixels).abs() < 0.5) return;
    _pos = p;
    _from = p.pixels;
    _to = target;
    _c.duration = Motion.paced(durationFor((target - _from).abs(), p.viewportDimension));
    _c.forward(from: 0);
  }

  void _frame() {
    final p = _pos;
    if (p == null || !p.hasContentDimensions) return;
    final t = EditMotion.curveOr(Curves.easeOutCubic).transform(_c.value);
    p.jumpTo((_from + (_to - _from) * t).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble());
  }

  /// Stops where it is (a touch on the view).
  void stop() {
    if (_c.isAnimating) _c.stop();
  }

  void dispose() => _c.dispose();
}
