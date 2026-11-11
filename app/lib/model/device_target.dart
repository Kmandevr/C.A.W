// One device (a track's C++ instrument or one of its native effects) as a device editor sees it: values, live edits, commit.
import 'package:flutter/foundation.dart';

import '../engine/component_info.dart';
import 'app_state.dart';
import 'arrange_fx.dart';
import 'mixer_fx.dart';
import 'project.dart';
import 'racks.dart';

/// Where a device sits: track [layerId], and [slot] in its native chain (`instrumentSlot`: its instrument).
/// It resolves the track on every read, so it keeps working after an undo replaced the project's objects.
class DeviceTarget {
  const DeviceTarget(this.state, this.layerId, this.slot);

  /// The slot that names a track's instrument (the FX stack's instrument card uses the same -1).
  static const int instrumentSlot = -1;

  final AppState state;
  final String layerId;
  final int slot;

  bool get isInstrument => slot == instrumentSlot;

  /// The track (the master's stand-in, [masterLayerOf], for [masterLayerId]).
  LayerDoc? get layer => layerId == masterLayerId
      ? masterLayerOf(state.project) : state.project.layers.where((l) => l.id == layerId).firstOrNull;

  /// The device's entry in the project, or null when it is gone (removed, or undone away).
  ComponentUseDoc? get use {
    final l = layer;
    if (l == null) return null;
    if (isInstrument) return l.instrument;
    return slot >= 0 && slot < l.components.length ? l.components[slot] : null;
  }

  String? get componentId => use?.id;

  NativeComponentInfo? get info {
    final id = componentId;
    if (id == null) return null;
    final base = state.componentInfo(id);
    // A rack (fx-racks): its own parameters, its children's and its routes, for the children it holds now.
    final u = use;
    if (base == null || u == null || !isRackComponent(id)) return base;
    return rackInfo(base, u.params, state.componentCatalog.value);
  }

  /// Which of the component's children its live display is (0: the component itself; a rack's child: its slot + 1).
  int get displayChild => 0;

  String get label {
    final id = componentId;
    return id == null ? 'Device' : state.componentLabel(id);
  }

  /// Fires when a value of the track's devices changes (live edits, undo, redo).
  ValueListenable<int> get tick => state.layerValueTick(layerId);

  ComponentParameterInfo? param(String id) => info?.param(id);

  /// The parameter's current value: the project's, else its default (0 for an unknown id).
  double value(String id) => use?.params[id] ?? param(id)?.defaultValue ?? 0;

  /// A move during a gesture: live in the engine at once, kept in the project; [commit] when the gesture ends.
  void setLive(String id, double v) {
    final l = layer;
    if (l == null || use == null) return;
    final p = param(id);
    if (p != null) v = clampToParam(p, v);
    if (isInstrument) {
      state.setInstrumentParamLive(l, id, v);
    } else {
      state.setNativeParamLive(l, slot, id, v);
    }
  }

  /// Saves the values (one undo step per gesture).
  void commit() {
    final l = layer;
    if (l != null) state.commitNativeParams(l);
  }

  /// One finished change: [setLive] and [commit].
  void set(String id, double v) {
    setLive(id, v);
    commit();
  }

  /// Several values in one undo step (a reset, a cleared route).
  void setAll(Map<String, double> values) {
    for (final e in values.entries) {
      setLive(e.key, e.value);
    }
    commit();
  }

  bool get bypass => use?.bypass ?? false;

  void setBypass(bool on) {
    final l = layer;
    if (l == null || use == null) return;
    if (isInstrument) {
      state.setInstrumentBypass(l, on);
    } else {
      state.setNativeBypass(l, slot, on);
    }
  }

  /// Every parameter back to its descriptor default, as one undo step.
  void resetAll() {
    final i = info;
    if (i == null) return;
    setAll({for (final p in i.parameters) p.id: p.defaultValue});
  }
}

/// [v] inside [p]'s range, on its step.
double clampToParam(ComponentParameterInfo p, double v) {
  if (v.isNaN) return p.defaultValue;
  var x = v.clamp(p.min, p.max).toDouble();
  if (p.step > 0) x = (p.min + ((x - p.min) / p.step).round() * p.step).clamp(p.min, p.max).toDouble();
  return x;
}
