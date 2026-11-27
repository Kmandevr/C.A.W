// Arrange's compact track header, the controls that drop out as it narrows, and the resize grip.
part of '../arranger_screen.dart';

/// A compact track header (owner, 2026-11-09): name, M, S and FX always show; record-arm, input, the instrument and
/// the rest are in the track menu (a hold, or right-click on a desktop). A tap or click selects the track, a double tap
/// or double-click opens its main editor (the focus view's FX tab: its instrument and effects; owner, 2026-11-12). The selected or focused track glows in its own colour, brighter. Its row is normal, compact (the name,
/// M and S in one row) or a thin bar ([TrackCollapse]; owner, 2026-11-11).
class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader({super.key, required this.state, required this.layer, required this.index, required this.depth,
    required this.taps,
    required this.trackHeight, required this.onTap, required this.onFx, required this.onMenu,
    this.collapse = TrackCollapse.normal, this.uprightMeter = false, this.hideMuteSolo = false, this.pinned = false,
    this.focused = false, this.onSwipe, this.onResize, this.onResizeEnd, this.drag,
    this.onTrackDrag});
  final AppState state;
  final LayerDoc layer;
  final int index, depth;

  /// The row's height (the track's own, the default, or its compact or thin height).
  final double trackHeight;
  final TrackCollapse collapse;

  /// The meter stands upright at the header's edge (a narrow header).
  final bool uprightMeter;

  /// A compact row at a phone's narrowest header width: M and S show only on the selected or focused track.
  final bool hideMuteSolo;

  /// The focus view's pinned track: a second tap anywhere on it is a double tap (the first tap moved it here).
  final bool pinned;
  final bool focused;
  final VoidCallback onTap, onFx;
  final void Function(Offset at) onMenu;
  final ClickCounter taps;
  final ValueChanged<int>? onSwipe;

  /// A drag on the row's bottom edge, by this many pixels; null on the focus view's pinned track.
  final ValueChanged<double>? onResize;
  final VoidCallback? onResizeEnd;

  /// Dragging the header moves the track (REAPER): on a touch screen a hold opens the track menu and moving on picks
  /// the track up (the menu closes), a plain drag with a mouse. Null on the pinned track.
  final ArrangeDrag? drag;
  final void Function(_HeaderPhase phase, Offset at)? onTrackDrag;

  @override
  Widget build(BuildContext context) {
    final color = trackColor(state, layer);
    final selected = focused || state.selectedLayerId == layer.id;
    final fxCount = layer.components.length;
    final low = trackHeight < 52;
    // REAPER-style (owner, 2026-11-10): the track's colour tints the whole header and its left edge, no outline.
    final edge = BorderSide(color: selected ? color : color.withValues(alpha: 0.75), width: selected ? 4 : 3);
    final compact = collapse == TrackCollapse.compact;
    final Widget box;
    if (collapse == TrackCollapse.thin) {
      // A sliver in the track's colour, indented like the track's header; still tapped, held and dragged.
      box = Container(key: ValueKey('thin-track-${layer.id}'), height: trackHeight, width: double.infinity,
        padding: EdgeInsets.only(left: folderIndent(depth)),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Neon.bg))),
        child: ColoredBox(color: color.withValues(alpha: selected ? 0.95 : 0.55)));
    } else {
      box = Container(height: trackHeight,
      padding: EdgeInsets.fromLTRB(6 + folderIndent(depth), compact || low ? 2 : 4, 2, compact || low ? 2 : 4),
      decoration: Glass.active
          ? BoxDecoration(
              gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [
                Color.lerp(Neon.panel, color, selected ? 0.42 : 0.26)!.withValues(alpha: 0.82),
                Color.lerp(Neon.panel, color, selected ? 0.20 : 0.10)!.withValues(alpha: 0.66),
              ]),
              border: Border(
                left: edge,
                bottom: BorderSide(color: Neon.bg.withValues(alpha: 0.6)),
                right: BorderSide(color: Neon.ink.withValues(alpha: 0.05)),
              ),
              boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.28), blurRadius: 12)] : null)
          : BoxDecoration(color: Color.lerp(Neon.panel, color, selected ? 0.30 : 0.16),
              border: Border(left: edge, bottom: const BorderSide(color: Neon.bg))),
      child: LayoutBuilder(builder: (context, box) {
        final oneRow = box.maxHeight < 56;
        final chip = compact || box.maxWidth < 86 ? 20.0 : box.maxWidth < 150 ? 24.0 : 30.0;
        final mute = _button(ToggleChip(label: 'M', size: chip, tooltip: layer.isFolder ? 'Mute folder' : 'Mute',
            on: layer.mute, color: Neon.yellow,
            onTap: () => layer.isFolder
                ? state.editLayer(layer, (l) => l.mute = !l.mute)
                : state.mixLayer(layer, mute: !layer.mute)));
        final solo = _button(ToggleChip(label: 'S', size: chip, tooltip: layer.isFolder ? 'Solo folder' : 'Solo',
            on: layer.solo, color: Neon.blue,
            onTap: () => layer.isFolder
                ? state.editLayer(layer, (l) => l.solo = !l.solo)
                : state.mixLayer(layer, solo: !layer.solo)));
        // A stereo track (a native instrument or effect, or a folder) meters each side; an empty track one bar.
        // An armed audio track shows its input's level instead (REAPER's record-armed meter).
        final armed = layer.input?.armed ?? false;
        final meter = armed
            ? Center(child: AudioInputMeter(layer: layer, height: low ? 5 : 7))
            : TrackMeter(key: ValueKey('meter-${layer.id}'), state: state, index: index, stereo: layer.isStereo,
                color: color);
        // Upright (a narrow header, or a compact row): a thin bar at the header's right edge, a live island of a
        // fixed size like the sideways one (owner, 2026-11-11).
        final standUp = uprightMeter || collapse != TrackCollapse.normal;
        final upright = Padding(
          padding: const EdgeInsets.only(left: 3, right: 1),
          child: SizedBox(key: ValueKey('upright-meter-${layer.id}'), width: layer.isStereo || armed ? 7 : 4,
            height: box.maxHeight, child: armed
                ? RotatedBox(quarterTurns: 3, child: AudioInputMeter(layer: layer, height: 7, upright: true))
                : LiveIsland(child: TrackMeter(key: ValueKey('meter-${layer.id}'), state: state, index: index,
                    stereo: layer.isStereo, color: color, vertical: true))));
        // FX: drawn at 18 dp, touched over about 34 dp; a dot tells the track has effects. A very narrow header
        // drops it: a tap on the header opens the track's effects too.
        final showFx = box.maxWidth - (uprightMeter || collapse != TrackCollapse.normal ? 11 : 0) >= 104;
        final fx = layer.isFolder
            ? Tooltip(message: layer.busEnabled ? 'Folder with a group bus' : 'Folder',
                child: SizedBox(width: 26, height: 26, child: Icon(Icons.account_tree_outlined, size: 15, color: color)))
            : _button(Tooltip(message: fxCount > 0 ? 'Effects ($fxCount)' : 'Effects', child: InkResponse(
                key: ValueKey('fx-button-${layer.id}'),
                radius: 20,
                onTap: () {
                  Haptics.tap();
                  onFx();
                },
                child: Pressable(glow: color, child: SizedBox(width: 30, height: 26, child: Stack(alignment: Alignment.center, children: [
                  Icon(Icons.graphic_eq, size: 18, color: fxCount > 0 ? color : Neon.dim),
                  if (fxCount > 0) Positioned(right: 3, top: 2, child: Container(width: 5, height: 5,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
                ]))))));
        // The envelope button (REAPER's, UG 18.16): opens the track's automation lanes under it; lit while open,
        // a dot while they are closed but there are some.
        final laneCount = canHaveLanes(layer) ? arrangeLanes(state, layer).length : 0;
        Widget? lanesButton(double w, double h) => !canHaveLanes(layer) || onTrackDrag == null ? null : _button(Tooltip(
          message: layer.showLanes ? 'Hide automation lanes' : 'Show automation lanes',
          child: InkResponse(key: ValueKey('lanes-button-${layer.id}'), radius: 18,
            onTap: () {
              Haptics.tap();
              state.setLanesShown(layer, !layer.showLanes);
            },
            child: Pressable(glow: Neon.blue, child: SizedBox(width: w, height: h, child: Stack(alignment: Alignment.center, children: [
              Icon(layer.showLanes ? Icons.keyboard_arrow_down : Icons.show_chart, size: math.min(17, h),
                color: layer.showLanes ? Neon.blue : laneCount > 0 ? color : Neon.dim),
              if (!layer.showLanes && laneCount > 0) Positioned(right: 2, top: 2, child: Container(width: 5, height: 5,
                decoration: const BoxDecoration(color: Neon.blue, shape: BoxShape.circle))),
            ]))))));
        // What the content has beside an upright meter.
        final w = box.maxWidth - (standUp ? 11 : 0);
        // A control that drops or comes back as the header narrows or shortens fades and scales (owner, 2026-11-11).
        Widget pop(String id, bool show, Widget child) => _HeaderPop(key: ValueKey('pop-$id-${layer.id}'), show: show,
            child: child);
        final chevron = !layer.isFolder ? null
            : _button(IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              key: ValueKey('folder-chevron-${layer.id}'),
              // 24 px wide: a padded 48 px target overflowed a phone's one-row folder header.
              style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              tooltip: layer.collapsed ? 'Open folder' : 'Collapse folder',
              icon: Icon(layer.collapsed ? Icons.chevron_right : Icons.expand_more, color: color, size: 18),
              onPressed: () => state.setFolderCollapsed(layer, !layer.collapsed)));
        // The name's tooltip shows on hover only: a finger's hold on it opens the track menu.
        final name = Expanded(child: Tooltip(triggerMode: TooltipTriggerMode.manual,
            message: layer.isFolder
                ? (layer.busEnabled ? 'Folder with a group bus' : 'Folder')
                : layer.isAudio ? 'Audio track · ${layer.input?.label ?? 'no input'} · hold for more'
                : 'Instrument: ${layer.instrument != null ? state.componentInfo(layer.instrument!.id)?.label ?? layer.instrument!.id
                    : 'none'} · hold for more',
            child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: Color.lerp(Neon.text, color, selected ? 0.35 : 0.15)))));
        // The upright meter and the sideways one cross-fade as the header crosses the width.
        // M and S beside the name need their chips, the folder's chevron and a little of the name.
        final msRoom = (layer.isFolder ? 27 : 3) + 2 * chip + 2 + 14;
        Widget withMeter(Widget content) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: content), pop('upright', standUp, upright)]);
        if (compact) {
          // The name, M and S in one row; at a phone's narrowest width M and S wait for the track to be selected.
          final ms = !hideMuteSolo || selected;
          return withMeter(SizedBox(height: box.maxHeight, child: Row(children: [
            ?chevron,
            const SizedBox(width: 3),
            pop('frozen', layer.frozen, FrozenBadge(state: state, layer: layer, size: 12)),
            name,
            pop('ms', ms && w >= msRoom, Row(mainAxisSize: MainAxisSize.min, children: [mute, const SizedBox(width: 2), solo])),
          ])));
        }
        final top = SizedBox(height: low ? 24 : 28, child: Row(children: [
          ?chevron,
          const SizedBox(width: 3),
          // A frozen track's snowflake (freeze, 1.0.5), fading and scaling in and out like the header's controls.
          pop('frozen', layer.frozen, FrozenBadge(state: state, layer: layer)),
          name,
          // A deep folder's header can get narrow: M and S move to their own row's place, the icons go first.
          if (oneRow) pop('ms', w >= msRoom, Row(mainAxisSize: MainAxisSize.min, children: [mute, const SizedBox(width: 2), solo])),
          // Arm sits by the name when the header has room for both; a phone's one-row header puts it by the meter.
          if (layer.isAudio && !oneRow) _button(AudioArmButton(state: state, layer: layer, size: chip)),
          // A folder's icon only says what it is: a narrow header gives its room to the name.
          pop('fx', showFx && (!layer.isFolder || w >= 140), fx),
        ]));
        if (oneRow) {
          // One row (a phone's default height): the envelope button sits at the meter's end, as high as the room
          // under the name allows.
          final room = box.maxHeight - (low ? 26 : 32);
          final lanes = room >= 12 ? lanesButton(30, math.min(18.0, room)) : null;
          final arm = layer.isAudio ? _button(AudioArmButton(state: state, layer: layer, size: math.max(12.0, math.min(18.0, room)))) : null;
          final under = standUp
              ? (lanes == null && arm == null ? null : Row(children: [?arm, const Spacer(), ?lanes]))
              : lanes == null && arm == null ? meter : Row(children: [?arm, Expanded(child: meter), ?lanes]);
          return withMeter(Column(mainAxisSize: MainAxisSize.min, children: [top,
            if (under != null) ...[SizedBox(height: low ? 2 : 4), under]]));
        }
        final lanes = lanesButton(26, 26);
        return withMeter(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          top,
          const SizedBox(height: 4),
          SizedBox(height: 26, child: Row(children: [
            mute,
            const SizedBox(width: 3),
            solo,
            const SizedBox(width: 8),
            Expanded(child: pop('meter', !standUp, meter)),
            // A very narrow header leaves it to the long-press menu's Show automation lanes.
            if (lanes != null && w >= 100) lanes else const SizedBox(width: 4),
          ])),
        ]));
      }),
    );
    }
    // Where a dragged track would land on this one: a line above or below it, or the folder lit up.
    final target = drag == null ? box : ValueListenableBuilder<DragSpot?>(
      valueListenable: drag!.hover,
      builder: (context, spot, child) {
        final here = drag!.active && spot?.layerId == layer.id && drag!.dragsTrack;
        if (!here) return child!;
        final into = spot!.where == TrackDrop.into;
        return Stack(children: [
          child!,
          // Nesting: the parent-to-be lights up, and an indented line under it shows the track landing one level in.
          if (into) ...[
            Positioned.fill(child: IgnorePointer(child: DecoratedBox(key: const ValueKey('track-drop-into'),
              decoration: BoxDecoration(border: Border.all(color: Neon.green, width: 2),
                color: Neon.green.withValues(alpha: 0.12))))),
            Positioned(left: 6 + folderIndent(depth + 1), right: 0, bottom: 0, height: 3,
              child: IgnorePointer(child: Container(key: const ValueKey('track-drop-into-line'), color: Neon.green))),
            Positioned(right: 4, top: 2, child: IgnorePointer(child: Icon(Icons.subdirectory_arrow_right,
              key: const ValueKey('track-drop-into-icon'), size: 16, color: Neon.green))),
          ] else Positioned(left: 0, right: 0, height: 3, top: spot.where == TrackDrop.above ? 0 : null,
            bottom: spot.where == TrackDrop.below ? 0 : null,
            child: IgnorePointer(child: Container(key: const ValueKey('track-drop-line'), color: Neon.green))),
        ]);
      },
      child: box);
    // One thin line per folder above, in that folder's colour (REAPER's nested folder indent, UG 5.13.5).
    final ancestors = <LayerDoc>[];
    for (var id = layer.parentId; id != null && ancestors.length < depth;) {
      final folder = state.project.layers.where((l) => l.id == id).firstOrNull;
      if (folder == null) break;
      ancestors.insert(0, folder);
      id = folder.parentId;
    }
    final guided = ancestors.isEmpty ? target : Stack(children: [
      target,
      for (var i = 0; i < ancestors.length; i++)
        Positioned(left: folderIndent(i + 1) - 4, top: 0, bottom: 0, width: 1.5,
          child: IgnorePointer(child: ColoredBox(key: ValueKey('folder-guide-${layer.id}-$i'),
            color: trackColor(state, ancestors[i]).withValues(alpha: 0.55)))),
    ]);
    final resizable = onResize == null ? guided : Stack(children: [
      guided,
      // The row's bottom edge: drag it to make this track thinner or taller, through compact and thin (saved);
      // with Shift, every track's default height. A thin bar is all edge.
      Positioned(left: 0, right: 0, bottom: 0, height: math.min(8.0, trackHeight), child: _ResizeGrip(
        key: ValueKey('track-height-grip-${layer.id}'), axis: Axis.vertical, label: 'Resize track',
        onDrag: onResize!, onEnd: onResizeEnd ?? () {})),
    ]);
    return Semantics(
      button: true,
      selected: selected,
      label: '${layer.name} track',
      // A tap selects the track at once; a quick second tap opens its main editor (owner, 2026-11-12), with no double
      // tap in the gesture arena to hold the first back. On the focus view's pinned track a tap goes back to all
      // tracks and a second tap anywhere on it counts. A hold opens the menu at once; moving on past the touch slop
      // closes it and picks the track up (the pinned track, which can't move, just opens the menu). The outermost pointer handler sees a press last: a press on one of the header's buttons
      // (M, S, FX, the arrows) isn't counted, and it clears the mark the button left.
      child: Listener(onPointerDown: (e) {
        _headerPointer = e.pointer;
        _onHeaderButton ? taps.reset() : taps.down(e, target: layer.id, anywhere: pinned);
        _onHeaderButton = false;
      }, onPointerUp: taps.up, child: GestureDetector(
        key: ValueKey('track-header-${layer.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => taps.twice ? onFx() : onTap(),
        onLongPressStart: (d) => onTrackDrag == null ? onMenu(d.globalPosition) : onTrackDrag!(_HeaderPhase.press, d.globalPosition),
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
      )),
    );
  }

  /// One of the header's own buttons: a press on it marks [_onHeaderButton], so it doesn't count as a header tap.
  static Widget _button(Widget child) => Listener(onPointerDown: (_) => _onHeaderButton = true, child: child);
}

/// The last pointer down on a header: the finger a hold on it follows.
int _headerPointer = 0;

/// A press went down on a header's button (set by the button, cleared by the header's outermost handler, which
/// sees the press last).
bool _onHeaderButton = false;

double _gainDb(double g) => g <= 0.001 ? -60 : (20 * math.log(g) / math.ln10).clamp(-60.0, 12.0).toDouble();
double _dbGain(double db) => db <= -60 ? 0 : math.pow(10, db / 20).toDouble();

/// Where a dragged track height lands: thin below halfway to compact, compact below halfway to the shortest normal
/// row, else a normal row of that height.
(TrackCollapse, double) trackRowSnap(double raw) {
  if (raw < (LayerDoc.thinHeight + LayerDoc.compactHeight) / 2) return (TrackCollapse.thin, LayerDoc.thinHeight);
  if (raw < (LayerDoc.compactHeight + LayerDoc.minHeight) / 2) return (TrackCollapse.compact, LayerDoc.compactHeight);
  return (TrackCollapse.normal, raw.clamp(LayerDoc.minHeight, LayerDoc.maxHeight).toDouble());
}

/// A header control that drops ([show] false) or comes back as the header narrows or shortens: it fades and scales
/// out and in, in the lengths edit-motion kind (a fade alone with Reduced motion, at once with motion Off).
class _HeaderPop extends StatelessWidget {
  const _HeaderPop({super.key, required this.show, required this.child});
  final bool show;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero;
    final fade = EditMotion.fadeOnly(context);
    return AnimatedSwitcher(duration: d, switchInCurve: EditMotion.curve, switchOutCurve: EditMotion.exitCurve,
      // The header lays out for what shows now; a control on its way out fades over its neighbours.
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none,
          children: [for (final p in previous) Positioned(left: 0, child: p), ?current]),
      transitionBuilder: (child, a) => FadeTransition(opacity: a,
          child: fade ? child : ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(a), child: child)),
      child: show ? KeyedSubtree(key: const ValueKey(true), child: child) : const SizedBox.shrink(key: ValueKey(false)));
  }
}

/// Below this header width a track's meter stands upright at the header's edge (owner, 2026-11-11).
const uprightMeterWidth = 120.0;

/// How far a track [depth] folders down is indented: 10 px a level for four levels, then 3 px a level up to
/// 60 px, so a deep tree still leaves a phone's narrow header room for the name.
double folderIndent(int depth) => depth <= 4 ? depth * 10.0 : math.min(60.0, 40.0 + (depth - 4) * 3.0);

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

class _ResizeGripState extends State<_ResizeGrip> with GrabFeedback {
  @override
  Widget build(BuildContext context) {
    final sideways = widget.axis == Axis.horizontal;
    // The shared grip (feedback.dart): it grows and lights when grabbed, with a haptic grab and drop.
    final line = GripMark(axis: widget.axis, grabbed: grabbed, hovered: hovered, length: 22,
      restColor: Neon.dim.withValues(alpha: 0.35), restThickness: 2);
    void start() => grab();
    void update(double d) => widget.onDrag(d);
    void end() { release(); widget.onEnd(); }
    // The tooltip shows on hover only: a finger's hold belongs to what is under the grip (a thin track's menu).
    return Semantics(label: widget.label, child: Tooltip(message: widget.label, waitDuration: const Duration(milliseconds: 600),
      triggerMode: TooltipTriggerMode.manual,
      child: MouseRegion(
        cursor: sideways ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        onEnter: (_) => hover(true),
        onExit: (_) => hover(false),
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
