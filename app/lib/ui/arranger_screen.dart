// Arrange: the tracks and clips on a timeline, compact track headers, the focus view (one track and its panel) and the mixer card.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../model/drums.dart' show drumsComponentId;
import '../model/app_state.dart';
import '../model/arrange_edit.dart';
import '../model/comping.dart';
import '../model/audio_edit.dart';
import '../model/arrange_fx.dart';
import '../model/arrange_markers.dart';
import '../model/audio_record.dart' show AudioRecorder;
import '../model/clip_automation.dart';
import '../model/clip_loop_edit.dart';
import '../model/freeze.dart';
import '../model/live_midi.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import '../model/tempo_map.dart';
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
import 'arrange/section_bar.dart';
import 'arrange/tempo_lane.dart';
import 'arrange/focus_panel.dart';
import 'arrange/edit_cues.dart';
import 'arrange/edit_motion.dart';
import 'arrange/freeze_ui.dart';
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
import 'arrange/timeline_window.dart';
import 'arrange/take_lanes.dart';
import 'arrange/track_lanes.dart';
import 'file_manager_screen.dart';
import 'frame/frame_widgets.dart';
import 'frame/record_tools.dart' show showTakePicker;
import 'widgets.dart';
import 'track_cards_screen.dart';
import 'glass.dart';
import 'key_router.dart';
import 'midi_file_actions.dart';
import 'arranger_screen/project_settings.dart';

part 'arranger_screen/arrange_input.dart';
part 'arranger_screen/arrange_layout.dart';
part 'arranger_screen/timeline_clip.dart';
part 'arranger_screen/timeline_header.dart';
part 'arranger_screen/timeline_lane.dart';
part 'arranger_screen/track_menus.dart';

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

  /// A clip drag's or trim's guides (owner, 2026-11-12): its span while it moves, null otherwise.
  final _guides = ValueNotifier<ClipGuide?>(null);

  /// Phone portrait: the focus panel opened up over the pinned track (owner, 2026-11-10: it can open higher).
  bool _panelHigh = false;

  /// The Files browser beside (or under) the tracks, so files can be dragged onto a track or into the FX stack
  /// without leaving Arrange (owner, 2026-11-10).
  bool _browser = false;
  bool _browserWas = false, _browserLeaving = false;
  Timer? _browserTimer;

  /// Time zoom: pixels per 16th step (× 0.85 at compact density). A zoom changes it alone, every frame of a pinch or
  /// glide: the lanes' parts that depend on it listen ([_stepWN]) and lay out at it, so nothing is scaled and nothing
  /// snaps when the fingers lift (owner, 2026-11-18), and the rest of the screen isn't built again.
  final _zoomN = ValueNotifier<double>(18.0);
  double get zoom => _zoomN.value;

  /// Pixels per step on screen: the zoom times the density's scale (set at each build).
  late final _stepWN = _StepWidth(_zoomN);
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
    // Far ahead at once (#241): each step lays the whole arrangement out again, so it comes every few screens of
    // scroll, not every frame near the end.
    if (reach > _reachSteps + 1) setState(() => _reachSteps = reach + 6 * p.viewportDimension / _stepW);
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

  // A pinch and the slider follow at once; the zoom buttons and Ctrl + wheel glide ([_animateViewTo]). All of them
  // go through [_setZoom], which lays the lanes out at the new zoom and scrolls in the same frame.

  // Two fingers on the timeline: a sideways pinch zooms time, an up-and-down pinch the track height.
  final Map<int, Offset> _touches = {};
  double _pinchDx0 = 0, _pinchDy0 = 0, _pinchZoom0 = 0, _pinchH0 = 0;
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

  /// The timeline's pixels per step now.
  double get _stepW => _stepWN.value;

  /// Bumped by every build of the screen (not by a zoom alone): a lane keeps the clip widgets it built while only the
  /// zoom moves on.
  int _buildGen = 0;

  /// Bumped by every settings change (the theme, the clips' look): with the project's [AppState.docGen], what the
  /// headers and clips are built from (#235).
  int _settingsGen = 0;
  void _settingsChanged() => _settingsGen++;

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
      old.state.settings.removeListener(_settingsChanged);
      widget.state.settings.addListener(_settingsChanged);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.state.tick.addListener(_followPlayhead);
    widget.state.revealStartRequests.addListener(_revealStart);
    widget.state.settings.addListener(_settingsChanged);
    _hScroll.addListener(_onHScroll);
    widget.state.onFrozenEdit = _frozenEdit;
    // Remember zoom per project (#244): the app reads and restores the view through these hooks.
    widget.state..readArrangeView = _arrangeView..applyArrangeView = _restoreArrangeView;
    if (widget.state.savedArrangeView case final v?) _restoreArrangeView(v);
  }

  /// The view now, for Remember zoom per project (#244): the zoom, the step at the left edge, the tracks' scroll.
  ArrangeView? _arrangeView() => !_hScroll.hasClients ? null : (zoom: zoom, left: _hScroll.positions.last.pixels / _stepW,
      top: _drag.vScroll.hasClients ? _drag.vScroll.positions.last.pixels : 0.0);

  /// Puts a remembered view back once the lanes are laid out.
  void _restoreArrangeView(ArrangeView v) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_hScroll.hasClients) return;
        _setZoom(v.zoom.clamp(minZoom, maxZoom).toDouble(), leftStep: v.left);
        if (_drag.vScroll.hasClients) {
          final p = _drag.vScroll.positions.last;
          p.jumpTo(v.top.clamp(0.0, p.maxScrollExtent).toDouble());
        }
      });

  bool _asking = false;

  /// An edit reached a frozen track (freeze, 1.0.5): one "Unfreeze to edit?" at a time; the edit itself was not made.
  Future<void> _frozenEdit(LayerDoc layer) async {
    if (_asking || !mounted) return;
    _asking = true;
    try {
      await askUnfreeze(context, widget.state, layer);
    } finally {
      _asking = false;
    }
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

  @override
  void dispose() {
    if (widget.state.onFrozenEdit == _frozenEdit) widget.state.onFrozenEdit = null;
    widget.state.rememberArrangeView();  // #244: the view is kept as the arranger closes
    if (widget.state.readArrangeView == _arrangeView) widget.state..readArrangeView = null..applyArrangeView = null;
    widget.state.tick.removeListener(_followPlayhead);
    widget.state.revealStartRequests.removeListener(_revealStart);
    widget.state.settings.removeListener(_settingsChanged);
    _router?.unregister(Area.arranger, _keys);
    _keys.dispose();
    _marquee.dispose();
    _guides.dispose();
    _headerHold.stop();
    _panelOut.dispose();
    _browserTimer?.cancel();
    _glide.dispose();
    _vGlide.dispose();
    _hScroll.removeListener(_onHScroll);
    _trackGhost?.remove();
    _trackGhostAt.dispose();
    _zoomN.dispose();
    _drag.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  /// The step that was under the fingers' midpoint as the pinch began: it stays under the midpoint, wherever the
  /// fingers go, and the pinch scrolls the view itself (its first move ends the view's own two-finger drag).
  double? _pinchBeat;

  /// The fingers' midpoint when the pinch began, from the lanes' left edge.
  double _pinchFocal0 = 0;

  /// The mouse pointer panning the view (middle-drag or Space+drag), if any.
  int? _panPointer;

  /// The second finger resting during a lifted clip drag (it frees the clip from the grid until it lifts).
  int? _resting;

  // ---------- a track header dragged (owner, 2026-11-11, after REAPER: a long press picks the track up; up and
  // down reorders, the right-most third of another header nests it there) ----------

  LayerDoc? _pressed, _dragged;
  Offset _pressAt = Offset.zero, _trackAt = Offset.zero;

  /// A finger's hold that hasn't moved yet: its track menu is open, and moving past the slop closes it.
  bool _held = false;
  final _headerHold = HoldToMove();

  OverlayEntry? _trackGhost;
  final _trackGhostAt = ValueNotifier<Offset>(Offset.zero);

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    _buildGen++;
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

  /// The tracks and their lanes. [pinned]: the focus view's one track, without the empty space under it.
  /// The tracks shown at the last build (null before the first), and where each row stood: for edit animations.
  Set<String>? _knownTracks;
  final Map<String, (double, Object)> _rowMemory = {};

}

/// The lanes' pixels per step: the zoom times the density's [scale], heard as the zoom changes.
class _StepWidth implements ValueListenable<double> {
  _StepWidth(this.zoom);
  final ValueListenable<double> zoom;
  double scale = 1;

  @override
  double get value => zoom.value * scale;

  @override
  void addListener(VoidCallback listener) => zoom.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => zoom.removeListener(listener);
}

/// What a track header, lane or clip asks of the arranger.
class _TrackCallbacks {
  const _TrackCallbacks({required this.onTap, required this.onFx, required this.onMenu, required this.onClipMenu,
    required this.onClipOpen, required this.selectMode, required this.onMarquee, required this.guides,
    this.onAudioOpen});

  /// A header's tap (it selects the track) and double tap (the track's main editor: the focus view's FX tab, with
  /// its instrument and effects; owner, 2026-11-12).
  final ValueChanged<LayerDoc> onTap, onFx;

  /// The guides a dragged or trimmed clip shows while it moves.
  final ValueNotifier<ClipGuide?> guides;
  final void Function(LayerDoc layer, Offset at) onMenu;
  final void Function(LayerDoc layer, ClipDoc clip, Offset at) onClipMenu;

  /// A double tap or double-click on a MIDI clip (owner, 2026-11-12): its notes, in the focus panel's Clip tab.
  final void Function(LayerDoc layer, ClipDoc clip) onClipOpen;

  /// An audio clip's double tap or double-click, or its menu's Clip settings…: the track's Clip tab.
  final void Function(LayerDoc layer)? onAudioOpen;

  /// Whether Select mode is on: a tap on a clip adds or removes it, a long-press drag in a lane draws a box.
  final bool Function() selectMode;

  /// A marquee's start, move and end, in global coordinates; [additive] adds to the selection.
  final void Function(_Marquee phase, Offset at, bool additive) onMarquee;
}

enum _Marquee { start, move, end }

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
