// The piano roll's parts for a clip opened in it (owner, 2026-11-11): the loop-end bar with the repeats past it drawn
// dimmed (REAPER-style), and the clip's automation lanes under the roll.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import 'arrange/track_lanes.dart';
import 'haptics.dart';
import 'theme.dart';

/// A loop length as it reads on the bar: whole bars, else beats, else steps.
String loopLengthLabel(int steps, int beatsPerBar) {
  final bar = math.max(1, beatsPerBar) * 4;
  String n(int v, String unit) => '$v $unit${v == 1 ? '' : 's'}';
  if (steps % bar == 0) return n(steps ~/ bar, 'bar');
  if (steps % 4 == 0) return n(steps ~/ 4, 'beat');
  return n(steps, 'step');
}

/// The loop bar over the roll: past it a shade, the loop's notes repeated dimmed up to [extentSteps] (where the clip
/// stops playing, in pattern time), and the bar itself with its grip under the ruler and its length on the ruler.
class ClipLoopPainter extends CustomPainter {
  ClipLoopPainter({
    required this.doc,
    required this.loopSteps,
    required this.extentSteps,
    required this.pxPerStep,
    required this.rowH,
    required this.scrollX,
    required this.scrollY,
    required this.keyW,
    required this.rulerH,
    required this.gridH,
    required this.color,
    required this.label,
    required this.active,
  });
  final PatternDoc doc;
  final int loopSteps;
  final double extentSteps, pxPerStep, rowH, scrollX, scrollY, keyW, rulerH, gridH;
  final Color color;
  final String label;
  final bool active; // being dragged or hovered

  /// The grip's height under the ruler: a finger's target for the bar.
  static const gripH = 26.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - keyW;
    if (w <= 0 || gridH <= 0) return;
    final loopPx = loopSteps * pxPerStep;
    final x = loopPx - scrollX;
    canvas.save();
    canvas.translate(keyW, rulerH);
    canvas.clipRect(Rect.fromLTWH(0, 0, w, gridH));
    if (x < w) {
      canvas.drawRect(Rect.fromLTRB(math.max(0.0, x), 0, w, gridH), Paint()..color = const Color(0x55000000));
      final fill = Paint()..color = color.withValues(alpha: 0.2);
      final edge = Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      final seam = Paint()..color = color.withValues(alpha: 0.3);
      for (var k = 1; k * loopSteps < extentSteps && k * loopPx - scrollX < w; k++) {
        final ox = k * loopPx - scrollX;
        if (ox + loopPx < 0) continue;
        canvas.drawLine(Offset(ox, 0), Offset(ox, gridH), seam);
        for (final n in doc.notes) {
          final at = n.at.toDouble();
          if (at >= loopSteps) continue;
          final nx = ox + at * pxPerStep;
          final nw = math.max(3.0, math.min(n.len.toDouble(), loopSteps - at) * pxPerStep - 1);
          if (nx > w || nx + nw < 0) continue;
          final y = (127 - n.pitch.round()) * rowH - scrollY;
          if (y > gridH || y + rowH < 0) continue;
          final r = RRect.fromRectAndRadius(Rect.fromLTWH(nx, y + 1, nw, rowH - 2), const Radius.circular(3));
          canvas.drawRRect(r, fill);
          canvas.drawRRect(r, edge);
        }
      }
    }
    canvas.restore();
    if (x < 0 || x > w) return;
    final bx = keyW + x;
    final bar = Paint()
      ..color = Neon.yellow
      ..strokeWidth = active ? 2.5 : 1.5;
    canvas.drawLine(Offset(bx, 0), Offset(bx, rulerH + gridH), bar);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(bx, rulerH + gripH / 2), width: 10, height: gripH - 4),
        const Radius.circular(4),
      ),
      Paint()..color = Neon.yellow.withValues(alpha: active ? 1 : 0.8),
    );
    final text = TextPainter(
      text: TextSpan(
        text: 'Loop · $label',
        style: const TextStyle(color: Neon.bg, fontSize: 10, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final room = size.width - bx - 6;
    final lx = room >= text.width + 8 ? bx + 4 : bx - text.width - 12;
    final pill = Rect.fromLTWH(math.max(keyW, lx), 2, text.width + 8, rulerH - 4);
    canvas.drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(4)), Paint()..color = Neon.yellow);
    text.paint(canvas, Offset(pill.left + 4, pill.top + (pill.height - text.height) / 2));
  }

  @override
  bool shouldRepaint(ClipLoopPainter o) =>
      !identical(o.doc, doc) ||
      o.loopSteps != loopSteps ||
      o.extentSteps != extentSteps ||
      o.pxPerStep != pxPerStep ||
      o.rowH != rowH ||
      o.scrollX != scrollX ||
      o.scrollY != scrollY ||
      o.gridH != gridH ||
      o.color != color ||
      o.label != label ||
      o.active != active ||
      o.keyW != keyW;
}

/// The clip's automation lanes under the roll, scrolled and zoomed with it: an "Automation" picker that adds a lane
/// for the track's volume, pan, instrument or effect knobs, then one lane row each (the Arrange lane, edited the same
/// way) across the clip's loop, with a menu (Move to track, Remove lane).
class ClipLanesStrip extends StatelessWidget {
  const ClipLanesStrip({
    super.key,
    required this.state,
    required this.layer,
    required this.clip,
    required this.loopSteps,
    required this.pxPerStep,
    required this.scrollX,
    required this.keyW,
  });
  final AppState state;
  final LayerDoc layer;
  final ClipDoc clip;
  final int loopSteps;
  final double pxPerStep, scrollX, keyW;

  /// The most lane rows shown at once; more scroll.
  static const maxRows = 3;

  @override
  Widget build(BuildContext context) {
    final lanes = [for (final a in clip.automation) ?ArrangeLane.ofClip(state, layer, clip, a)];
    final addable = addableClipLanes(state, layer, clip);
    final width = loopSteps * pxPerStep;
    Widget row(ArrangeLane lane) => SizedBox(
      height: kLaneRowHeight,
      child: Row(
        children: [
          SizedBox(
            width: keyW,
            child: Builder(
              builder: (context) => IconButton(
                key: ValueKey('clip-lane-menu-${lane.key}'),
                padding: EdgeInsets.zero,
                iconSize: 16,
                tooltip: 'Lane menu',
                icon: Icon(Icons.more_vert, color: lane.color),
                onPressed: () {
                  Haptics.tap();
                  final box = context.findRenderObject() as RenderBox?;
                  laneMenu(context, lane, box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero)));
                },
              ),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: -scrollX,
                    top: 0,
                    width: width,
                    height: kLaneRowHeight,
                    child: LaneRow(
                      key: ValueKey('clip-lane-row-${lane.key}'),
                      lane: lane,
                      stepW: pxPerStep,
                      width: width,
                    ),
                  ),
                  Positioned(
                    left: 4,
                    top: 1,
                    child: IgnorePointer(
                      child: Text(
                        lane.name,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: lane.color.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Neon.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: kLaneAddRowHeight,
            child: Row(
              children: [
                SizedBox(width: keyW),
                PopupMenuButton<String>(
                  key: const ValueKey('clip-lane-add'),
                  tooltip: 'Add a clip automation lane',
                  enabled: addable.isNotEmpty,
                  padding: EdgeInsets.zero,
                  onSelected: (v) => addClipArrangeLane(state, layer, clip, v),
                  itemBuilder: (_) => [
                    for (final (value, label) in addable) PopupMenuItem(value: value, child: Text(label)),
                  ],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 16, color: addable.isEmpty ? Neon.dim : Neon.blue),
                      Text(
                        lanes.isEmpty ? 'Automation' : 'Lane',
                        style: TextStyle(fontSize: 10, color: addable.isEmpty ? Neon.dim : Neon.blue),
                      ),
                    ],
                  ),
                ),
                // The label gives way first in a narrow roll (the focus panel's), ending in an ellipsis.
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: 8, right: 8),
                    child: Text(
                      'CLIP AUTOMATION · loops with the clip',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(color: Neon.dim, fontSize: 9, letterSpacing: 1),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (lanes.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: kLaneRowHeight * maxRows),
              child: SingleChildScrollView(child: Column(children: [for (final l in lanes) row(l)])),
            ),
        ],
      ),
    );
  }
}
