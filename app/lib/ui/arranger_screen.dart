// Arrange: the tracks and clips on a timeline, compact track headers, the focus view (one track and its panel) and the mixer card.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/app_state.dart';
import '../model/arrange_fx.dart';
import '../model/live_midi.dart';
import '../model/project.dart';
import '../model/settings.dart';
import 'arrange/focus_panel.dart';
import 'arrange/long_press_menu.dart';
import 'arrange/mixer_card.dart';
import 'frame/sections.dart';
import 'motion.dart';
import 'param_control.dart';
import 'theme.dart';
import 'arrange/track_color.dart';
import 'frame/frame_widgets.dart';
import 'widgets.dart';
import 'track_cards_screen.dart';
import 'glass.dart';
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

  @override
  void dispose() {
    _zoomAnim.dispose();
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
    _touches[e.pointer] = e.localPosition;
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
    final gens = s.project.modules.where((m) => s.isGenerator(m.id)).toList();
    s.componentCatalog.refreshIfStale();
    final natives = s.nativeInstruments..sort((a, b) => a.label.compareTo(b.label));
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
        for (final g in gens)
          MenuAction('gen:${g.id}', 'Instrument · ${g.name}', Icons.piano,
              checked: layer.instrument == null && g.id == layer.generatorId),
        // C++ instruments: the engine's built-ins and the project's loaded (trusted) ones.
        for (final c in natives)
          MenuAction('inst:${c.id}', 'Instrument · ${c.label}', Icons.piano_outlined,
              checked: layer.instrument?.id == c.id, hint: c.builtin ? 'Built-in C++' : 'Project C++'),
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
    if (v.startsWith('gen:')) s.setCawGenerator(layer, v.substring(4));
    if (v.startsWith('inst:')) s.setNativeInstrument(layer, v.substring(5));
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
    final v = await showLongPressMenu<String>(context, at: at, title: s.project.module(clip.patternId)?.name ?? 'Clip',
      style: s.settings.longPressMenu, actions: [
        const MenuAction('notes', 'Edit notes', Icons.piano),
        if (widget.onOpenPattern != null) const MenuAction('edit', 'Open in Sounds', Icons.open_in_new),
        MenuAction('select', s.selectedClipIds.contains(clip.id) ? 'Deselect' : 'Add to selection', Icons.select_all),
        const MenuAction('copy', 'Duplicate independently', Icons.copy),
        const MenuAction('linked', 'Duplicate linked', Icons.link),
        MenuAction('loop', clip.loop ? 'Disable clip looping' : 'Enable clip looping', Icons.loop, checked: clip.loop),
        if (canSplit) const MenuAction('split', 'Split at time selection', Icons.content_cut),
        const MenuAction('midi', 'Export as MIDI file', Icons.file_upload_outlined),
        const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true),
      ]);
    if (v == null || !mounted) return;
    if (v == 'notes') { s.activateClip(layer, clip); _focus(layer.id, tab: FocusTab.clip); }
    if (v == 'edit') { s.activateClip(layer, clip); widget.onOpenPattern?.call(); }
    if (v == 'select') s.selectClip(layer, clip, additive: true);
    if (v == 'copy') s.duplicateClip(layer, clip);
    if (v == 'linked') s.duplicateClip(layer, clip, linked: true);
    if (v == 'loop') s.editLayer(layer, (l) => clip.loop = !clip.loop);
    if (v == 'split') s.splitClipAt(layer, clip, splitAt!);
    if (v == 'midi') await exportClipAsMidi(context, s, clip);
    if (v == 'delete') s.removeClip(layer, clip);
  }

  _TrackCallbacks _callbacks(List<ModuleDoc> patterns) => _TrackCallbacks(
    onTap: (l) => _openTrack(l),
    onFx: (l) => _openTrack(l, tab: FocusTab.fx),
    onMenu: (l, at) => _trackMenu(l, at, patterns),
    onClipMenu: _clipMenu,
    onClipOpen: (l, c) { widget.state.activateClip(l, c); _focus(l.id, tab: FocusTab.clip); },
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

    return PopScope(
      // Android Back leaves the focus view first (owner, 2026-11-09).
      canPop: focused == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && focused != null) _focus(null);
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
        Expanded(child: body),
        if (mixer) _ArrangementMixer(state: s),
      ]),
    );
  }

  Widget _toolbar(BuildContext context, LayerDoc? focused) {
    final s = widget.state;
    final p = s.project;
    final selectedLayer = p.layers.where((l) => l.id == s.selectedLayerId).firstOrNull;
    final selectedClip = selectedLayer?.clips.where((c) => c.id == s.selectedClipId).firstOrNull;
    final splitAt = s.timeSelectionEnd;
    final gap = s.settings.trackGap;
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
          if (selectedLayer != null && selectedClip != null && splitAt != null && splitAt > selectedClip.startSteps && splitAt < selectedClip.startSteps + selectedClip.lengthSteps)
            IconButton(onPressed: () => s.splitClipAt(selectedLayer, selectedClip, splitAt),
              icon: const Icon(Icons.content_cut), tooltip: 'Split at time selection'),
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
        return Row(children: [
          const Expanded(child: Text('ARRANGEMENT', style: TextStyle(
            color: Neon.dim, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w800))),
          ...controls,
        ]);
      }),
    );
  }

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
      Expanded(flex: 3, child: Slider(key: const ValueKey('arrange-zoom-time'),
        value: (math.log(zoom / minZoom) / ratio).clamp(0.0, 1.0).toDouble(),
        onChanged: (v) { _zoomAnim.stop(); _setZoom(minZoom * math.exp(v * ratio)); })),
      icon(Icons.add, 'Zoom in', () => _animateZoom(_zoomAnim.isAnimating ? _zoomTarget * 1.4 : zoom * 1.4)),
      const SizedBox(width: 6),
      const Tooltip(message: 'Track height', child: Icon(Icons.swap_vert, size: 16, color: Neon.dim)),
      Expanded(flex: 2, child: Slider(key: const ValueKey('arrange-zoom-height'),
        value: h.clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble(),
        min: Settings.minTrackHeight, max: Settings.maxTrackHeight,
        onChanged: (v) => setState(() => _dragTrackH = v),
        onChangeEnd: (_) => _saveHeaderSize())),
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
    // The song ends at its last clip or automation point (or the shortest length) and playback loops back there,
    // as in Reaper. The timeline always reaches 64 bars past it, so a clip can go anywhere and the song grows with it.
    final end = p.engineLoopSteps;
    final width = math.max(560.0, math.min(p.maxArrangementSteps, math.max(p.timelineSteps, end + 64 * p.stepsPerBar)) * stepW);
    final ruler = pinned ? 20.0 : 30.0;
    final focusId = _focusId;
    // Two fingers scroll by their average, so a pinch zooms without dragging the view; the pointers are read raw.
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(multitouchDragStrategy: MultitouchDragStrategy.averageBoundaryPointers),
      child: Listener(
      onPointerDown: (e) => _touchDown(e, headW),
      onPointerMove: (e) => _touchMove(e, headW),
      onPointerUp: _touchUp,
      onPointerCancel: _touchUp,
      child: LayoutBuilder(builder: (context, view) => SingleChildScrollView(child: Listener(
        onPointerSignal: (e) => _wheel(e, null),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Stack(children: [SizedBox(width: headW, child: Column(children: [
        SizedBox(height: ruler, child: Padding(
          padding: EdgeInsets.only(left: 10, top: pinned ? 4 : 8),
          child: Align(alignment: Alignment.centerLeft,
            child: Text(pinned ? 'FOCUS · swipe ⇆' : 'TRACKS',
              style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3))))),
        for (final layer in layers) ...[
          _TimelineHeader(state: s, layer: layer, index: p.layers.indexOf(layer),
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
      ])),
        // The headers' right edge: drag it to make the headers narrower or wider (saved).
        Positioned(right: 0, top: 0, bottom: 0, width: 10, child: _ResizeGrip(
          key: const ValueKey('header-width-grip'), axis: Axis.horizontal, label: 'Resize track headers',
          onDrag: (dx) => setState(() => _dragHeaderW = (_headerWidth + dx)
              .clamp(Settings.minHeaderWidth, Settings.maxHeaderWidth).toDouble()),
          onEnd: _saveHeaderSize)),
      ]),
      Expanded(child: SingleChildScrollView(controller: _hScroll, scrollDirection: Axis.horizontal,
        child: Listener(
          onPointerSignal: (e) => _wheel(e, _hScroll.hasClients ? e.localPosition.dx - _hScroll.positions.last.pixels : null),
          child: SizedBox(width: width, child: Stack(children: [
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
              _TimelineLane(state: s, layer: layer, width: width, stepW: stepW,
                trackHeight: trackHeight, selectedIds: s.selectedClipIds, callbacks: callbacks),
              // A spacer and the gap leave the timeline empty too, so lanes stay level with their headers.
              if (layer.spaceBelow > 0 && !pinned) SizedBox(height: layer.spaceBelow),
              SizedBox(height: gap),
            ],
          ])),
          Positioned.fill(child: IgnorePointer(child: ValueListenableBuilder<int>(
            valueListenable: s.tick,
            builder: (context, _, _) {
              final playheadStep = s.meters.playing && s.meters.loopLength > 0
                  ? endPosition(s, p, s.meters.loopLength) : -1.0;
              return CustomPaint(painter: _PlayheadPainter(stepW, playheadStep));
            },
          ))),
        ]))))),
    ]))))));
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
    required this.onClipOpen});
  final ValueChanged<LayerDoc> onTap, onFx;
  final void Function(LayerDoc layer, Offset at) onMenu;
  final void Function(LayerDoc layer, ClipDoc clip, Offset at) onClipMenu;
  final void Function(LayerDoc layer, ClipDoc clip) onClipOpen;
}

/// A compact track header (owner, 2026-11-09): name, M, S and FX always show; record-arm, input, the instrument and
/// the rest are in the long-press menu (right-click on a desktop). A tap opens the track's focus view. The selected
/// or focused track glows in its own colour, brighter.
class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader({required this.state, required this.layer, required this.index, required this.depth,
    required this.trackHeight, required this.onTap, required this.onFx, required this.onMenu,
    this.focused = false, this.onSwipe, this.onResize, this.onResizeEnd});
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
        // The engine reports one peak per track today, so a track's meter is a single bar (the master is stereo).
        final meter = PeakMeter(key: ValueKey('meter-${layer.id}'), state: state, color: color,
            read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0);
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
    final resizable = onResize == null ? box : Stack(children: [
      box,
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
        onLongPressStart: (d) => onMenu(d.globalPosition),
        onSecondaryTapUp: (d) => onMenu(d.globalPosition),
        onHorizontalDragEnd: onSwipe == null ? null : (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() > 200) onSwipe!(v < 0 ? 1 : -1);
        },
        child: resizable,
      ),
    );
  }
}

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

class _TimelineLane extends StatelessWidget {
  const _TimelineLane({required this.state, required this.layer, required this.width,
    required this.stepW, required this.trackHeight, required this.selectedIds, required this.callbacks});
  final AppState state;
  final LayerDoc layer;
  final double width, stepW, trackHeight;
  final Set<String> selectedIds;
  final _TrackCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final height = trackHeight + layer.automation.length * 34.0;
    // A dropped effect joins this track's chain; a dropped pattern becomes a clip where it lands.
    return DragTarget<AssetDrag>(
      onWillAcceptWithDetails: (_) => !layer.isFolder,
      onAcceptWithDetails: (d) {
        final box = context.findRenderObject() as RenderBox?;
        final x = box == null ? 0.0 : box.globalToLocal(d.offset).dx;
        state.dropAsset(layer, d.data, atStep: math.max(0, (x / stepW).floor()));
      },
      builder: (context, hovering, _) => SizedBox(width: width, height: height,
    child: Stack(children: [
      Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque,
        // A plain horizontal drag belongs to the enclosing scroll view. Long-press
        // drag creates a time selection without stealing normal timeline navigation.
        onTapUp: (d) { final step = (d.localPosition.dx / stepW).round(); state.setTimeSelection(step, step); },
        onLongPressStart: (d) { state.beginTimeSelection((d.localPosition.dx / stepW).round()); },
        onLongPressMoveUpdate: (d) => state.updateTimeSelection((d.localPosition.dx / stepW).round()),
        onLongPressEnd: (_) => state.endTimeSelection(),
        child: hovering.isEmpty ? const SizedBox.expand()
            : DecoratedBox(decoration: BoxDecoration(color: trackColor(state, layer).withValues(alpha: 0.12),
                border: Border.all(color: trackColor(state, layer)))))),
      if (state.timeSelectionStart != null && state.timeSelectionEnd != null)
        Positioned(left: math.min(state.timeSelectionStart!, state.timeSelectionEnd!) * stepW, top: 0,
          width: math.max(1.0, (state.timeSelectionEnd! - state.timeSelectionStart!).abs() * stepW), height: height,
          child: IgnorePointer(child: Container(color: Neon.blue.withValues(alpha: .09)))),

      for (final clip in layer.clips)
        Positioned(left: clip.startSteps * stepW, top: _clipInset(trackHeight),
          width: math.max(12.0, clip.lengthSteps * stepW), height: trackHeight - 2 * _clipInset(trackHeight),
          child: _TimelineClip(state: state, layer: layer, clip: clip, stepW: stepW,
            color: trackColor(state, layer), selected: selectedIds.contains(clip.id), callbacks: callbacks)),
      if (layer.clips.isEmpty && !layer.isFolder)
        Positioned(left: 10, top: trackHeight * 0.38, child: const IgnorePointer(child: Text('Hold the track for clips, or drop a pattern here',
          style: TextStyle(color: Neon.dim, fontSize: 10)))),
      for (var i = 0; i < layer.automation.length; i++)
        Positioned(left: 0, right: 0, top: trackHeight + i * 34.0, height: 34,
          child: _AutomationLaneView(state: state, layer: layer, lane: layer.automation[i], stepW: stepW, width: width)),
    ]),
  ));
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
  const _PlayheadPainter(this.stepW, this.step);
  final double stepW, step;

  @override
  void paint(Canvas canvas, Size size) {
    if (step < 0) return;
    final x = step * stepW;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height),
      Paint()..color = Neon.blue..strokeWidth = 1.6);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter old) => old.step != step || old.stepW != stepW;
}


class _TimelineClip extends StatefulWidget {
  const _TimelineClip({required this.state, required this.layer, required this.clip,
    required this.stepW, required this.color, required this.selected, required this.callbacks});
  final AppState state;
  final LayerDoc layer;
  final ClipDoc clip;
  final double stepW;
  final Color color;
  final bool selected;
  final _TrackCallbacks callbacks;
  @override
  State<_TimelineClip> createState() => _TimelineClipState();
}

class _TimelineClipState extends State<_TimelineClip> {
  double dx = 0, resizeDx = 0;
  bool dragging = false, resizing = false, sourceDragging = false;
  int? _lastSnap;

  int get _snap => widget.state.arrangementSnapSteps;
  bool get _free => HardwareKeyboard.instance.isShiftPressed;

  /// Where a move ends, in steps: on the grid unless Shift is held.
  int _moveTarget() {
    final raw = (dx / widget.stepW).round();
    if (sourceDragging) return _free ? raw : (raw / _snap).round() * _snap;
    final rawStart = widget.clip.startSteps + raw;
    return _free ? rawStart : (rawStart / _snap).round() * _snap;
  }

  /// A light tick each time the clip lands on another grid line (owner: haptics on grid snaps).
  void _tickOnSnap(int at) {
    if (_lastSnap != null && _lastSnap != at) Motion.tick();
    _lastSnap = at;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final rawLength = c.lengthSteps + (resizing ? (resizeDx / widget.stepW).round() : 0);
    final length = (resizing && !_free ? math.max(_snap, (rawLength / _snap).round() * _snap) : rawLength)
        .clamp(1, widget.state.project.maxArrangementSteps - c.startSteps).toInt();
    final name = widget.state.project.module(c.patternId)?.name ?? 'Missing pattern';
    final shown = dragging && !sourceDragging ? (_moveTarget() - c.startSteps) * widget.stepW : 0.0;
    return Transform.translate(offset: Offset(shown, 0),
      child: Transform.scale(scaleX: resizing ? length / c.lengthSteps : 1.0,
        alignment: Alignment.centerLeft,
        child: Material(color: Glass.active ? Colors.transparent : widget.color.withValues(alpha: widget.selected ? .42 : .23),
          borderRadius: BorderRadius.circular(5),
          child: Stack(children: [
        Positioned.fill(child: GestureDetector(
          onLongPressStart: (d) => widget.callbacks.onClipMenu(widget.layer, c, d.globalPosition),
          onSecondaryTapUp: (d) => widget.callbacks.onClipMenu(widget.layer, c, d.globalPosition),
          onTap: () {
            if (HardwareKeyboard.instance.isShiftPressed) {
              widget.state.selectClip(widget.layer, c, additive: true);
            } else if (widget.state.selectedClipIds.contains(c.id)) {
              widget.state.activateClip(widget.layer, c);
            } else {
              widget.state.selectClip(widget.layer, c);
            }
          },
          // A clip's notes open in the Clip tab of the focus view (owner, 2026-11-09).
          onDoubleTap: () => widget.callbacks.onClipOpen(widget.layer, c),
          onHorizontalDragStart: (_) => setState(() {
            dragging = true; sourceDragging = HardwareKeyboard.instance.isAltPressed; dx = 0; _lastSnap = null;
          }),
          onHorizontalDragUpdate: (d) => setState(() { dx += d.delta.dx; _tickOnSnap(_moveTarget()); }),
          onHorizontalDragEnd: (_) {
            final target = _moveTarget();
            if (sourceDragging) {
              widget.state.shiftClipSource(widget.layer, c, target);
            } else {
              widget.state.moveClip(widget.layer, c, target);
            }
            setState(() { dragging = false; sourceDragging = false; dx = 0; _lastSnap = null; });
          },
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
            padding: const EdgeInsets.fromLTRB(7, 4, 13, 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: widget.color, fontSize: 10, fontWeight: FontWeight.w800)),
              Expanded(child: Align(alignment: Alignment.bottomLeft,
                child: Text(c.loop ? 'MIDI · LOOP' : 'MIDI',
                  style: TextStyle(color: widget.color.withValues(alpha: .8), fontSize: 8)))),
            ]),
          ),
        )),
        Positioned(right: 0, top: 0, bottom: 0, width: 12,
          child: GestureDetector(behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => setState(() { resizing = true; resizeDx = 0; _lastSnap = null; }),
            onHorizontalDragUpdate: (d) => setState(() {
              resizeDx += d.delta.dx;
              final raw = c.lengthSteps + (resizeDx / widget.stepW).round();
              _tickOnSnap(_free ? raw : (raw / _snap).round() * _snap);
            }),
            onHorizontalDragEnd: (_) {
              widget.state.resizeClip(widget.layer, c, length);
              setState(() { resizing = false; resizeDx = 0; _lastSnap = null; });
            },
            child: Center(child: Container(width: 2, height: 22, color: widget.color)))),
          ]),
        )),
    );
  }
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
                    Expanded(child: Slider(value: l.volume, onChanged: (v) => state.mixLayer(l, volume: v)))]),
                  Row(children: [const Text('L', style: TextStyle(color: Neon.dim, fontSize: 10)),
                    Expanded(child: Slider(value: l.pan, min: -1, max: 1,
                      onChanged: (v) => state.mixLayer(l, pan: v))),
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
              builder: (context, _, _) => Slider(
                value: s.project.master.clamp(0.0, 1.0).toDouble(),
                activeColor: Neon.blue,
                onChanged: s.setMaster,
              ),
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

