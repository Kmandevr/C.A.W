// Arrange's track lanes and the timeline's painters: the grid, the bar ruler, the playhead, the marquee and clips as blocks.
part of '../arranger_screen.dart';

/// The space above and below a clip in its row.
double _clipInset(double trackHeight) => trackHeight < 60 ? 3 : 8;

class _TimelineLane extends StatefulWidget {
  const _TimelineLane({super.key, required this.state, required this.layer, required this.width,
    required this.stepW, required this.zoom, required this.gen, required this.look, required this.trackHeight,
    required this.selectedIds,
    required this.callbacks, this.drag, this.thin = false});
  final AppState state;
  final LayerDoc layer;
  final double width, stepW, trackHeight;

  /// The pixels per step as they change, for the clips, which lay out at it without being built again.
  final ValueListenable<double> zoom;

  /// The arranger's build this lane comes from (a zoom alone keeps it).
  final int gen;

  /// What the clips are built from besides their own fields: the project's edits and the settings. A clip keeps its
  /// widget across builds of the arranger while this, its selection, colour and size stay the same (#235).
  final Object look;

  /// A thin row: its clips are bars (also while it glides there).
  final bool thin;
  final Set<String> selectedIds;
  final _TrackCallbacks callbacks;

  /// Null on the pinned track, where clips only move in time.
  final ArrangeDrag? drag;

  @override
  State<_TimelineLane> createState() => _TimelineLaneState();
}

class _TimelineLaneState extends State<_TimelineLane> {
  // #90: the clips are built in a window around the view, placed relative to its origin.
  ScrollPosition? _pos;
  TimelineWindow _shownWindow = TimelineWindow.all;

  double _windowStepW = 0;

  /// The window to build: the one shown while it still covers the view at the same zoom, else a new one around it.
  TimelineWindow _window() {
    final p = _pos;
    if (p == null || !p.hasPixels || !p.hasViewportDimension) return TimelineWindow.all;
    final w = widget.stepW;
    if (w == _windowStepW && !_shownWindow.isAll &&
        _shownWindow.covers(p.pixels / w, (p.pixels + p.viewportDimension) / w)) {
      return _shownWindow;
    }
    return TimelineWindow.around(p.pixels, p.viewportDimension, w);
  }

  void _onScroll() {
    if (!mounted) return;
    if (_window() != _shownWindow) setState(() {});
  }

  // The clip widgets this lane built, by clip id: where they were placed (pixels per step, row height and window
  // origin; the clip's rectangle), what the clip was built from, the slot and the clip inside it (#241, #235). A
  // build reuses the slot while the place and the clip's inputs stay, so a window move builds only the clips coming
  // into view and a selection only the clips it changes; a zoom places the same clips again (the slot, not the clip,
  // is built). A new row height or a dependency change builds them all anew.
  final Map<String, (Object, Rect, Object, Widget, Widget)> _clipWidgets = {};

  @override
  void didUpdateWidget(_TimelineLane old) {
    super.didUpdateWidget(old);
    if (old.trackHeight != widget.trackHeight || old.thin != widget.thin || old.zoom != widget.zoom ||
        old.drag != widget.drag || old.state != widget.state) {
      _clipWidgets.clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clipWidgets.clear();
    final p = Scrollable.maybeOf(context, axis: Axis.horizontal)?.position;
    if (p == _pos) return;
    _pos?.removeListener(_onScroll);
    _pos = p?..addListener(_onScroll);
  }

  @override
  void dispose() {
    _pos?.removeListener(_onScroll);
    super.dispose();
  }

  /// A Ctrl+drag with the mouse in empty space draws a new empty clip (REAPER): from, to, in steps.
  (int, int)? _drawing;
  final _clicks = ClickCounter();

  // Edit animations: the clips seen at the last build (null before the first) and where, and deleted ones leaving.
  Set<String>? _known;
  final Map<String, (Rect, Color, String)> _seen = {};
  final Map<String, (Rect, Color, String)> _leaving = {};

  /// Which clips an edit just added (they grow in) and deleted (they shrink out where they were); a clip that went
  /// to another track only moved, and appears there.
  Set<String> _clipChanges(Duration? motion) {
    final ids = {for (final c in layer.clips) c.id};
    final known = _known;
    _known = ids;
    if (known == null) return const {};
    final gone = known.difference(ids);
    if (gone.isNotEmpty && motion != null) {
      final anywhere = {for (final l in state.project.layers) for (final c in l.clips) c.id};
      for (final id in gone) {
        if (!anywhere.contains(id) && _seen[id] != null) _leaving[id] = _seen[id]!;
      }
    }
    for (final id in gone) {
      _seen.remove(id);
    }
    return ids.difference(known);
  }

  AppState get state => widget.state;
  LayerDoc get layer => widget.layer;
  int get _snap => state.arrangementSnapSteps;
  int _snapped(double x, {bool up = false}) {
    final raw = math.max(0, (x / widget.stepW).floor());
    if (HardwareKeyboard.instance.isShiftPressed) return raw;
    return up ? ((raw + _snap) ~/ _snap) * _snap : (raw ~/ _snap) * _snap;
  }

  /// REAPER's right-drag in the arrange view draws a marquee around items; Shift adds to the selection (UG 15.x mouse
  /// modifiers, "Arrange view, right drag").
  bool _marquee = false;

  /// A mouse's left drag on empty space draws a time selection at once (owner, 2026-11-11; a finger holds first):
  /// where it went down, until it has moved [_selectSlop]; then whether a selection was drawn, so the click's tap
  /// doesn't also reset it.
  double? _selectFrom;
  bool _mouseSelected = false;
  static const double _selectSlop = 4;

  void _drawDown(PointerDownEvent e) {
    _mouseSelected = false;
    _selectFrom = null;
    // The middle button and Space+drag pan the view (the screen's own listener).
    if (startsMousePan(e)) return;
    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
      _marquee = true;
      widget.callbacks.onMarquee(_Marquee.start, e.position, HardwareKeyboard.instance.isShiftPressed);
      return;
    }
    if (!isMousePointer(e.kind) || e.buttons != kPrimaryMouseButton) return;
    if (!HardwareKeyboard.instance.isControlPressed) {
      // In Select mode the drag draws a box around clips; otherwise a time selection.
      if (widget.callbacks.selectMode()) {
        _marquee = true;
        widget.callbacks.onMarquee(_Marquee.start, e.position, true);
      } else {
        _selectFrom = e.localPosition.dx;
      }
      return;
    }
    final at = _snapped(e.localPosition.dx);
    setState(() => _drawing = (at, at + _snap));
  }

  void _drawMove(PointerMoveEvent e) {
    if (_marquee) return widget.callbacks.onMarquee(_Marquee.move, e.position, false);
    final from = _selectFrom;
    if (from != null) {
      final x = e.localPosition.dx;
      if (!_mouseSelected) {
        if ((x - from).abs() < _selectSlop) return;
        _mouseSelected = true;
        state.beginTimeSelection((from / widget.stepW).round());
      }
      state.updateTimeSelection((x / widget.stepW).round());
      return;
    }
    final d = _drawing;
    if (d == null) return;
    final to = math.max(d.$1 + 1, _snapped(e.localPosition.dx, up: true));
    if (to != d.$2) setState(() => _drawing = (d.$1, to));
  }

  void _drawUp(PointerEvent e) {
    if (_marquee) {
      _marquee = false;
      return widget.callbacks.onMarquee(_Marquee.end, e.position, false);
    }
    if (_selectFrom != null) {
      _selectFrom = null;
      if (_mouseSelected) state.endTimeSelection();
      return;
    }
    final d = _drawing;
    if (d == null) return;
    setState(() => _drawing = null);
    if (e is PointerUpEvent) state.addEmptyClip(layer, d.$1, d.$2 - d.$1);
  }

  @override
  Widget build(BuildContext context) {
    final trackHeight = widget.trackHeight, stepW = widget.stepW;
    final height = trackHeight;
    final thin = widget.thin;
    final blocks = stepW * 16 < 4;
    final color = trackColor(state, layer);
    final leaving = EditMotion.of(context, EditMotionKind.clips);
    final appearing = _clipChanges(leaving);
    final win = _shownWindow = _window();
    _windowStepW = stepW;
    // The first layout has no viewport yet: the window settles right after it, not on the first scroll.
    if (win.isAll && _pos != null) WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    // A clip outside the window isn't built, unless it is selected or a drag is on (it may be the one carried).
    bool keep(String id, double start, double end) =>
        win.shows(start, end) || widget.selectedIds.contains(id) || (widget.drag?.active ?? false);
    // A clip that left the window is built anew when it comes back (its slot was let go).
    if (_clipWidgets.isNotEmpty) {
      final kept = {
        for (final c in layer.clips)
          if (keep(c.id, c.startSteps.toDouble(), (c.startSteps + c.lengthSteps).toDouble())) c.id,
        for (final c in layer.audioClips)
          if (keep(c.id, c.startSteps, c.startSteps + c.spanSteps(state.project.tempo))) 'audio:${c.id}',
      };
      _clipWidgets.removeWhere((id, _) => !kept.contains(id));
    }
    // A dropped effect or instrument goes on this track (an instrument asks before replacing one); a dropped
    // pattern or MIDI file becomes clips where it lands. On a folder, its first track inside takes it.
    final lane = DragTarget<AssetDrag>(
      onAcceptWithDetails: (d) {
        final box = context.findRenderObject() as RenderBox?;
        final x = box == null ? 0.0 : box.globalToLocal(d.offset).dx;
        dropOnTrack(context, state, layer, d.data, atStep: math.max(0, (x / stepW).floor()));
      },
      builder: (context, hovering, _) => SizedBox(width: widget.width, height: height,
    child: Stack(children: [
      Positioned.fill(child: Listener(
        onPointerDown: (e) {
          _clicks.down(e);
          _drawDown(e);
        },
        onPointerMove: _drawMove,
        onPointerUp: (e) {
          _clicks.up(e);
          _drawUp(e);
        },
        onPointerCancel: _drawUp,
        child: GestureDetector(behavior: HitTestBehavior.opaque,
        // A plain horizontal drag belongs to the enclosing scroll view. Long-press
        // drag creates a time selection without stealing normal timeline navigation.
        // A tap sets the edit cursor; stopped, play then starts there and Split cuts there (REAPER).
        onTapUp: (d) {
          // A mouse drag that drew a time selection keeps it.
          if (_mouseSelected) {
            _mouseSelected = false;
            return;
          }
          final step = (d.localPosition.dx / stepW).round();
          state.setTimeSelection(step, step);
          if (!state.meters.playing) state.seekTo(step.toDouble());
          // A quick second tap (or a double-click) in empty space also draws a one-bar empty clip there (the touch
          // stand-in for REAPER's Ctrl+drag); the first tap answered at once.
          if (_clicks.twice) state.addEmptyClip(layer, _snapped(_clicks.localPosition.dx), state.project.stepsPerBar);
        },
        // In Select mode a long-press drag draws a box around clips instead of a time selection.
        onLongPressStart: (d) => widget.callbacks.selectMode()
            ? widget.callbacks.onMarquee(_Marquee.start, d.globalPosition, true)
            : state.beginTimeSelection((d.localPosition.dx / stepW).round()),
        onLongPressMoveUpdate: (d) => widget.callbacks.selectMode()
            ? widget.callbacks.onMarquee(_Marquee.move, d.globalPosition, true)
            : state.updateTimeSelection((d.localPosition.dx / stepW).round()),
        onLongPressEnd: (d) => widget.callbacks.selectMode()
            ? widget.callbacks.onMarquee(_Marquee.end, d.globalPosition, true)
            : state.endTimeSelection(),
        child: hovering.isEmpty ? const SizedBox.expand()
            : DecoratedBox(decoration: BoxDecoration(color: color.withValues(alpha: 0.12),
                border: Border.all(color: color)))))),
      if (state.timeSelectionStart != null && state.timeSelectionEnd != null)
        Positioned(left: math.min(state.timeSelectionStart!, state.timeSelectionEnd!) * stepW, top: 0,
          width: math.max(1.0, (state.timeSelectionEnd! - state.timeSelectionStart!).abs() * stepW), height: height,
          child: IgnorePointer(child: Container(color: Neon.blue.withValues(alpha: .09)))),

      // A thin row (owner, 2026-11-11): each clip is a bar in its colour; the track's header opens it out again. Far
      // out (a bar under 4 px) the clips are blocks too, merged per pixel column, so nothing is built per clip.
      if (thin || blocks) ...[
        Positioned.fill(child: IgnorePointer(child: RepaintBoundary(child: CustomPaint(
          key: ValueKey('clip-blocks-${layer.id}'),
          painter: _ClipBlocksPainter([
            // Far out a MIDI clip's block is a glass tint with its notes over it as thin lines (owner, 2026-11-12:
            // "Thin note lines"), as its body shows them nearer in; a thin row stays a solid bar.
            for (final clip in layer.clips) (clip.startSteps.toDouble(), clip.lengthSteps.toDouble(),
                (clip.color == null ? color : Neon.layer(clip.color!))
                    .withValues(alpha: clip.mute ? 0.3 : thin ? 0.8 : 0.32)),
            for (final clip in layer.audioClips) (clip.startSteps.toDouble(), clip.spanSteps(state.project.tempo),
                audioClipColor(state, layer, clip).withValues(alpha: clip.mute ? 0.3 : 0.8)),
          ], stepW, inset: thin ? 1 : _clipInset(trackHeight), notes: thin ? const [] : [
            for (final clip in layer.clips)
              if (MidiClipPreview.of(state.project, clip, stepW: stepW, top: 1,
                  drums: layer.instrument?.id == drumsComponentId,
                  color: Color.lerp(clip.color == null ? color : Neon.layer(clip.color!), Neon.ink, 0.45)!
                      .withValues(alpha: clip.mute ? 0.4 : 0.9)) case final preview?)
                (clip.startSteps.toDouble(), clip.lengthSteps.toDouble(), preview),
          ]))))),
        if (thin) for (final clip in layer.clips) Positioned(left: clip.startSteps * stepW, top: 0, width: 1, height: 1,
            child: SizedBox(key: ValueKey('thin-clip-${clip.id}'))),
      ] else Positioned(left: win.originStep * stepW, top: 0, width: win.width(stepW, widget.width), height: height,
        child: Stack(key: ValueKey('lane-window-${layer.id}'), clipBehavior: Clip.none, children: [
      for (final clip in layer.clips)
        if (keep(clip.id, clip.startSteps.toDouble(), (clip.startSteps + clip.lengthSteps).toDouble())) () {
        final rect = Rect.fromLTWH(win.x(clip.startSteps.toDouble(), stepW), _clipInset(trackHeight),
            math.max(12.0, clip.lengthSteps * stepW), trackHeight - 2 * _clipInset(trackHeight));
        final clipColor = clip.color == null ? color : Neon.layer(clip.color!);
        _seen[clip.id] = (rect.shift(Offset(win.originStep * stepW, 0)), clipColor, state.clipName(clip));
        // The window's origin is in the scale: a new origin or zoom places the clips again without a glide.
        final scale = (stepW, trackHeight, win.originStep);
        final selected = widget.selectedIds.contains(clip.id);
        final inputs = (widget.look, clip, selected, clipColor, rect.height, layer.instrument?.id,
            state.project.module(clip.patternId)?.source);
        final had = _clipWidgets[clip.id];
        final appear = appearing.contains(clip.id);
        if (had != null && !appear && had.$1 == scale && had.$2 == rect && had.$3 == inputs) return had.$4;
        // Its own layer: a clip coming into the window paints, the ones already there don't again. It reads the zoom
        // itself, so a zoom keeps it as built.
        final child = had != null && had.$3 == inputs ? had.$5 : RepaintBoundary(child: _TimelineClip(state: state,
            layer: layer, clip: clip, zoom: widget.zoom, drag: widget.drag, height: rect.height, color: clipColor,
            selected: selected, callbacks: widget.callbacks));
        final built = ClipSlot(key: ValueKey('clip-slot-${clip.id}'), id: clip.id, rect: rect, scale: scale,
          appear: appear, child: child);
        _clipWidgets[clip.id] = (scale, rect, inputs, built, child);
        return built;
      }(),
      for (final MapEntry(key: id, value: (rect, leftColor, name)) in _leaving.entries)
        LeavingClip(key: ValueKey('clip-leaving-$id'), rect: rect.shift(Offset(-win.originStep * stepW, 0)),
          color: leftColor, name: name,
          duration: leaving!, onDone: () { if (mounted) setState(() => _leaving.remove(id)); }),
      // Audio clips (API 18): an audio track's clips, with their own handles (audio_clip_view.dart).
      // A fixed clip is as wide as its seconds on the tempo map (#208).
      for (final clip in layer.audioClips)
        if (keep(clip.id, clip.startSteps, clip.startSteps + clip.spanSteps(state.project.tempo))) () {
        final scale = (stepW, trackHeight, win.originStep);
        final inputs = (widget.look, clip, widget.selectedIds.contains(clip.id), audioClipColor(state, layer, clip));
        final had = _clipWidgets['audio:${clip.id}'];
        if (had != null && had.$1 == scale && had.$3 == inputs) return had.$4;
        final built = Positioned(left: win.x(clip.startSteps, stepW), top: _clipInset(trackHeight),
          width: math.max(12.0, clip.spanSteps(state.project.tempo) * stepW),
          height: trackHeight - 2 * _clipInset(trackHeight),
          child: RepaintBoundary(child: AudioClipView(key: ValueKey('audio-view-${clip.id}'), state: state,
            layer: layer, clip: clip, stepW: stepW, drag: widget.drag, height: trackHeight - 2 * _clipInset(trackHeight),
            color: audioClipColor(state, layer, clip), selected: widget.selectedIds.contains(clip.id),
            selectMode: widget.callbacks.selectMode, guides: widget.callbacks.guides,
            onOpen: () => widget.callbacks.onAudioOpen?.call(layer))));
        _clipWidgets['audio:${clip.id}'] = (scale, Rect.zero, inputs, built, built);
        return built;
      }(),
      ])),
      if (_drawing case (final from, final to))
        Positioned(left: from * stepW, top: _clipInset(trackHeight), width: (to - from) * stepW,
          height: trackHeight - 2 * _clipInset(trackHeight), child: IgnorePointer(child: DecoratedBox(
            key: const ValueKey('clip-draw-preview'),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: color.withValues(alpha: 0.18),
              border: Border.all(color: color))))),
    ]),
  ));
    final drag = widget.drag;
    if (drag == null) return lane;
    // A clip dragged over this lane lights it up (its ghost shows where it lands).
    return ValueListenableBuilder<DragSpot?>(
      valueListenable: drag.hover,
      builder: (context, spot, child) {
        final here = drag.active && !drag.dragsTrack && spot?.layerId == layer.id;
        return Stack(children: [
          child!,
          if (here) Positioned.fill(child: IgnorePointer(child: DecoratedBox(key: ValueKey('lane-target-${layer.id}'),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.10),
              border: Border.all(color: color.withValues(alpha: 0.9), width: 1.5))))),
        ]);
      },
      child: lane);
  }
}

/// A spacer under a track (owner, 2026-11-04): an empty row that only separates tracks on screen. Drag its bottom
/// edge to change its height; × removes it. The engine never sees it.
class _SpacerHeader extends StatelessWidget {
  const _SpacerHeader({required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  /// A new spacer's height.
  static const initial = 24.0;

  @override
  Widget build(BuildContext context) {
    final h = layer.spaceBelow;
    return SizedBox(
      height: h,
      child: Stack(children: [
        Center(child: Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 12),
          color: Neon.line.withValues(alpha: 0.6))),
        if (h >= 20) Positioned(right: 0, top: 0, bottom: 0, child: IconButton(
          tooltip: 'Remove spacer', iconSize: 14, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, color: Neon.dim),
          onPressed: () => state.setSpaceBelow(layer, 0))),
        Positioned(left: 0, right: 40, bottom: 0, height: h < 16 ? h : 16, child: Semantics(
          label: 'Resize spacer',
          child: MouseRegion(cursor: SystemMouseCursors.resizeRow, child: GestureDetector(
            key: ValueKey('spacer-grip-${layer.id}'),
            behavior: HitTestBehavior.opaque,
            // Follows the finger from where it went down, though the tracks can scroll (the New track zone).
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragUpdate: (d) => state.setSpaceBelow(layer, (layer.spaceBelow + d.delta.dy).clamp(8.0, LayerDoc.maxSpaceBelow)),
            child: Center(child: Container(width: 28, height: 3,
              decoration: BoxDecoration(color: Neon.dim.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(2)))),
          )),
        )),
      ]),
    );
  }
}
/// The part of a timeline [size] wide that [scroll] shows, in pixels (all of it, up to 4096 px, before layout).
(double, double) visibleSpan(ScrollController scroll, Size size) {
  if (!scroll.hasClients) return (0, math.min(size.width, 4096));
  // While the focus view swaps one timeline for another, the old one is attached for a frame too: use the newest.
  final position = scroll.positions.last;
  final from = position.pixels.clamp(0.0, size.width).toDouble();
  return (from, (position.pixels + position.viewportDimension).clamp(from, size.width).toDouble());
}

/// A lane's clips as plain blocks (a thin row, or zoomed far out): one rectangle per pixel column at most, so a long
/// song's thousands of clips cost a few hundred rectangles.
class _ClipBlocksPainter extends CustomPainter {
  _ClipBlocksPainter(this.clips, this.stepW, {required this.inset, this.notes = const []});
  final List<(double start, double length, Color color)> clips;
  final double stepW, inset;

  /// The MIDI clips' notes drawn over their blocks (each from its pattern's cached picture).
  final List<(double start, double length, MidiClipPreview preview)> notes;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final top = inset, h = math.max(1.0, size.height - 2 * inset);
    // Clips that start in the same pixel column as the block before, in the same colour, extend it.
    var left = -1.0, right = -1.0;
    Color? c;
    void flush() {
      if (c != null) canvas.drawRect(Rect.fromLTRB(left, top, math.max(left + 1, right), top + h), paint..color = c);
    }
    final sorted = [...clips]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (start, length, color) in sorted) {
      final l = start * stepW, r = (start + length) * stepW;
      if (c != null && color == c && l <= right + 1) {
        right = math.max(right, r);
        continue;
      }
      flush();
      left = l.floorToDouble();
      right = r;
      c = color;
    }
    flush();
    for (final (start, length, preview) in notes) {
      final w = length * stepW;
      if (w < 1) continue;
      canvas.save();
      canvas.translate(start * stepW, top);
      preview.paint(canvas, Size(w, h));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ClipBlocksPainter old) =>
      old.stepW != stepW || old.inset != inset || old.clips.length != clips.length ||
      [for (var i = 0; i < clips.length; i++) old.clips[i] != clips[i]].any((d) => d) ||
      old.notes.length != notes.length ||
      [for (var i = 0; i < notes.length; i++)
        old.notes[i].$1 != notes[i].$1 || old.notes[i].$2 != notes[i].$2 || !old.notes[i].$3.sameAs(notes[i].$3)]
          .any((d) => d);
}

/// The arrangement grid's step, in 16th steps: 1, a beat, a bar, or 4, 16, 64… bars, whichever keeps its lines at
/// least 5 px apart at [stepW] pixels a step.
int arrangeGridEvery(double stepW, int barSteps) {
  if (stepW >= 5) return 1;
  if (stepW * 4 >= 5) return 4;
  var every = barSteps;
  while (every * stepW < 5 && every < (1 << 40)) {
    every *= 4;
  }
  return every;
}

class _ArrangementGrid extends CustomPainter {
  _ArrangementGrid(this.stepW, this.bars, this.scroll) : super(repaint: scroll);
  final double stepW;
  final BarMath bars;
  final ScrollController scroll;
  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()..color = Neon.line.withValues(alpha: .55)..strokeWidth = .6;
    final major = Paint()..color = Neon.dim.withValues(alpha: .35)..strokeWidth = 1;
    final (from, to) = visibleSpan(scroll, size);
    final first = bars.signatures.first;
    if (bars.constant && first.den == 4) {
      // One n/4 all through: zoomed out, the minor lines thin to beats, then to bars, then every 4, 16, 64… bars,
      // so they stay at least 5 px apart and nothing is drawn per bar however far out (owner, 2026-11-11).
      // The next finer lines fade in from 3.75 to 5 px apart (eased, so they don't hatch the lanes on the way), so a
      // zoom never pops a level of lines in or out.
      final barSteps = first.num * 4;
      final every = arrangeGridEvery(stepW, barSteps);
      final finer = every == 1 ? 0 : every == 4 ? 1 : every == barSteps ? 4 : every ~/ 4;
      final ease = finer > 0 ? zoomFade(finer * stepW, 5, from: 0.75) : 0.0;
      final fade = ease * ease;
      final step = fade > 0 ? finer : every;
      final faintMinor = Paint()..color = Neon.line.withValues(alpha: .55 * fade)..strokeWidth = .6;
      final faintMajor = Paint()..color = Neon.dim.withValues(alpha: .35 * fade)..strokeWidth = 1;
      for (var n = (from / stepW / step).floor() * step; n * stepW <= to; n += step) {
        final x = n * stepW;
        final bar = n % barSteps == 0;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height),
            n % every == 0 ? (bar ? major : minor) : (bar ? faintMajor : faintMinor));
      }
      return;
    }
    // The bars follow the signatures (#207): a major line at each bar, minor ones at its steps, or at its own beats
    // (eighths in 6/8) when steps crowd, none inside a bar narrower than 20 px, and every 4, 16… bars further out.
    var barW = double.infinity;
    for (final b in bars.bars(from / stepW / 4, to / stepW / 4, limit: 64)) {
      barW = math.min(barW, b.length * 4 * stepW);
    }
    if (!barW.isFinite) return;
    var every = 1;
    while (every * barW < 5 && every < 1 << 30) {
      every *= 4;
    }
    for (final b in bars.bars(from / stepW / 4, to / stepW / 4, every: every, limit: 2048)) {
      final x0 = b.beat * 4 * stepW;
      canvas.drawLine(Offset(x0, 0), Offset(x0, size.height), major);
      if (every > 1) continue;
      final unit = 4 / bars.signatureOfBar(b.bar).den * 4;  // steps in one of the signature's beats
      final inner = stepW >= 5 ? 1.0 : unit * stepW >= 5 ? unit : 0.0;
      if (inner <= 0) continue;
      for (var t = inner; t < b.length * 4 - 1e-9; t += inner) {
        final x = x0 + t * stepW;
        if (x > to) break;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), minor);
      }
    }
  }
  @override
  bool shouldRepaint(covariant _ArrangementGrid old) =>
      old.stepW != stepW || old.bars != bars || old.scroll != scroll;
}

class _BarRuler extends CustomPainter {
  _BarRuler(this.stepW, this.bars, this.scroll) : super(repaint: scroll);
  final double stepW;
  final BarMath bars;
  final ScrollController scroll;
  @override
  void paint(Canvas canvas, Size size) {
    final (from, to) = visibleSpan(scroll, size);
    paintBarNumbers(canvas, bars, stepW, from, to, (x, label, room, _) {
      label.layout(maxWidth: math.max(1.0, room - 2));
      label.paint(canvas, Offset(x, (size.height - label.height) / 2));
    });
  }
  @override
  bool shouldRepaint(covariant _BarRuler old) => old.stepW != stepW || old.bars != bars || old.scroll != scroll;
}

class _PlayheadPainter extends CustomPainter {
  const _PlayheadPainter(this.stepW, this.step, {this.stopped = false});
  final double stepW, step;
  final bool stopped;

  @override
  void paint(Canvas canvas, Size size) {
    if (step < 0) return;
    final x = step * stepW;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height),
      Paint()..color = stopped ? Neon.blue.withValues(alpha: 0.45) : Neon.blue..strokeWidth = stopped ? 1.2 : 1.6);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter old) => old.step != step || old.stepW != stepW || old.stopped != stopped;
}

/// The marquee box being drawn around clips.
class _MarqueePainter extends CustomPainter {
  const _MarqueePainter(this.box);
  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(box, Paint()..color = Neon.blue.withValues(alpha: 0.12));
    canvas.drawRect(box, Paint()..color = Neon.blue.withValues(alpha: 0.8)..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter old) => old.box != box;
}
