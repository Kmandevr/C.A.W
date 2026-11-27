// The pattern editor's pointer handling: taps, drags, pinches, the ratchet brush, edge scrolling and the one-finger note edits.
// ignore_for_file: invalid_use_of_protected_member
part of '../pattern_editor.dart';

// ---------- pointer ----------

/// A mouse moves this far (px) on empty grid before its drag starts.
const double _mouseDragSlop = 4;

const _origin = Offset(_keyW, _rulerH);

// ---------- the ratchet brush (owner, 2026-11-11) ----------
// A drag over notes sets their ratchet count: each note the finger passes (on its row, or on the row the drag began
// in) joins, and the count follows the finger up (more) or down (fewer), one step every [_brushStep] px from the
// count the first note had. A note that is selected brings the whole selection. One undo step a drag.

const _brushStep = 24.0;

extension _RollGestures on _PatternEditorState {
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
      _cursorAt = _snapTime(_stepAt(p.dx), _cellLevel);
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
              rollMenuHead('Note${_sel.length > 1 ? 's (${_sel.length})' : ''}'),
              item('roll.notes.delete', 'Delete'),
              item('roll.edit.duplicate', 'Duplicate'),
              item('roll.edit.copy', 'Copy'),
              item('roll.edit.cut', 'Cut'),
              item('roll.notes.quantize', 'Quantize'),
              item('roll.notes.split', 'Split at the click'),
              if (_sel.length > 1) item('roll.notes.join', 'Join'),
              rollMenuHead('Velocity'),
              item('vel:1.0', 'Velocity 100%'),
              item('vel:0.8', 'Velocity 80%'),
              item('vel:0.5', 'Velocity 50%'),
              item('roll.notes.extras', 'Note extras…'),
            ]
          : [
              rollMenuHead('Grid'),
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
        // The Erase tool swipes from anywhere: from empty grid too, not only from a note (#228).
        if (_tool == PatternTool.erase) {
          _pending = null;
          _down(pending);
          _dragTo(p);
          return;
        }
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
    setState(() => _ghost = (at: _snapTime(_stepAt(p.dx), _cellLevel), pitch: _pitchAt(p.dy).clamp(0, 127), len: len));
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
    final cell = _cellLevel.toDouble(), touchCell = (t / cell).floor();
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
    _cursorAt = _snapTime(_stepAt(p.dx), _cellLevel);
    _tapCandidate = null;
    // Drawing where a note already starts on this pitch takes that note (selects it, a drag moves it) instead of
    // stacking a second one on it (#228).
    if (hit == null && _tool == PatternTool.draw && !_rectSelect) {
      final same = d.noteStartingAt(_cursorAt, _cursorPitch);
      if (same != null) (hit, edge) = (same.id, 0);
    }
    final tapAt = _tapAt;
    if (hit != null && !outside && hit == _tapNote && tapAt != null &&
        _gestureNow().difference(tapAt) < const Duration(milliseconds: 350)) {
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
    final last = _emptyTap, now = _gestureNow();
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
    // A moved note dropped where another starts on its pitch replaces it: no stacked duplicates (#228).
    if (_dragNote != null && _edge == 0 && _dragBase != null && _doc != null && !identical(_dragBase, _doc)) {
      final merged = _doc!.mergeStacked(_sel.isEmpty ? {_dragNote!} : _sel);
      if (!identical(merged, _doc)) setState(() => _doc = merged);
    }
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
    _tapAt = _gestureNow();
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
}
