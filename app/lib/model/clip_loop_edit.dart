// Edits of a MIDI clip's own loop point and its clip automation lanes (owner, 2026-11-11), each one undo step.
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_fx.dart';
import 'clip_automation.dart';
import 'project.dart';

extension ClipLoopEdit on AppState {
  /// Sets [clip]'s loop point to [steps] (null or 0: back to its pattern's length). One undo step.
  void setClipLoop(LayerDoc layer, ClipDoc clip, int? steps) {
    final next = steps == null || steps <= 0 ? null : steps.clamp(1, project.maxArrangementSteps).toInt();
    if (next == clip.loopSteps) return;
    endUndoStep();
    editLayer(layer, (_) {
      clip.loopSteps = next;
      // The lanes keep to the loop: points past the new end go (a longer loop keeps them all).
      final loop = project.clipLoopSteps(clip).toDouble();
      for (final lane in clip.automation) {
        lane.points.removeWhere((p) => p.step > loop);
      }
    });
    endUndoStep();
  }

  /// The value [layer]'s target holds at song step [at]: its track or project lane there, else the control's value
  /// (a parameter's default when the project stores none).
  double laneValueAt(LayerDoc layer, String targetType, String target, int? component, double at) {
    final key = automationKey(targetType, target, layerId: layer.id, component: component);
    final base = targetType == 'track'
        ? layer.automation.where((a) => a.target == target).firstOrNull?.points
        : project.automation.where((a) => a.key == key).firstOrNull?.points;
    if (base != null && base.isNotEmpty) {
      final merged = mergeClipLanes(base, 0, const []);
      return pointsValueAt(merged, at);
    }
    return project.controlValue(layer, targetType, target, component) ?? _paramDefault(layer, targetType, target, component);
  }

  double _paramDefault(LayerDoc layer, String targetType, String target, int? component) {
    final use = targetType == 'instrument'
        ? layer.instrument
        : component != null && component >= 0 && component < layer.components.length ? layer.components[component] : null;
    if (use == null) return 0;
    return componentInfo(use.id)?.parameters.where((p) => p.id == target).firstOrNull?.defaultValue ?? 0;
  }

  /// Adds a clip lane on [target] to [clip], flat at the value the target has where the clip starts, across its loop.
  /// The control's own value is stored in the project if it wasn't, so outside the clip the engine returns to it.
  ClipAutomationLaneDoc? addClipLane(LayerDoc layer, ClipDoc clip, String targetType, String target, {int? component}) {
    final existing = clip.automation
        .where((a) => a.targetType == targetType && a.target == target && a.component == component).firstOrNull;
    if (existing != null) return existing;
    final v = laneValueAt(layer, targetType, target, component, clip.startSteps.toDouble());
    final loop = project.clipLoopSteps(clip).toDouble();
    final lane = ClipAutomationLaneDoc(targetType: targetType, target: target, component: component,
        points: [AutomationPointDoc(step: 0, value: v), AutomationPointDoc(step: loop, value: v)]);
    endUndoStep();
    beginAutomationGesture();
    editLayer(layer, (l) {
      if (targetType != 'track' && project.controlValue(l, targetType, target, component) == null) {
        final use = targetType == 'instrument' ? l.instrument : l.components[component!];
        use?.params[target] = _paramDefault(l, targetType, target, component);
      }
      clip.automation.add(lane);
    });
    endAutomationGesture();
    endUndoStep();
    return lane;
  }

  void removeClipLane(LayerDoc layer, ClipDoc clip, ClipAutomationLaneDoc lane) {
    endUndoStep();
    beginAutomationGesture();
    editLayer(layer, (_) => clip.automation.remove(lane));
    endAutomationGesture();
    endUndoStep();
  }

  double _clampValue(ClipAutomationLaneDoc lane, double value) => lane.isTrack
      ? value.clamp(lane.target == 'volume' ? 0.0 : -1.0, lane.target == 'volume' ? kMaxMixGain : 1.0).toDouble()
      : value.clamp(-1000000.0, 1000000.0).toDouble();

  void addClipLanePoint(LayerDoc layer, ClipDoc clip, ClipAutomationLaneDoc lane, double step, double value) {
    final at = step.clamp(0.0, project.clipLoopSteps(clip).toDouble()).toDouble();
    if (lane.points.any((p) => (p.step - at).abs() < 0.01)) return;
    beginAutomationGesture();
    editLayer(layer, (_) {
      lane.points.add(AutomationPointDoc(step: at, value: _clampValue(lane, value)));
      lane.points.sort((a, b) => a.step.compareTo(b.step));
    });
    endAutomationGesture();
  }

  /// Moves point [index], kept between its neighbours and inside the loop (call inside an automation gesture).
  void updateClipLanePoint(LayerDoc layer, ClipDoc clip, ClipAutomationLaneDoc lane, int index, double step, double value) {
    if (index < 0 || index >= lane.points.length) return;
    editLayer(layer, (_) {
      final p = lane.points[index];
      final lower = index > 0 ? lane.points[index - 1].step + 0.01 : 0.0;
      final upper = index + 1 < lane.points.length ? lane.points[index + 1].step - 0.01 : project.clipLoopSteps(clip).toDouble();
      p.step = step.clamp(lower, math.max(lower, upper)).toDouble();
      p.value = _clampValue(lane, value);
    });
  }

  void removeClipLanePoint(LayerDoc layer, ClipDoc clip, ClipAutomationLaneDoc lane, int index) {
    if (index < 0 || index >= lane.points.length) return;
    beginAutomationGesture();
    editLayer(layer, (_) => lane.points.removeAt(index));
    endAutomationGesture();
  }

  /// "Move to track": [lane]'s values over every pass of [clip] go into the track's (or project's) lane on the
  /// same target, made if there is none, and the clip lane goes. One undo step.
  void moveClipLaneToTrack(LayerDoc layer, ClipDoc clip, ClipAutomationLaneDoc lane) {
    final key = lane.keyOn(layer.id);
    final trackLane = lane.isTrack ? layer.automation.where((a) => a.target == lane.target).firstOrNull : null;
    final projectLane = lane.isTrack ? null : project.automation.where((a) => a.key == key).firstOrNull;
    final base = trackLane?.points ?? projectLane?.points ?? const <AutomationPointDoc>[];
    final value = laneValueAt(layer, lane.targetType, lane.target, lane.component, clip.startSteps.toDouble());
    final span = clipLaneSpan(clip, lane.points, project.clipLoopSteps(clip));
    final merged = mergeClipLanes(base, value, [span]);
    endUndoStep();
    beginAutomationGesture();
    editLayer(layer, (l) {
      clip.automation.remove(lane);
      if (lane.isTrack) {
        if (trackLane != null) {
          trackLane.points = merged;
        } else {
          l.automation.add(AutomationLaneDoc(target: lane.target, points: merged));
        }
      } else if (projectLane != null) {
        projectLane.points = merged;
      } else {
        project.automation.add(ProjectAutomationLaneDoc(targetType: lane.targetType, target: lane.target, layerId: l.id,
            component: lane.component, points: merged));
      }
    });
    endAutomationGesture();
    endUndoStep();
  }

  /// "Move to clip": the track's (or project's) lane [key] on [layer] becomes [clip]'s lane, taking the values over
  /// the clip's first loop on the timeline (from its start, one loop long, in the clip's own time), and the track lane
  /// goes. False when there is no such lane. One undo step.
  bool moveTrackLaneToClip(LayerDoc layer, ClipDoc clip, String key) {
    final trackLane = layer.automation.where((a) => automationKey('track', a.target, layerId: layer.id) == key).firstOrNull;
    final projectLane = trackLane != null ? null : project.automation.where((a) => a.key == key && a.layerId == layer.id).firstOrNull;
    if (trackLane == null && projectLane == null) return false;
    final targetType = trackLane != null ? 'track' : projectLane!.targetType;
    if (targetType != 'track' && targetType != 'instrument' && targetType != 'component') return false;
    final target = trackLane?.target ?? projectLane!.target;
    final component = projectLane?.component;
    final base = mergeClipLanes(trackLane?.points ?? projectLane!.points, 0, const []);
    if (base.isEmpty) return false;
    final loop = project.clipLoopSteps(clip).toDouble();
    final t0 = clip.startSteps.toDouble(), u0 = clip.loop ? clip.sourceOffsetSteps % loop : 0.0;
    final span = math.min(clip.lengthSteps.toDouble(), clip.loop ? loop : loop - u0);
    // The loop's two pieces in clip time: from the offset to the loop's end, then (after a wrap) from its start.
    final pieces = <(double, double, double)>[]; // (timeline from, timeline to, clip time at the start)
    final first = math.min(span, loop - u0);
    pieces.add((t0, t0 + first, u0));
    if (span > first) pieces.add((t0 + first, t0 + span, 0));
    final local = <AutomationPointDoc>[];
    void add(double u, double v) {
      if (local.any((p) => (p.step - u).abs() < 0.01)) return;
      local.add(AutomationPointDoc(step: u, value: v));
    }

    for (final (a, b, u) in pieces) {
      add(u, pointsValueAt(base, a));
      for (final p in base) {
        if (p.step > a && p.step < b) add(u + p.step - a, p.value);
      }
      add(u + b - a, pointsValueAt(base, b, left: true));
    }
    local.sort((a, b) => a.step.compareTo(b.step));
    endUndoStep();
    beginAutomationGesture();
    editLayer(layer, (l) {
      clip.automation.removeWhere((a) => a.targetType == targetType && a.target == target && a.component == component);
      clip.automation.add(ClipAutomationLaneDoc(targetType: targetType, target: target, component: component, points: local));
      if (trackLane != null) {
        l.automation.remove(trackLane);
      } else {
        project.automation.remove(projectLane);
      }
    });
    endAutomationGesture();
    endUndoStep();
    return true;
  }
}
