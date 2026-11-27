// The pattern editor's Curve tool: velocity and chance curves in the lanes, and pitch curves drawn on notes.
// ignore_for_file: invalid_use_of_protected_member
part of '../pattern_editor.dart';

/// [raw] on a grid of [g], staying on [prev] until [raw] is 0.65 of a grid step from it.
double _sticky(double raw, double? prev, double g) =>
    prev != null && (raw - prev).abs() < g * 0.65 ? prev : Snap.to(raw, g);

bool _samePoints(List<NotePoint> a, List<NotePoint> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

extension _RollCurves on _PatternEditorState {
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
    return v.clamp(-NoteExpression.maxBend, NoteExpression.maxBend).toDouble();  // eight octaves (#226)
  }

  /// A point's place along [n] (0..1) under the finger at [x], on the time grid (sticky, as above) while snapping.
  double _bendU(double x, PatternNote n, {double? prev}) {
    final u = (x - _noteX(n)) / _noteW(n), g = _resSteps.toDouble() / n.len.toDouble();
    return (_free || g >= 1 ? u : _sticky(u, prev, g)).clamp(0.0, 1.0).toDouble();
  }

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
      final now = _gestureNow();
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

  /// The mouse over the roll with the Curve tool: highlights what a click would grab.
  void _curveHover(PointerHoverEvent e) {
    if (_tool != PatternTool.curve || _bNote != null) return;
    final hit = _curveHitAt(e.localPosition - _origin, _curveReach(e.kind));
    if (hit != _curveView.value.hit) _curveView.value = _CurveView(hit: hit);
  }
}
