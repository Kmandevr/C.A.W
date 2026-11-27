// The pattern editor's actions and keys: what the keymap, toolbars and macros run, copy and paste, and the roll's own shortcuts.
// ignore_for_file: invalid_use_of_protected_member
part of '../pattern_editor.dart';

final ActionRegistry _fallbackRegistry = ActionRegistry.standard();
final Keymap _fallbackKeymap = Keymap.defaults(_fallbackRegistry);

extension _RollCommands on _PatternEditorState {
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
        if (r == null || !rollResolutions.contains(r)) return true;
        setState(() => _res = r);
      case 'roll.tool.draw':
        _setTool(PatternTool.draw);
      case 'roll.tool.select':
        _setTool(PatternTool.select);
      case 'roll.tool.curve':
        _setTool(PatternTool.curve);
      case 'roll.tool.erase':
        _setTool(PatternTool.erase);
      case 'roll.tool.ratchet':
        _setTool(PatternTool.ratchet);
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
        setState(() => _res = rollResolutions[digit - 1]);
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
        _setTool(PatternTool.draw);
      case LogicalKeyboardKey.keyV:
        _setTool(PatternTool.select);
      case LogicalKeyboardKey.keyX:
        _setTool(PatternTool.erase);
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
}
