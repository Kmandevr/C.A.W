// Permissions at the host: role presets, each member's grants, the capability an op needs, and the walk from a
// node up its ancestors to the nearest scope that grants it.
import '../ids.dart';
import '../ops.dart';
import '../tree.dart';

/// The role presets; a custom role is any set of grants, given by an `access` op.
enum Role {
  viewer('viewer'),
  worker('worker'),
  collaborator('collaborator'),
  owner('owner');

  const Role(this.wire);
  final String wire;

  static Role? byWire(String wire) {
    for (final r in values) {
      if (r.wire == wire) return r;
    }
    return null;
  }

  /// The role's capabilities, all on the project scope. A worker's `edit_content` and `edit_code` on assigned
  /// scopes come from `access` ops.
  Set<Capability> get capabilities => switch (this) {
        Role.owner => Capability.values.toSet(),
        Role.collaborator => Capability.values.toSet()..removeAll([Capability.manageAccess, Capability.publish]),
        Role.worker => {Capability.view, Capability.renderExport},
        Role.viewer => {Capability.view},
      };

  List<Grant> get grants => [for (final c in Capability.values) if (capabilities.contains(c)) Grant(c, rootId)];
}

/// Which capability an op needs, and where it is checked.
///
/// Assumption: the design's table maps capabilities to areas (content, tracks, routing and settings, code) but
/// the host is model-agnostic, so the mapping goes by node kind: an insert, move, delete or revive of a
/// [structuralKinds] node needs `add_remove_tracks`; a `set` on a [settingsKinds] node needs `routing_settings`;
/// `text` needs `edit_code`; everything else on nodes needs `edit_content`. A `blob` or `checkpoint` needs
/// `edit_content` on some scope; `access` needs `manage_access` on the project. The coarse schema's defaults:
/// `track` is structural and `project` (which holds everything not yet mapped) is settings.
class PermissionPolicy {
  const PermissionPolicy({this.structuralKinds = const {'track'}, this.settingsKinds = const {'project'}});
  final Set<String> structuralKinds;
  final Set<String> settingsKinds;

  static const standard = PermissionPolicy();

  /// The checks [op] needs: each a capability and the node the walk starts from (null: any scope will do).
  List<(Capability, String?)> required(Op op, CollabTree tree) {
    String? kindOf(String id) => tree.node(id)?.kind;
    switch (op) {
      case SetOp():
        return [(settingsKinds.contains(kindOf(op.node)) ? Capability.routingSettings : Capability.editContent, op.node)];
      case TextOp():
        return [(Capability.editCode, op.node)];
      case InsertOp():
        return [(structuralKinds.contains(op.kind) ? Capability.addRemoveTracks : Capability.editContent, op.parent)];
      case MoveOp():
        final c = structuralKinds.contains(kindOf(op.node)) ? Capability.addRemoveTracks : Capability.editContent;
        return [(c, op.node), (c, op.parent)];
      case DeleteOp():
        return [(structuralKinds.contains(kindOf(op.node)) ? Capability.addRemoveTracks : Capability.editContent, op.node)];
      case ReviveOp():
        return [(structuralKinds.contains(kindOf(op.node)) ? Capability.addRemoveTracks : Capability.editContent, op.node)];
      case BlobOp():
      case CheckpointOp():
        return [(Capability.editContent, null)];
      case RestoreOp():
        return [(Capability.editContent, rootId)];
      case AccessOp():
        return [(Capability.manageAccess, rootId)];
    }
  }
}

/// Each member's grants, keyed by device key id.
class Permissions {
  final _grants = <String, List<Grant>>{};

  /// Every member the host has grants for (an empty list means removed).
  Map<String, List<Grant>> get all => Map.unmodifiable(_grants);

  List<Grant> grantsOf(String member) => _grants[member] ?? const [];

  bool isKnown(String member) => _grants.containsKey(member);

  void set(String member, List<Grant> grants) => _grants[member] = List.unmodifiable(grants);

  void clear() => _grants.clear();

  /// Whether [member] holds [capability] on [scope] itself.
  bool holds(String member, Capability capability, String scope) {
    for (final g in grantsOf(member)) {
      if (g.capability == capability && g.scope == scope) return true;
    }
    return false;
  }

  /// Whether [member] holds [capability] on any scope.
  bool holdsAnywhere(String member, Capability capability) => grantsOf(member).any((g) => g.capability == capability);

  /// Whether [member] may use [capability] at [node]: the walk goes from [node] up its ancestors (tombstoned ones
  /// too) to the nearest scope with a grant. A node the tree doesn't know is checked at the project scope (the
  /// tree then refuses the op as unknown).
  bool allows(CollabTree tree, String member, Capability capability, String? node) {
    if (node == null) return holdsAnywhere(member, capability);
    var id = tree.node(node) == null ? rootId : node;
    for (var steps = 0; steps <= tree.limits.maxDepth + 1; steps++) {
      if (holds(member, capability, id)) return true;
      if (id == rootId) return false;
      id = tree.node(id)!.parent;
    }
    return false;
  }

  /// Whether [member] may see the project at all.
  bool canView(String member) => holds(member, Capability.view, rootId);

  /// Whether every capability in [grants] is one [member] holds on the project (an invite gives at most one's own
  /// level).
  bool covers(String member, Iterable<Grant> grants) => grants.every((g) => holds(member, g.capability, rootId));
}
