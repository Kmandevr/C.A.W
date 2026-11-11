// A track's automation lanes in the arranger, REAPER-style: rows under the track behind its envelope button, edited
// in place (tap adds a point, drag moves one, double-tap deletes it, drag a segment's handle moves the segment).
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_edit.dart';
import '../../model/arrange_fx.dart';
import '../../model/automation_writer.dart';
import '../../model/clip_automation.dart';
import '../../model/clip_loop_edit.dart';
import '../../model/project.dart';
import '../feedback.dart';
import '../haptics.dart';
import '../theme.dart';
import '../volume_fader.dart' show VolumeTaper;
import '../pointer_input.dart';
import 'long_press_menu.dart';

/// One automation lane row's height: compact, and still a finger's height for its points (phone first).
const double kLaneRowHeight = 40;

/// The "+ lane" row under a track's open lanes.
const double kLaneAddRowHeight = 26;

/// Whether [layer] can have lanes: a track, or a folder with a group bus (its volume and pan act on the bus).
bool canHaveLanes(LayerDoc layer) => !layer.isFolder || layer.busEnabled;

/// The height a track's open lanes add under it (none while they are hidden).
double lanesHeight(AppState state, LayerDoc layer) => !layer.showLanes || !canHaveLanes(layer)
    ? 0 : arrangeLanes(state, layer).length * kLaneRowHeight + kLaneAddRowHeight;

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

  /// A value as a height through the lane, 0 at the bottom and 1 at the top (volume on the faders' taper).
  double fraction(double value) {
    if (isVolume) return VolumeTaper.position(value);
    return max > min ? ((value - min) / (max - min)).clamp(0.0, 1.0).toDouble() : 0.5;
  }

  double valueAt(double fraction) {
    final f = fraction.clamp(0.0, 1.0).toDouble();
    return isVolume ? VolumeTaper.gain(f) : min + f * (max - min);
  }

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

/// What the "+" can add to [layer]: (value, label) pairs; [addArrangeLane] takes the value.
List<(String, String)> addableLanes(AppState state, LayerDoc layer) {
  bool has(String key) => arrangeLanes(state, layer).any((l) => l.key == key);
  final out = <(String, String)>[
    for (final target in const ['volume', 'pan'])
      if (!layer.automation.any((a) => a.target == target)) ('track|$target', target == 'volume' ? 'Volume' : 'Pan'),
  ];
  if (layer.isFolder) return out;
  final instrument = layer.instrument;
  if (instrument != null) {
    final info = state.componentInfo(instrument.id);
    for (final p in info?.parameters ?? const []) {
      if (!p.automatable || has(automationKey('instrument', p.id, layerId: layer.id))) continue;
      out.add(('instrument|${p.id}', '${info!.label} · ${p.name.isEmpty ? p.id : p.name}'));
    }
  }
  for (var i = 0; i < layer.components.length; i++) {
    final info = state.componentInfo(layer.components[i].id);
    for (final p in info?.parameters ?? const []) {
      if (!p.automatable || has(automationKey('component', p.id, layerId: layer.id, component: i))) continue;
      out.add(('component|$i|${p.id}', '${info!.label} · ${p.name.isEmpty ? p.id : p.name}'));
    }
  }
  return out;
}

/// What a clip's "Automation" picker can add to [clip] on [layer]: (value, label) pairs as [addableLanes] gives,
/// less the clip's own lanes; [addClipArrangeLane] takes the value.
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

/// Adds the lane [value] names (from [addableLanes]): flat at the control's value now, across the song.
void addArrangeLane(AppState state, LayerDoc layer, String value) {
  final parts = value.split('|');
  if (parts.first == 'track' && parts.length == 2) return state.addAutomationLane(layer, parts[1]);
  final ComponentUseDoc? use;
  final int? component;
  final String param;
  if (parts.first == 'instrument' && parts.length == 2) {
    (use, component, param) = (layer.instrument, null, parts[1]);
  } else if (parts.first == 'component' && parts.length == 3) {
    final i = int.tryParse(parts[1]) ?? -1;
    if (i < 0 || i >= layer.components.length) return;
    (use, component, param) = (layer.components[i], i, parts[2]);
  } else {
    return;
  }
  if (use == null) return;
  final info = state.componentInfo(use.id)?.parameters.where((p) => p.id == param).firstOrNull;
  final v = use.params[param] ?? info?.defaultValue ?? 0;
  final end = state.project.arrangementEndSteps.clamp(1, state.project.maxArrangementSteps).toDouble();
  state.beginAutomationGesture(); // one undo step, in the automation undo too
  state.editProject((p) => p.automation.add(ProjectAutomationLaneDoc(targetType: parts.first, target: param,
      layerId: layer.id, component: component,
      points: [AutomationPointDoc(step: 0, value: v), AutomationPointDoc(step: end, value: v)])));
  state.endAutomationGesture();
}

/// The lanes' names under a track's header: a row per lane (name, ×) and the "+" that adds one.
class TrackLaneHeaders extends StatelessWidget {
  const TrackLaneHeaders({super.key, required this.state, required this.layer, required this.indent});
  final AppState state;
  final LayerDoc layer;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final lanes = arrangeLanes(state, layer);
    final addable = addableLanes(state, layer);
    return Column(children: [
      for (final lane in lanes)
        Container(key: ValueKey('lane-header-${lane.key}'), height: kLaneRowHeight,
          padding: EdgeInsets.only(left: 10 + indent),
          decoration: BoxDecoration(color: Color.lerp(Neon.panel, lane.color, 0.08),
            border: Border(left: BorderSide(color: lane.color.withValues(alpha: 0.6), width: 2),
              bottom: BorderSide(color: Neon.line.withValues(alpha: 0.6)))),
          child: Row(children: [
            // The lane's menu: a long press or double tap on its name, or a right-click (Move to clip).
            Expanded(child: GestureDetector(key: ValueKey('lane-name-${lane.key}'), behavior: HitTestBehavior.opaque,
              onLongPressStart: (d) => laneMenu(context, lane, d.globalPosition),
              onDoubleTapDown: (d) => laneMenu(context, lane, d.globalPosition),
              onSecondaryTapDown: (d) => laneMenu(context, lane, d.globalPosition),
              child: Align(alignment: Alignment.centerLeft, child: Text(lane.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: lane.color))))),
            // Arm (REAPER's envelope arm): the Automate button writes only armed lanes; new lanes start armed.
            SizedBox(width: 26, height: kLaneRowHeight, child: Pressable(child: IconButton(
              key: ValueKey('lane-arm-${lane.key}'),
              padding: EdgeInsets.zero, iconSize: 15, isSelected: lane.armed,
              tooltip: lane.armed ? 'Armed: Automate writes it (${PointerInput.tap} to disarm)' : 'Disarmed: only plays (${PointerInput.tap} to arm)',
              icon: Icon(lane.armed ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: lane.armed ? Neon.pink : Neon.dim),
              onPressed: () {
                Haptics.tap();
                lane.setArmed(!lane.armed);
              }))),
            // 26 px wide and a whole row high: a finger's target in a compact row, leaving the name room beside the arm.
            SizedBox(width: 26, height: kLaneRowHeight, child: Pressable(child: IconButton(
              key: ValueKey('lane-remove-${lane.key}'),
              padding: EdgeInsets.zero, tooltip: 'Remove lane', iconSize: 15,
              icon: const Icon(Icons.close, color: Neon.dim),
              onPressed: lane.delete))),
          ])),
      SizedBox(height: kLaneAddRowHeight, child: Padding(padding: EdgeInsets.only(left: 6 + indent),
        child: Align(alignment: Alignment.centerLeft, child: PopupMenuButton<String>(
          key: ValueKey('lane-add-${layer.id}'),
          tooltip: 'Add automation lane',
          enabled: addable.isNotEmpty,
          padding: EdgeInsets.zero,
          onSelected: (v) => addArrangeLane(state, layer, v),
          itemBuilder: (_) => [for (final (value, label) in addable) PopupMenuItem(value: value, child: Text(label))],
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add, size: 16, color: addable.isEmpty ? Neon.dim : Neon.blue),
            Text(lanes.isEmpty ? 'Add lane' : 'Lane',
              style: TextStyle(fontSize: 10, color: addable.isEmpty ? Neon.dim : Neon.blue)),
          ]))))),
    ]);
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

/// A track's lanes on the timeline: one [LaneRow] per lane and the empty "+" row, level with [TrackLaneHeaders].
class TrackLaneRows extends StatelessWidget {
  const TrackLaneRows({super.key, required this.state, required this.layer, required this.stepW,
      required this.width});
  final AppState state;
  final LayerDoc layer;
  final double stepW, width;

  @override
  Widget build(BuildContext context) => Column(children: [
    for (final lane in arrangeLanes(state, layer))
      LaneRow(key: ValueKey('lane-row-${lane.key}'), lane: lane, stepW: stepW, width: width),
    SizedBox(width: width, height: kLaneAddRowHeight),
  ]);
}

/// One lane, edited where it is drawn (REAPER, UG 18.14–18.15, pp. 367–368: a click adds a point, a drag moves a
/// point or a segment, Alt+click deletes a point). On a touch screen a tap adds a point, a drag on a point moves it,
/// a double-tap on a point deletes it, and the small handle in the middle of a segment drags the segment up or down.
/// Drags start only on a point or a handle, so the rest of the row still scrolls the timeline. With a mouse (owner,
/// 2026-11-11) a click selects a point (Shift-click adds one), a double-click adds a point or removes the one under
/// it, a right-click on a point or a segment's handle opens its menu, Shift drags finely, and Delete removes the
/// selected points.
class LaneRow extends StatefulWidget {
  const LaneRow({super.key, required this.lane, required this.stepW, required this.width});
  final ArrangeLane lane;
  final double stepW, width;

  @override
  State<LaneRow> createState() => _LaneRowState();
}

class _LaneRowState extends State<LaneRow> {
  static const _pad = 5.0; // keeps the top and bottom values off the row's edges
  static const _h = kLaneRowHeight;
  // A drag's running position, so a point follows the finger rather than snapping between frames.
  Offset _grab = Offset.zero;

  /// The points a mouse selected (indices), for Delete; and the mouse's clicks, told from double-clicks.
  Set<int> _selected = {};
  final _clicks = ClickCounter();
  final _keys = FocusNode(debugLabel: 'lane-row');

  /// Shift drags a fifth as far (fine control).
  static double get _rate => HardwareKeyboard.instance.isShiftPressed ? 0.2 : 1;

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LaneRow old) {
    super.didUpdateWidget(old);
    _selected = {for (final i in _selected) if (i < lane.points.length) i};
  }

  /// A mouse's click on point [i]: it becomes the selection, or joins it (or leaves it) with Shift; a double-click
  /// removes it.
  void _clickPoint(int i) {
    if (!_clicks.mouse) return;
    _keys.requestFocus();
    if (_clicks.doubleClick) {
      lane.remove(i);
      return setState(() => _selected = {});
    }
    setState(() {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _selected = _selected.contains(i) ? ({..._selected}..remove(i)) : {..._selected, i};
      } else {
        _selected = {i};
      }
    });
  }

  /// Removes the selected points, the last first, as one undo step.
  void _deleteSelected() {
    if (_selected.isEmpty) return;
    lane.state.beginAutomationGesture();
    for (final i in _selected.toList()..sort((a, b) => b.compareTo(a))) {
      if (i < lane.points.length) lane.remove(i);
    }
    lane.state.endAutomationGesture();
    setState(() => _selected = {});
  }

  /// A point's or a segment's right-click menu: delete the point, flatten the segment, or reset the whole curve to a
  /// flat line at its first value (its first and last points kept).
  Future<void> _menu(Offset at, {int? point, int? segment}) async {
    final v = await showLongPressMenu<String>(context, at: at, title: lane.name, style: lane.state.settings.longPressMenu,
        actions: [
          if (point != null) const MenuAction('delete', 'Delete point', Icons.delete_outline, section: 'Point'),
          if (point != null && _selected.length > 1)
            MenuAction('delete-selected', 'Delete ${_selected.length} selected points', Icons.delete_sweep_outlined,
                section: 'Point'),
          if (segment != null) const MenuAction('flatten', 'Flatten segment', Icons.horizontal_rule, section: 'Segment'),
          const MenuAction('reset', 'Reset curve', Icons.restart_alt, section: 'Curve'),
        ]);
    if (v == null || !mounted) return;
    final pts = lane.points;
    lane.state.beginAutomationGesture();
    switch (v) {
      case 'delete' when point != null && point < pts.length:
        lane.remove(point);
      case 'delete-selected':
        lane.state.endAutomationGesture();
        return _deleteSelected();
      case 'flatten' when segment != null && segment + 1 < pts.length:
        final mid = (pts[segment].value + pts[segment + 1].value) / 2;
        for (final i in [segment, segment + 1]) {
          lane.move(i, lane.points[i].step, mid);
        }
      case 'reset' when pts.isNotEmpty:
        final first = pts.first.value;
        for (var i = lane.points.length - 2; i >= 1; i--) {
          lane.remove(i);
        }
        for (var i = 0; i < lane.points.length; i++) {
          lane.move(i, lane.points[i].step, first);
        }
    }
    lane.state.endAutomationGesture();
    setState(() => _selected = {});
  }

  ArrangeLane get lane => widget.lane;
  double _y(double value) => _pad + (1 - lane.fraction(value)) * (_h - 2 * _pad);
  double _value(double y) => lane.valueAt(1 - (y - _pad) / (_h - 2 * _pad));
  double _x(double step) => step * widget.stepW;

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

  void _pointDrag(int index, DragStartDetails d) {
    final p = lane.points[index];
    _grab = Offset(_x(p.step), _y(p.value));
    lane.state.beginAutomationGesture();
    Haptics.grab();
  }

  void _pointMove(int index, DragUpdateDetails d) {
    if (index >= lane.points.length) return;
    _grab += d.delta * _rate;
    lane.move(index, math.max(0, _grab.dx / widget.stepW), _value(_grab.dy));
  }

  void _segmentMove(int index, DragUpdateDetails d) {
    if (index + 1 >= lane.points.length) return;
    final df = -d.delta.dy * _rate / (_h - 2 * _pad);
    for (final i in [index, index + 1]) {
      final p = lane.points[i];
      lane.move(i, p.step, lane.valueAt(lane.fraction(p.value) + df));
    }
  }

  void _end() {
    lane.state.endAutomationGesture();
    Haptics.drop();
  }

  @override
  Widget build(BuildContext context) {
    final points = lane.points;
    final writer = AutomationWriter.current;
    final curve = CustomPaint(size: Size(widget.width, _h),
      painter: _LanePainter(lane: lane, stepW: widget.stepW, pad: _pad, writer: writer, selected: _selected));
    // While the Automate button writes this lane, it repaints with the playhead so the new values show live.
    final live = writer == null ? curve : ListenableBuilder(listenable: writer, builder: (context, child) =>
        writer.writing ? ValueListenableBuilder<int>(valueListenable: lane.state.tick,
            builder: (context, _, _) => CustomPaint(size: Size(widget.width, _h),
              painter: _LanePainter(lane: lane, stepW: widget.stepW, pad: _pad, writer: writer)))
            : child!, child: curve);
    Offset? doubleAt;
    return Focus(
      focusNode: _keys,
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent || _selected.isEmpty) return KeyEventResult.ignored;
        if (e.logicalKey != LogicalKeyboardKey.delete && e.logicalKey != LogicalKeyboardKey.backspace) {
          return KeyEventResult.ignored;
        }
        _deleteSelected();
        return KeyEventResult.handled;
      },
      child: SizedBox(width: widget.width, height: _h, child: Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: Listener(onPointerDown: _clicks.down, child: TouchDoubleTap(
        onDoubleTapDown: (d) => doubleAt = d.localPosition,
        onDoubleTap: () {
          final i = doubleAt == null ? null : _pointNear(doubleAt!);
          if (i != null) lane.remove(i);
        },
        child: GestureDetector(
        key: ValueKey('lane-surface-${lane.key}'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          // A mouse: a click clears the point selection, a double-click adds a point.
          if (_clicks.mouse) {
            _keys.requestFocus();
            if (_selected.isNotEmpty) setState(() => _selected = {});
            if (!_clicks.doubleClick) return;
          }
          if (_pointNear(d.localPosition) != null) return;
          lane.add(math.max(0, d.localPosition.dx / widget.stepW), _value(d.localPosition.dy));
        },
        child: RepaintBoundary(child: live))))),
      // Each segment's middle: a handle that drags it up or down (REAPER's segment drag).
      for (var i = 0; i + 1 < points.length; i++)
        if (_x(points[i + 1].step) - _x(points[i].step) > 40)
          Positioned(
            left: (_x(points[i].step) + _x(points[i + 1].step)) / 2 - 12,
            top: (_y(points[i].value) + _y(points[i + 1].value)) / 2 - 12,
            width: 24, height: 24,
            child: GestureDetector(key: ValueKey('lane-segment-${lane.key}-$i'), behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onSecondaryTapUp: (d) => _menu(d.globalPosition, segment: i),
              onVerticalDragStart: (_) {
                lane.state.beginAutomationGesture();
                Haptics.grab();
              },
              onVerticalDragUpdate: (d) => _segmentMove(i, d),
              onVerticalDragEnd: (_) => _end(),
              onVerticalDragCancel: _end,
              child: Center(child: Container(width: 10, height: 4, decoration: BoxDecoration(
                color: lane.color.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(2)))))),
      // Each point: a 28 px target around its 8 px dot.
      for (var i = 0; i < points.length; i++)
        Positioned(left: _x(points[i].step) - 14, top: _y(points[i].value) - 14, width: 28, height: 28,
          child: Listener(onPointerDown: _clicks.down, child: TouchDoubleTap(
            onDoubleTap: () => lane.remove(i),
            child: GestureDetector(key: ValueKey('lane-point-${lane.key}-$i'), behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onTap: () => _clickPoint(i),
            onSecondaryTapUp: (d) => _menu(d.globalPosition, point: i),
            onPanStart: (d) => _pointDrag(i, d),
            onPanUpdate: (d) => _pointMove(i, d),
            onPanEnd: (_) => _end(),
            onPanCancel: _end,
            child: MouseRegion(cursor: SystemMouseCursors.move,
                child: Tooltip(message: lane.label(points[i].value), child: const SizedBox.expand())))))),
    ])));
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter({required this.lane, required this.stepW, required this.pad, this.writer, this.selected = const {}})
      : live = writer?.liveSamples(lane.key);
  final ArrangeLane lane;
  final double stepW, pad;
  final Set<int> selected;
  final AutomationWriter? writer;
  final List<(double, double)>? live;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height - 2 * pad;
    double y(double v) => pad + (1 - lane.fraction(v)) * h;
    canvas.drawRect(Offset.zero & size, Paint()..color = lane.color.withValues(alpha: 0.04));
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5),
        Paint()..color = Neon.line.withValues(alpha: 0.6));
    final points = lane.points;
    if (points.isNotEmpty) {
      // Before the first point and after the last the lane holds their values, as the engine plays it.
      final path = Path()..moveTo(0, y(points.first.value));
      for (final p in points) {
        path.lineTo(p.step * stepW, y(p.value));
      }
      path.lineTo(size.width, y(points.last.value));
      final fill = Path.from(path)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
      canvas.drawPath(fill, Paint()..color = lane.color.withValues(alpha: 0.10));
      canvas.drawPath(path, Paint()..color = lane.color..style = PaintingStyle.stroke..strokeWidth = 1.6);
      final dot = Paint()..color = lane.color;
      final ring = Paint()..color = Neon.text..style = PaintingStyle.stroke..strokeWidth = 1;
      for (var i = 0; i < points.length; i++) {
        final p = points[i];
        final at = Offset(p.step * stepW, y(p.value));
        // A selected point is larger, with a bright ring.
        final r = selected.contains(i) ? 5.5 : 4.0;
        canvas.drawCircle(at, r, dot);
        canvas.drawCircle(at, r, selected.contains(i) ? (Paint()..color = Neon.yellow..style = PaintingStyle.stroke..strokeWidth = 1.6) : ring);
      }
    }
    // What the Automate button is writing now, in red over the lane (it joins the lane when the take ends).
    final s = live;
    if (s != null && s.isNotEmpty) {
      final path = Path()..moveTo(s.first.$1 * stepW, y(s.first.$2));
      for (final (at, v) in s.skip(1)) {
        path.lineTo(at * stepW, y(v));
      }
      canvas.drawPath(path, Paint()..color = Neon.pink..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _LanePainter old) => true;
}
