// The music video's shot lane under the song's bars (owner, 2026-11-12), in the arranger lane's style: each shot a
// block to drag and trim, cut markers to move (a tap picks the transition), snapping to steps, beats or bars, beat
// markers along the lane with each beat effect's hits, a cursor and the preview's playhead.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../model/music_video_director.dart' show VideoTransition;
import '../../model/music_video_edit.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'video_kit.dart';

/// What a lane drag changes.
enum LaneDrag { move, trimStart, trimEnd, cut }

class ShotLane extends StatefulWidget {
  const ShotLane({super.key, required this.timeline, required this.stepsPerBar, required this.start, required this.end,
      required this.snap, required this.selected, required this.cursor, required this.onSelect,
      required this.onCursor, required this.onBeginEdit, required this.onEdit, required this.onEndEdit, this.playhead,
      this.enabled = true, this.onCutTap});

  /// A tap on the cut marker before shot [index] (its transition).
  final ValueChanged<int>? onCutTap;

  /// Off while auto-cut or a render runs: taps still choose and set the cursor, drags don't edit.
  final bool enabled;

  final VideoTimeline timeline;
  final int stepsPerBar;

  /// The video's range (song steps).
  final double start, end;
  final VideoSnap snap;
  final String? selected;

  /// Where Add and Split act (song steps).
  final double cursor;

  /// The preview's position, drawn as the playhead.
  final ValueListenable<double>? playhead;
  final ValueChanged<String?> onSelect;
  final ValueChanged<double> onCursor;

  /// A drag starts (the host keeps an undo step), moves the shots (repaint the preview) and ends (save).
  final VoidCallback onBeginEdit, onEdit, onEndEdit;

  /// The lane's heights: the ruler and the shots under it.
  static const rulerHeight = 20.0, laneHeight = 46.0;

  /// The widest a trim handle is, at each end of a block.
  static const handle = 14.0;

  @override
  State<ShotLane> createState() => ShotLaneState();
}

class ShotLaneState extends State<ShotLane> {
  final _scroll = ScrollController();

  /// Pixels per step: null fits the range to the width (at least [_minBar] a bar); +/− zoom by halves and doubles.
  double? _px;
  static const _minBar = 28.0;

  ({String? id, int cut, LaneDrag mode, double origin, double dx})? _drag;

  /// Shots that just went, fading out where they were.
  final Map<String, (VideoCut, Timer)> _leaving = {};
  Map<String, VideoCut> _last = {};

  double _shownPx = 0;

  /// Pixels per step as last drawn.
  double get pxPerStep => _shownPx;
  bool get dragging => _drag != null;

  @override
  void dispose() {
    _scroll.dispose();
    for (final (_, t) in _leaving.values) {
      t.cancel();
    }
    super.dispose();
  }

  /// Zooms in (factor 2) or out (0.5) around the middle of the view.
  void zoom(double factor, double fitPx) {
    final px = (_px ?? fitPx) * factor;
    setState(() => _px = px.clamp(fitPx * 0.5, 64.0).toDouble());
  }

  double _fit(double width) {
    final span = math.max(1.0, widget.end - widget.start);
    return math.max((width - 16) / span, _minBar / widget.stepsPerBar);
  }

  double _stepAt(double x, double px) => widget.start + (x - 8) / px;

  void _noteLeaving(Duration fade) {
    final now = {for (final c in widget.timeline.cuts) c.id: c};
    for (final e in _last.entries) {
      if (now.containsKey(e.key) || _leaving.containsKey(e.key) || fade == Duration.zero) continue;
      _leaving[e.key] = (e.value.copy(), Timer(fade, () {
        if (mounted) setState(() => _leaving.remove(e.key));
      }));
    }
    _last = {for (final c in widget.timeline.cuts) c.id: c.copy()};
  }

  void _startDrag(String? id, int cut, LaneDrag mode, double globalX) {
    if (!widget.enabled) return;
    final c = id == null ? null : widget.timeline.byId(id);
    final origin = switch (mode) {
      LaneDrag.move || LaneDrag.trimStart => c!.start,
      LaneDrag.trimEnd => c!.end,
      LaneDrag.cut => widget.timeline.cuts[cut].start,
    };
    widget.onBeginEdit();
    Haptics.tap();
    setState(() => _drag = (id: id, cut: cut, mode: mode, origin: origin, dx: globalX));
    if (id != null) widget.onSelect(id);
  }

  void _updateDrag(double globalX, double px) {
    final d = _drag;
    if (d == null) return;
    final to = d.origin + (globalX - d.dx) / px;
    final t = widget.timeline;
    final spb = widget.stepsPerBar;
    final changed = switch (d.mode) {
      LaneDrag.move => t.move(d.id!, to, snap: widget.snap, stepsPerBar: spb, lo: widget.start, hi: widget.end),
      LaneDrag.trimStart => t.trimStart(d.id!, to, snap: widget.snap, stepsPerBar: spb, lo: widget.start, hi: widget.end),
      LaneDrag.trimEnd => t.trimEnd(d.id!, to, snap: widget.snap, stepsPerBar: spb, lo: widget.start, hi: widget.end),
      LaneDrag.cut => t.moveCut(d.cut, to, snap: widget.snap, stepsPerBar: spb),
    };
    if (changed) {
      Haptics.tick();
      setState(() {});
      widget.onEdit();
    }
  }

  void _endDrag() {
    if (_drag == null) return;
    setState(() => _drag = null);
    widget.onEndEdit();
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final fade = Motion.fade(Motion.standard, level);
    _noteLeaving(fade);
    return LayoutBuilder(builder: (context, box) {
      final fit = _fit(box.maxWidth);
      final px = _px ?? fit;
      _shownPx = px;
      final spb = widget.stepsPerBar;
      final width = math.max(box.maxWidth, (widget.end - widget.start) * px + 16);
      double x(double step) => 8 + (step - widget.start) * px;
      final move = _drag != null ? Duration.zero : Motion.move(Motion.standard, level);
      final cuts = widget.timeline.cuts.where((c) => c.end > widget.start && c.start < widget.end).toList();
      final markers = widget.timeline.cutMarkers();

      Widget block(VideoCut c, {bool leaving = false}) {
        final view = c.layout.panels.first.view;
        final color = videoViewColor(view);
        final on = c.id == widget.selected && !leaving;
        final left = x(math.max(c.start, widget.start)), right = x(math.min(c.end, widget.end));
        final w = math.max(4.0, right - left - 2);
        final body = AnimatedContainer(
          duration: Motion.fade(Motion.small, level),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: color.withValues(alpha: on ? 0.32 : 0.18),
            border: Border.all(color: on ? color : color.withValues(alpha: 0.6), width: on ? 1.6 : 1),
            boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 10)] : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(5, 4, 5, 3),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(
                    TextSpan(children: [
                      if (w > 48) WidgetSpan(alignment: PlaceholderAlignment.middle, child: Padding(
                          padding: const EdgeInsets.only(right: 3), child: Icon(videoViewIcon(view), size: 12, color: color))),
                      TextSpan(text: c.layout.panels.length > 1 ? c.layout.preset.label : view.label),
                    ]),
                    maxLines: 1, overflow: TextOverflow.clip, softWrap: false,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Neon.text),
                  ),
                  const Spacer(),
                  if (w > 44)
                    Text([
                      if (c.layout.panels.length > 1) '${c.layout.panels.length} views',
                      if (c.effects.isNotEmpty) '${c.effects.length} FX',
                      if (c.transition != VideoTransition.cut) c.transition.label.toLowerCase(),
                    ].join(' · '), maxLines: 1, overflow: TextOverflow.clip,
                        style: const TextStyle(fontSize: 8.5, color: Neon.dim)),
                ]),
              ),
              // The trim handles, shown on the chosen shot.
              if (on && w > ShotLane.handle * 2.5) ...[
                Positioned(left: 0, top: 8, bottom: 8, width: 4,
                    child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)))),
                Positioned(right: 0, top: 8, bottom: 8, width: 4,
                    child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)))),
              ],
            ]),
          ),
        );
        Widget child = leaving
            ? TweenAnimationBuilder<double>(tween: Tween(begin: 1, end: 0), duration: fade,
                builder: (context, v, child) => Opacity(opacity: v, child: child), child: body)
            : GestureDetector(
                key: ValueKey('video-lane-shot-${c.id}'),
                behavior: HitTestBehavior.opaque,
                // From where the finger went down, so the block follows it with no jump.
                dragStartBehavior: DragStartBehavior.down,
                onTap: () {
                  Haptics.tap();
                  widget.onSelect(c.id);
                },
                onHorizontalDragStart: (d) {
                  final edges = on && w > ShotLane.handle * 2.5;
                  final mode = edges && d.localPosition.dx < ShotLane.handle
                      ? LaneDrag.trimStart
                      : edges && d.localPosition.dx > w - ShotLane.handle
                          ? LaneDrag.trimEnd
                          : LaneDrag.move;
                  _startDrag(c.id, -1, mode, d.globalPosition.dx);
                },
                onHorizontalDragUpdate: (d) => _updateDrag(d.globalPosition.dx, px),
                onHorizontalDragEnd: (_) => _endDrag(),
                onHorizontalDragCancel: _endDrag,
                child: VideoAppear(child: body),
              );
        return AnimatedPositioned(
          key: ValueKey('lane-block-${c.id}${leaving ? '-gone' : ''}'),
          duration: move,
          curve: Curves.easeOutCubic,
          left: left + 1,
          width: w,
          top: ShotLane.rulerHeight + 4,
          height: ShotLane.laneHeight - 8,
          child: IgnorePointer(ignoring: leaving, child: child),
        );
      }

      return SizedBox(
        height: ShotLane.rulerHeight + ShotLane.laneHeight,
        child: SingleChildScrollView(
          key: const ValueKey('video-lane'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: ShotLane.rulerHeight + ShotLane.laneHeight,
            child: Stack(clipBehavior: Clip.none, children: [
              // The ruler and lane background; a tap sets the cursor (and on the lane clears the choice).
              Positioned.fill(child: GestureDetector(
                key: const ValueKey('video-lane-ruler'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  final st = snapStep(_stepAt(d.localPosition.dx, px), widget.snap, spb)
                      .clamp(widget.start, widget.end)
                      .toDouble();
                  if (d.localPosition.dy > ShotLane.rulerHeight) widget.onSelect(null);
                  widget.onCursor(st);
                },
                child: CustomPaint(painter: _LanePainter(start: widget.start, end: widget.end, px: px,
                    stepsPerBar: spb, gaps: widget.timeline.gaps(widget.start, widget.end), hits: _hits(cuts, spb))),
              )),
              for (final c in cuts) block(c),
              for (final e in _leaving.entries)
                if (!widget.timeline.cuts.any((c) => c.id == e.key)) block(e.value.$1, leaving: true),
              // Cut markers: where one shot ends and the next starts, a handle on the ruler to drag the cut.
              for (final i in markers)
                if (widget.timeline.cuts[i].start > widget.start && widget.timeline.cuts[i].start < widget.end)
                  AnimatedPositioned(
                    key: ValueKey('lane-cut-${widget.timeline.cuts[i].id}'),
                    duration: move,
                    curve: Curves.easeOutCubic,
                    left: x(widget.timeline.cuts[i].start) - 11,
                    top: 0,
                    width: 22,
                    height: ShotLane.rulerHeight + 6,
                    child: GestureDetector(
                      key: ValueKey('video-lane-cut-$i'),
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onTap: widget.onCutTap == null ? null : () => widget.onCutTap!(i),
                      onHorizontalDragStart: (d) => _startDrag(null, i, LaneDrag.cut, d.globalPosition.dx),
                      onHorizontalDragUpdate: (d) => _updateDrag(d.globalPosition.dx, px),
                      onHorizontalDragEnd: (_) => _endDrag(),
                      onHorizontalDragCancel: _endDrag,
                      child: CustomPaint(painter: _CutMarkerPainter(
                          hot: _drag?.mode == LaneDrag.cut && _drag?.cut == i)),
                    ),
                  ),
              // The cursor and the playhead.
              AnimatedPositioned(
                duration: Motion.move(Motion.small, level),
                left: x(widget.cursor) - 1,
                top: 0,
                bottom: 0,
                width: 2,
                child: IgnorePointer(child: ColoredBox(color: Neon.yellow.withValues(alpha: 0.8))),
              ),
              if (widget.playhead != null)
                Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _PlayheadPainter(
                    widget.playhead!, (st) => x(st))))),
            ]),
          ),
        ),
      );
    });
  }
}

/// Where the shots' beat effects hit (song steps), for the lane's markers: each beat, off-beat or bar pulse of an
/// effect that is on, inside its shot. Bounded, so a long song with many beat effects stays quick.
List<double> _hits(List<VideoCut> cuts, int spb) {
  final out = <double>{};
  for (final c in cuts) {
    for (final e in c.effects) {
      if (!e.on || !VideoEffectPreset.beats(e.drive)) continue;
      final (period, offset) = switch (e.drive) {
        VideoDrive.bar => (math.max(1, spb).toDouble(), 0.0),
        VideoDrive.offbeat => (4.0, 2.0),
        _ => (4.0, 0.0),
      };
      for (var t = ((c.start - offset) / period).ceil() * period + offset; t < c.end && out.length < 4096; t += period) {
        out.add(t);
      }
    }
  }
  return out.toList()..sort();
}

class _LanePainter extends CustomPainter {
  _LanePainter({required this.start, required this.end, required this.px, required this.stepsPerBar, required this.gaps,
      this.hits = const []});
  final double start, end, px;
  final int stepsPerBar;
  final List<(double, double)> gaps;

  /// Where beat effects hit (song steps).
  final List<double> hits;

  @override
  void paint(Canvas canvas, Size size) {
    double x(double st) => 8 + (st - start) * px;
    const rh = ShotLane.rulerHeight;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, rh), const Radius.circular(6)),
        Paint()..color = Neon.panel.withValues(alpha: 0.9));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, rh + 1, size.width, size.height - rh - 1), const Radius.circular(6)),
        Paint()..color = Colors.white.withValues(alpha: 0.03));
    // Empty stretches show the arrangement: hatched faintly.
    final hatch = Paint()
      ..color = Neon.line.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (final (a, b) in gaps) {
      final l = x(a), r = x(b);
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(l, rh + 4, r, size.height - 4));
      for (var hx = l - size.height; hx < r; hx += 8) {
        canvas.drawLine(Offset(hx, size.height - 4), Offset(hx + size.height, rh + 4), hatch);
      }
      canvas.restore();
    }
    // Beat markers along the lane (owner, 2026-11-12): a faint tick on every beat, a firmer one on the bar.
    if (px * 4 >= 5) {
      final beat = Paint()
        ..color = Neon.line.withValues(alpha: 0.28)
        ..strokeWidth = 1;
      for (var b = (start / 4).ceil() * 4.0; b <= end; b += 4) {
        if (b % stepsPerBar == 0) continue;
        canvas.drawLine(Offset(x(b), size.height - 7), Offset(x(b), size.height - 2), beat);
      }
    }
    // The beat effects' hits: a dot where each pulse lands.
    final dot = Paint()..color = Neon.yellow.withValues(alpha: 0.85);
    for (final h in hits) {
      if (h < start || h > end) continue;
      canvas.drawCircle(Offset(x(h), size.height - 9), px * 4 >= 8 ? 2 : 1.4, dot);
    }
    final barW = stepsPerBar * px;
    final every = barW < 18 ? 4 : (barW < 34 ? 2 : 1);
    final firstBar = (start / stepsPerBar).floor();
    for (var bar = firstBar; bar * stepsPerBar <= end; bar++) {
      final st = bar * stepsPerBar.toDouble();
      if (st < start) continue;
      final bx = x(st);
      canvas.drawLine(Offset(bx, rh * 0.45), Offset(bx, size.height), Paint()
        ..color = Neon.line.withValues(alpha: 0.7)
        ..strokeWidth = 1);
      if (bar % every == 0) {
        final tp = TextPainter(text: TextSpan(text: '${bar + 1}', style: Neon.code(size: 9, color: Neon.dim)),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, Offset(bx + 3, 3));
        tp.dispose();
      }
      if (px * 4 >= 6) {
        for (var b = 1; b < stepsPerBar / 4; b++) {
          final tx = x(st + b * 4);
          if (st + b * 4 > end) break;
          canvas.drawLine(Offset(tx, rh * 0.7), Offset(tx, rh), Paint()
            ..color = Neon.line.withValues(alpha: 0.5)
            ..strokeWidth = 1);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) =>
      old.start != start || old.end != end || old.px != px || old.stepsPerBar != stepsPerBar || !listEquals(old.gaps, gaps) ||
      !listEquals(old.hits, hits);
}

class _CutMarkerPainter extends CustomPainter {
  _CutMarkerPainter({required this.hot});
  final bool hot;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, ShotLane.rulerHeight - 4);
    final color = hot ? Neon.yellow : Neon.text;
    canvas.drawLine(Offset(c.dx, 2), Offset(c.dx, size.height), Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1.4);
    final path = Path()
      ..moveTo(c.dx, c.dy - 6)
      ..lineTo(c.dx + 5, c.dy)
      ..lineTo(c.dx, c.dy + 6)
      ..lineTo(c.dx - 5, c.dy)
      ..close();
    if (hot) canvas.drawPath(path, Paint()..color = Neon.yellow.withValues(alpha: 0.4)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CutMarkerPainter old) => old.hot != hot;
}

class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter(this.step, this.x) : super(repaint: step);
  final ValueListenable<double> step;
  final double Function(double) x;

  @override
  void paint(Canvas canvas, Size size) {
    final px = x(step.value);
    canvas.drawLine(Offset(px, 0), Offset(px, size.height), Paint()
      ..color = Neon.pink
      ..strokeWidth = 1.6);
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) => old.step != step;
}
