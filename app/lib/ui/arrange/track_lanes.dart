// A track's automation lanes in the arranger, REAPER-style: rows under the track behind its envelope button, edited
// in place (tap adds a point, drag moves one, double-tap deletes it, drag a segment's handle moves the segment).
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/automation_writer.dart';
import '../../model/project.dart';
import '../feedback.dart';
import '../haptics.dart';
import '../theme.dart';
import '../volume_fader.dart' show VolumeTaper;

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
      {this.min = 0, this.max = 1});

  final AppState state;
  final LayerDoc layer;
  final String key, name;
  final Color color;
  final AutomationLaneDoc? _track;
  final ProjectAutomationLaneDoc? _project;
  final double min, max;

  bool get isVolume => _track?.target == 'volume';

  List<AutomationPointDoc> get points => _track?.points ?? _project!.points;

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
      : _track != null ? '${(value * 100).round()}%' : value.toStringAsFixed(max - min > 10 ? 0 : 2);

  void add(double step, double value) => _track != null
      ? state.addAutomationPoint(layer, _track, step, value)
      : state.addProjectAutomationPoint(_project!, step, value.clamp(min, max).toDouble());

  void move(int index, double step, double value) => _track != null
      ? state.updateAutomationPoint(layer, _track, index, step, value)
      : state.updateProjectAutomationPoint(_project!, index, step, value.clamp(min, max).toDouble());

  void remove(int index) => _track != null
      ? state.removeAutomationPoint(layer, _track, index)
      : state.removeProjectAutomationPoint(_project!, index);

  void delete() => _track != null ? state.removeAutomationLane(layer, _track) : state.removeProjectAutomationLane(_project!);
}

/// [layer]'s lanes, in order: volume and pan first, then its instrument's and effects' parameters.
List<ArrangeLane> arrangeLanes(AppState state, LayerDoc layer) {
  ArrangeLane? native(ProjectAutomationLaneDoc lane) {
    final id = switch (lane.targetType) {
      'instrument' => layer.instrument?.id,
      'component' when (lane.component ?? -1) >= 0 && lane.component! < layer.components.length =>
        layer.components[lane.component!].id,
      _ => null,
    };
    if (id == null) return null;
    final info = state.componentInfo(id);
    final param = info?.parameters.where((p) => p.id == lane.target).firstOrNull;
    final device = info?.label ?? state.componentLabel(id);
    return ArrangeLane._(state, layer, lane.key, '$device · ${param?.name.isNotEmpty == true ? param!.name : lane.target}',
        Neon.violet, null, lane, min: param?.min ?? 0, max: param?.max ?? 1);
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
            Expanded(child: Text(lane.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: lane.color))),
            // 32 px wide, a whole row high: a finger's target in a compact row.
            SizedBox(width: 32, height: kLaneRowHeight, child: Pressable(child: IconButton(
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
/// Drags start only on a point or a handle, so the rest of the row still scrolls the timeline.
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
    _grab += d.delta;
    lane.move(index, math.max(0, _grab.dx / widget.stepW), _value(_grab.dy));
  }

  void _segmentMove(int index, DragUpdateDetails d) {
    if (index + 1 >= lane.points.length) return;
    final df = -d.delta.dy / (_h - 2 * _pad);
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
      painter: _LanePainter(lane: lane, stepW: widget.stepW, pad: _pad, writer: writer));
    // While the Automate button writes this lane, it repaints with the playhead so the new values show live.
    final live = writer == null ? curve : ListenableBuilder(listenable: writer, builder: (context, child) =>
        writer.writing ? ValueListenableBuilder<int>(valueListenable: lane.state.tick,
            builder: (context, _, _) => CustomPaint(size: Size(widget.width, _h),
              painter: _LanePainter(lane: lane, stepW: widget.stepW, pad: _pad, writer: writer)))
            : child!, child: curve);
    Offset? doubleAt;
    return SizedBox(width: widget.width, height: _h, child: Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: GestureDetector(
        key: ValueKey('lane-surface-${lane.key}'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          if (_pointNear(d.localPosition) != null) return;
          lane.add(math.max(0, d.localPosition.dx / widget.stepW), _value(d.localPosition.dy));
        },
        onDoubleTapDown: (d) => doubleAt = d.localPosition,
        onDoubleTap: () {
          final i = doubleAt == null ? null : _pointNear(doubleAt!);
          if (i != null) lane.remove(i);
        },
        child: RepaintBoundary(child: live))),
      // Each segment's middle: a handle that drags it up or down (REAPER's segment drag).
      for (var i = 0; i + 1 < points.length; i++)
        if (_x(points[i + 1].step) - _x(points[i].step) > 40)
          Positioned(
            left: (_x(points[i].step) + _x(points[i + 1].step)) / 2 - 12,
            top: (_y(points[i].value) + _y(points[i + 1].value)) / 2 - 12,
            width: 24, height: 24,
            child: GestureDetector(key: ValueKey('lane-segment-${lane.key}-$i'), behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
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
          child: GestureDetector(key: ValueKey('lane-point-${lane.key}-$i'), behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onDoubleTap: () => lane.remove(i),
            onPanStart: (d) => _pointDrag(i, d),
            onPanUpdate: (d) => _pointMove(i, d),
            onPanEnd: (_) => _end(),
            onPanCancel: _end,
            child: Tooltip(message: lane.label(points[i].value), child: const SizedBox.expand()))),
    ]));
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter({required this.lane, required this.stepW, required this.pad, this.writer})
      : live = writer?.liveSamples(lane.key);
  final ArrangeLane lane;
  final double stepW, pad;
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
      for (final p in points) {
        final at = Offset(p.step * stepW, y(p.value));
        canvas.drawCircle(at, 4, dot);
        canvas.drawCircle(at, 4, ring);
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
