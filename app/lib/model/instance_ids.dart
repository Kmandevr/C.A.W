// Stable ids for a project's devices, sends, automation lanes and points and samples: shape, load check, index lookup.
import 'project.dart';

/// The prefixes [newId] makes instance ids with: `d` a device (a [ComponentUseDoc]: an instrument, effect or
/// per-note effect), `s` a send, `al` an automation lane, `ap` an automation point, `cs` a component's sample slot.
/// Each id is its prefix and 8 base-36 characters; the project file keeps them, the engine never sees them.
abstract final class InstanceIds {
  static const device = 'd', send = 's', lane = 'al', point = 'ap', sample = 'cs';

  static final _body = RegExp(r'^[0-9a-z]{8}$');

  /// Whether [raw] is an id [newId] made with [prefix]; anything else read from a file is replaced.
  static bool valid(Object? raw, String prefix) =>
      raw is String && raw.length == prefix.length + 8 && raw.startsWith(prefix) &&
      _body.hasMatch(raw.substring(prefix.length));

  /// [raw] when it is a well-formed id with [prefix], else null (a fresh one is made when it is first asked for).
  static String? read(Object? raw, String prefix) => valid(raw, prefix) ? raw as String : null;
}

/// Where device [uid] sits in [chain], or -1.
int deviceIndexIn(List<ComponentUseDoc> chain, String? uid) =>
    uid == null ? -1 : chain.indexWhere((c) => c.uid == uid);

/// The device a lane or link on [chain] aims at: the one [device] names when it is in [chain], else the one at
/// [index] (a file without device ids, or one whose id names nothing there); null when neither is.
ComponentUseDoc? aimedDevice(List<ComponentUseDoc> chain, String? device, int index) {
  final at = deviceIndexIn(chain, device);
  if (at >= 0) return chain[at];
  return index >= 0 && index < chain.length ? chain[index] : null;
}

extension ProjectInstanceIds on ProjectDoc {
  /// The effect chain lanes and links on [layerId] address (null: the master's), [notes] its per-note effects.
  List<ComponentUseDoc>? deviceChain(String? layerId, {bool notes = false}) {
    if (layerId == null) return notes ? null : masterComponents;
    final layer = layers.where((l) => l.id == layerId).firstOrNull;
    return layer == null ? null : (notes ? layer.noteComponents : layer.components);
  }

  /// Gives every device, send, lane, point and sample an id used once in the project (the first in project order
  /// keeps a repeated one, the later ones get new ids), then aims each effect lane and modulation link at its device
  /// by id: the device id when it names one of the chain, else the device at the saved index (an older file), whose
  /// index is then kept in step. Run when a project is read and each time it is written (a save, an undo snapshot).
  void settleIds() {
    final seen = <String>{};
    String once(String id, String prefix) {
      var out = id;
      while (!seen.add(out)) {
        out = newId(prefix);
      }
      return out;
    }

    void points(List<AutomationPointDoc> list) {
      for (final p in list) {
        p.uid = once(p.uid, InstanceIds.point);
      }
    }

    void chain(Iterable<ComponentUseDoc> list) {
      for (final c in list) {
        c.uid = once(c.uid, InstanceIds.device);
        for (final s in c.samples) {
          s.uid = once(s.uid, InstanceIds.sample);
        }
      }
    }

    chain(masterComponents);
    for (final l in layers) {
      chain([?l.instrument, ...l.components, ...l.noteComponents]);
      for (final s in l.sends) {
        s.uid = once(s.uid, InstanceIds.send);
      }
      for (final lane in l.automation) {
        lane.uid = once(lane.uid, InstanceIds.lane);
        points(lane.points);
      }
      for (final clip in l.clips) {
        for (final lane in clip.automation) {
          lane.uid = once(lane.uid, InstanceIds.lane);
          points(lane.points);
          if (lane.targetType != 'component') continue;
          final use = aimedDevice(l.components, lane.device, lane.component ?? -1);
          lane.device = use?.uid;
          if (use != null) lane.component = l.components.indexOf(use);
        }
      }
    }
    for (final lane in automation) {
      lane.uid = once(lane.uid, InstanceIds.lane);
      points(lane.points);
      if (lane.targetType != 'component' && lane.targetType != 'noteComponent') {
        lane.device = null;
        continue;
      }
      final list = deviceChain(lane.layerId, notes: lane.targetType == 'noteComponent');
      final use = list == null ? null : aimedDevice(list, lane.device, lane.component ?? -1);
      lane.device = use?.uid;
      if (use != null) lane.component = list!.indexOf(use);
    }
    for (final link in modLinks) {
      final t = link.target;
      if (t.type != 'component') continue;
      final list = deviceChain(t.layerId);
      final use = list == null ? null : aimedDevice(list, t.device, t.index);
      if (use == null) {
        if (t.device != null) link.target = t.at(t.index, device: null);
      } else if (use.uid != t.device || list!.indexOf(use) != t.index) {
        link.target = t.at(list!.indexOf(use), device: use.uid);
      }
    }
  }
}
