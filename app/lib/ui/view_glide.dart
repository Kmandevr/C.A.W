// A view that moves on its own glides there (owner, 2026-11-11): a page-follow step, back to the start, a jump to a
// marker, zoom to fit, the zoom buttons, the keyboard's cursor leaving the view. One helper per view moves its left
// edge and its zoom together ([ViewGlide.to], the editors' animateViewTo): a duration by distance (150–350 ms), the
// theme's curve, the zoom on a log scale; a touch stops it, a new target retargets it from where it is, and with
// motion off it jumps.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'motion.dart';

/// A view's place: its left edge in content units (steps) and its zoom in screen pixels per unit.
typedef ViewPlace = ({double left, double zoom});

/// Glides one view's left edge and zoom. The view says where it is ([read]) and takes each frame's place ([apply]).
class ViewGlide {
  ViewGlide(TickerProvider vsync, {required this.read, required this.apply}) : _c = AnimationController(vsync: vsync) {
    _c.addListener(_frame);
  }

  final ViewPlace Function() read;
  final void Function(ViewPlace place) apply;

  final AnimationController _c;
  ViewPlace _from = (left: 0, zoom: 1), _to = (left: 0, zoom: 1);
  // A zoom that keeps a point still: the content unit and its pixels from the view's left edge.
  ({double unit, double px})? _anchor;

  /// The shortest and longest glide; between them it grows with the distance, up to a screen's width.
  static const shortest = Duration(milliseconds: 150), longest = Duration(milliseconds: 350);

  /// Whether a glide is under way.
  bool get active => _c.isAnimating;

  /// Where the glide under way ends (where the view is when none is).
  ViewPlace get target => active ? _to : read();

  /// How long a glide over [distance] pixels in a view [view] wide takes, before the theme's pace.
  static Duration durationFor(double distance, double view) {
    final f = (distance / math.max(1.0, view)).clamp(0.0, 1.0);
    return shortest + (longest - shortest) * f;
  }

  /// How far a move from [a] to [b] looks on a [view]-pixel-wide screen: the pan at the nearer zoom, or the zoom's
  /// change (a doubling counts as half a screen), whichever is more.
  static double distanceOf(ViewPlace a, ViewPlace b, double view) {
    final pan = (b.left - a.left).abs() * math.min(a.zoom, b.zoom);
    final zoom = (math.log(b.zoom / a.zoom) / math.ln2).abs() * view * 0.5;
    return math.max(pan, zoom);
  }

  /// Glides to [left] (content units) at [zoom] (pixels per unit); either left out stays as it is, or as the glide
  /// under way ends. With [keep] (pixels from the view's left edge) and no [left], the content under that point stays
  /// there through the zoom. [view] is the view's width in pixels.
  void to({double? left, double? zoom, double? keep, required double view, required MotionLevel level}) {
    final now = read();
    final aim = target;
    final z = zoom ?? aim.zoom;
    ({double unit, double px})? anchor;
    var l = left ?? aim.left;
    if (left == null && keep != null && zoom != null) {
      final unit = aim.left + keep / aim.zoom;
      anchor = (unit: unit, px: keep);
      l = unit - keep / z;
    }
    final goal = (left: l, zoom: z);
    if (level != MotionLevel.full) {
      stop();
      apply(goal);
      return;
    }
    if ((goal.left - now.left).abs() * goal.zoom < 0.5 && (goal.zoom - now.zoom).abs() < 1e-9) {
      stop();
      return;
    }
    _from = now;
    _to = goal;
    _anchor = anchor;
    _c.duration = Motion.paced(durationFor(distanceOf(now, goal, view), view));
    _c.forward(from: 0);
  }

  void _frame() {
    final t = EditMotion.curveOr(Curves.easeOutCubic).transform(_c.value);
    // On a log scale, so a zoom across the whole range moves evenly.
    final z = _from.zoom == _to.zoom ? _to.zoom
        : math.exp(math.log(_from.zoom) + (math.log(_to.zoom) - math.log(_from.zoom)) * t);
    final a = _anchor;
    final left = a != null && _c.value < 1 ? a.unit - a.px / z : _from.left + (_to.left - _from.left) * t;
    apply((left: left, zoom: z));
  }

  /// Stops where it is (a touch on the view).
  void stop() {
    if (_c.isAnimating) _c.stop();
  }

  void dispose() => _c.dispose();
}
