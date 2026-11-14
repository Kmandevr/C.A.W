// The part of a timeline lane that is built (#90): a window around the visible span, its clips placed relative to the
// window's origin in doubles (the step less the origin, times the step width), so a clip far into a long song is laid
// out with small numbers, and clips far out of view aren't built at all.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

@immutable
class TimelineWindow {
  const TimelineWindow(this.originStep, this.endStep);

  /// Everything, from step 0 (no scroll view to follow).
  static const all = TimelineWindow(0, double.infinity);

  /// The first and last step the window holds.
  final double originStep, endStep;

  bool get isAll => endStep == double.infinity;

  /// Where song step [step] lands in the window, in pixels: relative first, then scaled.
  double x(double step, double stepW) => (step - originStep) * stepW;

  /// Whether anything of [start]..[end] (steps) is in the window.
  bool shows(double start, double end) => end >= originStep && start <= endStep;

  /// Whether the view from step [from] to [to] is all inside the window (it then needn't move).
  bool covers(double from, double to) => from >= originStep && to <= endStep;

  /// The window's width in pixels, within a lane [laneWidth] wide.
  double width(double stepW, double laneWidth) =>
      math.max(0.0, math.min(laneWidth, isAll ? laneWidth : endStep * stepW) - originStep * stepW);

  /// The window for a view scrolled to [pixels] with a [viewport] wide: chunks of a viewport, from one before the
  /// view's to two after it, so it moves only every viewport of scroll and always covers what is seen.
  static TimelineWindow around(double pixels, double viewport, double stepW) {
    if (stepW <= 0 || !pixels.isFinite || !viewport.isFinite) return all;
    final chunk = math.max(viewport, 256.0);
    final i = (math.max(0.0, pixels) / chunk).floor();
    final origin = math.max(0.0, ((i - 1) * chunk / stepW).floorToDouble());
    return TimelineWindow(origin, ((i + 3) * chunk / stepW).ceilToDouble());
  }

  @override
  bool operator ==(Object other) => other is TimelineWindow && other.originStep == originStep && other.endStep == endStep;

  @override
  int get hashCode => Object.hash(originStep, endStep);

  @override
  String toString() => 'TimelineWindow($originStep, $endStep)';
}
