// Arrange's clip on the timeline: its moves, trims and hold menu, and the ghost that follows a drag.
part of '../arranger_screen.dart';

class _TimelineClip extends StatefulWidget {
  const _TimelineClip({required this.state, required this.layer, required this.clip,
    required this.zoom, required this.color, required this.selected, required this.callbacks, this.drag,
    this.height = 60});
  final AppState state;
  final LayerDoc layer;
  final ClipDoc clip;
  final double height;

  /// Pixels per step: the clip reads it as it changes, so a zoom lays it out again without building it.
  final ValueListenable<double> zoom;
  final Color color;
  final bool selected;
  final _TrackCallbacks callbacks;
  final ArrangeDrag? drag;
  @override
  State<_TimelineClip> createState() => _TimelineClipState();
}

/// What a dragged clip's ghost shows: where it lands, in its target's colour, and whether it is a copy.
typedef _Ghost = ({Rect rect, Rect clip, Color color, bool copy});

class _TimelineClipState extends State<_TimelineClip> {
  double get _stepW => widget.zoom.value;
  double dx = 0, resizeDx = 0, trimDx = 0;
  (bool, bool) _tapKeys = (false, false);
  final _clicks = ClickCounter();
  bool dragging = false, resizing = false, trimming = false, sourceDragging = false;
  int? _lastSnap;

  // A body drag (REAPER: drag an item to move it, to another track too; Ctrl-drag copies it).
  Offset _from = Offset.zero, _pointer = Offset.zero;
  double _scroll0 = 0;
  bool _ignored = false;

  /// The drag began with a long press (owner, 2026-11-11): the clip is picked up whole, edges included, and a
  /// resting second finger frees it from the grid.
  bool _lifted = false;
  OverlayEntry? _ghost;
  final _ghostState = ValueNotifier<_Ghost?>(null);

  int get _snap => widget.state.arrangementSnapSteps;
  bool get _free => HardwareKeyboard.instance.isShiftPressed || (_lifted && (_drag?.free.value ?? false));
  ArrangeDrag? get _drag => widget.drag;
  bool get _copy => HardwareKeyboard.instance.isControlPressed || (_drag?.copy.value ?? false);
  double get _scrolled {
    final h = _drag?.hScroll;
    return h == null || !h.hasClients ? 0 : h.positions.last.pixels - _scroll0;
  }

  /// Where a move ends, in steps: on the grid unless Shift is held.
  int _moveTarget() {
    final raw = ((dx + _scrolled) / _stepW).round();
    if (sourceDragging) return _free ? raw : (raw / _snap).round() * _snap;
    final rawStart = widget.clip.startSteps + raw;
    final at = _free ? rawStart : (rawStart / _snap).round() * _snap;
    // Never before the project's start (nor past its end).
    return at.clamp(0, math.max(0, widget.state.project.maxArrangementSteps - widget.clip.lengthSteps)).toInt();
  }

  /// Where a left-edge trim puts the clip's start.
  int _trimTarget() {
    final raw = widget.clip.startSteps + (trimDx / _stepW).round();
    return _free ? raw : (raw / _snap).round() * _snap;
  }

  /// A light tick each time the clip lands on another grid line (owner: haptics on grid snaps).
  void _tickOnSnap(int at) {
    if (_lastSnap != null && _lastSnap != at) Motion.tick();
    _lastSnap = at;
  }

  /// A finger's hold (owner, 2026-11-12): held still it opens the clip menu, moved it picks the clip up.
  final _hold = HoldToMove();

  /// The last pointer down on the clip (its body or an edge): the finger a hold follows.
  int _downPointer = 0;

  @override
  void dispose() {
    _hold.stop();
    _removeGhost();
    _ghostState.dispose();
    super.dispose();
  }

  void _removeGhost() {
    _ghost?.remove();
    _ghost = null;
  }

  void _start(DragStartDetails d) => _begin(d.globalPosition);

  /// A hold opens the clip's menu (owner, 2026-11-12); moving past the touch slop closes it and picks the clip up
  /// whole, carried in time and across tracks from where the finger went down.
  void _lift(LongPressStartDetails d) {
    if ((_drag?.pinching ?? false) || dragging) return;
    _hold.start(_downPointer, d.globalPosition,
      begin: (from) {
        if (!mounted || widget.clip.lock) return;
        Motion.tick();
        _begin(from, lift: true);
      },
      move: (at) { if (_lifted) _moveTo(at); },
      end: (cancel) {
        if (!_lifted) return;
        cancel ? _cancel() : _end(null);
      });
    widget.callbacks.onClipMenu(widget.layer, widget.clip, d.globalPosition);
  }

  void _begin(Offset global, {bool lift = false}) {
    _ignored = (_drag?.pinching ?? false) || widget.clip.lock;
    if (_ignored) return;
    _lifted = lift;
    setState(() {
      dragging = true;
      sourceDragging = !lift && HardwareKeyboard.instance.isAltPressed;
      dx = 0;
      _lastSnap = null;
    });
    _from = _pointer = global;
    final h = _drag?.hScroll;
    _scroll0 = h == null || !h.hasClients ? 0 : h.positions.last.pixels;
    final drag = _drag;
    if (drag == null || sourceDragging) return;
    drag.begin(onScroll: _follow, onCancel: _cancel, lift: lift);
    drag.copy.addListener(_follow);
    drag.free.addListener(_follow);
    _ghost = OverlayEntry(builder: (_) => _GhostView(ghost: _ghostState, name: _name));
    Overlay.of(context).insert(_ghost!);
    _follow();
  }

  String get _name {
    final name = widget.state.clipName(widget.clip);
    final others = _together ? widget.state.selectedClipIds.length - 1 : 0;
    return others > 0 && dragging ? '$name +$others' : name;
  }

  /// This drag moves every selected clip (the grabbed one is among several selected), as REAPER moves a selection.
  bool get _together => widget.selected && widget.state.selectedClipIds.length > 1;

  void _update(DragUpdateDetails d) {
    if (_lifted) return;
    _moveTo(d.globalPosition);
  }

  void _moveTo(Offset global) {
    if (_ignored || !dragging) return;
    _pointer = global;
    dx = _pointer.dx - _from.dx;
    _drag?.point(_pointer);
    _follow();
  }

  /// Follows the pointer (and the view, while it scrolls at an edge): the lane under it, the snapped time, the ghost.
  void _follow() {
    if (!mounted || !dragging) return;
    final at = _moveTarget();
    _tickOnSnap(at);
    if (!sourceDragging) _showGuides(at);
    final drag = _drag;
    if (drag == null || sourceDragging) {
      setState(() {});
      return;
    }
    final spot = drag.spotAt(_pointer);
    drag.hover.value = spot;
    final lane = spot == null ? drag.laneRect(widget.layer.id)
        : spot.newTrack ? ArrangeDrag.rectOf(drag.newTrackLane) : drag.laneRect(spot.layerId!);
    final box = context.findRenderObject() as RenderBox?;
    final view = ArrangeDrag.rectOf(drag.hViewport);
    final vview = ArrangeDrag.rectOf(drag.vViewport);
    if (lane == null || box == null || view == null || vview == null) return;
    final target = spot?.layerId == null ? null
        : widget.state.project.layers.where((l) => l.id == spot!.layerId).firstOrNull;
    // As high in the target lane as the clip sits in its own.
    final own = drag.laneRect(widget.layer.id);
    final inset = own == null ? 4.0 : box.localToGlobal(Offset.zero).dy - own.top;
    _ghostState.value = (
      rect: Rect.fromLTWH(lane.left + at * _stepW, lane.top + (spot?.newTrack ?? false ? 4 : inset),
          box.size.width, box.size.height),
      clip: view.intersect(vview),
      color: spot?.newTrack ?? false ? Neon.green : target == null ? widget.color : trackColor(widget.state, target),
      copy: _copy,
    );
    setState(() {});
  }

  void _end(DragEndDetails? _) {
    if (_ignored || !dragging) return;
    final c = widget.clip;
    final at = _moveTarget();
    final drag = _drag;
    final spot0 = drag?.hover.value;
    final stays = !sourceDragging && !_copy && at == c.startSteps &&
        (spot0 == null || (!spot0.newTrack && spot0.layerId == widget.layer.id));
    // Put down where it was picked up: nothing changes. Otherwise the move is one undo step of its own.
    if (stays) return _finish();
    widget.state.endUndoStep();
    if (sourceDragging) {
      widget.state.shiftClipSource(widget.layer, c, at);
    } else if (drag == null) {
      directClipEdits.add(c.id); // the pinned track's clip already slid there
      widget.state.moveClip(widget.layer, c, at);
    } else {
      final spot = drag.hover.value;
      final copy = _copy;
      final target = spot == null || spot.newTrack ? null
          : widget.state.project.layers.where((l) => l.id == spot.layerId).firstOrNull;
      if (_together) {
        // Several selected clips move (or copy) together, by the same time and number of tracks.
        widget.state.moveSelectedClips(widget.layer, c, spot == null || spot.newTrack ? widget.layer : target, at,
          copy: copy);
      } else if (spot == null || (!spot.newTrack && target == null)) {
        widget.state.moveClip(widget.layer, c, at);
      } else {
        widget.state.moveClipTo(widget.layer, c, target, at, copy: copy);
      }
    }
    widget.state.endUndoStep();
    _finish();
  }

  /// Escape (or a cancelled gesture): the clip stays where it was.
  void _cancel() => _finish();

  /// The guides for a move to [at] (owner, 2026-11-12): the clip's start and end there, or with several selected
  /// clips moving together, the selection's first start and last end, moved by as much.
  void _showGuides(int at) {
    final c = widget.clip;
    var start = at, end = at + c.lengthSteps;
    if (_together) {
      final by = at - c.startSteps;
      final sel = widget.state.selectedClips;
      if (sel.isNotEmpty) {
        start = sel.map((x) => x.clip.startSteps).reduce(math.min) + by;
        end = sel.map((x) => x.clip.startSteps + x.clip.lengthSteps).reduce(math.max) + by;
      }
    }
    widget.callbacks.guides.value = ClipGuide(start.toDouble(), end.toDouble(), widget.color);
  }

  /// The guides while an edge trims: where the clip starts and ends as it would land.
  void _trimGuides() {
    final c = widget.clip;
    final start = trimming ? _trimStart() : c.startSteps;
    final end = trimming ? c.startSteps + c.lengthSteps : c.startSteps + _resizedLength();
    widget.callbacks.guides.value = ClipGuide(start.toDouble(), end.toDouble(), widget.color);
  }

  void _clearGuides() => widget.callbacks.guides.value = null;

  void _finish() {
    _removeGhost();
    _ghostState.value = null;
    _clearGuides();
    _drag?.copy.removeListener(_follow);
    _drag?.free.removeListener(_follow);
    if (dragging && !sourceDragging) _drag?.end();
    _lifted = false;
    if (mounted) setState(() { dragging = false; sourceDragging = false; dx = 0; _lastSnap = null; });
    _ignored = true; // the rest of this gesture does nothing
  }

  Widget _edge({required bool left}) => Positioned(left: left ? 0 : null, right: left ? null : 0, top: 0, bottom: 0,
    width: 12,
    child: widget.clip.lock ? const SizedBox.shrink() : MouseRegion(cursor: SystemMouseCursors.resizeColumn, child: GestureDetector(behavior: HitTestBehavior.opaque,
      // The edge follows the finger from where it went down, slop included.
      dragStartBehavior: DragStartBehavior.down,
      // A long press on an edge picks the whole clip up too: it never stretches.
      onLongPressStart: _lift,
      onHorizontalDragStart: (_) {
        setState(() {
          if (left) { trimming = true; trimDx = 0; } else { resizing = true; resizeDx = 0; }
          _lastSnap = null;
        });
        _trimGuides();
      },
      onHorizontalDragUpdate: (d) {
        setState(() {
          final c = widget.clip;
          if (left) {
            trimDx += d.delta.dx;
            _tickOnSnap(_trimTarget());
          } else {
            resizeDx += d.delta.dx;
            final raw = c.lengthSteps + (resizeDx / _stepW).round();
            _tickOnSnap(_free ? raw : (raw / _snap).round() * _snap);
          }
        });
        _trimGuides();
      },
      onHorizontalDragCancel: () {
        _clearGuides();
        if (mounted) setState(() { resizing = trimming = false; resizeDx = trimDx = 0; _lastSnap = null; });
      },
      onHorizontalDragEnd: (_) {
        _clearGuides();
        directClipEdits.add(widget.clip.id); // drawn at its new size already: no glide
        if (left) {
          widget.state.trimClipStart(widget.layer, widget.clip, _trimTarget());
        } else {
          widget.state.resizeClip(widget.layer, widget.clip, _resizedLength());
        }
        setState(() { resizing = trimming = false; resizeDx = trimDx = 0; _lastSnap = null; });
      },
      child: Center(child: Container(key: ValueKey('clip-${left ? 'start' : 'end'}-${widget.clip.id}'),
        width: 2, height: 22, color: widget.color)))));

  /// Where a left-edge trim shows the clip starting (kept inside its notes and before its end).
  int _trimStart() {
    final c = widget.clip;
    final end = c.startSteps + c.lengthSteps;
    return _trimTarget().clamp(math.max(0, c.startSteps - c.sourceOffsetSteps), end - 1).toInt();
  }

  int _resizedLength() {
    final c = widget.clip;
    final rawLength = c.lengthSteps + (resizing ? (resizeDx / _stepW).round() : 0);
    return (resizing && !_free ? math.max(_snap, (rawLength / _snap).round() * _snap) : rawLength)
        .clamp(1, widget.state.project.maxArrangementSteps - c.startSteps).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    var start = c.startSteps, length = _resizedLength();
    if (trimming) {
      start = _trimStart();
      length = c.startSteps + c.lengthSteps - start;
    }
    final name = _name;
    // The notes sit under the name when the clip is tall enough for both, else they fill it.
    MidiClipPreview? previewAt(double stepW) => MidiClipPreview.of(widget.state.project, c, stepW: stepW,
      trim: start - c.startSteps, drums: widget.layer.instrument?.id == drumsComponentId,
      top: widget.height >= 34 ? 15 : 1, color: Color.lerp(widget.color, Neon.ink, 0.45)!.withValues(alpha: 0.9));
    final preview = previewAt(_stepW);
    // What depends on the zoom reads it where it is used, so a zoom builds those few widgets and lays out the rest.
    Widget zoomed(Widget Function(double stepW) build) =>
        ValueListenableBuilder<double>(valueListenable: widget.zoom, builder: (context, w, _) => build(w));
    final ghosted = dragging && !sourceDragging && _drag != null && !_copy;
    // The body drags in any direction from the first few pixels, before the scroll views take the gesture.
    final mq = MediaQuery.of(context);
    return Opacity(opacity: ghosted ? 0.35 : c.mute ? 0.45 : 1,
      child: ValueListenableBuilder<double>(valueListenable: widget.zoom, builder: (context, stepW, body) {
        // On the pinned track the clip itself slides in time; elsewhere its ghost shows where it goes and it stays dim.
        final shown = dragging && !sourceDragging && _drag == null ? (_moveTarget() - c.startSteps) * stepW : 0.0;
        return Transform.translate(offset: Offset(shown + (start - c.startSteps) * stepW, 0),
          // An edge drag changes the clip's width, never its content's scale (owner, 2026-11-11, as REAPER): longer
          // shows more (the next repeats, or nothing), shorter crops, and a left trim keeps the notes where they are.
          child: OverflowBox(key: ValueKey('clip-body-${c.id}'), alignment: Alignment.centerLeft,
            minWidth: math.max(12.0, length * stepW), maxWidth: math.max(12.0, length * stepW), child: body));
      },
        child: Listener(onPointerDown: (e) => _downPointer = e.pointer,
          child: Material(color: ClipLook.under(widget.color, widget.selected), // the theme's clip fill and corners
          borderRadius: BorderRadius.circular(ClipLook.radius(widget.height)),
          child: Stack(children: [
        Positioned.fill(child: MediaQuery(
          data: mq.copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: kTouchSlop / 2)),
          // The modifiers count as they were when the click went down.
          child: Listener(onPointerDown: (e) {
            _tapKeys = (HardwareKeyboard.instance.isControlPressed, HardwareKeyboard.instance.isShiftPressed);
            _clicks.down(e);
          },
          onPointerUp: _clicks.up,
          // A tap or click only selects; a double tap or double-click opens the clip's editor, its notes in the
          // piano roll (owner, 2026-11-12). A hold opens the menu, as a right-click does; a hold that moves, or a drag,
          // moves the clip. No double tap in the gesture arena holds the first tap back.
          child: MouseRegion(cursor: SystemMouseCursors.grab, child: GestureDetector(
          key: ValueKey('clip-${c.id}'),
          onLongPressStart: _lift,
          onSecondaryTapUp: (d) => widget.callbacks.onClipMenu(widget.layer, c, d.globalPosition),
          onTap: () {
            if (_clicks.twice) return widget.callbacks.onClipOpen(widget.layer, c);
            final (ctrl, shift) = _tapKeys;
            // REAPER (UG 7.2.1): Ctrl-click adds or removes a clip, Shift-click selects the range to it. A tap in
            // Select mode adds or removes it, the phone's way.
            if (ctrl || widget.callbacks.selectMode()) {
              widget.state.toggleClipSelection(widget.layer, c);
            } else if (shift) {
              widget.state.selectClipRange(widget.layer, c);
            } else {
              widget.state.selectClip(widget.layer, c);
            }
          },
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: _start,
          onPanUpdate: _update,
          onPanEnd: _end,
          onPanCancel: () { if (dragging && !_lifted) _cancel(); },
          child: Container(
            // Glass: a faint fill that is lighter at the top, and a solid outline in the track's colour; the
            // selected clip glows in that colour, brighter.
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(ClipLook.radius(widget.height)),
              gradient: ClipLook.gradient(widget.color, widget.selected),
              boxShadow: widget.selected ? [BoxShadow(color: widget.color.withValues(alpha: .35), blurRadius: 8)] : null,
              border: Border.all(
                color: Glass.active || widget.selected ? widget.color : widget.color.withValues(alpha: .7),
                width: widget.selected ? 1.6 : 1)),
            // A compact row's clip has room for its name only.
            padding: widget.height < 26 ? const EdgeInsets.fromLTRB(13, 1, 13, 0) : const EdgeInsets.fromLTRB(13, 4, 13, 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: widget.color, fontSize: 10, fontWeight: FontWeight.w800)),
              if (widget.height >= 26) Expanded(child: Align(alignment: Alignment.bottomLeft,
                child: Row(children: [
                  if (c.lock) Icon(Icons.lock, key: ValueKey('clip-locked-${c.id}'), size: 9, color: widget.color),
                  if (c.mute) Icon(Icons.volume_off, key: ValueKey('clip-muted-${c.id}'), size: 9, color: widget.color),
                  if (preview == null) Flexible(child: Text(c.loop ? 'MIDI · LOOP' : 'MIDI', maxLines: 1,
                    overflow: TextOverflow.clip, style: TextStyle(color: widget.color.withValues(alpha: .8), fontSize: 8))),
                ]))),
            ]),
          ),
        ))))),
        // The clip's notes as a mini piano roll (REAPER), from a cached picture of its pattern; under the edges.
        if (preview != null) Positioned.fill(child: IgnorePointer(child: RepaintBoundary(child: zoomed((stepW) =>
          CustomPaint(key: ValueKey('clip-preview-${c.id}'), painter: ClipPreviewPainter(previewAt(stepW) ?? preview)))))),
        // A comp (#209): its joins marked where the parts meet (every pass of the loop).
        if (c.comp.isNotEmpty) Positioned.fill(child: IgnorePointer(child: zoomed((stepW) => CustomPaint(
          key: ValueKey('clip-comp-joins-${c.id}'),
          painter: CompJoinsPainter([for (final j in TakeClip.midi(c).joins(widget.state.project))
            (j - c.startSteps) * stepW], widget.color))))),
        // Loop-recorded takes: ‹ n/N › steps through them, a swipe across it too, a tap on the count lists them.
        if (c.takes.length > 1 && widget.height >= 26) zoomed((stepW) => c.lengthSteps * stepW >= 86
          ? Positioned(top: 2, right: 14, child: TakeChip(state: widget.state, layer: widget.layer, clip: c,
              color: widget.color))
          : const SizedBox.shrink()),
        // Both edges trim (REAPER: drag an item's edge): the left one moves the start and keeps the notes in time.
        _edge(left: true),
        _edge(left: false),
          ]),
        ))),
    );
  }
}

/// A dragged clip's ghost, drawn over the tracks (inside their view) where the clip would land, with + for a copy.
class _GhostView extends StatelessWidget {
  const _GhostView({required this.ghost, required this.name});
  final ValueNotifier<_Ghost?> ghost;
  final String name;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_Ghost?>(
    valueListenable: ghost,
    builder: (context, g, _) {
      if (g == null) return const SizedBox.shrink();
      return Positioned.fromRect(rect: g.clip, child: IgnorePointer(child: ClipRect(child: Stack(children: [
        Positioned(left: g.rect.left - g.clip.left, top: g.rect.top - g.clip.top, width: g.rect.width,
          height: g.rect.height, child: Container(
            key: const ValueKey('clip-drag-ghost'),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5),
              color: g.color.withValues(alpha: 0.30),
              border: Border.all(color: g.color, width: 1.6),
              boxShadow: [BoxShadow(color: g.color.withValues(alpha: 0.35), blurRadius: 10)]),
            padding: const EdgeInsets.fromLTRB(7, 4, 6, 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: g.color, fontSize: 10, fontWeight: FontWeight.w800, decoration: TextDecoration.none))),
              if (g.copy) Icon(Icons.add_circle, key: const ValueKey('clip-drag-copy'), size: 14, color: g.color),
            ]))),
      ]))));
    });
}
