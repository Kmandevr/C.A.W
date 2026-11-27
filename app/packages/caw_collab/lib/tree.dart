// The generic shared tree: nodes with ids, kinds, fields and ordered child lists, tombstones for deletes, and
// apply(op), which checks an op against the tree, the schema and the limits, applies it, and returns its inverse.
import 'fractional_key.dart';
import 'ids.dart';
import 'limits.dart';
import 'ops.dart';
import 'schema.dart';
import 'values.dart';

/// Why the tree refused an op. [reason] is a stable code (the design names `target_deleted`).
class OpRejected implements Exception {
  const OpRejected(this.reason, this.message);
  final String reason;
  final String message;

  static const invalid = 'invalid';
  static const unknownNode = 'unknown_node';
  static const duplicateNode = 'duplicate_node';
  static const targetDeleted = 'target_deleted';
  static const notDeleted = 'not_deleted';
  static const cycle = 'cycle';
  static const schema = 'schema';
  static const limit = 'limit';
  static const root = 'root';
  static const blobConflict = 'blob_conflict';

  @override
  String toString() => 'OpRejected($reason): $message';
}

/// One node. Tombstoned nodes keep everything, so a revive restores the subtree as it was.
class TreeNode {
  TreeNode._(this.id, this.kind, this.parent, this.list, this.key, this.fields);
  final String id;
  final String kind;

  /// The parent's id, the list it sits in and its key there; empty for the root.
  String parent;
  String list;
  String key;

  /// Whether this node itself is deleted (its descendants are hidden too, but keep their own flags).
  bool deleted = false;

  /// Field values, frozen. A field set to null is absent.
  final Map<String, Object?> fields;
}

/// A tree of nodes under one root, changed only through [apply].
///
/// Every replica applies the host's ops in `seq` order, so every replica that applied the same ops holds the same
/// tree. Ops that touch different nodes or different fields commute; children are ordered by (key, id), so
/// concurrent inserts at one position keep one order however they arrive.
class CollabTree {
  CollabTree(this.schema, {this.limits = TreeLimits.standard, this.opLimits = CollabLimits.standard}) {
    _nodes[rootId] = TreeNode._(rootId, schema.rootKind, '', '', '', {});
  }

  final Schema schema;
  final TreeLimits limits;
  final CollabLimits opLimits;

  final _nodes = <String, TreeNode>{};
  // parent id -> list name -> child ids (tombstoned ones included).
  final _children = <String, Map<String, Set<String>>>{};
  final _blobs = <String, BlobOp>{};

  /// The node with [id], tombstoned or not.
  TreeNode? node(String id) => _nodes[id];

  /// Every node, tombstones included.
  int get nodeCount => _nodes.length;

  /// The declared blobs by hash.
  Map<String, BlobOp> get blobs => Map.unmodifiable(_blobs);

  /// Whether [id] exists and neither it nor an ancestor is deleted.
  bool isVisible(String id) {
    var n = _nodes[id];
    while (n != null) {
      if (n.deleted) return false;
      if (n.id == rootId) return true;
      n = _nodes[n.parent];
    }
    return false;
  }

  /// The children in [parent]'s [list], ordered by key and then id; tombstoned ones only with [includeDeleted].
  List<String> children(String parent, String list, {bool includeDeleted = false}) {
    final ids = _children[parent]?[list];
    if (ids == null) return const [];
    final out = [for (final id in ids) if (includeDeleted || !_nodes[id]!.deleted) _nodes[id]!];
    out.sort((a, b) {
      final c = a.key.compareTo(b.key);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return [for (final n in out) n.id];
  }

  /// [key], or the host's tie-break of it when a sibling in [parent]'s [list] already has it: the author's short
  /// id appended until it is unique ([FractionalKeys.withSuffix]).
  ///
  /// Assumption: tombstoned siblings count (a revive brings them back), and after 8 tries, or once the key would
  /// pass the length limit, the key is left as it is: the (key, id) order still makes it stable.
  String resolveKey(String parent, String list, String key, String author) {
    final taken = {for (final id in _children[parent]?[list] ?? const <String>{}) _nodes[id]!.key};
    var k = key;
    for (var i = 0; i < 8 && taken.contains(k); i++) {
      final next = FractionalKeys.withSuffix(k, author);
      if (next.length > opLimits.maxKeyLength) return k;
      k = next;
    }
    return k;
  }

  /// Applies [op] and returns its inverse (null for ops that have none), or throws [OpRejected] and changes
  /// nothing. The inverse carries [op]'s author with sequence numbers of 0, for the caller to fill.
  ///
  /// Assumption: `access`, `checkpoint` and `restore` change no tree state (permissions, history and the host's
  /// expansion of a restore are later steps); they are checked for form and return no inverse.
  Op? apply(Op op) {
    final problem = opProblem(op, opLimits);
    if (problem != null) throw OpRejected(OpRejected.invalid, problem);
    Op inv(Op o) => o.withHeader(author: op.author, clientSeq: 0, baseSeq: 0);
    switch (op) {
      case SetOp():
        final n = _visible(op.node);
        _fieldCheck(n.kind, op.field, op.value);
        final old = n.fields[op.field];
        _write(n, op.field, op.value);
        return inv(SetOp(node: n.id, field: op.field, value: old, author: op.author, clientSeq: 0, baseSeq: 0));
      case TextOp():
        final n = _visible(op.node);
        if (!schema.isText(n.kind, op.field)) throw OpRejected(OpRejected.schema, '${n.kind}.${op.field} is not a text field');
        final old = n.fields[op.field];
        _write(n, op.field, op.value);
        return old is String
            ? inv(TextOp(node: n.id, field: op.field, value: old, lockEpoch: op.lockEpoch, author: op.author, clientSeq: 0, baseSeq: 0))
            : inv(SetOp(node: n.id, field: op.field, value: null, author: op.author, clientSeq: 0, baseSeq: 0));
      case InsertOp():
        final p = _visible(op.parent);
        if (_nodes.containsKey(op.node)) throw OpRejected(OpRejected.duplicateNode, '${op.node} already exists');
        if (_nodes.length >= limits.maxNodes) throw OpRejected(OpRejected.limit, 'over ${limits.maxNodes} nodes');
        final sp = schema.childProblem(p.kind, op.list, op.kind);
        if (sp != null) throw OpRejected(OpRejected.schema, sp);
        if (_depth(p) + 1 > limits.maxDepth) throw OpRejected(OpRejected.limit, 'deeper than ${limits.maxDepth}');
        for (final e in op.fields.entries) {
          _fieldCheck(op.kind, e.key, e.value);
        }
        final n = TreeNode._(op.node, op.kind, p.id, op.list, op.key, {
          for (final e in op.fields.entries)
            if (e.value != null) e.key: freezeValue(e.value),
        });
        _nodes[n.id] = n;
        _link(n);
        return inv(DeleteOp(node: n.id, author: op.author, clientSeq: 0, baseSeq: 0));
      case MoveOp():
        if (op.node == rootId) throw const OpRejected(OpRejected.root, 'the root cannot move');
        final n = _visible(op.node);
        final p = _visible(op.parent);
        final sp = schema.childProblem(p.kind, op.list, n.kind);
        if (sp != null) throw OpRejected(OpRejected.schema, sp);
        for (TreeNode? a = p; a != null; a = a.id == rootId ? null : _nodes[a.parent]) {
          if (a.id == n.id) throw const OpRejected(OpRejected.cycle, 'a node cannot move into its own subtree');
        }
        if (_depth(p) + 1 + _height(n, 0) > limits.maxDepth) throw OpRejected(OpRejected.limit, 'deeper than ${limits.maxDepth}');
        final back = MoveOp(node: n.id, parent: n.parent, list: n.list, key: n.key, author: op.author, clientSeq: 0, baseSeq: 0);
        _unlink(n);
        n
          ..parent = p.id
          ..list = op.list
          ..key = op.key;
        _link(n);
        return inv(back);
      case DeleteOp():
        if (op.node == rootId) throw const OpRejected(OpRejected.root, 'the root cannot be deleted');
        final n = _visible(op.node);
        n.deleted = true;
        return inv(ReviveOp(node: n.id, author: op.author, clientSeq: 0, baseSeq: 0));
      case ReviveOp():
        final n = _nodes[op.node];
        if (n == null) throw OpRejected(OpRejected.unknownNode, '${op.node} does not exist');
        if (!n.deleted) throw OpRejected(OpRejected.notDeleted, '${op.node} is not deleted');
        // Assumption: a node under a deleted ancestor can't be revived on its own (the design's undo revives
        // the parent first when the same person deleted it).
        if (!isVisible(n.parent)) throw OpRejected(OpRejected.targetDeleted, 'the parent of ${op.node} is deleted');
        n.deleted = false;
        return inv(DeleteOp(node: n.id, author: op.author, clientSeq: 0, baseSeq: 0));
      case BlobOp():
        // Assets are immutable by hash: the same declaration again changes nothing; a different one is refused.
        final had = _blobs[op.hash];
        if (had == null) {
          _blobs[op.hash] = op;
        } else if (canonicalJson(had.bodyJson()) != canonicalJson(op.bodyJson())) {
          throw OpRejected(OpRejected.blobConflict, '${op.hash} was declared with other metadata');
        }
        return null;
      case AccessOp():
      case CheckpointOp():
      case RestoreOp():
        return null;
    }
  }

  /// The whole tree, tombstones included, as canonical JSON-shaped data: equal trees give equal snapshots.
  Map<String, Object?> snapshot() {
    final ids = _nodes.keys.toList()..sort();
    final hashes = _blobs.keys.toList()..sort();
    return {
      'schema': schema.hash,
      'nodes': {
        for (final id in ids)
          id: {
            'kind': _nodes[id]!.kind,
            'parent': _nodes[id]!.parent,
            'list': _nodes[id]!.list,
            'key': _nodes[id]!.key,
            'deleted': _nodes[id]!.deleted,
            'fields': Map<String, Object?>.unmodifiable(_nodes[id]!.fields),
          },
      },
      'blobs': {for (final h in hashes) h: _blobs[h]!.bodyJson()},
    };
  }

  /// What a reader sees: the visible nodes from the root down, children in order, tombstones left out.
  Map<String, Object?> visibleView() => _view(_nodes[rootId]!);

  Map<String, Object?> _view(TreeNode n) {
    final lists = (_children[n.id]?.keys.toList() ?? <String>[])..sort();
    return {
      'id': n.id,
      'kind': n.kind,
      'fields': Map<String, Object?>.unmodifiable(n.fields),
      'lists': {
        for (final l in lists)
          if (children(n.id, l).isNotEmpty) l: [for (final c in children(n.id, l)) _view(_nodes[c]!)],
      },
    };
  }

  TreeNode _visible(String id) {
    final n = _nodes[id];
    if (n == null) throw OpRejected(OpRejected.unknownNode, '$id does not exist');
    if (!isVisible(id)) throw OpRejected(OpRejected.targetDeleted, '$id is deleted');
    return n;
  }

  void _fieldCheck(String kind, String field, Object? value) {
    final p = schema.fieldProblem(kind, field, value);
    if (p != null) throw OpRejected(OpRejected.schema, p);
  }

  void _write(TreeNode n, String field, Object? value) {
    if (value == null) {
      n.fields.remove(field);
    } else {
      n.fields[field] = freezeValue(value);
    }
  }

  int _depth(TreeNode n) {
    var d = 0;
    for (var a = n; a.id != rootId; a = _nodes[a.parent]!) {
      d++;
    }
    return d;
  }

  // How far the deepest descendant sits below n (0 for a leaf), tombstones included.
  int _height(TreeNode n, int level) {
    if (level > limits.maxDepth) return level;
    var h = 0;
    for (final ids in _children[n.id]?.values ?? const <Set<String>>[]) {
      for (final id in ids) {
        final c = 1 + _height(_nodes[id]!, level + 1);
        if (c > h) h = c;
      }
    }
    return h;
  }

  void _link(TreeNode n) => ((_children[n.parent] ??= {})[n.list] ??= <String>{}).add(n.id);

  void _unlink(TreeNode n) {
    final lists = _children[n.parent];
    final set = lists?[n.list];
    set?.remove(n.id);
    if (set != null && set.isEmpty) lists!.remove(n.list);
    if (lists != null && lists.isEmpty) _children.remove(n.parent);
  }
}
