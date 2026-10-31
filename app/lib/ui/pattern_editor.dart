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
import '../engine/engine.dart';

import '../model/app_state.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import 'key_router.dart';
import 'theme.dart';

enum PatternTool { draw, select, erase }

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
  bool _multiEdit = false;
  double _pxPerStep = 28, _scrollX = 0, _scrollY = 0;
  final double _rowH = 16;
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
  int _lane = 0; // a drag in the velocity (1) or extras (2) lane
  double _gridH = 0;
  Timer? _hold; // long press on a note opens its extras panel
  Offset? _holdAt;

  static const _keyW = 44.0, _velH = 56.0, _xH = 40.0, _rulerH = 20.0;
  double get _lanesH => (_velLane ? _velH : 0) + (_extrasLane ? _xH : 0);

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
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
        _clip = d.copy(_sel);
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

  // ---------- pointer ----------

  double _stepAt(double x) => (x + _scrollX) / _pxPerStep;
  double _pitchAt(double y) => 127 - ((y + _scrollY) / _rowH).floorToDouble();

  int? _noteAt(Offset p) {
    final d = _doc;
    if (d == null) return null;
    final t = _stepAt(p.dx), pitch = _pitchAt(p.dy);
    for (final n in d.notes.reversed) {
      if (n.pitch.round() == pitch && t >= n.at.toDouble() && t < n.end.toDouble()) return n.id;
    }
    return null;
  }

  void _down(Offset p) {
    _focus.requestFocus();
    final d = _doc;
    if (d == null) return;
    _dragStart = p;
    _dragBase = d;
    _dragMovedT = Steps.zero;
    _dragMovedP = 0;
    _lane = 0;
    if (p.dy >= _gridH) {
      _lane = _velLane && p.dy < _gridH + _velH ? 1 : 2;
      _laneEdit(p);
      return;
    }
    final hit = _noteAt(p);
    _cursorPitch = _pitchAt(p.dy).clamp(0, 127);
    _cursorAt = _snapTime(_stepAt(p.dx), _tapLevel);
    if (_tool == PatternTool.erase) {
      if (hit != null) _apply(d.delete({hit}));
      _dragNote = null;
      return;
    }
    if (hit != null) {
      final n = d.byId(hit)!;
      _dragNote = hit;
      _resizing = (n.end.toDouble() - _stepAt(p.dx)) * _pxPerStep < 12;
      if (!_sel.contains(hit)) setState(() => _sel = {hit});
      _holdAt = p;
      _hold = Timer(const Duration(milliseconds: 500), () {
        _up();
        _openExtras();
      });
      return;
    }
    _dragNote = null;
    if (_tool == PatternTool.draw) {
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
    if (_tool == PatternTool.erase) {
      final hit = _noteAt(p);
      if (hit != null && _doc != null) _apply(_doc!.delete({hit}));
      return;
    }
    if (_dragNote == null) {
      if (_tool == PatternTool.select) {
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
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final n = _doc!.byId(sel.first)!;
        void change(PatternDoc Function(PatternDoc) f) {
          setState(() => _doc = f(_doc!));
          set(() {});
        }

        return Padding(
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
          ]),
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
    final references = s.selectedPatternReferences;
    if (!s.canMultiEditSelectedClips) _multiEdit = false;
    final toolbar = _Toolbar(
      tool: _tool,
      onTool: (t) => setState(() => _tool = t),
      canUndo: _undo.isNotEmpty,
      canRedo: _redo.isNotEmpty,
      onUndo: () => _undoRedo(true),
      onRedo: () => _undoRedo(false),
      res: _res,
      onRes: (r) => setState(() => _res = r),
      snap: _snap,
      onSnap: () => setState(() => _snap = !_snap),
      fixed: _fixed,
      onFixed: () => setState(() => _fixed = !_fixed),
      grid: _grid,
      onGrid: () => setState(() => _grid = !_grid),
      triplet: _triplet,
      onTriplet: () => setState(() => _triplet = !_triplet),
      onMenu: (v) {
        switch (v) {
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
        if (s.selectedClipIds.length > 1)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Row(children: [
              Text('${s.selectedClipIds.length} CLIPS SELECTED',
                style: const TextStyle(color: Neon.dim, fontSize: 9, letterSpacing: 1)),
              const Spacer(),
              if (references.isNotEmpty)
                Text('${references.length} reference source(s)', style: const TextStyle(color: Neon.blue, fontSize: 9)),
              if (s.canMultiEditSelectedClips)
                TextButton(onPressed: () => setState(() => _multiEdit = !_multiEdit),
                  child: Text(_multiEdit ? 'MULTI-EDIT ON' : 'EDIT ALL LINKED')),
            ])),
        toolbar,
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth - _keyW, h = box.maxHeight - _lanesH - _rulerH;
            _gridH = h;
            _scrollX = _scrollX.clamp(0, math.max(0.0, length * _pxPerStep + 200 - w));
            _scrollY = _scrollY.clamp(0, math.max(0.0, 128 * _rowH - h));
            final grid = _grid ? _gridRows(d) : null;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (e) {
                _zoomStart = _pxPerStep;
                if (e.pointerCount == 1) _down(e.localFocalPoint - const Offset(_keyW, _rulerH));
              },
              onScaleUpdate: (e) {
                if (e.pointerCount >= 2) {
                  // Two fingers zoom and scroll; one finger always edits.
                  setState(() {
                    _pxPerStep = (_zoomStart * e.horizontalScale).clamp(4.0, 200.0);
                    _scrollX -= e.focalPointDelta.dx;
                    _scrollY -= e.focalPointDelta.dy;
                  });
                } else {
                  _move(e.localFocalPoint - const Offset(_keyW, _rulerH));
                }
              },
              onScaleEnd: (_) => _up(),
              child: Listener(
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

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.tool,
    required this.onTool,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.res,
    required this.onRes,
    required this.snap,
    required this.onSnap,
    required this.fixed,
    required this.onFixed,
    required this.grid,
    required this.onGrid,
    required this.fullScreen,
    required this.onFullScreen,
    required this.triplet,
    required this.onTriplet,
    required this.onMenu,
    required this.velLane,
    required this.extrasLane,
  });
  final PatternTool tool;
  final ValueChanged<PatternTool> onTool;
  final bool canUndo, canRedo, snap, fixed, grid, fullScreen, triplet, velLane, extrasLane;
  final VoidCallback onUndo, onRedo, onSnap, onFixed, onGrid, onFullScreen, onTriplet;
  final ValueChanged<String> onMenu;
  final int res;
  final ValueChanged<int> onRes;

  @override
  Widget build(BuildContext context) {
    Widget tb(IconData i, String tip, bool on, VoidCallback? f) => IconButton(
          tooltip: tip,
          onPressed: f,
          icon: Icon(i, color: on ? Neon.yellow : Neon.dim),
        );
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        tb(Icons.edit, 'Draw (B)', tool == PatternTool.draw, () => onTool(PatternTool.draw)),
        tb(Icons.highlight_alt, 'Select (V)', tool == PatternTool.select, () => onTool(PatternTool.select)),
        tb(Icons.auto_fix_normal, 'Erase (X)', tool == PatternTool.erase, () => onTool(PatternTool.erase)),
        const VerticalDivider(width: 12),
        tb(Icons.undo, 'Undo (Ctrl+Z)', false, canUndo ? onUndo : null),
        tb(Icons.redo, 'Redo (Ctrl+Shift+Z)', false, canRedo ? onRedo : null),
        const VerticalDivider(width: 12),
        Center(
          child: DropdownButton<int>(
            value: res,
            underline: const SizedBox(),
            items: [for (final r in _resolutions) DropdownMenuItem(value: r, child: Text(r == 1 ? '1' : '1/$r'))],
            onChanged: (v) => onRes(v!),
          ),
        ),
        tb(Icons.looks_3_outlined, 'Triplets (Alt+0)', triplet, onTriplet),
        tb(Icons.grid_on, 'Snap to grid (N)', snap, onSnap),
        tb(Icons.lock_outline, 'Fixed grid (Alt+F)', fixed, onFixed),
        tb(Icons.apps, 'Drum grid / piano roll (G)', grid, onGrid),
        tb(fullScreen ? Icons.fullscreen_exit : Icons.fullscreen, 'Full screen', false, onFullScreen),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: Neon.dim),
          onSelected: onMenu,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'note', child: Text('Note extras… (I, or hold a note)')),
            CheckedPopupMenuItem(value: 'vel', checked: velLane, child: const Text('Velocity lane (Alt+V)')),
            CheckedPopupMenuItem(value: 'extras', checked: extrasLane, child: const Text('Chance lane (Alt+X)')),
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
  });
  final double velH, xH;
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
      canvas.drawLine(Offset(x, 0), Offset(x, h),
          Paint()..color = isBar ? Neon.dim : (isBeat ? Neon.line : Neon.line.withValues(alpha: 0.45)));
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
    for (final n in doc.notes) {
      final x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
      if (x > w || x + nw < 0) continue;
      final y = (127 - n.pitch.round()) * rowH - scrollY;
      if (y > h || y + rowH < 0) continue;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, y + 1, nw, rowH - 2), const Radius.circular(3));
      canvas.drawRRect(r, Paint()..color = color.withValues(alpha: 0.35 + 0.65 * n.vel));
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
      if (pitch % 12 == 0) {
        ts.text = TextSpan(text: 'C${pitch ~/ 12 - 1}', style: const TextStyle(color: Neon.dim, fontSize: 10));
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
      o.color != color;
}
