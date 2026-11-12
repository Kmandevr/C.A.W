// Arrange: the tracks and clips on a timeline, compact track headers, the focus view (one track and its panel) and the mixer card.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../model/app_state.dart';
import '../model/arrange_edit.dart';
import '../model/audio_edit.dart';
import '../model/arrange_fx.dart';
import '../model/arrange_markers.dart';
import '../model/clip_automation.dart';
import '../model/clip_loop_edit.dart';
import '../model/live_midi.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import '../model/record_modes.dart';
import '../model/settings.dart';
import 'pointer_input.dart';
import 'arrange/audio_clip_view.dart';
import 'arrange/audio_input_ui.dart';
import 'audio_file_actions.dart';
import 'arrange/arrange_drag.dart';
import 'arrange/region_list.dart';
import 'arrange/take_chip.dart';
import 'arrange/templates_ui.dart';
import 'arrange/clip_bar.dart';
import 'arrange/clip_look.dart';
import 'arrange/clip_preview.dart';
import 'arrange/ruler.dart';
import 'arrange/focus_panel.dart';
import 'arrange/edit_motion.dart';
import 'arrange/fx_stack.dart';
import 'arrange/long_press_menu.dart';
import 'arrange/mixer_card.dart';
import 'follow_gate.dart';
import 'live_playhead.dart';
import 'frame/sections.dart';
import 'presence.dart';
import 'view_glide.dart';
import 'feedback.dart' show GrabFeedback, GripMark, Pressable;
import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';
import 'arrange/track_color.dart';
import 'arrange/track_lanes.dart';
import 'file_manager_screen.dart';
import 'frame/frame_widgets.dart';
import 'frame/record_tools.dart' show showTakePicker;
import 'widgets.dart';
import 'volume_fader.dart';
import 'track_cards_screen.dart';
import 'glass.dart';
import 'key_router.dart';
import 'midi_file_actions.dart';


/// Where the focus view's panel goes: under a pinned track (phone portrait) or beside the tracks.
enum FocusLayout { pinned, side }

/// Phone portrait pins the track; landscape (wider than tall) and desktops (900 dp and up) use a side panel.
FocusLayout focusLayoutFor(Size screen) =>
    screen.width < 900 && screen.height >= screen.width ? FocusLayout.pinned : FocusLayout.side;

class ArrangerScreen extends StatefulWidget {
  const ArrangerScreen({super.key, required this.state, this.onOpenPattern, this.onOpenModule});
  final AppState state;
  final VoidCallback? onOpenPattern;
  final ValueChanged<String>? onOpenModule;
  @override
  State<ArrangerScreen> createState() => _ArrangerScreenState();
}

class _ArrangerScreenState extends State<ArrangerScreen> with TickerProviderStateMixin {
  bool settings = false, cardsView = false, mixerCard = false, zoomBar = false;
  final _headerTaps = ClickCounter();

  /// Phone portrait: the focus panel opened up over the pinned track (owner, 2026-11-10: it can open higher).
  bool _panelHigh = false;

  /// The Files browser beside (or under) the tracks, so files can be dragged onto a track or into the FX stack
  /// without leaving Arrange (owner, 2026-11-10).
  bool _browser = false;
  bool _browserWas = false, _browserLeaving = false;
  Timer? _browserTimer;

  /// Time zoom: pixels per 16th step (× 0.85 at compact density).
  double zoom = 18.0;
  /// Zoomed all the way out a multi-hour song fits a phone (owner, 2026-11-11: REAPER zooms out "a metric ton").
  static const minZoom = 0.002, maxZoom = 64.0;

  /// Moves the view makes on its own glide (owner, 2026-11-11); a touch stops them. See [_animateViewTo].
  late final ViewGlide _glide = ViewGlide(this, read: _viewPlace, apply: _applyView);

  double get _zoomScale => Neon.compact(context) ? 0.85 : 1.0;

  ViewPlace _viewPlace() {
    final p = _hScroll.hasClients ? _hScroll.positions.last : null;
    return (left: p == null ? 0.0 : p.pixels / _stepW, zoom: _stepW);
  }

  void _applyView(ViewPlace v) {
    final z = (v.zoom / _zoomScale).clamp(minZoom, maxZoom).toDouble();
    if ((z - zoom).abs() < 1e-9) {
      if (!_hScroll.hasClients) return;
      final p = _hScroll.positions.last;
      p.jumpTo((v.left * _stepW).clamp(0.0, p.maxScrollExtent).toDouble());
      return;
    }
    _setZoom(z, leftStep: math.max(0.0, v.left));
  }

  /// The one way the view moves on its own (owner, 2026-11-11): its left edge to [leftStep] (steps) and its zoom to
  /// [zoom], together, in a glide of 150–350 ms by distance that a new move retargets and a touch stops; at once with
  /// motion off. Without [leftStep], [keep] (pixels from the lanes' left edge; the middle by default) stays put.
  void _animateViewTo({double? leftStep, double? zoom, double? keep}) {
    if (!_hScroll.hasClients) return;
    final view = _hScroll.positions.last.viewportDimension;
    _glide.to(left: leftStep == null ? null : math.max(0.0, leftStep),
        zoom: zoom == null ? null : zoom.clamp(minZoom, maxZoom).toDouble() * _zoomScale,
        keep: keep ?? view / 2, view: view, level: Motion.of(context));
  }

  /// The tracks' up-and-down glide, the same helper at a fixed zoom (left is pixels).
  late final ViewGlide _vGlide = ViewGlide(this,
      read: () => (left: _drag.vScroll.hasClients ? _drag.vScroll.positions.last.pixels : 0.0, zoom: 1.0),
      apply: (v) {
        if (!_drag.vScroll.hasClients) return;
        final p = _drag.vScroll.positions.last;
        p.jumpTo(v.left.clamp(0.0, p.maxScrollExtent).toDouble());
      });

  /// Glides the tracks up or down so [layerId]'s row shows, when it is out of the view (a track picked with the
  /// keyboard, or focused and pinned).
  void _revealTrack(String layerId) {
    final row = ArrangeDrag.rectOf(_drag.headerKey(layerId)), view = ArrangeDrag.rectOf(_drag.vViewport);
    if (row == null || view == null || !_drag.vScroll.hasClients) return;
    final p = _drag.vScroll.positions.last;
    double? to;
    if (row.top < view.top) to = p.pixels - (view.top - row.top) - 8;
    if (row.bottom > view.bottom) to = p.pixels + (row.bottom - view.bottom) + 8;
    if (to == null) return;
    _vGlide.to(left: to, view: view.height, level: Motion.of(context));
  }

  // What was selected at the last build: a change the view can't see (the keyboard, a paste) glides it into view.
  String? _selLayerSeen;
  Set<String> _selClipsSeen = const {};

  void _revealSelection() {
    final s = widget.state;
    final layer = s.selectedLayerId, clips = s.selectedClipIds.toSet();
    final layerMoved = layer != _selLayerSeen && _selLayerSeen != null;
    final added = clips.difference(_selClipsSeen);
    _selLayerSeen = layer;
    _selClipsSeen = clips;
    if (!layerMoved && added.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (layerMoved && layer != null) _revealTrack(layer);
      if (added.isEmpty || !_hScroll.hasClients) return;
      final picked = [for (final c in s.selectedClips) if (added.contains(c.clip.id)) c];
      if (picked.isEmpty) return;
      final a = picked.map((c) => c.clip.startSteps.toDouble()).reduce(math.min);
      final b = picked.map((c) => (c.clip.startSteps + c.clip.lengthSteps).toDouble()).reduce(math.max);
      final p = _hScroll.positions.last;
      final l = p.pixels / _stepW, r = (p.pixels + p.viewportDimension) / _stepW;
      // Only when none of it shows: a clip tapped at the view's edge stays where it is.
      if (b < l || a > r) _revealRange(a, b);
    });
  }

  /// The zoom the view is at or gliding to.
  double get _zoomAim => _glide.target.zoom / _zoomScale;

  /// The view reached this far right (steps): the timeline keeps going a few screens past it, past the last clip
  /// and the playhead, so scrolling right never meets a wall (owner, 2026-11-11). Scrolling doesn't change the song.
  double _reachSteps = 0;

  void _onHScroll() {
    if (!_hScroll.hasClients) return;
    final p = _hScroll.positions.last;
    if (!p.hasContentDimensions || p.pixels + p.viewportDimension * 2 < p.maxScrollExtent) return;
    final reach = (p.pixels + p.viewportDimension) / _stepW;
    if (reach > _reachSteps + 1) setState(() => _reachSteps = reach);
  }

  /// Glides the view so [step] shows, a tenth in, when it is off screen (a jump to a marker).
  void _reveal(double step) {
    if (!_hScroll.hasClients) return;
    final p = _hScroll.positions.last;
    final x = step * _stepW;
    if (x >= p.pixels && x <= p.pixels + p.viewportDimension - 24) return;
    _animateViewTo(leftStep: step - p.viewportDimension * 0.1 / _stepW);
  }

  /// Glides the view so steps [from]..[to] show: as it is when they do, else panned there, zoomed out to fit them
  /// when they are wider than the view (go to a clip, zoom to the selection with [fit]).
  void _revealRange(double from, double to, {bool fit = false}) {
    if (!_hScroll.hasClients) return;
    final p = _hScroll.positions.last;
    final view = p.viewportDimension;
    if (view <= 0) return;
    final span = math.max(1.0, to - from);
    if (fit || span * _stepW > view * 0.9) {
      final z = (view * 0.9 / span / _zoomScale).clamp(minZoom, maxZoom).toDouble();
      final z2 = fit ? z : math.min(zoom, z);
      _animateViewTo(leftStep: from - view * 0.05 / (z2 * _zoomScale), zoom: z2);
      return;
    }
    final l = p.pixels / _stepW, r = (p.pixels + view) / _stepW;
    if (from >= l && to <= r) return;
    _animateViewTo(leftStep: from < l ? from - view * 0.1 / _stepW : to - view * 0.9 / _stepW);
  }

  /// Glides the view back to the request's step (⏮: [AppState.requestRevealStart], or Show the start): always for a
  /// double tap, else only when that step is off screen.
  void _revealStart() {
    final req = widget.state.revealStartRequests.value;
    final step = req?.step ?? 0;
    if (req != null && !req.always && _hScroll.hasClients) {
      final p = _hScroll.positions.last;
      final l = p.pixels / _stepW, r = (p.pixels + p.viewportDimension) / _stepW;
      if (step >= l && step <= r) return;
    }
    _animateViewTo(leftStep: step <= 0 ? 0 : step - _startMargin);
  }

  /// Steps left of a revealed start that is not the project's start, so it sits a little in from the edge.
  double get _startMargin => _hScroll.hasClients ? _hScroll.positions.last.viewportDimension * 0.05 / _stepW : 0;

  /// Zoom to fit: the whole song in the view, from its start.
  void _zoomToFit() {
    if (!_hScroll.hasClients) return;
    final p = _hScroll.positions.last;
    final end = math.max(widget.state.project.stepsPerBar, widget.state.project.engineLoopSteps);
    final z = (p.viewportDimension * 0.95 / end / _zoomScale).clamp(minZoom, maxZoom).toDouble();
    _animateViewTo(leftStep: 0, zoom: z);
  }

  /// Zoom to the selection: the selected clips, else the time selection, fill the view.
  bool _zoomToSelection() {
    final s = widget.state;
    final clips = s.selectedClips.toList();
    double? a, b;
    if (clips.isNotEmpty) {
      a = clips.map((c) => c.clip.startSteps.toDouble()).reduce(math.min);
      b = clips.map((c) => (c.clip.startSteps + c.clip.lengthSteps).toDouble()).reduce(math.max);
    } else if (s.timeSelectionStart != null && s.timeSelectionEnd != null && s.timeSelectionStart != s.timeSelectionEnd) {
      a = math.min(s.timeSelectionStart!, s.timeSelectionEnd!).toDouble();
      b = math.max(s.timeSelectionStart!, s.timeSelectionEnd!).toDouble();
    }
    if (a == null || b == null) return false;
    _revealRange(a, b, fit: true);
    return true;
  }

  // A pinch, the slider or Ctrl + wheel follow at once; the zoom buttons glide ([_animateViewTo]).

  // Two fingers on the timeline: a sideways pinch zooms time, an up-and-down pinch the track height.
  final Map<int, Offset> _touches = {};
  double _pinchDx0 = 0, _pinchDy0 = 0, _pinchZoom0 = 0, _pinchH0 = 0;
  // A time pinch draws the lanes laid out at the zoom it started from, scaled sideways by [_pinchScale] (beta plan
  // B4.9): no clip lays out or repaints while the fingers move. With [_pinchAt], the scroll position a layout per
  // move would have reached (the view's own scrolling, [_pinchSeen] on, added in), it is exactly the view a layout
  // per move would show; the lanes lay out once at that zoom when the pinch ends, or when the scale passes
  // [_pinchRebase]. [_pinchJump]: a rebase's scroll to [_pinchAt] is still to come (after its frame).
  final _pinchView = ValueNotifier<Matrix4?>(null);
  double _pinchScale = 1, _pinchAt = 0, _pinchSeen = 0;
  bool _pinchJump = false;
  static const _pinchRebase = (0.6, 1.6);
  bool _pinchX = false, _pinchY = false;
  // The touches' global positions, and the track whose header a vertical pinch resizes (null: every track's).
  final Map<int, Offset> _touchesAt = {};
  String? _pinchRow;

  /// The track whose header is under [global], if any.
  LayerDoc? _headerAt(Offset global) {
    for (final l in widget.state.visibleLayers) {
      final r = ArrangeDrag.rectOf(_drag.headerKey(l.id));
      if (r != null && r.contains(global)) return l;
    }
    return null;
  }
  // A header resize in progress, shown before it is saved when the drag ends.
  double? _dragHeaderW, _dragTrackH;

  bool get _phone => MediaQuery.sizeOf(context).shortestSide < 600;

  /// The track row height: dragged from a row's bottom edge or picked in the toolbar's height menu (saved).
  double get _trackHeight {
    final saved = widget.state.settings.trackHeight;
    return _dragTrackH ?? (saved > 0 ? saved : (_phone ? 60.0 : 76.0));
  }

  /// The track header width: dragged from the headers' right edge (saved).
  double get _headerWidth {
    final saved = widget.state.settings.headerWidth;
    return _dragHeaderW ?? (saved > 0 ? saved : (_phone ? 132.0 : 176.0));
  }

  void _saveHeaderSize() {
    final w = _dragHeaderW, h = _dragTrackH;
    if (w == null && h == null) return;
    widget.state.settings.update((x) {
      if (w != null) x.headerWidth = w;
      if (h != null) x.trackHeight = h;
    }).then((_) { if (mounted) setState(() { _dragHeaderW = null; _dragTrackH = null; }); });
  }
  /// A row's bottom-edge drag or vertical pinch in progress (owner, 2026-11-11): the track and its height as dragged,
  /// shown snapped through normal, compact and thin, and saved (one undo step) when it ends.
  String? _rowDragId;
  double _rowDragRaw = 0;

  static (TrackCollapse, double) rowSnap(double raw) => trackRowSnap(raw);

  /// [l]'s row height: its own or the default, compact or thin (thin inside a collapsed folder).
  double _rowHeight(LayerDoc l) {
    if (l.id == _rowDragId) return rowSnap(_rowDragRaw).$2;
    return switch (widget.state.shownCollapse(l)) {
      TrackCollapse.thin => LayerDoc.thinHeight,
      TrackCollapse.compact => LayerDoc.compactHeight,
      TrackCollapse.normal => l.height ?? _trackHeight,
    };
  }

  TrackCollapse _rowCollapse(LayerDoc l) => l.id == _rowDragId ? rowSnap(_rowDragRaw).$1 : widget.state.shownCollapse(l);

  /// A row's bottom edge moved by [dy]: this track's height, ticking as it snaps into another state. With Shift it is
  /// every track's default height instead, as the toolbar's height menu sets it.
  void _rowResize(LayerDoc l, double dy) {
    if (HardwareKeyboard.instance.isShiftPressed && _rowDragId == null) {
      setState(() => _dragTrackH = (_trackHeight + dy).clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble());
      return;
    }
    _rowResizeTo(l, (_rowDragId == l.id ? _rowDragRaw : _rowHeight(l)) + dy);
  }

  void _rowResizeTo(LayerDoc l, double raw) {
    final before = _rowCollapse(l);
    setState(() {
      _rowGen++;
      _rowDragId = l.id;
      _rowDragRaw = raw.clamp(0.0, LayerDoc.maxHeight).toDouble();
    });
    if (rowSnap(_rowDragRaw).$1 != before) Motion.tick();
  }

  /// Bumped as rows change height under the finger or finish gliding, so the rows below take their new places as
  /// they are instead of gliding there again (TrackRowMotion's epoch).
  int _rowGen = 0;
  final Map<String, bool> _lanesSeen = {};
  bool _settlePending = false;

  void _rowsSettled() {
    if (_settlePending) return;
    _settlePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settlePending = false;
      if (mounted) setState(() => _rowGen++);
    });
  }

  void _rowResizeEnd() {
    final id = _rowDragId;
    if (id == null) return _saveHeaderSize();
    final layer = widget.state.project.layers.where((l) => l.id == id).firstOrNull;
    final (collapse, h) = rowSnap(_rowDragRaw);
    setState(() => _rowDragId = null);
    if (layer != null) widget.state.setTrackCollapse([layer], collapse, height: collapse == TrackCollapse.normal ? h : null);
  }

  // The timeline can be millions of bars long (F7.2), so the ruler and grid paint only what this shows.
  final _hScroll = ScrollController();

  /// The focus without the app's sections (tests, the docking shell): kept here instead.
  String? _localFocus;
  FocusTab _tab = FocusTab.fx;

  /// Clip and track drags: what they point at, edge scrolling and Escape (REAPER-style, #172).
  late final ArrangeDrag _drag = ArrangeDrag()..hScroll = _hScroll;

  /// Select mode (the phone's multi-select, from the clip bar or a clip's "Select several"): a tap adds or removes a
  /// clip and a long-press drag in empty lane space draws a box around clips.
  bool _selectMode = false;

  /// A marquee in progress (REAPER's right-drag; a long-press drag in Select mode), in global coordinates, and
  /// whether it adds to the selection (Shift).
  final _marquee = ValueNotifier<Rect?>(null);
  Offset? _marqueeFrom;
  bool _marqueeAdd = false;
  final _lanesBox = GlobalKey(debugLabel: 'lanes');

  /// The timeline's step width and track height at the last build, for the marquee's hit test.
  double _stepW = 18;

  final _keys = FocusNode(debugLabel: 'arranger keys', skipTraversal: true);
  KeyRouterState? _router;

  // Bumped by every rebuild cause but a time zoom: the track headers, which don't depend on the zoom, are kept as
  // built while a pinch or a zoom glide rebuilds the lanes every frame (#174).
  int _headersRev = 0;

  @override
  void setState(VoidCallback fn) {
    _headersRev++;
    super.setState(fn);
  }

  @override
  void didUpdateWidget(covariant ArrangerScreen old) {
    super.didUpdateWidget(old);
    _headersRev++;
    if (!identical(old.state, widget.state)) {
      old.state.tick.removeListener(_followPlayhead);
      widget.state.tick.addListener(_followPlayhead);
      old.state.revealStartRequests.removeListener(_revealStart);
      widget.state.revealStartRequests.addListener(_revealStart);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.state.tick.addListener(_followPlayhead);
    widget.state.revealStartRequests.addListener(_revealStart);
    _hScroll.addListener(_onHScroll);
  }

  /// Settings › Editing › Follow the playhead: while playing, the view keeps the playhead in sight, paging on when it
  /// leaves the view (REAPER's continuous-scroll-off follow) or, Smooth, scrolling so it stays a third in. It never
  /// pulls the view while the user scrolls, zooms or drags, and waits [FollowGate]'s quiet spell after that or after
  /// the selection (clips, a time selection) changes (owner, 2026-11-11).
  late final FollowGate _follow = FollowGate(widget.state.settings);
  Object? _selectionSeen;

  /// The selection that pauses following when it changes: clips and the time selection, not the track.
  Object _selectionKey() {
    final s = widget.state;
    return Object.hash(s.timeSelectionStart, s.timeSelectionEnd, Object.hashAllUnordered(s.selectedClipIds));
  }

  void _followPlayhead() {
    final s = widget.state;
    final sel = _selectionKey();
    if (_selectionSeen != null && sel != _selectionSeen) _follow.touch();
    _selectionSeen = sel;
    if (!_follow.allows(playing: s.meters.playing) || !_hScroll.hasClients) return;
    if (_touches.isNotEmpty || _drag.active) return;
    final p = _hScroll.positions.last;
    final x = s.smoothPlayheadStep * _stepW;
    final view = p.viewportDimension;
    if (view <= 0) return;
    if (s.settings.followSmooth) {
      // The tracks glide under a still playhead: the scroll moves painted layers, nothing is built again.
      _glide.stop();
      final to = (x - view / 3).clamp(0.0, p.maxScrollExtent).toDouble();
      if ((to - p.pixels).abs() >= 0.5) p.jumpTo(to);
      return;
    }
    // A page step glides (owner, 2026-11-11); while it runs the playhead is already on its way into view.
    if (_glide.active) return;
    if (x >= p.pixels && x <= p.pixels + view - 24) return;
    _animateViewTo(leftStep: s.smoothPlayheadStep - view * 0.1 / _stepW);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _headersRev++;
    final r = KeyRouter.of(context);
    if (r == _router) return;
    _router?.unregister(Area.arranger, _keys);
    _router = r?..register(Area.arranger, _keys, _action);
  }

  /// The clip actions (docs/actions.md, Arranger): false for the rest, which the key router runs itself.
  bool _action(String id, int count, String? arg) {
    final s = widget.state;
    switch (id) {
      case 'arranger.clip.split':
        if (!s.splitClips()) _router?.toast('Nothing under the playhead to split');
      case 'arranger.clip.glue':
        if (!s.glueSelected()) _router?.toast('Select two or more clips on a track to glue');
      case 'arranger.clip.duplicate':
        if (!s.duplicateSelected()) _router?.toast('Select clips to duplicate');
      case 'arranger.clip.properties':
        if (s.selectedClipIds.isEmpty) return false;
        showClipProperties(context, s);
      case 'arranger.clip.delete':
        if (!s.deleteSelected()) _router?.toast('Select clips to delete');
      case 'arranger.layer.delete':
        // REAPER's Delete removes the selected items; with no clip selected it deletes the track as before.
        if (s.selectedClipIds.isEmpty) return false;
        s.deleteSelected();
      case 'arranger.clip.copy':
        if (!s.copySelectedClips()) _router?.toast('Select clips to copy');
      case 'arranger.clip.cut':
        if (!s.cutSelectedClips()) _router?.toast('Select clips to cut');
      case 'arranger.clip.paste':
        final track = s.project.layers.where((l) => l.id == s.selectedLayerId && !l.isFolder).firstOrNull ??
            s.visibleLayers.where((l) => !l.isFolder).firstOrNull;
        if (ClipClipboard.items.isEmpty) {
          _router?.toast('Copy clips first');
        } else if (track == null || !s.pasteClips(track, s.editStep)) {
          _router?.toast('Nothing to paste on this track');
        }
      case 'arranger.clip.selectAll':
        if (!s.selectAllClips()) _router?.toast('No clips');
      case 'arranger.clip.selectNone':
        // Esc clears the clip and time selections, and leaves Select mode.
        s.clearClipSelection();
        s.clearTimeSelection();
        setState(() => _selectMode = false);
      case 'arranger.clip.selectMode':
        setState(() => _selectMode = !_selectMode);
      case 'arranger.loop.toggle':
        s.toggleLoopRange();
      case 'arranger.marker.add':
        s.addMarker(s.editStep);
      case 'arranger.region.add':
        final a = s.timeSelectionStart, b = s.timeSelectionEnd;
        if (a != null && b != null && a != b) {
          s.addMarker(math.min(a, b), end: math.max(a, b));
        } else if (s.project.hasLoopRange) {
          s.addMarker(s.project.loopStartSteps, end: s.project.loopEndSteps);
        } else {
          _router?.toast('Make a time selection or a loop range first');
        }
      case 'arranger.zoom.fit':
        _zoomToFit();
      case 'arranger.zoom.selection':
        if (!_zoomToSelection()) _router?.toast('Select clips or a time range to zoom to');
      case 'arranger.view.start':
        _revealStart();
      case 'arranger.marker.next' || 'arranger.marker.prev':
        if (!s.jumpToMarker(next: id.endsWith('next'))) _router?.toast('No marker that way');
        _reveal(s.playheadStep);
      case 'arranger.take.next' || 'arranger.take.prev':
        final withTakes = [for (final c in s.selectedClips) if (c.clip.takes.length > 1) c];
        if (withTakes.isEmpty) _router?.toast('Select a clip with takes (a loop recording)');
        for (final c in withTakes) {
          s.stepTake(c.layer, c.clip, id.endsWith('next') ? 1 : -1);
        }
      case 'arranger.marker.list':
        showMarkerList(context, s);
      case final go when go.startsWith('arranger.marker.go'):
        final n = int.tryParse(go.substring('arranger.marker.go'.length)) ?? 0;
        if (!s.jumpToMarkerNumber(n)) _router?.toast('No marker $n');
        _reveal(s.playheadStep);
      default:
        return false;
    }
    return true;
  }

  // ---------- the marquee ----------

  void _marqueeStart(Offset global, {bool additive = false}) {
    _marqueeFrom = global;
    _marqueeAdd = additive;
  }

  void _marqueeMove(Offset global) {
    final from = _marqueeFrom;
    if (from == null) return;
    // A right click that doesn't move stays a click.
    if (_marquee.value == null && (global - from).distance < 6) return;
    _marquee.value = Rect.fromPoints(from, global);
  }

  void _marqueeEnd() {
    final box = _marquee.value;
    _marqueeFrom = null;
    _marquee.value = null;
    if (box == null) return;
    final s = widget.state;
    final hit = <PlacedClip>[];
    for (final layer in s.visibleLayers) {
      final lane = _drag.laneRect(layer.id);
      if (lane == null) continue;
      final inset = _clipInset(lane.height);
      final top = lane.top + inset, bottom = lane.bottom - inset;
      if (box.bottom < top || box.top > bottom) continue;
      for (final clip in layer.clips) {
        final left = lane.left + clip.startSteps * _stepW;
        final right = left + math.max(12.0, clip.lengthSteps * _stepW);
        // REAPER: touching an item with the marquee is enough to include it (UG 7.2.2).
        if (box.right >= left && box.left <= right) hit.add((layer: layer, clip: clip));
      }
    }
    s.selectClipsInBox(hit, additive: _marqueeAdd);
  }

  @override
  void dispose() {
    widget.state.tick.removeListener(_followPlayhead);
    widget.state.revealStartRequests.removeListener(_revealStart);
    _router?.unregister(Area.arranger, _keys);
    _keys.dispose();
    _marquee.dispose();
    _panelOut.dispose();
    _browserTimer?.cancel();
    _glide.dispose();
    _vGlide.dispose();
    _hScroll.removeListener(_onHScroll);
    _trackGhost?.remove();
    _trackGhostAt.dispose();
    _pinchView.dispose();
    _drag.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  /// Sets the time zoom, keeping the timeline point under [focal] (pixels from the lanes' left edge; the middle of
  /// the view by default) where it is.
  /// With [leftStep], that step goes to the view's left edge instead.
  void _setZoom(double z, {double? focal, double? leftStep}) {
    z = z.clamp(minZoom, maxZoom).toDouble();
    if (z == zoom && leftStep == null) return;
    final pos = _hScroll.hasClients ? _hScroll.positions.last : null;
    final f = leftStep != null ? 0.0 : focal ?? (pos?.viewportDimension ?? 0) / 2;
    final anchor = leftStep ?? (pos == null ? null : (pos.pixels + f) / _stepW);
    super.setState(() => zoom = z); // the zoom alone: the headers stay as built
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hScroll.hasClients) return;
      final p = _hScroll.positions.last;
      p.jumpTo((anchor * _stepW - f).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }

  /// A time pinch's move to zoom [z] around [focal] (pixels from the lanes' left edge): what [_setZoom] would do,
  /// drawn as a scale of the lanes as laid out.
  void _pinchTo(double z, double focal) {
    z = z.clamp(minZoom, maxZoom).toDouble();
    final pos = _hScroll.hasClients ? _hScroll.positions.last : null;
    if (pos == null) return _setZoom(z, focal: focal);
    if (_pinchView.value == null && _pinchScale == 1 && !_pinchJump) _pinchAt = _pinchSeen = pos.pixels;
    if (!_pinchJump) {
      _pinchAt += pos.pixels - _pinchSeen; // the fingers' own scrolling
      _pinchSeen = pos.pixels;
    }
    final scale = z / zoom;
    if (scale == _pinchScale) return;
    // As _setZoom moves it: the step under the focal point stays there.
    _pinchAt = math.max(0.0, (_pinchAt + focal) * scale / _pinchScale - focal);
    _pinchScale = scale;
    if (_pinchJump || scale < _pinchRebase.$1 || scale > _pinchRebase.$2) return _pinchCommit();
    arrangeSpanReveal.value = 1 / _pinchRebase.$1 - 1;
    _pinchView.value = Matrix4.diagonal3Values(scale, 1, 1)..setTranslationRaw(pos.pixels - _pinchAt, 0, 0);
  }

  /// Lays the lanes out at the pinch's zoom and scroll position (once, as the pinch ends or rebases).
  void _pinchCommit() {
    if (_pinchView.value == null && _pinchScale == 1) return;
    final target = _pinchAt;
    final z = (zoom * _pinchScale).clamp(minZoom, maxZoom).toDouble();
    _pinchScale = 1;
    _pinchView.value = null;
    arrangeSpanReveal.value = 0;
    if (z != zoom) super.setState(() => zoom = z); // the zoom alone: the headers stay as built
    _pinchJump = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinchJump = false;
      if (!mounted || !_hScroll.hasClients) return;
      final p = _hScroll.positions.last;
      p.jumpTo(target.clamp(0.0, p.maxScrollExtent).toDouble());
      _pinchAt = _pinchSeen = p.pixels;
    });
  }

  /// The mouse pointer panning the view (middle-drag or Space+drag), if any.
  int? _panPointer;

  void _touchDown(PointerDownEvent e, double headW) {
    if (startsMousePan(e)) {
      _panPointer = e.pointer;
      if (e.buttons == kPrimaryMouseButton) SpacePan.claim();
      return;
    }
    if (e.kind != PointerDeviceKind.touch) return;
    // During a clip or track drag a second finger toggles copy (the phone's Ctrl) instead of starting a pinch; during
    // a clip picked up with a long press it frees the clip from the grid while it rests (owner, 2026-11-11).
    if (_drag.active) {
      if (_drag.lifted) {
        _resting = e.pointer;
        _drag.free.value = true;
      } else {
        _drag.copy.value = !_drag.copy.value;
      }
      Motion.tick();
      return;
    }
    _touches[e.pointer] = e.localPosition;
    _touchesAt[e.pointer] = e.position;
    _drag.pinching = _touches.length >= 2;
    if (_touches.length == 2) {
      final ps = _touches.values.toList();
      final dx = (ps[0].dx - ps[1].dx).abs(), dy = (ps[0].dy - ps[1].dy).abs();
      _pinchDx0 = dx;
      _pinchDy0 = dy;
      _pinchZoom0 = zoom;
      _pinchH0 = _trackHeight;
      // Fingers side by side zoom time, one above the other the height; diagonal, both.
      _pinchX = dx > 24 && dx >= dy * 0.6;
      _pinchY = dy > 24 && dy >= dx * 0.6;
      // Both fingers on one track's header, one above the other: that track's height only (owner, 2026-11-11).
      final at = _touchesAt.values.toList();
      final row = _pinchY && e.localPosition.dx < headW && ps[0].dx < headW && ps[1].dx < headW
          ? _headerAt(Offset((at[0].dx + at[1].dx) / 2, (at[0].dy + at[1].dy) / 2)) : null;
      _pinchRow = row?.id;
      if (row != null) {
        _pinchX = false;
        _pinchH0 = _rowHeight(row);
      }
      _glide.stop();
    }
  }

  void _touchMove(PointerMoveEvent e, double headW) {
    if (e.pointer == _panPointer) return panBy(e.delta, h: _hScroll, v: _drag.vScroll);
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length != 2) return;
    final ps = _touches.values.toList();
    if (_pinchX) {
      _pinchTo(_pinchZoom0 * (ps[0].dx - ps[1].dx).abs() / _pinchDx0, (ps[0].dx + ps[1].dx) / 2 - headW);
    }
    final row = _pinchRow == null ? null : widget.state.project.layers.where((l) => l.id == _pinchRow).firstOrNull;
    if (_pinchY && row != null) {
      _rowResizeTo(row, _pinchH0 * (ps[0].dy - ps[1].dy).abs() / _pinchDy0);
    } else if (_pinchY) {
      setState(() => _dragTrackH = (_pinchH0 * (ps[0].dy - ps[1].dy).abs() / _pinchDy0)
          .clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble());
    }
  }

  /// The second finger resting during a lifted clip drag (it frees the clip from the grid until it lifts).
  int? _resting;

  void _touchUp(PointerEvent e) {
    if (e.pointer == _panPointer) _panPointer = null;
    if (e.pointer == _resting) {
      _resting = null;
      _drag.free.value = false;
    }
    _touchesAt.remove(e.pointer);
    if (_touches.remove(e.pointer) == null) return;
    _drag.pinching = _touches.length >= 2;
    if (_touches.length == 1 && (_pinchX || _pinchY)) {
      _pinchCommit();
      _pinchX = _pinchY = false;
      _pinchRow = null;
      _rowResizeEnd();
    }
  }

  /// Ctrl + wheel zooms time around the mouse; Ctrl + Shift + wheel changes the track height. Registered before the
  /// scroll views see the wheel, so they don't also scroll. Settings › Editing › Wheel zooms swaps them: the wheel
  /// alone zooms and Ctrl + wheel scrolls.
  void _wheel(PointerSignalEvent e, double? focal) {
    final zooms = HardwareKeyboard.instance.isControlPressed != widget.state.settings.wheelZooms;
    if (e is! PointerScrollEvent || !zooms) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final d = (event as PointerScrollEvent).scrollDelta;
      final amount = d.dy != 0 ? d.dy : d.dx;
      if (amount == 0) return;
      final factor = amount > 0 ? 1 / 1.12 : 1.12;
      if (HardwareKeyboard.instance.isShiftPressed) {
        setState(() => _dragTrackH = (_trackHeight * factor)
            .clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble());
        _saveHeaderSize();
      } else {
        _setZoom(zoom * factor, focal: focal);
      }
    });
  }

  SectionController? get _sections => SectionController.maybeOf(context);

  String? get _focusId => _sections != null ? _sections!.focusedLayer : _localFocus;

  void _focus(String? layerId, {FocusTab? tab}) {
    // A header's tap held for a double tap can land as the arranger goes away (the recognizer's dispose sweeps it).
    if (!mounted) return;
    if (tab != null) _tab = tab;
    final sections = _sections;
    if (sections != null) {
      sections.focusLayer(layerId);
      setState(() {});
    } else {
      setState(() => _localFocus = layerId);
    }
    if (layerId != null) {
      final layer = widget.state.project.layers.where((l) => l.id == layerId).firstOrNull;
      if (layer != null && widget.state.selectedLayerId != layerId) widget.state.selectLayer(layer);
    }
  }

  /// The tracks the focus view steps through with a sideways swipe (folders hold no clips or effects).
  List<LayerDoc> get _focusable => widget.state.visibleLayers.where((l) => !l.isFolder).toList();

  void _step(int by) {
    final list = _focusable;
    final i = list.indexWhere((l) => l.id == _focusId);
    if (i < 0 || list.isEmpty) return;
    final next = i + by;
    if (next < 0 || next >= list.length) return;
    Motion.tick();
    _focus(list[next].id);
  }

  void _openTrack(LayerDoc layer, {FocusTab? tab}) {
    if (layer.isFolder) {
      widget.state.selectLayer(layer);
      return;
    }
    _focus(layer.id, tab: tab);
  }

  Future<void> _trackMenu(LayerDoc layer, Offset at, List<ModuleDoc> patterns) async {
    final s = widget.state;
    final index = s.project.layers.indexOf(layer);
    s.componentCatalog.refreshIfStale();
    final hasVolume = layer.automation.any((a) => a.target == 'volume');
    final hasPan = layer.automation.any((a) => a.target == 'pan');
    final canAutomate = !layer.isFolder || layer.busEnabled;
    final midi = LiveMidi.current;
    // Sections, the most used first (owner, 2026-11-11); volume and pan edit in place.
    const track = 'Track', mix = 'Mix', record = 'Record', clips = 'Clips', move = 'Move', lanes = 'Automation',
        collapse = 'Collapse', more = 'More';
    final shown = s.shownCollapse(layer);
    final v = await showLongPressMenu<String>(context, at: at, title: layer.name, style: s.settings.longPressMenu, actions: [
      if (!layer.isFolder) ...[
        const MenuAction('fx', 'Effects', Icons.graphic_eq, section: track),
        // The same browser as the FX stack's (REAPER: instruments are FX), filtered to instruments.
        if (!layer.isAudio)
          MenuAction('instrument', 'Instrument · ${s.instrumentName(layer) ?? 'none'}…', Icons.piano, section: track),
      ],
      const MenuAction('rename', 'Rename', Icons.edit_outlined, section: track),
      MenuAction('color', layer.ownColor || layer.parentId == null ? 'Colour' : 'Own colour', Icons.palette_outlined,
          section: track),
      if (layer.ownColor && layer.parentId != null) const MenuAction('folder-color', "Use the folder's colour",
          Icons.format_color_reset_outlined, section: track),
      if (!layer.isFolder || layer.busEnabled) ...[
        MenuAction('volume', 'Volume', Icons.volume_up_outlined, section: mix, number: MenuNumber(
          value: _gainDb(layer.volume), min: -60, max: _gainDb(kMaxMixGain), defaultValue: 0,
          format: (db) => db <= -60 ? '-inf dB' : '${db.toStringAsFixed(1)} dB',
          parse: (t) => t.trim().toLowerCase().startsWith('-inf') ? -60
              : double.tryParse(t.replaceAll(RegExp(r'[^-+0-9.]'), '')),
          onChanged: (db) => s.mixLayer(layer, volume: _dbGain(db)),
          onChangeEnd: (db) { s.mixLayer(layer, volume: _dbGain(db)); s.endUndoStep(); })),
        MenuAction('pan', 'Pan', Icons.compare_arrows, section: mix, number: MenuNumber(
          value: layer.pan * 100, min: -100, max: 100, defaultValue: 0,
          format: (v) => v.round() == 0 ? 'C' : '${v < 0 ? 'L' : 'R'}${v.abs().round()}',
          parse: (t) {
            final text = t.trim().toUpperCase();
            if (text == 'C') return 0;
            final n = double.tryParse(text.replaceAll(RegExp(r'[^-+0-9.]'), ''));
            return n == null ? null : (text.startsWith('L') ? -n.abs() : n);
          },
          onChanged: (v) => s.mixLayer(layer, pan: v / 100),
          onChangeEnd: (v) { s.mixLayer(layer, pan: v / 100); s.endUndoStep(); })),
      ],
      if (!layer.isFolder) ...[
        // MIDI keyboards and the on-screen keys record into a track (lib/model/live_midi.dart); audio recording needs
        // the engine's input.
        // While any track records, this stops that take (one take at a time).
        // With no USB keyboard, recording opens the on-screen keys and pads.
        if (layer.isAudio) ...[
          // An audio track records its input (lib/model/audio_record.dart) when armed and Record is pressed.
          MenuAction('audio-arm', 'Record arm', Icons.fiber_manual_record, checked: layer.input?.armed ?? false,
              section: record),
          MenuAction('audio-input', 'Input · ${layer.input?.label ?? 'none'}…', Icons.input, section: record),
        ] else ...[
          MenuAction('arm', midi?.recording ?? false ? 'Stop recording' : 'Record arm', Icons.fiber_manual_record,
              enabled: midi != null, checked: midi?.armedLayerId == layer.id, section: record),
          MenuAction('input', 'Input · ${midi == null || midi.devices.isEmpty ? 'none' : midi.devices.join(', ')}', Icons.input,
              enabled: false, hint: 'MIDI keyboards play the selected track; an audio track records audio input',
              section: record),
        ],
        if (layer.instrument == null && layer.clips.isEmpty)
          const MenuAction('audio-import', 'Import audio…', Icons.graphic_eq_rounded, section: clips)
        else
          const MenuAction('audio-track', 'New audio track below', Icons.graphic_eq_rounded, section: clips),
        for (final pattern in patterns)
          MenuAction('clip:${pattern.id}', 'Add clip · ${pattern.name}', Icons.add_box_outlined, section: clips),
        const MenuAction('midi', 'Import MIDI file…', Icons.file_open_outlined, section: clips),
      ],
      if (index > 0) const MenuAction('up', 'Move up', Icons.arrow_upward, section: move),
      if (index < s.project.layers.length - 1) const MenuAction('down', 'Move down', Icons.arrow_downward, section: move),
      // Out one level, as REAPER's folders nest (UG 5.13.5): into the folder above, or to the top.
      if (layer.parentId != null) MenuAction('unparent', 'Move out of ${s.project.layers
          .where((f) => f.id == layer.parentId).firstOrNull?.name ?? 'folder'}', Icons.drive_file_move_rtl_outlined,
          section: move),
      // Any folder at any depth, except this one, its folder and the folders inside it.
      for (final folder in s.project.layers.where((f) => f.isFolder && f.id != layer.id && f.id != layer.parentId &&
          !s.isInside(f, layer.id)))
        MenuAction('parent:${folder.id}', 'Move into ${folder.name}', Icons.drive_file_move_outlined, section: move),
      if (layer.isFolder) const MenuAction('subfolder', 'New folder inside', Icons.create_new_folder_outlined,
          section: move),
      if (layer.isFolder) MenuAction('bus', layer.busEnabled ? 'Disable group bus' : 'Enable group bus',
          Icons.account_tree_outlined, section: move),
      MenuAction('spacer', layer.spaceBelow > 0 ? 'Remove spacer below' : 'Add spacer below', Icons.space_bar,
          section: move),
      if (canAutomate) MenuAction('lanes', layer.showLanes ? 'Hide automation lanes' : 'Show automation lanes',
          Icons.show_chart, checked: layer.showLanes, section: lanes),
      if (canAutomate && !hasVolume) const MenuAction('automation-volume', 'Add volume automation', Icons.show_chart,
          section: lanes),
      if (canAutomate && !hasPan) const MenuAction('automation-pan', 'Add pan automation', Icons.show_chart,
          section: lanes),
      if (hasVolume) const MenuAction('remove-automation-volume', 'Remove volume automation',
          Icons.remove_circle_outline, section: lanes),
      if (hasPan) const MenuAction('remove-automation-pan', 'Remove pan automation', Icons.remove_circle_outline,
          section: lanes),
      // REAPER's track heights (owner, 2026-11-11): the row's full height, compact (name, M and S) or a thin bar.
      for (final (c, label, icon) in const [(TrackCollapse.normal, 'Normal', Icons.view_stream_outlined),
          (TrackCollapse.compact, 'Compact', Icons.view_headline), (TrackCollapse.thin, 'Thin', Icons.horizontal_rule)])
        MenuAction('collapse:${c.name}', label, icon, checked: shown == c, section: collapse),
      if (layer.height != null) const MenuAction('default-height', 'Default height', Icons.height, section: collapse),
      MenuAction('template', layer.isFolder ? 'Save folder as track template…' : 'Save as track template…',
          Icons.bookmark_add_outlined, section: more),
      const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true, section: more),
    ]);
    if (v == null || !mounted) return;
    if (v == 'fx') _openTrack(layer, tab: FocusTab.fx);
    if (v == 'arm') midi?.toggleRecord(layer.id);
    if (v == 'audio-arm') {
      await toggleAudioArm(context, s, layer);
      return;
    }
    if (v == 'audio-input') {
      await showAudioInputSheet(context, s, layer);
      return;
    }
    if (v == 'audio-import') {
      await importAudioFiles(context, s, layer: layer);
      return;
    }
    if (v == 'audio-track') s.addAudioTrack(after: layer);
    if (v == 'instrument') {
      await pickInstrument(context, s, layer);
      return;
    }
    if (v.startsWith('clip:')) s.addClip(layer, v.substring(5));
    if (v == 'midi') await importMidiFile(context, s, layer: layer);
    if (v == 'rename') await _rename(layer);
    if (v == 'color') s.editLayer(layer, (l) { l.color = l.ownColor ? (l.color + 1) % LayerDoc.trackColors : l.color; l.ownColor = true; });
    if (v == 'folder-color') s.editLayer(layer, (l) => l.ownColor = false);
    if (v == 'up' && index > 0) s.moveLayer(index, index - 1);
    if (v == 'down' && index < s.project.layers.length - 1) s.moveLayer(index, index + 2);
    if (v == 'unparent') {
      // Just below its folder, in that folder's own parent.
      final folder = s.project.layers.where((f) => f.id == layer.parentId).firstOrNull;
      folder == null ? s.moveLayerIntoFolder(layer, null) : s.moveTrack(layer, folder, TrackDrop.below);
    }
    if (v == 'subfolder') s.addFolder(parentId: layer.id);
    if (v.startsWith('parent:')) {
      final folder = s.project.layers.where((f) => f.id == v.substring(7)).firstOrNull;
      if (folder != null) s.moveTrack(layer, folder, TrackDrop.into);
    }
    if (v == 'bus') s.setFolderBus(layer, !layer.busEnabled);
    if (v.startsWith('collapse:')) {
      s.setTrackCollapse(_collapseTargets(layer), TrackCollapse.values.byName(v.substring(9)));
    }
    if (v == 'default-height') s.resetTrackHeight(layer);
    if (v == 'lanes') s.setLanesShown(layer, !layer.showLanes);
    if (v == 'automation-volume') s.addAutomationLane(layer, 'volume');
    if (v == 'automation-pan') s.addAutomationLane(layer, 'pan');
    if (v == 'remove-automation-volume') s.removeAutomationLane(layer, layer.automation.firstWhere((a) => a.target == 'volume'));
    if (v == 'remove-automation-pan') s.removeAutomationLane(layer, layer.automation.firstWhere((a) => a.target == 'pan'));
    if (v == 'template') {
      if (mounted) await saveTrackTemplate(context, s, layer);
      return;
    }
    if (v == 'spacer') s.setSpaceBelow(layer, layer.spaceBelow > 0 ? 0 : _SpacerHeader.initial);
    if (v == 'delete' && mounted && await confirmTrackDelete(context, s, layer) && mounted) {
      if (_focusId == layer.id) _focus(null);
      s.removeLayer(layer);
    }
  }

  /// The tracks the menu's Collapse applies to: the selected tracks, which is the one the menu is for (the arranger
  /// selects one track at a time today; a multi-track selection would join here).
  List<LayerDoc> _collapseTargets(LayerDoc layer) => [layer];

  // ---------- a track header dragged (owner, 2026-11-11, after REAPER: a long press picks the track up; up and
  // down reorders, the right-most third of another header nests it there) ----------

  LayerDoc? _pressed, _dragged;
  Offset _pressAt = Offset.zero, _trackAt = Offset.zero;

  /// A finger's hold that hasn't moved yet: let go now, it opens the track menu.
  bool _held = false;

  List<ModuleDoc> get _patterns => [for (final m in widget.state.project.modules) if (widget.state.isPattern(m.id)) m];
  OverlayEntry? _trackGhost;
  final _trackGhostAt = ValueNotifier<Offset>(Offset.zero);

  void _trackDrag(LayerDoc layer, _HeaderPhase phase, Offset at) {
    switch (phase) {
      case _HeaderPhase.press:
        // A long press lifts the track at once (the ghost and a tick); let go without moving, it stays put and the
        // track menu opens (owner, 2026-11-11).
        Motion.tick();
        _pressed = layer;
        _pressAt = at;
        _held = true;
        _startTrackDrag(layer, at);
        _trackHover();
      case _HeaderPhase.grab:
        _pressed = layer;
        _pressAt = at;
        _held = false;
        _startTrackDrag(layer, at);
      case _HeaderPhase.move:
        if (_dragged == null && _pressed == layer && (at - _pressAt).distance > 10) _startTrackDrag(layer, at);
        if (_dragged != layer) return;
        if ((at - _pressAt).distance > 10) _held = false;
        _trackAt = at;
        _trackGhostAt.value = at;
        _drag.point(at);
        _trackHover();
      case _HeaderPhase.release:
        if (_dragged != layer) {
          _pressed = null;
          return;
        }
        final spot = _drag.hover.value;
        final menu = _held;
        _held = false;
        _endTrackDrag();
        if (menu) {
          _trackMenu(layer, _pressAt, _patterns);
          return;
        }
        if (spot == null) return;
        final target = widget.state.project.layers.where((l) => l.id == spot.layerId).firstOrNull;
        widget.state.moveTrack(layer, spot.newTrack ? null : target, spot.where);
      case _HeaderPhase.cancel:
        if (_dragged == layer) _endTrackDrag();
        _pressed = null;
    }
  }

  void _startTrackDrag(LayerDoc layer, Offset at) {
    _dragged = layer;
    _trackAt = at;
    _trackGhostAt.value = at;
    _drag.begin(track: true, onScroll: _trackHover, onCancel: _endTrackDrag);
    final color = trackColor(widget.state, layer);
    _trackGhost = OverlayEntry(builder: (context) => ValueListenableBuilder<Offset>(
      valueListenable: _trackGhostAt,
      builder: (context, p, _) => Positioned(left: p.dx + 12, top: p.dy - 14, child: IgnorePointer(child: Material(
        key: const ValueKey('track-drag-ghost'),
        color: Color.lerp(Neon.panel, color, 0.35)!.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: color, width: 3))),
          child: Text(layer.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))))))));
    Overlay.of(context).insert(_trackGhost!);
  }

  void _trackHover() {
    final layer = _dragged;
    if (layer == null) return;
    final s = widget.state;
    var spot = _drag.trackSpotAt(_trackAt);
    // Onto itself, or into itself, a track inside it or the parent it is already in, it stays where it is.
    final onto = spot?.layerId == null ? null : s.project.layers.where((l) => l.id == spot!.layerId).firstOrNull;
    if (onto != null && (identical(onto, layer) || s.isInside(onto, layer.id) ||
        (spot!.where == TrackDrop.into && layer.parentId == onto.id))) {
      spot = null;
    }
    _drag.hover.value = spot;
  }

  void _endTrackDrag() {
    _trackGhost?.remove();
    _trackGhost = null;
    _dragged = _pressed = null;
    _drag.end();
  }

  Future<void> _rename(LayerDoc layer) async {
    final controller = TextEditingController(text: layer.name);
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Rename track'),
      content: TextField(controller: controller, autofocus: true, maxLength: 64,
        onSubmitted: (v) => Navigator.of(context).pop(v)),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Rename')),
      ],
    ));
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty && trimmed != layer.name) widget.state.editLayer(layer, (l) => l.name = trimmed);
  }

  Future<void> _clipMenu(LayerDoc layer, ClipDoc clip, Offset at) async {
    final s = widget.state;
    final splitAt = s.timeSelectionEnd;
    final canSplit = splitAt != null && splitAt > clip.startSteps && splitAt < clip.startSteps + clip.lengthSteps;
    final playhead = s.editStep;
    final canSplitHere = !clip.lock && playhead > clip.startSteps && playhead < clip.startSteps + clip.lengthSteps;
    const clipSection = 'Clip', edit = 'Edit', size = 'Size', more = 'More';
    final bar = s.project.stepsPerBar;
    // Reset goes back to the pattern's own length.
    final doc = PatternDoc.parse(s.project.module(clip.patternId)?.source ?? '').doc;
    final patternBars = doc == null ? null : math.max(1, doc.lengthSteps(s.project.beatsPerBar)) / bar;
    final v = await showLongPressMenu<String>(context, at: at, title: s.clipName(clip),
      style: s.settings.longPressMenu, actions: [
        const MenuAction('notes', 'Edit notes', Icons.piano, section: clipSection),
        const MenuAction('properties', 'Properties…', Icons.tune, section: clipSection),
        // The phone's way to select several (docs/ui.md): this clip joins the selection and Select mode turns on.
        if (!s.selectedClipIds.contains(clip.id) || !_selectMode)
          const MenuAction('select', 'Select several', Icons.checklist, section: clipSection)
        else
          const MenuAction('select', 'Deselect', Icons.deselect, section: clipSection),
        // Loop-recorded takes (lib/model/live_midi.dart): pick the one the clip plays.
        if (clip.takes.length > 1) MenuAction('takes', 'Takes (${clip.takes.length})…', Icons.layers_outlined,
            section: clipSection),
        if (widget.onOpenPattern != null) const MenuAction('edit', 'Open in Build', Icons.open_in_new,
            section: clipSection),
        const MenuAction('copy', 'Duplicate independently', Icons.copy, section: edit),
        const MenuAction('linked', 'Duplicate linked', Icons.link, section: edit),
        if (canSplitHere) const MenuAction('split-here', 'Split at the playhead', Icons.content_cut, section: edit),
        if (canSplit && !clip.lock) const MenuAction('split', 'Split at time selection', Icons.content_cut,
            section: edit),
        MenuAction('loop', clip.loop ? 'Disable clip looping' : 'Enable clip looping', Icons.loop, checked: clip.loop,
            section: edit),
        // The length in bars, on the grid's beats; applied when the slider is let go (it rebuilds the project).
        if (!clip.lock) MenuAction('length', 'Length (bars)', Icons.straighten, section: size, number: MenuNumber(
          value: clip.lengthSteps / bar, min: 1 / s.project.beatsPerBar,
          max: math.max(64.0, clip.lengthSteps / bar).ceilToDouble(),
          defaultValue: patternBars,
          format: (b) => b == b.roundToDouble() ? b.toInt().toString() : b.toStringAsFixed(2),
          onChangeEnd: (b) {
            s.resizeClip(layer, clip, math.max(1, (b * bar).round()));
            s.endUndoStep();
          })),
        // The clip's own loop point (owner, 2026-11-11; the piano roll's loop bar sets it too): in bars, whole steps.
        MenuAction('loop-length', 'Loop length…', Icons.repeat, section: size, number: MenuNumber(
          value: s.project.clipLoopSteps(clip) / bar, min: 1 / bar,
          max: math.max(16.0, s.project.clipLoopSteps(clip) / bar).ceilToDouble(),
          defaultValue: patternBars,
          format: (b) => b == b.roundToDouble() ? b.toInt().toString() : b.toStringAsFixed(2),
          onChangeEnd: (b) => s.setClipLoop(layer, clip, math.max(1, (b * bar).round())))),
        if (clip.loopSteps != null)
          const MenuAction('loop-reset', 'Reset loop to pattern length', Icons.restart_alt, section: size),
        const MenuAction('midi', 'Export as MIDI file', Icons.file_upload_outlined, section: more),
        if (!clip.lock) const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true, section: more),
      ]);
    if (v == null || !mounted) return;
    if (v == 'select') {
      final adding = !s.selectedClipIds.contains(clip.id) || !_selectMode;
      setState(() => _selectMode = true);
      if (adding && !s.selectedClipIds.contains(clip.id)) s.toggleClipSelection(layer, clip);
      if (!adding) s.toggleClipSelection(layer, clip);
    }
    if (v == 'properties') {
      if (!s.selectedClipIds.contains(clip.id)) s.selectClip(layer, clip);
      await showClipProperties(context, s);
      return;
    }
    if (v == 'split-here' || v == 'split') {
      s.selectClip(layer, clip);
      s.splitClips(at: v == 'split' ? splitAt : playhead);
    }
    if (v == 'notes') { s.activateClip(layer, clip); _focus(layer.id, tab: FocusTab.clip); }
    if (v == 'takes') return showTakePicker(context, s, layer, clip, at);
    if (v == 'edit') { s.activateClip(layer, clip); widget.onOpenPattern?.call(); }
    if (v == 'copy') s.duplicateClip(layer, clip);
    if (v == 'linked') s.duplicateClip(layer, clip, linked: true);
    if (v == 'loop') s.editLayer(layer, (l) => clip.loop = !clip.loop);
    if (v == 'loop-reset') s.setClipLoop(layer, clip, null);
    if (v == 'midi') await exportClipAsMidi(context, s, clip);
    if (v == 'delete') s.removeClip(layer, clip);
  }

  /// The + Track button's tooltip, in the words of the input in use.
  static String get _addTrackTip => 'Add a track (${PointerInput.hold} for a folder, audio or a template)';

  _TrackCallbacks _callbacks(List<ModuleDoc> patterns) => _TrackCallbacks(
    onTap: (l) => _openTrack(l),
    onFx: (l) => _openTrack(l, tab: FocusTab.fx),
    onMenu: (l, at) => _trackMenu(l, at, patterns),
    onClipMenu: _clipMenu,
    // A mouse's double-click on a MIDI clip opens its notes, as the menu's Edit notes does.
    onClipOpen: (l, c) {
      widget.state.activateClip(l, c);
      _focus(l.id, tab: FocusTab.clip);
    },
    onAudioOpen: (l) => _focus(l.id, tab: FocusTab.clip),
    selectMode: () => _selectMode,
    onMarquee: (phase, at, additive) => switch (phase) {
      _Marquee.start => _marqueeStart(at, additive: additive),
      _Marquee.move => _marqueeMove(at),
      _Marquee.end => _marqueeEnd(),
    },
  );

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    _revealSelection();
    // A header's quick second tap where its first was counts even when the first moved the track away (the focus
    // view pins it on top) and the panel or a lane is there now: it opens that track's effects (owner, 2026-11-11).
    // A press on another header is a first tap there (its own handler counted it).
    return Listener(behavior: HitTestBehavior.translucent, onPointerDown: (e) {
      if (!_headerTaps.secondHere(e)) return;
      final l = s.project.layers.where((x) => x.id == _headerTaps.lastTarget).firstOrNull;
      if (l != null) _openTrack(l, tab: FocusTab.fx);
    // The track cards slide in over the arrangement and back out (owner, 2026-11-11); the arrangement isn't built
    // while they cover it.
    }, child: Stack(children: [
      if (!cardsView) Positioned.fill(child: _main(context)),
      Positioned.fill(child: Presence(from: const Offset(0, 0.08), child: !cardsView ? null : ColoredBox(
        color: Neon.bg,
        child: Column(children: [
          TrackCardsHeader(onBack: () => setState(() => cardsView = false)),
          Expanded(child: TrackCardsScreen(state: s, onOpenModule: widget.onOpenModule ?? s.selectModule,
              onBack: () => setState(() => cardsView = false))),
        ])))),
    ]));
  }

  /// The track whose focus panel is on its way out, and the one shown last (owner, 2026-11-11: the panel leaves as
  /// it came).
  LayerDoc? _closing, _shownFocus;
  late final AnimationController _panelOut = AnimationController(vsync: this)
    ..addStatusListener((st) {
      if (st == AnimationStatus.dismissed && _closing != null && mounted) setState(() => _closing = null);
    });

  Widget _main(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final focused = p.layers.where((l) => l.id == _focusId && !l.isFolder).firstOrNull;
    if (focused != null) {
      _closing = null;
      _shownFocus = focused;
    } else if (_shownFocus != null) {
      final d = EditMotion.scaled(Motion.of(context), EditMotionKind.panels, Motion.panel);
      if (d != null && p.layers.contains(_shownFocus)) {
        _closing = _shownFocus;
        _panelOut.duration = d;
        _panelOut.reverse(from: 1);
      }
      _shownFocus = null;
    }
    // The panel's track: the focused one, or the one whose panel is leaving.
    final shownTrack = focused ?? _closing;
    final layout = focusLayoutFor(MediaQuery.sizeOf(context));
    final callbacks = _callbacks(_patterns);
    final focusable = _focusable;
    final fi = focused == null ? -1 : focusable.indexOf(focused);
    Widget panel(bool sheet) => FocusPanel(
      state: s, layer: shownTrack!, tab: _tab, bottomSheetStyle: sheet,
      onTab: (t) => setState(() => _tab = t),
      onClose: () { _panelHigh = false; _focus(null); },
      expanded: _panelHigh,
      onExpand: sheet ? (v) => setState(() => _panelHigh = v) : null,
      onPrevious: fi > 0 ? () => _step(-1) : null,
      onNext: fi >= 0 && fi < focusable.length - 1 ? () => _step(1) : null,
      onOpenModule: widget.onOpenModule,
      browsing: _browser,
      onBrowse: () => setState(() => _browser = !_browser),
    );

    // On its way out the panel slides and fades back where it came from, and takes no touches.
    Widget leaving(Widget panel, Offset to) => _closing == null ? panel : IgnorePointer(child: FadeTransition(
      opacity: CurvedAnimation(parent: _panelOut, curve: Curves.easeOutCubic),
      child: Motion.of(context) != MotionLevel.full ? panel : SlideTransition(
        position: Tween(begin: to, end: Offset.zero).animate(CurvedAnimation(parent: _panelOut, curve: Curves.easeOutCubic)),
        child: panel)));
    final Widget body;
    if (shownTrack != null && layout == FocusLayout.pinned) {
      // Phone portrait: the track pinned at the top (still scrollable and editable), its panel below.
      // Opened higher, the panel slides up over the track and leaves only a sliver of it.
      body = LayoutBuilder(builder: (context, box) {
        final pinnedH = (box.maxHeight * 0.2).clamp(84.0, 220.0).toDouble();
        return Column(children: [
          AnimatedContainer(duration: Motion.move(Motion.panel, Motion.of(context)), curve: Curves.easeOutCubic,
            height: _panelHigh ? 0 : pinnedH + 4,
            child: ClipRect(child: OverflowBox(alignment: Alignment.topCenter, minHeight: pinnedH + 4, maxHeight: pinnedH + 4,
              child: Column(children: [
                SizedBox(height: pinnedH, child: _timeline(context, [shownTrack], callbacks, pinned: true)),
                const SizedBox(height: 4),
              ])))),
          Expanded(child: leaving(SlideIn(from: const Offset(0, 0.12), child: panel(true)), const Offset(0, 0.12))),
        ]);
      });
    } else if (shownTrack != null) {
      // Landscape and desktop: a right side panel; the tracks keep their full height.
      // Its size is FocusSidePane's (focus_panel.dart): resizable on a phone, two thirds by default.
      body = FocusSidePane(settings: s.settings, desktop: MediaQuery.sizeOf(context).width >= 900,
        tracks: _arrangement(context, callbacks), panel: leaving(panel(false), const Offset(0.15, 0)));
    } else {
      body = _arrangement(context, callbacks);
    }

    // The Files pane leaves as it came: its room stays while it slides out (owner, 2026-11-11).
    if (_browserWas && !_browser) {
      final d = EditMotion.scaled(Motion.of(context), EditMotionKind.panels, Motion.panel);
      if (d != null) {
        _browserLeaving = true;
        _browserTimer?.cancel();
        _browserTimer = Timer(d, () { if (mounted) setState(() => _browserLeaving = false); });
      }
    }
    if (_browser) _browserLeaving = false;
    _browserWas = _browser;
    final paneRoom = _browser || _browserLeaving;
    final withBrowser = LayoutBuilder(builder: (context, box) {
      // The same Files browser as Build's explorer; hold an item and drag it onto a track or the FX stack.
      final pane = Presence(
        from: box.maxWidth >= 600 ? const Offset(0.15, 0) : const Offset(0, 0.15),
        child: !_browser ? null : Padding(padding: const EdgeInsets.all(4), child: GlassPanel(key: const ValueKey('arrange-browser'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: 30, child: Row(children: [
              const SizedBox(width: 10),
              const Icon(Icons.drag_indicator, size: 14, color: Neon.dim),
              const SizedBox(width: 4),
              const Expanded(child: Text('Hold an item, drag it onto a track', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Neon.dim, fontSize: 11))),
              IconButton(tooltip: 'Close the browser', iconSize: 16, visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _browser = false), icon: const Icon(Icons.close)),
            ])),
            Expanded(child: FileManagerScreen(key: const ValueKey('arrange explorer'), state: s, explorer: true,
              onOpenAsset: (_) {})),
          ]))));
      if (box.maxWidth >= 600) {
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: body),
          if (paneRoom) SizedBox(width: math.min(300.0, box.maxWidth * 0.32), child: pane),
        ]);
      }
      return Column(children: [
        Expanded(child: body),
        if (paneRoom) SizedBox(height: math.max(160.0, box.maxHeight * 0.4), child: pane),
      ]);
    });

    return PopScope(
      // Android Back closes the browser, then leaves the focus view (owner, 2026-11-09).
      canPop: focused == null && !_browser,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_browser) {
          setState(() => _browser = false);
        } else if (focused != null) {
          _focus(null);
        }
      },
      child: Column(children: [
        if (s.meters.overloaded > 0) _OverloadBanner(state: s),
        // The toolbar tucks away with the status row while the tracks scroll down (owner, 2026-11-10).
        _tucked(Column(mainAxisSize: MainAxisSize.min, children: [
          _toolbar(context, focused),
          AnimatedSize(duration: Motion.move(Motion.standard, Motion.of(context)), curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Presence(from: const Offset(0, -0.3), child: zoomBar ? _zoomBar() : null)),
        ])),
        if (settings) _settingsPanel(),
        Expanded(child: _withDockedClipBar(withBrowser, focused)),
      ]),
    );
  }

  /// A phone (a narrow arrangement) gets the clip bar docked near the bottom of the tracks while clips are selected,
  /// in reach of the thumb; a wide one has it in the toolbar.
  Widget _withDockedClipBar(Widget body, LayerDoc? focused) {
    final s = widget.state;
    if (focused != null || mixerCard || (s.selectedClipIds.isEmpty && !_selectMode)) return body;
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 760) return body;
      return Stack(children: [
        Positioned.fill(child: body),
        Positioned(left: 8, right: 8, bottom: 10, child: Center(child: SlideIn(from: const Offset(0, 0.4),
          child: FittedBox(fit: BoxFit.scaleDown, child: _clipBar(docked: true))))),
      ]);
    });
  }

  Widget _toolbar(BuildContext context, LayerDoc? focused) {
    final s = widget.state;
    final p = s.project;
    final gap = s.settings.trackGap;
    final clipsChosen = s.selectedClipIds.isNotEmpty || _selectMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      child: LayoutBuilder(builder: (context, constraints) {
        // A phone gets one row of icon buttons that scrolls sideways, instead of two rows of labelled buttons
        // under a heading (owner, 2026-11-05: one toolbar row, as in the UI plan).
        final narrow = constraints.maxWidth < 760;
        final controls = <Widget>[
          // Long-press (or right-click) for the add-track menu: a folder and the track templates.
          Builder(builder: (context) => GestureDetector(
            onSecondaryTapUp: (d) => showAddTrackMenu(context, s, d.globalPosition),
            child: narrow
              // The tooltip shows on hover only: a long press opens the add-track menu.
              ? Tooltip(message: _addTrackTip, triggerMode: TooltipTriggerMode.manual,
                  child: TextButton(key: const ValueKey('arrange-add-track'), onPressed: s.addLayer,
                    onLongPress: () => showAddTrackMenu(context, s, menuAnchorOf(context)),
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48), shape: const CircleBorder()),
                    child: const Icon(Icons.add, color: Neon.green)))
              // A desktop's hover names the menu behind it (a finger's long press shows no tooltip).
              : Tooltip(message: _addTrackTip, triggerMode: TooltipTriggerMode.manual,
                  child: TextButton.icon(key: const ValueKey('arrange-add-track'), onPressed: s.addLayer,
                  onLongPress: () => showAddTrackMenu(context, s, menuAnchorOf(context)),
                  icon: const Icon(Icons.add, size: 17), label: const Text('Track'))))),
          IconButton(key: const ValueKey('arrange-browse'), onPressed: () => setState(() => _browser = !_browser),
            color: _browser ? Neon.blue : Neon.dim, icon: const Icon(Icons.folder_open),
            tooltip: 'Files: drag one onto a track'),
          // REAPER's repeat (R): loops playback over the loop range drawn on the ruler, or the whole song when off.
          IconButton(key: const ValueKey('arrange-loop'), onPressed: s.toggleLoopRange,
            color: p.loopsRange ? Neon.blue : Neon.dim, icon: const Icon(Icons.repeat),
            tooltip: p.loopsRange ? 'Loop range on (R): drag on the ruler to change it' : 'Loop range (R): drag on the ruler to set it'),
          IconButton(onPressed: () => setState(() => zoomBar = !zoomBar),
            key: const ValueKey('arrange-zoom'),
            color: zoomBar ? Neon.blue : null,
            icon: const Icon(Icons.zoom_in), tooltip: 'Zoom (or pinch; Ctrl + wheel)'),
          PopupMenuButton<String>(
            tooltip: 'Track height',
            onSelected: (v) {
              final px = double.parse(v.substring(2));
              if (v.startsWith('h:')) {
                s.settings.update((x) => x.trackHeight = px).then((_) { if (mounted) setState(() {}); });
              } else {
                s.settings.update((x) => x.trackGap = px).then((_) { if (mounted) setState(() {}); });
              }
            },
            icon: const Icon(Icons.height, color: Neon.dim),
            itemBuilder: (_) => [
              for (final (px, name) in const [(44.0, 'Thin'), (60.0, 'Compact'), (76.0, 'Standard'), (96.0, 'Tall'), (120.0, 'Extra tall')])
                CheckedPopupMenuItem(value: 'h:$px', checked: _trackHeight == px, child: Text('$name · ${px.round()} px')),
              const PopupMenuDivider(),
              for (final (px, name) in const [(0.0, 'No gap'), (3.0, 'Small gap'), (6.0, 'Gap'), (12.0, 'Wide gap'), (20.0, 'Extra wide gap')])
                CheckedPopupMenuItem(value: 'g:$px', checked: gap == px, child: Text(px == 0 ? name : '$name · ${px.round()} px')),
            ],
          ),
          Tooltip(message: 'Grid: clips snap to this', child: DropdownButton<int>(key: const ValueKey('arrange-snap'),
            value: s.arrangementSnapSteps, underline: const SizedBox.shrink(),
            items: [for (final v in [1, 2, 4, 8, 16]) DropdownMenuItem(value: v, child: Text('1/${v == 1 ? 16 : 16 ~/ v}'))],
            onChanged: (v) { if (v != null) setState(() => s.arrangementSnapSteps = v); })),
          if (narrow)
            IconButton(onPressed: s.addFolder,
              icon: const Icon(Icons.create_new_folder_outlined), color: Neon.green, tooltip: 'Add folder')
          else
            TextButton.icon(onPressed: s.addFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 17), label: const Text('Folder')),
          // The mixer opens as a card over the tracks: the master and every track's strip (the Mixer workspace
          // folded into Arrange, #139).
          IconButton(key: const ValueKey('arrange-mixer'), onPressed: () => setState(() => mixerCard = !mixerCard),
            color: mixerCard ? Neon.blue : Neon.dim, icon: const Icon(Icons.tune), tooltip: 'Mixer'),
          IconButton(onPressed: () => setState(() => settings = !settings),
            color: settings ? Neon.blue : Neon.dim, icon: const Icon(Icons.settings_outlined), tooltip: 'Settings'),
          IconButton(onPressed: () => setState(() { cardsView = true; mixerCard = false; }),
            icon: const Icon(Icons.view_agenda_outlined), tooltip: 'Track cards'),
        ];
        if (narrow) {
          // The row scrolls; a fade at an edge says there is more past it (Mixer, Settings, Track cards).
          return ScrollFade(child: SingleChildScrollView(
            key: const ValueKey('arrange-toolbar'),
            scrollDirection: Axis.horizontal,
            child: Row(children: controls),
          ));
        }
        // Wide: the clip bar sits in the toolbar while clips are selected (owner, 2026-11-10: docs/reaper-flow.md).
        return Row(children: [
          const Text('ARRANGEMENT', style: TextStyle(
            color: Neon.dim, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: !clipsChosen ? const SizedBox.shrink()
              : SingleChildScrollView(scrollDirection: Axis.horizontal, child: _clipBar(docked: false)))),
          // The controls scroll sideways when the toolbar is just over the phone width.
          ConstrainedBox(constraints: BoxConstraints(maxWidth: math.max(0.0, constraints.maxWidth - 170)),
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true,
              child: Row(mainAxisSize: MainAxisSize.min, children: controls))),
        ]);
      }),
    );
  }

  Widget _clipBar({required bool docked}) => ClipBar(state: widget.state, docked: docked, selectMode: _selectMode,
    onSelectMode: (v) => setState(() => _selectMode = v),
    onProperties: () => showClipProperties(context, widget.state));

  Widget _tucked(Widget bar) {
    final shown = _sections?.barsShown;
    if (shown == null) return bar;
    return ValueListenableBuilder<bool>(valueListenable: shown,
      builder: (context, v, child) => TuckAway(shown: v || settings, child: child!), child: bar);
  }

  /// Time and height zoom: − and + glide a step, the sliders follow the finger (time on a log scale).
  Widget _zoomBar() {
    final ratio = math.log(maxZoom / minZoom);
    final h = _trackHeight;
    Widget icon(IconData i, String tip, VoidCallback onTap) => IconButton(onPressed: onTap, tooltip: tip,
        visualDensity: VisualDensity.compact, iconSize: 18, icon: Icon(i, color: Neon.dim));
    return SizedBox(height: 36, child: Row(key: const ValueKey('arrange-zoom-bar'), children: [
      const SizedBox(width: 6),
      const Tooltip(message: 'Time zoom', child: Icon(Icons.swap_horiz, size: 16, color: Neon.dim)),
      icon(Icons.remove, 'Zoom out', () => _animateViewTo(zoom: _zoomAim / 1.4)),
      Expanded(flex: 3, child: ResetOnDoubleTap(onReset: () => _animateViewTo(zoom: 18), child: Slider(key: const ValueKey('arrange-zoom-time'),
        value: (math.log(zoom / minZoom) / ratio).clamp(0.0, 1.0).toDouble(),
        onChanged: (v) { _glide.stop(); _setZoom(minZoom * math.exp(v * ratio)); }))),
      icon(Icons.add, 'Zoom in', () => _animateViewTo(zoom: _zoomAim * 1.4)),
      IconButton(key: const ValueKey('arrange-zoom-fit'), onPressed: _zoomToFit, tooltip: 'Zoom to fit the song',
        visualDensity: VisualDensity.compact, iconSize: 18, icon: const Icon(Icons.fit_screen, color: Neon.dim)),
      const SizedBox(width: 6),
      const Tooltip(message: 'Track height', child: Icon(Icons.swap_vert, size: 16, color: Neon.dim)),
      Expanded(flex: 2, child: ResetOnDoubleTap(onReset: () {
        widget.state.settings.update((x) => x.trackHeight = 0).then((_) { if (mounted) setState(() {}); });
      }, child: Slider(key: const ValueKey('arrange-zoom-height'),
        value: h.clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble(),
        min: Settings.minTrackHeight, max: Settings.maxTrackHeight,
        onChanged: (v) => setState(() => _dragTrackH = v),
        onChangeEnd: (_) => _saveHeaderSize()))),
    ]));
  }

  Widget _settingsPanel() {
    final s = widget.state;
    return Flexible(flex: 0, child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
      child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(10, 0, 10, 8), child: Column(children: [
        _ProjectSettings(state: s),
        // App-wide: how long-press menus open (owner: a list near the finger by default, a ring as a setting).
        Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
          const Expanded(child: Text('Long-press menus', style: TextStyle(color: Neon.dim))),
          SegmentedButton<LongPressMenuStyle>(
            key: const ValueKey('menu-style'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: LongPressMenuStyle.list, icon: Icon(Icons.list, size: 18), tooltip: 'List near the finger'),
              ButtonSegment(value: LongPressMenuStyle.ring, icon: Icon(Icons.donut_large, size: 18), tooltip: 'Ring'),
            ],
            selected: {s.settings.longPressMenu},
            onSelectionChanged: (v) => s.settings.update((x) => x.longPressMenu = v.first)
                .then((_) { if (mounted) setState(() {}); }),
          ),
        ])),
      ])),
    ));
  }

  /// The tracks and their lanes. [pinned]: the focus view's one track, without the empty space under it.
  /// The tracks shown at the last build (null before the first), and where each row stood: for edit animations.
  Set<String>? _knownTracks;
  final Map<String, (double, Object)> _rowMemory = {};

  Widget _timeline(BuildContext context, List<LayerDoc> layers, _TrackCallbacks callbacks, {bool pinned = false}) {
    final s = widget.state;
    final p = s.project;
    final stepW = zoom * (Neon.compact(context) ? 0.85 : 1.0);
    final trackHeight = _trackHeight;
    // The gap between tracks (Settings, chosen from the track height menu), so tracks don't sit on each other.
    final gap = pinned ? 0.0 : s.settings.trackGap;
    final headW = _headerWidth;
    if (!pinned) _stepW = stepW;
    // The song ends at its last clip or automation point (or the shortest length) and playback loops back there,
    // as in Reaper. The timeline always reaches 64 bars past it, so a clip can go anywhere and the song grows with it.
    final end = p.engineLoopSteps;
    // A few screens past the furthest of the song's end, the playhead and where the view has been: it never meets a
    // wall on the right (owner, 2026-11-11).
    final screens = 3 * MediaQuery.sizeOf(context).width / stepW;
    final reach = math.max(math.max(p.timelineSteps.toDouble(), end + 64.0 * p.stepsPerBar),
        math.max(s.playheadStep, _reachSteps) + screens);
    final width = math.max(560.0, math.min(p.maxArrangementSteps.toDouble(), reach) * stepW);
    // The ruler holds the bar numbers and loop range over the markers and regions: taller on a phone, for a finger.
    final ruler = pinned ? 20.0 : (_phone ? 44.0 : 36.0);
    final focusId = _focusId;
    final drag = pinned ? null : _drag;
    // The rows' total height, so the New track zone fills the rest of the view below the last track.
    // Each track's own row height (owner, 2026-11-11): its own height or the default, compact or thin.
    double rowH(LayerDoc l) => pinned ? trackHeight : _rowHeight(l);
    // A row's height glides to a new one (a collapse, a folder, the height menu; owner, 2026-11-11), in the lengths
    // edit-motion kind; the header and its lane glide together, and only they rebuild while it runs. A drag follows
    // the finger at once.
    final rowGlide = pinned || _dragTrackH != null || _rowDragId != null || EditMotion.fadeOnly(context) ? Duration.zero
        : EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero;
    // While it glides the row is laid out at the larger of its old and new heights and clipped to the height shown,
    // so a header's controls never squeeze.
    Widget glideRow(LayerDoc l, Widget Function(double h) build) {
      final target = rowH(l);
      return TweenAnimationBuilder<double>(
        tween: Tween(end: target), duration: rowGlide, curve: EditMotion.curve, onEnd: _rowsSettled,
        builder: (context, h, _) {
          if ((h - target).abs() < 0.01) return build(target);
          final room = math.max(h, target);
          return SizedBox(height: math.max(0.0, h), child: ClipRect(child: OverflowBox(alignment: Alignment.topCenter,
            minHeight: room, maxHeight: room, child: build(room))));
        });
    }
    // A track's automation lanes open and close by growing and shrinking under it, header and lanes together
    // (owner, 2026-11-11); once they have, the rows below take their places as they are.
    final lanesD = pinned ? null : EditMotion.of(context, EditMotionKind.lengths);
    Widget lanesReveal(LayerDoc l, Widget? lanes) {
      final open = lanes != null;
      if (_lanesSeen[l.id] != null && _lanesSeen[l.id] != open && lanesD != null) {
        Timer(lanesD + const Duration(milliseconds: 20), _rowsSettled);
      }
      _lanesSeen[l.id] = open;
      return AnimatedSwitcher(duration: lanesD ?? Duration.zero,
        switchInCurve: EditMotion.curve, switchOutCurve: EditMotion.exitCurve,
        transitionBuilder: (child, a) => SizeTransition(sizeFactor: a, alignment: Alignment.topCenter,
            child: FadeTransition(opacity: a, child: child)),
        child: lanes ?? const SizedBox(width: double.infinity));
    }
    // A thin row keeps its automation lanes closed.
    bool lanesOpen(LayerDoc l) => !pinned && l.showLanes && canHaveLanes(l) && _rowCollapse(l) != TrackCollapse.thin;
    final rows = layers.fold<double>(0, (h, l) => h + rowH(l) + (pinned ? 0 : (lanesOpen(l) ? lanesHeight(s, l) : 0) + l.spaceBelow) + gap);
    // Edit animations (owner, 2026-11-11): rows glide when tracks are added, deleted, reordered or nested, and a
    // track an edit added grows in. The first build, and the pinned track, just show what is there.
    final appearing = pinned || _knownTracks == null ? const <String>{}
        : {for (final l in layers) if (!_knownTracks!.contains(l.id)) l.id};
    if (!pinned) _knownTracks = {for (final l in layers) l.id};
    Widget row(String side, LayerDoc layer, List<Widget> children) => pinned
        ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children)
        : TrackRowMotion(key: ValueKey('row-$side-${layer.id}'), id: '$side:${layer.id}', memory: _rowMemory,
            epoch: (trackHeight, _rowGen), appear: appearing.contains(layer.id),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
              children: children));
    // Two fingers scroll by their average, so a pinch zooms without dragging the view; the pointers are read raw.
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(multitouchDragStrategy: MultitouchDragStrategy.averageBoundaryPointers),
      child: Listener(
      onPointerDown: (e) {
        _follow.hold();
        _glide.stop();
        _vGlide.stop();
        _touchDown(e, headW);
      },
      onPointerMove: (e) => _touchMove(e, headW),
      onPointerUp: (e) {
        _follow.release();
        _touchUp(e);
      },
      onPointerCancel: (e) {
        _follow.release();
        _touchUp(e);
      },
      onPointerSignal: (_) {
        _follow.touch();
        _glide.stop();
        _vGlide.stop();
      },
      onPointerPanZoomStart: (_) {
        _follow.hold();
        _glide.stop();
        _vGlide.stop();
      },
      onPointerPanZoomEnd: (_) => _follow.release(),
      child: LayoutBuilder(builder: (context, view) {
        // A pixel short of the view, so a few tracks still don't scroll (the lanes' column fills the view anyway).
        final zoneH = math.max(view.maxHeight - ruler - rows - 1, math.max(80.0, trackHeight * 1.5));
        // Repaint boundaries (#174): a scroll moves a layer already painted instead of repainting every track and
        // clip; only the grid and the ruler, which paint the visible span, repaint as the view moves.
        return SingleChildScrollView(key: drag?.vViewport, controller: drag?.vScroll, child: RepaintBoundary(child: Listener(
        onPointerSignal: (e) => _wheel(e, null),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Stack(children: [SizedBox(width: headW, child: Selected(
        select: () => (_headersRev, layers.length, zoneH),
        builder: (context) => Column(children: [
        SizedBox(height: ruler, child: Padding(
          padding: EdgeInsets.only(left: 10, top: pinned ? 4 : 8),
          child: Align(alignment: Alignment.centerLeft,
            child: Text(pinned ? 'FOCUS · swipe ‹ ›' : 'TRACKS',
              style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3))))),
        for (final layer in layers) row('h', layer, [
          glideRow(layer, (h) => _TimelineHeader(key: drag?.headerKey(layer.id), state: s, layer: layer,
            index: p.layers.indexOf(layer),
            taps: _headerTaps,
            drag: drag, onTrackDrag: drag == null ? null : (phase, at) => _trackDrag(layer, phase, at),
            depth: pinned ? 0 : s.folderDepth(layer), trackHeight: h,
            collapse: pinned ? TrackCollapse.normal : _rowCollapse(layer),
            // A narrow header stands its meter up; a phone's narrowest one drops a compact row's M and S until the
            // track is selected (owner, 2026-11-11).
            uprightMeter: headW < uprightMeterWidth,
            hideMuteSolo: _phone && headW <= Settings.minHeaderWidth + 0.5,
            pinned: pinned,
            focused: layer.id == focusId,
            // The pinned track: a tap goes back to all tracks, a sideways swipe to the next or previous one.
            onTap: pinned ? () => _focus(null) : () => callbacks.onTap(layer),
            onSwipe: pinned ? _step : null,
            onFx: () => callbacks.onFx(layer),
            onMenu: (at) => callbacks.onMenu(layer, at),
            onResize: pinned ? null : (dy) => _rowResize(layer, dy),
            onResizeEnd: _rowResizeEnd)),
          // The track's automation lanes, open under it (REAPER's envelope lanes, UG 18.16).
          if (!pinned) lanesReveal(layer, lanesOpen(layer) ? TrackLaneHeaders(key: ValueKey('lane-headers-${layer.id}'),
              state: s, layer: layer, indent: folderIndent(s.folderDepth(layer))) : null),
          if (layer.spaceBelow > 0 && !pinned) _SpacerHeader(state: s, layer: layer),
          SizedBox(height: gap),
        ]),
        if (drag != null) NewTrackZone(key: drag.newTrackHeader, state: s, drag: drag, height: zoneH, header: true),
      ]))),
        // The headers' right edge: drag it to make the headers narrower or wider (saved).
        Positioned(right: 0, top: 0, bottom: 0, width: 10, child: _ResizeGrip(
          key: const ValueKey('header-width-grip'), axis: Axis.horizontal, label: 'Resize track headers',
          onDrag: (dx) => setState(() => _dragHeaderW = (_headerWidth + dx)
              .clamp(Settings.minHeaderWidth, Settings.maxHeaderWidth).toDouble()),
          onEnd: _saveHeaderSize)),
      ]),
      Expanded(child: RepaintBoundary(child: SingleChildScrollView(key: drag?.hViewport, controller: _hScroll, scrollDirection: Axis.horizontal,
        child: Listener(
          onPointerSignal: (e) => _wheel(e, _hScroll.hasClients ? e.localPosition.dx - _hScroll.positions.last.pixels : null),
          // A time pinch scales the lanes as laid out ([_pinchTo]); at rest the transform is the identity.
          child: ValueListenableBuilder<Matrix4?>(valueListenable: _pinchView, builder: (context, m, child) =>
              Transform(transform: m ?? Matrix4.identity(), child: child),
            child: RepaintBoundary(child: SizedBox(key: pinned ? null : _lanesBox, width: width, child: Stack(children: [
          // One grid behind every track, through the gaps and spacers and down to the bottom of the view
          // below the last track (owner: like Reaper).
          Positioned(left: 0, right: 0, top: ruler, bottom: 0, child: IgnorePointer(child: RepaintBoundary(child: CustomPaint(
            painter: _ArrangementGrid(stepW, p.stepsPerBar, _hScroll))))),
          // The loop range's edges, down through the lanes while it is on.
          if (p.loopsRange) for (final at in [p.loopStartSteps, p.loopEndSteps])
            Positioned(left: at * stepW - 0.5, top: ruler, bottom: 0, width: 1, child: IgnorePointer(
              child: ColoredBox(color: Neon.blue.withValues(alpha: 0.45)))),
          // Where the song ends and playback loops back to the start.
          Positioned(left: end * stepW - 1, top: 0, bottom: 0, width: 2, child: IgnorePointer(
            child: Tooltip(message: 'Song end: playback loops back to the start',
              child: Container(color: Neon.pink.withValues(alpha: 0.7))))),
          ConstrainedBox(constraints: BoxConstraints(minHeight: pinned ? 0 : view.maxHeight), child: RepaintBoundary(child: Column(children: [
            RepaintBoundary(child: pinned
                ? SizedBox(height: ruler, width: width, child: CustomPaint(painter: _BarRuler(stepW, p.stepsPerBar, _hScroll)))
                : ArrangeRuler(state: s, stepW: stepW, width: width, height: ruler, scroll: _hScroll)),
            for (final layer in layers) row('l', layer, [
              glideRow(layer, (h) => _TimelineLane(key: drag?.laneKey(layer.id), state: s, layer: layer, width: width,
                stepW: stepW, trackHeight: h, selectedIds: s.selectedClipIds, callbacks: callbacks, drag: drag,
                thin: !pinned && _rowCollapse(layer) == TrackCollapse.thin)),
              if (!pinned) lanesReveal(layer, lanesOpen(layer)
                  ? TrackLaneRows(state: s, layer: layer, stepW: stepW, width: width) : null),
              // A spacer and the gap leave the timeline empty too, so lanes stay level with their headers.
              if (layer.spaceBelow > 0 && !pinned) SizedBox(height: layer.spaceBelow),
              SizedBox(height: gap),
            ]),
            if (drag != null) SizedBox(width: width,
              child: NewTrackZone(key: drag.newTrackLane, state: s, drag: drag, height: zoneH, stepW: stepW)),
          ]))),
          // One hint while no track holds a clip (owner, 2026-11-11), centred in the view below the ruler; it fades
          // out with the first clip.
          if (!pinned) Positioned(left: 10, top: ruler + (view.maxHeight - ruler) / 2 - 8, child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: EditMotion.of(context, EditMotionKind.panels) ?? Duration.zero,
              switchInCurve: EditMotion.curve, switchOutCurve: EditMotion.exitCurve,
              child: s.project.layers.any((l) => l.clips.isNotEmpty || l.audioClips.isNotEmpty)
                  ? const SizedBox.shrink()
                  : SizedBox(key: const ValueKey('arrange-hint'), height: 16, child: Text(
                      s.project.layers.every((l) => l.isFolder || l.isAudio)
                          ? 'Drop audio here, or arm the track and record'
                          : 'Double-tap for a clip, or drop a pattern here',
                      style: const TextStyle(color: Neon.dim, fontSize: 10)))))),
          // A live island (widgets.dart): the line moves on every frame while playing (live_playhead.dart), and
          // without it the timeline around it would lay out and repaint with it. Smooth follow scrolls in the same
          // frame, so the line holds still a third in.
          Positioned.fill(child: IgnorePointer(child: LiveIsland(child: PlayheadFrames(
            state: s,
            onFrame: () {
              if (s.settings.followSmooth) _followPlayhead();
            },
            builder: (context) {
              // Stopped, a dimmer line shows where play starts and Split cuts (REAPER's edit cursor).
              final playing = s.meters.playing && s.meters.loopLength > 0;
              return CustomPaint(painter: _PlayheadPainter(stepW,
                s.smoothPlayheadStep, stopped: !playing));
            },
          )))),
          if (!pinned) Positioned.fill(child: IgnorePointer(child: ValueListenableBuilder<Rect?>(
            valueListenable: _marquee,
            builder: (context, box, _) {
              final me = _lanesBox.currentContext?.findRenderObject();
              if (box == null || me is! RenderBox || !me.attached) return const SizedBox.shrink();
              final local = Rect.fromPoints(me.globalToLocal(box.topLeft), me.globalToLocal(box.bottomRight));
              return CustomPaint(painter: _MarqueePainter(local));
            }))),
        ])))))))),
    ]))));
      })));
  }

  Widget _arrangement(BuildContext context, _TrackCallbacks callbacks) {
    final s = widget.state;
    final tracks = s.project.layers.isEmpty
        ? _EmptyArrangement(onAdd: () { Haptics.tap(); s.addLayer(); }, onBrowse: () => setState(() => _browser = true))
        : _timeline(context, s.visibleLayers, callbacks);
    // The mixer card slides up over the tracks and back down (owner, 2026-11-11).
    return LayoutBuilder(builder: (context, box) => Stack(children: [
      Positioned.fill(child: tracks),
      Positioned(left: 6, right: 6, bottom: 6, height: math.min(box.maxHeight - 12, math.max(320.0, box.maxHeight * 0.86)),
        child: Presence(from: const Offset(0, 0.15), child: !mixerCard ? null
            : MixerCard(state: s, onClose: () => setState(() => mixerCard = false)))),
    ]));
  }
}

/// What a track header, lane or clip asks of the arranger.
class _TrackCallbacks {
  const _TrackCallbacks({required this.onTap, required this.onFx, required this.onMenu, required this.onClipMenu,
    required this.onClipOpen, required this.selectMode, required this.onMarquee, this.onAudioOpen});
  final ValueChanged<LayerDoc> onTap, onFx;
  final void Function(LayerDoc layer, Offset at) onMenu;
  final void Function(LayerDoc layer, ClipDoc clip, Offset at) onClipMenu;

  /// A tap on the selected MIDI clip, or a mouse's double-click on one: its notes, in the focus panel's Clip tab.
  final void Function(LayerDoc layer, ClipDoc clip) onClipOpen;

  /// A tap on the selected audio clip, its double-click, or its menu's Clip settings…: the track's Clip tab.
  final void Function(LayerDoc layer)? onAudioOpen;

  /// Whether Select mode is on: a tap on a clip adds or removes it, a long-press drag in a lane draws a box.
  final bool Function() selectMode;

  /// A marquee's start, move and end, in global coordinates; [additive] adds to the selection.
  final void Function(_Marquee phase, Offset at, bool additive) onMarquee;
}

enum _Marquee { start, move, end }

/// A compact track header (owner, 2026-11-09): name, M, S and FX always show; record-arm, input, the instrument and
/// the rest are in the track menu (a hold, or right-click on a desktop). A tap focuses the track, a double tap opens
/// its effects. The selected or focused track glows in its own colour, brighter. Its row is normal, compact (the name,
/// M and S in one row) or a thin bar ([TrackCollapse]; owner, 2026-11-11).
class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader({super.key, required this.state, required this.layer, required this.index, required this.depth,
    required this.taps,
    required this.trackHeight, required this.onTap, required this.onFx, required this.onMenu,
    this.collapse = TrackCollapse.normal, this.uprightMeter = false, this.hideMuteSolo = false, this.pinned = false,
    this.focused = false, this.onSwipe, this.onResize, this.onResizeEnd, this.drag,
    this.onTrackDrag});
  final AppState state;
  final LayerDoc layer;
  final int index, depth;

  /// The row's height (the track's own, the default, or its compact or thin height).
  final double trackHeight;
  final TrackCollapse collapse;

  /// The meter stands upright at the header's edge (a narrow header).
  final bool uprightMeter;

  /// A compact row at a phone's narrowest header width: M and S show only on the selected or focused track.
  final bool hideMuteSolo;

  /// The focus view's pinned track: a second tap anywhere on it is a double tap (the first tap moved it here).
  final bool pinned;
  final bool focused;
  final VoidCallback onTap, onFx;
  final void Function(Offset at) onMenu;
  final ClickCounter taps;
  final ValueChanged<int>? onSwipe;

  /// A drag on the row's bottom edge, by this many pixels; null on the focus view's pinned track.
  final ValueChanged<double>? onResize;
  final VoidCallback? onResizeEnd;

  /// Dragging the header moves the track (REAPER): a long press picks it up on a touch screen (released without
  /// moving, it opens the track menu), a plain drag with a mouse. Null on the pinned track.
  final ArrangeDrag? drag;
  final void Function(_HeaderPhase phase, Offset at)? onTrackDrag;

  @override
  Widget build(BuildContext context) {
    final color = trackColor(state, layer);
    final selected = focused || state.selectedLayerId == layer.id;
    final fxCount = layer.components.length;
    final low = trackHeight < 52;
    // REAPER-style (owner, 2026-11-10): the track's colour tints the whole header and its left edge, no outline.
    final edge = BorderSide(color: selected ? color : color.withValues(alpha: 0.75), width: selected ? 4 : 3);
    final compact = collapse == TrackCollapse.compact;
    final Widget box;
    if (collapse == TrackCollapse.thin) {
      // A sliver in the track's colour, indented like the track's header; still tapped, held and dragged.
      box = Container(key: ValueKey('thin-track-${layer.id}'), height: trackHeight, width: double.infinity,
        padding: EdgeInsets.only(left: folderIndent(depth)),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Neon.bg))),
        child: ColoredBox(color: color.withValues(alpha: selected ? 0.95 : 0.55)));
    } else {
      box = Container(height: trackHeight,
      padding: EdgeInsets.fromLTRB(6 + folderIndent(depth), compact || low ? 2 : 4, 2, compact || low ? 2 : 4),
      decoration: Glass.active
          ? BoxDecoration(
              gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [
                Color.lerp(Neon.panel, color, selected ? 0.42 : 0.26)!.withValues(alpha: 0.82),
                Color.lerp(Neon.panel, color, selected ? 0.20 : 0.10)!.withValues(alpha: 0.66),
              ]),
              border: Border(
                left: edge,
                bottom: BorderSide(color: Neon.bg.withValues(alpha: 0.6)),
                right: BorderSide(color: Neon.ink.withValues(alpha: 0.05)),
              ),
              boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.28), blurRadius: 12)] : null)
          : BoxDecoration(color: Color.lerp(Neon.panel, color, selected ? 0.30 : 0.16),
              border: Border(left: edge, bottom: const BorderSide(color: Neon.bg))),
      child: LayoutBuilder(builder: (context, box) {
        final oneRow = box.maxHeight < 56;
        final chip = compact || box.maxWidth < 86 ? 20.0 : box.maxWidth < 150 ? 24.0 : 30.0;
        final mute = _button(ToggleChip(label: 'M', size: chip, tooltip: layer.isFolder ? 'Mute folder' : 'Mute',
            on: layer.mute, color: Neon.yellow,
            onTap: () => layer.isFolder
                ? state.editLayer(layer, (l) => l.mute = !l.mute)
                : state.mixLayer(layer, mute: !layer.mute)));
        final solo = _button(ToggleChip(label: 'S', size: chip, tooltip: layer.isFolder ? 'Solo folder' : 'Solo',
            on: layer.solo, color: Neon.blue,
            onTap: () => layer.isFolder
                ? state.editLayer(layer, (l) => l.solo = !l.solo)
                : state.mixLayer(layer, solo: !layer.solo)));
        // A stereo track (a native instrument or effect, or a folder) meters each side; an empty track one bar.
        // An armed audio track shows its input's level instead (REAPER's record-armed meter).
        final armed = layer.input?.armed ?? false;
        final meter = armed
            ? Center(child: AudioInputMeter(layer: layer, height: low ? 5 : 7))
            : TrackMeter(key: ValueKey('meter-${layer.id}'), state: state, index: index, stereo: layer.isStereo,
                color: color);
        // Upright (a narrow header, or a compact row): a thin bar at the header's right edge, a live island of a
        // fixed size like the sideways one (owner, 2026-11-11).
        final standUp = uprightMeter || collapse != TrackCollapse.normal;
        final upright = Padding(
          padding: const EdgeInsets.only(left: 3, right: 1),
          child: SizedBox(key: ValueKey('upright-meter-${layer.id}'), width: layer.isStereo || armed ? 7 : 4,
            height: box.maxHeight, child: armed
                ? RotatedBox(quarterTurns: 3, child: AudioInputMeter(layer: layer, height: 7))
                : LiveIsland(child: TrackMeter(key: ValueKey('meter-${layer.id}'), state: state, index: index,
                    stereo: layer.isStereo, color: color, vertical: true))));
        // FX: drawn at 18 dp, touched over about 34 dp; a dot tells the track has effects. A very narrow header
        // drops it: a tap on the header opens the track's effects too.
        final showFx = box.maxWidth - (uprightMeter || collapse != TrackCollapse.normal ? 11 : 0) >= 104;
        final fx = layer.isFolder
            ? Tooltip(message: layer.busEnabled ? 'Folder with a group bus' : 'Folder',
                child: SizedBox(width: 26, height: 26, child: Icon(Icons.account_tree_outlined, size: 15, color: color)))
            : _button(Tooltip(message: fxCount > 0 ? 'Effects ($fxCount)' : 'Effects', child: InkResponse(
                key: ValueKey('fx-button-${layer.id}'),
                radius: 20,
                onTap: () {
                  Haptics.tap();
                  onFx();
                },
                child: Pressable(glow: color, child: SizedBox(width: 30, height: 26, child: Stack(alignment: Alignment.center, children: [
                  Icon(Icons.graphic_eq, size: 18, color: fxCount > 0 ? color : Neon.dim),
                  if (fxCount > 0) Positioned(right: 3, top: 2, child: Container(width: 5, height: 5,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
                ]))))));
        // The envelope button (REAPER's, UG 18.16): opens the track's automation lanes under it; lit while open,
        // a dot while they are closed but there are some.
        final laneCount = canHaveLanes(layer) ? arrangeLanes(state, layer).length : 0;
        Widget? lanesButton(double w, double h) => !canHaveLanes(layer) || onTrackDrag == null ? null : _button(Tooltip(
          message: layer.showLanes ? 'Hide automation lanes' : 'Show automation lanes',
          child: InkResponse(key: ValueKey('lanes-button-${layer.id}'), radius: 18,
            onTap: () {
              Haptics.tap();
              state.setLanesShown(layer, !layer.showLanes);
            },
            child: Pressable(glow: Neon.blue, child: SizedBox(width: w, height: h, child: Stack(alignment: Alignment.center, children: [
              Icon(layer.showLanes ? Icons.keyboard_arrow_down : Icons.show_chart, size: math.min(17, h),
                color: layer.showLanes ? Neon.blue : laneCount > 0 ? color : Neon.dim),
              if (!layer.showLanes && laneCount > 0) Positioned(right: 2, top: 2, child: Container(width: 5, height: 5,
                decoration: const BoxDecoration(color: Neon.blue, shape: BoxShape.circle))),
            ]))))));
        // What the content has beside an upright meter.
        final w = box.maxWidth - (standUp ? 11 : 0);
        // A control that drops or comes back as the header narrows or shortens fades and scales (owner, 2026-11-11).
        Widget pop(String id, bool show, Widget child) => _HeaderPop(key: ValueKey('pop-$id-${layer.id}'), show: show,
            child: child);
        final chevron = !layer.isFolder ? null
            : _button(IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              key: ValueKey('folder-chevron-${layer.id}'),
              // 24 px wide: a padded 48 px target overflowed a phone's one-row folder header.
              style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              tooltip: layer.collapsed ? 'Open folder' : 'Collapse folder',
              icon: Icon(layer.collapsed ? Icons.chevron_right : Icons.expand_more, color: color, size: 18),
              onPressed: () => state.setFolderCollapsed(layer, !layer.collapsed)));
        // The name's tooltip shows on hover only: a finger's hold on it opens the track menu.
        final name = Expanded(child: Tooltip(triggerMode: TooltipTriggerMode.manual,
            message: layer.isFolder
                ? (layer.busEnabled ? 'Folder with a group bus' : 'Folder')
                : layer.isAudio ? 'Audio track · ${layer.input?.label ?? 'no input'} · hold for more'
                : 'Instrument: ${layer.instrument != null ? state.componentInfo(layer.instrument!.id)?.label ?? layer.instrument!.id
                    : 'none'} · hold for more',
            child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: Color.lerp(Neon.text, color, selected ? 0.35 : 0.15)))));
        // The upright meter and the sideways one cross-fade as the header crosses the width.
        // M and S beside the name need their chips, the folder's chevron and a little of the name.
        final msRoom = (layer.isFolder ? 27 : 3) + 2 * chip + 2 + 14;
        Widget withMeter(Widget content) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: content), pop('upright', standUp, upright)]);
        if (compact) {
          // The name, M and S in one row; at a phone's narrowest width M and S wait for the track to be selected.
          final ms = !hideMuteSolo || selected;
          return withMeter(SizedBox(height: box.maxHeight, child: Row(children: [
            ?chevron,
            const SizedBox(width: 3),
            name,
            pop('ms', ms && w >= msRoom, Row(mainAxisSize: MainAxisSize.min, children: [mute, const SizedBox(width: 2), solo])),
          ])));
        }
        final top = SizedBox(height: low ? 24 : 28, child: Row(children: [
          ?chevron,
          const SizedBox(width: 3),
          name,
          // A deep folder's header can get narrow: M and S move to their own row's place, the icons go first.
          if (oneRow) pop('ms', w >= msRoom, Row(mainAxisSize: MainAxisSize.min, children: [mute, const SizedBox(width: 2), solo])),
          // Arm sits by the name when the header has room for both; a phone's one-row header puts it by the meter.
          if (layer.isAudio && !oneRow) _button(AudioArmButton(state: state, layer: layer, size: chip)),
          // A folder's icon only says what it is: a narrow header gives its room to the name.
          pop('fx', showFx && (!layer.isFolder || w >= 140), fx),
        ]));
        if (oneRow) {
          // One row (a phone's default height): the envelope button sits at the meter's end, as high as the room
          // under the name allows.
          final room = box.maxHeight - (low ? 26 : 32);
          final lanes = room >= 12 ? lanesButton(30, math.min(18.0, room)) : null;
          final arm = layer.isAudio ? _button(AudioArmButton(state: state, layer: layer, size: math.max(12.0, math.min(18.0, room)))) : null;
          final under = standUp
              ? (lanes == null && arm == null ? null : Row(children: [?arm, const Spacer(), ?lanes]))
              : lanes == null && arm == null ? meter : Row(children: [?arm, Expanded(child: meter), ?lanes]);
          return withMeter(Column(mainAxisSize: MainAxisSize.min, children: [top,
            if (under != null) ...[SizedBox(height: low ? 2 : 4), under]]));
        }
        final lanes = lanesButton(26, 26);
        return withMeter(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          top,
          const SizedBox(height: 4),
          SizedBox(height: 26, child: Row(children: [
            mute,
            const SizedBox(width: 3),
            solo,
            const SizedBox(width: 8),
            Expanded(child: pop('meter', !standUp, meter)),
            // A very narrow header leaves it to the long-press menu's Show automation lanes.
            if (lanes != null && w >= 100) lanes else const SizedBox(width: 4),
          ])),
        ]));
      }),
    );
    }
    // Where a dragged track would land on this one: a line above or below it, or the folder lit up.
    final target = drag == null ? box : ValueListenableBuilder<DragSpot?>(
      valueListenable: drag!.hover,
      builder: (context, spot, child) {
        final here = drag!.active && spot?.layerId == layer.id && drag!.dragsTrack;
        if (!here) return child!;
        final into = spot!.where == TrackDrop.into;
        return Stack(children: [
          child!,
          // Nesting: the parent-to-be lights up, and an indented line under it shows the track landing one level in.
          if (into) ...[
            Positioned.fill(child: IgnorePointer(child: DecoratedBox(key: const ValueKey('track-drop-into'),
              decoration: BoxDecoration(border: Border.all(color: Neon.green, width: 2),
                color: Neon.green.withValues(alpha: 0.12))))),
            Positioned(left: 6 + folderIndent(depth + 1), right: 0, bottom: 0, height: 3,
              child: IgnorePointer(child: Container(key: const ValueKey('track-drop-into-line'), color: Neon.green))),
            Positioned(right: 4, top: 2, child: IgnorePointer(child: Icon(Icons.subdirectory_arrow_right,
              key: const ValueKey('track-drop-into-icon'), size: 16, color: Neon.green))),
          ] else Positioned(left: 0, right: 0, height: 3, top: spot.where == TrackDrop.above ? 0 : null,
            bottom: spot.where == TrackDrop.below ? 0 : null,
            child: IgnorePointer(child: Container(key: const ValueKey('track-drop-line'), color: Neon.green))),
        ]);
      },
      child: box);
    // One thin line per folder above, in that folder's colour (REAPER's nested folder indent, UG 5.13.5).
    final ancestors = <LayerDoc>[];
    for (var id = layer.parentId; id != null && ancestors.length < depth;) {
      final folder = state.project.layers.where((l) => l.id == id).firstOrNull;
      if (folder == null) break;
      ancestors.insert(0, folder);
      id = folder.parentId;
    }
    final guided = ancestors.isEmpty ? target : Stack(children: [
      target,
      for (var i = 0; i < ancestors.length; i++)
        Positioned(left: folderIndent(i + 1) - 4, top: 0, bottom: 0, width: 1.5,
          child: IgnorePointer(child: ColoredBox(key: ValueKey('folder-guide-${layer.id}-$i'),
            color: trackColor(state, ancestors[i]).withValues(alpha: 0.55)))),
    ]);
    final resizable = onResize == null ? guided : Stack(children: [
      guided,
      // The row's bottom edge: drag it to make this track thinner or taller, through compact and thin (saved);
      // with Shift, every track's default height. A thin bar is all edge.
      Positioned(left: 0, right: 0, bottom: 0, height: math.min(8.0, trackHeight), child: _ResizeGrip(
        key: ValueKey('track-height-grip-${layer.id}'), axis: Axis.vertical, label: 'Resize track',
        onDrag: onResize!, onEnd: onResizeEnd ?? () {})),
    ]);
    return Semantics(
      button: true,
      selected: selected,
      label: '${layer.name} track',
      // A tap focuses the track at once; a quick second tap switches the focus view to its effects (owner,
      // 2026-11-11), with no double tap in the gesture arena to hold the first back. The first tap moves the track
      // (the pinned track goes to the top), so a second tap anywhere on the pinned track counts. A hold opens the
      // menu when let go without moving and picks the track up when it moves (on the pinned track, which can't move,
      // it opens the menu). The outermost pointer handler sees a press last: a press on one of the header's buttons
      // (M, S, FX, the arrows) isn't counted, and it clears the mark the button left.
      child: Listener(onPointerDown: (e) {
        _onHeaderButton ? taps.reset() : taps.down(e, target: layer.id, anywhere: pinned);
        _onHeaderButton = false;
      }, onPointerUp: taps.up, child: GestureDetector(
        key: ValueKey('track-header-${layer.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => taps.twice ? onFx() : onTap(),
        onLongPressStart: (d) => onTrackDrag == null ? onMenu(d.globalPosition) : onTrackDrag!(_HeaderPhase.press, d.globalPosition),
        onLongPressMoveUpdate: onTrackDrag == null ? null : (d) => onTrackDrag!(_HeaderPhase.move, d.globalPosition),
        onLongPressEnd: onTrackDrag == null ? null : (d) => onTrackDrag!(_HeaderPhase.release, d.globalPosition),
        onLongPressCancel: onTrackDrag == null ? null : () => onTrackDrag!(_HeaderPhase.cancel, Offset.zero),
        onSecondaryTapUp: (d) => onMenu(d.globalPosition),
        onHorizontalDragEnd: onSwipe == null ? null : (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() > 200) onSwipe!(v < 0 ? 1 : -1);
        },
        // A mouse drags the header straight away; a finger's vertical drag still scrolls the tracks.
        child: onTrackDrag == null ? resizable : GestureDetector(
          supportedDevices: const {PointerDeviceKind.mouse},
          onVerticalDragStart: (d) => onTrackDrag!(_HeaderPhase.grab, d.globalPosition),
          onVerticalDragUpdate: (d) => onTrackDrag!(_HeaderPhase.move, d.globalPosition),
          onVerticalDragEnd: (_) => onTrackDrag!(_HeaderPhase.release, Offset.zero),
          onVerticalDragCancel: () => onTrackDrag!(_HeaderPhase.cancel, Offset.zero),
          child: resizable),
      )),
    );
  }

  /// One of the header's own buttons: a press on it marks [_onHeaderButton], so it doesn't count as a header tap.
  static Widget _button(Widget child) => Listener(onPointerDown: (_) => _onHeaderButton = true, child: child);
}

/// A press went down on a header's button (set by the button, cleared by the header's outermost handler, which
/// sees the press last).
bool _onHeaderButton = false;

double _gainDb(double g) => g <= 0.001 ? -60 : (20 * math.log(g) / math.ln10).clamp(-60.0, 12.0).toDouble();
double _dbGain(double db) => db <= -60 ? 0 : math.pow(10, db / 20).toDouble();

/// Where a dragged track height lands: thin below halfway to compact, compact below halfway to the shortest normal
/// row, else a normal row of that height.
(TrackCollapse, double) trackRowSnap(double raw) {
  if (raw < (LayerDoc.thinHeight + LayerDoc.compactHeight) / 2) return (TrackCollapse.thin, LayerDoc.thinHeight);
  if (raw < (LayerDoc.compactHeight + LayerDoc.minHeight) / 2) return (TrackCollapse.compact, LayerDoc.compactHeight);
  return (TrackCollapse.normal, raw.clamp(LayerDoc.minHeight, LayerDoc.maxHeight).toDouble());
}

/// A header control that drops ([show] false) or comes back as the header narrows or shortens: it fades and scales
/// out and in, in the lengths edit-motion kind (a fade alone with Reduced motion, at once with motion Off).
class _HeaderPop extends StatelessWidget {
  const _HeaderPop({super.key, required this.show, required this.child});
  final bool show;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero;
    final fade = EditMotion.fadeOnly(context);
    return AnimatedSwitcher(duration: d, switchInCurve: EditMotion.curve, switchOutCurve: EditMotion.exitCurve,
      // The header lays out for what shows now; a control on its way out fades over its neighbours.
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none,
          children: [for (final p in previous) Positioned(left: 0, child: p), ?current]),
      transitionBuilder: (child, a) => FadeTransition(opacity: a,
          child: fade ? child : ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(a), child: child)),
      child: show ? KeyedSubtree(key: const ValueKey(true), child: child) : const SizedBox.shrink(key: ValueKey(false)));
  }
}

/// Below this header width a track's meter stands upright at the header's edge (owner, 2026-11-11).
const uprightMeterWidth = 120.0;

/// How far a track [depth] folders down is indented: 10 px a level for four levels, then 3 px a level up to
/// 60 px, so a deep tree still leaves a phone's narrow header room for the name.
double folderIndent(int depth) => depth <= 4 ? depth * 10.0 : math.min(60.0, 40.0 + (depth - 4) * 3.0);

/// A track header's drag, as the header reports it: a long press ([press]) that may become a drag once it moves, or
/// a mouse drag ([grab]) that is one at once.
enum _HeaderPhase { press, grab, move, release, cancel }

/// A thin edge that resizes something when dragged: a faint grip line shows where it is, and the mouse cursor
/// changes over it on a desktop.
class _ResizeGrip extends StatefulWidget {
  const _ResizeGrip({super.key, required this.axis, required this.label, required this.onDrag, required this.onEnd});

  /// [Axis.horizontal]: dragged sideways (a width); [Axis.vertical]: dragged up and down (a height).
  final Axis axis;
  final String label;
  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;
  @override
  State<_ResizeGrip> createState() => _ResizeGripState();
}

class _ResizeGripState extends State<_ResizeGrip> with GrabFeedback {
  @override
  Widget build(BuildContext context) {
    final sideways = widget.axis == Axis.horizontal;
    // The shared grip (feedback.dart): it grows and lights when grabbed, with a haptic grab and drop.
    final line = GripMark(axis: widget.axis, grabbed: grabbed, hovered: hovered, length: 22,
      restColor: Neon.dim.withValues(alpha: 0.35), restThickness: 2);
    void start() => grab();
    void update(double d) => widget.onDrag(d);
    void end() { release(); widget.onEnd(); }
    // The tooltip shows on hover only: a finger's hold belongs to what is under the grip (a thin track's menu).
    return Semantics(label: widget.label, child: Tooltip(message: widget.label, waitDuration: const Duration(milliseconds: 600),
      triggerMode: TooltipTriggerMode.manual,
      child: MouseRegion(
        cursor: sideways ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        onEnter: (_) => hover(true),
        onExit: (_) => hover(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The edge follows the finger from where it went down, slop included.
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: sideways ? (_) => start() : null,
          onHorizontalDragUpdate: sideways ? (d) => update(d.delta.dx) : null,
          onHorizontalDragEnd: sideways ? (_) => end() : null,
          onVerticalDragStart: sideways ? null : (_) => start(),
          onVerticalDragUpdate: sideways ? null : (d) => update(d.delta.dy),
          onVerticalDragEnd: sideways ? null : (_) => end(),
          child: Align(alignment: sideways ? Alignment.center : Alignment.bottomCenter, child: line)))));
  }
}

/// The space above and below a clip in its row.
double _clipInset(double trackHeight) => trackHeight < 60 ? 3 : 8;

class _TimelineLane extends StatefulWidget {
  const _TimelineLane({super.key, required this.state, required this.layer, required this.width,
    required this.stepW, required this.trackHeight, required this.selectedIds, required this.callbacks, this.drag,
    this.thin = false});
  final AppState state;
  final LayerDoc layer;
  final double width, stepW, trackHeight;

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
            for (final clip in layer.clips) (clip.startSteps.toDouble(), clip.lengthSteps.toDouble(),
                (clip.color == null ? color : Neon.layer(clip.color!)).withValues(alpha: clip.mute ? 0.3 : 0.8)),
            for (final clip in layer.audioClips) (clip.startSteps.toDouble(), clip.lengthAt(state.project.bpm),
                audioClipColor(state, layer, clip).withValues(alpha: clip.mute ? 0.3 : 0.8)),
          ], stepW, inset: thin ? 1 : _clipInset(trackHeight)))))),
        if (thin) for (final clip in layer.clips) Positioned(left: clip.startSteps * stepW, top: 0, width: 1, height: 1,
            child: SizedBox(key: ValueKey('thin-clip-${clip.id}'))),
      ] else ...[
      for (final clip in layer.clips) () {
        final rect = Rect.fromLTWH(clip.startSteps * stepW, _clipInset(trackHeight),
            math.max(12.0, clip.lengthSteps * stepW), trackHeight - 2 * _clipInset(trackHeight));
        final clipColor = clip.color == null ? color : Neon.layer(clip.color!);
        _seen[clip.id] = (rect, clipColor, state.clipName(clip));
        return ClipSlot(key: ValueKey('clip-slot-${clip.id}'), id: clip.id, rect: rect, scale: (stepW, trackHeight),
          appear: appearing.contains(clip.id),
          child: _TimelineClip(state: state, layer: layer, clip: clip, stepW: stepW, drag: widget.drag,
            height: rect.height, color: clipColor,
            selected: widget.selectedIds.contains(clip.id), callbacks: widget.callbacks));
      }(),
      for (final MapEntry(key: id, value: (rect, leftColor, name)) in _leaving.entries)
        LeavingClip(key: ValueKey('clip-leaving-$id'), rect: rect, color: leftColor, name: name,
          duration: leaving!, onDone: () { if (mounted) setState(() => _leaving.remove(id)); }),
      // Audio clips (API 18): an audio track's clips, with their own handles (audio_clip_view.dart).
      for (final clip in layer.audioClips)
        Positioned(left: clip.startSteps * stepW, top: _clipInset(trackHeight),
          width: math.max(12.0, clip.lengthAt(state.project.bpm) * stepW),
          height: trackHeight - 2 * _clipInset(trackHeight),
          child: AudioClipView(key: ValueKey('audio-view-${clip.id}'), state: state, layer: layer, clip: clip,
            stepW: stepW, drag: widget.drag, height: trackHeight - 2 * _clipInset(trackHeight),
            color: audioClipColor(state, layer, clip), selected: widget.selectedIds.contains(clip.id),
            selectMode: widget.callbacks.selectMode, onOpen: () => widget.callbacks.onAudioOpen?.call(layer))),
      ],
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
/// The part of a timeline [size] wide that [scroll] shows, in pixels (all of it, up to 4096 px, before layout),
/// widened by [arrangeSpanReveal] during a time pinch.
(double, double) visibleSpan(ScrollController scroll, Size size) {
  if (!scroll.hasClients) return (0, math.min(size.width, 4096));
  // While the focus view swaps one timeline for another, the old one is attached for a frame too: use the newest.
  final position = scroll.positions.last;
  final reveal = position.viewportDimension * arrangeSpanReveal.value; // a time pinch's margin (ruler.dart)
  final from = (position.pixels - reveal).clamp(0.0, size.width).toDouble();
  return (from, (position.pixels + position.viewportDimension + reveal).clamp(from, size.width).toDouble());
}

/// A lane's clips as plain blocks (a thin row, or zoomed far out): one rectangle per pixel column at most, so a long
/// song's thousands of clips cost a few hundred rectangles.
class _ClipBlocksPainter extends CustomPainter {
  _ClipBlocksPainter(this.clips, this.stepW, {required this.inset});
  final List<(double start, double length, Color color)> clips;
  final double stepW, inset;

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
  }

  @override
  bool shouldRepaint(covariant _ClipBlocksPainter old) =>
      old.stepW != stepW || old.inset != inset || old.clips.length != clips.length ||
      [for (var i = 0; i < clips.length; i++) old.clips[i] != clips[i]].any((d) => d);
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
  _ArrangementGrid(this.stepW, this.barSteps, this.scroll)
      : super(repaint: Listenable.merge([scroll, arrangeSpanReveal]));
  final double stepW;
  final int barSteps;
  final ScrollController scroll;
  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()..color = Neon.line.withValues(alpha: .55)..strokeWidth = .6;
    final major = Paint()..color = Neon.dim.withValues(alpha: .35)..strokeWidth = 1;
    final (from, to) = visibleSpan(scroll, size);
    // Zoomed out, the minor lines thin to beats, then to bars, then every 4, 16, 64… bars, so they stay at least
    // 5 px apart and nothing is drawn per bar however far out (owner, 2026-11-11).
    final every = arrangeGridEvery(stepW, barSteps);
    for (var n = (from / stepW / every).floor() * every; n * stepW <= to; n += every) {
      final x = n * stepW;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), n % barSteps == 0 ? major : minor);
    }
  }
  @override
  bool shouldRepaint(covariant _ArrangementGrid old) =>
      old.stepW != stepW || old.barSteps != barSteps || old.scroll != scroll;
}

class _BarRuler extends CustomPainter {
  _BarRuler(this.stepW, this.barSteps, this.scroll) : super(repaint: Listenable.merge([scroll, arrangeSpanReveal]));
  final double stepW;
  final int barSteps;
  final ScrollController scroll;
  @override
  void paint(Canvas canvas, Size size) {
    final barW = barSteps * stepW;
    final (from, to) = visibleSpan(scroll, size);
    // A label every bar, or every 4, 16, 64… bars when bars are narrower than a label.
    var every = 1;
    while (every * barW < 28 && every < 1 << 30) {
      every *= 4;
    }
    for (var b = (from / barW / every).floor() * every; b * barW <= to; b += every) {
      final label = TextPainter(text: TextSpan(text: '${b + 1}', style: Neon.code(size: 10, color: Neon.dim)),
        textDirection: TextDirection.ltr, maxLines: 1)..layout(maxWidth: math.max(1.0, every * barW - 2));
      label.paint(canvas, Offset(b * barW, (size.height - label.height) / 2));
      label.dispose();
    }
  }
  @override
  bool shouldRepaint(covariant _BarRuler old) => old.stepW != stepW || old.barSteps != barSteps || old.scroll != scroll;
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


class _TimelineClip extends StatefulWidget {
  const _TimelineClip({required this.state, required this.layer, required this.clip,
    required this.stepW, required this.color, required this.selected, required this.callbacks, this.drag,
    this.height = 60});
  final AppState state;
  final LayerDoc layer;
  final ClipDoc clip;
  final double stepW, height;
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
    final raw = ((dx + _scrolled) / widget.stepW).round();
    if (sourceDragging) return _free ? raw : (raw / _snap).round() * _snap;
    final rawStart = widget.clip.startSteps + raw;
    final at = _free ? rawStart : (rawStart / _snap).round() * _snap;
    // Never before the project's start (nor past its end).
    return at.clamp(0, math.max(0, widget.state.project.maxArrangementSteps - widget.clip.lengthSteps)).toInt();
  }

  /// Where a left-edge trim puts the clip's start.
  int _trimTarget() {
    final raw = widget.clip.startSteps + (trimDx / widget.stepW).round();
    return _free ? raw : (raw / _snap).round() * _snap;
  }

  /// A light tick each time the clip lands on another grid line (owner: haptics on grid snaps).
  void _tickOnSnap(int at) {
    if (_lastSnap != null && _lastSnap != at) Motion.tick();
    _lastSnap = at;
  }

  /// A finger's tap on the selected clip: its notes open once the double-tap window has passed.
  Timer? _opening;

  @override
  void dispose() {
    _opening?.cancel();
    _removeGhost();
    _ghostState.dispose();
    super.dispose();
  }

  void _removeGhost() {
    _ghost?.remove();
    _ghost = null;
  }

  void _start(DragStartDetails d) => _begin(d.globalPosition);

  /// A long press picks the clip up: a tick, and its ghost at once; moving carries it in time and across tracks.
  void _lift(LongPressStartDetails d) {
    if ((_drag?.pinching ?? false) || widget.clip.lock || dragging) return;
    Motion.tick();
    _begin(d.globalPosition, lift: true);
  }

  void _liftMove(LongPressMoveUpdateDetails d) {
    if (!_lifted) return;
    _moveTo(d.globalPosition);
  }

  void _liftEnd(LongPressEndDetails _) {
    if (_lifted) _end(null);
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
      rect: Rect.fromLTWH(lane.left + at * widget.stepW, lane.top + (spot?.newTrack ?? false ? 4 : inset),
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

  void _finish() {
    _removeGhost();
    _ghostState.value = null;
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
      onLongPressMoveUpdate: _liftMove,
      onLongPressEnd: _liftEnd,
      onHorizontalDragStart: (_) => setState(() {
        if (left) { trimming = true; trimDx = 0; } else { resizing = true; resizeDx = 0; }
        _lastSnap = null;
      }),
      onHorizontalDragUpdate: (d) => setState(() {
        final c = widget.clip;
        if (left) {
          trimDx += d.delta.dx;
          _tickOnSnap(_trimTarget());
        } else {
          resizeDx += d.delta.dx;
          final raw = c.lengthSteps + (resizeDx / widget.stepW).round();
          _tickOnSnap(_free ? raw : (raw / _snap).round() * _snap);
        }
      }),
      onHorizontalDragEnd: (_) {
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

  int _resizedLength() {
    final c = widget.clip;
    final rawLength = c.lengthSteps + (resizing ? (resizeDx / widget.stepW).round() : 0);
    return (resizing && !_free ? math.max(_snap, (rawLength / _snap).round() * _snap) : rawLength)
        .clamp(1, widget.state.project.maxArrangementSteps - c.startSteps).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    var start = c.startSteps, length = _resizedLength();
    if (trimming) {
      final end = c.startSteps + c.lengthSteps;
      start = _trimTarget().clamp(math.max(0, c.startSteps - c.sourceOffsetSteps), end - 1).toInt();
      length = end - start;
    }
    final name = _name;
    // The notes sit under the name when the clip is tall enough for both, else they fill it.
    final preview = MidiClipPreview.of(widget.state.project, c, stepW: widget.stepW, trim: start - c.startSteps,
      top: widget.height >= 34 ? 15 : 1, color: Color.lerp(widget.color, Neon.ink, 0.45)!.withValues(alpha: 0.9));
    // On the pinned track the clip itself slides in time; elsewhere its ghost shows where it goes and it stays dim.
    final shown = dragging && !sourceDragging && _drag == null ? (_moveTarget() - c.startSteps) * widget.stepW : 0.0;
    final ghosted = dragging && !sourceDragging && _drag != null && !_copy;
    // The body drags in any direction from the first few pixels, before the scroll views take the gesture.
    final mq = MediaQuery.of(context);
    return Opacity(opacity: ghosted ? 0.35 : c.mute ? 0.45 : 1,
      child: Transform.translate(offset: Offset(shown + (start - c.startSteps) * widget.stepW, 0),
      // An edge drag changes the clip's width, never its content's scale (owner, 2026-11-11, as REAPER): longer shows
      // more (the next repeats, or nothing), shorter crops, and a left trim keeps the notes where they are.
      child: OverflowBox(key: ValueKey('clip-body-${c.id}'), alignment: Alignment.centerLeft,
        minWidth: math.max(12.0, length * widget.stepW), maxWidth: math.max(12.0, length * widget.stepW),
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
          // A tap selects at once; a quick second tap opens the clip menu as well (owner, 2026-11-11), which replaced
          // the double tap that opened the notes: its first item, "Edit notes", does what that did. A mouse's
          // double-click opens the notes; the right-click opens the menu.
          child: MouseRegion(cursor: SystemMouseCursors.grab, child: GestureDetector(
          key: ValueKey('clip-${c.id}'),
          // A long press picks the clip up (owner, 2026-11-11); a double tap, or a right-click, opens its menu.
          onLongPressStart: _lift,
          onLongPressMoveUpdate: _liftMove,
          onLongPressEnd: _liftEnd,
          onSecondaryTapUp: (d) => widget.callbacks.onClipMenu(widget.layer, c, d.globalPosition),
          onTap: () {
            _opening?.cancel();
            _opening = null;
            if (_clicks.doubleClick) return widget.callbacks.onClipOpen(widget.layer, c);
            if (_clicks.doubleTap) return widget.callbacks.onClipMenu(widget.layer, c, _clicks.position);
            final (ctrl, shift) = _tapKeys;
            // REAPER (UG 7.2.1): Ctrl-click adds or removes a clip, Shift-click selects the range to it. A tap in
            // Select mode adds or removes it, the phone's way.
            if (ctrl || widget.callbacks.selectMode()) {
              widget.state.toggleClipSelection(widget.layer, c);
            } else if (shift) {
              widget.state.selectClipRange(widget.layer, c);
            } else if (widget.state.selectedClipIds.contains(c.id)) {
              // A tap on the selected clip opens its notes in the piano roll (owner, 2026-11-11). The roll moves the
              // clip (the focus view), so a finger's waits out the double tap that opens the menu instead.
              final layer = widget.layer;
              if (_clicks.mouse) return widget.callbacks.onClipOpen(layer, c);
              _opening = Timer(kDoubleTapTimeout, () {
                _opening = null;
                if (mounted) widget.callbacks.onClipOpen(layer, c);
              });
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
        if (preview != null) Positioned.fill(child: IgnorePointer(child: RepaintBoundary(
          child: CustomPaint(key: ValueKey('clip-preview-${c.id}'), painter: ClipPreviewPainter(preview))))),
        // Loop-recorded takes: ‹ n/N › steps through them, a swipe across it too, a tap on the count lists them.
        if (c.takes.length > 1 && c.lengthSteps * widget.stepW >= 86 && widget.height >= 26)
          Positioned(top: 2, right: 14, child: TakeChip(state: widget.state, layer: widget.layer, clip: c,
            color: widget.color)),
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

class _OverloadBanner extends StatelessWidget {
  const _OverloadBanner({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: NeonPanel(
          color: Neon.pink,
          child: Row(children: [
            const Icon(Icons.speed, color: Neon.pink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  'Out of headroom: the newest layer${state.meters.overloaded > 1 ? 's were' : ' was'} muted to keep audio clean.'
                  '${state.lightTurnedOnBySelf ? ' Lightweight profile is now active (Settings).' : ''}'),
            ),
            TextButton(onPressed: state.clearOverload, child: const Text('Unmute')),
          ]),
        ),
      );
}

class _ProjectSettings extends StatefulWidget {
  const _ProjectSettings({required this.state});
  final AppState state;

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  final List<DateTime> _taps = [];
  late final TextEditingController _seed;
  late int _syncedSeed;

  static const keys = [
    'C major', 'C minor', 'C# minor', 'D major', 'D minor', 'Eb major', 'E minor', 'F major', 'F minor', //
    'F# minor', 'G major', 'G minor', 'A major', 'A minor', 'Bb major', 'B minor', 'None',
  ];

  @override
  void initState() {
    super.initState();
    _syncedSeed = widget.state.project.seed;
    _seed = TextEditingController(text: _syncedSeed.toRadixString(16));
  }

  @override
  void didUpdateWidget(covariant _ProjectSettings old) {
    super.didUpdateWidget(old);
    // Re-sync only when the project's seed changed (Enter, undo, another project). Comparing against the
    // typed text instead would put the old seed back on every rebuild while it is being edited (#20).
    final seed = widget.state.project.seed;
    if (seed == _syncedSeed) return;
    _syncedSeed = seed;
    _seed.text = seed.toRadixString(16);
  }

  @override
  void dispose() {
    _seed.dispose();
    super.dispose();
  }

  void _tap() {
    final now = DateTime.now();
    if (_taps.isNotEmpty && now.difference(_taps.last).inMilliseconds > 2000) _taps.clear();
    _taps.add(now);
    if (_taps.length > 5) _taps.removeAt(0);
    if (_taps.length >= 2) {
      final ms = _taps.last.difference(_taps.first).inMicroseconds / 1000.0 / (_taps.length - 1);
      final bpm = (60000 / ms).clamp(20.0, 400.0);
      widget.state.editProject((p) => p.bpm = double.parse(bpm.toStringAsFixed(1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final bpmText = p.bpm == p.bpm.roundToDouble() ? p.bpm.toStringAsFixed(0) : p.bpm.toStringAsFixed(1);
    return NeonPanel(
      color: Neon.blue,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton.outlined(
              tooltip: 'Slower: 1 BPM',
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm - 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.remove)),
          Expanded(
            child: Column(children: [
              Text(bpmText, style: Neon.code(size: 34, color: Neon.blue).copyWith(fontWeight: FontWeight.w700)),
              const Text('BPM', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ]),
          ),
          IconButton.outlined(
              tooltip: 'Faster: 1 BPM',
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm + 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.add)),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Neon.blue, minimumSize: const Size(72, 48)),
            onPressed: _tap,
            child: const Text('TAP', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _Labeled(
            'Time',
            DropdownButton<int>(
              value: p.beatsPerBar,
              items: [for (final b in {2, 3, 4, 5, 6, 7, p.beatsPerBar}.toList()..sort()) DropdownMenuItem(value: b, child: Text('$b/4'))],
              onChanged: (v) => s.editProject((p) => p.beatsPerBar = v!),
            ),
          ),
          _Labeled(
            'Length',
            BarsField(value: p.loopBars, max: p.maxLoopBars, title: 'Shortest song length',
              onChanged: (v) => s.editProject((p) => p.loopBars = v)),
          ),
          _Labeled(
            'Key',
            DropdownButton<String>(
              value: keys.contains(p.key) ? p.key : 'None',
              items: [for (final k in keys) DropdownMenuItem(value: k, child: Text(k))],
              onChanged: (v) => s.editProject((p) => p.key = v!),
            ),
          ),
          _Labeled(
            'Seed',
            SizedBox(
              width: 92,
              child: TextField(
                controller: _seed,
                style: Neon.code(size: 14),
                decoration: const InputDecoration(prefixText: '0x'),
                onSubmitted: (v) {
                  final n = int.tryParse(v, radix: 16);
                  if (n != null && n >= 0 && n <= 0xFFFFFFFF) s.editProject((p) => p.seed = n);
                },
              ),
            ),
          ),
          Text('${p.songSeconds.toStringAsFixed(2)} s song', style: const TextStyle(color: Neon.dim)),
        ]),
        Row(children: [
          const SizedBox(width: 56, child: Text('Master', style: TextStyle(color: Neon.dim))),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: s.masterValueTick,
              builder: (context, _, _) => Row(children: [
                Expanded(child: SizedBox(height: 36, child: VolumeFader(value: s.project.master, vertical: false,
                  color: Neon.blue, label: 'Master level', onChanged: s.setMaster))),
                SizedBox(width: 56, child: Text(VolumeTaper.label(s.project.master), textAlign: TextAlign.right,
                  style: Neon.code(size: 10, color: Neon.dim))),
              ]),
            ),
          ),
          SizedBox(width: 120, child: PeakMeter(state: s, read: () => s.audibleMeters.peakL, readRight: () => s.audibleMeters.peakR, color: Neon.blue)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeThumbColor: Neon.blue,
          title: const Text('Crossfade loop seams'),
          subtitle: const Text('3 ms blend where a layer restarts', style: TextStyle(color: Neon.dim)),
          value: p.seamCrossfade,
          onChanged: (v) => s.editProject((p) => p.seamCrossfade = v),
        ),
      ]),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: const TextStyle(color: Neon.dim)),
        child,
      ]);
}

/// No tracks yet: what to do first, with the button to do it.
class _EmptyArrangement extends StatelessWidget {
  const _EmptyArrangement({required this.onAdd, required this.onBrowse});
  final VoidCallback onAdd, onBrowse;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.queue_music, size: 40, color: Neon.green.withValues(alpha: 0.7)),
            const SizedBox(height: 10),
            const Text('No tracks yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('Add a track, give it an instrument, then draw a pattern clip on it.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Neon.dim)),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              FilledButton.icon(key: const ValueKey('empty-add-track'), onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 18), label: const Text('Add a track')),
              OutlinedButton.icon(onPressed: onBrowse,
                  icon: const Icon(Icons.folder_open, size: 18), label: const Text('Drag one in from Files')),
            ]),
          ]),
        ),
      );
}
