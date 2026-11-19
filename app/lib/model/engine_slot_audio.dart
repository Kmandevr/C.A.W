// The device shell's per-slot meters and auto gain over the engine (C API 39): DeviceSlotAudio for a running engine.
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_fx.dart';
import 'device_slot_audio.dart';
import 'device_target.dart';
import 'mixer_fx.dart';
import 'project.dart';

/// [DeviceSlotAudio] read from [DeviceTarget.state]'s engine: each slot's output peak (`Engine.componentMeter`) and
/// auto gain (`Engine.setComponentAutoGain`, `Engine.componentAutoGain`), with the per-device switch kept in the
/// project ([ComponentUseDoc.autoGain], one undo step: [ArrangeFx.setNativeAutoGain]). [AppState] sets it as
/// [DeviceSlotAudio.current] once its engine loads, and clears it when the state goes.
///
/// Only a plain device has either: a rack's child, a modulator or a UI range is left out. A track's or the master's
/// effect has both; a track's instrument has a meter and no auto gain (the engine refuses it there); per-note effects
/// are not device targets.
class EngineSlotAudio extends DeviceSlotAudio {
  const EngineSlotAudio();

  static const instance = EngineSlotAudio();

  /// The last trim read for each effect, kept while the engine is busy (a project update) so the ear does not blink.
  static final Expando<double> _lastTrim = Expando('auto gain trim');

  @override
  bool get hasMeter => true;

  @override
  bool get hasAutoGain => true;

  static bool _plain(DeviceTarget t) => t.runtimeType == DeviceTarget;

  @override
  bool meterAvailable(DeviceTarget t) => _plain(t) && t.state.engine != null;

  @override
  bool autoGainAvailable(DeviceTarget t) => _plain(t) && !t.isInstrument && t.state.engine != null;

  /// Where [t] sits in the engine: its layer id (null: the master) and component index, or null when the engine has
  /// no such slot (no engine, gone, or an effect the engine hasn't loaded).
  static ({String? layer, int index})? _slot(DeviceTarget t) {
    final l = t.layer, use = t.use;
    if (l == null || use == null) return null;
    if (t.isInstrument) {
      return t.state.componentPlayable(use.id) ? (layer: l.id, index: ProjectDoc.instrumentIndex) : null;
    }
    final i = t.state.engineComponentIndex(l, t.slot);
    return i == null ? null : (layer: engineLayerId(l), index: i);
  }

  @override
  double? outputPeak(DeviceTarget t) {
    final e = t.state.engine;
    final at = e == null || !_plain(t) ? null : _slot(t);
    if (at == null) return null;
    // Null while the engine is busy: no new reading this frame (the meter falls as it would).
    final m = e!.componentMeter(at.layer, at.index);
    return m == null ? null : math.max(m.peakL, m.peakR);
  }

  /// The last cost read for each slot, kept while the engine is busy so the header doesn't blink.
  static final Expando<DeviceCost> _lastCost = Expando('slot cost');

  @override
  DeviceCost? cost(DeviceTarget t) {
    final e = t.state.engine, use = t.use;
    if (e == null || use == null || !_plain(t)) return null;
    final at = _slot(t);
    if (at == null) return null;
    final c = e.componentCost(at.layer, at.index);
    if (c == null) return _lastCost[use];
    return _lastCost[use] = DeviceCost(cpuShare: c.cpuShare, latencyMs: c.latencyMs, armed: c.armed);
  }

  @override
  bool autoGain(DeviceTarget t) => !t.isInstrument && _plain(t) && (t.use?.autoGain ?? false);

  @override
  void setAutoGain(DeviceTarget t, bool on) {
    final l = t.layer;
    if (l == null || !autoGainAvailable(t)) return;
    t.state.setNativeAutoGain(l, t.slot, on);
  }

  @override
  double? autoGainTrimDb(DeviceTarget t) {
    final use = t.use;
    if (use == null || !autoGain(t)) return null;
    final at = _slot(t);
    final e = t.state.engine;
    if (at == null || e == null) return null;
    final db = e.componentAutoGain(at.layer, at.index);
    if (db != null) _lastTrim[use] = db;
    return db ?? _lastTrim[use];
  }
}
