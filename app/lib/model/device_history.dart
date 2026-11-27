// One device's own steps in the project's undo history (the device header's ⋯ › Undo history): what each step changed on it.
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'device_target.dart';
import 'merged_devices.dart' show rackLayoutParam;
import 'mixer_fx.dart' show masterLayerId;

/// One undo step as a device sees it: its values as they stood before the step, and which of them that step changed.
class DeviceHistoryStep {
  const DeviceHistoryStep({required this.stepsBack, required this.values, required this.changed});

  /// How many undo steps back it is (1: the last step).
  final int stepsBack;

  /// The device's values in that snapshot.
  final Map<String, double> values;

  /// The parameters whose value differs from the snapshot after it (or from now, for the newest).
  final List<String> changed;
}

/// The undo steps that changed [t]'s values, newest first, at most [limit]. Each holds the device's values as they
/// stood before that step. Only the descriptor's parameters count (a rack's saved layout is not one of its knobs).
/// The device is found in each snapshot by its instance id (`ComponentUseDoc.uid`), so its steps from before a
/// reorder, or a move to another chain, still count. The step that added it (no device with its id before) or
/// replaced it ends the list. A snapshot without device ids falls back to its slot, ending the list at a step that
/// changed the chain's order (an effect added, removed or moved). Call [AppState.endUndoStep] first, so an edit
/// still settling is a step.
List<DeviceHistoryStep> deviceHistory(DeviceTarget t, {int limit = 30}) {
  final use = t.use, info = t.info;
  if (use == null) return const [];
  final ids = info == null ? null : {for (final p in info.parameters) p.id};
  Map<String, double> known(Map<String, double> v) =>
      ids == null ? v : {for (final e in v.entries) if (ids.contains(e.key)) e.key: e.value};
  final snapshots = t.state.history.undoSnapshots;
  _forget(snapshots);
  final out = <DeviceHistoryStep>[];
  final chain = _chainNow(t);
  ({List<_Entry>? chain, Map<String, double> values}) after = (chain: chain, values: known(use.params));
  for (var i = snapshots.length - 1; i >= 0 && out.length < limit; i--) {
    final slices = _slicesOf(snapshots[i]);
    if (slices == null) break;
    final _Entry entry;
    List<_Entry>? beforeChain;
    if (slices.byUid.isNotEmpty) {
      final found = slices.byUid[use.uid];
      if (found == null) break;
      entry = found;
    } else {
      beforeChain = _chainIn(slices, t);
      if (beforeChain == null || after.chain == null || !_sameOrder(beforeChain, after.chain!)) break;
      entry = t.isInstrument ? beforeChain.single : beforeChain[t.slot];
    }
    if (entry.id != use.id) break;
    final before = known(entry.params);
    final keys = {...before.keys, ...after.values.keys};
    final changed = [for (final k in keys) if (before[k] != after.values[k]) k]..sort();
    if (changed.isNotEmpty) {
      out.add(DeviceHistoryStep(stepsBack: snapshots.length - i, values: before, changed: changed));
    }
    after = (chain: beforeChain, values: before);
  }
  return out;
}

/// How many snapshots [deviceHistory] has decoded so far (each is decoded once while it stays in the history).
@visibleForTesting
int deviceHistoryDecodes = 0;

/// One saved device entry: its component and values.
typedef _Entry = ({String id, Map<String, double> params});

/// The devices of one snapshot: each track's instrument and effects by track id, the master's effects, and every
/// device by its instance id (empty for a snapshot saved without ids).
typedef _Slices = ({Map<String, (_Entry?, List<_Entry>)> layers, List<_Entry> master, Map<String, _Entry> byUid});

/// The decoded devices of the snapshots seen, by the snapshot (the history keeps each one's text unchanged, so a
/// later look decodes only the steps added since). Null: a snapshot that doesn't read.
final Map<String, _Slices?> _cache = Map.identity();

void _forget(List<String> live) {
  if (_cache.isEmpty) return;
  final keep = Set<String>.identity()..addAll(live);
  _cache.removeWhere((k, _) => !keep.contains(k));
}

_Slices? _slicesOf(String snapshot) {
  if (_cache.containsKey(snapshot)) return _cache[snapshot];
  deviceHistoryDecodes++;
  return _cache[snapshot] = _decode(snapshot);
}

_Slices? _decode(String snapshot) {
  final Object? j;
  try {
    j = jsonDecode(snapshot);
  } on FormatException {
    return null;
  }
  if (j is! Map) return null;
  List<_Entry> list(Object? x) => [if (x is List) for (final e in x) _entry(e) ?? (id: '', params: const {})];
  final byUid = <String, _Entry>{};
  // A chain's ids sit beside its entries (ComponentUseDoc.idsJson), one per entry.
  void index(List<_Entry> chain, Object? uids) {
    if (uids is! List || uids.length != chain.length) return;
    for (var i = 0; i < chain.length; i++) {
      if (uids[i] case final String uid) byUid[uid] = chain[i];
    }
  }
  final layers = <String, (_Entry?, List<_Entry>)>{};
  if (j['layers'] case final List ls) {
    for (final l in ls.whereType<Map>()) {
      final instrument = _entry(l['instrument']), effects = list(l['components']);
      if (instrument != null) index([instrument], [l['instrument_uid']]);
      index(effects, l['component_uids']);
      if (l['id'] case final String id) layers[id] = (instrument, effects);
    }
  }
  final master = list(j['master_components']);
  index(master, j['master_component_uids']);
  return (layers: layers, master: master, byUid: byUid);
}

_Entry? _entry(Object? e) {
  final String? id = e is String ? e : (e is Map && e['id'] is String ? e['id'] as String : null);
  if (id == null) return null;
  final params = e is Map ? e['params'] : null;
  return (id: id, params: {
    if (params is Map)
      for (final p in params.entries)
        // A rack's layout is saved with it but is not one of its values (ComponentUseDoc.toJson).
        if (p.key is String && p.key != rackLayoutParam && p.value is num && (p.value as num).isFinite)
          p.key as String: (p.value as num).toDouble(),
  });
}

/// [t]'s chain in a snapshot: the instrument alone, or the track's (the master's) effects; null when it isn't there.
List<_Entry>? _chainIn(_Slices s, DeviceTarget t) {
  if (t.layerId == masterLayerId && !t.isInstrument) return _inRange(s.master, t.slot);
  final layer = s.layers[t.layerId];
  if (layer == null) return null;
  if (t.isInstrument) return layer.$1 == null ? null : [layer.$1!];
  return _inRange(layer.$2, t.slot);
}

List<_Entry>? _inRange(List<_Entry> chain, int slot) => slot >= 0 && slot < chain.length ? chain : null;

/// [t]'s chain as the project holds it now.
List<_Entry> _chainNow(DeviceTarget t) {
  if (t.isInstrument) return [(id: t.use!.id, params: t.use!.params)];
  final list = t.layerId == masterLayerId ? t.state.project.masterComponents : t.layer?.components ?? const [];
  return [for (final c in list) (id: c.id, params: c.params)];
}

/// Whether a step kept the chain's order: the same components in the same places, and not two of them swapped
/// (the same entries, values and all, in another order).
bool _sameOrder(List<_Entry> a, List<_Entry> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  final moved = [for (var i = 0; i < a.length; i++) if (!_sameValues(a[i].params, b[i].params)) i];
  if (moved.length < 2) return true;
  // Several entries changed: a move when each one now holds another's values exactly.
  final left = [for (final i in moved) b[i]];
  for (final i in moved) {
    final at = left.indexWhere((e) => e.id == a[i].id && _sameValues(e.params, a[i].params));
    if (at < 0) return true;
    left.removeAt(at);
  }
  return false;
}

bool _sameValues(Map<String, double> a, Map<String, double> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}
