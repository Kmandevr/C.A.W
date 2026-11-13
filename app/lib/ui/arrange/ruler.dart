// Arrange's ruler (docs/reaper-flow.md, gap 2; #207): bar numbers from the time signatures with a flag at each
// change, and the loop range (drag along the ruler to draw it, drag its handles to adjust it, as in REAPER). A hold
// adds a section, marker, signature change or tempo change; sections and markers live in the section bar above.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_markers.dart';
import '../../model/arrange_tempo.dart';
import '../../model/project.dart';
import '../../model/tempo_map.dart';
import '../panel_motion.dart';
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
    final bars = p.bars;
    final bar = bars.barAt(step / 4);
    final sig = bars.signatureOfBar(bar);
    final v = await showLongPressMenu<String>(context, at: global, title: 'Bar ${bar + 1}',
      style: s.settings.longPressMenu, actions: [
        const MenuAction('section', 'Add section', Icons.space_bar, section: 'Song'),
        const MenuAction('marker', 'Add marker', Icons.flag_outlined, section: 'Song'),
        MenuAction('signature', 'Time signature… (${sig.label})', Icons.straighten, section: 'Time'),
        const MenuAction('tempo', 'Add tempo change', Icons.speed, section: 'Time'),
        const MenuAction('list', 'Markers and sections…', Icons.list, section: 'Song'),
      ]);
    if (v == null || !mounted) return;
    switch (v) {
      case 'list':
        await showMarkerList(context, s);
      case 'marker':
        s.addMarker(step);
      case 'section':
        // The time selection when it is under the finger, else four bars from the bar pressed.
        final a = s.timeSelectionStart, b = s.timeSelectionEnd;
        if (a != null && b != null && a != b && step >= math.min(a, b) && step <= math.max(a, b)) {
          s.addMarker(math.min(a, b), end: math.max(a, b));
        } else {
          s.addMarker((bars.beatOfBar(bar) * 4).round(), end: (bars.beatOfBar(bar + 4) * 4).round());
        }
      case 'signature':
        final pick = await pickTimeSignature(context, sig.num, sig.den, bar: bar);
        if (pick != null) s.setTimeSignature(bar, pick.num, pick.den);
      case 'tempo':
        // At the step pressed, at the tempo playing there: the lane shows, and the point is dragged from there.
        s.addTempoPoint(step / 4);
    }
  }

  Future<void> _flagMenu(TimeSignature sig, Offset global) async {
    final v = await showLongPressMenu<String>(context, at: global, title: '${sig.label} from bar ${sig.bar + 1}',
      style: s.settings.longPressMenu, actions: [
        const MenuAction('change', 'Change…', Icons.straighten),
        if (sig.bar > 0) const MenuAction('remove', 'Remove', Icons.delete_outline, danger: true),
      ]);
    if (v == null || !mounted) return;
    if (v == 'remove') return s.removeTimeSignature(sig.bar);
    final pick = await pickTimeSignature(context, sig.num, sig.den, bar: sig.bar);
    if (pick != null) s.setTimeSignature(sig.bar, pick.num, pick.den);
  }

  /// A signature change's flag: its pole on the bar line and its n/d beside it, in the ruler's lower half.
  Widget _flag(TimeSignature sig) {
    final h = widget.height, w = widget.stepW;
    final flagH = math.max(13.0, h * 0.5);
    return Positioned(key: ValueKey('sig-flag-${sig.bar}'), left: sig.beat * 4 * w, top: h - flagH, height: flagH,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => s.seekTo(sig.beat * 4),
        onLongPressStart: (d) => _flagMenu(sig, d.globalPosition),
        onSecondaryTapUp: (d) => _flagMenu(sig, d.globalPosition),
        child: Semantics(label: 'Time signature ${sig.label} from bar ${sig.bar + 1}: hold to change it',
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 1.5, color: Neon.yellow),
          Container(
            margin: const EdgeInsets.only(bottom: 1),
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(color: Neon.yellow.withValues(alpha: 0.22),
              borderRadius: const BorderRadius.only(topRight: Radius.circular(3), bottomRight: Radius.circular(3))),
            alignment: Alignment.center,
            child: Text(sig.label, style: Neon.code(size: 9, color: Neon.yellow).copyWith(fontWeight: FontWeight.w700))),
        ]))));
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
    final sigs = p.timeSignatures;
    // Flags at each change, and at bar 1 once the meter is anything but plain 4/4.
    final flags = [for (final g in sigs) if (g.bar > 0 || sigs.length > 1 || g.label != '4/4') g];
    return SizedBox(key: const ValueKey('arrange-ruler'), width: widget.width, height: h, child: Stack(children: [
      Positioned.fill(child: Semantics(
        label: 'Ruler: drag to set the loop range, tap to move the playhead, hold to add a section, marker, time signature '
            'or tempo change',
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
          child: CustomPaint(painter: _RulerPainter(w, p.bars, widget.scroll, h)))))),
      // The loop range: a band over the top half, bright while on, with a grip at each end. It fades out when it
      // goes (a handle dragged onto the other end removes it).
      Positioned.fill(child: IgnorePointer(child: FadeHold<(int, int, bool)>(
        value: shown ? (from, to, on) : null,
        builder: (context, r) => LoopBand(from: r.$1 * w, to: r.$2 * w, on: r.$3, band: band)))),
      for (final g in flags) _flag(g),
    ]));
  }
}

/// How far past each side of the view the ruler and grid paint, in views (0 at rest): a time pinch shows the lanes
/// scaled ([ArrangerScreen]), and zooming out brings in what was beside the view before it lays out again.
final arrangeSpanReveal = ValueNotifier<double>(0);

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.stepW, this.bars, this.scroll, this.height)
      : super(repaint: Listenable.merge([scroll, arrangeSpanReveal]));
  final double stepW, height;
  final BarMath bars;
  final ScrollController scroll;

  @override
  void paint(Canvas canvas, Size size) {
    var from = 0.0, to = math.min(size.width, 4096.0);
    if (scroll.hasClients) {
      final pos = scroll.positions.last;
      final reveal = pos.viewportDimension * arrangeSpanReveal.value;
      from = (pos.pixels - reveal).clamp(0.0, size.width).toDouble();
      to = (pos.pixels + pos.viewportDimension + reveal).clamp(from, size.width).toDouble();
    }
    final tick = Paint()..color = Neon.dim.withValues(alpha: 0.4)..strokeWidth = 1;
    canvas.drawLine(Offset(from, size.height - 0.5), Offset(to, size.height - 0.5), Paint()..color = Neon.line);
    paintBarNumbers(canvas, bars, stepW, from, to, (x, label, room) {
      canvas.drawLine(Offset(x, 0), Offset(x, height * 0.5), tick);
      label.layout(maxWidth: math.max(1.0, room - 4));
      label.paint(canvas, Offset(x + 3, (height * 0.5 - label.height) / 2));
    });
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.stepW != stepW || old.bars != bars || old.scroll != scroll || old.height != height;
}

/// Bar numbers from x [from] to [to] at [stepW] pixels a step, from the time signatures: every bar, or every 4, 16,
/// 64… bars when bars are narrower than a label (owner, 2026-11-11: far out it still reads). [draw] gets each label's
/// x, its text (laid out by [draw]) and the room to the next label.
void paintBarNumbers(Canvas canvas, BarMath bars, double stepW, double from, double to,
    void Function(double x, TextPainter label, double room) draw) {
  // The narrowest bar in view sets the spacing, so labels never crowd.
  var barW = double.infinity;
  for (final b in bars.bars(from / stepW / 4, to / stepW / 4, limit: 64)) {
    barW = math.min(barW, b.length * 4 * stepW);
  }
  for (final g in bars.signatures) {
    if (g.beat * 4 * stepW > from && g.beat * 4 * stepW < to) barW = math.min(barW, g.barBeats * 4 * stepW);
  }
  if (!barW.isFinite || barW <= 0) return;
  var every = 1;
  while (every * barW < (every >= 1024 ? 40 : 28) && every < 1 << 30) {
    every *= 4;
  }
  for (final b in bars.bars(from / stepW / 4, to / stepW / 4, every: every, limit: 1024)) {
    final x = b.beat * 4 * stepW;
    final label = TextPainter(text: TextSpan(text: '${b.bar + 1}', style: Neon.code(size: 10, color: Neon.dim)),
      textDirection: TextDirection.ltr, maxLines: 1);
    draw(x, label, every * b.length * 4 * stepW);
    label.dispose();
  }
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

/// Asks for a time signature from bar [bar] (0-based), starting at [num]/[den]: the beats a bar (1–32) and the note
/// that counts one (1 to 32). Null when cancelled.
Future<({int num, int den})?> pickTimeSignature(BuildContext context, int num, int den, {required int bar}) =>
    showDialog<({int num, int den})>(context: context, animationStyle: dialogAnimation(context), builder: (context) {
      var n = num, d = den;
      return StatefulBuilder(builder: (context, setState) => AlertDialog(
        title: Text('Time signature from bar ${bar + 1}'),
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          DropdownButton<int>(key: const ValueKey('sig-num'), value: n,
            items: [for (var i = 1; i <= 32; i++) DropdownMenuItem(value: i, child: Text('$i'))],
            onChanged: (v) => setState(() => n = v ?? n)),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('/', style: TextStyle(fontSize: 20))),
          DropdownButton<int>(key: const ValueKey('sig-den'), value: d,
            items: [for (final i in kSignatureDens) DropdownMenuItem(value: i, child: Text('$i'))],
            onChanged: (v) => setState(() => d = v ?? d)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(key: const ValueKey('sig-ok'), onPressed: () => Navigator.of(context).pop((num: n, den: d)),
              child: const Text('Set')),
        ]));
    });
