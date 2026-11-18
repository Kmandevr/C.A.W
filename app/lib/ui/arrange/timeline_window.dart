// The part of a timeline lane that is built (#90): a window around the visible span, its clips placed relative to the
// window's origin in doubles (the step less the origin, times the step width), so a clip far into a long song is laid
// out with small numbers, and clips far out of view aren't built at all. The origin moves only every [anchorPx], so a
// window that moves on as the view scrolls leaves the clips it keeps where they are (#241).
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

@immutable
class TimelineWindow {
  const TimelineWindow(this.originStep, this.endStep, {double? startStep}) : startStep = startStep ?? originStep;

  /// How far apart the origins lie, in pixels: far enough that a scroll seldom crosses one (a whole lane's clips are
  /// placed again when it does), near enough that a position stays a small number (float32 keeps 1/256 px there).
  static const anchorPx = 32768.0;

  /// Everything, from step 0 (no scroll view to follow).
  static const all = TimelineWindow(0, double.infinity);

  /// The step the window's clips are placed from (at or before [startStep]).
  final double originStep;

  /// The first and last step the window holds.
  final double startStep, endStep;

  bool get isAll => endStep == double.infinity;

  /// Where song step [step] lands in the window, in pixels: relative first, then scaled.
  double x(double step, double stepW) => (step - originStep) * stepW;

  /// Whether anything of [start]..[end] (steps) is in the window.
  bool shows(double start, double end) => end >= startStep && start <= endStep;

  /// Whether the view from step [from] to [to] is all inside the window (it then needn't move).
  bool covers(double from, double to) => from >= startStep && to <= endStep;

  /// The window's width in pixels, within a lane [laneWidth] wide.
  double width(double stepW, double laneWidth) =>
      math.max(0.0, math.min(laneWidth, isAll ? laneWidth : endStep * stepW) - originStep * stepW);

  /// The window for a view scrolled to [pixels] with a [viewport] wide: chunks of a viewport, from one before the
  /// view's to two after it, so it moves only every viewport of scroll and always covers what is seen. Its origin is
  /// the [anchorPx] mark at or before its start, the same for every window between two marks.
  static TimelineWindow around(double pixels, double viewport, double stepW) {
    if (stepW <= 0 || !pixels.isFinite || !viewport.isFinite) return all;
    final chunk = math.max(viewport, 256.0);
    final i = (math.max(0.0, pixels) / chunk).floor();
    final start = math.max(0.0, ((i - 1) * chunk / stepW).floorToDouble());
    final origin = ((start * stepW / anchorPx).floor() * anchorPx / stepW).floorToDouble();
    return TimelineWindow(math.min(origin, start), ((i + 3) * chunk / stepW).ceilToDouble(), startStep: start);
  }

  @override
  bool operator ==(Object other) => other is TimelineWindow && other.originStep == originStep &&
      other.startStep == startStep && other.endStep == endStep;

  @override
  int get hashCode => Object.hash(originStep, startStep, endStep);

  @override
  String toString() => 'TimelineWindow($originStep, $startStep, $endStep)';
}
