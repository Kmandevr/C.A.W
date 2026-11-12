// Arrange's ruler (docs/reaper-flow.md, gap 2): bar numbers, the loop range (drag along the ruler to draw it, drag
// its handles to adjust it, as in REAPER), and markers and regions (a long press adds one; tap jumps, drag moves, a
// region dragged with Alt takes its clips and with Ctrl or a second finger copies them; long press for the menu).
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_markers.dart';
import '../../model/project.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'edit_cues.dart';
import 'long_press_menu.dart';
import 'region_list.dart';

/// The ruler over the lanes, [width] wide at [stepW] pixels a step; [scroll] is the lanes' horizontal scroll, so
/// only the visible bars are painted.
class ArrangeRuler extends StatefulWidget {
  const ArrangeRuler({super.key, required this.state, required this.stepW, required this.width, required this.height,
    required this.scroll});
  final AppState state;
  final double stepW, width, height;
  final ScrollController scroll;

  @override
  State<ArrangeRuler> createState() => _ArrangeRulerState();
}

enum _Edge { start, end, draw }

class _ArrangeRulerState extends State<ArrangeRuler> {
  /// A loop drag in progress: which edge moves and the range it shows (committed when the drag ends).
  _Edge? _edge;
  int _from = 0, _to = 0;

  /// A marker or region being dragged, and where it would start.
  MarkerDoc? _moving;
  int _movingAt = 0;
  double _movingDx = 0;

  /// Fingers on the ruler: a second one while a region is dragged copies it with its clips.
  final Set<int> _pointers = {};
  bool _secondFinger = false;

  /// How a region drag ends, by the keys held (or a second finger): the region alone, with its clips, or a copy.
  ({bool clips, bool copy}) get _regionMode {
    final keys = HardwareKeyboard.instance;
    final copy = _secondFinger || keys.isControlPressed || keys.isMetaPressed;
    return (clips: copy || keys.isAltPressed, copy: copy);
  }

  AppState get s => widget.state;
  ProjectDoc get p => s.project;

  /// The step under [x], on the arrangement's snap grid unless Shift is held.
  int _snapped(double x) {
    final raw = math.max(0, (x / widget.stepW).round());
    if (HardwareKeyboard.instance.isShiftPressed) return raw;
    final snap = s.arrangementSnapSteps;
    return (raw / snap).round() * snap;
  }

  /// The handles' reach either side of an edge, in pixels: wide enough for a finger.
  static const _grab = 14.0;

  void _dragStart(DragStartDetails d) {
    final x = d.localPosition.dx;
    final w = widget.stepW;
    if (p.hasLoopRange && (x - p.loopEndSteps * w).abs() <= _grab) {
      _edge = _Edge.end;
    } else if (p.hasLoopRange && (x - p.loopStartSteps * w).abs() <= _grab) {
      _edge = _Edge.start;
    } else {
      _edge = _Edge.draw;
    }
    setState(() {
      _from = _edge == _Edge.draw ? _snapped(x) : p.loopStartSteps;
      _to = _edge == _Edge.draw ? _from : p.loopEndSteps;
    });
  }

  void _dragUpdate(DragUpdateDetails d) {
    final at = _snapped(d.localPosition.dx);
    setState(() {
      if (_edge == _Edge.start) {
        _from = at;
      } else {
        _to = at;
      }
    });
  }

  void _dragEnd() {
    final edge = _edge;
    setState(() => _edge = null);
    if (edge == null) return;
    if (_from == _to) {
      // A handle dragged onto the other end collapses the loop: it turns off and its markers go (owner,
      // 2026-11-12); undo brings it back. A draw that never moved draws nothing.
      if (edge != _Edge.draw) {
        Motion.tick();
        s.clearLoopRange();
      }
      return;
    }
    Motion.tick();
    s.setLoopRange(_from, _to);
  }

  Future<void> _rulerMenu(Offset global, double x) async {
    final step = _snapped(x);
    final bar = p.stepsPerBar;
    final v = await showLongPressMenu<String>(context, at: global, title: 'Bar ${step ~/ bar + 1}',
      style: s.settings.longPressMenu, actions: const [
        MenuAction('marker', 'Add marker', Icons.flag_outlined),
        MenuAction('region', 'Add region', Icons.space_bar),
        MenuAction('list', 'Markers and regions…', Icons.list),
      ]);
    if (v == null || !mounted) return;
    if (v == 'list') await showMarkerList(context, s);
    if (v == 'marker') s.addMarker(step);
    if (v == 'region') {
      // The time selection when it is under the finger, else four bars from the bar pressed.
      final a = s.timeSelectionStart, b = s.timeSelectionEnd;
      if (a != null && b != null && a != b && step >= math.min(a, b) && step <= math.max(a, b)) {
        s.addMarker(math.min(a, b), end: math.max(a, b));
      } else {
        final from = step ~/ bar * bar;
        s.addMarker(from, end: from + 4 * bar);
      }
    }
  }

  Future<void> _markerMenu(MarkerDoc m, Offset global) => markerMenu(context, s, m, global);

  Widget _marker(MarkerDoc m) {
    final w = widget.stepW, h = widget.height;
    final moving = identical(_moving, m);
    final start = moving ? _movingAt : m.startSteps;
    final color = Neon.layer(m.color);
    final lane = h * 0.5;
    final width = m.isRegion ? math.max(16.0, (m.endSteps! - m.startSteps) * w) : 96.0;
    return Positioned(key: ValueKey('ruler-marker-${m.id}'), left: start * w, top: h - lane, height: lane, width: width,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The marker follows the finger from where it went down, slop included.
        dragStartBehavior: DragStartBehavior.down,
        onTap: () => s.seekTo(m.startSteps.toDouble()),
        onLongPressStart: (d) => _markerMenu(m, d.globalPosition),
        onSecondaryTapUp: (d) => _markerMenu(m, d.globalPosition),
        onHorizontalDragStart: (_) => setState(() {
          _moving = m;
          _movingAt = m.startSteps;
          _movingDx = 0;
          _secondFinger = false;
        }),
        onHorizontalDragUpdate: (d) => setState(() {
          _movingDx += d.delta.dx;
          _movingAt = _snapped(m.startSteps * w + _movingDx);
        }),
        onHorizontalDragEnd: (_) {
          final at = _movingAt;
          final mode = _regionMode;
          setState(() {
            _moving = null;
            _secondFinger = false;
          });
          if (m.isRegion && mode.clips) {
            if (s.moveRegionWithClips(m, at, copy: mode.copy) != null) Haptics.drop();
            return;
          }
          s.endUndoStep();
          s.moveMarker(m, at);
          s.endUndoStep();
        },
        child: m.isRegion
            ? Container(margin: const EdgeInsets.only(bottom: 2), padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(color: color.withValues(alpha: moving ? 0.45 : 0.28),
                  borderRadius: BorderRadius.circular(3), border: Border.all(color: color.withValues(alpha: 0.9))),
                alignment: Alignment.centerLeft,
                // While dragged, it says what the drop will do.
                child: Text(moving && _regionMode.copy ? '${m.name} · copy with clips'
                    : moving && _regionMode.clips ? '${m.name} · with clips' : m.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)))
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(width: 2, color: color),
                Flexible(child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  margin: const EdgeInsets.only(bottom: 2),
                  decoration: BoxDecoration(color: color.withValues(alpha: moving ? 0.5 : 0.3),
                    borderRadius: const BorderRadius.only(topRight: Radius.circular(4), bottomRight: Radius.circular(4))),
                  alignment: Alignment.centerLeft,
                  child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)))),
              ]),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.stepW, h = widget.height;
    final drawing = _edge != null;
    final from = drawing ? math.min(_from, _to) : p.loopStartSteps;
    final to = drawing ? math.max(_from, _to) : p.loopEndSteps;
    final shown = drawing ? to > from : p.hasLoopRange;
    final on = drawing || p.loopRange;
    final band = h * 0.5;
    // Regions first, so a marker on top of one stays reachable.
    final marks = [...p.markers]..sort((a, b) => (a.isRegion ? 0 : 1).compareTo(b.isRegion ? 0 : 1));
    return Listener(
      onPointerDown: (e) {
        _pointers.add(e.pointer);
        if (_pointers.length > 1 && _moving != null && _moving!.isRegion && !_secondFinger) {
          Haptics.threshold();
          setState(() => _secondFinger = true);
        }
      },
      onPointerUp: (e) => _pointers.remove(e.pointer),
      onPointerCancel: (e) => _pointers.remove(e.pointer),
      child: SizedBox(key: const ValueKey('arrange-ruler'), width: widget.width, height: h, child: Stack(children: [
      Positioned.fill(child: Semantics(
        label: 'Ruler: drag to set the loop range, tap to move the playhead, long-press to add a marker or region',
        child: MouseRegion(cursor: SystemMouseCursors.text, child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: (d) => s.seekTo(_snapped(d.localPosition.dx).toDouble()),
          onLongPressStart: (d) => _rulerMenu(d.globalPosition, d.localPosition.dx),
          onSecondaryTapUp: (d) => _rulerMenu(d.globalPosition, d.localPosition.dx),
          onHorizontalDragStart: _dragStart,
          onHorizontalDragUpdate: _dragUpdate,
          onHorizontalDragEnd: (_) => _dragEnd(),
          onHorizontalDragCancel: () => setState(() => _edge = null),
          child: CustomPaint(painter: _RulerPainter(w, p.stepsPerBar, widget.scroll, h)))))),
      // The loop range: a band over the top half, bright while on, with a grip at each end. It fades out when it
      // goes (a handle dragged onto the other end removes it).
      Positioned.fill(child: IgnorePointer(child: FadeHold<(int, int, bool)>(
        value: shown ? (from, to, on) : null,
        builder: (context, r) => LoopBand(from: r.$1 * w, to: r.$2 * w, on: r.$3, band: band)))),
      for (final m in marks) _marker(m),
    ])));
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.stepW, this.barSteps, this.scroll, this.height) : super(repaint: scroll);
  final double stepW, height;
  final int barSteps;
  final ScrollController scroll;

  @override
  void paint(Canvas canvas, Size size) {
    final barW = barSteps * stepW;
    var from = 0.0, to = math.min(size.width, 4096.0);
    if (scroll.hasClients) {
      final pos = scroll.positions.last;
      from = pos.pixels.clamp(0.0, size.width).toDouble();
      to = (pos.pixels + pos.viewportDimension).clamp(from, size.width).toDouble();
    }
    // A label every bar, or every 4, 16, 64… bars when bars are narrower than a label (owner, 2026-11-11: far out it
    // still reads); a tick at each label.
    var every = 1;
    while (every * barW < (every >= 1024 ? 40 : 28) && every < 1 << 30) {
      every *= 4;
    }
    final tick = Paint()..color = Neon.dim.withValues(alpha: 0.4)..strokeWidth = 1;
    canvas.drawLine(Offset(from, size.height - 0.5), Offset(to, size.height - 0.5), Paint()..color = Neon.line);
    for (var b = (from / barW / every).floor() * every; b * barW <= to; b += every) {
      final x = b * barW;
      canvas.drawLine(Offset(x, 0), Offset(x, height * 0.5), tick);
      final label = TextPainter(text: TextSpan(text: '${b + 1}', style: Neon.code(size: 10, color: Neon.dim)),
        textDirection: TextDirection.ltr, maxLines: 1)..layout(maxWidth: math.max(1.0, every * barW - 4));
      label.paint(canvas, Offset(x + 3, (height * 0.5 - label.height) / 2));
      label.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.stepW != stepW || old.barSteps != barSteps || old.scroll != scroll || old.height != height;
}

/// A loop range's band over the top [band] pixels of a ruler, from x [from] to [to], bright while [on], with a grip
/// at each end (Arrange's ruler and the piano roll's).
class LoopBand extends StatelessWidget {
  const LoopBand({super.key, required this.from, required this.to, required this.on, required this.band});
  final double from, to, band;
  final bool on;

  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
    Positioned(key: const ValueKey('ruler-loop'), left: from, width: math.max(2.0, to - from), top: 1,
      height: band - 2, child: DecoratedBox(decoration: BoxDecoration(
        color: (on ? Neon.blue : Neon.dim).withValues(alpha: on ? 0.28 : 0.14),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: (on ? Neon.blue : Neon.dim).withValues(alpha: on ? 0.9 : 0.4))))),
    for (final x in [from, to])
      Positioned(left: x - 3, width: 6, top: 0, height: band, child: DecoratedBox(
        decoration: BoxDecoration(color: on ? Neon.blue : Neon.dim, borderRadius: BorderRadius.circular(2)))),
  ]);
}
