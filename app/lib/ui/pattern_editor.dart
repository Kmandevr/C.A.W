// The pattern editor: a piano roll and a drum grid over the same notes, with an adaptive grid, velocity lane and keys.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/app_state.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import 'theme.dart';

enum PatternTool { draw, select, erase }

/// Grid resolutions as fractions of a whole note (1 = a bar of 4/4), from 1 down to 1/128.
const _resolutions = [1, 2, 4, 8, 16, 32, 64, 128];

class PatternEditor extends StatefulWidget {
  const PatternEditor({super.key, required this.state, required this.module, this.fullScreen = false});
  final AppState state;
  final ModuleDoc module;
  final bool fullScreen;

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
  bool _snap = true, _fixed = false;
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

  static const _keyW = 44.0, _velH = 56.0, _rulerH = 20.0;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PatternEditor old) {
    super.didUpdateWidget(old);
    if (old.module.id != widget.module.id || widget.module.source != _lastText) _load();
  }

  @override
  void dispose() {
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

  Steps get _resSteps => Steps(16, _res);

  /// The finest grid level shown at this zoom: lines at least 10 px apart, never finer than the resolution.
  Steps _levelFor(double minPx) {
    var steps = Steps(16 * 4, 1); // start at 4 bars' worth and halve
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

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
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
      fullScreen: widget.fullScreen,
      onFullScreen: () {
        _flush();
        if (widget.fullScreen) {
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                  body: SafeArea(child: PatternEditor(state: s, module: widget.module, fullScreen: true)))));
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
            final w = box.maxWidth - _keyW, h = box.maxHeight - _velH - _rulerH;
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
  });
  final PatternTool tool;
  final ValueChanged<PatternTool> onTool;
  final bool canUndo, canRedo, snap, fixed, grid, fullScreen;
  final VoidCallback onUndo, onRedo, onSnap, onFixed, onGrid, onFullScreen;
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
        tb(Icons.grid_on, 'Snap to grid (N)', snap, onSnap),
        tb(Icons.lock_outline, 'Fixed grid (Alt+F)', fixed, onFixed),
        tb(Icons.apps, 'Drum grid / piano roll (G)', grid, onGrid),
        tb(fullScreen ? Icons.fullscreen_exit : Icons.fullscreen, 'Full screen', false, onFullScreen),
      ]),
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
  });
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

  static const keyW = _PatternEditorState._keyW, velH = _PatternEditorState._velH, rulerH = _PatternEditorState._rulerH;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - keyW, h = size.height - velH - rulerH;
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
    // Velocity lane.
    final vy = rulerH + h;
    canvas.drawRect(Rect.fromLTWH(keyW, vy, w, velH), Paint()..color = Neon.panel);
    for (final n in doc.notes) {
      final x = keyW + n.at.toDouble() * pxPerStep - scrollX;
      if (x < keyW || x > size.width) continue;
      final bh = (velH - 6) * n.vel;
      canvas.drawRect(Rect.fromLTWH(x, vy + velH - 3 - bh, 3, bh),
          Paint()..color = sel.contains(n.id) ? Neon.text : color);
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
      o.color != color;
}
