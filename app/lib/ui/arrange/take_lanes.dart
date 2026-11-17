// A track's take lanes in the arranger (#209, comping; owner 2026-11-17): a row per take of its clips with takes,
// under the track like the automation lanes. Swipe across a take to pick that part into the comp; tap selects the
// clip, double tap plays the take whole, hold opens the menu (Use this take, Flatten, Hide), hold-and-move moves a
// join of the comp.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/automation_edit.dart' show snapStep;
import '../../model/clip_automation.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/comping.dart';
import '../../model/project.dart';
import '../haptics.dart';
import '../motion.dart';
import '../pointer_input.dart';
import '../theme.dart';
import 'audio_waveform.dart';
import 'clip_preview.dart';
import 'long_press_menu.dart';
import 'track_color.dart';
import 'track_lanes.dart' show kArrangeLaneHeight;

/// A take lane's row height: the automation lanes' default.
const double kTakeLaneHeight = kArrangeLaneHeight;

/// The height [layer]'s open take lanes add under it (none while hidden or without takes).
double takeLanesHeight(LayerDoc layer) =>
    layer.showTakes && !layer.isFolder ? takeLaneCount(layer) * kTakeLaneHeight : 0;

/// The menu of take lane [index] (its header's, and its body's with [clip] and [at] for a clip's own actions).
Future<void> takeLaneMenu(BuildContext context, AppState state, LayerDoc layer, int index, Offset at,
    {TakeClip? clip}) async {
  final take = clip == null || index >= clip.takes.length ? null : clip.takes[index];
  final all = takeClips(layer);
  final v = await showLongPressMenu<String>(context, at: at, title: 'Take ${index + 1}', style: state.settings.longPressMenu,
      actions: [
        if (take != null) ...[
          const MenuAction('whole', 'Use this take', Icons.check_circle_outline, section: 'Take'),
          const MenuAction('flatten', 'Flatten', Icons.compress, section: 'Comp'),
        ] else ...[
          MenuAction('whole-all', 'Use take ${index + 1} everywhere', Icons.check_circle_outline, section: 'Take'),
          if (all.isNotEmpty) const MenuAction('flatten-all', 'Flatten all takes', Icons.compress, section: 'Comp'),
        ],
        const MenuAction('hide', 'Hide take lanes', Icons.visibility_off_outlined, section: 'Lanes'),
      ]);
  if (v == null) return;
  switch (v) {
    case 'whole':
      state.useWholeTake(layer, clip!, take!);
    case 'flatten':
      state.flattenTakes(layer, [clip!]);
    case 'whole-all':
      // One undo step per clip would be several: each clip that has this take plays it.
      for (final c in all) {
        if (index < c.takes.length) state.useWholeTake(layer, c, c.takes[index]);
      }
    case 'flatten-all':
      state.flattenTakes(layer, all);
    case 'hide':
      state.setTakesShown(layer, false);
  }
  Haptics.tap();
}

/// The take lanes' names under a track's header, a row each, as the automation lanes' headers look; a hold, a
/// double tap or a right-click on the name opens the lane's menu.
class TakeLaneHeaders extends StatelessWidget {
  const TakeLaneHeaders({super.key, required this.state, required this.layer, required this.indent});
  final AppState state;
  final LayerDoc layer;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final color = trackColor(state, layer);
    final clips = takeClips(layer);
    return Column(children: [
      for (var i = 0; i < takeLaneCount(layer); i++)
        Container(key: ValueKey('take-header-${layer.id}-$i'), height: kTakeLaneHeight,
          padding: EdgeInsets.only(left: 10 + indent, right: 6),
          decoration: BoxDecoration(color: Color.lerp(Neon.panel, color, 0.08),
            border: Border(left: BorderSide(color: color.withValues(alpha: 0.6), width: 2),
              bottom: BorderSide(color: Neon.line.withValues(alpha: 0.6)))),
          child: GestureDetector(key: ValueKey('take-name-${layer.id}-$i'), behavior: HitTestBehavior.opaque,
            onLongPressStart: (d) => takeLaneMenu(context, state, layer, i, d.globalPosition),
            onDoubleTapDown: (d) => takeLaneMenu(context, state, layer, i, d.globalPosition),
            onSecondaryTapDown: (d) => takeLaneMenu(context, state, layer, i, d.globalPosition),
            child: Row(children: [
              Expanded(child: Text('Take ${i + 1}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color))),
              // A dot while some clip's comp plays part of this take.
              AnimatedOpacity(opacity: clips.any((c) => i < c.takes.length && c.comp.any((p) => p.take == c.takes[i]))
                  ? 1 : 0, duration: EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero,
                child: Container(key: ValueKey('take-used-${layer.id}-$i'), width: 6, height: 6,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
            ]))),
    ]);
  }
}

/// The take lanes on the timeline, level with [TakeLaneHeaders]: lane i shows take i of each clip with takes,
/// where the clip is.
class TakeLaneRows extends StatelessWidget {
  const TakeLaneRows({super.key, required this.state, required this.layer, required this.stepW, required this.width});
  final AppState state;
  final LayerDoc layer;
  final double stepW, width;

  @override
  Widget build(BuildContext context) {
    final clips = takeClips(layer);
    final color = trackColor(state, layer);
    final p = state.project;
    return Column(children: [
      for (var i = 0; i < takeLaneCount(layer); i++)
        Container(key: ValueKey('take-row-${layer.id}-$i'), width: width, height: kTakeLaneHeight,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.03),
              border: Border(bottom: BorderSide(color: Neon.line.withValues(alpha: 0.6)))),
          child: Stack(children: [
            for (final c in clips)
              if (i < c.takes.length)
                Positioned(left: c.start * stepW, top: 3, height: kTakeLaneHeight - 6,
                  width: math.max(4.0, (c.end(p) - c.start) * stepW),
                  child: TakeLaneClip(key: ValueKey('take-${c.id}-$i'), state: state, layer: layer, clip: c, index: i,
                      stepW: stepW, color: color)),
          ])),
    ]);
  }
}

/// Take [index] of [clip] in its lane: the take's notes or waveform, the parts the comp plays from it lit and the
/// rest dimmed, the comp's joins marked.
class TakeLaneClip extends StatefulWidget {
  const TakeLaneClip({super.key, required this.state, required this.layer, required this.clip, required this.index,
      required this.stepW, required this.color});
  final AppState state;
  final LayerDoc layer;
  final TakeClip clip;
  final int index;
  final double stepW;
  final Color color;

  @override
  State<TakeLaneClip> createState() => _TakeLaneClipState();
}

class _TakeLaneClipState extends State<TakeLaneClip> {
  final _clicks = ClickCounter();
  final _hold = HoldToMove();
  int _pointer = 0;

  /// A swipe in progress (song steps), or a join being moved (its index and where it is).
  double? _swipeFrom, _swipeTo;
  int? _join;
  double? _joinAt;

  AppState get s => widget.state;
  TakeClip get c => widget.clip;
  String get take => c.takes[widget.index];

  @override
  void dispose() {
    _hold.stop();
    super.dispose();
  }

  double _stepAt(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    final x = box == null ? 0.0 : box.globalToLocal(global).dx;
    final step = c.start + x / widget.stepW;
    if (HardwareKeyboard.instance.isShiftPressed) return step;
    return snapStep(step, s.arrangementSnapSteps);
  }

  void _tap() {
    if (_clicks.twice) {
      // The quick action: this take plays whole.
      if (s.useWholeTake(widget.layer, c, take)) Haptics.tap();
      return;
    }
    if (c.midi case final m?) {
      s.selectClip(widget.layer, m);
    } else {
      s.selectAudioClip(widget.layer, c.audio!);
    }
    Haptics.tap();
  }

  void _swipeStart(DragStartDetails d) {
    if (c.locked) {
      Haptics.error();
      return;
    }
    Haptics.grab();
    final at = _stepAt(d.globalPosition);
    setState(() => _swipeFrom = _swipeTo = at);
  }

  void _swipeUpdate(DragUpdateDetails d) {
    if (_swipeFrom == null) return;
    final at = _stepAt(d.globalPosition);
    if (at != _swipeTo) Motion.tick();
    setState(() => _swipeTo = at);
  }

  void _swipeEnd() {
    final a = _swipeFrom, b = _swipeTo;
    setState(() => _swipeFrom = _swipeTo = null);
    if (a == null || b == null || a == b) return;
    if (s.swipeTake(widget.layer, c, take, a, b)) Haptics.drop();
  }

  void _holdStart(LongPressStartDetails d) {
    _hold.start(_pointer, d.globalPosition,
      begin: (from) {
        if (!mounted || c.locked) return;
        // The join nearest where the hold went down moves with the finger.
        final at = c.start + (from.dx - (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dx) /
            widget.stepW;
        final joins = c.joins(s.project);
        if (joins.isEmpty) return;
        var best = 0;
        for (var i = 1; i < joins.length; i++) {
          if ((joins[i] - at).abs() < (joins[best] - at).abs()) best = i;
        }
        Haptics.grab();
        setState(() {
          _join = best % (c.comp.length - 1) + 1;
          _joinAt = joins[best];
        });
      },
      move: (at) {
        if (_join == null) return;
        final step = _stepAt(at);
        if (step != _joinAt) Motion.tick();
        setState(() => _joinAt = step);
      },
      end: (cancel) {
        final j = _join, at = _joinAt;
        setState(() => _join = _joinAt = null);
        if (!cancel && j != null && at != null && s.moveCompJoin(widget.layer, c, j, at)) Haptics.drop();
      });
    takeLaneMenu(context, s, widget.layer, widget.index, d.globalPosition, clip: c);
  }

  /// The song-step spans of the clip where this take plays in the comp.
  List<(double, double)> _lit(ProjectDoc p) {
    final parts = c.comp;
    final out = <(double, double)>[];
    final end = c.end(p);
    if (c.audio case final a?) {
      final u0 = a.offsetSeconds, u1 = audioSourceEnd(p, a);
      for (final r in compRanges(parts, u1)) {
        if (r.take != take || r.to <= u0) continue;
        out.add((audioStepAt(p, a, math.max(r.from, u0)), audioStepAt(p, a, r.to)));
      }
      return out;
    }
    final m = c.midi!;
    final loop = m.loop ? p.clipLoopSteps(m) : 1 << 30;
    for (var pass = 0; pass < 4096; pass++) {
      final base = m.startSteps - m.sourceOffsetSteps + pass * loop;
      if (base >= end) break;
      for (final r in compRanges(parts, loop.toDouble())) {
        if (r.take != take) continue;
        final a = math.max(base + r.from, c.start), b = math.min(base + r.to, end);
        if (b > a) out.add((a, b));
      }
      if (!m.loop) break;
    }
    return out;
  }

  Widget _content(ProjectDoc p, double width, double height) {
    if (c.midi case final m?) {
      final view = ClipDoc(id: m.id, patternId: take, startSteps: m.startSteps, lengthSteps: m.lengthSteps,
          sourceOffsetSteps: m.sourceOffsetSteps, loop: m.loop, loopSteps: m.loopSteps);
      final preview = MidiClipPreview.of(p, view, stepW: widget.stepW, top: 2, color: widget.color);
      return preview == null ? const SizedBox.shrink()
          : CustomPaint(key: ValueKey('take-notes-${c.id}-${widget.index}'), painter: ClipPreviewPainter(preview));
    }
    final a = c.audio!;
    final asset = p.asset(take);
    if (asset == null) return const SizedBox.shrink();
    final per = width <= 0 ? 0.0 : (audioSourceEnd(p, a) - a.offsetSeconds) / width;
    return CustomPaint(key: ValueKey('take-wave-${c.id}-${widget.index}'), painter: AudioClipPainter(
      peaks: () => WaveformCache.instance.peaks(s.audioIo, asset.path, asset.seconds, per.abs()),
      window: ClipWindow(offset: a.offsetSeconds, perPixel: per, fileSeconds: asset.seconds, reverse: a.reverse,
          loop: a.loop, loopStart: a.loopStart, loopEnd: a.loopEnd),
      color: widget.color, gain: a.gain, fadeIn: 0, fadeOut: 0, inCurve: a.fadeInCurve, outCurve: a.fadeOutCurve,
      path: asset.path));
  }

  @override
  Widget build(BuildContext context) {
    // On its way out (Flatten took the takes): nothing left to show.
    if (widget.index >= c.takes.length) return const SizedBox.shrink();
    final p = s.project;
    final selected = s.selectedClipIds.contains(c.id);
    final d = EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      double x(double step) => (step - c.start) * widget.stepW;
      final lit = _lit(p);
      final joins = c.joins(p);
      final swipe = _swipeFrom == null ? null : (math.min(_swipeFrom!, _swipeTo!), math.max(_swipeFrom!, _swipeTo!));
      return Listener(
        onPointerDown: (e) {
          _pointer = e.pointer;
          _clicks.down(e, target: c.id);
        },
        onPointerUp: _clicks.up,
        child: GestureDetector(
          key: ValueKey('take-lane-${c.id}-${widget.index}'),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTap: _tap,
          onLongPressStart: _holdStart,
          onSecondaryTapUp: (e) => takeLaneMenu(context, s, widget.layer, widget.index, e.globalPosition, clip: c),
          onHorizontalDragStart: _swipeStart,
          onHorizontalDragUpdate: _swipeUpdate,
          onHorizontalDragEnd: (_) => _swipeEnd(),
          onHorizontalDragCancel: _swipeEnd,
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5),
              color: widget.color.withValues(alpha: 0.10),
              border: Border.all(color: widget.color.withValues(alpha: selected ? 0.9 : 0.4), width: selected ? 1.4 : 1)),
            child: ClipRRect(borderRadius: BorderRadius.circular(5), child: Stack(children: [
              // The lit parts: what the comp plays from this take.
              for (final (i, (a, b)) in lit.indexed)
                AnimatedPositioned(key: ValueKey('take-lit-${c.id}-${widget.index}-$i'), duration: d,
                    curve: EditMotion.curve, left: x(a), width: math.max(0.0, x(b) - x(a)), top: 0, bottom: 0,
                    child: ColoredBox(color: widget.color.withValues(alpha: 0.30))),
              Positioned.fill(child: _content(p, w, h)),
              // Everything else dimmed.
              Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _DimPainter(
                  [for (final (a, b) in lit) (x(a), x(b))], Colors.black.withValues(alpha: 0.42))))),
              for (final j in joins)
                Positioned(left: x(j) - 0.75, width: 1.5, top: 0, bottom: 0,
                    child: ColoredBox(color: Neon.ink.withValues(alpha: 0.55))),
              if (swipe != null)
                Positioned(key: ValueKey('take-swipe-${c.id}-${widget.index}'), left: x(swipe.$1),
                    width: math.max(1.0, x(swipe.$2) - x(swipe.$1)), top: 0, bottom: 0,
                    child: Container(decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.35),
                        border: Border.symmetric(vertical: BorderSide(color: widget.color, width: 1.5))))),
              if (_joinAt != null)
                Positioned(left: x(_joinAt!) - 1, width: 2, top: 0, bottom: 0, child: ColoredBox(color: widget.color)),
              if (h >= 30)
                Positioned(left: 4, top: 1, child: Text(
                    c.audio != null ? (p.asset(take)?.name ?? 'Take ${widget.index + 1}')
                        : (p.module(take)?.name ?? 'Take ${widget.index + 1}'),
                    style: TextStyle(color: widget.color, fontSize: 9, fontWeight: FontWeight.w700))),
            ])),
          ),
        ),
      );
    });
  }
}

/// Shades [size] outside the lit spans [lit] (x ranges).
class _DimPainter extends CustomPainter {
  _DimPainter(this.lit, this.color);
  final List<(double, double)> lit;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final spans = [...lit]..sort((a, b) => a.$1.compareTo(b.$1));
    var x = 0.0;
    for (final (a, b) in spans) {
      if (a > x) canvas.drawRect(Rect.fromLTRB(x, 0, math.min(a, size.width), size.height), paint);
      x = math.max(x, b);
    }
    if (x < size.width) canvas.drawRect(Rect.fromLTRB(x, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.color != color || old.lit.length != lit.length ||
      Iterable<int>.generate(lit.length).any((i) => old.lit[i] != lit[i]);
}

/// The comp's joins over a clip on the track (its crossfades for audio): a short line with a small cross at each.
class CompJoinsPainter extends CustomPainter {
  CompJoinsPainter(this.joins, this.color, {this.crossfade = 0});
  final List<double> joins; // x in the clip's box
  final Color color;

  /// Half a crossfade's width in pixels (0: a plain line, a MIDI comp).
  final double crossfade;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    for (final x in joins) {
      if (x < 0 || x > size.width) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line..color = color.withValues(alpha: 0.5));
      final w = math.max(3.0, crossfade);
      line.color = color;
      canvas.drawLine(Offset(x - w, size.height - 8), Offset(x + w, size.height - 2), line);
      canvas.drawLine(Offset(x - w, size.height - 2), Offset(x + w, size.height - 8), line);
    }
  }

  @override
  bool shouldRepaint(CompJoinsPainter old) =>
      old.color != color || old.crossfade != crossfade || old.joins.length != joins.length ||
      Iterable<int>.generate(joins.length).any((i) => old.joins[i] != joins[i]);
}

/// Opens or closes [layer]'s take lanes (the clip menus' and the track menu's Take lanes).
void toggleTakeLanes(AppState state, LayerDoc layer) => state.setTakesShown(layer, !layer.showTakes);

/// Whether an audio clip draws as a comp: two or more parts.
bool audioComped(AudioClipDoc c) => c.comp.length >= 2;
