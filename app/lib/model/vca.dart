// VCA groups (REAPER-style): one fader over several tracks' levels, mute and solo, without summing their audio (no screen yet).
import 'project.dart';

/// The engine's limits (engine/src/project.h): groups per project, members per group.
const kMaxVcaGroups = 32;
const kMaxVcaMembers = 256;

/// A VCA group: its [volume] (linear, 0..[kMaxMixGain]) multiplies each member's own fader (after the member's
/// volume lane), and its [mute] and [solo] act on the members beside their own. Members are layer ids (tracks or
/// folder buses); a bus and its child both in one group scale the child twice, as REAPER does. [automation] is an
/// optional volume lane that replaces the fader while it has points, as a track's does.
class VcaGroupDoc {
  VcaGroupDoc({required this.id, required this.name, this.volume = 1.0, this.mute = false, this.solo = false,
      List<String>? members, this.automation})
      : members = members ?? [];

  final String id;
  String name;
  double volume;
  bool mute, solo;
  List<String> members;
  AutomationLaneDoc? automation;

  /// The project file: [withIds] with the lane's and its points' instance ids.
  Map<String, dynamic> toJson({bool withIds = false}) => {
        'id': id,
        'name': name,
        'volume': volume,
        if (mute) 'mute': true,
        if (solo) 'solo': true,
        'members': members,
        if (automation != null) 'automation': [automation!.toJson(withIds: withIds)],
      };

  /// The engine's entry ("vca_groups", docs/engine.md): only members in [layerIds] (the project's layers), and the
  /// lane only while it has points.
  Map<String, dynamic> toEngineJson(Set<String> layerIds) => {
        'id': id,
        'name': name,
        'volume': volume,
        'mute': mute,
        'solo': solo,
        'members': [for (final m in members) if (layerIds.contains(m)) m],
        if (automation case final lane? when lane.points.isNotEmpty)
          'automation': [lane.toJson()..remove('height')..remove('armed')],
      };

  /// Null for an entry that isn't a group (no string id). Values are held to the engine's ranges.
  static VcaGroupDoc? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || (j['id'] as String).isEmpty) return null;
    final volume = j['volume'];
    final lanes = j['automation'];
    final lane = lanes is List && lanes.isNotEmpty && lanes.first is Map<String, dynamic>
        ? AutomationLaneDoc.fromJson(lanes.first as Map<String, dynamic>) : null;
    return VcaGroupDoc(
      id: j['id'] as String,
      name: j['name'] is String ? j['name'] as String : 'VCA',
      volume: volume is num && volume.isFinite ? volume.toDouble().clamp(0.0, kMaxMixGain).toDouble() : 1.0,
      mute: j['mute'] == true,
      solo: j['solo'] == true,
      members: <String>{
        for (final m in ((j['members'] as List?) ?? const []).take(kMaxVcaMembers)) if (m is String) m,
      }.toList(),
      automation: lane == null ? null : (lane..target = 'volume'),
    );
  }
}

/// Model edits on a project's VCA groups (no screen yet: the owner decides how they look, Hub #35). Each is one undo
/// step through AppState, which saves and syncs the engine after it.
extension VcaEdits on ProjectDoc {
  VcaGroupDoc? vcaGroup(String id) => vcaGroups.where((g) => g.id == id).firstOrNull;

  /// A new group over [layerIds] (the layers among them, each once, at most [kMaxVcaMembers]); null when the project
  /// already holds [kMaxVcaGroups].
  VcaGroupDoc? createVcaGroup(Iterable<String> layerIds, {String? name}) {
    if (vcaGroups.length >= kMaxVcaGroups) return null;
    final ids = {for (final l in layers) l.id};
    final g = VcaGroupDoc(
      id: newId('v'),
      name: name ?? 'VCA ${vcaGroups.length + 1}',
      members: [for (final id in layerIds.toSet()) if (ids.contains(id)) id].take(kMaxVcaMembers).toList(),
    );
    vcaGroups.add(g);
    return g;
  }

  /// Adds [layerId] to group [groupId]; false when there is no such group or layer, it is a member already, or the
  /// group is full.
  bool addVcaMember(String groupId, String layerId) {
    final g = vcaGroup(groupId);
    if (g == null || g.members.contains(layerId) || g.members.length >= kMaxVcaMembers) return false;
    if (!layers.any((l) => l.id == layerId)) return false;
    g.members.add(layerId);
    return true;
  }

  bool removeVcaMember(String groupId, String layerId) => vcaGroup(groupId)?.members.remove(layerId) ?? false;

  bool deleteVcaGroup(String groupId) {
    final before = vcaGroups.length;
    vcaGroups.removeWhere((g) => g.id == groupId);
    return vcaGroups.length != before;
  }

  /// The groups [layerId] is a member of.
  List<VcaGroupDoc> vcaGroupsOf(String layerId) => [for (final g in vcaGroups) if (g.members.contains(layerId)) g];

  /// Drops members whose layer is gone, and repeats (toJson runs it through settleIds).
  void settleVcaGroups() {
    final ids = {for (final l in layers) l.id};
    for (final g in vcaGroups) {
      final seen = <String>{};
      g.members.removeWhere((m) => !ids.contains(m) || !seen.add(m));
    }
  }
}
