// The focus view's Automation tab: the focused track's lanes, the same ones drawn under it in Arrange (#241): volume,
// pan and its devices' parameters, edited with the same lane row and tools, added with the same Automate picker.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../model/app_state.dart';
import '../../model/automation_curve.dart' show laneValueAt;
import '../../model/project.dart';
import '../theme.dart';
import '../widgets.dart';
import 'lane_tools.dart';
import 'track_lanes.dart';

/// One track's lanes (the focus view's Automation tab): every lane [arrangeLanes] gives the track under it in Arrange,
/// each drawn and edited with the arranger's [LaneRow] over the whole song, with its points' sliders under it; the
/// tool row's Automate adds one. An edit here or under the track is the same edit.
class TrackAutomationPanel extends StatelessWidget {
  const TrackAutomationPanel({super.key, required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) {
    if (!canHaveLanes(layer)) {
      return const Center(child: Text('Turn on the folder\'s group bus to automate it.', style: TextStyle(color: Neon.dim)));
    }
    return ListenableBuilder(listenable: state, builder: (context, _) {
      final lanes = arrangeLanes(state, layer);
      return ListView(key: ValueKey('automation-tab-${layer.id}'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 48),
          children: [
        NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(layer.name, style: const TextStyle(fontWeight: FontWeight.w800)),
          LaneToolRow(state: state, layer: layer, height: kLaneToolRowHeight),
          if (lanes.isEmpty) ...[
            const Padding(padding: EdgeInsets.only(top: 6),
                child: Text('No lanes yet: Automate adds volume, pan or a device\'s parameter.',
                    style: TextStyle(color: Neon.dim))),
            const _WriteHint(),
          ],
          for (final lane in lanes) _AutomationLane(key: ValueKey('automation-tab-lane-${lane.key}'), state: state,
              lane: lane),
        ])),
      ]);
    });
  }
}

/// How to write automation by playing (the transport's Automate button), which the lane lists don't show.
class _WriteHint extends StatelessWidget {
  const _WriteHint();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.fiber_manual_record, size: 12, color: Neon.pink),
          SizedBox(width: 6),
          Expanded(child: Text('Or record it: turn on Automate in the transport, play, and move any fader or knob.',
              key: ValueKey('automate-hint'), style: TextStyle(color: Neon.dim, fontSize: 12))),
        ]),
      );
}

/// One lane: its name, the lane row over the whole song, and a slider pair per point.
class _AutomationLane extends StatelessWidget {
  const _AutomationLane({super.key, required this.state, required this.lane});
  final AppState state;
  final ArrangeLane lane;

  @override
  Widget build(BuildContext context) {
    final maxStep = math.max(1, state.project.timelineSteps).toDouble();
    return Padding(padding: const EdgeInsets.only(top: 12), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(lane.name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Neon.code(size: 12, color: lane.color))),
          IconButton(tooltip: 'Remove lane', onPressed: lane.delete, icon: const Icon(Icons.close, size: 18)),
          IconButton(tooltip: 'Add midpoint point', onPressed: () {
            final mid = (maxStep / 2).roundToDouble();
            lane.add(mid, laneValueAt(lane.points, mid, lane.valueAt(0.5)));
          }, icon: const Icon(Icons.add_circle_outline, size: 18)),
        ]),
        // The same row as under the track in Arrange, fitted to the panel: the whole song at once.
        LayoutBuilder(builder: (context, box) => ClipRect(child: LaneRow(key: ValueKey('automation-tab-row-${lane.key}'),
            lane: lane, stepW: box.maxWidth / maxStep, width: box.maxWidth, tools: true, reveal: false))),
        for (var i = 0; i < lane.points.length; i++)
          _PointEditor(state: state, lane: lane, index: i, maxStep: maxStep),
      ],
    ));
  }
}

class _PointEditor extends StatelessWidget {
  const _PointEditor({required this.state, required this.lane, required this.index, required this.maxStep});
  final AppState state;
  final ArrangeLane lane;
  final int index;
  final double maxStep;

  @override
  Widget build(BuildContext context) {
    final point = lane.points[index];
    final color = lane.color;
    final name = lane.isVolume ? 'LEVEL' : lane.name == 'Pan' ? 'PAN' : 'VALUE';
    // A slider's drag is one automation undo step.
    final stepSlider = Slider(
      value: point.step.clamp(0.0, maxStep).toDouble(),
      min: 0,
      max: maxStep,
      activeColor: color,
      semanticFormatterCallback: (value) => 'Step ${value.round()}',
      onChangeStart: (_) => state.beginAutomationGesture(),
      onChangeEnd: (_) => state.endAutomationGesture(),
      onChanged: (value) => lane.move(index, value, point.value),
    );
    // A value slider runs through the lane's height (volume on the faders' taper), as the lane row draws it.
    final valueSlider = Slider(
      value: lane.fraction(point.value),
      activeColor: color,
      semanticFormatterCallback: (f) => '${lane.name} ${lane.label(lane.valueAt(f))}',
      onChangeStart: (_) => state.beginAutomationGesture(),
      onChangeEnd: (_) => state.endAutomationGesture(),
      onChanged: (f) => lane.move(index, point.step, lane.valueAt(f)),
    );
    final shown = lane.label(point.value);
    final removeButton = IconButton(
      tooltip: 'Remove automation point',
      onPressed: () => lane.remove(index),
      icon: const Icon(Icons.close, size: 16),
    );

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 560) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('POINT ${index + 1}', style: Neon.code(size: 10, color: color))),
            Text('Step ${point.step.toStringAsFixed(0)} · $shown',
              style: Neon.code(size: 10, color: Neon.dim)),
            removeButton,
          ]),
          Row(children: [
            const SizedBox(width: 42, child: Text('TIME', style: TextStyle(color: Neon.dim, fontSize: 9))),
            Expanded(child: stepSlider),
          ]),
          Row(children: [
            SizedBox(width: 42, child: Text(name, style: const TextStyle(color: Neon.dim, fontSize: 9))),
            Expanded(child: valueSlider),
          ]),
        ]);
      }
      return Row(children: [
        SizedBox(width: 28, child: Text('P${index + 1}', style: Neon.code(size: 10, color: color))),
        Expanded(child: stepSlider),
        SizedBox(width: 38, child: Text(point.step.toStringAsFixed(0), textAlign: TextAlign.end,
          style: Neon.code(size: 10, color: Neon.dim))),
        Expanded(child: valueSlider),
        SizedBox(width: 56, child: Text(shown, textAlign: TextAlign.end,
          style: Neon.code(size: 10, color: color))),
        removeButton,
      ]);
    });
  }
}
