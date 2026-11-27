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
import '../model/tempo_map.dart';
import '../model/settings.dart';
import 'key_router.dart';
import 'page_closer.dart';
import 'pointer_input.dart';
import 'note_expression.dart';
import 'motion.dart';
import 'theme.dart';
import 'widgets.dart';
import 'arrange/edit_cues.dart';
import 'arrange/ruler.dart' show LoopBand, zoomFade;
import 'arrange/track_color.dart';
import 'clip_roll_parts.dart';
import 'glass.dart';
import 'adaptive_sheet.dart';
import 'follow_gate.dart';
import 'haptics.dart';
import 'live_playhead.dart';
import 'feedback.dart';
import 'view_glide.dart';
import 'pattern_editor/roll_dialogs.dart';
import 'pattern_editor/roll_toolbar.dart';

part 'pattern_editor/roll_commands.dart';
part 'pattern_editor/roll_curves.dart';
part 'pattern_editor/roll_gestures.dart';
part 'pattern_editor/roll_painters.dart';
part 'pattern_editor/roll_tools.dart';

// The gesture binding's sampling clock, for double taps: the wall clock in the app, the test's fake clock under test,
// so a busy machine can't split a double tap (as ClickCounter in pointer_input.dart).
DateTime _gestureNow() => GestureBinding.instance.samplingClock.now();

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

const _keyW = 44.0, _rulerH = 20.0;

// A finger held this long on empty grid starts a selection box (the state's selection box fields).
const _boxHold = Duration(milliseconds: 350);

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
        rollMenuHead('Loop'),
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

  /// Where the roll's shade starts (#226, the owner: "it should stay dark for the actual length of the clip"): opened
  /// for a clip, where that clip stops playing in the roll's time (a looping clip's repeats run on past its loop bar,
  /// dimmed by [ClipLoopPainter]; a clip that doesn't loop stops at its end or its loop point); in Build, the loop of
  /// the pattern's first clip in the song (the roll's time wraps there); a pattern in no clip, its own length.
  double _shadeFrom(PatternDoc d, int length) {
    final c = _anchor;
    if (c == null) return length.toDouble();
    final loop = widget.clip != null && widget.layer != null
        ? (_loopSteps(d) ?? length)
        : c.loopLength(d.lengthSteps(s.project.beatsPerBar));
    final opened = widget.clip != null && widget.layer != null;
    if (c.loop) return opened ? (c.sourceOffsetSteps % loop + c.lengthSteps).toDouble() : loop.toDouble();
    return math.min(c.sourceOffsetSteps + c.lengthSteps, loop).toDouble();
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
  /// playhead, wrapped to its loop. [smooth]: between reads too ([AppState.smoothPlayheadStep]), for drawing; else
  /// as drawn on the reads ([AppState.heldPlayheadStep], Smooth follow's scroll and line).
  double? _playStep({bool smooth = false}) {
    final d = _doc;
    if (d == null || !s.meters.playing) return null;
    final ph = smooth ? s.smoothPlayheadStep : s.heldPlayheadStep;
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
  /// Picks a tool (#228: a pick always applies): a gesture the last tool had armed (a pending tap, its ghost, a double
  /// tap waiting on a note) is dropped, so the next touch is the new tool's.
  void _setTool(PatternTool t) {
    _pending = null;
    _tapNote = null;
    _tapCandidate = null;
    _boxTimer?.cancel();
    _ghost = null;
    setState(() => _tool = t);
  }

  /// The grid cell a tap lands in (#228, the owner: "it doesn't always place notes where you tap them"): the cell
  /// between the grid lines drawn at this zoom, so a note starts at the line left of the finger, never a coarser one.
  Steps get _cellLevel => _lineLevel;

  // Finger-sized taps on a phone: the device's screen decides, not the panel's size (a docked panel is smaller). The
  // length a tapped note gets (until a stretch sets another), not where it starts.
  Steps get _tapLevel {
    final view = View.of(context);
    final screen = view.physicalSize / view.devicePixelRatio;
    return _levelFor(screen.shortestSide < 600 ? 48 : 24);
  }

  void _apply(PatternDoc next, {Set<int>? select}) {
    final d = _doc;
    if (d == null) return;
    if (identical(next, d)) {
      // Nothing changed (a note drawn onto one already there, #228): it still becomes the selection.
      if (select != null && !setEquals(select, _sel)) setState(() => _sel = select);
      return;
    }
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

  PatternClip? _clip;
  Steps? _pasteAt; // where the next paste goes: after the copied notes, then after the last paste

  // The pitch edit under way: the note, what was grabbed and how.
  int? _bNote, _bPoint, _bSeg;
  _CurveHit? _bHit;
  double _bK0 = 0;
  Offset? _bStart, _bAt, _bSmooth;
  bool _bMoved = false, _bFrame = false, _bHandle = false;
  ({int id, int point, DateTime at})? _bTapped; // the last point tapped: a second tap soon after removes it

  // ---------- step input (REAPER flow gap 8; REAPER's step recording, UG 13.26) ----------
  // While on, each note played on the roll's keys or a MIDI keyboard goes in at the cursor, one grid long, and the
  // cursor moves on a grid step; keys pressed while others are held join their chord. Rest skips a step.

  bool _step = false;
  StreamSubscription<Object?>? _stepMidi;
  Steps _stepChordAt = Steps.zero;
  final Set<int> _stepHeld = {}; // pitches down now (keys and keyboard)
  final Map<int, ({int pitch, int? preview})> _stepKeys = {}; // roll-key pointers held

  // ---------- hearing notes (owner, 2026-11-05) ----------
  // A note sounds while you place, move, hold or bend it; a tapped-in note plays its own length. A selection sounds
  // its opening chord (the notes that start first). Each sounding note: its preview id and the pitch it plays.
  final Map<int, ({int id, double pitch})> _heard = {};
  Timer? _tapOff;
  int? _drawnNote; // the note this gesture drew: a tap plays it for its length
  final _drawnAt = Stopwatch()..start(); // since that note was drawn: only a quick tap plays out its length

  /// The mouse pointer panning the roll (middle-drag or Space+drag), if any; whether the press is a mouse's.
  int? _mousePan;
  bool _mouse = false;

  /// The mouse cursor for what the mouse is over: resize on a note's ends, move on its body, else the tool's own.
  MouseCursor _hoverCursor = MouseCursor.defer;

  Offset? _brushAt; // where the drag began; null when no brush drag is under way
  Offset _brushNow = Offset.zero;
  PatternDoc? _brushBase;
  Set<int> _brushIds = {};
  int _brush0 = 1, _brushCount = 1;

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

  double _rampDepth = 0.7; // the ratchet ramp's depth, kept while the roll is open

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
    final toolbar = RollToolbar(
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
                builder: (_) => RollToolbarEditor(router: router),
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
            final shade = _shadeFrom(d, length);
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
                        length: shade,
                        beatsPerBar: s.project.beatsPerBar,
                        bars: s.project.bars,
                        origin: widget.clip == null ? 0 : widget.clip!.startSteps - widget.clip!.sourceOffsetSteps,
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

/// One undo step: the doc before an edit, or, with [sel], the selection before a selection box changed it.
class _Undo {
  const _Undo(this.doc, {this.sel});
  final PatternDoc doc;
  final Set<int>? sel;
}

/// Which end of the song's loop a drag on the roll's ruler moves, or a new range drawn.
enum _RulerEdge { start, end, draw }
