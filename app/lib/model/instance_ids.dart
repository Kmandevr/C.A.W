// Stable ids for a project's devices, sends, automation lanes and points and samples: shape, load check, index lookup.
import 'project.dart';
import 'vca.dart';

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

/// The device a lane or link on [chain] aims at: the one [device] names, else (no device id yet: a file from before
/// them, a lane just made) the one at [index]. Null when there is none: an id naming nothing in [chain] (a removed
/// device) never falls back to its index, so nothing is re-aimed at whatever sits there now.
ComponentUseDoc? aimedDevice(List<ComponentUseDoc> chain, String? device, int index) {
  if (device != null) return switch (deviceIndexIn(chain, device)) { -1 => null, final at => chain[at] };
  return index >= 0 && index < chain.length ? chain[index] : null;
}

/// Where a lane or link on [chain] plays: its device's index ([aimedDevice]), or null when it aims at nothing.
int? aimedIndex(List<ComponentUseDoc> chain, String? device, int index) =>
    device == null ? index : switch (deviceIndexIn(chain, device)) { -1 => null, final at => at };

extension ProjectInstanceIds on ProjectDoc {
  /// The effect chain lanes and links on [layerId] address (null: the master's), [notes] its per-note effects.
  List<ComponentUseDoc>? deviceChain(String? layerId, {bool notes = false}) {
    if (layerId == null) return notes ? null : masterComponents;
    final layer = layers.where((l) => l.id == layerId).firstOrNull;
    return layer == null ? null : (notes ? layer.noteComponents : layer.components);
  }

  /// Gives every device, send, lane, point and sample an id used once in the project (the first in project order
  /// keeps a repeated one, the later ones get new ids), then aims each effect lane and modulation link at its device
  /// by id, its index kept in step: one without a device id yet (an older file) gets the id of the device at its
  /// index; one whose id names no device of its chain (a removed one) goes, as a removed device's lanes do. A clip
  /// lane naming a device of another track (its clip moved there) goes by its index on the new track, as before ids. Run when a project is read and each time it is written (a save, an undo snapshot).
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
    }
    // Every track's effect ids, for clip lanes whose clip moved to another track.
    final elsewhere = {for (final l in layers) for (final c in l.components) c.uid};
    for (final l in layers) {
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
        }
        clip.automation.removeWhere((lane) {
          if (lane.targetType != 'component') return false;
          if (lane.device != null && deviceIndexIn(l.components, lane.device) < 0 && elsewhere.contains(lane.device)) {
            lane.device = null;  // the clip moved here from the device's track: its index decides, as before ids
          }
          final use = aimedDevice(l.components, lane.device, lane.component ?? -1);
          if (use == null) return lane.device != null;
          lane.device = use.uid;
          lane.component = l.components.indexOf(use);
          return false;
        });
      }
    }
    for (final lane in automation) {
      lane.uid = once(lane.uid, InstanceIds.lane);
      points(lane.points);
    }
    for (final g in vcaGroups) {
      if (g.automation case final lane?) {
        lane.uid = once(lane.uid, InstanceIds.lane);
        points(lane.points);
      }
    }
    settleVcaGroups();  // members whose layer is gone leave their groups
    // A chain that is gone (its track deleted) leaves its lanes and links as they are.
    automation.removeWhere((lane) {
      if (lane.targetType != 'component' && lane.targetType != 'noteComponent') {
        lane.device = null;
        return false;
      }
      final list = deviceChain(lane.layerId, notes: lane.targetType == 'noteComponent');
      if (list == null) return false;
      final use = aimedDevice(list, lane.device, lane.component ?? -1);
      if (use == null) return lane.device != null;
      lane.device = use.uid;
      lane.component = list.indexOf(use);
      return false;
    });
    modLinks.removeWhere((link) {
      final t = link.target;
      if (t.type != 'component') return false;
      final list = deviceChain(t.layerId);
      if (list == null) return false;
      final use = aimedDevice(list, t.device, t.index);
      if (use == null) return t.device != null;
      if (use.uid != t.device || list.indexOf(use) != t.index) link.target = t.at(list.indexOf(use), device: use.uid);
      return false;
    });
  }
}
