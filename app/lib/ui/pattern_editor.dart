// The pattern editor: a piano roll and a drum grid over the same notes, with an adaptive grid, velocity lane and keys,
// the quantize sheet, step input and the generators.
import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../actions/actions.dart';
import '../actions/keymap.dart';
import '../actions/macro.dart';
import '../engine/engine.dart';

import '../model/app_state.dart';
import '../model/arrange_markers.dart';
import '../model/clip_loop_edit.dart';
import '../model/lane_curve.dart';
import '../model/live_midi.dart';
import '../model/midi_clips.dart';
import '../model/midi_file.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import '../model/settings.dart';
import 'key_router.dart';
import 'page_closer.dart';
import 'pointer_input.dart';
import 'note_expression.dart';
import 'motion.dart';
import 'theme.dart';
import 'widgets.dart';
import 'arrange/edit_cues.dart';
import 'arrange/ruler.dart' show LoopBand;
import 'arrange/track_color.dart';
import 'clip_roll_parts.dart';
import 'glass.dart';
import 'adaptive_sheet.dart';
import 'follow_gate.dart';
import 'frame/frame_widgets.dart' show ScrollFade;
import 'haptics.dart';
import 'live_playhead.dart';
import 'feedback.dart';
import 'view_glide.dart';

enum PatternTool { draw, select, curve, erase, ratchet }

/// Paint counts of the roll's layers, for the frame benchmark in the tests: the whole roll, and the live curve on top.
@visibleForTesting
class RollPaintStats {
  static int roll = 0, live = 0;
  static String? label; // the pitch label the overlay last drew, if any
  static int edits = 0; // notes the roll's last paint drew part way through an edit animation
  static Offset? anchor; // where it last drew a curve's start, if anywhere
  static void reset() => roll = live = 0;
}

/// A note length as a fraction of a whole note (a step is a 16th): `1/4`, `3/8`, `1`, `5/4`, or `1/12` in triplets.
String noteLengthLabel(Steps len) {
  final whole = len / Steps(16);
  return whole.denominator == 1 ? '${whole.numerator}' : '${whole.numerator}/${whole.denominator}';
}

/// Grid resolutions as fractions of a whole note (1 = a bar of 4/4), from 1 down to 1/128.
const _resolutions = [1, 2, 4, 8, 16, 32, 64, 128];

class PatternEditor extends StatefulWidget {
  const PatternEditor(
      {super.key, required this.state, required this.module, this.fullScreen = false, this.router, this.layer, this.clip});
  final AppState state;
  final ModuleDoc module;
  final bool fullScreen;

  /// The clip the roll is opened for (the focus panel's Clip tab, and its full-screen roll), on [layer]: the roll then
  /// shows the clip's loop bar and its automation lanes. Null in Build, where a pattern is edited on its own.
  final LayerDoc? layer;
  final ClipDoc? clip;

  /// The key router, for a full-screen roll whose route sits outside it.
  final KeyRouterState? router;

  @override
  State<PatternEditor> createState() => _PatternEditorState();
}

class _PatternEditorState extends State<PatternEditor> with TickerProviderStateMixin {
  final FocusNode _focus = FocusNode(debugLabel: 'pattern editor');
  PatternDoc? _doc;
  String? _error;
  String _lastText = '';
  // Undo steps: the doc before an edit, or (with [sel]) a selection a box drew, which an undo takes back.
  final List<_Undo> _undo = [], _redo = [];
  Set<int> _sel = {};
  PatternTool _tool = PatternTool.draw;
  bool _grid = false; // drum grid instead of the roll
  int _res = 16; // grid resolution: 1/16 of a whole note = one step
  bool _snap = true, _fixed = false, _triplet = false;
  bool _velLane = true, _extrasLane = false; // Alt+V, Alt+X
  bool _multiEditEnabled = false;
  final Map<String, PatternDoc> _multiDocs = {};
  List<String> _multiSourceIds = [];
  double _pxPerStep = 28, _scrollX = 0, _scrollY = 0;
  Steps _cursorAt = Steps.zero;
  double _cursorPitch = 60;
  Steps? _lastLen;
  Timer? _sendTimer;
  // A drag heard while the song plays (#170): its newest state goes to the engine at most every 33 ms.
  Timer? _liveTimer;
  PatternDoc? _liveDoc;
  bool _liveSent = false;
  // Drag state.
  int? _dragNote;
  int _edge = 0; // the note end a drag stretches: 1 the end, -1 the start, 0 none (it moves)
  // While a stretch is dragged the edge follows the finger: [_lag] px past the snapped edge, which a faint ghost shows.
  // On release the edge springs back onto it.
  double _lag = 0;
  Set<int> _lagIds = const {};
  late final AnimationController _spring = AnimationController(vsync: this)..addListener(_springTick);
  double _lagFrom = 0;
  int _lagEdge = 1;

  // Edit animations (owner, 2026-11-11; [EditMotion]): notes an edit adds pop in from their start, deleted ones shrink
  // and fade, moved ones slide from where they were and changed lengths grow or shrink. One controller drives them
  // all; the painter reads its value (no widget per note, no rebuild a frame). Drags don't animate: their ghosts
  // and snapping are the help.
  late final AnimationController _editCtl = AnimationController(vsync: this)
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed && _motion != null && mounted) setState(() => _motion = null);
    });
  _RollMotion? _motion;

  /// Starts the edit animation from [from] to [to], for the kinds turned on.
  void _animateEdit(PatternDoc from, PatternDoc to) {
    final notesD = EditMotion.of(context, EditMotionKind.notes), lenD = EditMotion.of(context, EditMotionKind.lengths);
    _motion = null;
    if (notesD == null && lenD == null) return;
    final old = {for (final n in from.notes) n.id: n};
    final appear = <int>{};
    final was = <int, ({double at, double pitch, double len})>{};
    final ids = <int>{};
    for (final n in to.notes) {
      ids.add(n.id);
      final o = old[n.id];
      if (o == null) {
        if (notesD != null) appear.add(n.id);
        continue;
      }
      final moved = notesD != null && (o.at != n.at || o.pitch != n.pitch), sized = lenD != null && o.len != n.len;
      if (moved || sized) {
        was[n.id] = (
          at: (moved ? o.at : n.at).toDouble(),
          pitch: moved ? o.pitch : n.pitch,
          len: (sized ? o.len : n.len).toDouble(),
        );
      }
    }
    final gone = notesD == null ? const <PatternNote>[] : [for (final n in from.notes) if (!ids.contains(n.id)) n];
    final count = appear.length + was.length + gone.length;
    if (count == 0 || count > 2000) return; // a huge edit just lands
    final d1 = notesD ?? Duration.zero, d2 = was.isEmpty ? Duration.zero : (lenD ?? Duration.zero);
    // Notes that only moved (a nudge, a paste in place, a quantize, a drag's last snap) slide there quickly, in one
    // short glide the painter draws (owner, 2026-11-11).
    final lens = {for (final n in to.notes) n.id: n.len.toDouble()};
    final moveOnly = appear.isEmpty && gone.isEmpty && was.entries.every((e) => e.value.len == lens[e.key]);
    final nudge = moveOnly ? EditMotion.nudge(context, EditMotionKind.notes) : null;
    if (moveOnly && nudge == null) return;
    _editCtl.duration = nudge ?? (d1 > d2 ? d1 : d2);
    _motion = _RollMotion(_editCtl, appear: appear, was: was, gone: gone, fade: EditMotion.fadeOnly(context),
        curve: nudge != null ? EditMotion.nudgeCurve : EditMotion.curve);
    _editCtl.forward(from: 0);
  }

  void _springTick() {
    setState(() {
      final t = Motion.settleCurve(_lagFrom.abs(), MotionLevel.full).transform(_spring.value);
      _lag = _lagFrom * (1 - t);
      if (_spring.isCompleted) {
        _lag = 0;
        _lagIds = const {};
      }
    });
  }
  // Snap bypass: a second finger resting on the roll during a note drag frees it from the grid until it lifts.
  int? _editPointer;
  bool _bypass = false;
  Offset _restAt = Offset.zero, _editAtBypass = Offset.zero; // where the resting and dragging fingers were then
  bool _touch = false; // the drag is a finger's, so the note ends get finger-sized zones
  // Edge auto-scroll while a drag sits near the grid's edge.
  late final Ticker _scroller = createTicker(_scrollTick);
  Duration _scrolledAt = Duration.zero;
  Offset? _lastP;
  double _gridW = 0, _maxScrollX = 0, _maxScrollY = 0;
  // A finger down on empty grid with the Draw tool: where its note would land, shown before it lifts.
  ({Steps at, double pitch, Steps len})? _ghost;
  double _lastVel = 1; // a new note takes the last velocity set
  Offset? _dragStart, _rectEnd;
  Steps _dragMovedT = Steps.zero;
  double _dragMovedP = 0;
  PatternDoc? _dragBase;
  double _zoomStart = 28;
  // Raw touches: every finger on the roll, and a one-finger touch on empty grid that is not yet a tap or a scroll.
  final Map<int, Offset> _pointers = {};
  Offset? _pending;
  bool _panning = false;
  double _pinchSpan = 0;
  Offset _pinchFocal = Offset.zero;
  int _lane = 0; // a drag in the velocity (1) or extras (2) lane
  bool _rectSelect = false; // this drag draws a selection rectangle
  // The selection box (owner, 2026-11-11): a long press on empty grid, then a drag, adds the notes it covers to
  // [_rectBase], the selection before it; one undo step takes it back. A rectangle isn't drawn until past the slop,
  // so a tap never changes the selection, and a double tap on empty grid clears it.
  static const _boxHold = Duration(milliseconds: 350);
  Timer? _boxTimer;
  bool _boxAdd = false, _rectMoved = false;
  Set<int> _rectBase = const {};
  ({Offset at, DateTime when})? _emptyTap;
  // The Curve tool: one curve per lane (1 velocity, 2 chance), kept while the roll is open.
  // Replaced (never changed in place) on each edit, so the painter sees a new map only when a curve changed.
  Map<int, LaneCurve> _curves = const {1: LaneCurve(), 2: LaneCurve()};
  LaneCurve? _cBase; // the lane's curve when the gesture began, put back if it is cancelled
  int _cLane = 0; // the lane a curve gesture is in, 0 when none
  int? _cPoint, _cSeg; // the point being dragged, or the segment being bent
  double _cBend0 = 0;
  Offset? _cStart;
  bool _cAddOnTap = false; // a touch inside a segment: a tap adds a point there, a drag bends it
  // The Curve tool's overlay: the curve under the mouse or finger, and a pitch curve while it is dragged.
  final _curveView = ValueNotifier(const _CurveView());
  double _gridH = 0;
  Timer? _hold; // long press on a note opens its extras panel
  Offset? _holdAt;
  // A plain tap on a note arms a double tap: a second tap on it soon after deletes it.
  int? _tapCandidate, _tapNote;
  DateTime? _tapAt;

  static const _keyW = 44.0, _rulerH = 20.0;

  // The clip's loop bar (owner, 2026-11-11): its length while dragged (committed on release, one undo step), where
  // the finger took it relative to the bar, and whether the mouse is over it (a resize cursor).
  int? _loopLive;
  double _loopGrab = 0;
  bool _loopHover = false;

  /// Where the clip loops in the roll's time, or null when the roll isn't opened for a clip.
  int? _loopSteps(PatternDoc d) {
    final c = widget.clip;
    if (c == null || widget.layer == null) return null;
    return _loopLive ?? c.loopLength(d.lengthSteps(s.project.beatsPerBar));
  }

  /// Whether [p] (grid coordinates; the ruler is above 0) takes the loop bar: a mouse right on it anywhere down the
  /// grid; a finger on the ruler or the grip under it, a little either side.
  bool _loopHit(Offset p, PointerDeviceKind kind) {
    final d = _doc;
    final l = d == null ? null : _loopSteps(d);
    if (l == null || p.dx < 0) return false;
    final dx = (p.dx - (l * _pxPerStep - _scrollX)).abs();
    if (kind == PointerDeviceKind.mouse) return dx <= 6 && p.dy < _gridH;
    return dx <= 18 && p.dy < ClipLoopPainter.gripH;
  }

  void _loopDown(Offset p) {
    final l = _loopSteps(_doc!)!;
    _loopGrab = p.dx - (l * _pxPerStep - _scrollX);
    Haptics.grab();
    setState(() => _loopLive = l);
  }

  /// The bar follows the finger, on the grid (whole steps when freed by Shift, a second finger or snap off).
  void _loopMove(Offset p) {
    final raw = (p.dx - _loopGrab + _scrollX) / _pxPerStep;
    final grid = _resSteps.toDouble();
    final v = math.max(1, (_free || grid < 1 ? raw : Snap.to(raw, grid)).round());
    if (v == _loopLive) return;
    Haptics.tick();
    setState(() => _loopLive = v);
  }

  void _loopEnd({required bool cancel}) {
    final v = _loopLive, layer = widget.layer, clip = widget.clip;
    setState(() => _loopLive = null);
    if (cancel || v == null || layer == null || clip == null) return;
    Haptics.drop();
    if (v != clip.loopLength(_doc!.lengthSteps(s.project.beatsPerBar)) || clip.loopSteps != null) {
      s.setClipLoop(layer, clip, v);
    }
  }

  void _loopHoverAt(PointerHoverEvent e) {
    final on = _loopHit(e.localPosition - _origin, e.kind);
    if (on != _loopHover) setState(() => _loopHover = on);
  }

  /// The loop bar's right-click menu: back to the pattern's length, and the clip's looping off (or on).
  Future<void> _loopMenu(Offset global) async {
    final layer = widget.layer, clip = widget.clip;
    if (layer == null || clip == null) return;
    final box = Overlay.of(context).context.findRenderObject() as RenderBox;
    final at = box.globalToLocal(global);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & box.size),
      items: [
        _menuHead('Loop'),
        PopupMenuItem(value: 'reset', enabled: clip.loopSteps != null, height: 36,
            child: const Text('Reset to pattern length')),
        PopupMenuItem(value: 'loop', height: 36, child: Text(clip.loop ? 'Loop off' : 'Loop on')),
      ],
    );
    if (v == null || !mounted) return;
    if (v == 'reset') s.setClipLoop(layer, clip, null);
    if (v == 'loop') s.editLayer(layer, (_) => clip.loop = !clip.loop);
    setState(() {});
  }
  // ---------- the ruler (owner, 2026-11-12): as Arrange's, a tap moves the song's cursor there and a drag draws the
  // song's loop range (or moves an end of it), both on the roll's grid; the roll's time lines up with the song's
  // through [_anchor] ----------

  /// The clip the roll's time lines up with the song through: the clip it is opened for, else (in Build) the
  /// pattern's first clip in the song; null when the pattern isn't in the song (the roll's time is the song's).
  ClipDoc? get _anchor {
    final own = widget.clip;
    if (own != null && widget.layer != null) return own;
    ClipDoc? first;
    for (final l in s.project.layers) {
      for (final c in l.clips) {
        if (c.patternId == widget.module.id && (first == null || c.startSteps < first.startSteps)) first = c;
      }
    }
    return first;
  }

  /// How far the roll's time is ahead of the song's at [_anchor] (roll = song + this), as the playhead maps it.
  double _rollShift(PatternDoc d) {
    final c = _anchor;
    if (c == null) return 0;
    final opened = widget.clip != null && widget.layer != null;
    final shown = opened && c.loop ? c.sourceOffsetSteps % (_loopSteps(d) ?? 1) : c.sourceOffsetSteps;
    return (shown - c.startSteps).toDouble();
  }

  /// A song step in the roll's time; in Build, inside a looping clip it wraps to the loop, as the playhead does.
  double _songToRoll(PatternDoc d, double song) {
    final roll = song + _rollShift(d);
    final c = _anchor;
    if (widget.clip == null && c != null && c.loop && song >= c.startSteps && song < c.startSteps + c.lengthSteps) {
      return roll % math.max(1, c.loopLength(d.lengthSteps(s.project.beatsPerBar)));
    }
    return roll;
  }

  /// The song step at the roll's step [roll], on the whole steps the song's loop and cursor take.
  int _rollToSong(PatternDoc d, double roll) => math.max(0, (roll - _rollShift(d)).round());

  /// A press on the ruler (grid coordinates, so above 0) while it lasts, and the loop drag it became: which end moves
  /// (or a new range drawn) and the range it shows, in the roll's steps (committed on release, one undo step).
  Offset? _rulerAt;
  _RulerEdge? _rulerEdge;
  double _rulerFrom = 0, _rulerTo = 0;

  /// The song's loop range in the roll's steps, or null when there is none.
  (double, double)? _songLoop(PatternDoc d) {
    final p = s.project;
    if (!p.hasLoopRange) return null;
    return (p.loopStartSteps + _rollShift(d), p.loopEndSteps + _rollShift(d));
  }

  /// The roll's step under the ruler's x [dx] (grid coordinates), on the roll's grid unless freed.
  double _rulerStep(double dx) => _snapAt(_stepAt(dx));

  void _rulerDown(Offset p) {
    _rulerAt = p;
    _rulerEdge = null;
  }

  void _rulerMove(Offset p) {
    final at = _rulerAt, d = _doc;
    if (at == null || d == null) return;
    if (_rulerEdge == null) {
      if ((p - at).distance <= (_mouse ? _mouseDragSlop : kTouchSlop)) return;
      // A drag that starts on an end of the loop moves that end; anywhere else it draws a new range.
      final loop = _songLoop(d);
      double xOf(double step) => step * _pxPerStep - _scrollX;
      if (loop != null && (at.dx - xOf(loop.$2)).abs() <= 14) {
        _rulerEdge = _RulerEdge.end;
      } else if (loop != null && (at.dx - xOf(loop.$1)).abs() <= 14) {
        _rulerEdge = _RulerEdge.start;
      } else {
        _rulerEdge = _RulerEdge.draw;
      }
      _rulerFrom = _rulerEdge == _RulerEdge.draw ? _rulerStep(at.dx) : loop!.$1;
      _rulerTo = _rulerEdge == _RulerEdge.draw ? _rulerFrom : loop!.$2;
      Haptics.grab();
    }
    final step = _rulerStep(p.dx);
    final was = _rulerEdge == _RulerEdge.start ? _rulerFrom : _rulerTo;
    if (step == was) return;
    Haptics.tick();
    setState(() {
      if (_rulerEdge == _RulerEdge.start) {
        _rulerFrom = step;
      } else {
        _rulerTo = step;
      }
    });
  }

  void _rulerEnd({required bool cancel}) {
    final at = _rulerAt, edge = _rulerEdge, d = _doc;
    _rulerAt = null;
    _rulerEdge = null;
    if (cancel || at == null || d == null) {
      if (edge != null) setState(() {});
      return;
    }
    if (edge == null) {
      // A tap: the song's cursor goes there (playing, playback jumps there).
      s.seekTo(_rollToSong(d, _rulerStep(at.dx)).toDouble());
      setState(() {});
      return;
    }
    final from = _rollToSong(d, _rulerFrom), to = _rollToSong(d, _rulerTo);
    setState(() {});
    if (from == to) {
      // An end dragged onto the other collapses the loop: it turns off and goes; undo brings it back.
      if (edge != _RulerEdge.draw) {
        Motion.tick();
        s.clearLoopRange();
      }
      return;
    }
    Motion.tick();
    s.setLoopRange(from, to);
  }

  RollLook get _look => s.settings.roll;
  // The row height while a pinch or the zoom bar changes it; saved to the roll's look when it ends.
  double? _rowDrag;
  double get _rowH => _rowDrag ?? _look.rowHeight;
  // Zoomed all the way out a long clip's bars are under a pixel each (owner, 2026-11-11: zoom out a lot).
  static const _minRow = 10.0, _maxRow = 40.0, _minPx = 0.05, _maxPx = 200.0;
  bool _zoomBar = false;
  double _rowStart = 16, _pinchSpanY = 0;
  bool _pinchX = true, _pinchY = false;

  void _saveRow() {
    final r = _rowDrag;
    if (r == null) return;
    s.settings.update((x) => x.roll = x.roll.copyWith(rowHeight: r)).then((_) {
      if (mounted) setState(() => _rowDrag = null);
    });
  }

  /// Time zoom to [px] per step, keeping the grid point [fx] pixels from the grid's left edge in place.
  void _zoomX(double px, {double? fx}) {
    px = px.clamp(_minPx, _maxPx).toDouble();
    final f = fx ?? _gridW / 2;
    _scrollX = math.max(0.0, (_scrollX + f) / _pxPerStep * px - f);
    _pxPerStep = px;
  }

  /// The roll's view moves on its own the way Arrange's do ([ViewGlide]; owner, 2026-11-11): zoom keys and buttons,
  /// fit, back to the start, the keyboard's cursor leaving the view, page following. A touch stops it.
  late final ViewGlide _glide = ViewGlide(this,
      read: () => (left: _scrollX / _pxPerStep, zoom: _pxPerStep),
      apply: (v) {
        if (!mounted) return;
        setState(() {
          _pxPerStep = v.zoom.clamp(_minPx, _maxPx).toDouble();
          _scrollX = (v.left * _pxPerStep).clamp(0.0, math.max(_maxScrollX, v.left * _pxPerStep)).toDouble();
          if (_scrollX < 0) _scrollX = 0;
        });
      });

  /// Glides the view's left edge to [leftStep] and its zoom to [px] per step, together; without [leftStep] the
  /// middle of the grid stays put.
  void _animateViewTo({double? leftStep, double? px}) => _glide.to(
      left: leftStep == null ? null : math.max(0.0, leftStep),
      zoom: px?.clamp(_minPx, _maxPx).toDouble(), keep: _gridW / 2, view: math.max(1.0, _gridW),
      level: Motion.of(context));

  double get _pxAim => _glide.target.zoom;

  /// Back to the pattern's start ([AppState.requestRevealStart], the transport's ⏮).
  void _revealStart() => _animateViewTo(leftStep: 0);

  // Following the playhead: the same rule as Arrange ([FollowGate], Settings › Editing).
  late final FollowGate _follow = FollowGate(s.settings);
  Object? _selSeen;

  /// Where the song's playhead is in the roll's time, while it plays this pattern; null otherwise. Opened for a clip,
  /// that clip's repeats run on along the roll as it draws them; in Build, the first clip of the pattern under the
  /// playhead, wrapped to its loop. [smooth]: between reads too ([AppState.smoothPlayheadStep]), for drawing.
  double? _playStep({bool smooth = false}) {
    final d = _doc;
    if (d == null || !s.meters.playing) return null;
    final ph = smooth ? s.smoothPlayheadStep : s.playheadStep;
    final own = widget.clip;
    if (own != null && widget.layer != null) {
      if (ph < own.startSteps || ph >= own.startSteps + own.lengthSteps) return null;
      final loop = _loopSteps(d) ?? 1;
      return (own.loop ? own.sourceOffsetSteps % loop : own.sourceOffsetSteps) + ph - own.startSteps;
    }
    final len = d.lengthSteps(s.project.beatsPerBar);
    for (final l in s.project.layers) {
      for (final c in l.clips) {
        if (c.patternId != widget.module.id || c.mute || ph < c.startSteps || ph >= c.startSteps + c.lengthSteps) continue;
        final at = c.sourceOffsetSteps + ph - c.startSteps;
        return c.loop ? at % c.loopLength(len) : at;
      }
    }
    return null;
  }

  /// True while Smooth follow scrolls the roll on each read: the playhead is then drawn at the read too, so it holds
  /// still a third in rather than running ahead between the view's steps.
  bool _scrollFollows = false;

  void _followPlayhead() {
    if (!mounted) return;
    if (_selSeen != null && !identical(_sel, _selSeen)) _follow.touch();
    _selSeen = _sel;
    final at = _playStep();
    if (!_follow.allows(playing: s.meters.playing) || at == null || _pointers.isNotEmpty || _gridW <= 0) {
      _scrollFollows = false;
      return;
    }
    final x = at * _pxPerStep;
    _scrollFollows = s.settings.followSmooth;
    if (s.settings.followSmooth) {
      _glide.stop();
      final to = math.max(0.0, x - _gridW / 3);
      if ((to - _scrollX).abs() >= 0.5) setState(() => _scrollX = to);
      return;
    }
    if (_glide.active) return;
    if (x >= _scrollX && x <= _scrollX + _gridW - 24) return;
    _animateViewTo(leftStep: at - _gridW * 0.1 / _pxPerStep);
  }

  // The keyboard's cursor at the last build: when it leaves the view, the view glides after it.
  Steps? _cursorSeen;

  void _revealCursor() {
    final at = _cursorAt;
    if (_cursorSeen == null || at == _cursorSeen) {
      _cursorSeen = at;
      return;
    }
    _cursorSeen = at;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _gridW <= 0) return;
      final x = at.toDouble() * _pxPerStep;
      if (x >= _scrollX && x <= _scrollX + _gridW - 24) return;
      _animateViewTo(leftStep: at.toDouble() - _gridW * (x < _scrollX ? 0.1 : 0.7) / _pxPerStep);
    });
  }

  /// Row zoom to [row] pixels per note, keeping the pitch [fy] pixels below the grid's top in place.
  void _zoomY(double row, {double? fy}) {
    row = row.clamp(_minRow, _maxRow).toDouble();
    final f = fy ?? _gridH / 2;
    _scrollY = math.max(0.0, (_scrollY + f) / _rowH * row - f);
    _rowDrag = row;
  }
  double get _velH => _look.velocityLane;
  double get _xH => _look.chanceLane;
  double get _lanesH => (_velLane ? _velH : 0) + (_extrasLane ? _xH : 0);

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    // Settings › Editing: the grid, snapping, tool and note length the roll opens with.
    final ed = s.settings;
    _res = ed.rollGrid;
    _snap = ed.rollSnap;
    _tool = ed.rollTool == StartTool.select ? PatternTool.select : PatternTool.draw;
    if (ed.rollNoteSteps > 0) _lastLen = Steps.fromDouble(ed.rollNoteSteps);
    s.settings.addListener(_settingsChanged);
    s.tick.addListener(_followPlayhead);
    s.revealStartRequests.addListener(_revealStart);
    _load();
  }

  void _settingsChanged() {
    if (mounted) setState(() {});
  }

  KeyRouterState? _router;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = widget.router ?? KeyRouter.of(context);
    if (r != _router) {
      _router?.unregister(Area.pattern, _focus);
      _router = r?..register(Area.pattern, _focus, _action);
    }
  }

  @override
  void didUpdateWidget(PatternEditor old) {
    super.didUpdateWidget(old);
    if (old.module.id != widget.module.id || widget.module.source != _lastText) {
      _load();
      _multiEditEnabled = false;
      _multiDocs.clear();
      _multiSourceIds = [];
    }
  }

  @override
  void dispose() {
    _stepMidi?.cancel();
    _stepKeysOff();
    _hold?.cancel();
    _liveEnd();
    _hearStop();
    _curveView.dispose();
    _spring.dispose();
    _editCtl.dispose();
    _scroller.dispose();
    _glide.dispose();
    s.tick.removeListener(_followPlayhead);
    s.revealStartRequests.removeListener(_revealStart);
    s.settings.removeListener(_settingsChanged);
    _router?.unregister(Area.pattern, _focus);
    _flush(closing: true);
    _focus.dispose();
    super.dispose();
  }

  void _load() {
    final src = widget.module.source;
    final r = PatternDoc.parse(src.trim().isEmpty ? '---\nkind: pattern\n---\n' : src);
    _lastText = src;
    if (r.ok) {
      _doc = r.doc;
      _written = r.doc;
      _error = null;
      _undo.clear();
      _redo.clear();
      _sel = {};
      final ps = _doc!.notes.map((n) => n.pitch);
      if (ps.isNotEmpty) _scrollY = (127 - ps.reduce(math.max) - 4).clamp(0, 127) * _rowH;
    } else {
      _error = r.error;
    }
  }

  void _loadMultiDocs(AppState state) {
    final ids = state.selectedPatternModuleIds.where((id) => id != widget.module.id).toList()..sort();
    _multiDocs.clear();
    for (final id in ids) {
      final module = state.project.module(id);
      if (module == null) continue;
      final parsed = PatternDoc.parse(module.source);
      if (parsed.ok && parsed.doc != null) _multiDocs[id] = parsed.doc!;
    }
    _multiSourceIds = ids;
  }

  void _mirrorSelectedSources(PatternDoc before, PatternDoc after) {
    if (!_multiEditEnabled) return;
    for (final id in _multiDocs.keys.toList()) {
      _multiDocs[id] = _multiDocs[id]!.mirrorChanges(before, after);
    }
  }

  // ---------- edits ----------

  Steps get _resSteps => _triplet ? Steps(32, _res * 3) : Steps(16, _res);

  /// The finest grid level shown at this zoom: lines at least 10 px apart, never finer than the resolution.
  Steps _levelFor(double minPx) {
    var steps = _triplet ? Steps(128, 3) : Steps(16 * 4, 1); // start at 4 bars' worth (or its triplet) and halve
    // Far out, 16, 64, 256… bars' worth, so the lines stay apart.
    while (steps.toDouble() * _pxPerStep < minPx && steps.toDouble() < 1e9) {
      steps = Steps(steps.numerator * 4, steps.denominator);
    }
    final finest = _snap ? _resSteps : Steps(1, 128);
    while (true) {
      final half = Steps(steps.numerator, steps.denominator * 2);
      if (half < finest || half.toDouble() * _pxPerStep < minPx) break;
      steps = half;
    }
    return _fixed ? finest : (steps < finest ? finest : steps);
  }

  Steps get _lineLevel => _levelFor(10);
  // Finger-sized taps on a phone: the device's screen decides, not the panel's size (a docked panel is smaller).
  Steps get _tapLevel {
    final view = View.of(context);
    final screen = view.physicalSize / view.devicePixelRatio;
    return _levelFor(screen.shortestSide < 600 ? 48 : 24);
  }

  void _apply(PatternDoc next, {Set<int>? select}) {
    final d = _doc;
    if (d == null || identical(next, d)) return;
    _mirrorSelectedSources(d, next);
    _pushUndo(_Undo(d));
    _animateEdit(d, next);
    setState(() {
      _doc = next;
      if (select != null) _sel = select;
      _sel = _sel.where((id) => next.byId(id) != null).toSet();
    });
    _scheduleSend();
  }

  // The text and the engine are updated after a short pause, not on every touch (light on low-end phones).
  void _scheduleSend() {
    _sendTimer?.cancel();
    _sendTimer = Timer(const Duration(milliseconds: 150), _flush);
  }

  /// The doc the module's source last came from or was written from: an unedited roll writes nothing (an empty
  /// pattern's source stays empty instead of gaining a header).
  PatternDoc? _written;

  /// Writes the roll's notes to the module (and the engine). [closing]: from dispose, which runs while the tree is
  /// locked, so the write (whose notification rebuilds the app) waits for the end of the frame.
  void _flush({bool closing = false}) {
    _sendTimer?.cancel();
    _sendTimer = null;
    final d = _doc;
    if (d == null || identical(d, _written)) return;
    final text = d.serialize();
    _written = d;
    if (text == widget.module.source) return;
    _lastText = text;
    if (closing && SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      final s = this.s, id = widget.module.id, multi = _multiEditEnabled ? {for (final e in _multiDocs.entries) e.key: e.value.serialize()} : const <String, String>{};
      SchedulerBinding.instance.addPostFrameCallback((_) => _write(s, id, text, multi));
      return;
    }
    _write(s, widget.module.id, text, {
      if (_multiEditEnabled)
        for (final e in _multiDocs.entries) e.key: e.value.serialize()
    });
  }

  static void _write(AppState s, String id, String text, Map<String, String> multi) {
    s.editSource(id, text);
    s.run(id);
    for (final entry in multi.entries) {
      if (s.project.module(entry.key)?.source == entry.value) continue;
      s.editSource(entry.key, entry.value);
      s.run(entry.key);
    }
  }

  /// A drag step while the song plays: a sounding note follows it (AppState.livePattern). The roll doesn't rebuild:
  /// only the text goes, about 30 times a second.
  void _live(PatternDoc d) {
    if (!s.meters.playing) return;
    _liveDoc = d;
    _liveTimer ??= Timer(const Duration(milliseconds: 33), () {
      _liveTimer = null;
      final next = _liveDoc;
      _liveDoc = null;
      if (next == null || !mounted) return;
      _liveSent = true;
      s.livePattern(widget.module.id, next.serialize());
    });
  }

  /// Stops sending drag steps; whether any went.
  bool _liveEnd() {
    _liveTimer?.cancel();
    _liveTimer = null;
    _liveDoc = null;
    final sent = _liveSent;
    _liveSent = false;
    return sent;
  }

  /// After a drag that was heard live: the result goes now (no pause), or the engine gets the pattern back as it is.
  void _liveDone() {
    final d = _doc;
    if (d != null && d.serialize() != widget.module.source) {
      _flush();
    } else {
      s.livePattern(widget.module.id, null);
    }
  }

  void _pushUndo(_Undo u) {
    _undo.add(u);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
  }

  void _undoRedo(bool undo) {
    final from = undo ? _undo : _redo, to = undo ? _redo : _undo;
    if (from.isEmpty || _doc == null) return;
    final before = _doc!;
    final step = from.removeLast();
    final sel = step.sel;
    if (sel != null) {
      // A selection step: the notes stay, the selection goes back (or forward) to what it was.
      to.add(_Undo(before, sel: _sel));
      setState(() => _sel = sel.where((id) => before.byId(id) != null).toSet());
      return;
    }
    final next = step.doc;
    _mirrorSelectedSources(before, next);
    to.add(_Undo(before));
    _animateEdit(before, next);
    setState(() => _doc = next);
    _scheduleSend();
  }

  /// Remembers the selection's velocity for the next drawn note.
  void _keepVel() {
    final n = _sel.isEmpty ? null : _doc?.byId(_sel.first);
    if (n != null) _lastVel = n.vel;
  }

  /// Moves and stretches snap to the grid unless snapping is off, Shift is held or a second finger rests on the roll.
  bool get _free => !_snap || _bypass || HardwareKeyboard.instance.isShiftPressed;

  /// A volume, timbre, velocity or chance value (0..1) on the value grid while snapping applies.
  double _snapValue(double v) => (_free ? v : Snap.to(v, _look.valueGrid.step)).clamp(0.0, 1.0).toDouble();

  /// A curve point's time (in steps) on the time grid while snapping applies.
  double _snapAt(double steps) => math.max(0.0, _free ? steps : Snap.to(steps, _resSteps.toDouble()));

  void _snapMenu(String v) {
    if (v == 'toggle') {
      setState(() => _snap = !_snap);
    } else if (v.startsWith('res:')) {
      setState(() => _res = int.parse(v.substring(4)));
    } else if (v == 'triplets') {
      setState(() => _triplet = !_triplet);
    } else if (v == 'adaptive') {
      setState(() => _fixed = !_fixed);
    } else if (v.startsWith('value:')) {
      final g = ValueGrid.values.byName(v.substring(6));
      s.settings.update((x) => x.roll = x.roll.copyWith(valueGrid: g));
    }
  }

  Steps _snapTime(double steps, Steps level) {
    final t = Steps.fromDouble(math.max(0, steps), maxDenominator: 384);
    return _snap ? t.floorTo(level) : t;
  }

  // ---------- keys ----------

  /// The roll's actions (docs/actions.md), run by keys, toolbars and macros through the key router.
  bool _action(String id, int count, String? arg) {
    // Save writes the roll's pending edit into the project first, then the router's global save runs.
    if (id == 'project.save') {
      _flush();
      return false;
    }
    final d = _doc;
    if (d == null) return false;
    final g = _resSteps.times(count);
    void moveCursor(int dir) => setState(() {
          if (dir == 0) _cursorPitch = math.min(127, _cursorPitch + count);
          if (dir == 1) _cursorPitch = math.max(0, _cursorPitch - count);
          if (dir == 2) _cursorAt = Steps.max(Steps.zero, _cursorAt - g);
          if (dir == 3) _cursorAt = _cursorAt + g;
          if (_router?.vim.selecting ?? false) {
            _sel = {..._sel, ...d.notesIn(_cursorAt, _cursorAt, _cursorPitch, _cursorPitch)};
          } else {
            _sel = d.notesIn(_cursorAt, _cursorAt, _cursorPitch, _cursorPitch);
          }
        });
    void jump(int dir) => setState(() {
          for (var i = 0; i < count; i++) {
            final id = d.nextNoteFrom(_cursorAt, _cursorPitch, dir == 1 || dir == 2 ? -1 : 1);
            final n = id == null ? null : d.byId(id);
            if (n == null) break;
            _cursorAt = n.at;
            _cursorPitch = n.pitch;
            _sel = {n.id};
          }
        });
    void times(PatternDoc Function(PatternDoc) f) {
      var x = d;
      for (var i = 0; i < count; i++) {
        x = f(x);
      }
      _apply(x);
    }

    final div = const {'div1': 1, 'div2': 2, 'div4': 4, 'div8': 8, 'div16': 16, 'div32': 32, 'div64': 64, 'div128': 128};
    switch (id) {
      case 'roll.notes.later':
        _apply(d.move(_sel, g, 0));
      case 'roll.notes.earlier':
        _apply(d.move(_sel, -g, 0));
      case 'roll.notes.up':
        _apply(d.move(_sel, Steps.zero, count.toDouble()));
      case 'roll.notes.down':
        _apply(d.move(_sel, Steps.zero, -count.toDouble()));
      case 'roll.cursor.up':
        moveCursor(0);
      case 'roll.cursor.down':
        moveCursor(1);
      case 'roll.cursor.left':
        moveCursor(2);
      case 'roll.cursor.right':
        moveCursor(3);
      case 'roll.cursor.jumpUp' || 'roll.select.next':
        jump(0);
      case 'roll.cursor.jumpDown':
        jump(1);
      case 'roll.cursor.jumpLeft' || 'roll.select.prev':
        jump(2);
      case 'roll.cursor.jumpRight':
        jump(3);
      case 'roll.notes.insert':
        final r = d.insert(_cursorAt, _cursorPitch, _lastLen ?? _resSteps, vel: _lastVel);
        if (r.id != null) _apply(r.doc, select: {r.id!});
      case 'roll.select.copyafter':
        var x = d;
        var sel = _sel;
        for (var i = 0; i < count && sel.isNotEmpty; i++) {
          final r = x.copyAfter(sel, grid: _pasteGrid);
          x = r.doc;
          sel = r.ids;
        }
        _apply(x, select: sel);
      case 'roll.notes.shorter':
        _apply(d.resize(_sel, -g));
      case 'roll.notes.longer':
        _apply(d.resize(_sel, g));
      case 'roll.notes.invertUp':
        times((x) => x.invertUp(_sel));
      case 'roll.notes.invertDown':
        times((x) => x.invertDown(_sel));
      case 'roll.notes.delete':
        _apply(d.delete(_sel), select: {});
      case 'roll.edit.cut':
        _copy(d);
        _apply(d.delete(_sel), select: {});
      case 'roll.select.all':
        setState(() => _sel = {for (final n in d.notes) n.id});
      case 'roll.select.none':
        // Esc with nothing selected leaves the full-screen roll.
        if (_sel.isEmpty && widget.fullScreen) {
          _closeFullScreen();
        } else {
          setState(() => _sel = {});
        }
      case 'roll.select.addAtCursor':
        setState(() => _sel = {..._sel, ...d.notesIn(_cursorAt, _cursorAt, _cursorPitch, _cursorPitch)});
      case 'roll.edit.copy':
        if (_sel.isNotEmpty) setState(() => _copy(d));
      case 'roll.edit.paste':
        final c = _clip;
        if (c == null || c.isEmpty) return true;
        // Right after the copied notes (owner, 2026-11-11), then after each paste, so pastes chain end to end; the
        // copy becomes the selection.
        var x = d;
        var ids = <int>{};
        for (var i = 0; i < count; i++) {
          final at = _pasteAt ?? _cursorAt;
          final r = x.paste(c, at);
          x = r.doc;
          ids = r.ids;
          _pasteAt = _afterSpan(at, c.span);
        }
        _apply(x, select: ids);
      case 'roll.edit.duplicate':
        final r = d.copyAfter(_sel, grid: _pasteGrid);
        _apply(r.doc, select: r.ids);
      case 'roll.notes.split':
        final r = d.split(_sel, _cursorAt);
        _apply(r.doc, select: r.ids);
      case 'roll.notes.join':
        final r = d.join(_sel);
        _apply(r.doc, select: r.ids);
      case 'roll.notes.quantize':
        _apply(d.quantize(_sel.isEmpty ? {for (final n in d.notes) n.id} : _sel, _resSteps));
      case 'roll.notes.quantizeSheet':
        _quantizeSheet();
      case 'roll.step.toggle':
        _stepToggle();
      case 'roll.step.rest':
        if (_step) _stepAdvance(_resSteps.times(count));
      case 'roll.gen.euclid' ||
            'roll.gen.random' ||
            'roll.gen.arpeggiate' ||
            'roll.gen.humanize' ||
            'roll.gen.chordStamp' ||
            'roll.gen.connect' ||
            'roll.gen.tremolo':
        _generate(id);
      case 'roll.gen.vibrato':
        _vibrato();
      case 'roll.gen.reverse':
        _apply(d.reverse(_sel));
      case 'roll.gen.invertPitch':
        _apply(d.invertPitch(_sel, _cursorPitch));
      case 'roll.gen.legato':
        _apply(d.legato(_sel));
      case 'roll.vel.up':
        _apply(d.addVelocity(_sel, 0.1 * count));
        _keepVel();
      case 'roll.vel.down':
        _apply(d.addVelocity(_sel, -0.1 * count));
        _keepVel();
      case 'roll.vel.upFine':
        _apply(d.addVelocity(_sel, 0.01 * count));
        _keepVel();
      case 'roll.vel.downFine':
        _apply(d.addVelocity(_sel, -0.01 * count));
        _keepVel();
      case 'roll.vel.set':
        final v = double.tryParse(arg ?? '');
        if (v == null) return true;
        _apply(d.setVelocity(_sel, v > 1 ? v / 100 : v));
        _keepVel();
      case 'roll.prob.cycle':
        times((x) => x.cycleProb(_sel));
      case 'roll.ratchet.cycle':
        times((x) => x.cycleRatchet(_sel));
      case 'roll.slide.toggle':
        _apply(d.toggleSlide(_sel));
      case 'roll.notes.extras':
        _openExtras();
      case 'roll.grid.triplets':
        setState(() => _triplet = !_triplet);
      case 'roll.grid.snap':
        setState(() => _snap = !_snap);
      case 'roll.grid.adaptive':
        setState(() => _fixed = !_fixed);
      case 'roll.grid.set':
        final r = int.tryParse((arg ?? '').replaceFirst('1/', ''));
        if (r == null || !_resolutions.contains(r)) return true;
        setState(() => _res = r);
      case 'roll.tool.draw':
        setState(() => _tool = PatternTool.draw);
      case 'roll.tool.select':
        setState(() => _tool = PatternTool.select);
      case 'roll.tool.curve':
        setState(() => _tool = PatternTool.curve);
      case 'roll.tool.erase':
        setState(() => _tool = PatternTool.erase);
      case 'roll.tool.ratchet':
        setState(() => _tool = PatternTool.ratchet);
      case 'roll.view.switch':
        setState(() => _grid = !_grid);
      case 'roll.view.zoomIn':
        _animateViewTo(px: _pxAim * 1.25);
      case 'roll.view.zoomOut':
        _animateViewTo(px: _pxAim / 1.25);
      case 'roll.view.fit':
        // Clamped like zoom, so a very long pattern scrolls instead of drawing millions of grid lines.
        _animateViewTo(leftStep: 0, px: (math.max(4.0, (context.size?.width ?? 400) - _keyW) /
            math.max(1, d.lengthSteps(s.project.beatsPerBar))).clamp(4.0, 200.0).toDouble());
      case 'roll.view.velocityLane':
        setState(() => _velLane = !_velLane);
      case 'roll.view.extrasLanes':
        setState(() => _extrasLane = !_extrasLane);
      case 'edit.undo':
        for (var i = 0; i < count; i++) {
          _undoRedo(true);
        }
      case 'edit.redo':
        for (var i = 0; i < count; i++) {
          _undoRedo(false);
        }
      default:
        final r = div[id.replaceFirst('roll.grid.', '')];
        if (r == null) return false;
        setState(() => _res = r);
    }
    return true;
  }

  PatternClip? _clip;
  Steps? _pasteAt; // where the next paste goes: after the copied notes, then after the last paste

  /// The grid a paste or a copy-after lands on: the roll's while snapping, else none.
  Steps? get _pasteGrid => _snap ? _resSteps : null;

  /// The first grid line at or after [at] + [span] (exactly there when not snapping).
  Steps _afterSpan(Steps at, Steps span) {
    final end = at + span, g = _pasteGrid;
    return g == null ? end : end.ceilTo(g);
  }

  /// Copies the selection; the next paste lands right after it.
  void _copy(PatternDoc d) {
    final c = d.copy(_sel);
    if (c.isEmpty) return;
    _clip = c;
    _pasteAt = _afterSpan(_selected(d).map((n) => n.at).reduce(Steps.min), c.span);
  }

  List<PatternNote> _selected(PatternDoc d) => [for (final id in _sel) ?d.byId(id)];

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Keys go through the action system first (keymap, counts, macros); what it doesn't bind falls through to here.
    if (_router?.handle(e, area: Area.pattern) == KeyEventResult.handled) return KeyEventResult.handled;
    final d = _doc;
    if (d == null) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed, shift = hw.isShiftPressed, alt = hw.isAltPressed;
    int? dir(LogicalKeyboardKey k) => switch (k) {
          LogicalKeyboardKey.keyW || LogicalKeyboardKey.arrowUp => 0,
          LogicalKeyboardKey.keyS || LogicalKeyboardKey.arrowDown => 1,
          LogicalKeyboardKey.keyA || LogicalKeyboardKey.arrowLeft => 2,
          LogicalKeyboardKey.keyD || LogicalKeyboardKey.arrowRight => 3,
          _ => null,
        };
    final g = _resSteps;
    // Ctrl+S saves here too (owner, 2026-11-11: it saves everywhere); the cursor moves down with Ctrl+Down.
    if (ctrl && !shift && !alt && k == LogicalKeyboardKey.keyS) {
      _flush();
      unawaited(s.flush());
      return KeyEventResult.handled;
    }
    final dd = dir(k);
    if (alt) {
      final digit = k.keyLabel.isNotEmpty ? int.tryParse(k.keyLabel) : null;
      if (digit == 0) {
        setState(() => _triplet = !_triplet);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyV || k == LogicalKeyboardKey.keyX) {
        setState(() => k == LogicalKeyboardKey.keyV ? _velLane = !_velLane : _extrasLane = !_extrasLane);
        return KeyEventResult.handled;
      }
      if (digit != null && digit >= 1 && digit <= 8) {
        setState(() => _res = _resolutions[digit - 1]);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyF) {
        setState(() => _fixed = !_fixed);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (dd != null && ctrl) {
      // Ctrl moves the cursor a step; Ctrl+Shift jumps to the next note that way. The note it lands on is selected.
      setState(() {
        if (shift) {
          final id = d.nextNoteFrom(_cursorAt, _cursorPitch, dd);
          final n = id == null ? null : d.byId(id);
          if (n != null) {
            _cursorAt = n.at;
            _cursorPitch = n.pitch;
            _sel = {n.id};
          }
        } else {
          if (dd == 0) _cursorPitch = math.min(127, _cursorPitch + 1);
          if (dd == 1) _cursorPitch = math.max(0, _cursorPitch - 1);
          if (dd == 2) _cursorAt = Steps.max(Steps.zero, _cursorAt - g);
          if (dd == 3) _cursorAt = _cursorAt + g;
          final hit = d.notesIn(_cursorAt, _cursorAt + Steps(1, 1024), _cursorPitch, _cursorPitch);
          _sel = hit;
        }
      });
      return KeyEventResult.handled;
    }
    if (dd != null && shift) {
      if (dd == 2 || dd == 3) _apply(d.resize(_sel, dd == 3 ? g : -g));
      if (dd == 0) _apply(d.invertUp(_sel));
      if (dd == 1) _apply(d.invertDown(_sel));
      return KeyEventResult.handled;
    }
    if (dd != null) {
      if (_sel.isEmpty) return KeyEventResult.handled;
      _apply(d.move(_sel, dd == 2 ? -g : (dd == 3 ? g : Steps.zero), dd == 0 ? 1 : (dd == 1 ? -1 : 0)));
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      _undoRedo(!shift);
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyY) {
      _undoRedo(false);
      return KeyEventResult.handled;
    }
    if (ctrl) return KeyEventResult.ignored;
    switch (k) {
      case LogicalKeyboardKey.keyQ:
        final r = d.insert(_cursorAt, _cursorPitch, _lastLen ?? g, vel: _lastVel);
        if (r.id != null) _apply(r.doc, select: {r.id!});
      case LogicalKeyboardKey.keyE:
        if (_sel.isNotEmpty) {
          final r = d.copyAfter(_sel, grid: _pasteGrid);
          _apply(r.doc, select: r.ids);
        }
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        _apply(d.delete(_sel), select: {});
      case LogicalKeyboardKey.escape:
        if (_sel.isEmpty && widget.fullScreen) {
          _closeFullScreen();
        } else {
          setState(() => _sel = {});
        }
      case LogicalKeyboardKey.equal:
        _apply(d.addVelocity(_sel, 0.1));
      case LogicalKeyboardKey.minus:
        _apply(d.addVelocity(_sel, -0.1));
      case LogicalKeyboardKey.keyP:
        _apply(d.cycleProb(_sel));
      case LogicalKeyboardKey.keyR:
        _apply(d.cycleRatchet(_sel));
      case LogicalKeyboardKey.keyL:
        _apply(d.toggleSlide(_sel));
      case LogicalKeyboardKey.keyN:
        setState(() => _snap = !_snap);
      case LogicalKeyboardKey.keyB:
        setState(() => _tool = PatternTool.draw);
      case LogicalKeyboardKey.keyV:
        setState(() => _tool = PatternTool.select);
      case LogicalKeyboardKey.keyX:
        setState(() => _tool = PatternTool.erase);
      case LogicalKeyboardKey.keyG:
        setState(() => _grid = !_grid);
      case LogicalKeyboardKey.enter:
        _flush();
      case LogicalKeyboardKey.keyI:
        if (_sel.isNotEmpty) _openExtras();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static final ActionRegistry _fallbackRegistry = ActionRegistry.standard();
  static final Keymap _fallbackKeymap = Keymap.defaults(_fallbackRegistry);

  /// A toolbar button: through the key router (so `.`, recording and toasts see it), or straight to the roll when
  /// there is no router (tests, previews).
  /// Leaves the full-screen roll (its pending edit is written first).
  void _closeFullScreen() {
    _flush();
    Navigator.of(context).maybePop();
  }

  void _runRef(ActionRef r) {
    final router = _router;
    if (router != null) {
      // The router runs a roll action on the focused roll; give this one focus first (applied before the next task).
      _focus.requestFocus();
      Future(() => router.runRef(r));
    } else if (!r.isMacro) {
      _action(r.id, 1, null);
    }
  }

  // ---------- curve tool ----------

  void _setCurve(int lane, LaneCurve c) => setState(() => _curves = {..._curves, lane: c});

  /// A lane's top and height in grid coordinates (1 velocity, 2 chance).
  (double, double) _laneBox(int lane) =>
      lane == 1 ? (_gridH, _velH) : (_gridH + (_velLane ? _velH : 0), _xH);

  double _laneValue(int lane, double y) {
    final (top, hgt) = _laneBox(lane);
    return (1 - (y - top - 3) / (hgt - 6)).clamp(0.0, 1.0);
  }

  Offset _curvePx(int lane, CurvePoint q) {
    final (top, hgt) = _laneBox(lane);
    return Offset(q.at * _pxPerStep - _scrollX, top + 3 + (1 - q.value) * (hgt - 6));
  }

  /// A tap on the grid with the Curve tool: adds the note under it to the notes the curves shape, or clears them.
  void _pickForCurve(Offset p) {
    final hit = _noteAt(p);
    if (hit == null) return _emptyTapped(p);
    setState(() => _sel = _sel.contains(hit) ? (Set.of(_sel)..remove(hit)) : {..._sel, hit});
  }

  void _curveDown(Offset p) {
    final d = _doc;
    if (d == null) return;
    final lane = _velLane && p.dy < _gridH + _velH ? 1 : (_extrasLane ? 2 : 0);
    if (lane == 0) return;
    _cLane = lane;
    _cStart = p;
    _dragBase = d;
    final c = _cBase = _curves[lane]!;
    // Near a point: drag it (hold to delete). Inside a segment: wait to see a tap (add) or a drag (bend). Else add.
    for (var i = 0; i < c.points.length; i++) {
      if ((_curvePx(lane, c.points[i]) - p).distance < math.max(16, _look.grab)) {
        _cPoint = i;
        _hold = Timer(Duration(milliseconds: _look.holdMs), () {
          _setCurve(lane, _curves[lane]!.remove(i));
          _cPoint = null;
          _shapeNotes();
        });
        _holdAt = p;
        return;
      }
    }
    final seg = c.segmentAt(_stepAt(p.dx));
    if (seg != null) {
      _cSeg = seg;
      _cBend0 = c.points[seg].bend;
      _cAddOnTap = true;
      return;
    }
    final (added, i) = c.add(_snapAt(_stepAt(p.dx)), _snapValue(_laneValue(lane, p.dy)));
    _setCurve(lane, added);
    _cPoint = i;
    _shapeNotes();
  }

  void _curveMove(Offset p) {
    final lane = _cLane, start = _cStart;
    if (start == null) return;
    if (_hold != null && (p - _holdAt!).distance > 8) {
      _hold!.cancel();
      _hold = null;
    }
    final i = _cPoint, seg = _cSeg;
    if (i != null) {
      _setCurve(lane, _curves[lane]!.move(i, _snapAt(_stepAt(p.dx)), _snapValue(_laneValue(lane, p.dy))));
    } else if (seg != null) {
      if (_cAddOnTap && (p - start).distance <= kTouchSlop) return;
      _cAddOnTap = false;
      // Dragging a segment up bends it to rise late (ease in), down to rise early.
      final (_, hgt) = _laneBox(lane);
      _setCurve(lane, _curves[lane]!.bend(seg, _cBend0 - (p.dy - start.dy) / hgt * 2));
    }
    _shapeNotes();
  }

  void _curveEnd({required bool cancel}) {
    if (_cLane == 0) return;
    _hold?.cancel();
    _hold = null;
    final start = _cStart;
    if (!cancel && _cAddOnTap && start != null) {
      final (added, _) = _curves[_cLane]!.add(_snapAt(_stepAt(start.dx)), _snapValue(_laneValue(_cLane, start.dy)));
      _setCurve(_cLane, added);
      _shapeNotes();
    }
    if (cancel && _cBase != null) _setCurve(_cLane, _cBase!);
    _cLane = 0;
    _cPoint = _cSeg = null;
    _cStart = null;
    _cBase = null;
    _cAddOnTap = false;
    cancel ? _cancelEdit() : _up();
  }

  /// Sets the velocity (or chance) of the selected notes, or of every note when none is selected, from the lane's
  /// curve; notes outside its first and last points keep their value. One undo step per gesture.
  void _shapeNotes() {
    final base = _dragBase, lane = _cLane;
    if (base == null || lane == 0) return;
    final c = _curves[lane]!;
    if (c.isEmpty) return setState(() => _doc = base);
    final first = c.points.first.at, last = c.points.last.at;
    final targets = {
      for (final n in base.notes)
        if ((_sel.isEmpty || _sel.contains(n.id)) && n.at.toDouble() >= first && n.at.toDouble() <= last) n.id
    };
    setState(() => _doc = base.shape(targets, (n) => c.valueAt(n.at.toDouble()), chance: lane == 2));
  }

  // ---------- pitch curves on notes (Curve tool) ----------
  // Any note's curve is edited where it is drawn, no selection first (owner, 2026-11-10, #170): the nearest point
  // under the touch, else the nearest line, else the note itself. While a drag is under way its points live in
  // [_curveView] and only the overlay repaints, once a frame; the model and undo get them when the finger lifts.

  static const _bendRange = 12.0; // the owner's default: +-12 semitones on screen (the file allows +-48)

  double _noteX(PatternNote n) => n.at.toDouble() * _pxPerStep - _scrollX;
  double _noteW(PatternNote n) => math.max(3.0, n.len.toDouble() * _pxPerStep - 1);
  double _noteMid(PatternNote n) => (127 - n.pitch.round()) * _rowH - _scrollY + _rowH / 2;
  Offset _bendPx(PatternNote n, NotePoint q) => Offset(_noteX(n) + q.t * _noteW(n), _noteMid(n) - q.v * _rowH);

  /// How far a curve's touch zone reaches: 24 dp for a finger or pen, the grab setting for a mouse.
  double _curveReach(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad ? _look.grab : math.max(24.0, _look.grab);

  /// What a touch at [p] on the grid grabs with the Curve tool: the nearest pitch point within [reach] of any note,
  /// else the nearest pitch line (a plain note's line is its row's middle), else the note under it.
  _CurveHit? _curveHitAt(Offset p, double reach) {
    final d = _doc;
    if (d == null || p.dy >= _gridH) return null;
    _CurveHit? point, line;
    var pointD = reach, lineD = reach;
    for (final n in d.notes) {
      final x0 = _noteX(n), w = _noteW(n);
      if (p.dx < x0 - reach || p.dx > x0 + w + reach) continue;
      final pts = n.expr.bend;
      for (var i = 0; i < pts.length; i++) {
        final dist = (_bendPx(n, pts[i]) - p).distance;
        if (dist <= pointD) {
          pointD = dist;
          point = _CurveHit(n.id, point: i);
        }
      }
      if (point != null) continue; // a point anywhere wins over every line
      // The line near the touch, every 2 px across the reach.
      final mid = _noteMid(n);
      for (var dx = -reach; dx <= reach; dx += 2) {
        final x = p.dx + dx;
        if (x < x0 || x > x0 + w) continue;
        final y = mid - displayCurveAt(pts, (x - x0) / w, w) * _rowH;
        final dist = Offset(dx, p.dy - y).distance;
        if (dist <= lineD) {
          lineD = dist;
          line = _CurveHit(n.id, line: true);
        }
      }
    }
    if (point != null) return point;
    // A selected note's tension handles come next: they sit on its line.
    _CurveHit? handle;
    var handleD = reach;
    for (final n in d.notes) {
      if (!_sel.contains(n.id) || n.expr.bend.length < 2) continue;
      final x0 = _noteX(n), w = _noteW(n), mid = _noteMid(n);
      for (final h in curveHandles(n.expr.bend, w)) {
        final dist = (Offset(x0 + h.u * w, mid - h.v * _rowH) - p).distance;
        if (dist <= handleD) {
          handleD = dist;
          handle = _CurveHit(n.id, handle: h.seg);
        }
      }
    }
    if (handle != null) return handle;
    if (line != null) return line;
    final body = _noteAt(p);
    return body == null ? null : _CurveHit(body);
  }

  /// Where the finger at [y] puts a pitch point of [n]: on a semitone while snapping applies, sticking to [prev]
  /// until the finger is well past halfway to the next one, so a finger resting on a boundary doesn't flicker.
  double _bendValue(double y, PatternNote n, {double? prev}) {
    var v = (_noteMid(n) - y) / _rowH;
    if (!_free) v = _sticky(v, prev, 1);
    return v.clamp(-_bendRange, _bendRange).toDouble();
  }

  /// A point's place along [n] (0..1) under the finger at [x], on the time grid (sticky, as above) while snapping.
  double _bendU(double x, PatternNote n, {double? prev}) {
    final u = (x - _noteX(n)) / _noteW(n), g = _resSteps.toDouble() / n.len.toDouble();
    return (_free || g >= 1 ? u : _sticky(u, prev, g)).clamp(0.0, 1.0).toDouble();
  }

  /// [raw] on a grid of [g], staying on [prev] until [raw] is 0.65 of a grid step from it.
  static double _sticky(double raw, double? prev, double g) =>
      prev != null && (raw - prev).abs() < g * 0.65 ? prev : Snap.to(raw, g);

  // The pitch edit under way: the note, what was grabbed and how.
  int? _bNote, _bPoint, _bSeg;
  _CurveHit? _bHit;
  double _bK0 = 0;
  Offset? _bStart, _bAt, _bSmooth;
  bool _bMoved = false, _bFrame = false, _bHandle = false;
  ({int id, int point, DateTime at})? _bTapped; // the last point tapped: a second tap soon after removes it

  List<NotePoint> get _livePoints => _curveView.value.points ?? _doc!.byId(_bNote!)!.expr.bend;

  /// Shows [points] as note [_bNote]'s curve, [active] the point that follows the finger. The roll itself repaints
  /// only when a drag starts showing points (it then leaves that note to the overlay).
  void _showLive(List<NotePoint> points, {int? active, bool drawing = false, int? handle}) {
    final first = _curveView.value.points == null;
    _curveView.value =
        _CurveView(hit: _bHit, id: _bNote, points: points, active: active, drawing: drawing, handle: handle);
    if (first) setState(() {});
  }

  void _bendDown(Offset p, _CurveHit hit) {
    final d = _doc!, n = d.byId(hit.id)!;
    _dragBase = d;
    _bNote = hit.id;
    _bHit = hit;
    _bStart = _bAt = _bSmooth = p;
    _bMoved = false;
    _bPoint = _bSeg = null;
    _curveView.value = _CurveView(hit: hit);
    final pts = n.expr.bend;
    if (hit.point != null) {
      final i = hit.point!;
      _bPoint = i;
      _showLive(pts, active: i);
      _holdAt = p;
      _hold = Timer(Duration(milliseconds: _look.holdMs), () {
        final now = _livePoints;
        if (i < now.length) _showLive([...now]..removeAt(i));
        // Held down: the point is gone and the rest of this touch does nothing.
        _bPoint = null;
        _bSeg = -1;
        _bMoved = true;
        _hearStop();
      });
      _hearBendAt(p);
      return;
    }
    if (hit.handle != null && hit.handle! + 1 < pts.length) {
      // A tension handle follows the finger at once: the segment bends to pass under it.
      _bSeg = hit.handle;
      _bHandle = true;
      _bK0 = pts[hit.handle!].k;
      _showLive(pts, handle: hit.handle);
      final seg = hit.handle!;
      _holdAt = p;
      _hold = Timer(Duration(milliseconds: _look.holdMs), () {
        // Held down: the segment goes straight and the rest of this touch does nothing.
        final now = [..._livePoints];
        if (seg < now.length) now[seg] = NotePoint(now[seg].t, now[seg].v);
        _showLive(now);
        _bSeg = -1;
        _bMoved = true;
        Haptics.tick();
      });
      return;
    }
    if (hit.line && pts.length > 1) {
      final raw = ((p.dx - _noteX(n)) / _noteW(n)).clamp(0.0, 1.0);
      for (var i = 0; i + 1 < pts.length; i++) {
        if (raw > pts[i].t && raw < pts[i + 1].t) {
          _bSeg = i;
          _bK0 = pts[i].k;
          return; // a tap adds a point here, a drag bends the segment
        }
      }
    }
    // Elsewhere on the line or the note: a tap selects, a drag places a new point.
  }

  List<NotePoint> _insertPoint(List<NotePoint> pts, NotePoint q) {
    final out = [...pts];
    final i = out.indexWhere((x) => x.t > q.t);
    out.insert(i < 0 ? out.length : i, q);
    return out;
  }

  /// A move during a pitch edit: kept, and applied once on the next frame however many events arrive before it.
  void _bendMove(Offset p) {
    _bAt = p;
    if (_hold != null && (p - _holdAt!).distance > 8) {
      _hold!.cancel();
      _hold = null;
    }
    if (_bFrame) return;
    _bFrame = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (_bFrame) _bendApply();
    });
  }

  void _bendApply({bool last = false}) {
    _bFrame = false;
    final id = _bNote, start = _bStart, raw = _bAt, d = _dragBase;
    if (id == null || start == null || raw == null || d == null || !mounted) return;
    final n = d.byId(id);
    if (n == null || _bSeg == -1) return;
    // A point follows the finger at once (snapping keeps it still); a line or a note waits past the touch slop to
    // tell a drag from a tap. Past the slop, it is no longer a tap.
    if (!_bMoved && (raw - start).distance > kTouchSlop) {
      _bMoved = true;
      _tapClear();
    }
    if (!_bMoved && ((_bPoint == null && !_bHandle) || (raw - start).distance < 2)) return;
    _selectForCurve(id);
    // Free (unsnapped) drags follow a lightly smoothed finger; the release lands where the finger is.
    final s0 = _bSmooth ?? raw;
    final p = _bSmooth = last || !_free ? raw : s0 + (raw - s0) * 0.6;
    var pts = [..._livePoints];
    var i = _bPoint;
    final seg = _bSeg;
    if (i == null && seg == null) {
      // Placing a new point. A plain note's curve starts at its own pitch: that anchor, then the point.
      final q = NotePoint(_bendU(p.dx, n), _bendValue(p.dy, n));
      pts = pts.isEmpty && q.t > 0.02 ? [const NotePoint(0, 0), q] : _insertPoint(pts, q);
      i = _bPoint = pts.indexOf(q);
      _showLive(pts, active: i, drawing: true);
    } else if (i != null && i < pts.length) {
      final lo = i > 0 ? pts[i - 1].t : 0.0, hi = i + 1 < pts.length ? pts[i + 1].t : 1.0;
      final u = _bendU(p.dx, n, prev: pts[i].t).clamp(lo, hi);
      pts[i] = NotePoint(u, _bendValue(p.dy, n, prev: pts[i].v), pts[i].k);
      _showLive(pts, active: i, drawing: _curveView.value.drawing);
    } else if (_bHandle && seg != null && seg + 1 < pts.length) {
      // The handle: the segment's middle goes where the finger is (its tension, k, stored on the segment's start).
      final a = pts[seg], b = pts[seg + 1];
      pts[seg] = NotePoint(a.t, a.v, tensionThrough(a.v, b.v, (_noteMid(n) - p.dy) / _rowH));
      _showLive(pts, handle: seg);
    } else if (seg != null && seg < pts.length) {
      // Dragging the line up bends it to rise late (eases in), down to rise early, as on the lanes.
      final k = (_bK0 - (raw.dy - start.dy) / 120).clamp(-1.0, 1.0);
      pts[seg] = NotePoint(pts[seg].t, pts[seg].v, (k * 100).roundToDouble() / 100);
      _showLive(pts);
    }
    _live(d.setExpression({id}, n.expr.copyWith(bend: List.unmodifiable(pts))));
    _hearBendAt(p);
  }

  void _tapClear() => _bTapped = null;

  /// Editing a note's curve selects it, unless it already is.
  void _selectForCurve(int id) {
    if (!_sel.contains(id)) setState(() => _sel = {id});
  }

  void _bendEnd({required bool cancel}) {
    final id = _bNote, start = _bStart, base = _dragBase, hit = _bHit;
    if (id == null) return;
    _hold?.cancel();
    _hold = null;
    if (!cancel && _bAt != null) _bendApply(last: true);
    _hearStop();
    final n = base?.byId(id);
    var pts = _curveView.value.points;
    if (!cancel && !_bMoved && n != null && start != null && hit != null) {
      final now = DateTime.now();
      if (hit.point != null) {
        // A tap on a point: a second one on the same point soon after removes it.
        final t = _bTapped;
        if (t != null && t.id == id && t.point == hit.point && now.difference(t.at) < kDoubleTapTimeout) {
          pts = [...n.expr.bend]..removeAt(hit.point!);
          _bTapped = null;
        } else {
          _bTapped = (id: id, point: hit.point!, at: now);
        }
        _selectForCurve(id);
      } else if ((hit.line || hit.handle != null) && n.expr.bend.length > 1) {
        // A tap on a bent line (or its handle) adds a point there, on the line, so the curve keeps its shape.
        final u = _bendU(start.dx, n);
        pts = _insertPoint(n.expr.bend, NotePoint(u, NoteExpression.valueAt(n.expr.bend, u)));
        _bTapped = null;
        _selectForCurve(id);
      } else {
        // A tap on a plain note (or beside a bent one's line): picks it for the lane curves, or unpicks it.
        _bTapped = null;
        setState(() => _sel = _sel.contains(id) ? (Set.of(_sel)..remove(id)) : {..._sel, id});
      }
    }
    if (!cancel && base != null && n != null && pts != null && !_samePoints(pts, n.expr.bend)) {
      _doc = base.setExpression({id}, n.expr.copyWith(bend: List.unmodifiable(pts)));
    }
    _bNote = _bPoint = _bSeg = null;
    _bHit = null;
    _bStart = _bAt = _bSmooth = null;
    _bMoved = _bFrame = _bHandle = false;
    _curveView.value = const _CurveView();
    cancel ? _cancelEdit() : _up();
  }

  static bool _samePoints(List<NotePoint> a, List<NotePoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The mouse over the roll with the Curve tool: highlights what a click would grab.
  void _curveHover(PointerHoverEvent e) {
    if (_tool != PatternTool.curve || _bNote != null) return;
    final hit = _curveHitAt(e.localPosition - _origin, _curveReach(e.kind));
    if (hit != _curveView.value.hit) _curveView.value = _CurveView(hit: hit);
  }

  // ---------- generators ----------

  /// Asks for a generator's settings, then applies it as one undo step. Euclid and Random write from the cursor at the
  /// grid size; the others work on the selection.
  Future<void> _generate(String id) async {
    final d = _doc;
    if (d == null) return;
    final bar = Steps(s.project.beatsPerBar * 4);
    final seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    final v = await showDialogOrSheet<Map<String, double>>(
      context: context,
      builder: (_) => _GenDialog(id: id, rate: _resSteps),
    );
    if (v == null || !mounted || _doc == null) return;
    final doc = _doc!;
    switch (id) {
      case 'roll.gen.euclid':
        final r = doc.euclid(
            at: _cursorAt,
            pulses: v['pulses']!.round(),
            steps: v['steps']!.round(),
            rotate: v['rotate']!.round(),
            cell: _resSteps,
            pitch: _cursorPitch);
        _apply(r.doc, select: r.ids);
      case 'roll.gen.random':
        final range = v['range']!.round();
        final r = doc.randomInKey(
            at: _cursorAt,
            span: bar.times(v['bars']!.round()),
            cell: _resSteps,
            lo: (_cursorPitch - range).round(),
            hi: (_cursorPitch + range).round(),
            density: v['density']! / 100,
            key: _key,
            seed: seed);
        _apply(r.doc, select: r.ids);
      case 'roll.gen.arpeggiate':
        final r = doc.arpeggiate(_sel, _resSteps, order: const ['up', 'down', 'updown'][v['order']!.round()]);
        _apply(r.doc, select: r.ids);
      case 'roll.gen.humanize':
        _apply(doc.humanize(_sel, timing: v['timing']! / 100, velocity: v['velocity']! / 100, seed: seed));
      case 'roll.gen.chordStamp':
        final r = doc.chordStamp(_sel, key: _key, seventh: v['seventh']! > 0);
        _apply(r.doc, select: {..._sel, ...r.ids});
      case 'roll.gen.connect':
        _apply(doc.connect(_sel, glide: v['glide']! / 100));
      case 'roll.gen.tremolo':
        final wave = TremoloWave.values[v['wave']!.round()];
        final cycle = _tremoloCycles[v['cycle']!.round()];
        final depth = v['depth']! / 100;
        final sel = _sel.isEmpty ? {for (final n in doc.notes) n.id} : _sel;
        if (v['mode']!.round() == 1) {
          final r = doc.tremoloRepeat(sel, rate: _resSteps, cycle: cycle, depth: depth, wave: wave);
          _apply(r.doc, select: r.ids);
        } else {
          _apply(doc.tremolo(sel, cycle: cycle, depth: depth, wave: wave));
        }
    }
  }

  /// Vibrato (owner, 2026-11-11): sets the selected notes' own vibrato (every note when none is selected), the same
  /// values the extras panel's vibrato sliders show; their bend curves stay. A synced rate is turned into Hz at the
  /// project's tempo when it is applied. One undo step; repeatable (no randomness).
  Future<void> _vibrato() async {
    final d = _doc;
    if (d == null || d.notes.isEmpty) return;
    final v = await showDialogOrSheet<_Vibrato>(
      context: context,
      builder: (_) => _VibratoDialog(secPerStep: _secPerStep),
    );
    final doc = _doc;
    if (v == null || !mounted || doc == null) return;
    final sel = _sel.isEmpty ? {for (final n in doc.notes) n.id} : _sel;
    _apply(doc.setVibrato(sel, depth: v.cents / 100, rate: v.hz(_secPerStep), fade: v.fade));
  }

  // ---------- the quantize sheet (REAPER flow gap 8; REAPER's Quantize events, UG 13.23) ----------

  /// Opens the sheet; the roll shows (and, while playing, plays) each setting as it moves, and Apply makes it one
  /// undo step. Cancel or a swipe away puts the notes back. No selection: every note.
  Future<void> _quantizeSheet() async {
    final base = _doc;
    if (base == null) return;
    final sel = _sel.isEmpty ? {for (final n in base.notes) n.id} : _sel;
    final seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    PatternDoc result(_Quantize q) => base.quantizeWith(sel, q.grid,
        strength: q.strength, swing: q.swing, what: q.what, humanTiming: q.timing, humanVelocity: q.velocity, seed: seed);
    void preview(_Quantize? q) {
      if (!mounted) return;
      final next = q == null ? base : result(q);
      setState(() => _doc = next);
      _live(next);
    }

    final q = await showDialogOrSheet<_Quantize>(
      context: context,
      builder: (_) => _QuantizeSheet(res: _res, triplet: _triplet, count: sel.length, onPreview: preview),
    );
    if (!mounted) return;
    final sent = _liveEnd();
    setState(() => _doc = base);
    if (q == null) {
      if (sent) s.livePattern(widget.module.id, null);
      return;
    }
    _apply(result(q));
    if (sent) _flush();
  }

  // ---------- step input (REAPER flow gap 8; REAPER's step recording, UG 13.26) ----------
  // While on, each note played on the roll's keys or a MIDI keyboard goes in at the cursor, one grid long, and the
  // cursor moves on a grid step; keys pressed while others are held join their chord. Rest skips a step.

  bool _step = false;
  StreamSubscription<Object?>? _stepMidi;
  Steps _stepChordAt = Steps.zero;
  final Set<int> _stepHeld = {}; // pitches down now (keys and keyboard)
  final Map<int, ({int pitch, int? preview})> _stepKeys = {}; // roll-key pointers held

  void _stepToggle() {
    setState(() => _step = !_step);
    Haptics.tap();
    _stepMidi?.cancel();
    _stepMidi = null;
    _stepHeld.clear();
    _stepKeysOff();
    if (!_step) return;
    final live = LiveMidi.current;
    _stepMidi = live?.input?.messages.listen((m) {
      if (!mounted || !_step || !live.accepts(m)) return;
      if (m.isNoteOn) _stepNoteOn(m.data1, m.data2 / 127);
      if (m.isNoteOff) _stepHeld.remove(m.data1);
    });
  }

  /// A note played: a new step when no other key is down (the cursor moves on), else part of the held chord.
  void _stepNoteOn(int pitch, double vel) {
    final d = _doc;
    if (d == null) return;
    final len = _resSteps;
    if (_stepHeld.isEmpty) {
      _stepChordAt = _cursorAt;
      _stepAdvance(len);
    }
    _stepHeld.add(pitch);
    _cursorPitch = pitch.toDouble();
    final r = d.insert(_stepChordAt, pitch.toDouble(), len, vel: vel);
    if (r.id != null) {
      final chord = {for (final n in r.doc.notes) if (n.at == _stepChordAt && _sel.contains(n.id)) n.id};
      _apply(r.doc, select: {...chord, r.id!});
    }
    Haptics.tick();
  }

  /// Moves the step cursor on by [by], scrolling so it stays in view.
  void _stepAdvance(Steps by) {
    setState(() {
      _cursorAt = _cursorAt + by;
      final x = _cursorAt.toDouble() * _pxPerStep - _scrollX;
      if (_gridW > 0 && (x > _gridW - 48 || x < 0)) _scrollX = math.max(0.0, _cursorAt.toDouble() * _pxPerStep - _gridW / 3);
    });
  }

  void _stepKeysOff() {
    for (final k in _stepKeys.values) {
      if (k.preview != null) s.previewOff(k.preview!);
    }
    _stepKeys.clear();
  }

  /// A finger or click on the roll's keys during step input: the note sounds while held and goes in.
  void _stepKeyDown(PointerDownEvent e, double y) {
    final pitch = _pitchAt(y).clamp(0, 127).round();
    final layer = _hearLayer;
    int? pid;
    if (layer != null) {
      pid = s.nextPreviewId();
      s.previewOn(layer, pid, pitch.toDouble(), _lastVel);
    }
    _stepKeys[e.pointer] = (pitch: pitch, preview: pid);
    _stepNoteOn(pitch, _lastVel);
  }

  void _stepKeyUp(int pointer) {
    final k = _stepKeys.remove(pointer);
    if (k == null) return;
    if (k.preview != null) s.previewOff(k.preview!);
    if (!_stepKeys.values.any((o) => o.pitch == k.pitch)) _stepHeld.remove(k.pitch);
  }

  /// The step input bar under the toolbar: where the next note goes, Rest and Done.
  Widget _stepBar() {
    final bar = s.project.beatsPerBar * 4;
    final at = _cursorAt.toDouble();
    final pos = '${at ~/ bar + 1}.${(at % bar) ~/ 4 + 1}.${formatNumber(((at % 4) * 1000).roundToDouble() / 1000 + 1)}';
    return Container(
      key: const ValueKey('roll-step-bar'),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: Neon.pink.withValues(alpha: 0.12),
      child: Row(children: [
        const Icon(Icons.piano, size: 16, color: Neon.pink),
        const SizedBox(width: 6),
        Expanded(
          child: Text('STEP INPUT · next at $pos · ${noteLengthLabel(_resSteps)}',
              overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.pink, fontSize: 11, letterSpacing: 0.8)),
        ),
        Pressable(child: TextButton(onPressed: () => _runRef(const ActionRef.action('roll.step.rest')), child: const Text('Rest'))),
        Pressable(child: TextButton(onPressed: () => _runRef(const ActionRef.action('roll.step.toggle')), child: const Text('Done'))),
      ]),
    );
  }

  // ---------- hearing notes (owner, 2026-11-05) ----------
  // A note sounds while you place, move, hold or bend it; a tapped-in note plays its own length. A selection sounds
  // its opening chord (the notes that start first). Each sounding note: its preview id and the pitch it plays.
  final Map<int, ({int id, double pitch})> _heard = {};
  Timer? _tapOff;
  int? _drawnNote; // the note this gesture drew: a tap plays it for its length
  final _drawnAt = Stopwatch()..start(); // since that note was drawn: only a quick tap plays out its length

  String? get _hearLayer => _look.hearNotes ? s.previewLayerFor(widget.module.id) : null;

  /// Starts [ids]' previews (ending any before): of several notes, those that start first.
  void _hear(Iterable<int> ids) {
    _hearStop();
    final d = _doc, layer = _hearLayer;
    if (d == null || layer == null) return;
    final notes = [for (final id in ids) ?d.byId(id)];
    if (notes.isEmpty) return;
    final first = notes.map((n) => n.at).reduce(Steps.min);
    for (final n in notes) {
      if (n.at != first) continue;
      final pid = s.nextPreviewId();
      s.previewOn(layer, pid, n.pitch, n.vel);
      _heard[n.id] = (id: pid, pitch: n.pitch);
    }
  }

  /// After a move: a note whose pitch changed ends and starts again at its new pitch; a move in time doesn't.
  void _hearFollow() {
    final d = _doc, layer = _hearLayer;
    if (d == null || layer == null) return;
    for (final entry in _heard.entries.toList()) {
      final n = d.byId(entry.key);
      if (n == null || n.pitch == entry.value.pitch) continue;
      s.previewOn(layer, entry.value.id, n.pitch, n.vel);
      _heard[entry.key] = (id: entry.value.id, pitch: n.pitch);
    }
  }

  /// While a pitch point is dragged the note sounds at that point's pitch; on a segment, at the curve under the finger.
  void _hearBendAt(Offset p) {
    final id = _bNote, d = _dragBase ?? _doc, layer = _hearLayer;
    if (id == null || d == null || layer == null) return;
    final n = d.byId(id);
    if (n == null) return;
    final pts = _curveView.value.points ?? n.expr.bend, i = _bPoint;
    final pitch = (n.pitch +
            (i != null && i < pts.length
                ? pts[i].v
                : NoteExpression.valueAt(pts, ((p.dx - _noteX(n)) / _noteW(n)).clamp(0.0, 1.0))))
        .clamp(0.0, 127.0)
        .toDouble();
    final h = _heard[id];
    if (h == null) {
      _hearStop();
      final pid = s.nextPreviewId();
      s.previewOn(layer, pid, pitch, n.vel);
      _heard[id] = (id: pid, pitch: pitch);
    } else if (h.pitch != pitch) {
      s.previewPitch(h.id, pitch);
      _heard[id] = (id: h.id, pitch: pitch);
    }
  }

  void _hearStop() {
    _tapOff?.cancel();
    _tapOff = null;
    for (final h in _heard.values) {
      s.previewOff(h.id);
    }
    _heard.clear();
  }

  // ---------- pointer ----------

  /// A mouse moves this far (px) on empty grid before its drag starts.
  static const double _mouseDragSlop = 4;

  /// The mouse pointer panning the roll (middle-drag or Space+drag), if any; whether the press is a mouse's.
  int? _mousePan;
  bool _mouse = false;

  /// The mouse cursor for what the mouse is over: resize on a note's ends, move on its body, else the tool's own.
  MouseCursor _hoverCursor = MouseCursor.defer;

  void _cursorHover(PointerHoverEvent e) {
    final c = _cursorFor(e.localPosition - _origin);
    if (c != _hoverCursor) setState(() => _hoverCursor = c);
  }

  MouseCursor _cursorFor(Offset p) {
    final d = _doc;
    if (d == null || p.dx < 0 || p.dy < 0) return MouseCursor.defer;
    _touch = false;
    if (p.dy >= _gridH) return SystemMouseCursors.resizeUpDown; // a lane: drag a value up or down
    if (_tool == PatternTool.curve) return SystemMouseCursors.precise;
    final hit = _noteAt(p);
    if (hit != null) {
      if (_tool == PatternTool.erase) return SystemMouseCursors.disappearing;
      if (_tool == PatternTool.ratchet) return SystemMouseCursors.resizeUpDown;
      final part = _partAt(d.byId(hit)!, p.dx) ?? 0;
      return part == 0 ? SystemMouseCursors.move : SystemMouseCursors.resizeLeftRight;
    }
    if (_edgeAt(p) != null) return SystemMouseCursors.resizeLeftRight;
    return switch (_tool) {
      PatternTool.draw => SystemMouseCursors.precise,
      PatternTool.erase => SystemMouseCursors.disappearing,
      PatternTool.ratchet => SystemMouseCursors.resizeUpDown,
      _ => SystemMouseCursors.basic,
    };
  }

  /// A right-click on the roll: on a note, the note menu (the note joins the selection first); on empty grid, the
  /// grid menu. The cursor moves to the click, so Insert and Split work there. Built from the roll's own actions.
  Future<void> _contextMenu(Offset p, Offset global) async {
    final d = _doc;
    if (d == null || p.dx < 0 || p.dy < 0 || p.dy >= _gridH) return;
    final hit = _noteAt(p);
    setState(() {
      _cursorPitch = _pitchAt(p.dy).clamp(0, 127);
      _cursorAt = _snapTime(_stepAt(p.dx), _tapLevel);
      if (hit != null && !_sel.contains(hit)) _sel = {hit};
    });
    PopupMenuItem<String> item(String id, String label, {bool enabled = true}) {
      final keys = _router?.vim.keymap.keysFor(Area.pattern, ActionRef.action(id)) ?? const [];
      return PopupMenuItem<String>(
        value: id,
        enabled: enabled,
        height: 36,
        child: Row(children: [
          Expanded(child: Text(label)),
          if (keys.isNotEmpty)
            Padding(padding: const EdgeInsets.only(left: 16),
                child: Text(keys.first.toString(), style: const TextStyle(color: Neon.dim, fontSize: 11))),
        ]),
      );
    }

    final box = Overlay.of(context).context.findRenderObject() as RenderBox;
    final at = box.globalToLocal(global);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & box.size),
      items: hit != null
          ? [
              _menuHead('Note${_sel.length > 1 ? 's (${_sel.length})' : ''}'),
              item('roll.notes.delete', 'Delete'),
              item('roll.edit.duplicate', 'Duplicate'),
              item('roll.edit.copy', 'Copy'),
              item('roll.edit.cut', 'Cut'),
              item('roll.notes.quantize', 'Quantize'),
              item('roll.notes.split', 'Split at the click'),
              if (_sel.length > 1) item('roll.notes.join', 'Join'),
              _menuHead('Velocity'),
              item('vel:1.0', 'Velocity 100%'),
              item('vel:0.8', 'Velocity 80%'),
              item('vel:0.5', 'Velocity 50%'),
              item('roll.notes.extras', 'Note extras…'),
            ]
          : [
              _menuHead('Grid'),
              item('roll.edit.paste', 'Paste', enabled: _clip != null && !_clip!.isEmpty),
              item('roll.notes.insert', 'Insert a note here'),
              item('roll.select.all', 'Select all', enabled: d.notes.isNotEmpty),
              if (_sel.isNotEmpty) item('roll.select.none', 'Select none'),
              item('roll.notes.quantizeSheet', 'Quantize…'),
            ],
    );
    if (v == null || !mounted) return;
    if (v.startsWith('vel:')) {
      _action('roll.vel.set', 1, v.substring(4));
    } else if (v == 'roll.edit.paste') {
      // Paste at the click, not after the copied notes.
      _pasteAt = _cursorAt;
      _action(v, 1, null);
    } else {
      _action(v, 1, null);
    }
  }

  static const _origin = Offset(_keyW, _rulerH);

  /// One finger on a note, in a lane or with the select tool edits; on empty grid it waits: a tap draws (or erases),
  /// a drag scrolls. Two fingers zoom and scroll, and drop an edit the first finger had started.
  void _pointerDown(PointerDownEvent e) {
    _focus.requestFocus();
    _glide.stop();
    _follow.hold();
    final local = e.localPosition - _origin;
    if (isMousePointer(e.kind) && _pointers.isEmpty) {
      // A right-click opens the menu (it never draws); the middle button or Space+drag pans.
      if (e.buttons & kSecondaryMouseButton != 0) {
        _loopHit(local, e.kind) ? _loopMenu(e.position) : _contextMenu(local, e.position);
        return;
      }
      if (startsMousePan(e)) {
        if (e.buttons == kPrimaryMouseButton) SpacePan.claim();
        setState(() => _mousePan = e.pointer);
        return;
      }
    }
    if (_step && !_grid && local.dx < 0 && local.dy >= 0 && local.dy < _gridH) {
      _stepKeyDown(e, local.dy); // the keys play step input, and stay out of the roll's gestures
      return;
    }
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      final p = e.localPosition - _origin;
      _editPointer = e.pointer;
      _touch = e.kind == PointerDeviceKind.touch;
      _mouse = isMousePointer(e.kind);
      _lastP = p;
      if (_loopHit(p, e.kind)) {
        _loopDown(p);
      } else if (p.dy < 0 && p.dx >= 0) {
        _rulerDown(p);
      } else if (_tool == PatternTool.curve) {
        // Curve tool: the lanes edit their curve; on the grid any note's curve edits where it is touched, and on
        // empty grid a tap clears the selection and a drag scrolls.
        final hit = p.dy < _gridH ? _curveHitAt(p, _curveReach(e.kind)) : null;
        if (p.dy >= _gridH) {
          _curveDown(p);
        } else if (hit != null) {
          _bendDown(p, hit);
        } else {
          _pending = p;
          _panning = false;
          _armBox();
        }
      } else if (_tool == PatternTool.ratchet) {
        _brushDown(p);
      } else if (p.dy >= _gridH || _noteAt(p) != null || _tool == PatternTool.select) {
        _down(p);
      } else {
        _pending = p;
        _panning = false;
        if (_tool == PatternTool.draw) _showGhost(p);
        _armBox();
      }
    } else if (_pointers.length == 2 && _editing) {
      // A second finger during a drag (a note, a lane, a curve or a pitch point) frees it from the grid while it
      // rests.
      _hold?.cancel();
      _hold = null;
      _boxTimer?.cancel();
      _tapCandidate = null; // two fingers aren't a tap: lifting them doesn't arm the double tap
      _bypass = true;
      _restAt = e.localPosition;
      _editAtBypass = _pointers[_editPointer] ?? e.localPosition;
      _editMove(_lastP!);
    } else if (_pointers.length == 2) {
      _boxTimer?.cancel();
      _cancelEdit();
      _curveEnd(cancel: true);
      _bendEnd(cancel: true);
      _brushEnd(cancel: true);
      _pending = null;
      _clearGhost();
      _startPinch();
    }
  }

  // ---------- the ratchet brush (owner, 2026-11-11) ----------
  // A drag over notes sets their ratchet count: each note the finger passes (on its row, or on the row the drag began
  // in) joins, and the count follows the finger up (more) or down (fewer), one step every [_brushStep] px from the
  // count the first note had. A note that is selected brings the whole selection. One undo step a drag.

  static const _brushStep = 24.0;
  Offset? _brushAt; // where the drag began; null when no brush drag is under way
  Offset _brushNow = Offset.zero;
  PatternDoc? _brushBase;
  Set<int> _brushIds = {};
  int _brush0 = 1, _brushCount = 1;

  void _brushDown(Offset p) {
    final d = _doc;
    if (d == null || p.dy >= _gridH) return;
    _brushAt = _brushNow = p;
    _brushBase = d;
    _brushIds = {};
    final hit = _noteAt(p);
    _brush0 = hit == null ? 1 : d.byId(hit)!.ratchet;
    _brushCount = _brush0;
    if (hit != null && _sel.contains(hit)) _brushIds = {..._sel};
    _brushPick(p);
    setState(() {});
  }

  void _brushPick(Offset p) {
    final start = _brushAt!;
    for (final at in [p, Offset(p.dx, start.dy)]) {
      final id = _noteAt(at);
      if (id != null) _brushIds.add(id);
    }
  }

  void _brushMove(Offset p) {
    final start = _brushAt, base = _brushBase;
    if (start == null || base == null) return;
    _brushNow = p;
    _brushPick(p);
    final count = (_brush0 - ((p.dy - start.dy) / _brushStep).round()).clamp(1, kPatternMaxRatchet).toInt();
    if (count != _brushCount) Haptics.tick();
    _brushCount = count;
    setState(() => _doc = base.setRatchet(_brushIds, count));
  }

  void _brushEnd({required bool cancel}) {
    final base = _brushBase;
    if (_brushAt == null) return;
    _brushAt = null;
    _brushBase = null;
    if (base == null) return;
    if (cancel) {
      setState(() => _doc = base);
      return;
    }
    final d = _doc;
    if (d != null && !identical(d, base) && d.serialize() != base.serialize()) {
      _pushUndo(_Undo(base));
      _scheduleSend();
    } else {
      _doc = base;
    }
    setState(() {});
  }

  void _startPinch() {
    final ps = _pointers.values.take(2).toList();
    _pinchSpan = (ps[0].dx - ps[1].dx).abs();
    _pinchSpanY = (ps[0].dy - ps[1].dy).abs();
    _pinchFocal = (ps[0] + ps[1]) / 2;
    _zoomStart = _pxPerStep;
    _rowStart = _rowH;
    // Fingers side by side zoom time, one above the other the rows; diagonal, both.
    _pinchX = _pinchSpan > 24 && _pinchSpan >= _pinchSpanY * 0.6;
    _pinchY = _pinchSpanY > 24 && _pinchSpanY >= _pinchSpan * 0.6;
  }

  void _pointerMove(PointerMoveEvent e) {
    if (e.pointer == _mousePan) {
      return setState(() {
        _scrollX -= e.delta.dx;
        _scrollY -= e.delta.dy;
      });
    }
    if (!_pointers.containsKey(e.pointer)) return; // step-input keys included: they aren't in it
    _pointers[e.pointer] = e.localPosition;
    if (_bypass) {
      // Only the finger that started the drag moves it; the resting one just holds the bypass. A second finger that
      // moves first (the dragging one still) is a pinch after all: the edit is dropped and the view zooms.
      if (e.pointer == _editPointer) {
        _editMove(e.localPosition - _origin);
      } else if ((e.localPosition - _restAt).distance > kTouchSlop &&
          (_pointers[_editPointer]! - _editAtBypass).distance <= kTouchSlop) {
        _bypass = false;
        _editEnd(cancel: true);
        _startPinch();
      }
      return;
    }
    if (_pointers.length >= 2) {
      final ps = _pointers.values.take(2).toList();
      final focal = (ps[0] + ps[1]) / 2, span = (ps[0].dx - ps[1].dx).abs(), spanY = (ps[0].dy - ps[1].dy).abs();
      final f = focal - _origin;
      setState(() {
        // Per axis: a sideways pinch zooms time, an upright one the rows, around the fingers.
        if (_pinchX) _zoomX(_zoomStart * span / _pinchSpan, fx: f.dx);
        if (_pinchY) _zoomY(_rowStart * spanY / _pinchSpanY, fy: f.dy);
        _scrollX = math.max(0.0, _scrollX - (focal.dx - _pinchFocal.dx));
        _scrollY = math.max(0.0, _scrollY - (focal.dy - _pinchFocal.dy));
      });
      _pinchFocal = focal;
      return;
    }
    final p = e.localPosition - _origin, pending = _pending;
    if (pending != null) {
      // A mouse's drag starts after a few pixels (a finger's after the touch slop).
      if (!_panning && (p - pending).distance > (_mouse ? _mouseDragSlop : kTouchSlop)) {
        _boxTimer?.cancel();
        _clearGhost();
        // A drag from just outside a selected note's end stretches it (a tap there still draws).
        if (_tool != PatternTool.curve && _edgeAt(pending) != null) {
          _pending = null;
          _down(pending, outside: true);
          _dragTo(p);
          return;
        }
        // A drag from empty grid does what the settings say: scroll, select, or the tool's own drag. A mouse's left
        // drag always draws a selection box (owner, 2026-11-11); it pans with the middle button or Space.
        final empty = _mouse ? EmptyDrag.select : _look.emptyDrag;
        if (empty != EmptyDrag.scroll && _tool != PatternTool.curve) {
          _pending = null;
          _down(pending, rect: empty == EmptyDrag.select);
          _dragTo(p);
          return;
        }
        _panning = true;
      }
      if (_panning) {
        setState(() {
          _scrollX -= e.delta.dx;
          _scrollY -= e.delta.dy;
        });
      }
      return;
    }
    _editMove(p);
  }

  /// Whether a one-finger drag is under way: a note, a lane, a curve point or segment, or a pitch point.
  bool get _editing =>
      (_dragStart != null && (_dragNote != null || _lane != 0)) || _cLane != 0 || _bNote != null || _brushAt != null ||
      _loopLive != null || _rulerAt != null;

  void _editMove(Offset p) {
    _lastP = p;
    if (_loopLive != null) return _loopMove(p);
    if (_rulerAt != null) return _rulerMove(p);
    if (_brushAt != null) return _brushMove(p);
    if (_bNote != null) {
      _bendMove(p);
      return _hearBendAt(p);
    }
    if (_cLane != 0) return _curveMove(p);
    _dragTo(p);
  }

  void _editEnd({required bool cancel}) {
    if (_loopLive != null) return _loopEnd(cancel: cancel);
    if (_rulerAt != null) return _rulerEnd(cancel: cancel);
    if (_brushAt != null) return _brushEnd(cancel: cancel);
    if (_bNote != null) return _bendEnd(cancel: cancel);
    if (_cLane != 0) return _curveEnd(cancel: cancel);
    cancel ? _cancelEdit() : _up();
  }

  /// A one-finger drag moved to [p]: the edit follows, and near the grid's edge the view starts scrolling.
  void _dragTo(Offset p) {
    _lastP = p;
    _move(p);
    if (_dragStart != null && _lane == 0 && _edgeSpeed(p) != Offset.zero && !_scroller.isActive) {
      _scrolledAt = Duration.zero;
      _scroller.start();
    }
  }

  /// How fast the view scrolls (px a second) with the finger at [p]: faster the closer it is to an edge.
  Offset _edgeSpeed(Offset p) {
    const zone = 28.0, top = 600.0;
    double axis(double v, double size) {
      if (size <= 2 * zone) return 0;
      if (v < zone) return -top * (1 - math.max(0.0, v) / zone);
      if (v > size - zone) return top * (1 - math.max(0.0, size - v) / zone);
      return 0;
    }

    return Offset(axis(p.dx, _gridW), axis(p.dy, _gridH));
  }

  void _scrollTick(Duration now) {
    final p = _lastP;
    final v = p == null || _dragStart == null ? Offset.zero : _edgeSpeed(p);
    if (v == Offset.zero) {
      _scroller.stop();
      return;
    }
    final dt = (now - _scrolledAt).inMicroseconds / 1e6;
    _scrolledAt = now;
    if (dt <= 0 || dt > 0.1) return; // the first frame, or a stall: no jump
    final nx = (_scrollX + v.dx * dt).clamp(0.0, _maxScrollX), ny = (_scrollY + v.dy * dt).clamp(0.0, _maxScrollY);
    final moved = Offset(nx - _scrollX, ny - _scrollY);
    if (moved == Offset.zero) {
      _scroller.stop(); // at the end of the view: the next move near the edge starts it again
      return;
    }
    // The content moves under the finger, so a held finger isn't a long press.
    _hold?.cancel();
    _hold = null;
    // The drag's start is in screen space: it moves with the content, so the edit grows by what scrolled.
    _dragStart = _dragStart! - moved;
    setState(() {
      _scrollX = nx;
      _scrollY = ny;
    });
    _move(p!);
  }

  void _pointerUp(PointerEvent e, {required bool cancel}) {
    _follow.release();
    if (e.pointer == _mousePan) setState(() => _mousePan = null);
    _stepKeyUp(e.pointer);
    if (_pointers.remove(e.pointer) == null) return;
    if (_bypass) {
      if (e.pointer != _editPointer) {
        // The resting finger lifted: back on the grid where the dragging finger is.
        if (_pointers.length == 1) {
          _bypass = false;
          _editMove(_lastP!);
        }
        return;
      }
      // The dragging finger lifted first: the edit ends; one finger left scrolls until it lifts, two pinch.
      _bypass = false;
      _editEnd(cancel: cancel);
      if (_pointers.length >= 2) {
        _startPinch();
      } else if (_pointers.isNotEmpty) {
        _pending = _pointers.values.first - _origin;
        _panning = true;
      }
      return;
    }
    if (_pointers.length == 1) {
      _saveRow();
      // Back to one finger after a pinch: it keeps scrolling until it lifts.
      _pending = _pointers.values.first - _origin;
      _panning = true;
      return;
    }
    if (_pointers.isNotEmpty) return;
    _boxTimer?.cancel();
    _clearGhost();
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      if (!_panning && !cancel) {
        if (_tool == PatternTool.curve) {
          _pickForCurve(pending);
        } else {
          _down(pending);
          _up();
        }
      }
      return;
    }
    _editEnd(cancel: cancel);
  }

  void _showGhost(Offset p) {
    final len = _lastLen ?? _tapLevel;
    setState(() => _ghost = (at: _snapTime(_stepAt(p.dx), _tapLevel), pitch: _pitchAt(p.dy).clamp(0, 127), len: len));
  }

  void _clearGhost() {
    if (_ghost != null) setState(() => _ghost = null);
  }

  /// Drops a one-finger edit in progress, restoring the notes as they were before it.
  void _cancelEdit() {
    _hold?.cancel();
    _hold = null;
    _boxTimer?.cancel();
    if (_liveEnd()) s.livePattern(widget.module.id, null);
    _hearStop();
    _scroller.stop();
    _bypass = false;
    final base = _dragBase;
    if (base == null) return;
    setState(() {
      _doc = base;
      _dragStart = null;
      _dragBase = null;
      _dragNote = null;
      _rectEnd = null;
      _edge = 0;
      _lag = 0;
      _lagIds = const {};
    });
  }

  double _stepAt(double x) => (x + _scrollX) / _pxPerStep;
  double _pitchAt(double y) => 127 - ((y + _scrollY) / _rowH).floorToDouble();

  /// Whether [p] is on [n]'s row or, for a bent note, on its ribbon where it is drawn above [p] (clamped to the note's
  /// ends, so a touch just past an end tests the ribbon's end). Time is the caller's test.
  bool _onNote(PatternNote n, Offset p) {
    final e = n.expr;
    if (!_isBent(e)) return n.pitch.round() == _pitchAt(p.dy);
    final nw = _noteW(n), lenSec = n.len.toDouble() * _secPerStep;
    final at = _ribbonAt(e, p.dx - _noteX(n), nw, _rowH, lenSec, _vibWave(e, nw, lenSec));
    return (p.dy - (_noteMid(n) - at.dy)).abs() <= at.half + 1;
  }

  double get _secPerStep => 15 / widget.state.project.bpm;

  int? _noteAt(Offset p) {
    final d = _doc;
    if (d == null) return null;
    final t = _stepAt(p.dx);
    for (final n in d.notes.reversed) {
      if (t >= n.at.toDouble() && t < n.end.toDouble() && _onNote(n, p)) return n.id;
    }
    // A short note is easier to grab: a touch beside it, within the grab zone, counts as on it, but only inside the
    // tap cell the note starts in, so a tap in the next cell still draws there.
    final cell = _tapLevel.toDouble(), touchCell = (t / cell).floor();
    for (final n in d.notes.reversed) {
      if ((n.at.toDouble() / cell).floor() != touchCell || !_onNote(n, p)) continue;
      final w = n.len.toDouble() * _pxPerStep, pad = math.max(0.0, _look.grab * 2 - w) / 2 / _pxPerStep;
      if (t >= n.at.toDouble() - pad && t < n.end.toDouble() + pad) return n.id;
    }
    return null;
  }

  /// How far a note end's touch zone reaches each side of the edge: 24 dp for a finger (a 48 dp zone), the grab
  /// setting for a mouse.
  double get _reach => _touch ? math.max(24.0, _look.grab) : _look.grab;

  /// The part of [n] that [x] (px on the grid) grabs: its start (-1), its end (1) or its body (0), or null outside
  /// every zone. The body keeps a middle at least a reach wide, so a narrow note's end zones reach outside it.
  int? _partAt(PatternNote n, double x) {
    final l = _noteX(n), w = n.len.toDouble() * _pxPerStep, reach = _reach;
    final half = math.max(w / 2 - math.min(reach, w / 4), reach / 2), d = x - (l + w / 2);
    if (d.abs() <= half) return 0;
    if (d.abs() <= half + 2 * reach) return d.sign.toInt();
    return null;
  }

  /// An end zone of a selected note that reaches outside it, under [p]; null for the Erase tool.
  ({int id, int edge})? _edgeAt(Offset p) {
    final d = _doc;
    if (d == null || _tool == PatternTool.erase) return null;
    for (final n in d.notes.reversed) {
      if (!_sel.contains(n.id) || !_onNote(n, p)) continue;
      final part = _partAt(n, p.dx);
      if (part != null && part != 0) return (id: n.id, edge: part);
    }
    return null;
  }

  /// Starts a one-finger edit at [p]. [outside]: the drag began just outside a selected note's end and stretches it.
  void _down(Offset p, {bool rect = false, bool outside = false, bool add = false}) {
    _focus.requestFocus();
    final d = _doc;
    if (d == null) return;
    _dragStart = p;
    _dragBase = d;
    _dragMovedT = Steps.zero;
    _dragMovedP = 0;
    _lane = 0;
    _edge = 0;
    _spring.stop();
    _lag = 0;
    _lagIds = const {};
    _rectSelect = rect || _tool == PatternTool.select;
    if (p.dy >= _gridH) {
      _lane = _velLane && p.dy < _gridH + _velH ? 1 : 2;
      _laneEdit(p);
      return;
    }
    var hit = _noteAt(p);
    var edge = hit == null ? 0 : (_partAt(d.byId(hit)!, p.dx) ?? 0);
    if (hit == null && outside && !_rectSelect) {
      final e = _edgeAt(p);
      if (e != null) (hit, edge) = (e.id, e.edge);
    }
    _cursorPitch = _pitchAt(p.dy).clamp(0, 127);
    _cursorAt = _snapTime(_stepAt(p.dx), _tapLevel);
    _tapCandidate = null;
    final tapAt = _tapAt;
    if (hit != null && !outside && hit == _tapNote && tapAt != null &&
        DateTime.now().difference(tapAt) < const Duration(milliseconds: 350)) {
      _tapNote = null;
      _dragStart = null;
      _dragBase = null;
      _dragNote = null;
      _apply(d.delete({hit}));
      return;
    }
    if (_tool == PatternTool.erase && !_rectSelect) {
      if (hit != null) _apply(d.delete({hit}));
      _dragNote = null;
      return;
    }
    if (hit != null) {
      _dragNote = hit;
      _tapCandidate = hit;
      // Keep an existing multi-selection intact when dragging any member: the whole selection moves, or stretches
      // by the same amount from an end zone.
      final id = hit;
      if (!_sel.contains(id)) setState(() => _sel = {id});
      _edge = edge;
      _drawnNote = null;
      _hear(_sel);
      _holdAt = p;
      _hold = Timer(Duration(milliseconds: _look.holdMs), () {
        // Opening the extras sheet takes the touch from the roll (its route cancels it), so the note's preview ends.
        _up();
        _openExtras();
      });
      return;
    }
    _dragNote = null;
    if (_tool == PatternTool.draw && !_rectSelect) {
      final r = d.insert(_cursorAt, _cursorPitch, _lastLen ?? _tapLevel, vel: _lastVel);
      if (r.id != null) {
        _apply(r.doc, select: {r.id!});
        _dragNote = r.id;
        _edge = 1;
        _dragBase = r.doc;
        Motion.tick();
        _drawnNote = r.id;
        _drawnAt.reset();
        _hear({r.id!});
      }
    } else {
      // A rectangle from empty grid. It replaces the selection once it is drawn past the slop, or adds to it as a
      // selection box ([add], or held still for [_boxHold] first).
      _rectBase = _sel;
      _rectMoved = false;
      _boxAdd = add;
      _boxTimer?.cancel();
      if (!add) {
        _boxTimer = Timer(_boxHold, () {
          if (_rectMoved || _dragStart == null || _rectEnd == null) return;
          Haptics.tick();
          setState(() => _boxAdd = true);
        });
      }
      setState(() => _rectEnd = p);
    }
  }

  /// A finger down on empty grid: held still for [_boxHold], it starts a selection box that adds to the selection.
  void _armBox() {
    _boxTimer?.cancel();
    _boxTimer = Timer(_boxHold, () {
      final p = _pending;
      if (p == null || _panning || _pointers.length != 1 || !mounted) return;
      _pending = null;
      _clearGhost();
      Haptics.tick();
      _down(p, rect: true, add: true);
    });
  }

  /// A tap on empty grid: a second one soon after, near it, clears the selection (a single tap leaves it).
  void _emptyTapped(Offset p) {
    final last = _emptyTap, now = DateTime.now();
    if (last != null && now.difference(last.when) < kDoubleTapTimeout && (p - last.at).distance < 48) {
      _emptyTap = null;
      if (_sel.isNotEmpty) setState(() => _sel = {});
      return;
    }
    _emptyTap = (at: p, when: now);
  }

  void _move(Offset p) {
    final start = _dragStart, base = _dragBase;
    if (start == null || base == null) return;
    if (_hold != null && (p - _holdAt!).distance > 8) {
      _hold!.cancel();
      _hold = null;
    }
    if (_lane != 0) {
      _laneEdit(p);
      return;
    }
    if (_tool == PatternTool.erase && !_rectSelect) {
      final hit = _noteAt(p);
      if (hit != null && _doc != null) _apply(_doc!.delete({hit}));
      return;
    }
    if (_dragNote == null) {
      if (_rectSelect) {
        if (!_rectMoved && (p - start).distance <= kTouchSlop) return;
        _rectMoved = true;
        setState(() {
          _rectEnd = p;
          final a = _stepAt(math.min(start.dx, p.dx)), b = _stepAt(math.max(start.dx, p.dx));
          final inBox = base.notesIn(Steps.fromDouble(a, maxDenominator: 384), Steps.fromDouble(b, maxDenominator: 384),
              math.min(_pitchAt(start.dy), _pitchAt(p.dy)), math.max(_pitchAt(start.dy), _pitchAt(p.dy)));
          _sel = _boxAdd ? {..._rectBase, ...inBox} : inBox;
        });
      }
      return;
    }
    final free = _free;
    final dSteps = (p.dx - start.dx) / _pxPerStep;
    _motion = null; // a drag shows the notes where they are
    if (_edge != 0) {
      final b = base.byId(_dragNote!);
      if (b == null) return;
      // The dragged note's end lands on a grid line (or anywhere when free); the rest of the selection stretches
      // by the same amount.
      final from = _edge > 0 ? b.end : b.at, to = from.toDouble() + dSteps;
      final dt = (free ? Steps.fromDouble(to, maxDenominator: 384) : _resSteps.times((to / _resSteps.toDouble()).round())) - from;
      final ids = _sel.isEmpty ? {_dragNote!} : _sel;
      final next = base.stretch(ids, dt, start: _edge < 0, min: free ? null : _resSteps);
      final n = next.byId(_dragNote!)!;
      final moved = ((_edge > 0 ? n.end : n.at) - from).toDouble() * _pxPerStep;
      if (!free && n.len != _doc?.byId(_dragNote!)?.len) Motion.tick();
      _lastLen = n.len;
      setState(() {
        _doc = next;
        _lagIds = ids;
        _lagEdge = _edge;
        _lag = p.dx - start.dx - moved;
      });
      _live(next);
    } else {
      final dt = free ? Steps.fromDouble(dSteps, maxDenominator: 384) : _resSteps.times((dSteps / _resSteps.toDouble()).round());
      final dp = -((p.dy - start.dy) / _rowH).roundToDouble();
      if (dt == _dragMovedT && dp == _dragMovedP) return;
      _dragMovedT = dt;
      _dragMovedP = dp;
      setState(() => _doc = base.move(_sel, dt, dp));
      _live(_doc!);
      _hearFollow();
    }
  }

  void _up() {
    _hold?.cancel();
    _hold = null;
    _boxTimer?.cancel();
    if (_rectEnd != null && _dragStart != null && _dragNote == null && _lane == 0) {
      if (_boxAdd && _doc != null && !setEquals(_sel, _rectBase)) {
        _pushUndo(_Undo(_doc!, sel: _rectBase)); // undo takes back what the box added
      } else if (!_rectMoved && !_boxAdd) {
        _emptyTapped(_dragStart!);
      }
    }
    _boxAdd = _rectMoved = false;
    final live = _liveEnd();
    _scroller.stop();
    _edge = 0;
    // A note tapped in (drawn quickly, not stretched) plays out its own length, at most 4 s; anything held stops now.
    final quick = _drawnAt.elapsedMilliseconds < _look.holdMs;
    final tapped = _drawnNote == null || !quick || !identical(_dragBase, _doc) ? null : _doc?.byId(_drawnNote!);
    _drawnNote = null;
    if (tapped != null && _heard.isNotEmpty) {
      final secs = math.min(4.0, tapped.len.toDouble() * 15 / s.project.bpm);
      _tapOff?.cancel();
      _tapOff = Timer(Duration(microseconds: (secs * 1e6).round()), _hearStop);
    } else {
      _hearStop();
    }
    if (_lag != 0) {
      // The stretched edge springs onto its snapped place.
      final d = Motion.move(const Duration(milliseconds: 150), Motion.of(context));
      if (d == Duration.zero) {
        _lag = 0;
        _lagIds = const {};
      } else {
        _lagFrom = _lag;
        _spring.duration = d;
        _spring.forward(from: 0);
      }
    }
    // A tap on an existing note that moved nothing arms the double tap; a note just drawn doesn't.
    _tapNote = _tapCandidate != null && identical(_dragBase, _doc) ? _tapCandidate : null;
    _tapAt = DateTime.now();
    _tapCandidate = null;
    if (_dragBase != null && _doc != null && !identical(_dragBase, _doc)) {
      // One undo step for the whole drag.
      _pushUndo(_Undo(_dragBase!));
      if (!live) _scheduleSend();
    }
    if (live) _liveDone();
    setState(() {
      _dragStart = null;
      _dragBase = null;
      _dragNote = null;
      _rectEnd = null;
    });
  }

  /// A touch in a lane sets the velocity (or chance) of the notes starting under it: the selected ones if any are.
  void _laneEdit(Offset p) {
    final d = _doc;
    if (d == null) return;
    final top = _lane == 1 ? _gridH : _gridH + (_velLane ? _velH : 0), hgt = _lane == 1 ? _velH : _xH;
    final v = _snapValue((1 - (p.dy - top - 3) / (hgt - 6)).clamp(0.0, 1.0));
    final x = p.dx + _scrollX;
    var hit = {
      for (final n in d.notes)
        if ((n.at.toDouble() * _pxPerStep - x).abs() < 8) n.id
    };
    if (hit.any(_sel.contains)) hit = hit.where(_sel.contains).toSet();
    if (hit.isEmpty) return;
    if (_lane == 1) _lastVel = v;
    setState(() => _doc = _lane == 1 ? d.setVelocity(hit, v) : d.setProb(hit, v));
  }

  double _rampDepth = 0.7; // the ratchet ramp's depth, kept while the roll is open

  /// The extras panel for the selected notes, in sections with the most used first (owner, 2026-11-11): velocity
  /// and chance; ratchet with its ramp and the brush; slide; tremolo and vibrato; then the note's own expression.
  /// One undo step for the whole visit.
  Future<void> _openExtras() async {
    final base = _doc;
    if (base == null || _sel.isEmpty) return;
    final sel = Set<int>.of(_sel);
    String? then; // an action to run once the sheet has closed (a tool or a dialog)
    await showGlassSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final n = _doc!.byId(sel.first)!;
        void change(PatternDoc Function(PatternDoc) f) {
          setState(() => _doc = f(_doc!));
          set(() {});
        }

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sel.length == 1 ? 'Note at ${n.at}, length ${n.len}' : '${sel.length} notes',
                style: const TextStyle(color: Neon.text)),
            const Heading('Note'),
            ValueSlider(
                label: 'Velocity',
                value: n.vel,
                min: 0,
                max: 1,
                reset: 1,
                scale: 100,
                unit: '%',
                onChanged: (v) => change((d) => d.setVelocity(sel, _lastVel = v))),
            // Chance steps by the value grid while snapping is on, like the chance lane.
            ValueSlider(
                label: 'Chance',
                value: n.prob,
                min: 0,
                max: 1,
                reset: 1,
                scale: 100,
                unit: '%',
                divisions: _snap ? (1 / _look.valueGrid.step).round() : null,
                onChanged: (v) => change((d) => d.setProb(sel, v))),
            const Heading('Ratchet'),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (var r = 1; r <= 8; r++)
                ChoiceChip(
                  label: Text('$r'),
                  selected: n.ratchet == r,
                  onSelected: (_) => change((d) => d.setRatchet(sel, r)),
                ),
            ]),
            if (sel.any((id) => (_doc!.byId(id)?.ratchet ?? 1) > 1)) ...[
              // The engine plays a ratchet's repeats at one velocity: a ramp writes them out as notes.
              Text('Ramp the repeats (writes them out as notes)', style: TextStyle(color: Neon.dim, fontSize: 12)),
              ValueSlider(
                  label: 'Ramp depth',
                  value: _rampDepth,
                  min: 0,
                  max: 1,
                  reset: 0.7,
                  scale: 100,
                  unit: '%',
                  onChanged: (v) => set(() => _rampDepth = v)),
              Wrap(spacing: 6, children: [
                for (final (ramp, name) in const [(RatchetRamp.fadeIn, 'Fade in'), (RatchetRamp.fadeOut, 'Fade out')])
                  ActionChip(
                    key: ValueKey('ratchet-ramp-${ramp.name}'),
                    label: Text(name),
                    onPressed: () => change((d) {
                      final r = d.ratchetRamp(sel, ramp: ramp, depth: _rampDepth);
                      sel
                        ..clear()
                        ..addAll(r.ids);
                      _sel = {...sel};
                      return r.doc;
                    }),
                  ),
              ]),
            ],
            TextButton.icon(
              onPressed: () {
                then = 'roll.tool.ratchet';
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.view_week_outlined, size: 18),
              label: const Text('Ratchet brush (drag over notes)'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Slide'),
              value: n.slide,
              onChanged: (v) => change((d) => d.setSlide(sel, v)),
            ),
            const Heading('Wobble'),
            Wrap(spacing: 6, children: [
              for (final (id, name) in const [('roll.gen.tremolo', 'Tremolo…'), ('roll.gen.vibrato', 'Vibrato…')])
                ActionChip(
                  label: Text(name),
                  onPressed: () {
                    then = id;
                    Navigator.pop(ctx);
                  },
                ),
            ]),
            // The note's own pitch curve, vibrato, volume and timbre (MPE style); one undo step with the rest.
            ExpressionPanel(
              expr: n.expr,
              color: _noteColor,
              // A shared expression edit has no single note duration to snap against.
              timeSnap: _snap && sel.length == 1 ? _resSteps.toDouble() / n.len.toDouble() : 0,
              valueSnap: _snap ? _look.valueGrid.step : 0,
              onChanged: (e) => change((d) => d.setExpression(sel, e)),
            ),
          ]),
          ),
        );
      }),
    );
    if (!mounted) return;
    if (!identical(base, _doc)) {
      _pushUndo(_Undo(base));
      setState(() {});
      _scheduleSend();
    }
    final next = then;
    if (next != null) _action(next, 1, null);
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Replaces the notes with a MIDI file's (one undo step); the file's tempo isn't applied.
  /// ⋮ Import MIDI file: a .mid through the app's own converter (`lib/model/midi_clips.dart`, on another isolate),
  /// replacing the notes; a file of several parts comes in as one pattern with all of them.
  Future<void> _importMidi() async {
    try {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['mid', 'midi']);
      if (f == null) return;
      if (await f.xFile.length() > kMaxMidiFileBytes) throw const MidiFileException('the file is bigger than 16 MB');
      final bytes = await f.xFile.readAsBytes();
      final beats = s.project.beatsPerBar;
      final m = await Isolate.run(() => midiImport(bytes, beatsPerBar: beats));
      if (m.clips.isEmpty) throw const FormatException('the file has no notes');
      final current = _doc;
      if (current == null) return;
      // The pattern keeps its own name and header; its notes become the file's, every part together, and its
      // length the longest part's.
      var doc = current.delete({for (final n in current.notes) n.id});
      var steps = 1;
      for (final c in m.clips) {
        final r = PatternDoc.parse(c.source);
        if (!r.ok) throw FormatException(r.error ?? 'unreadable pattern');
        doc = doc.paste(PatternClip(r.doc!.notes, Steps.zero), Steps.zero).doc;
        steps = math.max(steps, r.doc!.lengthSteps(beats));
      }
      doc = doc.setLength(steps: steps);
      _apply(doc, select: {});
      _say('Imported ${doc.notes.length} notes');
    } on FormatException catch (e) {
      _say('Not imported: ${e.message}');
    } catch (e) {
      _say('Could not import: $e');
    }
  }

  Future<void> _exportMidi({required bool clip}) async {
    _flush();
    final d = _doc;
    if (d == null) return;
    final name = '${widget.module.name}.${clip ? 'midi2' : 'mid'}';
    try {
      final Uint8List bytes;
      if (clip) {
        // MIDI 2.0 clips still come from the engine's converter.
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}${Platform.pathSeparator}caw-export-${DateTime.now().microsecondsSinceEpoch}';
        final source = d.serialize(), bpm = s.project.bpm.toDouble(), beats = s.project.beatsPerBar;
        // The engine's converter writes the file: off the UI isolate, as the exporter does.
        final err = await Isolate.run(() => Engine.exportPattern(source, path, bpm: bpm, beatsPerBar: beats, clip: true));
        if (err != null) throw Exception(err);
        final file = File(path);
        bytes = await file.readAsBytes();
        await file.delete();
      } else {
        // A Standard MIDI File from the app's own converter, as a clip's export makes (MPE when notes are bent).
        bytes = patternToMidi(d, bpm: s.project.bpm.toDouble(), beatsPerBar: s.project.beatsPerBar, name: widget.module.name);
      }
      final saved = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'audio/midi');
      _say(saved == null ? 'Not exported (picker closed).' : 'Exported $name');
    } catch (e) {
      _say('Could not export: $e');
    }
  }

  // ---------- build ----------

  ({int root, List<int> scale})? get _key {
    final k = s.project.keyNumbers;
    if (k == null) return null;
    return (root: k.$1, scale: k.$2 == 0 ? const [0, 2, 4, 5, 7, 9, 11] : const [0, 2, 3, 5, 7, 8, 10]);
  }

  Color get _noteColor {
    for (final l in s.project.layers) {
      if (l.patternId == widget.module.id || l.clips.any((clip) => clip.patternId == widget.module.id)) {
        return trackColor(s, l);
      }
    }
    return Neon.yellow;
  }

  /// The zoom bar: time on a log scale with − and +, and the row height; both follow the finger.
  Widget _zoomRow() {
    final ratio = math.log(_maxPx / _minPx);
    Widget icon(IconData i, String tip, VoidCallback onTap) => IconButton(onPressed: onTap, tooltip: tip,
        visualDensity: VisualDensity.compact, iconSize: 18, icon: Icon(i, color: Neon.dim));
    return SizedBox(height: 36, child: Row(key: const ValueKey('roll-zoom-bar'), children: [
      const SizedBox(width: 6),
      const Tooltip(message: 'Time zoom', child: Icon(Icons.swap_horiz, size: 16, color: Neon.dim)),
      icon(Icons.remove, 'Zoom out', () => _animateViewTo(px: _pxAim / 1.25)),
      Expanded(flex: 3, child: ResetOnDoubleTap(onReset: () => _animateViewTo(px: 28), child: Slider(key: const ValueKey('roll-zoom-time'),
        value: (math.log(_pxPerStep / _minPx) / ratio).clamp(0.0, 1.0).toDouble(),
        onChanged: (v) { _glide.stop(); setState(() => _zoomX(_minPx * math.exp(v * ratio))); }))),
      icon(Icons.add, 'Zoom in', () => _animateViewTo(px: _pxAim * 1.25)),
      const SizedBox(width: 6),
      const Tooltip(message: 'Row height', child: Icon(Icons.swap_vert, size: 16, color: Neon.dim)),
      Expanded(flex: 2, child: ResetOnDoubleTap(onReset: () { setState(() => _zoomY(const RollLook().rowHeight)); _saveRow(); },
        child: Slider(key: const ValueKey('roll-zoom-rows'),
        value: _rowH.clamp(_minRow, _maxRow).toDouble(), min: _minRow, max: _maxRow,
        onChanged: (v) => setState(() => _zoomY(v)),
        onChangeEnd: (_) => _saveRow()))),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    if (d == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(_error ?? 'Not a pattern', style: const TextStyle(color: Neon.pink)),
      );
    }
    _revealCursor();
    final length = d.lengthSteps(s.project.beatsPerBar);
    final selectedSourceIds = s.selectedPatternModuleIds.where((id) => id != widget.module.id).toList()..sort();
    if (_multiEditEnabled && selectedSourceIds.join('|') != _multiSourceIds.join('|')) _loadMultiDocs(s);
    final references = _multiEditEnabled ? _multiDocs.values.toList() : s.selectedPatternReferences;
    final router = _router;
    final registry = router?.registry ?? _fallbackRegistry;
    final toolbar = _Toolbar(
      items: router?.vim.keymap.toolbars[Area.pattern] ?? _fallbackKeymap.toolbars[Area.pattern] ?? const [],
      registry: registry,
      keymap: router?.vim.keymap,
      isOn: (id) => switch (id) {
        'roll.tool.draw' => _tool == PatternTool.draw,
        'roll.tool.select' => _tool == PatternTool.select,
        'roll.tool.erase' => _tool == PatternTool.erase,
        'roll.tool.curve' => _tool == PatternTool.curve,
        'roll.tool.ratchet' => _tool == PatternTool.ratchet,
        'roll.grid.snap' => _snap,
        'roll.grid.triplets' => _triplet,
        'roll.grid.adaptive' => _fixed,
        'roll.view.switch' => _grid,
        'roll.view.velocityLane' => _velLane,
        'roll.view.extrasLanes' => _extrasLane,
        'roll.step.toggle' => _step,
        _ => false,
      },
      isEnabled: (id) => switch (id) {
        'edit.undo' => _undo.isNotEmpty,
        'edit.redo' => _redo.isNotEmpty,
        _ => true,
      },
      selectedCount: _sel.length,
      canPaste: _clip != null,
      onCopy: () => _runRef(ActionRef.action('roll.edit.copy')),
      onPaste: () => _runRef(ActionRef.action('roll.edit.paste')),
      onRun: _runRef,
      snap: (on: _snap, res: _res, triplet: _triplet, fixed: _fixed, value: _look.valueGrid),
      onSnap: _snapMenu,
      canCustomise: router != null,
      onMenu: (v) {
        if (v.startsWith('run:')) return _runRef(ActionRef.action(v.substring(4)));
        switch (v) {
          case 'toolbar':
            if (router != null) {
              showGlassSheet<void>(
                context: context,
                backgroundColor: Neon.panel,
                isScrollControlled: true,
                builder: (_) => _ToolbarEditor(router: router),
              ).then((_) => mounted ? setState(() {}) : null);
            }
          case 'import':
            _importMidi();
          case 'mid':
            _exportMidi(clip: false);
          case 'midi2':
            _exportMidi(clip: true);
          case 'vel':
            setState(() => _velLane = !_velLane);
          case 'extras':
            setState(() => _extrasLane = !_extrasLane);
          case 'hear':
            _hearStop();
            s.settings.update((x) => x.roll = x.roll.copyWith(hearNotes: !x.roll.hearNotes));
          case 'note':
            _openExtras();
        }
      },
      velLane: _velLane,
      extrasLane: _extrasLane,
      stepInput: _step,
      hearNotes: _look.hearNotes,
      zoomBar: _zoomBar,
      onZoom: () => setState(() => _zoomBar = !_zoomBar),
      fullScreen: widget.fullScreen,
      onFullScreen: () {
        _flush();
        if (widget.fullScreen) {
          Navigator.of(context).pop();
        } else {
          // A closable page: Esc (with nothing selected) and the mouse's Back button close it too.
          Navigator.of(context).push(MaterialPageRoute<void>(
              settings: closablePage,
              builder: (_) => GlassPage(
                  child: Scaffold(
                      body: SafeArea(
                          child: PatternEditor(state: s, module: widget.module, fullScreen: true, router: _router,
                              layer: widget.layer, clip: widget.clip))))));
        }
      },
    );
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(children: [
        if (s.selectedClipIds.length > 1)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Row(children: [
              Text('${s.selectedClipIds.length} CLIPS SELECTED',
                style: const TextStyle(color: Neon.dim, fontSize: 9, letterSpacing: 1)),
              const Spacer(),
              if (s.canMultiEditSelectedClips)
                const Text('SHARED SOURCE · edits affect every selected linked clip',
                  style: TextStyle(color: Neon.blue, fontSize: 9))
              else if (references.isNotEmpty)
                Text(_multiEditEnabled ? 'MULTI-EDIT · mirroring to ${references.length} source(s)' : '${references.length} read-only reference source(s)',
                  style: const TextStyle(color: Neon.blue, fontSize: 9)),
              if (references.isNotEmpty && !s.canMultiEditSelectedClips)
                TextButton(onPressed: () => setState(() {
                  _multiEditEnabled = !_multiEditEnabled;
                  if (_multiEditEnabled) { _loadMultiDocs(s); } else { _multiDocs.clear(); _multiSourceIds = []; }
                }), child: Text(_multiEditEnabled ? 'MULTI-EDIT ON' : 'EDIT ALL SELECTED')),

            ])),
        toolbar,
        if (_step) _stepBar(),
        AnimatedSize(duration: Motion.move(Motion.standard, Motion.of(context)), curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _zoomBar ? _zoomRow() : const SizedBox(width: double.infinity)),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth - _keyW, h = box.maxHeight - _lanesH - _rulerH;
            _gridH = h;
            _gridW = w;
            final loop = _loopSteps(d);
            final clip = widget.clip;
            // A clip shows its repeats past the loop bar, up to where it stops playing (in the roll's time).
            final extent = loop == null || clip == null
                ? 0.0
                : (clip.loop ? clip.sourceOffsetSteps % loop : clip.sourceOffsetSteps) + clip.lengthSteps.toDouble();
            final reach = math.max(length.toDouble(), math.max(loop?.toDouble() ?? 0, math.min(extent, length * 8.0 + 64)));
            _maxScrollX = math.max(0.0, reach * _pxPerStep + 200 - w);
            _maxScrollY = math.max(0.0, 128 * _rowH - h);
            _scrollX = _scrollX.clamp(0, _maxScrollX);
            _scrollY = _scrollY.clamp(0, _maxScrollY);
            final grid = _grid ? _gridRows(d) : null;
            // The roll claims every touch on it, so a scrolling page around it (the Builder on a phone) never takes
            // its drags; the pointers are then read raw below.
            return MouseRegion(
              // Over the loop bar, the mouse shows it resizes (the bar drags like a clip's edge).
              // Elsewhere: a grab hand while panning, else what the mouse is over ([_cursorHover]).
              cursor: _loopHover || _loopLive != null
                  ? SystemMouseCursors.resizeColumn
                  : _mousePan != null
                      ? SystemMouseCursors.grabbing
                      : _hoverCursor,
              child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                    () => EagerGestureRecognizer(), (_) {}),
              },
              child: Listener(
                onPointerDown: _pointerDown,
                onPointerMove: _pointerMove,
                onPointerUp: (e) => _pointerUp(e, cancel: false),
                onPointerCancel: (e) => _pointerUp(e, cancel: true),
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) {
                    _glide.stop();
                    _follow.touch();
                    setState(() {
                      final f = e.localPosition - _origin;
                      final factor = e.scrollDelta.dy > 0 ? 0.9 : 1.1;
                      if (HardwareKeyboard.instance.isControlPressed && HardwareKeyboard.instance.isShiftPressed) {
                        _zoomY(_rowH * factor, fy: f.dy);
                        _saveRow();
                      } else if (HardwareKeyboard.instance.isControlPressed) {
                        _zoomX(_pxPerStep * factor, fx: f.dx);
                      } else if (HardwareKeyboard.instance.isShiftPressed) {
                        _scrollX += e.scrollDelta.dy;
                      } else {
                        _scrollY += e.scrollDelta.dy;
                        _scrollX += e.scrollDelta.dx;
                      }
                    });
                  }
                },
                onPointerHover: (e) {
                  _loopHoverAt(e);
                  _curveHover(e);
                  _cursorHover(e);
                },
                // The roll repaints when the notes or the view change; the Curve tool's overlay above it repaints on
                // its own while a curve is hovered or dragged.
                child: Stack(fit: StackFit.expand, children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _RollPainter(
                        doc: d,
                        references: references,
                        sel: _sel,
                        length: length,
                        beatsPerBar: s.project.beatsPerBar,
                        pxPerStep: _pxPerStep,
                        rowH: _rowH,
                        scrollX: _scrollX,
                        scrollY: _scrollY,
                        line: _lineLevel,
                        key: _key,
                        color: _noteColor,
                        cursorAt: _cursorAt,
                        cursorPitch: _cursorPitch,
                        rect: _rectEnd == null || _dragStart == null ? null : Rect.fromPoints(_dragStart!, _rectEnd!),
                        gridRows: grid,
                        focused: _focus.hasFocus,
                        velH: _velLane ? _velH : 0,
                        xH: _extrasLane ? _xH : 0,
                        gridStrength: _look.gridStrength,
                        curves: _tool == PatternTool.curve ? _curves : null,
                        secPerStep: 15 / s.project.bpm,
                        curveMode: _tool == PatternTool.curve,
                        hide: _curveView.value.points == null ? null : _curveView.value.id,
                        keyLabels: _look.keyLabels,
                        lag: _lag,
                        lagIds: _lagIds,
                        lagEdge: _lagEdge,
                        lengthOf: _edge != 0 ? _dragNote : null,
                        ghost: _ghost,
                        motion: _motion,
                      ),
                    ),
                  ),
                  if (loop != null && clip != null)
                    IgnorePointer(child: RepaintBoundary(child: CustomPaint(size: Size.infinite, painter: ClipLoopPainter(
                      doc: d, loopSteps: loop, extentSteps: clip.loop ? extent : loop.toDouble(), pxPerStep: _pxPerStep,
                      rowH: _rowH, scrollX: _scrollX, scrollY: _scrollY, keyW: _keyW, rulerH: _rulerH, gridH: h,
                      color: _noteColor, label: loopLengthLabel(loop, s.project.beatsPerBar),
                      active: _loopLive != null || _loopHover)))),
                  // The song's loop range, as on Arrange's ruler (owner, 2026-11-12): a band on the ruler and, while
                  // on, its ends down the grid; drawn or moved on the ruler, it fades out when it goes.
                  Positioned(left: _keyW, top: 0, right: 0, height: _rulerH + h, child: IgnorePointer(child: ClipRect(
                    child: FadeHold<(double, double, bool)>(
                      value: _shownSongLoop(d),
                      builder: (context, r) => Stack(clipBehavior: Clip.none, children: [
                        LoopBand(from: r.$1 * _pxPerStep - _scrollX, to: r.$2 * _pxPerStep - _scrollX, on: r.$3,
                          band: _rulerH * 0.5),
                        if (r.$3) for (final at in [r.$1, r.$2])
                          Positioned(left: at * _pxPerStep - _scrollX - 0.5, top: _rulerH, bottom: 0, width: 1,
                            child: ColoredBox(color: Neon.blue.withValues(alpha: 0.45))),
                      ]))))),
                  // The song's playhead while it plays this pattern (a live island: it moves on every frame while
                  // playing, live_playhead.dart, without rebuilding the roll; with Smooth follow it moves with the reads).
                  // Stopped, a dimmer line shows where play starts (the edit cursor), as in Arrange; both run the
                  // roll's whole height.
                  Positioned.fill(child: IgnorePointer(child: RepaintBoundary(child: PlayheadFrames(
                    state: s,
                    builder: (context) => ListenableBuilder(listenable: s, builder: (context, _) {
                      final playing = s.meters.playing;
                      return CustomPaint(key: const ValueKey('roll-playhead'),
                        painter: RollPlayheadPainter(
                          step: playing ? _playStep(smooth: !_scrollFollows) : _songToRoll(d, s.playheadStep),
                          stopped: !playing, pxPerStep: _pxPerStep, scrollX: _scrollX, left: _keyW,
                          bottom: box.maxHeight));
                    }))))),
                  // A mouse over the bar: its length and what it does (a finger sees the length on the ruler).
                  if (loop != null && clip != null && _loopHover && _loopLive == null)
                    Positioned(
                      left: (_origin.dx + loop * _pxPerStep - _scrollX + 10).clamp(0.0, math.max(0.0, box.maxWidth - 220)),
                      top: _origin.dy + 4,
                      child: IgnorePointer(
                        child: Container(
                          key: const ValueKey('roll-loop-tip'),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: Neon.bg.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(6), border: Border.all(color: Neon.line)),
                          child: Text('Loop ${loopLengthLabel(loop, s.project.beatsPerBar)} · drag to change, '
                              'right-click for options', style: const TextStyle(color: Neon.text, fontSize: 11)),
                        ),
                      ),
                    ),
                  if (_brushAt != null)
                    Positioned(
                      left: (_origin.dx + _brushNow.dx - 36).clamp(0.0, math.max(0.0, box.maxWidth - 80)),
                      top: math.max(0.0, _origin.dy + _brushNow.dy - 56),
                      child: IgnorePointer(
                        child: Container(
                          key: const ValueKey('ratchet-brush-label'),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                              color: Neon.bg.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Neon.yellow)),
                          child: Text(_brushCount == 1 ? 'Ratchet off' : 'Ratchet $_brushCount',
                              style: const TextStyle(color: Neon.text, fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                      ),
                    ),
                  if (_tool == PatternTool.curve)
                    RepaintBoundary(
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _CurveOverlayPainter(
                          view: _curveView,
                          doc: d,
                          sel: _sel,
                          pxPerStep: _pxPerStep,
                          rowH: _rowH,
                          scrollX: _scrollX,
                          scrollY: _scrollY,
                          gridH: h,
                          color: _noteColor,
                          secPerStep: 15 / s.project.bpm,
                        ),
                      ),
                    ),
                ]),
              ),
            ));
          }),
        ),
        if (widget.clip case final clip? when widget.layer != null && _loopSteps(d) != null)
          ClipLanesStrip(state: s, layer: widget.layer!, clip: clip, loopSteps: _loopSteps(d)!, pxPerStep: _pxPerStep,
              scrollX: _scrollX, keyW: _keyW),
      ]),
    );
  }

  /// The song's loop range to show on the ruler in the roll's steps, and whether it is on: the one being drawn or
  /// moved, else the project's.
  (double, double, bool)? _shownSongLoop(PatternDoc d) {
    if (_rulerEdge != null) {
      final a = math.min(_rulerFrom, _rulerTo), b = math.max(_rulerFrom, _rulerTo);
      return b > a ? (a, b, true) : null;
    }
    final loop = _songLoop(d);
    return loop == null ? null : (loop.$1, loop.$2, s.project.loopRange);
  }

  /// Drum grid rows: the pitches the pattern uses (or C3 when empty), highest first.
  List<double> _gridRows(PatternDoc d) {
    final ps = d.notes.map((n) => n.pitch).toSet().toList()..sort((a, b) => b.compareTo(a));
    return ps.isEmpty ? const [48] : ps;
  }
}

/// Icons for actions that sit well on a toolbar; any other action shows its name.
const Map<String, IconData> _actionIcons = {
  'roll.tool.draw': Icons.edit,
  'roll.tool.select': Icons.highlight_alt,
  'roll.tool.erase': Icons.auto_fix_normal,
  'roll.tool.curve': Icons.gesture,
  'roll.tool.ratchet': Icons.view_week_outlined,
  'edit.undo': Icons.undo,
  'edit.redo': Icons.redo,
  'roll.grid.triplets': Icons.looks_3_outlined,
  'roll.grid.snap': Icons.grid_on,
  'roll.grid.adaptive': Icons.lock_outline,
  'roll.view.switch': Icons.apps,
  'roll.view.zoomIn': Icons.zoom_in,
  'roll.view.zoomOut': Icons.zoom_out,
  'roll.view.fit': Icons.fit_screen,
  'roll.view.velocityLane': Icons.equalizer,
  'roll.view.extrasLanes': Icons.casino_outlined,
  'roll.notes.delete': Icons.delete_outline,
  'roll.notes.extras': Icons.tune,
  'roll.edit.copy': Icons.content_copy,
  'roll.edit.paste': Icons.content_paste,
  'roll.edit.duplicate': Icons.copy_all,
  'roll.notes.quantize': Icons.straighten,
  'roll.gen.euclid': Icons.blur_circular,
  'roll.gen.random': Icons.shuffle,
  'roll.gen.arpeggiate': Icons.stairs_outlined,
  'roll.gen.humanize': Icons.waves,
  'roll.gen.chordStamp': Icons.library_music_outlined,
  'roll.gen.legato': Icons.linear_scale,
  'roll.gen.connect': Icons.timeline,
  'roll.gen.tremolo': Icons.graphic_eq,
  'roll.gen.vibrato': Icons.waves_outlined,
  'roll.notes.quantizeSheet': Icons.align_horizontal_left,
  'roll.step.toggle': Icons.piano,
  'roll.step.rest': Icons.space_bar,
  'roll.gen.reverse': Icons.swap_horiz,
  'roll.gen.invertPitch': Icons.swap_vert,
  'transport.playstop': Icons.play_arrow,
  'transport.stop': Icons.stop,
};

/// Actions the roll can't run yet; they stay in the keymap but don't show on its toolbar.
const Set<String> _notBuilt = {};

/// The roll's toolbar: the keymap's pattern toolbar (the user's own actions and macros, in their order), then the
/// full-screen switch and the ⋮ menu, which always stay.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.items,
    required this.registry,
    required this.keymap,
    required this.isOn,
    required this.isEnabled,
    required this.selectedCount,
    required this.canPaste,
    required this.onCopy,
    required this.onPaste,
    required this.onRun,
    required this.snap,
    required this.onSnap,
    required this.fullScreen,
    required this.onFullScreen,
    required this.onMenu,
    required this.velLane,
    required this.extrasLane,
    required this.stepInput,
    required this.hearNotes,
    required this.canCustomise,
    required this.zoomBar,
    required this.onZoom,
  });
  final bool zoomBar;
  final VoidCallback onZoom;
  final List<ActionRef> items;
  final ActionRegistry registry;
  final Keymap? keymap;
  final bool Function(String id) isOn, isEnabled;
  final int selectedCount;
  final bool canPaste;
  final VoidCallback onCopy, onPaste;
  final ValueChanged<ActionRef> onRun;
  final bool fullScreen, velLane, extrasLane, canCustomise, hearNotes, stepInput;
  final VoidCallback onFullScreen;
  final ValueChanged<String> onMenu;
  final ({bool on, int res, bool triplet, bool fixed, ValueGrid value}) snap;
  final ValueChanged<String> onSnap;

  String _tip(ActionRef r) {
    final name = r.isMacro ? 'Macro: ${r.id}' : (registry[r.id]?.name ?? r.id);
    final keys = keymap?.keysFor(Area.pattern, r).map((k) => k.format()).join(', ') ?? '';
    return keys.isEmpty ? name : '$name ($keys)';
  }

  Widget _item(ActionRef r) {
    if (!r.isMacro && r.id == 'roll.grid.menu') return _SnapButton(snap: snap, onSnap: onSnap, tip: _tip(r));
    final icon = r.isMacro ? null : _actionIcons[r.id];
    final enabled = r.isMacro || isEnabled(r.id);
    if (icon != null) {
      return IconButton(
        tooltip: _tip(r),
        onPressed: enabled
            ? () {
                Haptics.tap();
                onRun(r);
              }
            : null,
        icon: Icon(icon, color: isOn(r.id) ? Neon.yellow : Neon.dim),
      );
    }
    final label = r.isMacro ? '▶ ${r.id}' : (registry[r.id]?.name ?? r.id);
    return Tooltip(
      message: _tip(r),
      child: TextButton(
        onPressed: enabled ? () => onRun(r) : null,
        child: Text(label, style: TextStyle(color: isOn(r.id) ? Neon.yellow : Neon.text)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The tools scroll with a fade where there are more; ⋯ (generators, lanes, MIDI import) stays pinned at the end so
    // it is never hidden past the edge, and on a phone the buttons are a little narrower so the snap fits too.
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 480;
      return IconButtonTheme(
        data: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: Size(narrow ? 40 : 48, 48),
            padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap)),
        child: SizedBox(
      height: 48,
      child: Row(children: [
        Expanded(child: ScrollFade(child: SingleChildScrollView(key: const ValueKey('roll-toolbar'), scrollDirection: Axis.horizontal,
          child: Row(children: [
        for (final r in items)
          if (r.isMacro || !_notBuilt.contains(r.id)) _item(r),
        if (selectedCount > 0) ...[
          TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.content_copy),
            label: Text('Copy ($selectedCount)'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
          TextButton.icon(
            onPressed: canPaste ? onPaste : null,
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ],
        IconButton(
          key: const ValueKey('roll-zoom'),
          tooltip: 'Zoom (or pinch; Ctrl + wheel)',
          onPressed: onZoom,
          icon: Icon(Icons.zoom_in, color: zoomBar ? Neon.blue : Neon.dim),
        ),
        IconButton(
          tooltip: 'Full screen',
          onPressed: onFullScreen,
          icon: Icon(fullScreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Neon.dim),
        ),
        ])))),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: Neon.dim),
          onSelected: onMenu,
          // Sections with headers, the most used first (owner, 2026-11-11).
          itemBuilder: (_) => [
            _menuHead('Notes'),
            const PopupMenuItem(value: 'note', child: Text('Note extras… (I, or hold a note)')),
            const PopupMenuItem(value: 'run:roll.notes.quantizeSheet', child: Text('Quantize…')),
            const PopupMenuItem(value: 'run:roll.gen.tremolo', child: Text('Tremolo…')),
            const PopupMenuItem(value: 'run:roll.gen.vibrato', child: Text('Vibrato…')),
            _menuHead('Tools'),
            CheckedPopupMenuItem(value: 'run:roll.tool.ratchet', checked: isOn('roll.tool.ratchet'),
                child: const Text('Ratchet brush')),
            CheckedPopupMenuItem(value: 'run:roll.step.toggle', checked: stepInput, child: const Text('Step input')),
            CheckedPopupMenuItem(value: 'hear', checked: hearNotes, child: const Text('Hear notes')),
            _menuHead('Lanes'),
            CheckedPopupMenuItem(value: 'vel', checked: velLane, child: const Text('Velocity lane (Alt+V)')),
            CheckedPopupMenuItem(value: 'extras', checked: extrasLane, child: const Text('Chance lane (Alt+X)')),
            _menuHead('Generate'),
            for (final id in const [
              'roll.gen.euclid',
              'roll.gen.random',
              'roll.gen.arpeggiate',
              'roll.gen.chordStamp',
              'roll.gen.humanize',
              'roll.gen.legato',
              'roll.gen.connect',
              'roll.gen.reverse',
              'roll.gen.invertPitch',
            ])
              PopupMenuItem(value: 'run:$id', child: Text(registry[id]?.name ?? id)),
            _menuHead('MIDI files'),
            const PopupMenuItem(value: 'import', child: Text('Import MIDI file…')),
            const PopupMenuItem(value: 'mid', child: Text('Export as MIDI (.mid)')),
            const PopupMenuItem(value: 'midi2', child: Text('Export as MIDI 2.0 clip (.midi2)')),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'toolbar', enabled: canCustomise, child: const Text('Customise toolbar…')),
          ],
        ),
      ]),
    ));
    });
  }
}

/// A section's header in a menu: small caps, not a choice.
PopupMenuItem<String> _menuHead(String text) => PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(text.toUpperCase(),
          style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: Neon.dim)),
    );

/// The snap magnet with its time grid: a tap turns snapping on or off for notes and every curve; the ▾ menu holds
/// the time grid, triplets, adaptive and the value grid, in a sheet (owner, 2026-11-04).
class _SnapButton extends StatelessWidget {
  const _SnapButton({required this.snap, required this.onSnap, required this.tip});
  final ({bool on, int res, bool triplet, bool fixed, ValueGrid value}) snap;
  final ValueChanged<String> onSnap;
  final String tip;

  /// A compact sheet of chip rows (a menu of every choice would be taller than a phone).
  void _open(BuildContext context) {
    var now = snap;
    showGlassSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      builder: (_) => StatefulBuilder(builder: (context, set) {
        void pick(String v) {
          onSnap(v);
          set(() => now = switch (v) {
                'toggle' => (on: !now.on, res: now.res, triplet: now.triplet, fixed: now.fixed, value: now.value),
                'triplets' => (on: now.on, res: now.res, triplet: !now.triplet, fixed: now.fixed, value: now.value),
                'adaptive' => (on: now.on, res: now.res, triplet: now.triplet, fixed: !now.fixed, value: now.value),
                _ when v.startsWith('res:') =>
                  (on: now.on, res: int.parse(v.substring(4)), triplet: now.triplet, fixed: now.fixed, value: now.value),
                _ => (on: now.on, res: now.res, triplet: now.triplet, fixed: now.fixed,
                    value: ValueGrid.values.byName(v.substring(6))),
              });
        }

        Widget title(String t) => Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(t, style: const TextStyle(color: Neon.dim, fontSize: 11, letterSpacing: 1.3)),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Snap (N)'),
                subtitle: const Text('Notes and every curve. Shift or a second finger skips it for one drag.'),
                value: now.on,
                onChanged: (_) => pick('toggle'),
              ),
              title('TIME GRID'),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final x in _resolutions)
                  ChoiceChip(label: Text(x == 1 ? '1 bar' : '1/$x'), selected: now.res == x, onSelected: (_) => pick('res:$x')),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                FilterChip(label: const Text('Triplets'), selected: now.triplet, onSelected: (_) => pick('triplets')),
                FilterChip(label: const Text('Adaptive'), selected: !now.fixed, onSelected: (_) => pick('adaptive')),
              ]),
              title('VALUE GRID · volume, timbre, velocity, chance'),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final g in ValueGrid.values)
                  ChoiceChip(label: Text(g.label), selected: now.value == g, onSelected: (_) => pick('value:${g.name}')),
              ]),
            ]),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = snap.on ? Neon.yellow : Neon.dim;
    final grid = '${snap.res == 1 ? '1' : '1/${snap.res}'}${snap.triplet ? 'T' : ''}';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
        message: tip,
        child: InkWell(
          key: const ValueKey('roll-snap'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => onSnap('toggle'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                CustomPaint(size: const Size(18, 18), painter: _MagnetPainter(c)),
                const SizedBox(width: 4),
                Text(grid, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ),
      IconButton(
        key: const ValueKey('roll-snap-menu'),
        tooltip: 'Snap and grid settings',
        icon: const Icon(Icons.arrow_drop_down, color: Neon.dim),
        onPressed: () => _open(context),
      ),
    ]);
  }
}

/// A horseshoe magnet: Material has no magnet icon.
class _MagnetPainter extends CustomPainter {
  _MagnetPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, t = w * 0.26;
    final body = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = t;
    // An upside-down U: two legs down from an arch, with light tips.
    final r = (w - t) / 2;
    final path = Path()
      ..moveTo(t / 2, h)
      ..lineTo(t / 2, h * 0.45 + r * 0.2)
      ..arcToPoint(Offset(w - t / 2, h * 0.45 + r * 0.2), radius: Radius.circular(r))
      ..lineTo(w - t / 2, h);
    canvas.drawPath(path, body);
    final tip = Paint()..color = Neon.text;
    canvas.drawRect(Rect.fromLTWH(0, h - t * 0.9, t, t * 0.9), tip);
    canvas.drawRect(Rect.fromLTWH(w - t, h - t * 0.9, t, t * 0.9), tip);
  }

  @override
  bool shouldRepaint(_MagnetPainter o) => o.color != color;
}

/// Edits the roll's toolbar: reorder, remove, add any action or macro, or go back to the default.
class _ToolbarEditor extends StatefulWidget {
  const _ToolbarEditor({required this.router});
  final KeyRouterState router;

  @override
  State<_ToolbarEditor> createState() => _ToolbarEditorState();
}

class _ToolbarEditorState extends State<_ToolbarEditor> {
  Keymap get _k => widget.router.vim.keymap;
  late List<ActionRef> _items = List.of(_k.toolbars[Area.pattern] ?? const []);
  Future<void> _saving = Future.value();

  /// Saves one after another, so quick edits never write keys.txt at the same time.
  Future<void> _save() {
    _k.toolbars[Area.pattern] = List.of(_items);
    return _saving = _saving.then((_) => widget.router.saveKeymap());
  }

  Future<void> _add() async {
    final reg = widget.router.registry;
    final choices = [
      for (final d in reg.all)
        if ((d.area == Area.pattern || d.area == Area.global) && !d.internal && !d.takesArg) ActionRef.action(d.id),
      for (final m in _k.macros.names) ActionRef.macro(m),
    ].where((r) => !_items.contains(r)).toList();
    final picked = await showGlassSheet<ActionRef>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (ctx) => _ActionPicker(choices: choices, registry: reg),
    );
    if (picked == null) return;
    setState(() => _items.add(picked));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.router.registry;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(children: [
              const Expanded(child: Text('Roll toolbar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              TextButton(
                onPressed: () async {
                  setState(() => _items = List.of(widget.router.defaults.toolbars[Area.pattern] ?? const []));
                  await _save();
                },
                child: const Text('Default'),
              ),
              FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add')),
            ]),
          ),
          Expanded(
            child: ReorderableListView(
              onReorderItem: (from, to) {
                setState(() => _items.insert(to, _items.removeAt(from)));
                _save();
              },
              children: [
                for (final r in _items)
                  ListTile(
                    key: ValueKey(r),
                    leading: Icon(r.isMacro ? Icons.playlist_play : (_actionIcons[r.id] ?? Icons.label_outline),
                        color: Neon.blue),
                    title: Text(r.isMacro ? 'Macro: ${r.id}' : (reg[r.id]?.name ?? r.id)),
                    subtitle: _notBuilt.contains(r.id) ? const Text('Not built yet, hidden') : null,
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() => _items.remove(r));
                        _save();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// A searchable list of actions and macros to put on the toolbar.
class _ActionPicker extends StatefulWidget {
  const _ActionPicker({required this.choices, required this.registry});
  final List<ActionRef> choices;
  final ActionRegistry registry;

  @override
  State<_ActionPicker> createState() => _ActionPickerState();
}

class _ActionPickerState extends State<_ActionPicker> {
  String _q = '';

  String _name(ActionRef r) => r.isMacro ? 'Macro: ${r.id}' : (widget.registry[r.id]?.name ?? r.id);

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final found = widget.choices.where((r) => q.isEmpty || _name(r).toLowerCase().contains(q) || r.id.contains(q)).toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Find an action or macro'),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: ListView(children: [
                for (final r in found)
                  ListTile(
                    leading: Icon(r.isMacro ? Icons.playlist_play : (_actionIcons[r.id] ?? Icons.label_outline),
                        color: Neon.blue),
                    title: Text(_name(r)),
                    subtitle: r.isMacro ? null : Text(r.id, style: Neon.code(size: 11)),
                    onTap: () => Navigator.pop(context, r),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One undo step: the doc before an edit, or, with [sel], the selection before a selection box changed it.
class _Undo {
  const _Undo(this.doc, {this.sel});
  final PatternDoc doc;
  final Set<int>? sel;
}

/// What a touch grabs with the Curve tool: a note's pitch point [point], its line ([line]), or the note itself.
@immutable
class _CurveHit {
  const _CurveHit(this.id, {this.point, this.line = false, this.handle});
  final int id;
  final int? point;
  final bool line;
  final int? handle; // a segment's tension handle: the segment after point [handle]

  @override
  bool operator ==(Object o) =>
      o is _CurveHit && o.id == id && o.point == point && o.line == line && o.handle == handle;
  @override
  int get hashCode => Object.hash(id, point, line, handle);
}

/// The tension handles of curve [pts] on a note [nw] px wide: one on each segment that changes pitch and is at
/// least 16 px wide, at its middle in time and on the curve there (u 0..1 along the note, v in semitones).
List<({int seg, double u, double v})> curveHandles(List<NotePoint> pts, double nw) => [
      for (var i = 0; i + 1 < pts.length; i++)
        if ((pts[i + 1].v - pts[i].v).abs() > 1e-6 && (pts[i + 1].t - pts[i].t) * nw >= 16)
          (
            seg: i,
            u: (pts[i].t + pts[i + 1].t) / 2,
            v: NoteExpression.valueAt(pts, (pts[i].t + pts[i + 1].t) / 2),
          ),
    ];

/// The bend (k, -1..1) that puts a segment from [a] to [b] through [v] at its middle in time: the curve is
/// a + (b - a) x^(4^k), so k = log4(ln f / ln 0.5) for f = (v - a) / (b - a).
double tensionThrough(double a, double b, double v) {
  final f = ((v - a) / (b - a)).clamp(0.02, 0.98);
  final k = math.log(math.log(f) / math.log(0.5)) / math.log(4);
  return (k.clamp(-1.0, 1.0) * 100).roundToDouble() / 100;
}

/// The Curve tool's overlay: what the mouse or finger would grab ([hit]), and while a drag is under way note [id]'s
/// [points] as they will be committed, [active] the one that follows the finger; [drawing]: a new point being placed.
@immutable
class _CurveView {
  const _CurveView({this.hit, this.id, this.points, this.active, this.drawing = false, this.handle});
  final _CurveHit? hit;
  final int? id;
  final List<NotePoint>? points;
  final int? active;
  final int? handle; // the tension handle being dragged
  final bool drawing;
}

/// Whether [e] bends its note away from its row (a pitch curve or vibrato): the roll then draws it as a ribbon.
bool _isBent(NoteExpression e) => e.bend.isNotEmpty || e.vibDepth > 0;

/// Whether a note [nw] px wide, [lenSec] long, draws its vibrato as a wave: only while a cycle spans at least 8 px;
/// zoomed out it would alias into spikes (#170), so the ribbon follows the bend alone inside a faint band.
bool _vibWave(NoteExpression e, double nw, double lenSec) =>
    e.vibDepth > 0 && e.vibRate > 0 && lenSec > 0 && nw / (lenSec * e.vibRate) >= 8;

/// The pitch the roll draws [px] into a note [nw] px wide (clamped to the note, so a stretch in progress holds its
/// ends): the smoothed curve ([displayCurveAt]), plus the vibrato while it is drawn as a wave. In rows above the
/// note's own; the sound follows the stored curve.
double _drawnPitch(NoteExpression e, double px, double nw, double lenSec, bool wave) {
  final u = nw > 0 ? (px / nw).clamp(0.0, 1.0) : 0.0;
  final bend = displayCurveAt(e.bend, u, nw);
  return wave ? bend + e.pitchAt(u, u * lenSec) - NoteExpression.valueAt(e.bend, u) : bend;
}

/// A bent note's ribbon at [px] into it: its centre's height above the row's middle, its [slope] on screen (px down
/// per px across) and [half] its height straight up and down there. The ribbon keeps the note's thickness across its
/// slope, so a glide stays as solid as the note; [half] grows with the slope (up to 8 times, for a near-vertical
/// jump). The painter and the note tool's hit test both use this.
({double dy, double slope, double half}) _ribbonAt(
    NoteExpression e, double px, double nw, double rowH, double lenSec, bool wave) {
  final c = _drawnPitch(e, px, nw, lenSec, wave);
  final slope = -(_drawnPitch(e, px + 1, nw, lenSec, wave) - _drawnPitch(e, px - 1, nw, lenSec, wave)) * rowH / 2;
  return (dy: c * rowH, slope: slope, half: (rowH - 2) / 2 * math.min(8.0, math.sqrt(1 + slope * slope)));
}

/// A bent note's pitch line as the roll draws it, for a note at [x] (row top [y], [nw] wide) on a grid [w] wide, its
/// ends at [left] and [right] (a stretch in progress moves one): the ribbon's centre, and [band]: draw the vibrato as
/// a faint band (zoomed out). Sampled every 2 px where it is on screen plus at its points, so it draws cleanly at any
/// zoom.
({Path line, bool band}) _pitchPath(NoteExpression e,
    {required double x, required double y, required double nw, required double w, required double rowH,
    required double lenSec, double? left, double? right}) {
  final wave = _vibWave(e, nw, lenSec);
  final l = (left ?? x) - x, r = (right ?? x + nw) - x;
  final from = math.max(l, -x), to = math.min(r, w - x);
  final xs = <double>{for (var px = (from / 2).ceil() * 2.0; px < to; px += 2) px, from, to,
    for (final q in e.bend) if (q.t * nw > from && q.t * nw < to) q.t * nw}.toList()..sort();
  final line = Path(), mid = y + rowH / 2;
  for (var i = 0; i < xs.length; i++) {
    final py = mid - _drawnPitch(e, xs[i], nw, lenSec, wave) * rowH;
    i == 0 ? line.moveTo(x + xs[i], py) : line.lineTo(x + xs[i], py);
  }
  return (line: line, band: drawsVibratoAsBand(e, nw, lenSec));
}

/// Whether the roll draws [e]'s vibrato as a faint band round the ribbon (zoomed out, a note [nw] px wide and
/// [lenSec] long) instead of as a wave.
@visibleForTesting
bool drawsVibratoAsBand(NoteExpression e, double nw, double lenSec) => e.vibDepth > 0 && !_vibWave(e, nw, lenSec);

/// One note of the roll in [box] (its row at [x], [y], [nw] wide, its stretch already applied to [box]): layer
/// colour, brighter when louder. A bent note is itself bent (owner, 2026-11-10: "the actual MIDI note itself to be
/// the one that's bent"): a ribbon of its own height whose centre follows the smoothed pitch, a bright thread
/// through its middle, and its start row kept as a faint anchor. [points] 1 shows its pitch points dim, 2 bright, on
/// their true values. White outline when [selected].
void _paintNote(Canvas canvas, PatternNote n, NoteExpression e, Rect box,
    {required double x, required double y, required double nw, required double w, required double rowH,
    required Color color, required double secPerStep, required bool selected, int points = 0}) {
  final r = RRect.fromRectAndRadius(box, const Radius.circular(3));
  final fill = color.withValues(alpha: 0.35 + 0.65 * n.vel);
  if (!_isBent(e)) {
    canvas.drawRRect(r, Paint()..color = fill);
    if (selected) {
      canvas.drawRRect(r, Paint()
        ..color = Neon.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    return;
  }
  // The anchor: the row the note is written on, faint.
  canvas.drawRRect(r, Paint()..color = fill.withValues(alpha: 0.12));
  canvas.drawRRect(r, Paint()
    ..color = fill.withValues(alpha: 0.3)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8);
  final shape = _pitchPath(e,
      x: x, y: y, nw: nw, w: w, rowH: rowH, lenSec: n.len.toDouble() * secPerStep, left: box.left, right: box.right);
  if (shape.band) {
    canvas.drawPath(shape.line, Paint()
      ..color = fill.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = rowH - 2 + 2 * e.vibDepth * rowH);
  }
  // The ribbon: the line stroked as thick as the note, square to it at its ends, in the note's colour made opaque
  // over the grid so where a tight turn folds the stroke over itself it doesn't show darker. Selected, a white
  // stroke a little wider underneath outlines it.
  final ribbon = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = rowH - 2;
  if (selected) canvas.drawPath(shape.line, ribbon..color = Neon.text..strokeWidth = rowH + 1);
  canvas.drawPath(shape.line, ribbon
    ..color = Color.alphaBlend(fill, Neon.panel)
    ..strokeWidth = rowH - 2);
  if (rowH >= 6) {
    canvas.drawPath(shape.line, Paint()
      ..color = Color.lerp(color, Neon.text, 0.55)!.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 1.2);
  }
  if (points > 0) {
    final dot = Paint()..color = points > 1 ? Neon.yellow : Neon.yellow.withValues(alpha: 0.55);
    for (final p in e.bend) {
      canvas.drawCircle(Offset(x + p.t * nw, y + rowH / 2 - p.v * rowH), points > 1 ? 5 : 3.5, dot);
    }
  }
}

/// The Curve tool's overlay on the roll, repainted on its own as [view] changes (a drag repaints only this, once a
/// frame): the curve under the mouse or finger lit, and a curve being dragged with its start, the point that follows
/// the finger, a guide at that point's time and its pitch as a label (`+2.0 st`).
class _CurveOverlayPainter extends CustomPainter {
  _CurveOverlayPainter({
    required this.view,
    required this.doc,
    required this.sel,
    required this.pxPerStep,
    required this.rowH,
    required this.scrollX,
    required this.scrollY,
    required this.gridH,
    required this.color,
    required this.secPerStep,
  }) : super(repaint: view);
  final ValueListenable<_CurveView> view;
  final PatternDoc doc;
  final Set<int> sel;
  final double pxPerStep, rowH, scrollX, scrollY, gridH, secPerStep;
  final Color color;

  static const keyW = _PatternEditorState._keyW, rulerH = _PatternEditorState._rulerH;

  @override
  void paint(Canvas canvas, Size size) {
    RollPaintStats.live++;
    RollPaintStats.label = null;
    RollPaintStats.anchor = null;
    final v = view.value, w = size.width - keyW;
    canvas.save();
    canvas.translate(keyW, rulerH);
    canvas.clipRect(Rect.fromLTWH(0, 0, w, gridH));
    PatternNote? note(int? id) => id == null ? null : doc.byId(id);
    double nx(PatternNote n) => n.at.toDouble() * pxPerStep - scrollX;
    double nwOf(PatternNote n) => math.max(3.0, n.len.toDouble() * pxPerStep - 1);
    double ny(PatternNote n) => (127 - n.pitch.round()) * rowH - scrollY;
    final live = note(v.id), pts = v.points;
    if (live != null && pts != null) {
      final x = nx(live), y = ny(live), nw = nwOf(live), mid = y + rowH / 2;
      final e = live.expr.copyWith(bend: pts);
      _paintNote(canvas, live, e, Rect.fromLTWH(x, y + 1, nw, rowH - 2),
          x: x, y: y, nw: nw, w: w, rowH: rowH, color: color, secPerStep: secPerStep,
          selected: sel.contains(live.id), points: 2);
      if (pts.isNotEmpty) {
        // Where the curve starts: a ring round its first point.
        final a = Offset(x + pts.first.t * nw, mid - pts.first.v * rowH);
        RollPaintStats.anchor = a;
        canvas.drawCircle(a, 8, Paint()
          ..color = Neon.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      }
      final i = v.active;
      if (i != null && i < pts.length) {
        final q = pts[i], at = Offset(x + q.t * nw, mid - q.v * rowH);
        // A guide at the point's time, the point itself, and its pitch.
        canvas.drawLine(Offset(at.dx, 0), Offset(at.dx, gridH), Paint()
          ..color = Neon.yellow.withValues(alpha: 0.45)
          ..strokeWidth = 1);
        canvas.drawCircle(at, 7, Paint()..color = Neon.yellow);
        canvas.drawCircle(at, 7, Paint()
          ..color = Neon.bg
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
        final text = bendLabel(q.v);
        RollPaintStats.label = text;
        final label = TextPainter(
          text: TextSpan(text: text, style: const TextStyle(color: Neon.text, fontSize: 11, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout();
        final top = at.dy - label.height - 14;
        final lp = Offset((at.dx - label.width / 2).clamp(0.0, math.max(0.0, w - label.width)),
            top < 0 ? at.dy + 12 : top);
        canvas.drawRRect(RRect.fromRectAndRadius((lp - const Offset(4, 1)) & Size(label.width + 8, label.height + 2),
            const Radius.circular(4)), Paint()..color = Neon.bg.withValues(alpha: 0.85));
        label.paint(canvas, lp);
      }
    }
    // Tension handles on each selected note's bent segments: a diamond on the curve at the segment's middle, and a
    // faint chord between its ends so the bend reads against a straight line.
    for (final id in sel) {
      final n = note(id);
      if (n == null) continue;
      final bend = id == v.id && pts != null ? pts : n.expr.bend;
      if (bend.length < 2) continue;
      final x = nx(n), nw = nwOf(n), mid = ny(n) + rowH / 2;
      for (final h in curveHandles(bend, nw)) {
        final a = bend[h.seg], b = bend[h.seg + 1];
        final on = id == v.id && v.handle == h.seg;
        canvas.drawLine(Offset(x + a.t * nw, mid - a.v * rowH), Offset(x + b.t * nw, mid - b.v * rowH), Paint()
          ..color = Neon.blue.withValues(alpha: on ? 0.6 : 0.3)
          ..strokeWidth = 1);
        final c = Offset(x + h.u * nw, mid - h.v * rowH), r = on ? 7.0 : 5.0;
        final diamond = Path()
          ..moveTo(c.dx, c.dy - r)
          ..lineTo(c.dx + r, c.dy)
          ..lineTo(c.dx, c.dy + r)
          ..lineTo(c.dx - r, c.dy)
          ..close();
        canvas.drawPath(diamond, Paint()..color = on ? Neon.blue : Neon.blue.withValues(alpha: 0.8));
        canvas.drawPath(diamond, Paint()
          ..color = Neon.bg
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
        if (on) {
          final text = 'curve ${a.k >= 0 ? '+' : ''}${a.k.toStringAsFixed(2)}';
          RollPaintStats.label = text;
          final label = TextPainter(
            text: TextSpan(text: text, style: const TextStyle(color: Neon.text, fontSize: 11, fontWeight: FontWeight.w600)),
            textDirection: TextDirection.ltr,
          )..layout();
          final lp = Offset((c.dx - label.width / 2).clamp(0.0, math.max(0.0, w - label.width)),
              c.dy - label.height - 14 < 0 ? c.dy + 12 : c.dy - label.height - 14);
          canvas.drawRRect(RRect.fromRectAndRadius((lp - const Offset(4, 1)) & Size(label.width + 8, label.height + 2),
              const Radius.circular(4)), Paint()..color = Neon.bg.withValues(alpha: 0.85));
          label.paint(canvas, lp);
        }
      }
    }
    // What the mouse or finger would grab: its point ringed, or its line lit.
    final hit = v.hit, hn = note(hit?.id);
    if (hit != null && hn != null && v.active == null) {
      final e = hit.id == v.id && pts != null ? hn.expr.copyWith(bend: pts) : hn.expr;
      final x = nx(hn), y = ny(hn), nw = nwOf(hn);
      if (hit.handle != null) {
        for (final h in curveHandles(e.bend, nw)) {
          if (h.seg != hit.handle) continue;
          canvas.drawCircle(Offset(x + h.u * nw, y + rowH / 2 - h.v * rowH), 9, Paint()
            ..color = Neon.blue
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
        }
      } else if (hit.point != null && hit.point! < e.bend.length) {
        final q = e.bend[hit.point!];
        canvas.drawCircle(Offset(x + q.t * nw, y + rowH / 2 - q.v * rowH), 9, Paint()
          ..color = Neon.yellow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      } else if (hit.line) {
        final line = _pitchPath(e, x: x, y: y, nw: nw, w: w, rowH: rowH, lenSec: hn.len.toDouble() * secPerStep);
        canvas.drawPath(line.line, Paint()
          ..color = Neon.yellow.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = rowH + 4);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CurveOverlayPainter o) =>
      !identical(o.doc, doc) ||
      o.view != view ||
      o.sel != sel ||
      o.pxPerStep != pxPerStep ||
      o.rowH != rowH ||
      o.scrollX != scrollX ||
      o.scrollY != scrollY ||
      o.gridH != gridH ||
      o.color != color ||
      o.secPerStep != secPerStep;
}

/// A pitch point's value as the Curve tool labels it: `+2.0 st`, `-1.5 st`, `0.0 st`.
String bendLabel(double v) => '${v > 0 ? '+' : v < 0 ? '-' : ''}${v.abs().toStringAsFixed(1)} st';

class _RollPainter extends CustomPainter {
  _RollPainter({
    required this.doc,
    required this.references,
    required this.sel,
    required this.length,
    required this.beatsPerBar,
    required this.pxPerStep,
    required this.rowH,
    required this.scrollX,
    required this.scrollY,
    required this.line,
    required this.key,
    required this.color,
    required this.cursorAt,
    required this.cursorPitch,
    required this.rect,
    required this.gridRows,
    required this.focused,
    required this.velH,
    required this.xH,
    required this.gridStrength,
    required this.keyLabels,
    required this.curves,
    required this.secPerStep,
    required this.curveMode,
    this.hide,
    this.lag = 0,
    this.lagIds = const {},
    this.lagEdge = 1,
    this.lengthOf,
    this.ghost,
    this.motion,
  }) : super(repaint: motion?.anim);
  final _RollMotion? motion; // an edit animation under way
  // A stretch in progress: the notes' edge (end 1, start -1) is drawn [lag] px past its snapped place.
  final double lag;
  final Set<int> lagIds;
  final int lagEdge;
  final int? lengthOf; // the note whose length shows as a number (a stretch or a draw in progress)
  final ({Steps at, double pitch, Steps len})? ghost; // where a tap would draw
  final Map<int, LaneCurve>? curves;
  final double secPerStep; // seconds per 16th at the project tempo, for drawing vibrato
  final bool curveMode; // the Curve tool: every bent note shows its pitch points (brighter when selected)
  final int? hide; // the note the curve overlay draws while its curve is dragged
  final double velH, xH, gridStrength;
  final KeyLabels keyLabels;
  final PatternDoc doc;
  final List<PatternDoc> references;
  final Set<int> sel;
  final int length, beatsPerBar;
  final double pxPerStep, rowH, scrollX, scrollY, cursorPitch;
  final Steps line, cursorAt;
  final ({int root, List<int> scale})? key;
  final Color color;
  final Rect? rect;
  final List<double>? gridRows;
  final bool focused;

  static const keyW = _PatternEditorState._keyW, rulerH = _PatternEditorState._rulerH;
  static const _names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  @override
  void paint(Canvas canvas, Size size) {
    RollPaintStats.roll++;
    final w = size.width - keyW, h = size.height - velH - xH - rulerH;
    final bg = Paint()..color = Neon.bg;
    canvas.drawRect(Offset.zero & size, bg);
    canvas.save();
    canvas.translate(keyW, rulerH);
    canvas.clipRect(Rect.fromLTWH(0, 0, w, h));
    // Rows: those in the project's key are lit (owner: highlight only, no lock).
    final first = (scrollY / rowH).floor(), last = math.min(127, ((scrollY + h) / rowH).ceil());
    for (var r = first; r <= last; r++) {
      final pitch = 127 - r;
      final inKey = key == null || key!.scale.contains((pitch - key!.root) % 12);
      final y = r * rowH - scrollY;
      canvas.drawRect(Rect.fromLTWH(0, y, w, rowH),
          Paint()..color = inKey ? Neon.panel : Neon.bg.withValues(alpha: 1));
      if (pitch % 12 == 0) canvas.drawLine(Offset(0, y + rowH), Offset(w, y + rowH), Paint()..color = Neon.line);
    }
    // Adaptive grid lines: finer lines appear as you zoom in, down to the resolution.
    final lineSteps = line.toDouble();
    final bar = beatsPerBar * 4.0;
    final t0 = scrollX / pxPerStep, t1 = (scrollX + w) / pxPerStep;
    for (var t = (t0 / lineSteps).floor() * lineSteps; t <= t1; t += lineSteps) {
      final x = t * pxPerStep - scrollX;
      final isBar = (t % bar).abs() < 1e-9, isBeat = (t % 4).abs() < 1e-9;
      final c = isBar ? Neon.dim : Neon.line, a = isBar || isBeat ? 1.0 : 0.45;
      canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = c.withValues(alpha: (c.a * a * gridStrength).clamp(0.0, 1.0)));
    }
    // Past the pattern's end is shaded.
    final endX = length * pxPerStep - scrollX;
    if (endX < w) canvas.drawRect(Rect.fromLTWH(endX, 0, w - endX, h), Paint()..color = const Color(0x88000000));
    // Other selected clips are faint references; the active source remains the only editable owner.
    for (final reference in references) {
      for (final n in reference.notes) {
        final x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
        if (x > w || x + nw < 0) continue;
        final y = (127 - n.pitch.round()) * rowH - scrollY;
        if (y > h || y + rowH < 0) continue;
        final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, y + 1, nw, rowH - 2), const Radius.circular(3));
        canvas.drawRRect(r, Paint()..color = Neon.blue.withValues(alpha: 0.13));
        canvas.drawRRect(r, Paint()..color = Neon.blue.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke..strokeWidth = 0.8);
      }
    }
    // Notes: layer colour, brighter when louder; white outline when selected; a dot when it has extras.
    final m = motion, mt = m?.t ?? 1;
    var animated = 0;
    for (final n in doc.notes) {
      var x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
      var y = (127 - n.pitch.round()) * rowH - scrollY;
      double? alpha;
      if (m != null && mt < 1) {
        final was = m.was[n.id];
        if (m.appear.contains(n.id)) {
          animated++;
          alpha = mt;
          if (!m.fade) nw = math.max(3.0, nw * mt); // pops in from its start
        } else if (was != null && !m.fade) {
          animated++;
          final x0 = was.at * pxPerStep - scrollX, y0 = (127 - was.pitch.round()) * rowH - scrollY;
          final w0 = math.max(3.0, was.len * pxPerStep - 1);
          x = x0 + (x - x0) * mt;
          y = y0 + (y - y0) * mt;
          nw = w0 + (nw - w0) * mt;
        }
      }
      if (x > w || x + nw < 0) continue;
      final e = n.expr;
      final bent = _isBent(e);
      // A bent note can sound far from its row: keep it on screen while any of its curve is.
      final reach = bent ? (e.bend.fold(0.0, (m, p) => math.max(m, p.v.abs())) + e.vibDepth + 2) * rowH : 0.0;
      if (y - reach > h || y + rowH + reach < 0 || n.id == hide) continue;
      var box = Rect.fromLTWH(x, y + 1, nw, rowH - 2);
      if (lag != 0 && lagIds.contains(n.id)) {
        // The snapped length as a faint ghost; the note itself follows the finger.
        canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)),
            Paint()
              ..color = Neon.text.withValues(alpha: 0.5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
        box = lagEdge > 0
            ? Rect.fromLTRB(box.left, box.top, math.max(box.left + 3, box.right + lag), box.bottom)
            : Rect.fromLTRB(math.min(box.right - 3, box.left + lag), box.top, box.right, box.bottom);
      }
      if (alpha != null) canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0)));
      _paintNote(canvas, n, e, box,
          x: x, y: y, nw: nw, w: w, rowH: rowH, color: color, secPerStep: secPerStep, selected: sel.contains(n.id),
          points: !curveMode || !bent ? 0 : (sel.contains(n.id) ? 2 : 1));
      if (alpha != null) canvas.restore();
      if (n.prob < 1 || n.ratchet > 1 || n.slide) {
        // On the ribbon where a bent note starts.
        final lift = bent ? _drawnPitch(e, 4, nw, n.len.toDouble() * secPerStep, false) * rowH : 0.0;
        canvas.drawCircle(Offset(x + 4, y + rowH / 2 - lift), 2, Paint()..color = Neon.bg);
      }
    }
    if (m != null && mt < 1) {
      // Deleted notes shrink to their middle and fade (only fade when reduced).
      final k = 1 - m.exit;
      for (final n in m.gone) {
        final x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
        final y = (127 - n.pitch.round()) * rowH - scrollY;
        if (x > w || x + nw < 0 || y > h || y + rowH < 0) continue;
        animated++;
        final full = Rect.fromLTWH(x, y + 1, nw, rowH - 2);
        final box = m.fade ? full : Rect.fromCenter(center: full.center, width: full.width * k, height: full.height * k);
        canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)),
            Paint()..color = color.withValues(alpha: (0.35 + 0.65 * n.vel) * k));
      }
    }
    RollPaintStats.edits = animated;
    final g = ghost;
    if (g != null) {
      final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(g.at.toDouble() * pxPerStep - scrollX, (127 - g.pitch) * rowH - scrollY + 1,
              math.max(3.0, g.len.toDouble() * pxPerStep - 1), rowH - 2),
          const Radius.circular(3));
      canvas.drawRRect(r, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawRRect(r, Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    final lenNote = lengthOf == null ? null : doc.byId(lengthOf!);
    if (lenNote != null) {
      // The length while it is dragged, above the note's end.
      final label = TextPainter(
        text: TextSpan(
            text: noteLengthLabel(lenNote.len),
            style: TextStyle(color: Neon.text, fontSize: 11, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final end = lenNote.end.toDouble() * pxPerStep - scrollX + (lagIds.contains(lenNote.id) && lagEdge > 0 ? lag : 0);
      // Above the note's end, where its ribbon ends if it is bent.
      final endPx = math.max(3.0, lenNote.len.toDouble() * pxPerStep - 1);
      final lift = _isBent(lenNote.expr)
          ? _drawnPitch(lenNote.expr, endPx, endPx, lenNote.len.toDouble() * secPerStep, false) * rowH
          : 0.0;
      final top = (127 - lenNote.pitch.round()) * rowH - scrollY - lift - label.height - 4;
      final at = Offset((end - label.width / 2).clamp(0.0, math.max(0.0, w - label.width)), math.max(0.0, top));
      canvas.drawRRect(RRect.fromRectAndRadius((at - const Offset(4, 1)) & Size(label.width + 8, label.height + 2),
          const Radius.circular(4)), Paint()..color = Neon.bg.withValues(alpha: 0.85));
      label.paint(canvas, at);
    }
    // The keyboard cursor.
    if (focused) {
      final cx = cursorAt.toDouble() * pxPerStep - scrollX, cy = (127 - cursorPitch) * rowH - scrollY;
      canvas.drawRect(Rect.fromLTWH(cx, cy, math.max(4, line.toDouble() * pxPerStep), rowH),
          Paint()
            ..color = Neon.blue
            ..style = PaintingStyle.stroke);
    }
    if (rect != null) {
      canvas.drawRect(rect!, Paint()..color = Neon.blue.withValues(alpha: 0.15));
    }
    canvas.restore();
    // Piano keys and ruler.
    final ts = TextPainter(textDirection: TextDirection.ltr);
    for (var r = first; r <= last; r++) {
      final pitch = 127 - r, y = rulerH + r * rowH - scrollY;
      if (y < rulerH - rowH || y > rulerH + h) continue;
      final black = const [1, 3, 6, 8, 10].contains(pitch % 12);
      canvas.drawRect(Rect.fromLTWH(0, y, keyW - 2, rowH - 1), Paint()..color = black ? Neon.bg : Neon.panelHi);
      final label = switch (keyLabels) {
        KeyLabels.none => false,
        KeyLabels.octaves => pitch % 12 == 0,
        KeyLabels.all => !black && rowH >= 11,
      };
      if (label) {
        ts.text = TextSpan(
            text: '${_names[pitch % 12]}${pitch ~/ 12 - 1}',
            style: TextStyle(color: Neon.dim, fontSize: math.min(10, rowH - 4)));
        ts.layout();
        ts.paint(canvas, Offset(4, y + 2));
      }
    }
    canvas.drawRect(Rect.fromLTWH(keyW, 0, w, rulerH), Paint()..color = Neon.panel);
    // A label every bar, or every 4, 16, 64… bars zoomed far out, so they never crowd (owner, 2026-11-11).
    var every = 1;
    while (every * bar * pxPerStep < 28 && every < 1 << 20) {
      every *= 4;
    }
    for (var b = (t0 / bar / every).floor() * every; b * bar <= t1; b += every) {
      final x = keyW + b * bar * pxPerStep - scrollX;
      if (x < keyW) continue;
      ts.text = TextSpan(text: '${b + 1}', style: const TextStyle(color: Neon.dim, fontSize: 11));
      ts.layout();
      ts.paint(canvas, Offset(x + 3, 3));
    }
    // Lanes: velocity, then chance (with ratchet and slide marks).
    void lane(double top, double hgt, double Function(PatternNote) value, {bool marks = false}) {
      canvas.drawRect(Rect.fromLTWH(keyW, top, w, hgt), Paint()..color = Neon.panel);
      canvas.drawLine(Offset(keyW, top), Offset(size.width, top), Paint()..color = Neon.line);
      for (final n in doc.notes) {
        final x = keyW + n.at.toDouble() * pxPerStep - scrollX;
        if (x < keyW || x > size.width) continue;
        final bh = (hgt - 6) * value(n);
        final paint = Paint()..color = sel.contains(n.id) ? Neon.text : color;
        canvas.drawRect(Rect.fromLTWH(x, top + hgt - 3 - bh, 3, bh), paint);
        if (marks && n.ratchet > 1) {
          for (var i = 1; i < n.ratchet; i++) {
            canvas.drawRect(Rect.fromLTWH(x + 4 + i * 3, top + hgt - 6, 2, 3), paint);
          }
        }
        if (marks && n.slide) canvas.drawLine(Offset(x, top + 3), Offset(x + 10, top + 3), paint);
      }
    }

    if (velH > 0) lane(rulerH + h, velH, (n) => n.vel);
    if (xH > 0) lane(rulerH + h + velH, xH, (n) => n.prob, marks: true);
    // The Curve tool's curves, over their lanes: the line, sampled every few pixels, and its points.
    void curve(LaneCurve c, double top, double hgt) {
      if (c.isEmpty) return;
      double y(double v) => top + 3 + (1 - v) * (hgt - 6);
      final path = Path();
      for (var x = keyW; x <= size.width; x += 3) {
        final v = c.valueAt((x - keyW + scrollX) / pxPerStep);
        x == keyW ? path.moveTo(x, y(v)) : path.lineTo(x, y(v));
      }
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(keyW, top, w, hgt));
      canvas.drawPath(path, Paint()
        ..color = Neon.yellow
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      for (final q in c.points) {
        canvas.drawCircle(Offset(keyW + q.at * pxPerStep - scrollX, y(q.value)), 5, Paint()..color = Neon.yellow);
      }
      canvas.restore();
    }

    final cs = curves;
    if (cs != null) {
      if (velH > 0) curve(cs[1]!, rulerH + h, velH);
      if (xH > 0) curve(cs[2]!, rulerH + h + velH, xH);
    }
  }

  @override
  bool shouldRepaint(_RollPainter o) =>
      !identical(o.doc, doc) ||
      o.references != references ||
      o.sel != sel ||
      o.pxPerStep != pxPerStep ||
      o.scrollX != scrollX ||
      o.scrollY != scrollY ||
      o.line != line ||
      o.cursorAt != cursorAt ||
      o.cursorPitch != cursorPitch ||
      o.rect != rect ||
      o.focused != focused ||
      o.velH != velH ||
      o.xH != xH ||
      o.rowH != rowH ||
      o.gridStrength != gridStrength ||
      o.keyLabels != keyLabels ||
      o.curves != curves ||
      o.secPerStep != secPerStep ||
      o.curveMode != curveMode ||
      o.hide != hide ||
      o.lag != lag ||
      o.lagIds != lagIds ||
      o.lagEdge != lagEdge ||
      o.lengthOf != lengthOf ||
      o.ghost != ghost ||
      o.motion != motion ||
      o.color != color;
}

/// An edit animation on the roll: [appear] pops in from its start, [was] holds where moved or resized notes were,
/// [gone] shrinks and fades; with [fade] (Reduced motion) only opacity changes.
class _RollMotion {
  _RollMotion(this.anim, {required this.appear, required this.was, required this.gone, required this.fade,
      required this.curve});
  final Animation<double> anim;
  final Set<int> appear;
  final Map<int, ({double at, double pitch, double len})> was;
  final List<PatternNote> gone;
  final bool fade;
  final Curve curve;

  double get t => curve.transform(anim.value.clamp(0.0, 1.0));
  double get exit => EditMotion.exitCurve.transform(anim.value.clamp(0.0, 1.0));
}

/// The settings a generator asks for, as named numbers; the last values are kept for the next time.
class _GenDialog extends StatefulWidget {
  const _GenDialog({required this.id, required this.rate});
  final String id;

  /// The roll's grid: Tremolo's repeats come this often.
  final Steps rate;

  static final Map<String, double> _last = {};

  @override
  State<_GenDialog> createState() => _GenDialogState();
}

class _GenDialogState extends State<_GenDialog> {
  late final List<(String key, String label, double min, double max, double init, List<String>? names)> _fields =
      switch (widget.id) {
    'roll.gen.euclid' => [
        ('pulses', 'Hits', 1, 32, 3, null),
        ('steps', 'Steps (at the grid size)', 1, 32, 8, null),
        ('rotate', 'Rotate', 0, 31, 0, null),
      ],
    'roll.gen.random' => [
        ('density', 'Density %', 5, 100, 50, null),
        ('range', 'Range ± semitones', 1, 24, 7, null),
        ('bars', 'Bars', 1, 8, 1, null),
      ],
    'roll.gen.arpeggiate' => [('order', 'Order', 0, 2, 0, ['Up', 'Down', 'Up and down'])],
    'roll.gen.humanize' => [
        ('timing', 'Timing ± % of a step', 0, 50, 10, null),
        ('velocity', 'Velocity ± %', 0, 50, 10, null),
      ],
    'roll.gen.connect' => [('glide', 'Glide into the next note, % of each note', 0, 100, 25, null)],
    'roll.gen.tremolo' => [
        ('mode', 'As', 0, 1, 0, ['Volume', 'Repeats at ${noteLengthLabel(widget.rate)}']),
        ('wave', 'Wave', 0, 2, 0, ['Sine', 'Triangle', 'Square']),
        ('cycle', 'Speed', 0, 3, 2, [for (final c in _tremoloCycles) 'Every ${noteLengthLabel(c)}']),
        ('depth', 'Depth %', 0, 100, 50, null),
      ],
    _ => [('seventh', 'Chord', 0, 1, 0, ['Triad', 'Seventh'])],
  };
  late final Map<String, double> _v = {
    for (final f in _fields) f.$1: (_GenDialog._last['${widget.id}.${f.$1}'] ?? f.$5).clamp(f.$3, f.$4)
  };

  @override
  Widget build(BuildContext context) {
    final name = switch (widget.id) { 'roll.gen.connect' => 'connect notes', final id => id.replaceFirst('roll.gen.', '') };
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: Text(name[0].toUpperCase() + name.substring(1)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.id == 'roll.gen.tremolo')
          // The preview follows the controls: a two-bar note's volume, or its hits' velocities.
          SizedBox(
            key: const ValueKey('tremolo-preview'),
            height: 56,
            width: double.infinity,
            child: CustomPaint(
              painter: _TremoloPreview(
                wave: TremoloWave.values[_v['wave']!.round()],
                cycle: _tremoloCycles[_v['cycle']!.round()],
                depth: _v['depth']! / 100,
                rate: _v['mode']!.round() == 1 ? widget.rate : null,
              ),
            ),
          ),
        for (final f in _fields)
          if (f.$6 != null)
            Wrap(spacing: 6, children: [
              for (var i = 0; i < f.$6!.length; i++)
                ChoiceChip(
                  label: Text(f.$6![i]),
                  selected: _v[f.$1]!.round() == i,
                  onSelected: (_) {
                    Haptics.tick();
                    setState(() => _v[f.$1] = i.toDouble());
                  },
                ),
            ])
          else
            ValueSlider(
              label: f.$2,
              min: f.$3,
              max: f.$4,
              reset: f.$5,
              divisions: (f.$4 - f.$3).round(),
              value: _v[f.$1]!,
              onChanged: (x) => setState(() => _v[f.$1] = x.roundToDouble()),
            ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            _v.forEach((k, x) => _GenDialog._last['${widget.id}.$k'] = x);
            Navigator.pop(context, _v);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// The Vibrato dialog's settings: [cents] deep, one cycle every [cycle] steps (synced) or [freeHz], [fade] 0..1.
class _Vibrato {
  const _Vibrato({required this.cents, required this.cycle, required this.freeHz, required this.fade});
  final double cents, freeHz, fade;
  final Steps? cycle; // null: the free rate

  /// The rate in Hz, a synced one at [secPerStep] seconds a step (the engine takes 0.1 to 30 Hz).
  double hz(double secPerStep) {
    final c = cycle;
    return (c == null ? freeHz : 1 / (c.toDouble() * secPerStep)).clamp(0.1, 30).toDouble();
  }
}

/// Vibrato: depth in cents, a rate synced to 1/4..1/32 or free in Hz, a fade-in; the preview follows each control.
class _VibratoDialog extends StatefulWidget {
  const _VibratoDialog({required this.secPerStep});
  final double secPerStep;

  static _Vibrato last = _Vibrato(cents: 30, cycle: Steps.one, freeHz: 5.5, fade: 0.3);

  @override
  State<_VibratoDialog> createState() => _VibratoDialogState();
}

class _VibratoDialogState extends State<_VibratoDialog> {
  late double _cents = _VibratoDialog.last.cents, _hz = _VibratoDialog.last.freeHz, _fade = _VibratoDialog.last.fade;
  late Steps? _cycle = _VibratoDialog.last.cycle;

  _Vibrato get _v => _Vibrato(cents: _cents, cycle: _cycle, freeHz: _hz, fade: _fade);

  @override
  Widget build(BuildContext context) {
    final v = _v;
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: const Text('Vibrato'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            key: const ValueKey('vibrato-preview'),
            height: 56,
            child: CustomPaint(
                painter: _VibratoPreview(cents: v.cents, hz: v.hz(widget.secPerStep), fade: v.fade,
                    span: 32 * widget.secPerStep)),
          ),
          const Heading('Rate'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final c in [..._tremoloCycles, null])
              ChoiceChip(
                label: Text(c == null ? 'Free (Hz)' : noteLengthLabel(c)),
                selected: _cycle == c,
                onSelected: (_) {
                  Haptics.tick();
                  setState(() => _cycle = c);
                },
              ),
          ]),
          if (_cycle == null)
            ValueSlider(label: 'Rate', value: _hz, min: 0.5, max: 12, reset: 5.5, decimals: 1, unit: ' Hz',
                sliderKey: const ValueKey('vibrato-hz'), onChanged: (x) => setState(() => _hz = x))
          else
            Text('${v.hz(widget.secPerStep).toStringAsFixed(2)} Hz at this tempo',
                style: TextStyle(color: Neon.dim, fontSize: 12)),
          const Heading('Shape'),
          ValueSlider(label: 'Depth', value: _cents, min: 0, max: 200, reset: 30, unit: ' cents', divisions: 200,
              sliderKey: const ValueKey('vibrato-depth'), onChanged: (x) => setState(() => _cents = x)),
          ValueSlider(label: 'Fade-in', value: _fade, min: 0, max: 1, reset: 0.3, scale: 100, unit: '%',
              sliderKey: const ValueKey('vibrato-fade'), onChanged: (x) => setState(() => _fade = x)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            Haptics.drop();
            _VibratoDialog.last = v;
            Navigator.pop(context, v);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// The vibrato's pitch over two bars of a note: the wave growing in over the fade-in.
class _VibratoPreview extends CustomPainter {
  _VibratoPreview({required this.cents, required this.hz, required this.fade, required this.span});
  final double cents, hz, fade, span; // span: seconds shown

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
        Paint()..color = Neon.bg.withValues(alpha: 0.6));
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Neon.line);
    final e = NoteExpression(vibDepth: cents / 100, vibRate: hz, vibFade: fade);
    final path = Path();
    final n = math.max(128, size.width.round() * 2);
    for (var i = 0; i <= n; i++) {
      final u = i / n;
      // Full scale is 2 semitones (200 cents) each way.
      final y = mid - e.pitchAt(u, u * span) / 2 * (mid - 4);
      i == 0 ? path.moveTo(u * size.width, y) : path.lineTo(u * size.width, y);
    }
    canvas.drawPath(path, Paint()
      ..color = Neon.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_VibratoPreview o) => o.cents != cents || o.hz != hz || o.fade != fade || o.span != span;
}

/// Tremolo speeds: one cycle every 1/4, 1/8, 1/16 or 1/32 note (in steps).
final List<Steps> _tremoloCycles = [Steps(4), Steps(2), Steps.one, Steps(1, 2)];

/// The tremolo generator's preview: the wave's level over two bars of a note, as a line (volume) or as bars (repeats
/// every [rate]).
class _TremoloPreview extends CustomPainter {
  _TremoloPreview({required this.wave, required this.cycle, required this.depth, this.rate});
  final TremoloWave wave;
  final Steps cycle;
  final double depth;
  final Steps? rate;

  static const _span = 32.0; // two bars of 4/4, in steps

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Neon.bg.withValues(alpha: 0.6);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)), bg);
    final c = cycle.toDouble();
    double y(double level) => size.height - 4 - level * (size.height - 8);
    final r = rate;
    if (r != null) {
      final step = r.toDouble();
      final w = size.width * step / _span;
      final bar = Paint()..color = Neon.green;
      for (var t = 0.0; t < _span - 1e-9; t += step) {
        final level = PatternDoc.tremoloLevel(wave, t / c, depth);
        final x = t / _span * size.width;
        canvas.drawRect(Rect.fromLTRB(x + w * 0.15, y(level), x + w * 0.85, size.height - 4), bar);
      }
      return;
    }
    final path = Path();
    final n = math.max(64, size.width.round());
    for (var i = 0; i <= n; i++) {
      final t = i / n * _span;
      final p = Offset(i / n * size.width, y(PatternDoc.tremoloLevel(wave, t / c, depth)));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, Paint()
      ..color = Neon.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_TremoloPreview o) => o.wave != wave || o.cycle != cycle || o.depth != depth || o.rate != rate;
}

/// The quantize sheet's settings.
class _Quantize {
  const _Quantize(this.grid, this.what, this.strength, this.swing, this.timing, this.velocity);
  final Steps grid;
  final QuantizeWhat what;
  final double strength, swing, timing, velocity; // 0..1; timing in steps
}

/// Quantize (REAPER's Quantize events, UG 13.23): the grid (the roll's by default), what moves, strength, swing and
/// humanize, each previewed on the roll as it moves; Bypass shows the notes as they were. The last applied settings
/// (all but the grid) stay for next time.
class _QuantizeSheet extends StatefulWidget {
  const _QuantizeSheet({required this.res, required this.triplet, required this.count, required this.onPreview});
  final int res, count;
  final bool triplet;
  final ValueChanged<_Quantize?> onPreview;

  static ({QuantizeWhat what, double strength, double swing, double timing, double velocity})? _last;

  @override
  State<_QuantizeSheet> createState() => _QuantizeSheetState();
}

class _QuantizeSheetState extends State<_QuantizeSheet> {
  late int _res = widget.res;
  late bool _triplet = widget.triplet;
  QuantizeWhat _what = _QuantizeSheet._last?.what ?? QuantizeWhat.starts;
  double _strength = _QuantizeSheet._last?.strength ?? 100, _swing = _QuantizeSheet._last?.swing ?? 0;
  double _timing = _QuantizeSheet._last?.timing ?? 0, _velocity = _QuantizeSheet._last?.velocity ?? 0;
  bool _bypass = false;

  _Quantize get _q => _Quantize(_triplet ? Steps(32, _res * 3) : Steps(16, _res), _what, _strength / 100, _swing / 100,
      _timing / 100, _velocity / 100);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  void _changed() => widget.onPreview(_bypass ? null : _q);

  void _set(VoidCallback f) {
    setState(f);
    _changed();
  }

  Widget _chips<T>(List<(T, String)> items, T value, ValueChanged<T> on) => Wrap(spacing: 6, runSpacing: 2, children: [
        for (final (v, label) in items)
          ChoiceChip(
            label: Text(label),
            selected: v == value,
            onSelected: (_) {
              Haptics.tick();
              _set(() => on(v));
            },
          ),
      ]);

  Widget _slider(String key, String label, double value, double max, ValueChanged<double> on, {double reset = 0}) =>
      ValueSlider(
        sliderKey: ValueKey('quantize-$key'),
        label: label,
        unit: '%',
        min: 0,
        max: max,
        reset: reset,
        divisions: max.round(),
        value: value,
        onChanged: (x) {
          if (x.roundToDouble() != value) Haptics.tick();
          _set(() => on(x.roundToDouble()));
        },
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: Text('Quantize ${widget.count == 1 ? '1 note' : '${widget.count} notes'}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Grid'),
          const SizedBox(height: 4),
          _chips([for (final r in const [4, 8, 16, 32]) (r, '1/$r')], _res, (v) => _res = v),
          Row(children: [
            Expanded(child: Text('Triplets', style: TextStyle(color: _triplet ? Neon.text : Neon.dim))),
            Switch(value: _triplet, onChanged: (v) => _set(() => _triplet = v)),
          ]),
          const Text('Move'),
          const SizedBox(height: 4),
          _chips([(QuantizeWhat.starts, 'Starts'), (QuantizeWhat.ends, 'Ends'), (QuantizeWhat.both, 'Both')], _what,
              (v) => _what = v),
          const SizedBox(height: 8),
          _slider('strength', 'Strength', _strength, 100, (v) => _strength = v, reset: 100),
          _slider('swing', 'Swing', _swing, 100, (v) => _swing = v),
          _slider('timing', 'Humanize timing ± % of a step', _timing, 50, (v) => _timing = v),
          _slider('velocity', 'Humanize velocity ± %', _velocity, 50, (v) => _velocity = v),
          Row(children: [
            const Expanded(child: Text('Bypass (hear the notes as they were)')),
            Switch(key: const ValueKey('quantize-bypass'), value: _bypass, onChanged: (v) => _set(() => _bypass = v)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        Pressable(
          child: FilledButton(
            onPressed: () {
              Haptics.drop();
              _QuantizeSheet._last = (
                what: _what,
                strength: _strength,
                swing: _swing,
                timing: _timing,
                velocity: _velocity,
              );
              Navigator.pop(context, _q);
            },
            child: const Text('Apply'),
          ),
        ),
      ],
    );
  }
}

/// The song's playhead down the roll's ruler and grid: a line at [step] (the roll's time; null draws nothing).
class RollPlayheadPainter extends CustomPainter {
  const RollPlayheadPainter(
      {required this.step, required this.pxPerStep, required this.scrollX, required this.left, required this.bottom,
      this.stopped = false});
  final double? step;
  final double pxPerStep, scrollX, left, bottom;

  /// Stopped: the edit cursor, where play starts, dimmer and thinner (as Arrange's).
  final bool stopped;

  /// Where the line is, in the roll's pixels; null when there is none or it is off the grid.
  double? get x {
    final st = step;
    if (st == null) return null;
    final x = left + st * pxPerStep - scrollX;
    return x < left ? null : x;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final at = x;
    if (at == null || at > size.width) return;
    canvas.drawLine(Offset(at, 0), Offset(at, bottom),
        Paint()..color = stopped ? Neon.blue.withValues(alpha: 0.45) : Neon.blue..strokeWidth = stopped ? 1.2 : 1.6);
  }

  @override
  bool shouldRepaint(covariant RollPlayheadPainter old) => old.step != step || old.pxPerStep != pxPerStep ||
      old.scrollX != scrollX || old.bottom != bottom || old.stopped != stopped;
}

/// Which end of the song's loop a drag on the roll's ruler moves, or a new range drawn.
enum _RulerEdge { start, end, draw }
