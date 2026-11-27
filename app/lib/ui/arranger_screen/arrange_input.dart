// Arrange's input: the clip actions, the marquee, pinch and wheel zoom, touch scrolling and moving the focus between tracks.
// ignore_for_file: invalid_use_of_protected_member
part of '../arranger_screen.dart';

extension _ArrangeInput on _ArrangerScreenState {
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

  /// Sets the time zoom, keeping the timeline point under [focal] (pixels from the lanes' left edge; the middle of
  /// the view by default) where it is. With [leftStep], that step goes to the view's left edge instead. The lanes lay
  /// out at the new zoom and the view scrolls in the same frame, so the point holds still on every frame.
  void _setZoom(double z, {double? focal, double? leftStep, double? beat}) {
    z = z.clamp(_ArrangerScreenState.minZoom, _ArrangerScreenState.maxZoom).toDouble();
    if (z == zoom && leftStep == null && beat == null) return;
    final pos = _hScroll.hasClients ? _hScroll.positions.last : null;
    final f = leftStep != null ? 0.0 : focal ?? (pos?.viewportDimension ?? 0) / 2;
    final anchor = leftStep ?? beat ?? (pos == null ? null : (pos.pixels + f) / _stepW);
    _zoomN.value = z;
    if (anchor == null) return;
    _scrollLanesTo(math.max(0.0, anchor * _stepW - f));
  }

  /// Scrolls the lanes to [x] before the frame lays them out at a new zoom. Past the end the view had at the old zoom
  /// (zooming in near it), a jump would bounce back, so the view goes to that end and takes [x] silently; the
  /// layout then keeps it if the new width has room, as it does a few screens before the timeline's end.
  void _scrollLanesTo(double x) {
    for (final p in _hScroll.positions.toList()) {
      if (!p.hasContentDimensions) continue;
      if (x <= p.maxScrollExtent) {
        p.jumpTo(x);
      } else {
        p.jumpTo(p.maxScrollExtent);
        p.correctPixels(x);
      }
    }
  }

  /// A time pinch's move to zoom [z] with the fingers' midpoint at [focal] (pixels from the lanes' left edge).
  void _pinchTo(double z, double focal) {
    final pos = _hScroll.hasClients ? _hScroll.positions.last : null;
    if (pos == null) return _setZoom(z, focal: focal);
    final beat = _pinchBeat ??= (pos.pixels + _pinchFocal0) / _stepW;
    _setZoom(z, focal: focal, beat: beat);
  }

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
      _pinchBeat = null;
      _pinchFocal0 = (ps[0].dx + ps[1].dx) / 2 - headW;
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
        // A glide, as the buttons zoom (retargeted by the next notch), through the same layout per frame.
        _animateViewTo(zoom: _zoomAim * factor, keep: focal);
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
}
