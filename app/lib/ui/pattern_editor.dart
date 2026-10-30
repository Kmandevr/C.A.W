// The pattern editor: a piano roll and a drum grid over the same notes, with an adaptive grid, velocity lane and keys.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../actions/actions.dart';
import '../actions/keymap.dart';
import '../actions/macro.dart';
import '../engine/engine.dart';

import '../model/app_state.dart';
import '../model/lane_curve.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import '../model/settings.dart';
import 'key_router.dart';
import 'note_expression.dart';
import 'theme.dart';

enum PatternTool { draw, select, curve, erase }

/// Grid resolutions as fractions of a whole note (1 = a bar of 4/4), from 1 down to 1/128.
const _resolutions = [1, 2, 4, 8, 16, 32, 64, 128];

class PatternEditor extends StatefulWidget {
  const PatternEditor(
      {super.key, required this.state, required this.module, this.fullScreen = false, this.router});
  final AppState state;
  final ModuleDoc module;
  final bool fullScreen;

  /// The key router, for a full-screen roll whose route sits outside it.
  final KeyRouterState? router;

  @override
  State<PatternEditor> createState() => _PatternEditorState();
}

class _PatternEditorState extends State<PatternEditor> {
  final FocusNode _focus = FocusNode(debugLabel: 'pattern editor');
  PatternDoc? _doc;
  String? _error;
  String _lastText = '';
  final List<PatternDoc> _undo = [], _redo = [];
  Set<int> _sel = {};
  PatternTool _tool = PatternTool.draw;
  bool _grid = false; // drum grid instead of the roll
  int _res = 16; // grid resolution: 1/16 of a whole note = one step
  bool _snap = true, _fixed = false, _triplet = false;
  bool _velLane = true, _extrasLane = false; // Alt+V, Alt+X
  double _pxPerStep = 28, _scrollX = 0, _scrollY = 0;
  Steps _cursorAt = Steps.zero;
  double _cursorPitch = 60;
  Steps? _lastLen;
  Timer? _sendTimer;
  // Drag state.
  int? _dragNote;
  bool _resizing = false;
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
  // The Curve tool: one curve per lane (1 velocity, 2 chance), kept while the roll is open.
  // Replaced (never changed in place) on each edit, so the painter sees a new map only when a curve changed.
  Map<int, LaneCurve> _curves = const {1: LaneCurve(), 2: LaneCurve()};
  LaneCurve? _cBase; // the lane's curve when the gesture began, put back if it is cancelled
  int _cLane = 0; // the lane a curve gesture is in, 0 when none
  int? _cPoint, _cSeg; // the point being dragged, or the segment being bent
  double _cBend0 = 0;
  Offset? _cStart;
  bool _cAddOnTap = false; // a touch inside a segment: a tap adds a point there, a drag bends it
  // The Curve tool on a selected note: editing its pitch curve (bend points) right on the roll.
  int? _bNote, _bPoint, _bSeg;
  double _bK0 = 0;
  Offset? _bStart;
  bool _bAddOnTap = false;
  double _gridH = 0;
  Timer? _hold; // long press on a note opens its extras panel
  Offset? _holdAt;
  // A plain tap on a note arms a double tap: a second tap on it soon after deletes it.
  int? _tapCandidate, _tapNote;
  DateTime? _tapAt;

  static const _keyW = 44.0, _rulerH = 20.0;
  RollLook get _look => s.settings.roll;
  double get _rowH => _look.rowHeight;
  double get _velH => _look.velocityLane;
  double get _xH => _look.chanceLane;
  double get _lanesH => (_velLane ? _velH : 0) + (_extrasLane ? _xH : 0);

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.settings.addListener(_settingsChanged);
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
    if (old.module.id != widget.module.id || widget.module.source != _lastText) _load();
  }

  @override
  void dispose() {
    _hold?.cancel();
    s.settings.removeListener(_settingsChanged);
    _router?.unregister(Area.pattern, _focus);
    _flush();
    _focus.dispose();
    super.dispose();
  }

  void _load() {
    final src = widget.module.source;
    final r = PatternDoc.parse(src.trim().isEmpty ? '---\nkind: pattern\n---\n' : src);
    _lastText = src;
    if (r.ok) {
      _doc = r.doc;
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

  // ---------- edits ----------

  Steps get _resSteps => _triplet ? Steps(32, _res * 3) : Steps(16, _res);

  /// The finest grid level shown at this zoom: lines at least 10 px apart, never finer than the resolution.
  Steps _levelFor(double minPx) {
    var steps = _triplet ? Steps(128, 3) : Steps(16 * 4, 1); // start at 4 bars' worth (or its triplet) and halve
    final finest = _snap ? _resSteps : Steps(1, 128);
    while (true) {
      final half = Steps(steps.numerator, steps.denominator * 2);
      if (half < finest || half.toDouble() * _pxPerStep < minPx) break;
      steps = half;
    }
    return _fixed ? finest : (steps < finest ? finest : steps);
  }

  Steps get _lineLevel => _levelFor(10);
  Steps get _tapLevel => _levelFor(MediaQuery.of(context).size.shortestSide < 600 ? 48 : 24);

  void _apply(PatternDoc next, {Set<int>? select}) {
    final d = _doc;
    if (d == null || identical(next, d)) return;
    _undo.add(d);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
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

  void _flush() {
    _sendTimer?.cancel();
    _sendTimer = null;
    final d = _doc;
    if (d == null) return;
    final text = d.serialize();
    if (text == widget.module.source) return;
    _lastText = text;
    s.editSource(widget.module.id, text);
    s.run(widget.module.id);
  }

  void _undoRedo(bool undo) {
    final from = undo ? _undo : _redo, to = undo ? _redo : _undo;
    if (from.isEmpty || _doc == null) return;
    to.add(_doc!);
    setState(() => _doc = from.removeLast());
    _scheduleSend();
  }

  Steps _snapTime(double steps, Steps level) {
    final t = Steps.fromDouble(math.max(0, steps), maxDenominator: 384);
    return _snap ? t.floorTo(level) : t;
  }

  // ---------- keys ----------

  /// The roll's actions (docs/actions.md), run by keys, toolbars and macros through the key router.
  bool _action(String id, int count, String? arg) {
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
        final r = d.insert(_cursorAt, _cursorPitch, _lastLen ?? _resSteps);
        if (r.id != null) _apply(r.doc, select: {r.id!});
      case 'roll.select.copyafter':
        var x = d;
        var sel = _sel;
        for (var i = 0; i < count && sel.isNotEmpty; i++) {
          final r = x.copyAfter(sel);
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
        _clip = d.copy(_sel);
        _apply(d.delete(_sel), select: {});
      case 'roll.select.all':
        setState(() => _sel = {for (final n in d.notes) n.id});
      case 'roll.select.none':
        setState(() => _sel = {});
      case 'roll.select.addAtCursor':
        setState(() => _sel = {..._sel, ...d.notesIn(_cursorAt, _cursorAt, _cursorPitch, _cursorPitch)});
      case 'roll.edit.copy':
        if (_sel.isNotEmpty) setState(() => _clip = d.copy(_sel));
      case 'roll.edit.paste':
        final c = _clip;
        if (c == null) return true;
        final r = d.paste(c, _cursorAt);
        _apply(r.doc, select: r.ids);
      case 'roll.edit.duplicate':
        final r = d.copyAfter(_sel);
        _apply(r.doc, select: r.ids);
      case 'roll.notes.split':
        final r = d.split(_sel, _cursorAt);
        _apply(r.doc, select: r.ids);
      case 'roll.notes.join':
        final r = d.join(_sel);
        _apply(r.doc, select: r.ids);
      case 'roll.notes.quantize':
        _apply(d.quantize(_sel.isEmpty ? {for (final n in d.notes) n.id} : _sel, _resSteps));
      case 'roll.gen.euclid' ||
            'roll.gen.random' ||
            'roll.gen.arpeggiate' ||
            'roll.gen.humanize' ||
            'roll.gen.chordStamp':
        _generate(id);
      case 'roll.gen.reverse':
        _apply(d.reverse(_sel));
      case 'roll.gen.invertPitch':
        _apply(d.invertPitch(_sel, _cursorPitch));
      case 'roll.gen.legato':
        _apply(d.legato(_sel));
      case 'roll.vel.up':
        _apply(d.addVelocity(_sel, 0.1 * count));
      case 'roll.vel.down':
        _apply(d.addVelocity(_sel, -0.1 * count));
      case 'roll.vel.upFine':
        _apply(d.addVelocity(_sel, 0.01 * count));
      case 'roll.vel.downFine':
        _apply(d.addVelocity(_sel, -0.01 * count));
      case 'roll.vel.set':
        final v = double.tryParse(arg ?? '');
        if (v == null) return true;
        _apply(d.setVelocity(_sel, v > 1 ? v / 100 : v));
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
      case 'roll.view.switch':
        setState(() => _grid = !_grid);
      case 'roll.view.zoomIn':
        setState(() => _pxPerStep = math.min(200, _pxPerStep * 1.25));
      case 'roll.view.zoomOut':
        setState(() => _pxPerStep = math.max(4, _pxPerStep / 1.25));
      case 'roll.view.fit':
        setState(() {
          _scrollX = 0;
          _pxPerStep = math.max(4, (context.size?.width ?? 400) - _keyW) / math.max(1, d.lengthSteps(s.project.beatsPerBar));
        });
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
        final r = d.insert(_cursorAt, _cursorPitch, _lastLen ?? g);
        if (r.id != null) _apply(r.doc, select: {r.id!});
      case LogicalKeyboardKey.keyE:
        if (_sel.isNotEmpty) {
          final r = d.copyAfter(_sel);
          _apply(r.doc, select: r.ids);
        }
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        _apply(d.delete(_sel), select: {});
      case LogicalKeyboardKey.escape:
        setState(() => _sel = {});
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
    setState(() {
      if (hit == null) {
        _sel = {};
      } else {
        _sel = _sel.contains(hit) ? (Set.of(_sel)..remove(hit)) : {..._sel, hit};
      }
    });
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
    final (added, i) = c.add(_stepAt(p.dx), _laneValue(lane, p.dy));
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
      _setCurve(lane, _curves[lane]!.move(i, _stepAt(p.dx), _laneValue(lane, p.dy)));
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
      final (added, _) = _curves[_cLane]!.add(_stepAt(start.dx), _laneValue(_cLane, start.dy));
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

  static const _bendRange = 12.0; // the owner's default: +-12 semitones on screen (the file allows +-48)

  double _noteX(PatternNote n) => n.at.toDouble() * _pxPerStep - _scrollX;
  double _noteW(PatternNote n) => math.max(3.0, n.len.toDouble() * _pxPerStep - 1);
  double _noteMid(PatternNote n) => (127 - n.pitch.round()) * _rowH - _scrollY + _rowH / 2;
  Offset _bendPx(PatternNote n, NotePoint q) => Offset(_noteX(n) + q.t * _noteW(n), _noteMid(n) - q.v * _rowH);

  /// The selected note whose row or bent line is under [p] (a tap on an unselected note selects it instead).
  int? _bendNoteAt(Offset p) {
    final d = _doc;
    if (d == null) return null;
    final secPerStep = 15 / s.project.bpm;
    for (final id in _sel) {
      final n = d.byId(id);
      if (n == null) continue;
      final x0 = _noteX(n), w = _noteW(n);
      if (p.dx < x0 - 12 || p.dx > x0 + w + 12) continue;
      final u = ((p.dx - x0) / w).clamp(0.0, 1.0);
      final lineY = _noteMid(n) - n.expr.pitchAt(u, u * n.len.toDouble() * secPerStep) * _rowH;
      if ((p.dy - lineY).abs() < math.max(_rowH, 16) || (p.dy - _noteMid(n)).abs() < _rowH / 2) return id;
    }
    return null;
  }

  double _bendValue(double y, PatternNote n) {
    var v = (_noteMid(n) - y) / _rowH;
    if (_snap && !HardwareKeyboard.instance.isShiftPressed) v = v.roundToDouble();
    return v.clamp(-_bendRange, _bendRange).toDouble();
  }

  void _setBend(int id, List<NotePoint> pts) {
    final d = _doc!, n = d.byId(id)!;
    setState(() => _doc = d.setExpression({id}, n.expr.copyWith(bend: List.unmodifiable(pts))));
  }

  void _bendDown(Offset p, int id) {
    final d = _doc!, n = d.byId(id)!;
    _dragBase = d;
    _bNote = id;
    _bStart = p;
    final pts = n.expr.bend;
    for (var i = 0; i < pts.length; i++) {
      if ((_bendPx(n, pts[i]) - p).distance < math.max(16, _look.grab)) {
        _bPoint = i;
        _holdAt = p;
        _hold = Timer(Duration(milliseconds: _look.holdMs), () {
          final now = _doc!.byId(id)!.expr.bend;
          if (i < now.length) _setBend(id, [...now]..removeAt(i));
          _bPoint = null;
        });
        return;
      }
    }
    final u = ((p.dx - _noteX(n)) / _noteW(n)).clamp(0.0, 1.0);
    for (var i = 0; i + 1 < pts.length; i++) {
      if (u > pts[i].t && u < pts[i + 1].t) {
        _bSeg = i;
        _bK0 = pts[i].k;
        _bAddOnTap = true;
        return;
      }
    }
    // No points yet: the curve starts at the note's own pitch, then the touched point. Outside the points: a new one.
    final q = NotePoint(u, _bendValue(p.dy, n));
    final next = pts.isEmpty && u > 0.02 ? [const NotePoint(0, 0), q] : _insertPoint(pts, q);
    _bPoint = next.indexOf(q);
    _setBend(id, next);
  }

  List<NotePoint> _insertPoint(List<NotePoint> pts, NotePoint q) {
    final out = [...pts];
    final i = out.indexWhere((x) => x.t > q.t);
    out.insert(i < 0 ? out.length : i, q);
    return out.take(NoteExpression.maxPoints).toList();
  }

  void _bendMove(Offset p) {
    final id = _bNote, start = _bStart, d = _doc;
    if (id == null || start == null || d == null) return;
    final n = d.byId(id);
    if (n == null) return;
    if (_hold != null && (p - _holdAt!).distance > 8) {
      _hold!.cancel();
      _hold = null;
    }
    final pts = [...n.expr.bend];
    final i = _bPoint, seg = _bSeg;
    if (i != null && i < pts.length) {
      final lo = i > 0 ? pts[i - 1].t : 0.0, hi = i + 1 < pts.length ? pts[i + 1].t : 1.0;
      final u = ((p.dx - _noteX(n)) / _noteW(n)).clamp(lo, hi);
      pts[i] = NotePoint(u, _bendValue(p.dy, n), pts[i].k);
      _setBend(id, pts);
    } else if (seg != null && seg < pts.length) {
      if (_bAddOnTap && (p - start).distance <= kTouchSlop) return;
      _bAddOnTap = false;
      // Dragging the line up bends it to rise late (eases in), down to rise early, as on the lanes.
      final k = (_bK0 - (p.dy - start.dy) / 120).clamp(-1.0, 1.0);
      pts[seg] = NotePoint(pts[seg].t, pts[seg].v, (k * 100).roundToDouble() / 100);
      _setBend(id, pts);
    }
  }

  void _bendEnd({required bool cancel}) {
    final id = _bNote, start = _bStart;
    if (id == null) return;
    _hold?.cancel();
    _hold = null;
    if (!cancel && _bAddOnTap && start != null && _doc != null) {
      final n = _doc!.byId(id)!;
      final u = ((start.dx - _noteX(n)) / _noteW(n)).clamp(0.0, 1.0);
      _setBend(id, _insertPoint(n.expr.bend, NotePoint(u, _bendValue(start.dy, n))));
    }
    _bNote = _bPoint = _bSeg = null;
    _bStart = null;
    _bAddOnTap = false;
    cancel ? _cancelEdit() : _up();
  }

  // ---------- generators ----------

  /// Asks for a generator's settings, then applies it as one undo step. Euclid and Random write from the cursor at the
  /// grid size; the others work on the selection.
  Future<void> _generate(String id) async {
    final d = _doc;
    if (d == null) return;
    final bar = Steps(s.project.beatsPerBar * 4);
    final seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    final v = await showDialog<Map<String, double>>(
      context: context,
      builder: (_) => _GenDialog(id: id),
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
    }
  }

  // ---------- pointer ----------

  static const _origin = Offset(_keyW, _rulerH);

  /// One finger on a note, in a lane or with the select tool edits; on empty grid it waits: a tap draws (or erases),
  /// a drag scrolls. Two fingers zoom and scroll, and drop an edit the first finger had started.
  void _pointerDown(PointerDownEvent e) {
    _focus.requestFocus();
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      final p = e.localPosition - _origin;
      if (_tool == PatternTool.curve) {
        // Curve tool: the lanes edit their curve; on the grid a tap picks notes and a drag scrolls.
        final bendOn = p.dy < _gridH ? _bendNoteAt(p) : null;
        if (p.dy >= _gridH) {
          _curveDown(p);
        } else if (bendOn != null) {
          _bendDown(p, bendOn);
        } else {
          _pending = p;
          _panning = false;
        }
      } else if (p.dy >= _gridH || _noteAt(p) != null || _tool == PatternTool.select) {
        _down(p);
      } else {
        _pending = p;
        _panning = false;
      }
    } else if (_pointers.length == 2) {
      _cancelEdit();
      _curveEnd(cancel: true);
      _bendEnd(cancel: true);
      _pending = null;
      final ps = _pointers.values.toList();
      _pinchSpan = (ps[0].dx - ps[1].dx).abs();
      _pinchFocal = (ps[0] + ps[1]) / 2;
      _zoomStart = _pxPerStep;
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2) {
      final ps = _pointers.values.take(2).toList();
      final focal = (ps[0] + ps[1]) / 2, span = (ps[0].dx - ps[1].dx).abs();
      setState(() {
        // A pinch that starts with the fingers stacked vertically only scrolls.
        if (_pinchSpan > 24) _pxPerStep = (_zoomStart * span / _pinchSpan).clamp(4.0, 200.0);
        _scrollX -= focal.dx - _pinchFocal.dx;
        _scrollY -= focal.dy - _pinchFocal.dy;
      });
      _pinchFocal = focal;
      return;
    }
    final p = e.localPosition - _origin, pending = _pending;
    if (pending != null) {
      if (!_panning && (p - pending).distance > kTouchSlop) {
        // A drag from empty grid does what the settings say: scroll, select, or the tool's own drag.
        if (_look.emptyDrag != EmptyDrag.scroll && _tool != PatternTool.curve) {
          _pending = null;
          _down(pending, rect: _look.emptyDrag == EmptyDrag.select);
          _move(p);
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
    if (_bNote != null) return _bendMove(p);
    if (_cLane != 0) return _curveMove(p);
    _move(p);
  }

  void _pointerUp(PointerEvent e, {required bool cancel}) {
    if (_pointers.remove(e.pointer) == null) return;
    if (_pointers.length == 1) {
      // Back to one finger after a pinch: it keeps scrolling until it lifts.
      _pending = _pointers.values.first - _origin;
      _panning = true;
      return;
    }
    if (_pointers.isNotEmpty) return;
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
    if (_bNote != null) return _bendEnd(cancel: cancel);
    if (_cLane != 0) return _curveEnd(cancel: cancel);
    cancel ? _cancelEdit() : _up();
  }

  /// Drops a one-finger edit in progress, restoring the notes as they were before it.
  void _cancelEdit() {
    _hold?.cancel();
    _hold = null;
    final base = _dragBase;
    if (base == null) return;
    setState(() {
      _doc = base;
      _dragStart = null;
      _dragBase = null;
      _dragNote = null;
      _rectEnd = null;
    });
  }

  double _stepAt(double x) => (x + _scrollX) / _pxPerStep;
  double _pitchAt(double y) => 127 - ((y + _scrollY) / _rowH).floorToDouble();

  int? _noteAt(Offset p) {
    final d = _doc;
    if (d == null) return null;
    final t = _stepAt(p.dx), pitch = _pitchAt(p.dy);
    for (final n in d.notes.reversed) {
      if (n.pitch.round() == pitch && t >= n.at.toDouble() && t < n.end.toDouble()) return n.id;
    }
    // A short note is easier to grab: a touch beside it, within the grab zone, counts as on it, but only inside the
    // tap cell the note starts in, so a tap in the next cell still draws there.
    final cell = _tapLevel.toDouble(), touchCell = (t / cell).floor();
    for (final n in d.notes.reversed) {
      if (n.pitch.round() != pitch || (n.at.toDouble() / cell).floor() != touchCell) continue;
      final w = n.len.toDouble() * _pxPerStep, pad = math.max(0.0, _look.grab * 2 - w) / 2 / _pxPerStep;
      if (t >= n.at.toDouble() - pad && t < n.end.toDouble() + pad) return n.id;
    }
    return null;
  }

  void _down(Offset p, {bool rect = false}) {
    _focus.requestFocus();
    final d = _doc;
    if (d == null) return;
    _dragStart = p;
    _dragBase = d;
    _dragMovedT = Steps.zero;
    _dragMovedP = 0;
    _lane = 0;
    _rectSelect = rect || _tool == PatternTool.select;
    if (p.dy >= _gridH) {
      _lane = _velLane && p.dy < _gridH + _velH ? 1 : 2;
      _laneEdit(p);
      return;
    }
    final hit = _noteAt(p);
    _cursorPitch = _pitchAt(p.dy).clamp(0, 127);
    _cursorAt = _snapTime(_stepAt(p.dx), _tapLevel);
    _tapCandidate = null;
    final tapAt = _tapAt;
    if (hit != null && hit == _tapNote && tapAt != null &&
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
      final n = d.byId(hit)!;
      _dragNote = hit;
      _tapCandidate = hit;
      // Keep an existing multi-selection intact when dragging any member. Only a single note can resize;
      // a group drag always moves the complete selection without changing note lengths.
      final dragSelection = _sel.contains(hit) ? _sel : <int>{hit};
      if (!_sel.contains(hit)) setState(() => _sel = dragSelection);
      _resizing = dragSelection.length == 1 && (n.end.toDouble() - _stepAt(p.dx)) * _pxPerStep < _look.grab;
      _holdAt = p;
      _hold = Timer(Duration(milliseconds: _look.holdMs), () {
        _up();
        _openExtras();
      });
      return;
    }
    _dragNote = null;
    if (_tool == PatternTool.draw && !_rectSelect) {
      final r = d.insert(_cursorAt, _cursorPitch, _lastLen ?? _tapLevel);
      if (r.id != null) {
        _apply(r.doc, select: {r.id!});
        _dragNote = r.id;
        _resizing = true;
        _dragBase = r.doc;
      }
    } else {
      setState(() {
        _sel = {};
        _rectEnd = p;
      });
    }
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
        setState(() {
          _rectEnd = p;
          final a = _stepAt(math.min(start.dx, p.dx)), b = _stepAt(math.max(start.dx, p.dx));
          _sel = base.notesIn(Steps.fromDouble(a, maxDenominator: 384), Steps.fromDouble(b, maxDenominator: 384),
              math.min(_pitchAt(start.dy), _pitchAt(p.dy)), math.max(_pitchAt(start.dy), _pitchAt(p.dy)));
        });
      }
      return;
    }
    // Moves and resizes snap to the resolution; holding Shift frees a length from the grid.
    final free = HardwareKeyboard.instance.isShiftPressed || !_snap;
    final dSteps = (p.dx - start.dx) / _pxPerStep;
    final dt = free ? Steps.fromDouble(dSteps, maxDenominator: 384) : _resSteps.times((dSteps / _resSteps.toDouble()).round());
    if (_resizing) {
      final n = base.byId(_dragNote!);
      if (n == null) return;
      final len = Steps.max(free ? Steps(1, 32) : _resSteps, n.len + dt);
      _lastLen = len;
      setState(() => _doc = base.setNoteLength(_sel.isEmpty ? {_dragNote!} : _sel, len));
    } else {
      final dp = -((p.dy - start.dy) / _rowH).roundToDouble();
      if (dt == _dragMovedT && dp == _dragMovedP) return;
      _dragMovedT = dt;
      _dragMovedP = dp;
      setState(() => _doc = base.move(_sel, dt, dp));
    }
  }

  void _up() {
    _hold?.cancel();
    _hold = null;
    // A tap on an existing note that moved nothing arms the double tap; a note just drawn doesn't.
    _tapNote = _tapCandidate != null && identical(_dragBase, _doc) ? _tapCandidate : null;
    _tapAt = DateTime.now();
    _tapCandidate = null;
    if (_dragBase != null && _doc != null && !identical(_dragBase, _doc)) {
      // One undo step for the whole drag.
      _undo.add(_dragBase!);
      _redo.clear();
      _scheduleSend();
    }
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
    final v = (1 - (p.dy - top - 3) / (hgt - 6)).clamp(0.0, 1.0);
    final x = p.dx + _scrollX;
    var hit = {
      for (final n in d.notes)
        if ((n.at.toDouble() * _pxPerStep - x).abs() < 8) n.id
    };
    if (hit.any(_sel.contains)) hit = hit.where(_sel.contains).toSet();
    if (hit.isEmpty) return;
    setState(() => _doc = _lane == 1 ? d.setVelocity(hit, v) : d.setProb(hit, (v * 20).round() / 20));
  }

  /// The extras panel for the selected notes: velocity, chance, ratchet, slide. One undo step for the whole visit.
  Future<void> _openExtras() async {
    final base = _doc;
    if (base == null || _sel.isEmpty) return;
    final sel = Set<int>.of(_sel);
    await showModalBottomSheet<void>(
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
            Text('Velocity ${(n.vel * 100).round()}%'),
            Slider(value: n.vel, onChanged: (v) => change((d) => d.setVelocity(sel, v))),
            Text('Chance ${(n.prob * 100).round()}%'),
            Slider(value: n.prob, divisions: 20, onChanged: (v) => change((d) => d.setProb(sel, v))),
            const Text('Ratchet'),
            Wrap(spacing: 6, children: [
              for (var r = 1; r <= 8; r++)
                ChoiceChip(
                  label: Text('$r'),
                  selected: n.ratchet == r,
                  onSelected: (_) => change((d) => d.setRatchet(sel, r)),
                ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Slide'),
              value: n.slide,
              onChanged: (v) => change((d) => d.setSlide(sel, v)),
            ),
            // The note's own pitch curve, vibrato, volume and timbre (MPE style); one undo step with the rest.
            ExpressionPanel(
              expr: n.expr,
              color: _noteColor,
              // A shared expression edit has no single note duration to snap against.
              timeSnap: _snap && sel.length == 1 ? _resSteps.toDouble() / n.len.toDouble() : 0,
              onChanged: (e) => change((d) => d.setExpression(sel, e)),
            ),
          ]),
          ),
        );
      }),
    );
    if (!mounted || identical(base, _doc)) return;
    _undo.add(base);
    _redo.clear();
    setState(() {});
    _scheduleSend();
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Replaces the notes with a MIDI file's (one undo step); the file's tempo isn't applied.
  Future<void> _importMidi() async {
    try {
      final f = await FilePicker.pickFile();
      if (f == null) return;
      final text = Engine.patternFromMidi(await f.xFile.readAsBytes());
      final r = PatternDoc.parse(text);
      if (!r.ok) throw FormatException(r.error ?? 'unreadable pattern');
      _apply(r.doc!, select: {});
      _say('Imported ${r.doc!.notes.length} notes');
    } catch (e) {
      _say(e is FormatException ? 'Not a MIDI file: ${e.message}' : 'Could not import: $e');
    }
  }

  Future<void> _exportMidi({required bool clip}) async {
    _flush();
    final d = _doc;
    if (d == null) return;
    final name = '${widget.module.name}.${clip ? 'midi2' : 'mid'}';
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}${Platform.pathSeparator}caw-export-${DateTime.now().microsecondsSinceEpoch}';
      final err = Engine.exportPattern(d.serialize(), path,
          bpm: s.project.bpm.toDouble(), beatsPerBar: s.project.beatsPerBar, clip: clip);
      if (err != null) throw Exception(err);
      final file = File(path);
      final saved = await FilePicker.saveFile(fileName: name, bytes: await file.readAsBytes(), mimeType: 'audio/midi');
      await file.delete();
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
      if (l.patternId == widget.module.id) return Neon.layer(l.color);
    }
    return Neon.yellow;
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
    final length = d.lengthSteps(s.project.beatsPerBar);
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
        'roll.grid.snap' => _snap,
        'roll.grid.triplets' => _triplet,
        'roll.grid.adaptive' => _fixed,
        'roll.view.switch' => _grid,
        'roll.view.velocityLane' => _velLane,
        'roll.view.extrasLanes' => _extrasLane,
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
      res: _res,
      onRes: (r) => setState(() => _res = r),
      canCustomise: router != null,
      onMenu: (v) {
        if (v.startsWith('run:')) return _runRef(ActionRef.action(v.substring(4)));
        switch (v) {
          case 'toolbar':
            if (router != null) {
              showModalBottomSheet<void>(
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
          case 'note':
            _openExtras();
        }
      },
      velLane: _velLane,
      extrasLane: _extrasLane,
      fullScreen: widget.fullScreen,
      onFullScreen: () {
        _flush();
        if (widget.fullScreen) {
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                  body: SafeArea(child: PatternEditor(state: s, module: widget.module, fullScreen: true, router: _router)))));
        }
      },
    );
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(children: [
        toolbar,
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth - _keyW, h = box.maxHeight - _lanesH - _rulerH;
            _gridH = h;
            _scrollX = _scrollX.clamp(0, math.max(0.0, length * _pxPerStep + 200 - w));
            _scrollY = _scrollY.clamp(0, math.max(0.0, 128 * _rowH - h));
            final grid = _grid ? _gridRows(d) : null;
            // The roll claims every touch on it, so a scrolling page around it (the Builder on a phone) never takes
            // its drags; the pointers are then read raw below.
            return RawGestureDetector(
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
                    setState(() {
                      if (HardwareKeyboard.instance.isControlPressed) {
                        _pxPerStep = (_pxPerStep * (e.scrollDelta.dy > 0 ? 0.9 : 1.1)).clamp(4.0, 200.0);
                      } else if (HardwareKeyboard.instance.isShiftPressed) {
                        _scrollX += e.scrollDelta.dy;
                      } else {
                        _scrollY += e.scrollDelta.dy;
                        _scrollX += e.scrollDelta.dx;
                      }
                    });
                  }
                },
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _RollPainter(
                      doc: d,
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
                      editBend: _tool == PatternTool.curve && _sel.length == 1 ? _sel.first : null,
                      keyLabels: _look.keyLabels,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ]),
    );
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
  'roll.gen.reverse': Icons.swap_horiz,
  'roll.gen.invertPitch': Icons.swap_vert,
  'transport.playstop': Icons.play_arrow,
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
    required this.res,
    required this.onRes,
    required this.fullScreen,
    required this.onFullScreen,
    required this.onMenu,
    required this.velLane,
    required this.extrasLane,
    required this.canCustomise,
  });
  final List<ActionRef> items;
  final ActionRegistry registry;
  final Keymap? keymap;
  final bool Function(String id) isOn, isEnabled;
  final int selectedCount;
  final bool canPaste;
  final VoidCallback onCopy, onPaste;
  final ValueChanged<ActionRef> onRun;
  final bool fullScreen, velLane, extrasLane, canCustomise;
  final VoidCallback onFullScreen;
  final ValueChanged<String> onMenu;
  final int res;
  final ValueChanged<int> onRes;

  String _tip(ActionRef r) {
    final name = r.isMacro ? 'Macro: ${r.id}' : (registry[r.id]?.name ?? r.id);
    final keys = keymap?.keysFor(Area.pattern, r).map((k) => k.format()).join(', ') ?? '';
    return keys.isEmpty ? name : '$name ($keys)';
  }

  Widget _item(ActionRef r) {
    if (!r.isMacro && r.id == 'roll.grid.menu') {
      return Center(
        child: DropdownButton<int>(
          value: res,
          underline: const SizedBox(),
          items: [for (final x in _resolutions) DropdownMenuItem(value: x, child: Text(x == 1 ? '1' : '1/$x'))],
          onChanged: (v) => onRes(v!),
        ),
      );
    }
    final icon = r.isMacro ? null : _actionIcons[r.id];
    final enabled = r.isMacro || isEnabled(r.id);
    if (icon != null) {
      return IconButton(
        tooltip: _tip(r),
        onPressed: enabled ? () => onRun(r) : null,
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
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, children: [
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
          tooltip: 'Full screen',
          onPressed: onFullScreen,
          icon: Icon(fullScreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Neon.dim),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: Neon.dim),
          onSelected: onMenu,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'note', child: Text('Note extras… (I, or hold a note)')),
            CheckedPopupMenuItem(value: 'vel', checked: velLane, child: const Text('Velocity lane (Alt+V)')),
            CheckedPopupMenuItem(value: 'extras', checked: extrasLane, child: const Text('Chance lane (Alt+X)')),
            const PopupMenuDivider(),
            for (final id in const [
              'roll.gen.euclid',
              'roll.gen.random',
              'roll.gen.arpeggiate',
              'roll.gen.humanize',
              'roll.gen.chordStamp',
              'roll.gen.legato',
              'roll.gen.reverse',
              'roll.gen.invertPitch',
            ])
              PopupMenuItem(value: 'run:$id', child: Text('Generate: ${registry[id]?.name ?? id}')),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'toolbar', enabled: canCustomise, child: const Text('Customise toolbar…')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'import', child: Text('Import MIDI file…')),
            const PopupMenuItem(value: 'mid', child: Text('Export as MIDI (.mid)')),
            const PopupMenuItem(value: 'midi2', child: Text('Export as MIDI 2.0 clip (.midi2)')),
          ],
        ),
      ]),
    );
  }
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
    final picked = await showModalBottomSheet<ActionRef>(
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

class _RollPainter extends CustomPainter {
  _RollPainter({
    required this.doc,
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
    required this.editBend,
  });
  final Map<int, LaneCurve>? curves;
  final double secPerStep; // seconds per 16th at the project tempo, for drawing vibrato
  final int? editBend; // the note whose pitch points show (the Curve tool's selected note)
  final double velH, xH, gridStrength;
  final KeyLabels keyLabels;
  final PatternDoc doc;
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
    // Notes: layer colour, brighter when louder; white outline when selected; a dot when it has extras.
    for (final n in doc.notes) {
      final x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
      if (x > w || x + nw < 0) continue;
      final y = (127 - n.pitch.round()) * rowH - scrollY;
      final e = n.expr;
      final bent = e.bend.isNotEmpty || e.vibDepth > 0;
      // A bent note can sound far from its row: keep it on screen while any of its curve is.
      final reach = bent ? (e.bend.fold(0.0, (m, p) => math.max(m, p.v.abs())) + e.vibDepth + 1) * rowH : 0.0;
      if (y - reach > h || y + rowH + reach < 0) continue;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, y + 1, nw, rowH - 2), const Radius.circular(3));
      final fill = color.withValues(alpha: 0.35 + 0.65 * n.vel);
      if (bent) {
        // The note's pitch over time, MIDI Sketch style: its row stays faint, the bent line carries it.
        canvas.drawRRect(r, Paint()..color = fill.withValues(alpha: 0.18));
        final path = Path();
        final lenSec = n.len.toDouble() * secPerStep;
        for (var px = 0.0; px <= nw; px += 2) {
          final u = px / nw;
          final py = y + rowH / 2 - e.pitchAt(u, u * lenSec) * rowH;
          px == 0 ? path.moveTo(x + px, py) : path.lineTo(x + px, py);
        }
        canvas.drawPath(path, Paint()
          ..color = fill
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(3.0, rowH * 0.55));
        if (editBend == n.id) {
          for (final p in e.bend) {
            canvas.drawCircle(Offset(x + p.t * nw, y + rowH / 2 - p.v * rowH), 5, Paint()..color = Neon.yellow);
          }
        }
      } else {
        canvas.drawRRect(r, Paint()..color = fill);
      }
      if (sel.contains(n.id)) {
        canvas.drawRRect(r, Paint()
          ..color = Neon.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      }
      if (n.prob < 1 || n.ratchet > 1 || n.slide) {
        canvas.drawCircle(Offset(x + 4, y + rowH / 2), 2, Paint()..color = Neon.bg);
      }
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
    for (var b = (t0 / bar).floor(); b * bar <= t1; b++) {
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
      o.editBend != editBend ||
      o.color != color;
}

/// The settings a generator asks for, as named numbers; the last values are kept for the next time.
class _GenDialog extends StatefulWidget {
  const _GenDialog({required this.id});
  final String id;

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
    _ => [('seventh', 'Chord', 0, 1, 0, ['Triad', 'Seventh'])],
  };
  late final Map<String, double> _v = {
    for (final f in _fields) f.$1: (_GenDialog._last['${widget.id}.${f.$1}'] ?? f.$5).clamp(f.$3, f.$4)
  };

  @override
  Widget build(BuildContext context) {
    final name = widget.id.replaceFirst('roll.gen.', '');
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: Text(name[0].toUpperCase() + name.substring(1)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final f in _fields)
          if (f.$6 != null)
            Wrap(spacing: 6, children: [
              for (var i = 0; i < f.$6!.length; i++)
                ChoiceChip(
                  label: Text(f.$6![i]),
                  selected: _v[f.$1]!.round() == i,
                  onSelected: (_) => setState(() => _v[f.$1] = i.toDouble()),
                ),
            ])
          else ...[
            Text('${f.$2}: ${_v[f.$1]!.round()}'),
            Slider(
              min: f.$3,
              max: f.$4,
              divisions: (f.$4 - f.$3).round(),
              value: _v[f.$1]!,
              onChanged: (x) => setState(() => _v[f.$1] = x.roundToDouble()),
            ),
          ],
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
