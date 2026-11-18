// A track's automation lanes in the arranger, REAPER-style: rows under the track behind its envelope button, edited
// in place with the tool row's tools (select, pencil, line, shapes, eraser), curved segments and box transforms.
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_edit.dart';
import '../../model/arrange_fx.dart';
import '../../model/automation_curve.dart';
import '../../model/automation_edit.dart';
import '../../model/automation_writer.dart';
import '../../model/clip_automation.dart';
import '../../model/clip_loop_edit.dart';
import '../../model/project.dart';
import '../feedback.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../volume_fader.dart' show VolumeTaper;
import '../pointer_input.dart';
import 'lane_tools.dart';
import 'long_press_menu.dart';

/// A clip lane's row height in the piano roll: compact, and still a finger's height for its points (phone first).
const double kLaneRowHeight = 40;

/// A track lane's row height under it until it is dragged (#230: bigger, for the tools).
const double kArrangeLaneHeight = 56;

/// The roll's "+ lane" row under a clip's lanes.
const double kLaneAddRowHeight = 26;

/// The tool row under a track's open lanes (Automate and the tools).
const double kLaneToolRowHeight = 32;

/// Whether [layer] can have lanes: a track, or a folder with a group bus (its volume and pan act on the bus).
bool canHaveLanes(LayerDoc layer) => !layer.isFolder || layer.busEnabled;

/// The height a track's open lanes add under it (none while they are hidden).
double lanesHeight(AppState state, LayerDoc layer) => !layer.showLanes || !canHaveLanes(layer)
    ? 0 : arrangeLanes(state, layer).fold<double>(0, (h, l) => h + l.height) + kLaneToolRowHeight;

final _heightDrag = Expando<ValueNotifier<(String, double)?>>('lane height drag');

/// A lane row's height while its bottom edge is dragged (its key and height), so its header and row move together.
ValueNotifier<(String, double)?> laneHeightDrag(AppState state) =>
    _heightDrag[state] ??= ValueNotifier<(String, double)?>(null);

/// One lane under a track: its volume or pan ([AutomationLaneDoc]) or a parameter of its instrument or of one of
/// its native effects (a project lane, [ProjectAutomationLaneDoc], with this track's [LayerDoc.id]). The same
/// lanes the Automation panel edits and the Automate button writes.
class ArrangeLane {
  ArrangeLane._(this.state, this.layer, this.key, this.name, this.color, this._track, this._project,
      {this.min = 0, this.max = 1, this.clip, ClipAutomationLaneDoc? clipLane}) : _clip = clipLane;

  /// A clip's lane ([ClipDoc.automation]), in the clip's own time, as the piano roll edits it.
  static ArrangeLane? ofClip(AppState state, LayerDoc layer, ClipDoc clip, ClipAutomationLaneDoc lane) {
    final look = _laneLook(state, layer, lane.targetType, lane.target, lane.component);
    if (look == null) return null;
    return ArrangeLane._(state, layer, 'clip|${clip.id}|${lane.keyOn(layer.id)}', look.name, look.color, null, null,
        min: look.min, max: look.max, clip: clip, clipLane: lane);
  }

  final AppState state;
  final LayerDoc layer;
  final String key, name;
  final Color color;
  final AutomationLaneDoc? _track;
  final ProjectAutomationLaneDoc? _project;
  final ClipAutomationLaneDoc? _clip;
  final double min, max;

  /// The clip whose lane this is (null for a track's or the project's lane).
  final ClipDoc? clip;
  ClipAutomationLaneDoc? get clipLane => _clip;

  String? get _trackTarget => _track?.target ?? (_clip?.isTrack == true ? _clip!.target : null);

  bool get isVolume => _trackTarget == 'volume';

  List<AutomationPointDoc> get points => _track?.points ?? _project?.points ?? _clip!.points;

  /// Its row's height: as being dragged, as saved, or the default (a clip lane in the roll keeps the compact row).
  double get height {
    final d = laneHeightDrag(state).value;
    if (d != null && d.$1 == key) return d.$2;
    return _track?.height ?? _project?.height ?? (_clip != null ? kLaneRowHeight : kArrangeLaneHeight);
  }

  /// Whether its row's height can be dragged (a track's lanes; a clip's in the roll keep theirs).
  bool get resizable => _clip == null;

  /// Saves its row's height (null: back to the default). Screen only.
  void setHeight(double? h) {
    if (_clip != null) return;
    final v = h?.clamp(kMinLaneHeight, kMaxLaneHeight).toDouble();
    state.editProject((_) => _track != null ? _track.height = v : _project!.height = v);
  }

  /// A step on the arranger's grid (its snap setting); Shift, and a clip's lane in the roll, are free.
  double snap(double step) => _clip != null || HardwareKeyboard.instance.isShiftPressed
      ? step : snapStep(step, state.arrangementSnapSteps);

  /// The grid the shape tool draws a cycle on.
  double get grid => _clip != null ? 1 : math.max(1, state.arrangementSnapSteps).toDouble();

  /// A value as a height through the lane, 0 at the bottom and 1 at the top (volume on the faders' taper).
  double fraction(double value) {
    if (isVolume) return VolumeTaper.position(value);
    return max > min ? ((value - min) / (max - min)).clamp(0.0, 1.0).toDouble() : 0.5;
  }

  double valueAt(double fraction) {
    final f = fraction.clamp(0.0, 1.0).toDouble();
    return isVolume ? VolumeTaper.gain(f) : min + f * (max - min);
  }

  /// [v] within what the lane can hold.
  double clampValue(double v) => _trackTarget == 'volume'
      ? v.clamp(0.0, kMaxMixGain).toDouble()
      : _trackTarget == 'pan' ? v.clamp(-1.0, 1.0).toDouble() : v.clamp(min, max).toDouble();

  String label(double value) => isVolume
      ? VolumeTaper.label(value)
      : _trackTarget != null ? '${(value * 100).round()}%' : value.toStringAsFixed(max - min > 10 ? 0 : 2);

  void add(double step, double value) => _clip != null
      ? state.addClipLanePoint(layer, clip!, _clip, step, value.clamp(min, max).toDouble())
      : _track != null
          ? state.addAutomationPoint(layer, _track, step, value)
          : state.addProjectAutomationPoint(_project!, step, value.clamp(min, max).toDouble());

  void move(int index, double step, double value) => _clip != null
      ? state.updateClipLanePoint(layer, clip!, _clip, index, step, value.clamp(min, max).toDouble())
      : _track != null
          ? state.updateAutomationPoint(layer, _track, index, step, value)
          : state.updateProjectAutomationPoint(_project!, index, step, value.clamp(min, max).toDouble());

  void remove(int index) => _clip != null
      ? state.removeClipLanePoint(layer, clip!, _clip, index)
      : _track != null
          ? state.removeAutomationPoint(layer, _track, index)
          : state.removeProjectAutomationPoint(_project!, index);

  /// The lane's points replaced by [next] (time order; values held to the lane's range, steps to the song or the
  /// clip's loop). Call it between [AppState.beginAutomationGesture] and [AppState.endAutomationGesture], or use
  /// [edit] for one undo step.
  void setPoints(List<AutomationPointDoc> next) {
    final end = _clip != null ? state.project.clipLoopSteps(clip!).toDouble() : state.project.maxArrangementSteps.toDouble();
    final clean = [
      for (final p in next) p.copy(step: p.step.clamp(0.0, end).toDouble(), value: clampValue(p.value)),
    ]..sort((a, b) => a.step.compareTo(b.step));
    if (_clip != null) {
      state.editLayer(layer, (_) => _clip.points = clean);
    } else if (_track != null) {
      state.editLayer(layer, (_) => _track.points = clean);
    } else {
      state.editProject((_) => _project!.points = clean);
    }
  }

  /// [setPoints] as one automation undo step.
  void edit(List<AutomationPointDoc> next) {
    state.beginAutomationGesture();
    setPoints(next);
    state.endAutomationGesture();
  }

  void delete() => _clip != null
      ? state.removeClipLane(layer, clip!, _clip)
      : _track != null ? state.removeAutomationLane(layer, _track) : state.removeProjectAutomationLane(_project!);

  /// The clip [moveToClip] would take this track lane into: the selected clip on the track, else its first one.
  ClipDoc? get clipTarget {
    if (_clip != null || (_project != null && _project.targetType != 'instrument' && _project.targetType != 'component')) {
      return null;
    }
    return layer.clips.where((c) => c.id == state.selectedClipId).firstOrNull ?? layer.clips.firstOrNull;
  }

  /// "Move to clip" (a track lane) or "Move to track" (a clip lane): one undo step.
  void moveToClip(ClipDoc target) => state.moveTrackLaneToClip(layer, target, key);
  void moveToTrack() => state.moveClipLaneToTrack(layer, clip!, _clip!);

  /// Whether the Automate button writes this lane (REAPER's envelope arm). Clip lanes are drawn, not written.
  bool get armed => _clip != null || (_track?.armed ?? _project!.armed);

  /// Arms or disarms it: one undo step.
  void setArmed(bool on) {
    if (on == armed || _clip != null) return;
    state.endUndoStep();
    state.editProject((_) => _track != null ? _track.armed = on : _project!.armed = on);
    state.endUndoStep();
  }
}

/// A lane's name, colour and value range on [layer]: volume and pan, or a parameter of its instrument or an effect.
/// Null when the target isn't on the track (an effect that's gone).
({String name, Color color, double min, double max})? _laneLook(AppState state, LayerDoc layer, String targetType,
    String target, int? component) {
  if (targetType == 'track') {
    return (name: target == 'volume' ? 'Volume' : target == 'pan' ? 'Pan' : target,
        color: target == 'volume' ? Neon.green : Neon.blue, min: -1.0, max: 1.0);
  }
  final id = switch (targetType) {
    'instrument' => layer.instrument?.id,
    'component' when (component ?? -1) >= 0 && component! < layer.components.length => layer.components[component].id,
    _ => null,
  };
  if (id == null) return null;
  final info = state.componentInfo(id);
  final param = info?.parameters.where((p) => p.id == target).firstOrNull;
  final device = info?.label ?? state.componentLabel(id);
  return (name: '$device · ${param?.name.isNotEmpty == true ? param!.name : target}', color: Neon.violet,
      min: param?.min ?? 0.0, max: param?.max ?? 1.0);
}

/// [layer]'s lanes, in order: volume and pan first, then its instrument's and effects' parameters.
List<ArrangeLane> arrangeLanes(AppState state, LayerDoc layer) {
  ArrangeLane? native(ProjectAutomationLaneDoc lane) {
    final look = _laneLook(state, layer, lane.targetType, lane.target, lane.component);
    if (look == null || lane.targetType == 'track') return null;
    return ArrangeLane._(state, layer, lane.key, look.name, look.color, null, lane, min: look.min, max: look.max);
  }

  return [
    for (final lane in layer.automation)
      ArrangeLane._(state, layer, automationKey('track', lane.target, layerId: layer.id),
          lane.target == 'volume' ? 'Volume' : lane.target == 'pan' ? 'Pan' : lane.target,
          lane.target == 'volume' ? Neon.green : Neon.blue, lane, null, min: -1, max: 1),
    for (final lane in state.project.automation)
      if (lane.layerId == layer.id) ?native(lane),
  ];
}

/// What a clip's "Automation" picker can add to [clip] on [layer]: (value, label) pairs (volume, pan, then its
/// instrument's and effects' automatable parameters), less the clip's own lanes; [addClipArrangeLane] takes the value.
List<(String, String)> addableClipLanes(AppState state, LayerDoc layer, ClipDoc clip) {
  bool has(String type, String target, int? component) =>
      clip.automation.any((a) => a.targetType == type && a.target == target && a.component == component);
  final out = <(String, String)>[
    for (final target in const ['volume', 'pan'])
      if (!has('track', target, null)) ('track|$target', target == 'volume' ? 'Volume' : 'Pan'),
  ];
  final instrument = layer.instrument;
  if (instrument != null) {
    final info = state.componentInfo(instrument.id);
    for (final p in info?.parameters ?? const []) {
      if (p.automatable && !has('instrument', p.id, null)) out.add(('instrument|${p.id}', '${info!.label} · ${p.name.isEmpty ? p.id : p.name}'));
    }
  }
  for (var i = 0; i < layer.components.length; i++) {
    final info = state.componentInfo(layer.components[i].id);
    for (final p in info?.parameters ?? const []) {
      if (p.automatable && !has('component', p.id, i)) out.add(('component|$i|${p.id}', '${info!.label} · ${p.name.isEmpty ? p.id : p.name}'));
    }
  }
  return out;
}

/// Adds the clip lane [value] names (from [addableClipLanes]): one undo step.
void addClipArrangeLane(AppState state, LayerDoc layer, ClipDoc clip, String value) {
  final parts = value.split('|');
  if (parts.length == 2 && (parts.first == 'track' || parts.first == 'instrument')) {
    state.addClipLane(layer, clip, parts.first, parts[1]);
  } else if (parts.length == 3 && parts.first == 'component') {
    final i = int.tryParse(parts[1]);
    if (i != null && i >= 0 && i < layer.components.length) state.addClipLane(layer, clip, 'component', parts[2], component: i);
  }
}

/// The lanes' names under a track's header: a row per lane (name, arm, ×; its bottom edge drags its height) and the
/// tool row (Automate and the tools).
class TrackLaneHeaders extends StatelessWidget {
  const TrackLaneHeaders({super.key, required this.state, required this.layer, required this.indent});
  final AppState state;
  final LayerDoc layer;
  final double indent;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<(String, double)?>(
    valueListenable: laneHeightDrag(state),
    builder: (context, _, _) {
      final lanes = arrangeLanes(state, layer);
      return Column(children: [
        for (final lane in lanes)
          Container(key: ValueKey('lane-header-${lane.key}'), height: lane.height,
            padding: EdgeInsets.only(left: 10 + indent),
            decoration: BoxDecoration(color: Color.lerp(Neon.panel, lane.color, 0.08),
              border: Border(left: BorderSide(color: lane.color.withValues(alpha: 0.6), width: 2),
                bottom: BorderSide(color: Neon.line.withValues(alpha: 0.6)))),
            child: Stack(children: [
              Positioned.fill(child: Row(children: [
                // The lane's menu: a long press or double tap on its name, or a right-click (Move to clip).
                Expanded(child: GestureDetector(key: ValueKey('lane-name-${lane.key}'), behavior: HitTestBehavior.opaque,
                  onLongPressStart: (d) => laneMenu(context, lane, d.globalPosition),
                  onDoubleTapDown: (d) => laneMenu(context, lane, d.globalPosition),
                  onSecondaryTapDown: (d) => laneMenu(context, lane, d.globalPosition),
                  child: Align(alignment: Alignment.centerLeft, child: Text(lane.name,
                    maxLines: lane.height >= 52 ? 3 : 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: lane.color))))),
                // Arm (REAPER's envelope arm): the Automate button writes only armed lanes; new lanes start armed.
                SizedBox(width: 26, height: math.min(40, lane.height), child: Pressable(child: IconButton(
                  key: ValueKey('lane-arm-${lane.key}'),
                  padding: EdgeInsets.zero, iconSize: 15, isSelected: lane.armed,
                  tooltip: lane.armed ? 'Armed: Automate writes it (${PointerInput.tap} to disarm)' : 'Disarmed: only plays (${PointerInput.tap} to arm)',
                  icon: Icon(lane.armed ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: lane.armed ? Neon.pink : Neon.dim),
                  onPressed: () {
                    Haptics.tap();
                    lane.setArmed(!lane.armed);
                  }))),
                // 26 px wide and a finger's height: a target in a compact row, leaving the name room beside the arm.
                SizedBox(width: 26, height: math.min(40, lane.height), child: Pressable(child: IconButton(
                  key: ValueKey('lane-remove-${lane.key}'),
                  padding: EdgeInsets.zero, tooltip: 'Remove lane', iconSize: 15,
                  icon: const Icon(Icons.close, color: Neon.dim),
                  onPressed: lane.delete))),
              ])),
              // The bottom edge: drag the lane's height (saved per lane); a double tap goes back to the default.
              if (lane.resizable) Positioned(left: 0, right: 0, bottom: 0, height: 8,
                child: LaneHeightGrip.of(lane, key: ValueKey('lane-height-${lane.key}'))),
            ])),
        LaneToolRow(state: state, layer: layer, height: kLaneToolRowHeight),
      ]);
    });
}

/// A lane's bottom edge: drags its height, header and row together, and saves it when let go (an automation lane's,
/// and a track's take lanes'). While it moves, [laneHeightDrag] holds ([dragKey], the height) for the rows to read.
/// [rowsAbove]: how many rows of the same height end at this edge (take lanes share one height), so the edge stays
/// under the finger.
class LaneHeightGrip extends StatefulWidget {
  const LaneHeightGrip({super.key, required this.state, required this.dragKey, required this.color,
      required this.height, required this.onSave, this.rowsAbove = 1});
  final AppState state;
  final String dragKey;
  final Color color;
  final double Function() height;

  /// Saves the height (null: back to the default, a double tap).
  final void Function(double? height) onSave;
  final int rowsAbove;

  /// The grip on [lane]'s bottom edge.
  static LaneHeightGrip of(ArrangeLane lane, {Key? key}) => LaneHeightGrip(key: key, state: lane.state,
      dragKey: lane.key, color: lane.color, height: () => lane.height, onSave: lane.setHeight);

  @override
  State<LaneHeightGrip> createState() => _LaneHeightGripState();
}

class _LaneHeightGripState extends State<LaneHeightGrip> {
  double _start = 0, _dy = 0;

  ValueNotifier<(String, double)?> get _drag => laneHeightDrag(widget.state);

  @override
  Widget build(BuildContext context) => MouseRegion(cursor: SystemMouseCursors.resizeRow, child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    dragStartBehavior: DragStartBehavior.down,
    onDoubleTap: () {
      Haptics.tap();
      widget.onSave(null);
    },
    onVerticalDragStart: (_) {
      _start = widget.height();
      _dy = 0;
      Haptics.grab();
    },
    onVerticalDragUpdate: (d) {
      _dy += d.delta.dy;
      _drag.value = (widget.dragKey,
          (_start + _dy / math.max(1, widget.rowsAbove)).clamp(kMinLaneHeight, kMaxLaneHeight).toDouble());
    },
    onVerticalDragEnd: (_) => _end(),
    onVerticalDragCancel: _end,
    child: Center(child: Container(width: 24, height: 3, decoration: BoxDecoration(
      color: widget.color.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(2)))),
  ));

  void _end() {
    final d = _drag.value;
    _drag.value = null;
    if (d != null && d.$1 == widget.dragKey) widget.onSave(d.$2);
    Haptics.drop();
  }
}

/// A lane's menu (sectioned, as the Arrange menus are): a track lane moves into a clip on its track (the selected
/// one, else the first; its first loop's values, in clip time), a clip lane onto the track; either can be removed.
Future<void> laneMenu(BuildContext context, ArrangeLane lane, Offset at) async {
  final target = lane.clipTarget;
  final state = lane.state;
  final v = await showLongPressMenu<String>(context, at: at, title: lane.name, style: state.settings.longPressMenu, actions: [
    if (lane.clip != null)
      const MenuAction('to-track', 'Move to track', Icons.vertical_align_bottom, section: 'Lane')
    else if (target != null)
      MenuAction('to-clip', 'Move to clip «${state.clipName(target)}»', Icons.vertical_align_top, section: 'Lane'),
    const MenuAction('remove', 'Remove lane', Icons.close, danger: true, section: 'Lane'),
  ]);
  if (v == 'to-track') lane.moveToTrack();
  if (v == 'to-clip' && target != null) lane.moveToClip(target);
  if (v == 'remove') lane.delete();
}

/// A track's lanes on the timeline: one [LaneRow] per lane and the tool row's space, level with [TrackLaneHeaders].
class TrackLaneRows extends StatelessWidget {
  const TrackLaneRows({super.key, required this.state, required this.layer, required this.stepW,
      required this.width});
  final AppState state;
  final LayerDoc layer;
  final double stepW, width;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<(String, double)?>(
    valueListenable: laneHeightDrag(state),
    builder: (context, _, _) => Column(children: [
      for (final lane in arrangeLanes(state, layer))
        LaneRow(key: ValueKey('lane-row-${lane.key}'), lane: lane, stepW: stepW, width: width, tools: true),
      SizedBox(width: width, height: kLaneToolRowHeight),
    ]));
}

/// What a drag on the selection box does.
enum _Xform { move, scaleTop, scaleBottom, tiltLeft, tiltRight }

/// One lane, edited where it is drawn (REAPER, UG 18.14–18.15, pp. 367–368: a click adds a point, a drag moves a
/// point or a segment, Alt+click deletes a point). With the select tool (the default) a tap adds a point, a tap on a
/// point selects it, a drag on a point moves it from the first touch (the whole selection when it is in one; the
/// timeline's scroll never takes it, #241), a double-tap on a point
/// deletes it, a hold on a point or a segment's handle opens its menu, and the handle in the middle of a segment
/// drags the segment up or down, or bends it when dragged sideways (or with Alt or Ctrl). A long-press drag on empty
/// space (a mouse: a drag) draws a selection box; its body moves the points, its top and bottom edges scale them
/// and its corners tilt them. Other drags on empty space scroll the timeline. With [tools] the tool row's pencil,
/// line, shape and eraser draw instead. With a mouse (owner, 2026-11-11) a click selects a point (Shift-click adds
/// one), a double-click adds a point or removes the one under it, a right-click opens a menu, Shift drags finely,
/// and Delete, Ctrl+C, Ctrl+V and Ctrl+A work on the selection.
class LaneRow extends StatefulWidget {
  const LaneRow({super.key, required this.lane, required this.stepW, required this.width, this.tools = false,
      this.reveal = true});
  final ArrangeLane lane;
  final double stepW, width;

  /// Whether Automate's request to show this lane scrolls this row into view (the arranger's; the focus view's
  /// Automation tab draws the same lane again and leaves the request to it).
  final bool reveal;

  /// Whether the tool row's tools apply (the arranger's lanes; the roll's clip lanes keep the select tool).
  final bool tools;

  @override
  State<LaneRow> createState() => _LaneRowState();
}

class _LaneRowState extends State<LaneRow> {
  static const _pad = 5.0; // keeps the top and bottom values off the row's edges
  double get _h => lane.height;
  // A drag's running position, so a point follows the finger rather than snapping between frames.
  Offset _grab = Offset.zero;

  /// The selected points (indices), for Delete, copy and the selection box; and the clicks, told from double-clicks.
  Set<int> _selected = {};
  final _clicks = ClickCounter();
  static const _surface = -1; // the surface's presses, told apart from each point's (its index)
  final _keys = FocusNode(debugLabel: 'lane-row');

  // A box being drawn (local pixels), and where it started.
  Rect? _box;
  Offset _boxFrom = Offset.zero;
  bool _boxAdds = false;

  // A tool's drag: the pencil's samples (step, height), or the line's, shape's and eraser's start and end.
  List<(double, double)>? _stroke;
  Offset? _from, _to;

  // A selection transform: what it does, the points and selection it started from, and how far it has gone.
  _Xform? _xform;
  List<AutomationPointDoc> _origin = const [];
  Set<int> _originSelected = const {};
  Offset _moved = Offset.zero;

  // A segment handle's drag: whether it bends (decided once it moves) and the bend it started from.
  bool? _bending;
  double _bend0 = 0;
  Offset _segMoved = Offset.zero;

  // A press on a point: how far it has moved, whether that made it a drag (past [_pressSlop]: a finger's tap jitters),
  // whether it was held still long enough for the point's menu (opened on release), and where it went down.
  Offset _pressMoved = Offset.zero;
  bool _pressDragging = false, _pressHeld = false;
  double _pressSlop = 6;
  Offset _pressAt = Offset.zero;
  Timer? _pressHold;

  // A hold on a segment's handle (its menu, after a still half second) while its eager drag waits.
  Timer? _segHold;
  bool _segMenu = false;

  /// Shift drags a fifth as far (fine control).
  static double get _rate => HardwareKeyboard.instance.isShiftPressed ? 0.2 : 1;

  LaneTool get _tool => widget.tools ? laneToolOf(lane.state).value.tool : LaneTool.select;

  @override
  void initState() {
    super.initState();
    if (widget.tools) laneToolOf(lane.state).addListener(_toolChanged);
    lane.state.automationReveal.addListener(_reveal);
    _reveal();
  }

  @override
  void dispose() {
    if (widget.tools) laneToolOf(lane.state).removeListener(_toolChanged);
    lane.state.automationReveal.removeListener(_reveal);
    _segHold?.cancel();
    _pressHold?.cancel();
    _keys.dispose();
    super.dispose();
  }

  void _toolChanged() => setState(() {
    _box = null;
    _stroke = null;
    _from = _to = null;
  });

  /// Automate asked for this lane: once it is laid out, the view scrolls it into the middle (vertically).
  void _reveal() {
    if (!widget.reveal || lane.state.automationReveal.value != lane.key || lane.clip != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || lane.state.automationReveal.value != lane.key) return;
      lane.state.automationReveal.value = null;
      final box = context.findRenderObject();
      final pos = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
      if (box == null || pos == null) return;
      pos.ensureVisible(box, alignment: 0.5, duration: Motion.move(Motion.panel, Motion.of(context)),
          curve: Curves.easeOutCubic);
    });
  }

  @override
  void didUpdateWidget(LaneRow old) {
    super.didUpdateWidget(old);
    _selected = {for (final i in _selected) if (i < lane.points.length) i};
  }

  ArrangeLane get lane => widget.lane;
  double _y(double value) => _pad + (1 - lane.fraction(value)) * (_h - 2 * _pad);
  double _value(double y) => lane.valueAt(_frac(y));
  double _frac(double y) => (1 - (y - _pad) / (_h - 2 * _pad)).clamp(0.0, 1.0).toDouble();
  double _x(double step) => step * widget.stepW;
  double _step(double x) => math.max(0, x / widget.stepW);

  int? _pointNear(Offset at) {
    int? best;
    var bestD = 18.0;
    for (var i = 0; i < lane.points.length; i++) {
      final p = lane.points[i];
      final d = (Offset(_x(p.step), _y(p.value)) - at).distance;
      if (d < bestD) (best, bestD) = (i, d);
    }
    return best;
  }

  /// A tap on point [i]: it becomes the selection (a mouse's Shift-click adds or takes it away); a double tap or a
  /// double-click removes it.
  void _clickPoint(int i) {
    if (_clicks.mouse) _keys.requestFocus();
    if (_clicks.doubleClick || _clicks.doubleTap) {
      lane.remove(i);
      return setState(() => _selected = {});
    }
    setState(() {
      if (_clicks.mouse && HardwareKeyboard.instance.isShiftPressed) {
        _selected = _selected.contains(i) ? ({..._selected}..remove(i)) : {..._selected, i};
      } else {
        _selected = {i};
      }
    });
  }

  /// Removes the selected points as one undo step.
  void _deleteSelected() {
    if (_selected.isEmpty) return;
    final pts = lane.points;
    lane.edit([for (var i = 0; i < pts.length; i++) if (!_selected.contains(i)) pts[i]]);
    setState(() => _selected = {});
  }

  void _copy({int? point}) {
    final sel = _selected.isNotEmpty ? _selected : {?point};
    final c = AutomationClipboard.of(lane.points, sel, toHeight: lane.fraction);
    if (c == null) return;
    AutomationClipboard.current = c;
    Haptics.tap();
  }

  /// Pastes what was copied at the playhead (stopped: where play starts), over what the lane had there.
  void _paste() {
    final c = AutomationClipboard.current;
    if (c == null) return;
    final at = lane.clip != null ? 0.0 : lane.snap(lane.state.automationCursor);
    final r = c.pasteInto(lane.points, at, toValue: lane.valueAt);
    lane.edit(r.points);
    setState(() => _selected = r.selected);
  }

  /// Every segment's curve back to a straight line (the points stay): one undo step.
  void _resetCurves() => lane.edit([for (final p in lane.points) p.copy()..curve = AutomationCurve.linear..tension = 0]);

  void _setCurve(int i, AutomationCurve c) {
    final pts = [for (final p in lane.points) p.copy()];
    if (i < 0 || i >= pts.length) return;
    pts[i]
      ..curve = c
      ..tension = 0;
    lane.edit(pts);
  }

  /// A point's, a segment's or the lane's own menu (a hold, or a right-click).
  Future<void> _menu(Offset at, {int? point, int? segment}) async {
    final pts = lane.points;
    final seg = segment ?? (point != null && point + 1 < pts.length ? point : null);
    final curve = seg == null ? null : pts[seg].curve;
    final many = _selected.length > 1;
    final v = await showLongPressMenu<String>(context, at: at, title: lane.name, style: lane.state.settings.longPressMenu,
        actions: [
          if (point != null) const MenuAction('delete', 'Delete point', Icons.delete_outline, section: 'Point'),
          if (many)
            MenuAction('delete-selected', 'Delete ${_selected.length} selected points', Icons.delete_sweep_outlined,
                section: 'Selection'),
          if (point != null || _selected.isNotEmpty)
            MenuAction('copy', many ? 'Copy ${_selected.length} points' : 'Copy', Icons.copy, section: 'Selection'),
          if (AutomationClipboard.current != null && lane.clip == null)
            const MenuAction('paste', 'Paste at playhead', Icons.content_paste, section: 'Selection'),
          if (point == null && segment == null && pts.isNotEmpty)
            const MenuAction('select-all', 'Select all', Icons.select_all, section: 'Selection'),
          if (seg != null)
            for (final c in AutomationCurve.values)
              MenuAction('curve-${c.name}', c.label, _curveIcon(c), checked: c == curve, section: 'Curve'),
          if (segment != null) const MenuAction('flatten', 'Flatten segment', Icons.horizontal_rule, section: 'Segment'),
          if (pts.any((p) => p.curve != AutomationCurve.linear))
            const MenuAction('reset', 'Reset curves', Icons.restart_alt, section: 'Lane'),
        ]);
    if (v == null || !mounted) return;
    switch (v) {
      case 'delete' when point != null && point < lane.points.length:
        lane.state.beginAutomationGesture();
        lane.remove(point);
        lane.state.endAutomationGesture();
        setState(() => _selected = {});
      case 'delete-selected':
        _deleteSelected();
      case 'copy':
        _copy(point: point);
      case 'paste':
        _paste();
      case 'select-all':
        setState(() => _selected = {for (var i = 0; i < lane.points.length; i++) i});
      case 'flatten' when segment != null && segment + 1 < lane.points.length:
        final next = [for (final p in lane.points) p.copy()];
        final mid = (next[segment].value + next[segment + 1].value) / 2;
        next[segment].value = next[segment + 1].value = mid;
        lane.edit(next);
      case 'reset':
        _resetCurves();
      default:
        if (v.startsWith('curve-') && seg != null) {
          _setCurve(seg, AutomationCurve.values.firstWhere((c) => 'curve-${c.name}' == v));
        }
    }
  }

  // ---- point drags ----

  void _pointDrag(int index) {
    final p = lane.points[index];
    _grab = Offset(_x(p.step), _y(p.value));
    lane.state.beginAutomationGesture();
    Haptics.grab();
    if (_selected.length > 1 && _selected.contains(index)) _startXform(_Xform.move);
  }

  void _pointMove(int index, Offset delta) {
    if (_xform != null) return _xformMove(delta);
    if (index >= lane.points.length) return;
    _grab += delta * _rate;
    lane.move(index, lane.snap(_step(_grab.dx)), _value(_grab.dy));
  }

  void _pressDown(Offset global) {
    _pressMoved = Offset.zero;
    _pressDragging = _pressHeld = false;
    _pressAt = global;
    _pressHold?.cancel();
    _pressHold = Timer(kLongPressTimeout, () {
      if (!mounted || _pressDragging) return;
      _pressHeld = true;
      Haptics.tap();
    });
  }

  /// The press moved: past the slop it drags the point, caught up to the finger at once (no lag, no jump later).
  void _pressMove(int index, Offset delta) {
    if (_pressDragging) return _pointMove(index, delta);
    _pressMoved += delta;
    if (_pressMoved.distance < _pressSlop || index >= lane.points.length) return;
    _pressDragging = true;
    _pressHold?.cancel();
    _pointDrag(index);
    _pointMove(index, _pressMoved);
  }

  void _pressUp(int index, {bool cancelled = false}) {
    _pressHold?.cancel();
    if (_pressDragging) {
      _pressDragging = false;
      return _end();
    }
    if (cancelled || index >= lane.points.length) return;
    if (_pressHeld) {
      _pressHeld = false;
      _menu(_pressAt, point: index);
    } else {
      _clickPoint(index);
    }
  }

  void _end() {
    _xform = null;
    lane.state.endAutomationGesture();
    Haptics.drop();
  }

  // ---- segment handles ----

  // The undo step opens with the first move, so a press that moves nothing (a hold for the menu) leaves none.
  void _segmentStart(int i) {
    Haptics.grab();
    _bending = null;
    _segMoved = Offset.zero;
    _bend0 = bendOf(lane.points[i]);
  }

  void _segmentUpdate(int i, Offset delta) {
    if (i + 1 >= lane.points.length || delta == Offset.zero) return;
    lane.state.beginAutomationGesture();
    _segMoved += delta;
    final modifier = HardwareKeyboard.instance.isAltPressed || HardwareKeyboard.instance.isControlPressed;
    _bending ??= modifier || _segMoved.dx.abs() > _segMoved.dy.abs();
    if (_bending! && lane.points[i].curve == AutomationCurve.step) return;
    if (!_bending!) {
      final df = -delta.dy * _rate / (_h - 2 * _pad);
      for (final k in [i, i + 1]) {
        final p = lane.points[k];
        lane.move(k, p.step, lane.valueAt(lane.fraction(p.value) + df));
      }
      return;
    }
    // Sideways: right bends it toward Fast (quick at first), left toward Slow. With a modifier, up bends it up.
    final rising = lane.fraction(lane.points[i + 1].value) >= lane.fraction(lane.points[i].value);
    final amount = modifier && _segMoved.dy.abs() > _segMoved.dx.abs()
        ? -_segMoved.dy / 40 * (rising ? 1 : -1) : _segMoved.dx / 80;
    final next = [for (final p in lane.points) p.copy()];
    withBend(next[i], _bend0 + amount * _rate);
    lane.setPoints(next);
  }

  // ---- the selection box ----

  /// The selection's box in local pixels (padded so its handles have room), or null for fewer than two points.
  Rect? get _selectionRect {
    if (_selected.length < 2) return null;
    final pts = lane.points;
    var r = Rect.zero;
    var first = true;
    for (final i in _selected) {
      if (i >= pts.length) continue;
      final at = Offset(_x(pts[i].step), _y(pts[i].value));
      r = first ? Rect.fromCenter(center: at, width: 0, height: 0) : r.expandToInclude(Rect.fromCenter(center: at, width: 0, height: 0));
      first = false;
    }
    if (first) return null;
    return Rect.fromLTRB(r.left - 8, math.min(r.top - 6, r.bottom - 14), r.right + 8, math.max(r.bottom + 6, r.top + 14));
  }

  void _startXform(_Xform kind) {
    _xform = kind;
    _origin = [for (final p in lane.points) p.copy()];
    _originSelected = {..._selected};
    _moved = Offset.zero;
  }

  void _xformMove(Offset delta) {
    final kind = _xform;
    if (kind == null || delta == Offset.zero) return;
    lane.state.beginAutomationGesture();
    _moved += delta * _rate;
    final pts = [for (final i in _originSelected) if (i < _origin.length) _origin[i]];
    if (pts.isEmpty) return;
    final dF = -_moved.dy / (_h - 2 * _pad);
    final heights = [for (final p in pts) lane.fraction(p.value)];
    final top = heights.reduce(math.max), bottom = heights.reduce(math.min);
    final x0 = pts.map((p) => p.step).reduce(math.min), x1 = pts.map((p) => p.step).reduce(math.max);
    final Transformed r;
    switch (kind) {
      case _Xform.move:
        final ds = lane.snap(x0 + _moved.dx / widget.stepW) - x0;
        r = moveSelection(_origin, _originSelected, math.max(-x0, ds), dF, toHeight: lane.fraction, toValue: lane.valueAt);
      case _Xform.scaleTop:
      case _Xform.scaleBottom:
        final up = kind == _Xform.scaleTop;
        final anchor = up ? bottom : top, edge = up ? top : bottom;
        r = (edge - anchor).abs() < 1e-6
            ? moveSelection(_origin, _originSelected, 0, dF, toHeight: lane.fraction, toValue: lane.valueAt)
            : scaleSelection(_origin, _originSelected, anchor, (edge + dF - anchor) / (edge - anchor),
                toHeight: lane.fraction, toValue: lane.valueAt);
      case _Xform.tiltLeft:
        r = tiltSelection(_origin, _originSelected, x0, x1, dF, 0, toHeight: lane.fraction, toValue: lane.valueAt);
      case _Xform.tiltRight:
        r = tiltSelection(_origin, _originSelected, x0, x1, 0, dF, toHeight: lane.fraction, toValue: lane.valueAt);
    }
    lane.setPoints(r.points);
    setState(() => _selected = r.selected);
  }

  /// A drag taken at the first touch ([EagerPan]): the selection box's body and handles.
  Map<Type, GestureRecognizerFactory> _eager({required VoidCallback start, required void Function(Offset delta) update,
          required VoidCallback end}) => {
        EagerPan: GestureRecognizerFactoryWithHandlers<EagerPan>(EagerPan.new, (r) => r
          ..dragStartBehavior = DragStartBehavior.down
          ..onStart = ((_) => start())
          ..onUpdate = ((d) => update(d.delta))
          ..onEnd = ((_) => end())
          ..onCancel = end),
      };

  void _xformStart(_Xform kind) {
    Haptics.grab();
    _startXform(kind);
  }

  // ---- box selection and the tools ----

  void _boxStart(Offset at, {bool adds = false}) {
    _boxFrom = at;
    _boxAdds = adds;
    setState(() => _box = Rect.fromPoints(at, at));
    Haptics.grab();
  }

  void _boxUpdate(Offset at) => setState(() => _box = Rect.fromPoints(_boxFrom, at));

  void _boxEnd() {
    final box = _box;
    if (box == null) return;
    final pts = lane.points;
    final inside = {
      for (var i = 0; i < pts.length; i++)
        if (box.inflate(4).contains(Offset(_x(pts[i].step), _y(pts[i].value)))) i,
    };
    setState(() {
      _selected = _boxAdds ? {..._selected, ...inside} : inside;
      _box = null;
    });
    if (inside.isNotEmpty) Haptics.drop();
  }

  void _drawStart(Offset at) {
    _from = _to = at;
    if (_tool == LaneTool.pencil) _stroke = [(_step(at.dx), _frac(at.dy))];
    Haptics.grab();
    setState(() {});
  }

  void _drawUpdate(Offset at) {
    _to = at;
    if (_tool == LaneTool.pencil) _stroke?.add((_step(at.dx), _frac(at.dy)));
    setState(() {});
  }

  /// The points the line or shape tool would put down now (heights), from the drag's start to where it is.
  List<AutomationPointDoc> _drawnPoints() {
    final a = _from, b = _to;
    if (a == null || b == null) return const [];
    switch (_tool) {
      case LaneTool.pencil:
        final s = _stroke;
        return s == null || s.length < 2 ? const [] : pencilPoints(s);
      case LaneTool.line:
        return linePoints((lane.snap(_step(a.dx)), _frac(a.dy)), (lane.snap(_step(b.dx)), _frac(b.dy)));
      case LaneTool.shape:
        final from = lane.snap(_step(math.min(a.dx, b.dx))), to = lane.snap(_step(math.max(a.dx, b.dx)));
        final choice = laneToolOf(lane.state).value;
        return shapePoints(choice.shape, from, to, lane.grid, _frac(a.dy), _frac(b.dy) - _frac(a.dy),
            seed: _seed(from));
      default:
        return const [];
    }
  }

  /// The random shape's seed: the same lane and place give the same values (with the project's seed).
  int _seed(double from) {
    var h = 0x811c9dc5 ^ lane.state.project.seed;
    for (final c in lane.key.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return (h ^ (from * 16).round()) & 0x7fffffff;
  }

  void _drawEnd() {
    final a = _from, b = _to;
    if (a != null && b != null) {
      if (_tool == LaneTool.eraser) {
        // A tap (no sweep) erases the nearest point; a sweep, every point it crossed.
        final near = (b.dx - a.dx).abs() < 4 ? _pointNear(a) : null;
        if ((b.dx - a.dx).abs() >= 4) {
          lane.edit(erasePoints(lane.points, _step(a.dx), _step(b.dx)));
        } else if (near != null) {
          lane.edit([for (var i = 0; i < lane.points.length; i++) if (i != near) lane.points[i]]);
        }
      } else {
        final drawn = [for (final p in _drawnPoints()) p..value = lane.valueAt(p.value)];
        if (drawn.length >= 2) lane.edit(replaceSpan(lane.points, drawn));
      }
      Haptics.drop();
    }
    setState(() {
      _from = _to = null;
      _stroke = null;
      _selected = {};
    });
  }

  void _surfaceTap(TapUpDetails d) {
    // A mouse: a click clears the point selection, a double-click adds a point.
    if (_clicks.mouse) {
      _keys.requestFocus();
      if (_selected.isNotEmpty) setState(() => _selected = {});
      if (!_clicks.doubleClick) return;
    }
    final near = _pointNear(d.localPosition);
    if (_tool == LaneTool.eraser) {
      if (near != null) lane.edit([for (var i = 0; i < lane.points.length; i++) if (i != near) lane.points[i]]);
      return;
    }
    if (_tool == LaneTool.shape) return;
    if (near != null) {
      if (_clicks.doubleTap) lane.remove(near);
      return;
    }
    if (_selected.isNotEmpty) setState(() => _selected = {});
    lane.add(lane.snap(_step(d.localPosition.dx)), _value(d.localPosition.dy));
  }

  KeyEventResult _key(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && k == LogicalKeyboardKey.keyC && _selected.isNotEmpty) {
      _copy();
    } else if (ctrl && k == LogicalKeyboardKey.keyV && AutomationClipboard.current != null && lane.clip == null) {
      _paste();
    } else if (ctrl && k == LogicalKeyboardKey.keyA) {
      setState(() => _selected = {for (var i = 0; i < lane.points.length; i++) i});
    } else if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && _selected.isNotEmpty) {
      _deleteSelected();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final points = lane.points;
    final tool = _tool;
    final select = tool == LaneTool.select;
    final writer = AutomationWriter.current;
    final size = Size(widget.width, _h);
    // The curve is recorded once in a layer of its own and repaints only when its points, zoom or selection change;
    // while the Automate button writes this lane, a small painter over it draws the values being written with the
    // playhead (beta plan B4.7).
    Widget still(Set<int> selected) => RepaintBoundary(child: CustomPaint(size: size,
      painter: _LanePainter(lane: lane, stepW: widget.stepW, pad: _pad, selected: selected)));
    final curve = still(_selected);
    final live = writer == null ? curve : ListenableBuilder(listenable: writer, builder: (context, child) =>
        writer.writing ? ValueListenableBuilder<int>(valueListenable: lane.state.tick,
            builder: (context, _, _) => Stack(children: [
              still(const {}),
              CustomPaint(size: size, painter: _LiveLanePainter(lane: lane, stepW: widget.stepW, pad: _pad,
                  live: writer.liveSamples(lane.key))),
            ]))
            : child!, child: curve);
    final sel = select && _box == null ? _selectionRect : null;
    // A preview of what a tool is drawing, or the box being drawn, over the curve.
    final preview = _from == null && _box == null ? null : CustomPaint(size: size, painter: _ToolPreview(
      tool: tool, color: lane.color, box: _box, from: _from, to: _to,
      points: tool == LaneTool.eraser ? const [] : [
        for (final p in _drawnPoints()) Offset(_x(p.step), _pad + (1 - p.value) * (_h - 2 * _pad)),
      ]));
    return Focus(
      focusNode: _keys,
      onKeyEvent: (_, e) => _key(e),
      child: SizedBox(width: widget.width, height: _h, child: Stack(clipBehavior: Clip.none, children: [
      // Taps answer at once; a finger's quick second tap near a point (outside its own target) also removes it.
      Positioned.fill(child: Listener(onPointerDown: (e) => _clicks.down(e, target: _surface), onPointerUp: _clicks.up,
        child: GestureDetector(
        key: ValueKey('lane-surface-${lane.key}'),
        behavior: HitTestBehavior.opaque,
        onTapUp: _surfaceTap,
        onSecondaryTapUp: (d) => _menu(d.globalPosition),
        // Select: a long-press drag draws a selection box; held and let go without moving, the lane's menu.
        onLongPressStart: select ? (d) => _boxStart(d.localPosition) : null,
        onLongPressMoveUpdate: select ? (d) => _boxUpdate(d.localPosition) : null,
        onLongPressEnd: select ? (d) {
          final box = _box;
          if (box != null && box.width < 6 && box.height < 6) {
            setState(() => _box = null);
            _menu(d.globalPosition);
          } else {
            _boxEnd();
          }
        } : null,
        onLongPressCancel: select ? () => setState(() => _box = null) : null,
        // A mouse's drag on empty space draws a selection box at once (Shift adds to the selection). The drawing
        // tools take any drag in the lane from its first touch (the timeline doesn't scroll under them).
        child: select ? GestureDetector(
          supportedDevices: const {PointerDeviceKind.mouse},
          behavior: HitTestBehavior.translucent,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: select ? (d) => _boxStart(d.localPosition, adds: HardwareKeyboard.instance.isShiftPressed) : null,
          onPanUpdate: select ? (d) => _boxUpdate(d.localPosition) : null,
          onPanEnd: select ? (_) => _boxEnd() : null,
          onPanCancel: select ? () => setState(() => _box = null) : null,
          child: RepaintBoundary(child: live))
          : RawGestureDetector(key: ValueKey('lane-draw-${lane.key}'), behavior: HitTestBehavior.opaque, gestures: {
              EagerPan: GestureRecognizerFactoryWithHandlers<EagerPan>(EagerPan.new, (r) => r
                ..onStart = ((d) => _drawStart(d.localPosition))
                ..onUpdate = ((d) => _drawUpdate(d.localPosition))
                ..onEnd = ((_) => _drawEnd())
                ..onCancel = (() => setState(() => _from = _to = null))),
            }, child: RepaintBoundary(child: live))))),
      if (preview != null) Positioned.fill(child: IgnorePointer(child: preview)),
      // Each segment's middle: a handle that drags it up or down, or bends it sideways (REAPER's segment drag).
      if (select)
        for (var i = 0; i + 1 < points.length; i++)
          if (_x(points[i + 1].step) - _x(points[i].step) > 40)
            Positioned(
              left: (_x(points[i].step) + _x(points[i + 1].step)) / 2 - 12,
              top: _y(segmentValueAt(points[i], points[i + 1], (points[i].step + points[i + 1].step) / 2)) - 12,
              width: 24, height: 24,
              // Its drag is taken at the first touch, so a sideways bend doesn't scroll the timeline; held still for
              // half a second, it opens the segment's menu instead.
              child: GestureDetector(onSecondaryTapUp: (d) => _menu(d.globalPosition, segment: i),
                child: RawGestureDetector(key: ValueKey('lane-segment-${lane.key}-$i'), behavior: HitTestBehavior.opaque,
                gestures: {
                  EagerPan: GestureRecognizerFactoryWithHandlers<EagerPan>(EagerPan.new, (r) => r
                    ..dragStartBehavior = DragStartBehavior.down
                    ..onDown = (d) {
                      _segMenu = false;
                      _segHold?.cancel();
                      _segHold = Timer(kLongPressTimeout, () {
                        if (!mounted) return;
                        _segMenu = true;
                        _menu(d.globalPosition, segment: i);
                      });
                    }
                    ..onStart = ((_) => _segmentStart(i))
                    ..onUpdate = (d) {
                      if (_segMenu) return;
                      if (_segMoved.distance + d.delta.distance > 3) _segHold?.cancel();
                      _segmentUpdate(i, d.delta);
                    }
                    ..onEnd = (_) {
                      _segHold?.cancel();
                      _end();
                    }
                    ..onCancel = () {
                      _segHold?.cancel();
                      _end();
                    }),
                },
                child: MouseRegion(cursor: SystemMouseCursors.resizeUpDown, child: Center(child: Container(
                  width: points[i].curve == AutomationCurve.linear ? 10 : 12, height: 4,
                  decoration: BoxDecoration(
                    color: lane.color.withValues(alpha: points[i].curve == AutomationCurve.linear ? 0.7 : 0.95),
                    borderRadius: BorderRadius.circular(2)))))))),
      // The selection box, over the segments' handles: its body moves the points.
      if (sel != null)
        Positioned.fromRect(rect: sel, child: RawGestureDetector(key: ValueKey('lane-box-${lane.key}'),
          behavior: HitTestBehavior.opaque, gestures: _eager(
            start: () => _xformStart(_Xform.move), update: _xformMove, end: _end),
          child: MouseRegion(cursor: SystemMouseCursors.move, child: DecoratedBox(decoration: BoxDecoration(
            color: Neon.yellow.withValues(alpha: 0.06),
            border: Border.all(color: Neon.yellow.withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(3)))))),
      // Each point: a 28 px target around its 8 px dot. Its drag is taken at the first touch ([EagerPan]), so the
      // timeline's scroll can't win it (#241); a press that doesn't move is a tap, or, held, the point's menu.
      if (select)
        for (var i = 0; i < points.length; i++)
          Positioned(left: _x(points[i].step) - 14, top: _y(points[i].value) - 14, width: 28, height: 28,
            child: GestureDetector(onSecondaryTapUp: (d) => _menu(d.globalPosition, point: i),
              child: Listener(onPointerDown: (e) => _clicks.down(e, target: i), onPointerUp: _clicks.up,
              child: RawGestureDetector(key: ValueKey('lane-point-${lane.key}-$i'), behavior: HitTestBehavior.opaque,
                gestures: {
                  EagerPan: GestureRecognizerFactoryWithHandlers<EagerPan>(EagerPan.new, (r) => r
                    ..dragStartBehavior = DragStartBehavior.down
                    ..onDown = ((d) => _pressDown(d.globalPosition))
                    ..onStart = ((d) => _pressSlop = d.kind == null || isMousePointer(d.kind!) ? 1 : 6)
                    ..onUpdate = ((d) => _pressMove(i, d.delta))
                    ..onEnd = ((_) => _pressUp(i))
                    ..onCancel = (() => _pressUp(i, cancelled: true))),
                },
                child: MouseRegion(cursor: SystemMouseCursors.move,
                    child: Tooltip(message: lane.label(points[i].value), child: const SizedBox.expand())))))),
      // The box's handles: the top and bottom edges scale the points' values, the corners tilt them.
      if (sel != null) ...[
        for (final (kind, dx, dy) in [
          (_Xform.scaleTop, 0.5, 0.0), (_Xform.scaleBottom, 0.5, 1.0),
          (_Xform.tiltLeft, 0.0, 0.0), (_Xform.tiltRight, 1.0, 0.0),
          (_Xform.tiltLeft, 0.0, 1.0), (_Xform.tiltRight, 1.0, 1.0),
        ])
          Positioned(left: sel.left + sel.width * dx - 9, top: sel.top + sel.height * dy - 9, width: 18, height: 18,
            child: RawGestureDetector(key: ValueKey('lane-box-${kind.name}-${dy == 0 ? 'top' : 'bottom'}-${lane.key}'),
              behavior: HitTestBehavior.opaque, gestures: _eager(
                start: () => _xformStart(kind), update: (d) => _xformMove(Offset(0, d.dy)), end: _end),
              child: MouseRegion(cursor: dx == 0.5 ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeUpDown,
                child: Center(child: Container(
                  width: dx == 0.5 ? 14 : 7, height: dx == 0.5 ? 5 : 7,
                  decoration: BoxDecoration(color: Neon.yellow,
                    shape: dx == 0.5 ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius: dx == 0.5 ? BorderRadius.circular(2) : null)))))),
      ],
    ])));
  }
}

IconData _curveIcon(AutomationCurve c) => switch (c) {
      AutomationCurve.linear => Icons.trending_up,
      AutomationCurve.slow => Icons.south_east,
      AutomationCurve.fast => Icons.north_east,
      AutomationCurve.sCurve => Icons.ssid_chart,
      AutomationCurve.step => Icons.stairs_outlined,
    };

/// How many straight pieces a bent segment is drawn with.
const int _curvePieces = 24;

/// A lane's curve and points, from a copy of them taken when it is made (so a repaint is skipped when nothing moved).
class _LanePainter extends CustomPainter {
  _LanePainter({required this.lane, required this.stepW, required this.pad, this.selected = const {}})
      : shape = Float64List.fromList([for (final p in lane.points) ...[p.step, lane.fraction(p.value)]]),
        line = _line(lane),
        color = lane.color;
  final ArrangeLane lane;
  final double stepW, pad;
  final Set<int> selected;
  final Color color;

  /// Each point's step and height fraction, in pairs.
  final Float64List shape;

  /// The curve as drawn: steps and heights in pairs, bent segments in straight pieces along their curves.
  final Float64List line;

  static Float64List _line(ArrangeLane lane) {
    final pts = lane.points;
    final out = <double>[];
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      out..add(p.step)..add(lane.fraction(p.value));
      if (i + 1 < pts.length && p.curve != AutomationCurve.linear) {
        final q = pts[i + 1];
        if (p.curve == AutomationCurve.step) {
          out..add(q.step)..add(lane.fraction(p.value));
        } else {
          for (var k = 1; k < _curvePieces; k++) {
            final at = p.step + (q.step - p.step) * k / _curvePieces;
            out..add(at)..add(lane.fraction(segmentValueAt(p, q, at)));
          }
        }
      }
    }
    return Float64List.fromList(out);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height - 2 * pad;
    double y(double f) => pad + (1 - f) * h;
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: 0.04));
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5),
        Paint()..color = Neon.line.withValues(alpha: 0.6));
    final n = shape.length ~/ 2;
    if (n > 0) {
      // Before the first point and after the last the lane holds their values, as the engine plays it.
      final path = Path()..moveTo(0, y(line[1]));
      for (var i = 0; i < line.length ~/ 2; i++) {
        path.lineTo(line[2 * i] * stepW, y(line[2 * i + 1]));
      }
      path.lineTo(size.width, y(shape[2 * n - 1]));
      final fill = Path.from(path)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
      canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.10));
      canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.6);
      final dot = Paint()..color = color;
      final ring = Paint()..color = Neon.text..style = PaintingStyle.stroke..strokeWidth = 1;
      for (var i = 0; i < n; i++) {
        final at = Offset(shape[2 * i] * stepW, y(shape[2 * i + 1]));
        // A selected point is larger, with a bright ring.
        final r = selected.contains(i) ? 5.5 : 4.0;
        canvas.drawCircle(at, r, dot);
        canvas.drawCircle(at, r, selected.contains(i) ? (Paint()..color = Neon.yellow..style = PaintingStyle.stroke..strokeWidth = 1.6) : ring);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LanePainter old) {
    if (old.stepW != stepW || old.pad != pad || old.color != color || old.shape.length != shape.length) return true;
    if (!setEquals(old.selected, selected)) return true;
    return !listEquals(old.line, line) || !listEquals(old.shape, shape);
  }
}

/// What a tool is drawing (the pencil's stroke, the line, the shape), the eraser's sweep or the box being drawn.
class _ToolPreview extends CustomPainter {
  _ToolPreview({required this.tool, required this.color, required this.box, required this.from, required this.to,
      required this.points});
  final LaneTool tool;
  final Color color;
  final Rect? box;
  final Offset? from, to;
  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    final b = box;
    if (b != null) {
      canvas.drawRect(b, Paint()..color = Neon.yellow.withValues(alpha: 0.08));
      canvas.drawRect(b, Paint()..color = Neon.yellow.withValues(alpha: 0.8)..style = PaintingStyle.stroke..strokeWidth = 1);
      return;
    }
    if (tool == LaneTool.eraser && from != null && to != null) {
      final r = Rect.fromLTRB(math.min(from!.dx, to!.dx), 0, math.max(from!.dx, to!.dx), size.height);
      canvas.drawRect(r, Paint()..color = Neon.pink.withValues(alpha: 0.14));
      return;
    }
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, Paint()..color = Neon.text.withValues(alpha: 0.85)..style = PaintingStyle.stroke..strokeWidth = 1.6);
    for (final p in points) {
      canvas.drawCircle(p, 2.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _ToolPreview old) => true;
}

/// What the Automate button is writing now, in red over the lane (it joins the lane when the take ends).
class _LiveLanePainter extends CustomPainter {
  _LiveLanePainter({required this.lane, required this.stepW, required this.pad, required this.live});
  final ArrangeLane lane;
  final double stepW, pad;
  final List<(double, double)>? live;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height - 2 * pad;
    double y(double v) => pad + (1 - lane.fraction(v)) * h;
    final s = live;
    if (s != null && s.isNotEmpty) {
      final path = Path()..moveTo(s.first.$1 * stepW, y(s.first.$2));
      for (final (at, v) in s.skip(1)) {
        path.lineTo(at * stepW, y(v));
      }
      canvas.drawPath(path, Paint()..color = Neon.pink..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  // Redrawn on every read while a take runs: the samples grow in place.
  @override
  bool shouldRepaint(covariant _LiveLanePainter old) => true;
}

/// A pan that takes its pointer at once, before the timeline's scroll can: the drawing tools and the segment handles.
class EagerPan extends PanGestureRecognizer {
  EagerPan({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
