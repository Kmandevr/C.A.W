// One device's own steps in the project's undo history (the device header's ⋯ › Undo history): what each step changed on it.
import 'dart:convert';

import 'device_target.dart';
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
/// stood before that step. A step that removed or replaced the device (another component in its slot) ends the
/// list: earlier values belong to something else.
List<DeviceHistoryStep> deviceHistory(DeviceTarget t, {int limit = 30}) {
  final use = t.use;
  if (use == null) return const [];
  final snapshots = t.state.history.undoSnapshots;
  final out = <DeviceHistoryStep>[];
  var after = Map<String, double>.of(use.params);
  for (var i = snapshots.length - 1; i >= 0 && out.length < limit; i--) {
    final before = _deviceIn(snapshots[i], t, use.id);
    if (before == null) break;
    final keys = {...before.keys, ...after.keys};
    final changed = [for (final k in keys) if ((before[k] ?? double.nan) != (after[k] ?? double.nan) &&
        !(before[k] == null && after[k] == null)) k]..sort();
    if (changed.isNotEmpty) {
      out.add(DeviceHistoryStep(stepsBack: snapshots.length - i, values: before, changed: changed));
    }
    after = before;
  }
  return out;
}

/// The values of the device in [t]'s slot in a project snapshot, when it is still component [componentId].
Map<String, double>? _deviceIn(String snapshot, DeviceTarget t, String componentId) {
  final Object? j;
  try {
    j = jsonDecode(snapshot);
  } on FormatException {
    return null;
  }
  if (j is! Map) return null;
  Object? entry;
  if (t.layerId == masterLayerId) {
    final list = j['master_components'];
    entry = list is List && t.slot >= 0 && t.slot < list.length ? list[t.slot] : null;
  } else {
    final layers = j['layers'];
    if (layers is! List) return null;
    final layer = layers.whereType<Map>().where((l) => l['id'] == t.layerId).firstOrNull;
    if (layer == null) return null;
    if (t.isInstrument) {
      entry = layer['instrument'];
    } else {
      final list = layer['components'];
      entry = list is List && t.slot >= 0 && t.slot < list.length ? list[t.slot] : null;
    }
  }
  final String? id = entry is String ? entry : (entry is Map && entry['id'] is String ? entry['id'] as String : null);
  if (id != componentId) return null;
  final params = entry is Map ? entry['params'] : null;
  return {
    if (params is Map)
      for (final e in params.entries)
        if (e.key is String && e.value is num && (e.value as num).isFinite) e.key as String: (e.value as num).toDouble(),
  };
}
