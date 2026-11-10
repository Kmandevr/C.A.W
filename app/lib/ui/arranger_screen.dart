// Arrange: the tracks and clips on a timeline, compact track headers, the focus view (one track and its panel) and the mixer card.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../model/app_state.dart';
import '../model/arrange_edit.dart';
import '../model/arrange_fx.dart';
import '../model/live_midi.dart';
import '../model/project.dart';
import '../model/settings.dart';
import 'arrange/arrange_drag.dart';
import 'arrange/clip_bar.dart';
import 'arrange/focus_panel.dart';
import 'arrange/fx_stack.dart';
import 'arrange/long_press_menu.dart';
import 'arrange/mixer_card.dart';
import 'frame/sections.dart';
import 'motion.dart';
import 'param_control.dart';
import 'theme.dart';
import 'arrange/track_color.dart';
import 'file_manager_screen.dart';
import 'frame/frame_widgets.dart';
import 'widgets.dart';
import 'volume_fader.dart';
import 'track_cards_screen.dart';
import 'glass.dart';
import 'key_router.dart';
import 'midi_file_actions.dart';


double endPosition(AppState state, ProjectDoc project, int loopLength) {
  return project.engineLoopSteps * state.meters.position / loopLength;
}

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

class _ArrangerScreenState extends State<ArrangerScreen> with SingleTickerProviderStateMixin {
  bool mixer = false, settings = false, cardsView = false, mixerCard = false, zoomBar = false;

  /// Phone portrait: the focus panel opened up over the pinned track (owner, 2026-11-10: it can open higher).
  bool _panelHigh = false;

  /// The Files browser beside (or under) the tracks, so files can be dragged onto a track or into the FX stack
  /// without leaving Arrange (owner, 2026-11-10).
  bool _browser = false;

  /// Time zoom: pixels per 16th step (× 0.85 at compact density).
  double zoom = 18.0;
  static const minZoom = 3.0, maxZoom = 64.0;

  // The zoom buttons glide to their new zoom ([Motion.standard]); a pinch, slider or Ctrl + wheel follows at once.
  late final AnimationController _zoomAnim = AnimationController(vsync: this, duration: Motion.standard)
    ..addListener(_zoomFrame);
  double _zoomFrom = 18, _zoomTarget = 18;
  double? _zoomFocal;

  // Two fingers on the timeline: a sideways pinch zooms time, an up-and-down pinch the track height.
  final Map<int, Offset> _touches = {};
  double _pinchDx0 = 0, _pinchDy0 = 0, _pinchZoom0 = 0, _pinchH0 = 0;
  bool _pinchX = false, _pinchY = false;
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

  /// The timeline's step width and track height at the last build, for the marquee's hit test.
  double _stepW = 18, _laneTrackH = 60;

  final _keys = FocusNode(debugLabel: 'arranger keys', skipTraversal: true);
  KeyRouterState? _router;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = KeyRouter.of(context);
    if (r == _router) return;
    _router?.unregister(Area.arranger, _keys);
    _router = r?..register(Area.arranger, _keys, _action);
  }

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
      case 'arranger.clip.selectMode':
        setState(() => _selectMode = !_selectMode);
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
    final inset = _clipInset(_laneTrackH);
    final hit = <PlacedClip>[];
    for (final layer in s.visibleLayers) {
      final lane = _drag.laneRect(layer.id);
      if (lane == null) continue;
      final top = lane.top + inset, bottom = lane.top + _laneTrackH - inset;
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

  @override
  void dispose() {
    _router?.unregister(Area.arranger, _keys);
    _keys.dispose();
    _marquee.dispose();
    _zoomAnim.dispose();
    _trackGhost?.remove();
    _trackGhostAt.dispose();
    _drag.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  /// Sets the time zoom, keeping the timeline point under [focal] (pixels from the lanes' left edge; the middle of
  /// the view by default) where it is.
  void _setZoom(double z, {double? focal}) {
    z = z.clamp(minZoom, maxZoom).toDouble();
    if (z == zoom) return;
    final pos = _hScroll.hasClients ? _hScroll.positions.last : null;
    final f = focal ?? (pos?.viewportDimension ?? 0) / 2;
    final anchor = pos == null ? null : (pos.pixels + f) / zoom;
    setState(() => zoom = z);
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hScroll.hasClients) return;
      final p = _hScroll.positions.last;
      p.jumpTo((anchor * zoom - f).clamp(0.0, p.maxScrollExtent).toDouble());
    });
  }

  /// The zoom buttons: a short glide to [z] (at once when motion is off).
  void _animateZoom(double z) {
    _zoomTarget = z.clamp(minZoom, maxZoom).toDouble();
    if (Motion.of(context) != MotionLevel.full) {
      _setZoom(_zoomTarget);
      return;
    }
    _zoomFrom = zoom;
    _zoomFocal = null;
    _zoomAnim.forward(from: 0);
  }

  void _zoomFrame() {
    final t = Curves.easeOutCubic.transform(_zoomAnim.value);
    _setZoom(_zoomFrom + (_zoomTarget - _zoomFrom) * t, focal: _zoomFocal);
  }

  void _touchDown(PointerDownEvent e, double headW) {
    if (e.kind != PointerDeviceKind.touch) return;
    // During a clip or track drag a second finger toggles copy (the phone's Ctrl) instead of starting a pinch.
    if (_drag.active) {
      _drag.copy.value = !_drag.copy.value;
      Motion.tick();
      return;
    }
    _touches[e.pointer] = e.localPosition;
    _drag.pinching = _touches.length >= 2;
    if (_touches.length == 2) {
      final ps = _touches.values.toList();
      final dx = (ps[0].dx - ps[1].dx).abs(), dy = (ps[0].dy - ps[1].dy).abs();
      _pinchDx0 = dx;
      _pinchDy0 = dy;
      _pinchZoom0 = zoom;
      _pinchH0 = _trackHeight;
      // Fingers side by side zoom time, one above the other the height; diagonal, both.
      _pinchX = dx > 24 && dx >= dy * 0.6;
      _pinchY = dy > 24 && dy >= dx * 0.6;
      _zoomAnim.stop();
    }
  }

  void _touchMove(PointerMoveEvent e, double headW) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length != 2) return;
    final ps = _touches.values.toList();
    if (_pinchX) {
      _setZoom(_pinchZoom0 * (ps[0].dx - ps[1].dx).abs() / _pinchDx0, focal: (ps[0].dx + ps[1].dx) / 2 - headW);
    }
    if (_pinchY) {
      setState(() => _dragTrackH = (_pinchH0 * (ps[0].dy - ps[1].dy).abs() / _pinchDy0)
          .clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble());
    }
  }

  void _touchUp(PointerEvent e) {
    if (_touches.remove(e.pointer) == null) return;
    _drag.pinching = _touches.length >= 2;
    if (_touches.length == 1 && (_pinchX || _pinchY)) {
      _pinchX = _pinchY = false;
      _saveHeaderSize();
    }
  }

  /// Ctrl + wheel zooms time around the mouse; Ctrl + Shift + wheel changes the track height. Registered before the
  /// scroll views see the wheel, so they don't also scroll.
  void _wheel(PointerSignalEvent e, double? focal) {
    if (e is! PointerScrollEvent || !HardwareKeyboard.instance.isControlPressed) return;
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
        _setZoom(zoom * factor, focal: focal);
      }
    });
  }

  SectionController? get _sections => SectionController.maybeOf(context);

  String? get _focusId => _sections != null ? _sections!.focusedLayer : _localFocus;

  void _focus(String? layerId, {FocusTab? tab}) {
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

  Future<void> _trackMenu(LayerDoc layer, Offset at, List<ModuleDoc> patterns) async {
    final s = widget.state;
    final index = s.project.layers.indexOf(layer);
    s.componentCatalog.refreshIfStale();
    final hasVolume = layer.automation.any((a) => a.target == 'volume');
    final hasPan = layer.automation.any((a) => a.target == 'pan');
    final canAutomate = !layer.isFolder || layer.busEnabled;
    final midi = LiveMidi.current;
    final v = await showLongPressMenu<String>(context, at: at, title: layer.name, style: s.settings.longPressMenu, actions: [
      if (!layer.isFolder) ...[
        const MenuAction('fx', 'Effects', Icons.graphic_eq),
        // MIDI keyboards record into a track (lib/model/live_midi.dart); audio recording needs the engine's input.
        // While any track records, this stops that take (one take at a time).
        MenuAction('arm', midi?.recording ?? false ? 'Stop recording' : 'Record arm', Icons.fiber_manual_record,
            enabled: midi != null && (midi.devices.isNotEmpty || midi.recording),
            checked: midi?.armedLayerId == layer.id,
            hint: midi == null || midi.devices.isEmpty ? 'Connect a MIDI keyboard' : null),
        MenuAction('input', 'Input · ${midi == null || midi.devices.isEmpty ? 'none' : midi.devices.join(', ')}', Icons.input,
            enabled: false, hint: 'MIDI keyboards play the selected track; audio input comes later'),
        // The same browser as the FX stack's (REAPER: instruments are FX), filtered to instruments.
        MenuAction('instrument', 'Instrument · ${s.instrumentName(layer) ?? 'none'}…', Icons.piano),
        for (final pattern in patterns) MenuAction('clip:${pattern.id}', 'Add clip · ${pattern.name}', Icons.add_box_outlined),
        const MenuAction('midi', 'Import MIDI file…', Icons.file_open_outlined),
      ],
      const MenuAction('rename', 'Rename', Icons.edit_outlined),
      MenuAction('color', layer.ownColor || layer.parentId == null ? 'Colour' : 'Own colour', Icons.palette_outlined),
      if (layer.ownColor && layer.parentId != null) const MenuAction('folder-color', "Use the folder's colour", Icons.format_color_reset_outlined),
      if (index > 0) const MenuAction('up', 'Move up', Icons.arrow_upward),
      if (index < s.project.layers.length - 1) const MenuAction('down', 'Move down', Icons.arrow_downward),
      if (layer.parentId != null) const MenuAction('unparent', 'Move out of folder', Icons.drive_file_move_rtl_outlined),
      for (final folder in s.project.layers.where((f) => f.isFolder && f.id != layer.id && f.id != layer.parentId))
        MenuAction('parent:${folder.id}', 'Move into ${folder.name}', Icons.drive_file_move_outlined),
      if (layer.isFolder) MenuAction('bus', layer.busEnabled ? 'Disable group bus' : 'Enable group bus', Icons.account_tree_outlined),
      if (canAutomate && !hasVolume) const MenuAction('automation-volume', 'Add volume automation', Icons.show_chart),
      if (canAutomate && !hasPan) const MenuAction('automation-pan', 'Add pan automation', Icons.show_chart),
      if (hasVolume) const MenuAction('remove-automation-volume', 'Remove volume automation', Icons.remove_circle_outline),
      if (hasPan) const MenuAction('remove-automation-pan', 'Remove pan automation', Icons.remove_circle_outline),
      MenuAction('spacer', layer.spaceBelow > 0 ? 'Remove spacer below' : 'Add spacer below', Icons.space_bar),
      const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true),
    ]);
    if (v == null || !mounted) return;
    if (v == 'fx') _openTrack(layer, tab: FocusTab.fx);
    if (v == 'arm') midi?.toggleRecord(layer.id);
    if (v == 'instrument') {
      await pickInstrument(context, s, layer);
      return;
    }
    if (v.startsWith('clip:')) s.addClip(layer, v.substring(5));
    if (v == 'midi') await importMidiFile(context, s, layer: layer);
    if (v == 'rename') await _rename(layer);
    if (v == 'color') s.editLayer(layer, (l) { l.color = l.ownColor ? (l.color + 1) % LayerDoc.trackColors : l.color; l.ownColor = true; });
    if (v == 'folder-color') s.editLayer(layer, (l) => l.ownColor = false);
    if (v == 'up' && index > 0) s.moveLayer(index, index - 1);
    if (v == 'down' && index < s.project.layers.length - 1) s.moveLayer(index, index + 2);
    if (v == 'unparent') s.moveLayerIntoFolder(layer, null);
    if (v.startsWith('parent:')) s.moveLayerIntoFolder(layer, v.substring(7));
    if (v == 'bus') s.setFolderBus(layer, !layer.busEnabled);
    if (v == 'automation-volume') s.addAutomationLane(layer, 'volume');
    if (v == 'automation-pan') s.addAutomationLane(layer, 'pan');
    if (v == 'remove-automation-volume') s.removeAutomationLane(layer, layer.automation.firstWhere((a) => a.target == 'volume'));
    if (v == 'remove-automation-pan') s.removeAutomationLane(layer, layer.automation.firstWhere((a) => a.target == 'pan'));
    if (v == 'spacer') s.setSpaceBelow(layer, layer.spaceBelow > 0 ? 0 : _SpacerHeader.initial);
    if (v == 'delete') {
      if (_focusId == layer.id) _focus(null);
      s.removeLayer(layer);
    }
  }

  // ---------- a track header dragged (REAPER: drag a track panel up or down, or into a folder's middle) ----------

  LayerDoc? _pressed, _dragged;
  Offset _pressAt = Offset.zero, _trackAt = Offset.zero;
  OverlayEntry? _trackGhost;
  final _trackGhostAt = ValueNotifier<Offset>(Offset.zero);

  void _trackDrag(LayerDoc layer, _HeaderPhase phase, Offset at) {
    switch (phase) {
      case _HeaderPhase.press:
        _pressed = layer;
        _pressAt = at;
        Motion.tick();
      case _HeaderPhase.grab:
        _pressed = layer;
        _pressAt = at;
        _startTrackDrag(layer, at);
      case _HeaderPhase.move:
        if (_dragged == null && _pressed == layer && (at - _pressAt).distance > 10) _startTrackDrag(layer, at);
        if (_dragged != layer) return;
        _trackAt = at;
        _trackGhostAt.value = at;
        _drag.point(at);
        _trackHover();
      case _HeaderPhase.release:
        if (_dragged == layer) {
          final spot = _drag.hover.value;
          _endTrackDrag();
          if (spot == null) return;
          final target = widget.state.project.layers.where((l) => l.id == spot.layerId).firstOrNull;
          widget.state.moveTrack(layer, spot.newTrack ? null : target, spot.where);
        } else if (_pressed == layer) {
          _pressed = null;
          _trackMenu(layer, _pressAt, widget.state.project.modules.where((m) => widget.state.isPattern(m.id)).toList());
        }
      case _HeaderPhase.cancel:
        if (_dragged == layer) _endTrackDrag();
        _pressed = null;
    }
  }

  void _startTrackDrag(LayerDoc layer, Offset at) {
    _dragged = layer;
    _trackAt = at;
    _trackGhostAt.value = at;
    _drag.begin(track: true, onScroll: _trackHover, onCancel: _endTrackDrag);
    final color = trackColor(widget.state, layer);
    _trackGhost = OverlayEntry(builder: (context) => ValueListenableBuilder<Offset>(
      valueListenable: _trackGhostAt,
      builder: (context, p, _) => Positioned(left: p.dx + 12, top: p.dy - 14, child: IgnorePointer(child: Material(
        key: const ValueKey('track-drag-ghost'),
        color: Color.lerp(Neon.panel, color, 0.35)!.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: color, width: 3))),
          child: Text(layer.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))))))));
    Overlay.of(context).insert(_trackGhost!);
  }

  void _trackHover() {
    final layer = _dragged;
    if (layer == null) return;
    var spot = _drag.trackSpotAt(_trackAt, widget.state.project);
    // Onto itself (or into itself, for a folder) it stays where it is.
    final onto = spot?.layerId == null ? null : widget.state.project.layers.where((l) => l.id == spot!.layerId).firstOrNull;
    if (onto != null && (identical(onto, layer) || widget.state.folderDepth(onto) > 0 && _inside(onto, layer.id))) {
      spot = null;
    }
    _drag.hover.value = spot;
  }

  bool _inside(LayerDoc l, String folderId) {
    var parent = l.parentId;
    for (var d = 0; parent != null && d <= widget.state.project.layers.length; d++) {
      if (parent == folderId) return true;
      parent = widget.state.project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
    }
    return false;
  }

  void _endTrackDrag() {
    _trackGhost?.remove();
    _trackGhost = null;
    _dragged = _pressed = null;
    _drag.end();
  }

  Future<void> _rename(LayerDoc layer) async {
    final controller = TextEditingController(text: layer.name);
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Rename track'),
      content: TextField(controller: controller, autofocus: true, maxLength: 64,
        onSubmitted: (v) => Navigator.of(context).pop(v)),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Rename')),
      ],
    ));
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty && trimmed != layer.name) widget.state.editLayer(layer, (l) => l.name = trimmed);
  }

  Future<void> _clipMenu(LayerDoc layer, ClipDoc clip, Offset at) async {
    final s = widget.state;
    final splitAt = s.timeSelectionEnd;
    final canSplit = splitAt != null && splitAt > clip.startSteps && splitAt < clip.startSteps + clip.lengthSteps;
    final playhead = s.editStep;
    final canSplitHere = !clip.lock && playhead > clip.startSteps && playhead < clip.startSteps + clip.lengthSteps;
    final v = await showLongPressMenu<String>(context, at: at, title: s.clipName(clip),
      style: s.settings.longPressMenu, actions: [
        const MenuAction('notes', 'Edit notes', Icons.piano),
        if (widget.onOpenPattern != null) const MenuAction('edit', 'Open in Sounds', Icons.open_in_new),
        // The phone's way to select several (docs/ui.md): this clip joins the selection and Select mode turns on.
        if (!s.selectedClipIds.contains(clip.id) || !_selectMode)
          const MenuAction('select', 'Select several', Icons.checklist)
        else
          const MenuAction('select', 'Deselect', Icons.deselect),
        const MenuAction('properties', 'Properties…', Icons.tune),
        if (canSplitHere) const MenuAction('split-here', 'Split at the playhead', Icons.content_cut),
        const MenuAction('copy', 'Duplicate independently', Icons.copy),
        const MenuAction('linked', 'Duplicate linked', Icons.link),
        MenuAction('loop', clip.loop ? 'Disable clip looping' : 'Enable clip looping', Icons.loop, checked: clip.loop),
        if (canSplit && !clip.lock) const MenuAction('split', 'Split at time selection', Icons.content_cut),
        const MenuAction('midi', 'Export as MIDI file', Icons.file_upload_outlined),
        if (!clip.lock) const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true),
      ]);
    if (v == null || !mounted) return;
    if (v == 'select') {
      final adding = !s.selectedClipIds.contains(clip.id) || !_selectMode;
      setState(() => _selectMode = true);
      if (adding && !s.selectedClipIds.contains(clip.id)) s.toggleClipSelection(layer, clip);
      if (!adding) s.toggleClipSelection(layer, clip);
    }
    if (v == 'properties') {
      if (!s.selectedClipIds.contains(clip.id)) s.selectClip(layer, clip);
      await showClipProperties(context, s);
      return;
    }
    if (v == 'split-here' || v == 'split') {
      s.selectClip(layer, clip);
      s.splitClips(at: v == 'split' ? splitAt : playhead);
    }
    if (v == 'notes') { s.activateClip(layer, clip); _focus(layer.id, tab: FocusTab.clip); }
    if (v == 'edit') { s.activateClip(layer, clip); widget.onOpenPattern?.call(); }
    if (v == 'copy') s.duplicateClip(layer, clip);
    if (v == 'linked') s.duplicateClip(layer, clip, linked: true);
    if (v == 'loop') s.editLayer(layer, (l) => clip.loop = !clip.loop);
    if (v == 'midi') await exportClipAsMidi(context, s, clip);
    if (v == 'delete') s.removeClip(layer, clip);
  }

  _TrackCallbacks _callbacks(List<ModuleDoc> patterns) => _TrackCallbacks(
    onTap: (l) => _openTrack(l),
    onFx: (l) => _openTrack(l, tab: FocusTab.fx),
    onMenu: (l, at) => _trackMenu(l, at, patterns),
    onClipMenu: _clipMenu,
    onClipOpen: (l, c) { widget.state.activateClip(l, c); _focus(l.id, tab: FocusTab.clip); },
    selectMode: () => _selectMode,
    onMarquee: (phase, at, additive) => switch (phase) {
      _Marquee.start => _marqueeStart(at, additive: additive),
      _Marquee.move => _marqueeMove(at),
      _Marquee.end => _marqueeEnd(),
    },
  );

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    if (cardsView) {
      return Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 2), child: Row(children: [
          IconButton(onPressed: () => setState(() => cardsView = false), icon: const Icon(Icons.view_timeline), tooltip: 'Timeline view'),
          const Text('TRACK CARDS', style: TextStyle(color: Neon.dim, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
        ])),
        Expanded(child: TrackCardsScreen(state: s, onOpenModule: widget.onOpenModule ?? s.selectModule)),
      ]);
    }
    final focused = p.layers.where((l) => l.id == _focusId && !l.isFolder).firstOrNull;
    final layout = focusLayoutFor(MediaQuery.sizeOf(context));
    final patterns = p.modules.where((m) => s.isPattern(m.id)).toList();
    final callbacks = _callbacks(patterns);
    final focusable = _focusable;
    final fi = focused == null ? -1 : focusable.indexOf(focused);
    Widget panel(bool sheet) => FocusPanel(
      state: s, layer: focused!, tab: _tab, bottomSheetStyle: sheet,
      onTab: (t) => setState(() => _tab = t),
      onClose: () { _panelHigh = false; _focus(null); },
      expanded: _panelHigh,
      onExpand: sheet ? (v) => setState(() => _panelHigh = v) : null,
      onPrevious: fi > 0 ? () => _step(-1) : null,
      onNext: fi >= 0 && fi < focusable.length - 1 ? () => _step(1) : null,
      onOpenModule: widget.onOpenModule,
      browsing: _browser,
      onBrowse: () => setState(() => _browser = !_browser),
    );

    final Widget body;
    if (focused != null && layout == FocusLayout.pinned) {
      // Phone portrait: the track pinned at the top (still scrollable and editable), its panel below.
      // Opened higher, the panel slides up over the track and leaves only a sliver of it.
      body = LayoutBuilder(builder: (context, box) {
        final pinnedH = (box.maxHeight * 0.2).clamp(84.0, 220.0).toDouble();
        return Column(children: [
          AnimatedContainer(duration: Motion.move(Motion.panel, Motion.of(context)), curve: Curves.easeOutCubic,
            height: _panelHigh ? 0 : pinnedH + 4,
            child: ClipRect(child: OverflowBox(alignment: Alignment.topCenter, minHeight: pinnedH + 4, maxHeight: pinnedH + 4,
              child: Column(children: [
                SizedBox(height: pinnedH, child: _timeline(context, [focused], callbacks, pinned: true)),
                const SizedBox(height: 4),
              ])))),
          Expanded(child: SlideIn(from: const Offset(0, 0.12), child: panel(true))),
        ]);
      });
    } else if (focused != null) {
      // Landscape and desktop: a right side panel; the tracks keep their full height.
      body = LayoutBuilder(builder: (context, box) {
        final w = layout == FocusLayout.side && MediaQuery.sizeOf(context).width >= 900
            ? (box.maxWidth * 0.34).clamp(320.0, 480.0).toDouble()
            : box.maxWidth * 0.4;
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _arrangement(context, callbacks)),
          SizedBox(width: math.min(w, box.maxWidth - 120), child: SlideIn(from: const Offset(0.12, 0), child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4), child: panel(false)))),
        ]);
      });
    } else {
      body = _arrangement(context, callbacks);
    }

    final withBrowser = !_browser ? body : LayoutBuilder(builder: (context, box) {
      // The same Files browser as Build's explorer; hold an item and drag it onto a track or the FX stack.
      final pane = SlideIn(
        from: box.maxWidth >= 600 ? const Offset(0.15, 0) : const Offset(0, 0.15),
        child: Padding(padding: const EdgeInsets.all(4), child: GlassPanel(key: const ValueKey('arrange-browser'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: 30, child: Row(children: [
              const SizedBox(width: 10),
              const Icon(Icons.drag_indicator, size: 14, color: Neon.dim),
              const SizedBox(width: 4),
              const Expanded(child: Text('Hold an item, drag it onto a track', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Neon.dim, fontSize: 11))),
              IconButton(tooltip: 'Close the browser', iconSize: 16, visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _browser = false), icon: const Icon(Icons.close)),
            ])),
            Expanded(child: FileManagerScreen(key: const ValueKey('arrange explorer'), state: s, explorer: true,
              onOpenAsset: (_) {})),
          ]))));
      if (box.maxWidth >= 600) {
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: body),
          SizedBox(width: math.min(300.0, box.maxWidth * 0.32), child: pane),
        ]);
      }
      return Column(children: [
        Expanded(child: body),
        SizedBox(height: math.max(160.0, box.maxHeight * 0.4), child: pane),
      ]);
    });

    return PopScope(
      // Android Back closes the browser, then leaves the focus view (owner, 2026-11-09).
      canPop: focused == null && !_browser,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_browser) {
          setState(() => _browser = false);
        } else if (focused != null) {
          _focus(null);
        }
      },
      child: Column(children: [
        if (s.meters.overloaded > 0) _OverloadBanner(state: s),
        // The toolbar tucks away with the status row while the tracks scroll down (owner, 2026-11-10).
        _tucked(Column(mainAxisSize: MainAxisSize.min, children: [
          _toolbar(context, focused),
          AnimatedSize(duration: Motion.move(Motion.standard, Motion.of(context)), curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: zoomBar ? _zoomBar() : const SizedBox(width: double.infinity)),
        ])),
        if (settings) _settingsPanel(),
        Expanded(child: _withDockedClipBar(withBrowser, focused)),
        if (mixer) _ArrangementMixer(state: s),
      ]),
    );
  }

  /// A phone (a narrow arrangement) gets the clip bar docked near the bottom of the tracks while clips are selected,
  /// in reach of the thumb; a wide one has it in the toolbar.
  Widget _withDockedClipBar(Widget body, LayerDoc? focused) {
    final s = widget.state;
    if (focused != null || mixerCard || (s.selectedClipIds.isEmpty && !_selectMode)) return body;
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 760) return body;
      return Stack(children: [
        Positioned.fill(child: body),
        Positioned(left: 8, right: 8, bottom: 10, child: Center(child: SlideIn(from: const Offset(0, 0.4),
          child: FittedBox(fit: BoxFit.scaleDown, child: _clipBar(docked: true))))),
      ]);
    });
  }

  Widget _toolbar(BuildContext context, LayerDoc? focused) {
    final s = widget.state;
    final p = s.project;
    final gap = s.settings.trackGap;
    final clipsChosen = s.selectedClipIds.isNotEmpty || _selectMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      child: LayoutBuilder(builder: (context, constraints) {
        // A phone gets one row of icon buttons that scrolls sideways, instead of two rows of labelled buttons
        // under a heading (owner, 2026-11-05: one toolbar row, as in the UI plan).
        final narrow = constraints.maxWidth < 760;
        final controls = <Widget>[
          if (narrow)
            IconButton(onPressed: p.layers.length >= 64 ? null : s.addLayer,
              icon: const Icon(Icons.add), color: Neon.green, tooltip: 'Add track')
          else
            TextButton.icon(onPressed: p.layers.length >= 64 ? null : s.addLayer,
              icon: const Icon(Icons.add, size: 17), label: const Text('Track')),
          IconButton(key: const ValueKey('arrange-browse'), onPressed: () => setState(() => _browser = !_browser),
            color: _browser ? Neon.blue : Neon.dim, icon: const Icon(Icons.folder_open),
            tooltip: 'Files: drag one onto a track'),
          IconButton(onPressed: () => setState(() => zoomBar = !zoomBar),
            key: const ValueKey('arrange-zoom'),
            color: zoomBar ? Neon.blue : null,
            icon: const Icon(Icons.zoom_in), tooltip: 'Zoom (or pinch; Ctrl + wheel)'),
          PopupMenuButton<String>(
            tooltip: 'Track height',
            onSelected: (v) {
              final px = double.parse(v.substring(2));
              if (v.startsWith('h:')) {
                s.settings.update((x) => x.trackHeight = px).then((_) { if (mounted) setState(() {}); });
              } else {
                s.settings.update((x) => x.trackGap = px).then((_) { if (mounted) setState(() {}); });
              }
            },
            icon: const Icon(Icons.height, color: Neon.dim),
            itemBuilder: (_) => [
              for (final (px, name) in const [(44.0, 'Thin'), (60.0, 'Compact'), (76.0, 'Standard'), (96.0, 'Tall'), (120.0, 'Extra tall')])
                CheckedPopupMenuItem(value: 'h:$px', checked: _trackHeight == px, child: Text('$name · ${px.round()} px')),
              const PopupMenuDivider(),
              for (final (px, name) in const [(0.0, 'No gap'), (3.0, 'Small gap'), (6.0, 'Gap'), (12.0, 'Wide gap'), (20.0, 'Extra wide gap')])
                CheckedPopupMenuItem(value: 'g:$px', checked: gap == px, child: Text(px == 0 ? name : '$name · ${px.round()} px')),
            ],
          ),
          DropdownButton<int>(value: s.arrangementSnapSteps, underline: const SizedBox.shrink(),
            items: [for (final v in [1, 2, 4, 8, 16]) DropdownMenuItem(value: v, child: Text('1/${v == 1 ? 16 : 16 ~/ v}'))],
            onChanged: (v) { if (v != null) setState(() => s.arrangementSnapSteps = v); }),
          if (narrow)
            IconButton(onPressed: p.layers.length >= 64 ? null : s.addFolder,
              icon: const Icon(Icons.create_new_folder_outlined), color: Neon.green, tooltip: 'Add folder')
          else
            TextButton.icon(onPressed: p.layers.length >= 64 ? null : s.addFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 17), label: const Text('Folder')),
          // A phone opens the mixer as a card over the tracks; a wide screen docks it under them.
          IconButton(onPressed: () => setState(() => narrow ? mixerCard = !mixerCard : mixer = !mixer),
            color: (narrow ? mixerCard : mixer) ? Neon.blue : Neon.dim, icon: const Icon(Icons.tune), tooltip: 'Mixer'),
          IconButton(onPressed: () => setState(() => settings = !settings),
            color: settings ? Neon.blue : Neon.dim, icon: const Icon(Icons.settings_outlined), tooltip: 'Settings'),
          IconButton(onPressed: () => setState(() { cardsView = true; mixerCard = false; }),
            icon: const Icon(Icons.view_agenda_outlined), tooltip: 'Track cards'),
        ];
        if (narrow) {
          return SingleChildScrollView(
            key: const ValueKey('arrange-toolbar'),
            scrollDirection: Axis.horizontal,
            child: Row(children: controls),
          );
        }
        // Wide: the clip bar sits in the toolbar while clips are selected (owner, 2026-11-10: docs/reaper-flow.md).
        return Row(children: [
          const Text('ARRANGEMENT', style: TextStyle(
            color: Neon.dim, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: !clipsChosen ? const SizedBox.shrink()
              : SingleChildScrollView(scrollDirection: Axis.horizontal, child: _clipBar(docked: false)))),
          ...controls,
        ]);
      }),
    );
  }

  Widget _clipBar({required bool docked}) => ClipBar(state: widget.state, docked: docked, selectMode: _selectMode,
    onSelectMode: (v) => setState(() => _selectMode = v),
    onProperties: () => showClipProperties(context, widget.state));

  Widget _tucked(Widget bar) {
    final shown = _sections?.barsShown;
    if (shown == null) return bar;
    return ValueListenableBuilder<bool>(valueListenable: shown,
      builder: (context, v, child) => TuckAway(shown: v || settings, child: child!), child: bar);
  }

  /// Time and height zoom: − and + glide a step, the sliders follow the finger (time on a log scale).
  Widget _zoomBar() {
    final ratio = math.log(maxZoom / minZoom);
    final h = _trackHeight;
    Widget icon(IconData i, String tip, VoidCallback onTap) => IconButton(onPressed: onTap, tooltip: tip,
        visualDensity: VisualDensity.compact, iconSize: 18, icon: Icon(i, color: Neon.dim));
    return SizedBox(height: 36, child: Row(key: const ValueKey('arrange-zoom-bar'), children: [
      const SizedBox(width: 6),
      const Tooltip(message: 'Time zoom', child: Icon(Icons.swap_horiz, size: 16, color: Neon.dim)),
      icon(Icons.remove, 'Zoom out', () => _animateZoom(_zoomAnim.isAnimating ? _zoomTarget / 1.4 : zoom / 1.4)),
      Expanded(flex: 3, child: ResetOnDoubleTap(onReset: () => _animateZoom(18), child: Slider(key: const ValueKey('arrange-zoom-time'),
        value: (math.log(zoom / minZoom) / ratio).clamp(0.0, 1.0).toDouble(),
        onChanged: (v) { _zoomAnim.stop(); _setZoom(minZoom * math.exp(v * ratio)); }))),
      icon(Icons.add, 'Zoom in', () => _animateZoom(_zoomAnim.isAnimating ? _zoomTarget * 1.4 : zoom * 1.4)),
      const SizedBox(width: 6),
      const Tooltip(message: 'Track height', child: Icon(Icons.swap_vert, size: 16, color: Neon.dim)),
      Expanded(flex: 2, child: ResetOnDoubleTap(onReset: () {
        widget.state.settings.update((x) => x.trackHeight = 0).then((_) { if (mounted) setState(() {}); });
      }, child: Slider(key: const ValueKey('arrange-zoom-height'),
        value: h.clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble(),
        min: Settings.minTrackHeight, max: Settings.maxTrackHeight,
        onChanged: (v) => setState(() => _dragTrackH = v),
        onChangeEnd: (_) => _saveHeaderSize()))),
    ]));
  }

  Widget _settingsPanel() {
    final s = widget.state;
    return Flexible(flex: 0, child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
      child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(10, 0, 10, 8), child: Column(children: [
        _ProjectSettings(state: s),
        if (s.globalDefs.isNotEmpty) NeonPanel(color: Neon.blue, child: ParamGroups(
          params: s.globalDefs, color: Neon.blue, valueOf: s.globalValue,
          onChanged: (d, v) => s.setGlobal(d.name, v))),
        // App-wide: how long-press menus open (owner: a list near the finger by default, a ring as a setting).
        Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
          const Expanded(child: Text('Long-press menus', style: TextStyle(color: Neon.dim))),
          SegmentedButton<LongPressMenuStyle>(
            key: const ValueKey('menu-style'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: LongPressMenuStyle.list, icon: Icon(Icons.list, size: 18), tooltip: 'List near the finger'),
              ButtonSegment(value: LongPressMenuStyle.ring, icon: Icon(Icons.donut_large, size: 18), tooltip: 'Ring'),
            ],
            selected: {s.settings.longPressMenu},
            onSelectionChanged: (v) => s.settings.update((x) => x.longPressMenu = v.first)
                .then((_) { if (mounted) setState(() {}); }),
          ),
        ])),
      ])),
    ));
  }

  /// The tracks and their lanes. [pinned]: the focus view's one track, without the empty space under it.
  Widget _timeline(BuildContext context, List<LayerDoc> layers, _TrackCallbacks callbacks, {bool pinned = false}) {
    final s = widget.state;
    final p = s.project;
    final stepW = zoom * (Neon.compact(context) ? 0.85 : 1.0);
    final trackHeight = _trackHeight;
    // The gap between tracks (Settings, chosen from the track height menu), so tracks don't sit on each other.
    final gap = pinned ? 0.0 : s.settings.trackGap;
    final headW = _headerWidth;
    if (!pinned) {
      _stepW = stepW;
      _laneTrackH = trackHeight;
    }
    // The song ends at its last clip or automation point (or the shortest length) and playback loops back there,
    // as in Reaper. The timeline always reaches 64 bars past it, so a clip can go anywhere and the song grows with it.
    final end = p.engineLoopSteps;
    final width = math.max(560.0, math.min(p.maxArrangementSteps, math.max(p.timelineSteps, end + 64 * p.stepsPerBar)) * stepW);
    final ruler = pinned ? 20.0 : 30.0;
    final focusId = _focusId;
    final drag = pinned ? null : _drag;
    // The rows' total height, so the New track zone fills the rest of the view below the last track.
    final rows = layers.fold<double>(0, (h, l) => h + trackHeight + l.automation.length * 34.0
        + (pinned ? 0 : l.spaceBelow) + gap);
    // Two fingers scroll by their average, so a pinch zooms without dragging the view; the pointers are read raw.
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(multitouchDragStrategy: MultitouchDragStrategy.averageBoundaryPointers),
      child: Listener(
      onPointerDown: (e) => _touchDown(e, headW),
      onPointerMove: (e) => _touchMove(e, headW),
      onPointerUp: _touchUp,
      onPointerCancel: _touchUp,
      child: LayoutBuilder(builder: (context, view) {
        // A pixel short of the view, so a few tracks still don't scroll (the lanes' column fills the view anyway).
        final zoneH = math.max(view.maxHeight - ruler - rows - 1, math.max(80.0, trackHeight * 1.5));
        return SingleChildScrollView(key: drag?.vViewport, controller: drag?.vScroll, child: Listener(
        onPointerSignal: (e) => _wheel(e, null),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Stack(children: [SizedBox(width: headW, child: Column(children: [
        SizedBox(height: ruler, child: Padding(
          padding: EdgeInsets.only(left: 10, top: pinned ? 4 : 8),
          child: Align(alignment: Alignment.centerLeft,
            child: Text(pinned ? 'FOCUS · swipe ‹ ›' : 'TRACKS',
              style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3))))),
        for (final layer in layers) ...[
          _TimelineHeader(key: drag?.headerKey(layer.id), state: s, layer: layer, index: p.layers.indexOf(layer),
            drag: drag, onTrackDrag: drag == null ? null : (phase, at) => _trackDrag(layer, phase, at),
            depth: pinned ? 0 : s.folderDepth(layer), trackHeight: trackHeight,
            focused: layer.id == focusId,
            // The pinned track: a tap goes back to all tracks, a sideways swipe to the next or previous one.
            onTap: pinned ? () => _focus(null) : () => callbacks.onTap(layer),
            onSwipe: pinned ? _step : null,
            onFx: () => callbacks.onFx(layer),
            onMenu: (at) => callbacks.onMenu(layer, at),
            onResize: pinned ? null : (dy) => setState(() => _dragTrackH = (_trackHeight + dy)
                .clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble()),
            onResizeEnd: _saveHeaderSize),
          if (layer.spaceBelow > 0 && !pinned) _SpacerHeader(state: s, layer: layer),
          SizedBox(height: gap),
        ],
        if (drag != null) NewTrackZone(key: drag.newTrackHeader, state: s, drag: drag, height: zoneH, header: true),
      ])),
        // The headers' right edge: drag it to make the headers narrower or wider (saved).
        Positioned(right: 0, top: 0, bottom: 0, width: 10, child: _ResizeGrip(
          key: const ValueKey('header-width-grip'), axis: Axis.horizontal, label: 'Resize track headers',
          onDrag: (dx) => setState(() => _dragHeaderW = (_headerWidth + dx)
              .clamp(Settings.minHeaderWidth, Settings.maxHeaderWidth).toDouble()),
          onEnd: _saveHeaderSize)),
      ]),
      Expanded(child: SingleChildScrollView(key: drag?.hViewport, controller: _hScroll, scrollDirection: Axis.horizontal,
        child: Listener(
          onPointerSignal: (e) => _wheel(e, _hScroll.hasClients ? e.localPosition.dx - _hScroll.positions.last.pixels : null),
          child: SizedBox(key: pinned ? null : _lanesBox, width: width, child: Stack(children: [
          // One grid behind every track, through the gaps and spacers and down to the bottom of the view
          // below the last track (owner: like Reaper).
          Positioned(left: 0, right: 0, top: ruler, bottom: 0, child: IgnorePointer(child: CustomPaint(
            painter: _ArrangementGrid(stepW, p.stepsPerBar, _hScroll)))),
          // Where the song ends and playback loops back to the start.
          Positioned(left: end * stepW - 1, top: 0, bottom: 0, width: 2, child: IgnorePointer(
            child: Tooltip(message: 'Song end: playback loops back to the start',
              child: Container(color: Neon.pink.withValues(alpha: 0.7))))),
          ConstrainedBox(constraints: BoxConstraints(minHeight: pinned ? 0 : view.maxHeight), child: Column(children: [
            SizedBox(height: ruler, width: width,
              child: CustomPaint(painter: _BarRuler(stepW, p.stepsPerBar, _hScroll))),
            for (final layer in layers) ...[
              _TimelineLane(key: drag?.laneKey(layer.id), state: s, layer: layer, width: width, stepW: stepW,
                trackHeight: trackHeight, selectedIds: s.selectedClipIds, callbacks: callbacks, drag: drag),
              // A spacer and the gap leave the timeline empty too, so lanes stay level with their headers.
              if (layer.spaceBelow > 0 && !pinned) SizedBox(height: layer.spaceBelow),
              SizedBox(height: gap),
            ],
            if (drag != null) SizedBox(width: width,
              child: NewTrackZone(key: drag.newTrackLane, state: s, drag: drag, height: zoneH, stepW: stepW)),
          ])),
          Positioned.fill(child: IgnorePointer(child: ValueListenableBuilder<int>(
            valueListenable: s.tick,
            builder: (context, _, _) {
              // Stopped, a dimmer line shows where play starts and Split cuts (REAPER's edit cursor).
              final playing = s.meters.playing && s.meters.loopLength > 0;
              return CustomPaint(painter: _PlayheadPainter(stepW,
                playing ? endPosition(s, p, s.meters.loopLength) : s.playheadStep, stopped: !playing));
            },
          ))),
          if (!pinned) Positioned.fill(child: IgnorePointer(child: ValueListenableBuilder<Rect?>(
            valueListenable: _marquee,
            builder: (context, box, _) {
              final me = _lanesBox.currentContext?.findRenderObject();
              if (box == null || me is! RenderBox || !me.attached) return const SizedBox.shrink();
              final local = Rect.fromPoints(me.globalToLocal(box.topLeft), me.globalToLocal(box.bottomRight));
              return CustomPaint(painter: _MarqueePainter(local));
            }))),
        ]))))),
    ])));
      })));
  }

  Widget _arrangement(BuildContext context, _TrackCallbacks callbacks) {
    final s = widget.state;
    final tracks = s.project.layers.isEmpty
        ? const Center(child: Text('Add a track, choose a generator, then add a MIDI clip.'))
        : _timeline(context, s.visibleLayers, callbacks);
    if (!mixerCard) return tracks;
    return LayoutBuilder(builder: (context, box) => Stack(children: [
      Positioned.fill(child: tracks),
      Positioned(left: 6, right: 6, bottom: 6, height: math.min(box.maxHeight - 12, math.max(320.0, box.maxHeight * 0.86)),
        child: SlideIn(from: const Offset(0, 0.15), child: MixerCard(state: s, onClose: () => setState(() => mixerCard = false),
          onSlot: (layer, _) { setState(() => mixerCard = false); _openTrack(layer, tab: FocusTab.fx); }))),
    ]));
  }
}

/// What a track header, lane or clip asks of the arranger.
class _TrackCallbacks {
  const _TrackCallbacks({required this.onTap, required this.onFx, required this.onMenu, required this.onClipMenu,
    required this.onClipOpen, required this.selectMode, required this.onMarquee});
  final ValueChanged<LayerDoc> onTap, onFx;
  final void Function(LayerDoc layer, Offset at) onMenu;
  final void Function(LayerDoc layer, ClipDoc clip, Offset at) onClipMenu;
  final void Function(LayerDoc layer, ClipDoc clip) onClipOpen;

  /// Whether Select mode is on: a tap on a clip adds or removes it, a long-press drag in a lane draws a box.
  final bool Function() selectMode;

  /// A marquee's start, move and end, in global coordinates; [additive] adds to the selection.
  final void Function(_Marquee phase, Offset at, bool additive) onMarquee;
}

enum _Marquee { start, move, end }

/// A compact track header (owner, 2026-11-09): name, M, S and FX always show; record-arm, input, the instrument and
/// the rest are in the long-press menu (right-click on a desktop). A tap opens the track's focus view. The selected
/// or focused track glows in its own colour, brighter.
class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader({super.key, required this.state, required this.layer, required this.index, required this.depth,
    required this.trackHeight, required this.onTap, required this.onFx, required this.onMenu,
    this.focused = false, this.onSwipe, this.onResize, this.onResizeEnd, this.drag, this.onTrackDrag});
  final AppState state;
  final LayerDoc layer;
  final int index, depth;
  final double trackHeight;
  final bool focused;
  final VoidCallback onTap, onFx;
  final void Function(Offset at) onMenu;
  final ValueChanged<int>? onSwipe;

  /// A drag on the row's bottom edge, by this many pixels; null on the focus view's pinned track.
  final ValueChanged<double>? onResize;
  final VoidCallback? onResizeEnd;

  /// Dragging the header moves the track (REAPER): a long press then a move on a touch screen (a long press
  /// released without moving opens the menu), a plain drag with a mouse. Null on the pinned track.
  final ArrangeDrag? drag;
  final void Function(_HeaderPhase phase, Offset at)? onTrackDrag;

  @override
  Widget build(BuildContext context) {
    final color = trackColor(state, layer);
    final selected = focused || state.selectedLayerId == layer.id;
    final gens = state.project.modules.where((m) => state.isGenerator(m.id)).toList();
    final fxCount = layer.effectIds.length + layer.components.length;
    final thin = trackHeight < 52;
    // REAPER-style (owner, 2026-11-10): the track's colour tints the whole header and its left edge, no outline.
    final edge = BorderSide(color: selected ? color : color.withValues(alpha: 0.75), width: selected ? 4 : 3);
    final box = Container(height: trackHeight + layer.automation.length * 34.0,
      padding: EdgeInsets.fromLTRB(6 + depth * 10, thin ? 2 : 4, 2, thin ? 2 : 4),
      decoration: Glass.active
          ? BoxDecoration(
              gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [
                Color.lerp(Neon.panel, color, selected ? 0.42 : 0.26)!.withValues(alpha: 0.82),
                Color.lerp(Neon.panel, color, selected ? 0.20 : 0.10)!.withValues(alpha: 0.66),
              ]),
              border: Border(
                left: edge,
                bottom: BorderSide(color: Colors.black.withValues(alpha: 0.35)),
                right: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
              ),
              boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.28), blurRadius: 12)] : null)
          : BoxDecoration(color: Color.lerp(Neon.panel, color, selected ? 0.30 : 0.16),
              border: Border(left: edge, bottom: const BorderSide(color: Neon.bg))),
      child: LayoutBuilder(builder: (context, box) {
        final oneRow = box.maxHeight < 56;
        final chip = box.maxWidth < 150 ? 24.0 : 30.0;
        final mute = ToggleChip(label: 'M', size: chip, tooltip: layer.isFolder ? 'Mute folder' : 'Mute',
            on: layer.mute, color: Neon.yellow,
            onTap: () => layer.isFolder
                ? state.editLayer(layer, (l) => l.mute = !l.mute)
                : state.mixLayer(layer, mute: !layer.mute));
        final solo = ToggleChip(label: 'S', size: chip, tooltip: layer.isFolder ? 'Solo folder' : 'Solo',
            on: layer.solo, color: Neon.blue,
            onTap: () => layer.isFolder
                ? state.editLayer(layer, (l) => l.solo = !l.solo)
                : state.mixLayer(layer, solo: !layer.solo));
        // A stereo track (a native instrument or effect, or a folder) meters each side; a .caw track one bar.
        final meter = TrackMeter(key: ValueKey('meter-${layer.id}'), state: state, index: index, stereo: layer.isStereo,
            color: color);
        // FX: drawn at 18 dp, touched over about 34 dp; a dot tells the track has effects. A very narrow header
        // drops it: a tap on the header opens the track's effects too.
        final showFx = box.maxWidth >= 104;
        final fx = layer.isFolder
            ? Tooltip(message: layer.busEnabled ? 'Folder with a group bus' : 'Folder',
                child: SizedBox(width: 26, height: 26, child: Icon(Icons.account_tree_outlined, size: 15, color: color)))
            : Tooltip(message: 'Effects', child: InkResponse(
                key: ValueKey('fx-button-${layer.id}'),
                radius: 20,
                onTap: onFx,
                child: SizedBox(width: 30, height: 26, child: Stack(alignment: Alignment.center, children: [
                  Icon(Icons.graphic_eq, size: 18, color: fxCount > 0 ? color : Neon.dim),
                  if (fxCount > 0) Positioned(right: 3, top: 2, child: Container(width: 5, height: 5,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
                ]))));
        final top = SizedBox(height: thin ? 24 : 28, child: Row(children: [
          if (layer.isFolder)
            IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              // 24 px wide: a padded 48 px target overflowed a phone's one-row folder header.
              style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              tooltip: layer.collapsed ? 'Show folder' : 'Hide folder',
              icon: Icon(layer.collapsed ? Icons.chevron_right : Icons.expand_more, color: color, size: 18),
              onPressed: () => state.setFolderCollapsed(layer, !layer.collapsed)),
          const SizedBox(width: 3),
          Expanded(child: Tooltip(
            message: layer.isFolder
                ? (layer.busEnabled ? 'Folder with a group bus' : 'Folder')
                : 'Instrument: ${layer.instrument != null ? state.componentInfo(layer.instrument!.id)?.label ?? layer.instrument!.id
                    : gens.where((g) => g.id == layer.generatorId).firstOrNull?.name ?? 'none'} · hold for more',
            child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: Color.lerp(Neon.text, color, selected ? 0.35 : 0.15))))),
          if (oneRow) ...[mute, const SizedBox(width: 2), solo],
          if (showFx || layer.isFolder) fx,
        ]));
        if (oneRow) {
          return Column(mainAxisSize: MainAxisSize.min, children: [top, SizedBox(height: thin ? 2 : 4), meter]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          top,
          const SizedBox(height: 4),
          SizedBox(height: 26, child: Row(children: [
            mute,
            const SizedBox(width: 3),
            solo,
            const SizedBox(width: 8),
            Expanded(child: meter),
            const SizedBox(width: 4),
          ])),
        ]);
      }),
    );
    // Where a dragged track would land on this one: a line above or below it, or the folder lit up.
    final target = drag == null ? box : ValueListenableBuilder<DragSpot?>(
      valueListenable: drag!.hover,
      builder: (context, spot, child) {
        final here = drag!.active && spot?.layerId == layer.id && drag!.dragsTrack;
        if (!here) return child!;
        final into = spot!.where == TrackDrop.into;
        return Stack(children: [
          child!,
          if (into) Positioned.fill(child: IgnorePointer(child: DecoratedBox(key: const ValueKey('track-drop-into'),
            decoration: BoxDecoration(border: Border.all(color: Neon.green, width: 2),
              color: Neon.green.withValues(alpha: 0.10)))))
          else Positioned(left: 0, right: 0, height: 3, top: spot.where == TrackDrop.above ? 0 : null,
            bottom: spot.where == TrackDrop.below ? 0 : null,
            child: IgnorePointer(child: Container(key: const ValueKey('track-drop-line'), color: Neon.green))),
        ]);
      },
      child: box);
    final resizable = onResize == null ? target : Stack(children: [
      target,
      // The row's bottom edge: drag it to make every track thinner or taller (saved).
      Positioned(left: 0, right: 0, bottom: 0, height: 8, child: _ResizeGrip(
        key: ValueKey('track-height-grip-${layer.id}'), axis: Axis.vertical, label: 'Resize tracks',
        onDrag: onResize!, onEnd: onResizeEnd ?? () {})),
    ]);
    return Semantics(
      button: true,
      selected: selected,
      label: '${layer.name} track',
      child: GestureDetector(
        key: ValueKey('track-header-${layer.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPressStart: (d) => onTrackDrag == null ? onMenu(d.globalPosition) : onTrackDrag!(_HeaderPhase.press, d.globalPosition),
        onLongPressMoveUpdate: onTrackDrag == null ? null : (d) => onTrackDrag!(_HeaderPhase.move, d.globalPosition),
        onLongPressEnd: onTrackDrag == null ? null : (d) => onTrackDrag!(_HeaderPhase.release, d.globalPosition),
        onLongPressCancel: onTrackDrag == null ? null : () => onTrackDrag!(_HeaderPhase.cancel, Offset.zero),
        onSecondaryTapUp: (d) => onMenu(d.globalPosition),
        onHorizontalDragEnd: onSwipe == null ? null : (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() > 200) onSwipe!(v < 0 ? 1 : -1);
        },
        // A mouse drags the header straight away; a finger's vertical drag still scrolls the tracks.
        child: onTrackDrag == null ? resizable : GestureDetector(
          supportedDevices: const {PointerDeviceKind.mouse},
          onVerticalDragStart: (d) => onTrackDrag!(_HeaderPhase.grab, d.globalPosition),
          onVerticalDragUpdate: (d) => onTrackDrag!(_HeaderPhase.move, d.globalPosition),
          onVerticalDragEnd: (_) => onTrackDrag!(_HeaderPhase.release, Offset.zero),
          onVerticalDragCancel: () => onTrackDrag!(_HeaderPhase.cancel, Offset.zero),
          child: resizable),
      ),
    );
  }
}

/// A track header's drag, as the header reports it: a long press ([press]) that may become a drag once it moves, or
/// a mouse drag ([grab]) that is one at once.
enum _HeaderPhase { press, grab, move, release, cancel }

/// A thin edge that resizes something when dragged: a faint grip line shows where it is, and the mouse cursor
/// changes over it on a desktop.
class _ResizeGrip extends StatefulWidget {
  const _ResizeGrip({super.key, required this.axis, required this.label, required this.onDrag, required this.onEnd});

  /// [Axis.horizontal]: dragged sideways (a width); [Axis.vertical]: dragged up and down (a height).
  final Axis axis;
  final String label;
  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;
  @override
  State<_ResizeGrip> createState() => _ResizeGripState();
}

class _ResizeGripState extends State<_ResizeGrip> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final sideways = widget.axis == Axis.horizontal;
    final line = Container(
      width: sideways ? 2 : 22, height: sideways ? 22 : 2,
      decoration: BoxDecoration(color: (_active ? Neon.blue : Neon.dim).withValues(alpha: _active ? 0.9 : 0.35),
        borderRadius: BorderRadius.circular(1)));
    void start() => setState(() => _active = true);
    void update(double d) => widget.onDrag(d);
    void end() { setState(() => _active = false); widget.onEnd(); }
    return Semantics(label: widget.label, child: Tooltip(message: widget.label, waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: sideways ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The edge follows the finger from where it went down, slop included.
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: sideways ? (_) => start() : null,
          onHorizontalDragUpdate: sideways ? (d) => update(d.delta.dx) : null,
          onHorizontalDragEnd: sideways ? (_) => end() : null,
          onVerticalDragStart: sideways ? null : (_) => start(),
          onVerticalDragUpdate: sideways ? null : (d) => update(d.delta.dy),
          onVerticalDragEnd: sideways ? null : (_) => end(),
          child: Align(alignment: sideways ? Alignment.center : Alignment.bottomCenter, child: line)))));
  }
}

/// The space above and below a clip in its row.
double _clipInset(double trackHeight) => trackHeight < 60 ? 3 : 8;

class _TimelineLane extends StatefulWidget {
  const _TimelineLane({super.key, required this.state, required this.layer, required this.width,
    required this.stepW, required this.trackHeight, required this.selectedIds, required this.callbacks, this.drag});
  final AppState state;
  final LayerDoc layer;
  final double width, stepW, trackHeight;
  final Set<String> selectedIds;
  final _TrackCallbacks callbacks;

  /// Null on the pinned track, where clips only move in time.
  final ArrangeDrag? drag;

  @override
  State<_TimelineLane> createState() => _TimelineLaneState();
}

class _TimelineLaneState extends State<_TimelineLane> {
  /// A Ctrl+drag with the mouse in empty space draws a new empty clip (REAPER): from, to, in steps.
  (int, int)? _drawing;
  int? _doubleTapStep;

  AppState get state => widget.state;
  LayerDoc get layer => widget.layer;
  int get _snap => state.arrangementSnapSteps;
  int _snapped(double x, {bool up = false}) {
    final raw = math.max(0, (x / widget.stepW).floor());
    if (HardwareKeyboard.instance.isShiftPressed) return raw;
    return up ? ((raw + _snap) ~/ _snap) * _snap : (raw ~/ _snap) * _snap;
  }

  /// REAPER's right-drag in the arrange view draws a marquee around items; Shift adds to the selection (UG 15.x mouse
  /// modifiers, "Arrange view, right drag").
  bool _marquee = false;

  void _drawDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
      _marquee = true;
      widget.callbacks.onMarquee(_Marquee.start, e.position, HardwareKeyboard.instance.isShiftPressed);
      return;
    }
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryMouseButton ||
        !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    final at = _snapped(e.localPosition.dx);
    setState(() => _drawing = (at, at + _snap));
  }

  void _drawMove(PointerMoveEvent e) {
    if (_marquee) return widget.callbacks.onMarquee(_Marquee.move, e.position, false);
    final d = _drawing;
    if (d == null) return;
    final to = math.max(d.$1 + 1, _snapped(e.localPosition.dx, up: true));
    if (to != d.$2) setState(() => _drawing = (d.$1, to));
  }

  void _drawUp(PointerEvent e) {
    if (_marquee) {
      _marquee = false;
      return widget.callbacks.onMarquee(_Marquee.end, e.position, false);
    }
    final d = _drawing;
    if (d == null) return;
    setState(() => _drawing = null);
    if (e is PointerUpEvent) state.addEmptyClip(layer, d.$1, d.$2 - d.$1);
  }

  @override
  Widget build(BuildContext context) {
    final trackHeight = widget.trackHeight, stepW = widget.stepW;
    final height = trackHeight + layer.automation.length * 34.0;
    final color = trackColor(state, layer);
    // A dropped effect or instrument goes on this track (an instrument asks before replacing one); a dropped
    // pattern or MIDI file becomes clips where it lands. On a folder, its first track inside takes it.
    final lane = DragTarget<AssetDrag>(
      onAcceptWithDetails: (d) {
        final box = context.findRenderObject() as RenderBox?;
        final x = box == null ? 0.0 : box.globalToLocal(d.offset).dx;
        dropOnTrack(context, state, layer, d.data, atStep: math.max(0, (x / stepW).floor()));
      },
      builder: (context, hovering, _) => SizedBox(width: widget.width, height: height,
    child: Stack(children: [
      Positioned.fill(child: Listener(
        onPointerDown: _drawDown,
        onPointerMove: _drawMove,
        onPointerUp: _drawUp,
        onPointerCancel: _drawUp,
        child: GestureDetector(behavior: HitTestBehavior.opaque,
        // A plain horizontal drag belongs to the enclosing scroll view. Long-press
        // drag creates a time selection without stealing normal timeline navigation.
        // A tap sets the edit cursor; stopped, play then starts there and Split cuts there (REAPER).
        onTapUp: (d) {
          final step = (d.localPosition.dx / stepW).round();
          state.setTimeSelection(step, step);
          if (!state.meters.playing) state.seekTo(step.toDouble());
        },
        // A double-tap in empty space draws a one-bar empty clip there (the touch stand-in for REAPER's Ctrl+drag).
        onDoubleTapDown: (d) => _doubleTapStep = _snapped(d.localPosition.dx),
        onDoubleTap: () {
          final at = _doubleTapStep;
          if (at != null) state.addEmptyClip(layer, at, state.project.stepsPerBar);
        },
        // In Select mode a long-press drag draws a box around clips instead of a time selection.
        onLongPressStart: (d) => widget.callbacks.selectMode()
            ? widget.callbacks.onMarquee(_Marquee.start, d.globalPosition, true)
            : state.beginTimeSelection((d.localPosition.dx / stepW).round()),
        onLongPressMoveUpdate: (d) => widget.callbacks.selectMode()
            ? widget.callbacks.onMarquee(_Marquee.move, d.globalPosition, true)
            : state.updateTimeSelection((d.localPosition.dx / stepW).round()),
        onLongPressEnd: (d) => widget.callbacks.selectMode()
            ? widget.callbacks.onMarquee(_Marquee.end, d.globalPosition, true)
            : state.endTimeSelection(),
        child: hovering.isEmpty ? const SizedBox.expand()
            : DecoratedBox(decoration: BoxDecoration(color: color.withValues(alpha: 0.12),
                border: Border.all(color: color)))))),
      if (state.timeSelectionStart != null && state.timeSelectionEnd != null)
        Positioned(left: math.min(state.timeSelectionStart!, state.timeSelectionEnd!) * stepW, top: 0,
          width: math.max(1.0, (state.timeSelectionEnd! - state.timeSelectionStart!).abs() * stepW), height: height,
          child: IgnorePointer(child: Container(color: Neon.blue.withValues(alpha: .09)))),

      for (final clip in layer.clips)
        Positioned(left: clip.startSteps * stepW, top: _clipInset(trackHeight),
          width: math.max(12.0, clip.lengthSteps * stepW), height: trackHeight - 2 * _clipInset(trackHeight),
          child: _TimelineClip(state: state, layer: layer, clip: clip, stepW: stepW, drag: widget.drag,
            color: clip.color == null ? color : Neon.layer(clip.color!),
            selected: widget.selectedIds.contains(clip.id), callbacks: widget.callbacks)),
      if (_drawing case (final from, final to))
        Positioned(left: from * stepW, top: _clipInset(trackHeight), width: (to - from) * stepW,
          height: trackHeight - 2 * _clipInset(trackHeight), child: IgnorePointer(child: DecoratedBox(
            key: const ValueKey('clip-draw-preview'),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: color.withValues(alpha: 0.18),
              border: Border.all(color: color))))),
      if (layer.clips.isEmpty && !layer.isFolder)
        Positioned(left: 10, top: trackHeight * 0.38, child: const IgnorePointer(child: Text(
          'Double-tap for a clip, or drop a pattern here', style: TextStyle(color: Neon.dim, fontSize: 10)))),
      for (var i = 0; i < layer.automation.length; i++)
        Positioned(left: 0, right: 0, top: trackHeight + i * 34.0, height: 34,
          child: _AutomationLaneView(state: state, layer: layer, lane: layer.automation[i], stepW: stepW, width: widget.width)),
    ]),
  ));
    final drag = widget.drag;
    if (drag == null) return lane;
    // A clip dragged over this lane lights it up (its ghost shows where it lands).
    return ValueListenableBuilder<DragSpot?>(
      valueListenable: drag.hover,
      builder: (context, spot, child) {
        final here = drag.active && !drag.dragsTrack && spot?.layerId == layer.id;
        return Stack(children: [
          child!,
          if (here) Positioned.fill(child: IgnorePointer(child: DecoratedBox(key: ValueKey('lane-target-${layer.id}'),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.10),
              border: Border.all(color: color.withValues(alpha: 0.9), width: 1.5))))),
        ]);
      },
      child: lane);
  }
}

/// A spacer under a track (owner, 2026-11-04): an empty row that only separates tracks on screen. Drag its bottom
/// edge to change its height; × removes it. The engine never sees it.
class _SpacerHeader extends StatelessWidget {
  const _SpacerHeader({required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  /// A new spacer's height.
  static const initial = 24.0;

  @override
  Widget build(BuildContext context) {
    final h = layer.spaceBelow;
    return SizedBox(
      height: h,
      child: Stack(children: [
        Center(child: Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 12),
          color: Neon.line.withValues(alpha: 0.6))),
        if (h >= 20) Positioned(right: 0, top: 0, bottom: 0, child: IconButton(
          tooltip: 'Remove spacer', iconSize: 14, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, color: Neon.dim),
          onPressed: () => state.setSpaceBelow(layer, 0))),
        Positioned(left: 0, right: 40, bottom: 0, height: h < 16 ? h : 16, child: Semantics(
          label: 'Resize spacer',
          child: MouseRegion(cursor: SystemMouseCursors.resizeRow, child: GestureDetector(
            key: ValueKey('spacer-grip-${layer.id}'),
            behavior: HitTestBehavior.opaque,
            // Follows the finger from where it went down, though the tracks can scroll (the New track zone).
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragUpdate: (d) => state.setSpaceBelow(layer, (layer.spaceBelow + d.delta.dy).clamp(8.0, LayerDoc.maxSpaceBelow)),
            child: Center(child: Container(width: 28, height: 3,
              decoration: BoxDecoration(color: Neon.dim.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(2)))),
          )),
        )),
      ]),
    );
  }
}
/// The part of a timeline [size] wide that [scroll] shows, in pixels (all of it, up to 4096 px, before layout).
(double, double) visibleSpan(ScrollController scroll, Size size) {
  if (!scroll.hasClients) return (0, math.min(size.width, 4096));
  // While the focus view swaps one timeline for another, the old one is attached for a frame too: use the newest.
  final position = scroll.positions.last;
  final from = position.pixels.clamp(0.0, size.width).toDouble();
  return (from, (position.pixels + position.viewportDimension).clamp(from, size.width).toDouble());
}

class _ArrangementGrid extends CustomPainter {
  _ArrangementGrid(this.stepW, this.barSteps, this.scroll) : super(repaint: scroll);
  final double stepW;
  final int barSteps;
  final ScrollController scroll;
  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()..color = Neon.line.withValues(alpha: .55)..strokeWidth = .6;
    final major = Paint()..color = Neon.dim.withValues(alpha: .35)..strokeWidth = 1;
    final (from, to) = visibleSpan(scroll, size);
    // Zoomed out, the minor lines thin to beats, then to bars only, so they stay at least 5 px apart.
    final every = stepW >= 5 ? 1 : stepW * 4 >= 5 ? 4 : barSteps;
    for (var n = (from / stepW / every).floor() * every; n * stepW <= to; n += every) {
      final x = n * stepW;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), n % barSteps == 0 ? major : minor);
    }
  }
  @override
  bool shouldRepaint(covariant _ArrangementGrid old) =>
      old.stepW != stepW || old.barSteps != barSteps || old.scroll != scroll;
}

class _BarRuler extends CustomPainter {
  _BarRuler(this.stepW, this.barSteps, this.scroll) : super(repaint: scroll);
  final double stepW;
  final int barSteps;
  final ScrollController scroll;
  @override
  void paint(Canvas canvas, Size size) {
    final barW = barSteps * stepW;
    final (from, to) = visibleSpan(scroll, size);
    // A label every bar, or every 2, 4, 8… bars when bars are narrower than a label.
    var every = 1;
    while (every * barW < 28 && every < 1 << 16) {
      every *= 2;
    }
    for (var b = (from / barW / every).floor() * every; b * barW <= to; b += every) {
      final label = TextPainter(text: TextSpan(text: '${b + 1}', style: Neon.code(size: 10, color: Neon.dim)),
        textDirection: TextDirection.ltr, maxLines: 1)..layout(maxWidth: math.max(1.0, every * barW - 2));
      label.paint(canvas, Offset(b * barW, (size.height - label.height) / 2));
      label.dispose();
    }
  }
  @override
  bool shouldRepaint(covariant _BarRuler old) => old.stepW != stepW || old.barSteps != barSteps || old.scroll != scroll;
}

class _PlayheadPainter extends CustomPainter {
  const _PlayheadPainter(this.stepW, this.step, {this.stopped = false});
  final double stepW, step;
  final bool stopped;

  @override
  void paint(Canvas canvas, Size size) {
    if (step < 0) return;
    final x = step * stepW;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height),
      Paint()..color = stopped ? Neon.blue.withValues(alpha: 0.45) : Neon.blue..strokeWidth = stopped ? 1.2 : 1.6);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter old) => old.step != step || old.stepW != stepW || old.stopped != stopped;
}

/// The marquee box being drawn around clips.
class _MarqueePainter extends CustomPainter {
  const _MarqueePainter(this.box);
  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(box, Paint()..color = Neon.blue.withValues(alpha: 0.12));
    canvas.drawRect(box, Paint()..color = Neon.blue.withValues(alpha: 0.8)..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter old) => old.box != box;
}


class _TimelineClip extends StatefulWidget {
  const _TimelineClip({required this.state, required this.layer, required this.clip,
    required this.stepW, required this.color, required this.selected, required this.callbacks, this.drag});
  final AppState state;
  final LayerDoc layer;
  final ClipDoc clip;
  final double stepW;
  final Color color;
  final bool selected;
  final _TrackCallbacks callbacks;
  final ArrangeDrag? drag;
  @override
  State<_TimelineClip> createState() => _TimelineClipState();
}

/// What a dragged clip's ghost shows: where it lands, in its target's colour, and whether it is a copy.
typedef _Ghost = ({Rect rect, Rect clip, Color color, bool copy});

class _TimelineClipState extends State<_TimelineClip> {
  double dx = 0, resizeDx = 0, trimDx = 0;
  (bool, bool) _tapKeys = (false, false);
  bool dragging = false, resizing = false, trimming = false, sourceDragging = false;
  int? _lastSnap;

  // A body drag (REAPER: drag an item to move it, to another track too; Ctrl-drag copies it).
  Offset _from = Offset.zero, _pointer = Offset.zero;
  double _scroll0 = 0;
  bool _ignored = false;
  OverlayEntry? _ghost;
  final _ghostState = ValueNotifier<_Ghost?>(null);

  int get _snap => widget.state.arrangementSnapSteps;
  bool get _free => HardwareKeyboard.instance.isShiftPressed;
  ArrangeDrag? get _drag => widget.drag;
  bool get _copy => HardwareKeyboard.instance.isControlPressed || (_drag?.copy.value ?? false);
  double get _scrolled {
    final h = _drag?.hScroll;
    return h == null || !h.hasClients ? 0 : h.positions.last.pixels - _scroll0;
  }

  /// Where a move ends, in steps: on the grid unless Shift is held.
  int _moveTarget() {
    final raw = ((dx + _scrolled) / widget.stepW).round();
    if (sourceDragging) return _free ? raw : (raw / _snap).round() * _snap;
    final rawStart = widget.clip.startSteps + raw;
    return _free ? rawStart : (rawStart / _snap).round() * _snap;
  }

  /// Where a left-edge trim puts the clip's start.
  int _trimTarget() {
    final raw = widget.clip.startSteps + (trimDx / widget.stepW).round();
    return _free ? raw : (raw / _snap).round() * _snap;
  }

  /// A light tick each time the clip lands on another grid line (owner: haptics on grid snaps).
  void _tickOnSnap(int at) {
    if (_lastSnap != null && _lastSnap != at) Motion.tick();
    _lastSnap = at;
  }

  @override
  void dispose() {
    _removeGhost();
    _ghostState.dispose();
    super.dispose();
  }

  void _removeGhost() {
    _ghost?.remove();
    _ghost = null;
  }

  void _start(DragStartDetails d) {
    _ignored = (_drag?.pinching ?? false) || widget.clip.lock;
    if (_ignored) return;
    setState(() {
      dragging = true;
      sourceDragging = HardwareKeyboard.instance.isAltPressed;
      dx = 0;
      _lastSnap = null;
    });
    _from = _pointer = d.globalPosition;
    final h = _drag?.hScroll;
    _scroll0 = h == null || !h.hasClients ? 0 : h.positions.last.pixels;
    final drag = _drag;
    if (drag == null || sourceDragging) return;
    drag.begin(onScroll: _follow, onCancel: _cancel);
    drag.copy.addListener(_follow);
    _ghost = OverlayEntry(builder: (_) => _GhostView(ghost: _ghostState, name: _name));
    Overlay.of(context).insert(_ghost!);
    _follow();
  }

  String get _name {
    final name = widget.state.clipName(widget.clip);
    final others = _together ? widget.state.selectedClipIds.length - 1 : 0;
    return others > 0 && dragging ? '$name +$others' : name;
  }

  /// This drag moves every selected clip (the grabbed one is among several selected), as REAPER moves a selection.
  bool get _together => widget.selected && widget.state.selectedClipIds.length > 1;

  void _update(DragUpdateDetails d) {
    if (_ignored || !dragging) return;
    _pointer = d.globalPosition;
    dx = _pointer.dx - _from.dx;
    _drag?.point(_pointer);
    _follow();
  }

  /// Follows the pointer (and the view, while it scrolls at an edge): the lane under it, the snapped time, the ghost.
  void _follow() {
    if (!mounted || !dragging) return;
    final at = _moveTarget();
    _tickOnSnap(at);
    final drag = _drag;
    if (drag == null || sourceDragging) {
      setState(() {});
      return;
    }
    final spot = drag.spotAt(_pointer);
    drag.hover.value = spot;
    final lane = spot == null ? drag.laneRect(widget.layer.id)
        : spot.newTrack ? ArrangeDrag.rectOf(drag.newTrackLane) : drag.laneRect(spot.layerId!);
    final box = context.findRenderObject() as RenderBox?;
    final view = ArrangeDrag.rectOf(drag.hViewport);
    final vview = ArrangeDrag.rectOf(drag.vViewport);
    if (lane == null || box == null || view == null || vview == null) return;
    final target = spot?.layerId == null ? null
        : widget.state.project.layers.where((l) => l.id == spot!.layerId).firstOrNull;
    // As high in the target lane as the clip sits in its own.
    final own = drag.laneRect(widget.layer.id);
    final inset = own == null ? 4.0 : box.localToGlobal(Offset.zero).dy - own.top;
    _ghostState.value = (
      rect: Rect.fromLTWH(lane.left + at * widget.stepW, lane.top + (spot?.newTrack ?? false ? 4 : inset),
          box.size.width, box.size.height),
      clip: view.intersect(vview),
      color: spot?.newTrack ?? false ? Neon.green : target == null ? widget.color : trackColor(widget.state, target),
      copy: _copy,
    );
    setState(() {});
  }

  void _end(DragEndDetails _) {
    if (_ignored || !dragging) return;
    final c = widget.clip;
    final at = _moveTarget();
    final drag = _drag;
    if (sourceDragging) {
      widget.state.shiftClipSource(widget.layer, c, at);
    } else if (drag == null) {
      widget.state.moveClip(widget.layer, c, at);
    } else {
      final spot = drag.hover.value;
      final copy = _copy;
      final target = spot == null || spot.newTrack ? null
          : widget.state.project.layers.where((l) => l.id == spot.layerId).firstOrNull;
      if (_together) {
        // Several selected clips move (or copy) together, by the same time and number of tracks.
        widget.state.moveSelectedClips(widget.layer, c, spot == null || spot.newTrack ? widget.layer : target, at,
          copy: copy);
      } else if (spot == null || (!spot.newTrack && target == null)) {
        widget.state.moveClip(widget.layer, c, at);
      } else {
        widget.state.moveClipTo(widget.layer, c, target, at, copy: copy);
      }
    }
    _finish();
  }

  /// Escape (or a cancelled gesture): the clip stays where it was.
  void _cancel() => _finish();

  void _finish() {
    _removeGhost();
    _ghostState.value = null;
    _drag?.copy.removeListener(_follow);
    if (dragging && !sourceDragging) _drag?.end();
    if (mounted) setState(() { dragging = false; sourceDragging = false; dx = 0; _lastSnap = null; });
    _ignored = true; // the rest of this gesture does nothing
  }

  Widget _edge({required bool left}) => Positioned(left: left ? 0 : null, right: left ? null : 0, top: 0, bottom: 0,
    width: 12,
    child: widget.clip.lock ? const SizedBox.shrink() : MouseRegion(cursor: SystemMouseCursors.resizeColumn, child: GestureDetector(behavior: HitTestBehavior.opaque,
      // The edge follows the finger from where it went down, slop included.
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (_) => setState(() {
        if (left) { trimming = true; trimDx = 0; } else { resizing = true; resizeDx = 0; }
        _lastSnap = null;
      }),
      onHorizontalDragUpdate: (d) => setState(() {
        final c = widget.clip;
        if (left) {
          trimDx += d.delta.dx;
          _tickOnSnap(_trimTarget());
        } else {
          resizeDx += d.delta.dx;
          final raw = c.lengthSteps + (resizeDx / widget.stepW).round();
          _tickOnSnap(_free ? raw : (raw / _snap).round() * _snap);
        }
      }),
      onHorizontalDragEnd: (_) {
        if (left) {
          widget.state.trimClipStart(widget.layer, widget.clip, _trimTarget());
        } else {
          widget.state.resizeClip(widget.layer, widget.clip, _resizedLength());
        }
        setState(() { resizing = trimming = false; resizeDx = trimDx = 0; _lastSnap = null; });
      },
      child: Center(child: Container(key: ValueKey('clip-${left ? 'start' : 'end'}-${widget.clip.id}'),
        width: 2, height: 22, color: widget.color)))));

  int _resizedLength() {
    final c = widget.clip;
    final rawLength = c.lengthSteps + (resizing ? (resizeDx / widget.stepW).round() : 0);
    return (resizing && !_free ? math.max(_snap, (rawLength / _snap).round() * _snap) : rawLength)
        .clamp(1, widget.state.project.maxArrangementSteps - c.startSteps).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    var start = c.startSteps, length = _resizedLength();
    if (trimming) {
      final end = c.startSteps + c.lengthSteps;
      start = _trimTarget().clamp(math.max(0, c.startSteps - c.sourceOffsetSteps), end - 1).toInt();
      length = end - start;
    }
    final name = _name;
    // On the pinned track the clip itself slides in time; elsewhere its ghost shows where it goes and it stays dim.
    final shown = dragging && !sourceDragging && _drag == null ? (_moveTarget() - c.startSteps) * widget.stepW : 0.0;
    final ghosted = dragging && !sourceDragging && _drag != null && !_copy;
    // The body drags in any direction from the first few pixels, before the scroll views take the gesture.
    final mq = MediaQuery.of(context);
    return Opacity(opacity: ghosted ? 0.35 : c.mute ? 0.45 : 1,
      child: Transform.translate(offset: Offset(shown + (start - c.startSteps) * widget.stepW, 0),
      child: Transform.scale(scaleX: length / c.lengthSteps,
        alignment: Alignment.centerLeft,
        child: Material(color: Glass.active ? Colors.transparent : widget.color.withValues(alpha: widget.selected ? .42 : .23),
          borderRadius: BorderRadius.circular(5),
          child: Stack(children: [
        Positioned.fill(child: MediaQuery(
          data: mq.copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: kTouchSlop / 2)),
          // The modifiers count as they were when the click went down: the tap itself comes after the double-tap wait.
          child: Listener(onPointerDown: (_) =>
              _tapKeys = (HardwareKeyboard.instance.isControlPressed, HardwareKeyboard.instance.isShiftPressed),
          child: GestureDetector(
          key: ValueKey('clip-${c.id}'),
          onLongPressStart: (d) => widget.callbacks.onClipMenu(widget.layer, c, d.globalPosition),
          onSecondaryTapUp: (d) => widget.callbacks.onClipMenu(widget.layer, c, d.globalPosition),
          onTap: () {
            final (ctrl, shift) = _tapKeys;
            // REAPER (UG 7.2.1): Ctrl-click adds or removes a clip, Shift-click selects the range to it. A tap in
            // Select mode adds or removes it, the phone's way.
            if (ctrl || widget.callbacks.selectMode()) {
              widget.state.toggleClipSelection(widget.layer, c);
            } else if (shift) {
              widget.state.selectClipRange(widget.layer, c);
            } else if (widget.state.selectedClipIds.contains(c.id)) {
              widget.state.activateClip(widget.layer, c);
            } else {
              widget.state.selectClip(widget.layer, c);
            }
          },
          // A clip's notes open in the Clip tab of the focus view (owner, 2026-11-09; REAPER: a MIDI item's
          // double-click opens the MIDI editor).
          onDoubleTap: () => widget.callbacks.onClipOpen(widget.layer, c),
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: _start,
          onPanUpdate: _update,
          onPanEnd: _end,
          onPanCancel: () { if (dragging) _cancel(); },
          child: Container(
            // Glass: a faint fill that is lighter at the top, and a solid outline in the track's colour; the
            // selected clip glows in that colour, brighter.
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5),
              gradient: Glass.active
                  ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
                      widget.color.withValues(alpha: widget.selected ? .40 : .26),
                      widget.color.withValues(alpha: widget.selected ? .24 : .12),
                    ])
                  : null,
              boxShadow: widget.selected ? [BoxShadow(color: widget.color.withValues(alpha: .35), blurRadius: 8)] : null,
              border: Border.all(
                color: Glass.active || widget.selected ? widget.color : widget.color.withValues(alpha: .7),
                width: widget.selected ? 1.6 : 1)),
            padding: const EdgeInsets.fromLTRB(13, 4, 13, 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: widget.color, fontSize: 10, fontWeight: FontWeight.w800)),
              Expanded(child: Align(alignment: Alignment.bottomLeft,
                child: Row(children: [
                  if (c.lock) Icon(Icons.lock, key: ValueKey('clip-locked-${c.id}'), size: 9, color: widget.color),
                  if (c.mute) Icon(Icons.volume_off, key: ValueKey('clip-muted-${c.id}'), size: 9, color: widget.color),
                  Flexible(child: Text(c.loop ? 'MIDI · LOOP' : 'MIDI', maxLines: 1, overflow: TextOverflow.clip,
                    style: TextStyle(color: widget.color.withValues(alpha: .8), fontSize: 8))),
                ]))),
            ]),
          ),
        )))),
        // Both edges trim (REAPER: drag an item's edge): the left one moves the start and keeps the notes in time.
        _edge(left: true),
        _edge(left: false),
          ]),
        ))),
    );
  }
}

/// A dragged clip's ghost, drawn over the tracks (inside their view) where the clip would land, with + for a copy.
class _GhostView extends StatelessWidget {
  const _GhostView({required this.ghost, required this.name});
  final ValueNotifier<_Ghost?> ghost;
  final String name;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_Ghost?>(
    valueListenable: ghost,
    builder: (context, g, _) {
      if (g == null) return const SizedBox.shrink();
      return Positioned.fromRect(rect: g.clip, child: IgnorePointer(child: ClipRect(child: Stack(children: [
        Positioned(left: g.rect.left - g.clip.left, top: g.rect.top - g.clip.top, width: g.rect.width,
          height: g.rect.height, child: Container(
            key: const ValueKey('clip-drag-ghost'),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5),
              color: g.color.withValues(alpha: 0.30),
              border: Border.all(color: g.color, width: 1.6),
              boxShadow: [BoxShadow(color: g.color.withValues(alpha: 0.35), blurRadius: 10)]),
            padding: const EdgeInsets.fromLTRB(7, 4, 6, 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: g.color, fontSize: 10, fontWeight: FontWeight.w800, decoration: TextDecoration.none))),
              if (g.copy) Icon(Icons.add_circle, key: const ValueKey('clip-drag-copy'), size: 14, color: g.color),
            ]))),
      ]))));
    });
}

class _AutomationLaneView extends StatelessWidget {
  const _AutomationLaneView({required this.state, required this.layer, required this.lane, required this.stepW, required this.width});
  final AppState state;
  final LayerDoc layer;
  final AutomationLaneDoc lane;
  final double stepW, width;

  double _y(double value) => lane.target == 'volume' ? 28 - value * 24 : 16 - value * 12;

  @override
  Widget build(BuildContext context) => Stack(children: [
    GestureDetector(behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final step = (d.localPosition.dx / stepW).clamp(0.0, state.project.maxArrangementSteps.toDouble()).toDouble();
        final value = (lane.target == 'volume' ? (1 - d.localPosition.dy / 32).clamp(0.0, 1.0)
            : (1 - d.localPosition.dy / 16).clamp(-1.0, 1.0)).toDouble();
        state.addAutomationPoint(layer, lane, step, value);
      },
      child: CustomPaint(size: Size(width, 34), painter: _AutomationCurvePainter(lane, stepW))),
    for (var i = 0; i < lane.points.length; i++)
      Positioned(left: lane.points[i].step * stepW - 5, top: _y(lane.points[i].value) + 2,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {}, // Keep the lane's add-point tap recognizer from firing on an existing handle.
          onPanUpdate: (d) => state.updateAutomationPoint(layer, lane, i,
            lane.points[i].step + d.delta.dx / stepW,
            lane.points[i].value - d.delta.dy / (lane.target == 'volume' ? 24 : 12)),
          child: Container(width: 10, height: 10, decoration: BoxDecoration(
            color: Neon.blue, shape: BoxShape.circle, border: Border.all(color: Neon.text, width: 1))),
        )),
    Positioned(left: 6, top: 1, child: Text(lane.target.toUpperCase(),
      style: const TextStyle(color: Neon.dim, fontSize: 8, letterSpacing: 1))),
  ]);
}

class _AutomationCurvePainter extends CustomPainter {
  _AutomationCurvePainter(this.lane, this.stepW);
  final AutomationLaneDoc lane;
  final double stepW;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Neon.blue.withValues(alpha: .75)..strokeWidth = 1.5..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < lane.points.length; i++) {
      final p = lane.points[i];
      final y = lane.target == 'volume' ? 28 - p.value * 24 : 16 - p.value * 12;
      final at = Offset(p.step * stepW, y + 7);
      if (i == 0) { path.moveTo(at.dx, at.dy); } else { path.lineTo(at.dx, at.dy); }
    }
    canvas.drawPath(path, paint);
    canvas.drawLine(Offset(0, 33), Offset(size.width, 33), Paint()..color = Neon.line);
  }
  @override
  bool shouldRepaint(covariant _AutomationCurvePainter old) => true;
}

class _ArrangementMixer extends StatelessWidget {
  const _ArrangementMixer({required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => Container(height: 150,
    decoration: const BoxDecoration(color: Neon.panel, border: Border(top: BorderSide(color: Neon.line))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(padding: EdgeInsets.fromLTRB(12, 7, 12, 2),
        child: Text('MIXER', style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.4))),
      Expanded(child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final l in state.project.layers.where((x) => !x.isFolder || x.busEnabled))
          SizedBox(width: 150, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Column(children: [
              Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: trackColor(state, l), fontSize: 11)),
              Expanded(child: ValueListenableBuilder<int>(valueListenable: state.layerValueTick(l.id),
                builder: (context, _, _) => Column(children: [
                  Row(children: [const Icon(Icons.volume_up, size: 13, color: Neon.dim),
                    Expanded(child: SizedBox(height: 36, child: VolumeFader(value: l.volume, vertical: false,
                      label: '${l.name} level', onChanged: (v) => state.mixLayer(l, volume: v)))),
                    SizedBox(width: 52, child: Text(VolumeTaper.label(l.volume), textAlign: TextAlign.right,
                      style: Neon.code(size: 9, color: Neon.dim)))]),
                  Row(children: [const Text('L', style: TextStyle(color: Neon.dim, fontSize: 10)),
                    Expanded(child: ResetOnDoubleTap(onReset: () => state.mixLayer(l, pan: 0), child: Slider(
                      value: l.pan, min: -1, max: 1, onChanged: (v) => state.mixLayer(l, pan: v)))),
                    const Text('R', style: TextStyle(color: Neon.dim, fontSize: 10))]),
                ]))),
            ]))),
      ])),
    ]),
  );
}

class _OverloadBanner extends StatelessWidget {
  const _OverloadBanner({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: NeonPanel(
          color: Neon.pink,
          child: Row(children: [
            const Icon(Icons.speed, color: Neon.pink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  'Out of headroom: the newest layer${state.meters.overloaded > 1 ? 's were' : ' was'} muted to keep audio clean.'
                  '${state.lightTurnedOnBySelf ? ' Lightweight profile is now active (Settings).' : ''}'),
            ),
            TextButton(onPressed: state.clearOverload, child: const Text('Unmute')),
          ]),
        ),
      );
}

class _ProjectSettings extends StatefulWidget {
  const _ProjectSettings({required this.state});
  final AppState state;

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  final List<DateTime> _taps = [];
  late final TextEditingController _seed;
  late int _syncedSeed;

  static const keys = [
    'C major', 'C minor', 'C# minor', 'D major', 'D minor', 'Eb major', 'E minor', 'F major', 'F minor', //
    'F# minor', 'G major', 'G minor', 'A major', 'A minor', 'Bb major', 'B minor', 'None',
  ];

  @override
  void initState() {
    super.initState();
    _syncedSeed = widget.state.project.seed;
    _seed = TextEditingController(text: _syncedSeed.toRadixString(16));
  }

  @override
  void didUpdateWidget(covariant _ProjectSettings old) {
    super.didUpdateWidget(old);
    // Re-sync only when the project's seed changed (Enter, undo, another project). Comparing against the
    // typed text instead would put the old seed back on every rebuild while it is being edited (#20).
    final seed = widget.state.project.seed;
    if (seed == _syncedSeed) return;
    _syncedSeed = seed;
    _seed.text = seed.toRadixString(16);
  }

  @override
  void dispose() {
    _seed.dispose();
    super.dispose();
  }

  void _tap() {
    final now = DateTime.now();
    if (_taps.isNotEmpty && now.difference(_taps.last).inMilliseconds > 2000) _taps.clear();
    _taps.add(now);
    if (_taps.length > 5) _taps.removeAt(0);
    if (_taps.length >= 2) {
      final ms = _taps.last.difference(_taps.first).inMicroseconds / 1000.0 / (_taps.length - 1);
      final bpm = (60000 / ms).clamp(20.0, 400.0);
      widget.state.editProject((p) => p.bpm = double.parse(bpm.toStringAsFixed(1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final bpmText = p.bpm == p.bpm.roundToDouble() ? p.bpm.toStringAsFixed(0) : p.bpm.toStringAsFixed(1);
    return NeonPanel(
      color: Neon.blue,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton.outlined(
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm - 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.remove)),
          Expanded(
            child: Column(children: [
              Text(bpmText, style: Neon.code(size: 34, color: Neon.blue).copyWith(fontWeight: FontWeight.w700)),
              const Text('BPM', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ]),
          ),
          IconButton.outlined(
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm + 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.add)),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Neon.blue, minimumSize: const Size(72, 48)),
            onPressed: _tap,
            child: const Text('TAP', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _Labeled(
            'Time',
            DropdownButton<int>(
              value: p.beatsPerBar,
              items: [for (final b in {2, 3, 4, 5, 6, 7, p.beatsPerBar}.toList()..sort()) DropdownMenuItem(value: b, child: Text('$b/4'))],
              onChanged: (v) => s.editProject((p) => p.beatsPerBar = v!),
            ),
          ),
          _Labeled(
            'Length',
            BarsField(value: p.loopBars, max: p.maxLoopBars, title: 'Shortest song length',
              onChanged: (v) => s.editProject((p) => p.loopBars = v)),
          ),
          _Labeled(
            'Key',
            DropdownButton<String>(
              value: keys.contains(p.key) ? p.key : 'None',
              items: [for (final k in keys) DropdownMenuItem(value: k, child: Text(k))],
              onChanged: (v) => s.editProject((p) => p.key = v!),
            ),
          ),
          _Labeled(
            'Seed',
            SizedBox(
              width: 92,
              child: TextField(
                controller: _seed,
                style: Neon.code(size: 14),
                decoration: const InputDecoration(prefixText: '0x'),
                onSubmitted: (v) {
                  final n = int.tryParse(v, radix: 16);
                  if (n != null && n >= 0 && n <= 0xFFFFFFFF) s.editProject((p) => p.seed = n);
                },
              ),
            ),
          ),
          Text('${p.songSeconds.toStringAsFixed(2)} s song', style: const TextStyle(color: Neon.dim)),
        ]),
        Row(children: [
          const SizedBox(width: 56, child: Text('Master', style: TextStyle(color: Neon.dim))),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: s.masterValueTick,
              builder: (context, _, _) => Row(children: [
                Expanded(child: SizedBox(height: 36, child: VolumeFader(value: s.project.master, vertical: false,
                  color: Neon.blue, label: 'Master level', onChanged: s.setMaster))),
                SizedBox(width: 56, child: Text(VolumeTaper.label(s.project.master), textAlign: TextAlign.right,
                  style: Neon.code(size: 10, color: Neon.dim))),
              ]),
            ),
          ),
          SizedBox(width: 120, child: PeakMeter(state: s, read: () => s.meters.peakL, readRight: () => s.meters.peakR, color: Neon.blue)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeThumbColor: Neon.blue,
          title: const Text('Crossfade loop seams'),
          subtitle: const Text('3 ms blend where a layer restarts', style: TextStyle(color: Neon.dim)),
          value: p.seamCrossfade,
          onChanged: (v) => s.editProject((p) => p.seamCrossfade = v),
        ),
      ]),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: const TextStyle(color: Neon.dim)),
        child,
      ]);
}

