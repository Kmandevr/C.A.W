// Writes automation from the controls (owner, 2026-11-10: an Automate button in the transport, Touch by default):
// while it is on and the song plays, knob and fader moves become thinned points in their lanes, in Touch, Latch or
// Write mode; Read only plays. A disarmed lane (REAPER's envelope arm) only plays. One take of writing (play to stop)
// is one undo step.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../engine/component_info.dart';
import 'app_state.dart';
import 'arrange_fx.dart';
import 'project.dart';

/// REAPER's write modes (UG 18.8): Touch writes while a control is held and goes back to the lane when it is let
/// go; Latch writes from the first touch until stop; Write overwrites every lane (and any control moved) while
/// playing, then falls back to Read; Read only plays the lanes.
enum AutomationMode { touch, latch, write, read }

/// One automatable control: a track's `volume` or `pan` ([kind] `track`), a .caw module parameter (`param`), a
/// project `global`, a native effect's parameter (`component`, [component] its index in the track's chain) or a
/// native instrument's (`instrument`). [key] names its lane ([automationKey]).
class AutomationTarget {
  const AutomationTarget(this.kind, this.name, {this.layerId, this.moduleId, this.component});
  final String kind, name;
  final String? layerId, moduleId;
  final int? component;

  String get key => automationKey(kind, name, layerId: layerId, moduleId: moduleId, component: component);

  @override
  bool operator ==(Object other) => other is AutomationTarget && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

class _Segment {
  _Segment(this.target, this.value, {required this.hadLane, required this.original});
  final AutomationTarget target;
  final List<(double, double)> samples = [];
  double value;
  bool held = true;
  final bool hadLane;
  final double original; // the control's value before the take moved it (a new lane's level outside the take)
}

class AutomationWriter extends ChangeNotifier {
  /// The app's one instance (main.dart makes it beside LiveMidi), for the transport's Automate button.
  static AutomationWriter? current;

  /// [pointers] off: tests and hosts call [pointerDown] and [pointerUp] themselves instead of the global route.
  AutomationWriter(this.state, {this.pointers = true}) {
    mode = AutomationMode.values.where((m) => m.name == state.settings.automationMode).firstOrNull ?? AutomationMode.touch;
    state.onParamMove = _moved;
    state.addListener(_onState);
    state.tick.addListener(_onTick);
  }

  final AppState state;
  final bool pointers;

  /// The Automate button: on, moves made while playing are written (in [mode]).
  bool get armed => _armed;
  bool _armed = false;

  AutomationMode mode = AutomationMode.touch;

  /// True while some control is being written into its lane.
  bool get writing => _segments.isNotEmpty;

  final Map<String, _Segment> _segments = {};

  /// The (step, value) samples being written into the lane [key] names ([automationKey]) in this take, before they
  /// join the lane; null when it isn't being written. The arranger's lanes draw them live.
  List<(double, double)>? liveSamples(String key) => _segments[key]?.samples;
  bool _takeOpen = false, _writeStarted = false;
  int _down = 0;
  Timer? _idle;
  double _lastStep = 0;

  /// How long a move made with no finger or button down (a key, a typed value, a wheel) counts as held.
  static const idleRelease = Duration(milliseconds: 400);

  /// A Touch write returns to the lane over this many steps after the control is let go.
  static const returnSteps = 0.25;

  void setArmed(bool on) {
    if (on == _armed) return;
    _armed = on;
    if (pointers) {
      try {
        on ? GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer)
            : GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      } catch (_) {} // no binding (a plain unit test): the host reports pointers itself
    }
    if (!on) {
      _down = 0;
      if (_takeOpen) _finishTake();
    }
    notifyListeners();
  }

  void setMode(AutomationMode m) {
    if (m == mode) return;
    if (_takeOpen) _finishTake(); // a mode change ends the take as it stands
    mode = m;
    state.settings.automationMode = m.name;
    state.settings.save();
    notifyListeners();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      pointerDown();
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      pointerUp();
    }
  }

  /// A finger or button went down anywhere: moves from now on are held until every one is up again.
  void pointerDown() => _down++;

  void pointerUp() {
    _down = math.max(0, _down - 1);
    if (_down == 0) _releaseHeld();
  }

  bool get _playing => state.transportOn;
  double get _now => state.playheadStep;

  void _moved(AutomationTarget target, double value) {
    if (!_armed || mode == AutomationMode.read || !_playing || !value.isFinite || !_canAutomate(target) ||
        !laneArmed(target)) {
      return;
    }
    _openTake();
    final at = _now;
    final seg = _segments[target.key] ??= _start(target, at);
    seg.value = value;
    seg.held = true;
    _add(seg, at, value);
    if (_down == 0) {
      _idle?.cancel();
      _idle = Timer(idleRelease, _releaseHeld);
    }
    notifyListeners();
  }

  _Segment _start(AutomationTarget target, double at) {
    final had = _laneOf(target) != null;
    final seg = _Segment(target, valueOf(target), hadLane: had, original: valueOf(target));
    // The engine leaves the lane out while it is written, so the moving control is what plays.
    if (had && state.suspendedLanes.add(target.key)) state.resyncEngine();
    return seg;
  }

  void _add(_Segment seg, double at, double value) {
    final s = seg.samples;
    if (s.isNotEmpty && (at - s.last.$1).abs() < 1e-6) {
      s[s.length - 1] = (s.last.$1, value); // moves between two playhead reads: the latest wins
    } else {
      s.add((at, value));
    }
  }

  void _openTake() {
    if (_takeOpen) return;
    _takeOpen = true;
    state.beginAutomationGesture(); // one step in the automation screen's own undo too
    state.holdHistory(true);
  }

  /// Every control let go: Touch writes what it recorded and returns to the lane; Latch and Write go on until stop.
  void _releaseHeld() {
    _idle?.cancel();
    var released = false;
    for (final seg in _segments.values.toList()) {
      if (!seg.held) continue;
      seg.held = false;
      if (mode != AutomationMode.touch) continue;
      _add(seg, _now, seg.value);
      _segments.remove(seg.target.key);
      _commit(seg, returns: true);
      released = true;
    }
    if (released) state.engine?.releaseTouches(); // the knobs it moved follow their (new) lanes again
    notifyListeners();
  }

  void _onTick() {
    if (!_armed || !_playing) return;
    final at = _now;
    if (mode == AutomationMode.write && !_writeStarted && state.meters.playing) _startWrite(at);
    if (at + 1 < _lastStep && _segments.isNotEmpty) {
      // The song (or its loop range) looped: what was written reaches the loop's end, and writing goes on from its start.
      final p = state.project;
      final (start, end) = p.loopsRange
          ? (p.loopStartSteps.toDouble(), p.loopEndSteps.toDouble())
          : (0.0, p.engineLoopSteps.toDouble());
      for (final seg in _segments.values.toList()) {
        _add(seg, end, seg.value);
        _commit(seg, returns: true);
        final next = _Segment(seg.target, seg.value, hadLane: true, original: seg.original)..held = seg.held;
        _add(next, start, seg.value);
        _segments[seg.target.key] = next;
      }
    }
    _lastStep = at;
  }

  /// Write: every lane in the project is overwritten with its control's value, from now until stop.
  void _startWrite(double at) {
    _writeStarted = true;
    _openTake();
    final targets = [
      for (final l in state.project.layers)
        for (final a in l.automation) AutomationTarget('track', a.target, layerId: l.id),
      for (final a in state.project.automation)
        AutomationTarget(a.targetType, a.target, layerId: a.layerId, moduleId: a.moduleId, component: a.component),
    ];
    for (final t in targets) {
      if (!_canAutomate(t) || !laneArmed(t) || _segments.containsKey(t.key)) continue;
      final seg = _start(t, at)..held = false;
      _add(seg, at, seg.value);
      _segments[t.key] = seg;
    }
    notifyListeners();
  }

  void _onState() {
    if (_takeOpen && !_playing) _finishTake();
    if (!_playing) {
      _writeStarted = false;
      _lastStep = state.pausedStep ?? 0;
    }
  }

  /// Stop (or a pause, a mode change, Automate off): what is still being written ends here, as one undo step.
  void _finishTake() {
    _idle?.cancel();
    final at = state.pausedStep ?? _lastStep;
    // Closed first: the commits below notify the state, which calls back here.
    final open = _segments.values.toList();
    _segments.clear();
    _takeOpen = false;
    _writeStarted = false;
    for (final seg in open) {
      _add(seg, math.max(at, seg.samples.isEmpty ? at : seg.samples.last.$1), seg.value);
      _commit(seg, returns: seg.hadLane || mode == AutomationMode.touch);
    }
    if (state.suspendedLanes.isNotEmpty) {
      state.suspendedLanes.clear();
      state.resyncEngine();
    }
    state.endAutomationGesture();
    state.holdHistory(false);
    if (mode == AutomationMode.write) {
      // REAPER's option: after a Write pass the lanes are read, so the next play doesn't overwrite them again.
      mode = AutomationMode.read;
      state.settings.automationMode = mode.name;
      state.settings.save();
    }
    notifyListeners();
  }

  /// Writes [seg] into its lane (made if needed): thinned, replacing the lane over the written span, with a short
  /// return to what the lane did after it when [returns].
  void _commit(_Segment seg, {required bool returns}) {
    final t = seg.target;
    if (seg.samples.isEmpty || !_canAutomate(t)) return;
    final range = _range(t, seg);
    final volume = t.kind == 'track' && t.name == 'volume';
    final thinned = thin(seg.samples, tolerance: 0.004 * range,
        forward: volume ? _gainToDb : null);
    state.editProject((p) {
      final old = _pointsOf(t);
      final merged = merge(old ?? const [], thinned, original: seg.original, returns: returns);
      _setPoints(t, merged);
    });
    if (state.suspendedLanes.remove(t.key)) state.resyncEngine();
  }

  // ---------- reading and writing the lanes ----------

  LayerDoc? _layer(String? id) => state.project.layers.where((l) => l.id == id).firstOrNull;

  bool _canAutomate(AutomationTarget t) {
    if (t.kind == 'param') return t.moduleId != null && state.project.module(t.moduleId) != null;
    if (t.kind == 'global') return true;
    final l = _layer(t.layerId);
    if (l == null) return false;
    return switch (t.kind) {
      'track' => !l.isFolder || l.busEnabled,
      'component' => (t.component ?? -1) >= 0 && t.component! < l.components.length,
      'instrument' => l.instrument != null,
      _ => false,
    };
  }

  Object? _laneOf(AutomationTarget t) {
    if (t.kind == 'track') return _layer(t.layerId)?.automation.where((a) => a.target == t.name).firstOrNull;
    return state.project.automation.where((a) => a.key == t.key).firstOrNull;
  }

  /// Whether moves of [t] are written: its lane is armed, or it has none yet (writing makes one, armed).
  bool laneArmed(AutomationTarget t) => switch (_laneOf(t)) {
        final AutomationLaneDoc lane => lane.armed,
        final ProjectAutomationLaneDoc lane => lane.armed,
        _ => true,
      };

  List<AutomationPointDoc>? _pointsOf(AutomationTarget t) => switch (_laneOf(t)) {
        final AutomationLaneDoc lane => lane.points,
        final ProjectAutomationLaneDoc lane => lane.points,
        _ => null,
      };

  void _setPoints(AutomationTarget t, List<AutomationPointDoc> points) {
    final lane = _laneOf(t);
    if (lane is AutomationLaneDoc) {
      lane.points = points;
    } else if (lane is ProjectAutomationLaneDoc) {
      lane.points = points;
    } else if (t.kind == 'track') {
      _layer(t.layerId)?.automation.add(AutomationLaneDoc(target: t.name, points: points));
    } else {
      state.project.automation.add(ProjectAutomationLaneDoc(targetType: t.kind, target: t.name,
          moduleId: t.moduleId, layerId: t.layerId, component: t.component, points: points));
    }
  }

  /// The control's stored value now.
  double valueOf(AutomationTarget t) {
    final l = _layer(t.layerId);
    switch (t.kind) {
      case 'track':
        return t.name == 'volume' ? l?.volume ?? 1 : l?.pan ?? 0;
      case 'component':
        final i = t.component ?? -1;
        if (l == null || i < 0 || i >= l.components.length) return 0;
        final use = l.components[i];
        return use.params[t.name] ?? _componentParam(use.id, t.name)?.defaultValue ?? 0;
      case 'instrument':
        final use = l?.instrument;
        if (use == null) return 0;
        return use.params[t.name] ?? _componentParam(use.id, t.name)?.defaultValue ?? 0;
      case 'param':
        return state.project.module(t.moduleId)?.params[t.name] ??
            state.info[t.moduleId]?.params.where((p) => p.name == t.name).firstOrNull?.defaultValue ?? 0;
      default:
        return state.project.globals[t.name] ??
            state.globalDefs.where((p) => p.name == t.name).firstOrNull?.defaultValue ?? 0;
    }
  }

  ComponentParameterInfo? _componentParam(String id, String param) =>
      state.componentInfo(id)?.parameters.where((p) => p.id == param).firstOrNull;

  /// The span of the control's values, for the thinning tolerance (volume: in dB, -60..+12).
  double _range(AutomationTarget t, _Segment seg) {
    double? lo, hi;
    final l = _layer(t.layerId);
    switch (t.kind) {
      case 'track':
        return t.name == 'volume' ? 72 : 2;
      case 'component' || 'instrument':
        final id = t.kind == 'instrument' ? l?.instrument?.id : (l != null && (t.component ?? -1) >= 0 &&
            t.component! < l.components.length ? l.components[t.component!].id : null);
        final p = id == null ? null : _componentParam(id, t.name);
        if (p != null) (lo, hi) = (p.min, p.max);
      case 'param':
        final p = state.info[t.moduleId]?.params.where((p) => p.name == t.name).firstOrNull;
        if (p != null) (lo, hi) = (p.min, p.max);
      default:
        final p = state.globalDefs.where((p) => p.name == t.name).firstOrNull;
        if (p != null) (lo, hi) = (p.min, p.max);
    }
    if (lo != null && hi != null && hi > lo) return hi - lo;
    final values = [seg.original, for (final s in seg.samples) s.$2];
    final span = values.reduce(math.max) - values.reduce(math.min);
    return span > 0 ? span : 1;
  }

  static double _gainToDb(double g) => g <= 0.001 ? -60 : (20 * math.log(g) / math.ln10).clamp(-60.0, 12.0);

  // ---------- the pure parts (tested on their own) ----------

  /// [samples] (step, value) with fewer points: moves within 1/32 step merge (the later wins), then
  /// Ramer-Douglas-Peucker keeps only points that bend the line by more than [tolerance] (in [forward]'s units,
  /// the values themselves without it). The first and last stay.
  static List<(double, double)> thin(List<(double, double)> samples,
      {required double tolerance, double Function(double)? forward}) {
    final sorted = [...samples]..sort((a, b) => a.$1.compareTo(b.$1));
    final pts = <(double, double)>[];
    for (final s in sorted) {
      if (pts.isNotEmpty && s.$1 - pts.last.$1 < 1 / 32) {
        pts[pts.length - 1] = (pts.last.$1, s.$2);
      } else {
        pts.add(s);
      }
    }
    if (pts.length <= 2) return pts;
    // Distances are measured in [forward]'s units (volume: dB), the values themselves are kept as they were.
    final v = [for (final p in pts) forward == null ? p.$2 : forward(p.$2)];
    final keep = List.filled(pts.length, false)..[0] = true..[pts.length - 1] = true;
    final stack = <(int, int)>[(0, pts.length - 1)];
    while (stack.isNotEmpty) {
      final (a, b) = stack.removeLast();
      var worst = -1.0, at = -1;
      for (var i = a + 1; i < b; i++) {
        final span = pts[b].$1 - pts[a].$1;
        final f = span <= 0 ? 0.0 : (pts[i].$1 - pts[a].$1) / span;
        final d = (v[i] - (v[a] + (v[b] - v[a]) * f)).abs();
        if (d > worst) (worst, at) = (d, i);
      }
      if (at > 0 && worst > tolerance) {
        keep[at] = true;
        stack..add((a, at))..add((at, b));
      }
    }
    return [for (var i = 0; i < pts.length; i++) if (keep[i]) pts[i]];
  }

  /// The lane's value at [at]: straight lines between points, held before the first and after the last (the
  /// engine's rule, `automationLaneValue`).
  static double valueAt(List<AutomationPointDoc> points, double at, double fallback) {
    if (points.isEmpty) return fallback;
    if (at <= points.first.step) return points.first.value;
    if (at >= points.last.step) return points.last.value;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      if (at <= b.step) {
        final span = b.step - a.step;
        return span <= 0 ? b.value : a.value + (b.value - a.value) * (at - a.step) / span;
      }
    }
    return points.last.value;
  }

  /// [old] with [written] in place of what it had over the written span: a point just before keeps the lane (or,
  /// for a new lane, [original]) up to there; with [returns], a point [returnSteps] after the span goes back to
  /// what the lane had there (a new lane: [original]), and the old points after it stay.
  static List<AutomationPointDoc> merge(List<AutomationPointDoc> old, List<(double, double)> written,
      {required double original, required bool returns}) {
    if (written.isEmpty) return [for (final p in old) AutomationPointDoc(step: p.step, value: p.value)];
    final sorted = [...old]..sort((a, b) => a.step.compareTo(b.step));
    final a = written.first.$1, b = written.last.$1;
    double prior(double t) => valueAt(sorted, t, original);
    final out = <AutomationPointDoc>[
      for (final p in sorted)
        if (p.step < a - 0.01) AutomationPointDoc(step: p.step, value: p.value),
    ];
    if (a >= 0.01 && (sorted.isNotEmpty || (written.first.$2 - original).abs() > 1e-9)) {
      out.add(AutomationPointDoc(step: a - 0.01, value: prior(a - 0.01)));
    }
    for (final w in written) {
      out.add(AutomationPointDoc(step: w.$1, value: w.$2));
    }
    if (returns) {
      final r = b + returnSteps;
      out.add(AutomationPointDoc(step: r, value: prior(r)));
      for (final p in sorted) {
        if (p.step > r + 0.01) out.add(AutomationPointDoc(step: p.step, value: p.value));
      }
    } else {
      for (final p in sorted) {
        if (p.step > b + 0.01) out.add(AutomationPointDoc(step: p.step, value: p.value));
      }
    }
    return out;
  }

  @override
  void dispose() {
    setArmed(false);
    _idle?.cancel();
    if (state.onParamMove == _moved) state.onParamMove = null;
    state.removeListener(_onState);
    state.tick.removeListener(_onTick);
    super.dispose();
  }
}
