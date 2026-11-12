// Arrange's direct manipulation, REAPER-style (#172): where a dragged clip or track header points, auto-scroll at the
// view's edges, Escape to cancel, the "New track" zone below the last track, and drops that ask before replacing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/project.dart';
import '../frame/sections.dart';
import '../theme.dart';
import 'templates_ui.dart';
import '../panel_motion.dart';

/// What a drag over the tracks points at: a track (and, for a dragged header, where on it), or the empty area below
/// the last track, where a drop makes a new track.
@immutable
class DragSpot {
  const DragSpot.track(String this.layerId, {this.where = TrackDrop.into}) : newTrack = false;
  const DragSpot.newTrack() : layerId = null, where = TrackDrop.below, newTrack = true;
  final String? layerId;
  final TrackDrop where;
  final bool newTrack;

  @override
  bool operator ==(Object other) =>
      other is DragSpot && other.layerId == layerId && other.where == where && other.newTrack == newTrack;
  @override
  int get hashCode => Object.hash(layerId, where, newTrack);
}

/// One per arranger: finds what a pointer is over (lanes and headers register their keys while built), scrolls
/// while a drag sits at an edge, and lets Escape cancel the drag in progress.
class ArrangeDrag {
  final Map<String, GlobalKey> _lanes = {}, _headers = {};

  /// The empty area under the tracks (the lane side and the header side).
  final newTrackLane = GlobalKey(debugLabel: 'new-track-lane'), newTrackHeader = GlobalKey(debugLabel: 'new-track-header');

  /// The vertical and horizontal scroll views of the tracks, for edge scrolling and their visible area.
  final vViewport = GlobalKey(debugLabel: 'tracks-viewport'), hViewport = GlobalKey(debugLabel: 'lanes-viewport');
  final vScroll = ScrollController();
  ScrollController? hScroll;

  /// What the drag in progress points at (lanes and the New track zone light up from it).
  final hover = ValueNotifier<DragSpot?>(null);

  /// The drag in progress makes a copy (Ctrl on a desktop, a second finger on a touch screen).
  final copy = ValueNotifier<bool>(false);

  /// A clip or header drag is in progress; a second finger then toggles [copy] instead of zooming.
  bool active = false;

  /// The drag in progress moves a track header (headers show where it lands) rather than a clip (lanes do).
  bool dragsTrack = false;

  /// Two fingers are on the timeline (a pinch): a clip drag doesn't start.
  bool pinching = false;

  /// The drag in progress began with a long press (a clip picked up whole): a second finger resting on the screen
  /// then frees it from the grid ([free]) instead of making a copy, as in the piano roll.
  bool lifted = false;

  /// A second finger rests on the screen during a [lifted] drag: it moves off the grid until that finger lifts.
  final free = ValueNotifier<bool>(false);

  GlobalKey laneKey(String layerId) => _lanes.putIfAbsent(layerId, () => GlobalKey(debugLabel: 'lane-$layerId'));
  GlobalKey headerKey(String layerId) => _headers.putIfAbsent(layerId, () => GlobalKey(debugLabel: 'head-$layerId'));

  static Rect? rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? laneRect(String layerId) => _lanes[layerId] == null ? null : rectOf(_lanes[layerId]!);

  /// The lane (or the New track zone) at the height of [global]: the gap under a track counts as that track.
  DragSpot? spotAt(Offset global, {Map<String, GlobalKey>? from}) {
    final zone = rectOf(from == null ? newTrackLane : newTrackHeader) ?? rectOf(newTrackLane);
    if (zone != null && global.dy >= zone.top) return const DragSpot.newTrack();
    final rows = <(String, Rect)>[
      for (final e in (from ?? _lanes).entries)
        if (rectOf(e.value) case final r?) (e.key, r),
    ]..sort((a, b) => a.$2.top.compareTo(b.$2.top));
    if (rows.isEmpty) return null;
    var hit = rows.first;
    for (final row in rows) {
      if (row.$2.top <= global.dy) hit = row;
    }
    return DragSpot.track(hit.$1);
  }

  /// Where a dragged track header lands (owner, 2026-11-11, after REAPER): a plain up and down drag only reorders,
  /// the upper half of a header going above that track and the lower half below it; with the finger in the
  /// right-most third of a header the dragged track nests under that one (any track can be a parent).
  DragSpot? trackSpotAt(Offset global) {
    final spot = spotAt(global, from: _headers);
    if (spot == null || spot.newTrack) return spot;
    final r = rectOf(_headers[spot.layerId]!)!;
    if (global.dx >= r.left + r.width * 2 / 3 && global.dy <= r.bottom) {
      return DragSpot.track(spot.layerId!, where: TrackDrop.into);
    }
    final y = (global.dy - r.top) / r.height;
    return DragSpot.track(spot.layerId!, where: y < 0.5 ? TrackDrop.above : TrackDrop.below);
  }

  // ---------- a drag in progress: edge scrolling and Escape ----------

  Timer? _edgeTimer;
  Offset? _pointer;
  VoidCallback? _onScroll, _onCancel;

  /// Starts a drag: [onScroll] runs after an edge scroll moved the view, [onCancel] when Escape is pressed.
  void begin({required VoidCallback onScroll, required VoidCallback onCancel, bool track = false, bool lift = false}) {
    active = true;
    dragsTrack = track;
    lifted = lift;
    _onScroll = onScroll;
    _onCancel = onCancel;
    HardwareKeyboard.instance.addHandler(_key);
  }

  /// The pointer moved to [global]: near an edge of the tracks the view scrolls, faster nearer the edge.
  void point(Offset global) {
    _pointer = global;
    _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _edgeScroll());
  }

  void end() {
    active = false;
    dragsTrack = false;
    lifted = false;
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _pointer = null;
    _onScroll = _onCancel = null;
    HardwareKeyboard.instance.removeHandler(_key);
    hover.value = null;
    copy.value = false;
    free.value = false;
  }

  bool _key(KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && _onCancel != null) {
      _onCancel!();
      return true;
    }
    // Ctrl pressed or let go mid-drag turns copy on or off at once (the ghost shows it).
    if (e.logicalKey == LogicalKeyboardKey.controlLeft || e.logicalKey == LogicalKeyboardKey.controlRight) {
      scheduleMicrotask(() => _onScroll?.call());
    }
    return false;
  }

  static const _edge = 40.0, _maxSpeed = 18.0;

  double _speed(double pos, double lo, double hi) {
    if (pos < lo + _edge) return -_maxSpeed * ((lo + _edge - pos) / _edge).clamp(0.0, 1.0);
    if (pos > hi - _edge) return _maxSpeed * ((pos - (hi - _edge)) / _edge).clamp(0.0, 1.0);
    return 0;
  }

  void _edgeScroll() {
    final p = _pointer;
    if (p == null) return;
    var moved = false;
    bool scroll(ScrollController? c, double by) {
      if (c == null || !c.hasClients || by == 0) return false;
      final pos = c.positions.last;
      final to = (pos.pixels + by).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (to == pos.pixels) return false;
      pos.jumpTo(to);
      return true;
    }
    final v = rectOf(vViewport);
    if (v != null && p.dx >= v.left && p.dx <= v.right) moved |= scroll(vScroll, _speed(p.dy, v.top, v.bottom));
    final h = rectOf(hViewport);
    if (h != null && p.dy >= h.top && p.dy <= h.bottom) moved |= scroll(hScroll, _speed(p.dx, h.left, h.right));
    if (moved) _onScroll?.call();
  }

  void dispose() {
    end();
    vScroll.dispose();
    hover.dispose();
    copy.dispose();
    free.dispose();
  }
}

/// Puts [asset] on [layer] (a folder passes it to its first track inside), asking first when it is an instrument that
/// would replace the one the track has. True when something changed.
Future<bool> dropOnTrack(BuildContext context, AppState state, LayerDoc layer, AssetDrag asset, {int? atStep}) async {
  final track = state.dropTrackFor(layer, newName: asset.name);
  if (state.replacesInstrument(track, asset)) {
    final old = state.instrumentName(track);
    final ok = await showDialog<bool>(context: context, animationStyle: dialogAnimation(context), builder: (context) => AlertDialog(
      title: const Text('Replace the instrument?'),
      content: Text('${track.name} plays $old. Replace it with ${asset.name}?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Replace')),
      ],
    ));
    if (ok != true) return false;
  }
  return state.dropAsset(track, asset, atStep: atStep);
}

/// The empty area below the last track (REAPER: drop an item, file, FX or instrument there for a new track with
/// it; double-click it for a new track). The lane side takes the drop step from where it lands.
class NewTrackZone extends StatelessWidget {
  const NewTrackZone({super.key, required this.state, required this.drag, required this.height, this.stepW,
    this.header = false});
  final AppState state;
  final ArrangeDrag drag;
  final double height;

  /// Pixels per step on the lane side (null on the header side: a drop lands at the song's start).
  final double? stepW;
  final bool header;

  @override
  Widget build(BuildContext context) {
    return DragTarget<AssetDrag>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) {
        final box = context.findRenderObject() as RenderBox?;
        final x = box == null || stepW == null ? 0.0 : box.globalToLocal(d.offset).dx;
        state.dropOnNewTrack(d.data, atStep: stepW == null ? 0 : (x / stepW!).floor().clamp(0, 1 << 30));
      },
      builder: (context, assets, _) => ValueListenableBuilder<DragSpot?>(
        valueListenable: drag.hover,
        builder: (context, spot, _) {
          final on = (assets.isNotEmpty || (spot?.newTrack ?? false));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: header ? () => state.addEmptyTrack() : null,
            // Long-press: the add-track menu with the track templates (docs/reaper-flow.md, Templates).
            onLongPressStart: header ? (d) => showAddTrackMenu(context, state, d.globalPosition) : null,
            // A right-click opens the same menu with a mouse, anywhere in the zone.
            onSecondaryTapUp: (d) => showAddTrackMenu(context, state, d.globalPosition),
            child: SizedBox(height: height, child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
              child: Align(alignment: Alignment.topLeft, child: AnimatedOpacity(
                duration: const Duration(milliseconds: 90),
                opacity: on ? 1 : 0,
                child: Container(
                  key: ValueKey(header ? 'new-track-indicator-header' : 'new-track-indicator'),
                  height: 40,
                  decoration: BoxDecoration(
                    color: Neon.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: Neon.green.withValues(alpha: 0.8), width: 1.2)),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: header
                      ? const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.add, size: 14, color: Neon.green),
                          SizedBox(width: 4),
                          Flexible(child: Text('New track', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Neon.green, fontSize: 11, fontWeight: FontWeight.w700))),
                        ])
                      : const SizedBox.expand(),
                ),
              )),
            )),
          );
        },
      ),
    );
  }
}
