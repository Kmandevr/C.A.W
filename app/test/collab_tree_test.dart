// caw_collab's tree: the schema check, tombstones, moves that can't make cycles, the depth and size limits,
// inverses, and convergence of concurrent ops wherever the design says they converge.
import 'dart:math';

import 'package:caw_collab/caw_collab.dart';
import 'package:flutter_test/flutter_test.dart';

// A nesting schema for structural tests: folders hold folders and leaves.
final folders = Schema(version: 1, rootKind: 'project', kinds: const [
  KindSpec('project', lists: {'items': {'folder', 'leaf'}}),
  KindSpec('folder', fields: {'name': FieldSpec(FieldType.string), 'gain': FieldSpec(FieldType.number, min: 0, max: 2), 'source': FieldSpec(FieldType.text)}, lists: {'items': {'folder', 'leaf'}}),
  KindSpec('leaf', fields: {'name': FieldSpec(FieldType.string), 'on': FieldSpec(FieldType.boolean)}),
]);

int _cs = 0;
InsertOp ins(String parent, String node, {String kind = 'folder', String list = 'items', String key = 'V', Map<String, Object?> fields = const {}, String author = 'kim'}) =>
    InsertOp(parent: parent, list: list, node: node, key: key, kind: kind, fields: fields, author: author, clientSeq: ++_cs, baseSeq: 0);
SetOp set(String node, String field, Object? value, {String author = 'kim'}) => SetOp(node: node, field: field, value: value, author: author, clientSeq: ++_cs, baseSeq: 0);
MoveOp mv(String node, String parent, {String key = 'V', String author = 'kim'}) => MoveOp(node: node, parent: parent, list: 'items', key: key, author: author, clientSeq: ++_cs, baseSeq: 0);
DeleteOp del(String node) => DeleteOp(node: node, author: 'kim', clientSeq: ++_cs, baseSeq: 0);
ReviveOp rev(String node) => ReviveOp(node: node, author: 'kim', clientSeq: ++_cs, baseSeq: 0);

Matcher rejected(String reason) => throwsA(isA<OpRejected>().having((e) => e.reason, 'reason', reason));

String id(int i) => 'f${i.toString().padLeft(8, '0')}';

/// The tree's structural invariants: every node's parent exists, sits in its parent's list, and the root is
/// reached within the depth limit (so there is no cycle).
void checkInvariants(CollabTree t, Iterable<String> ids) {
  for (final i in [rootId, ...ids]) {
    final n = t.node(i);
    if (n == null) continue;
    if (i == rootId) continue;
    expect(t.node(n.parent), isNotNull, reason: '$i has a parent');
    expect(t.children(n.parent, n.list, includeDeleted: true), contains(i));
    var depth = 0;
    for (var a = n; a.id != rootId; a = t.node(a.parent)!) {
      depth++;
      expect(depth, lessThanOrEqualTo(t.limits.maxDepth), reason: 'a cycle or too deep at $i');
    }
  }
}

/// A random op over [n] candidate ids, valid or not.
Op randomOp(Random r, int n) {
  final a = id(r.nextInt(n)), b = r.nextInt(5) == 0 ? rootId : id(r.nextInt(n));
  final author = ['kim', 'sam', 'ana'][r.nextInt(3)];
  final key = FractionalKeys.digits[1 + r.nextInt(61)];
  return switch (r.nextInt(7)) {
    0 || 1 => ins(b, a, key: key, kind: r.nextInt(4) == 0 ? 'leaf' : 'folder', author: author),
    2 => mv(a, b, key: key, author: author),
    3 => set(a, ['name', 'gain', 'extra'][r.nextInt(3)], r.nextInt(3), author: author),
    4 => del(a),
    5 => rev(a),
    _ => TextOp(node: a, field: 'source', value: 'x${r.nextInt(9)}', lockEpoch: 0, author: author, clientSeq: ++_cs, baseSeq: 0),
  };
}

bool tryApply(CollabTree t, Op op) {
  try {
    t.apply(op);
    return true;
  } on OpRejected {
    return false;
  }
}

void main() {
  test('the coarse project schema takes tracks of whole JSON and has a stable hash', () {
    final t = CollabTree(coarseProjectSchema);
    t.apply(SetOp(node: rootId, field: 'json', value: {'tempo': 120}, author: 'kim', clientSeq: 1, baseSeq: 0));
    t.apply(InsertOp(parent: rootId, list: 'tracks', node: 'l00000001', key: 'V', kind: 'track', fields: {'json': {'name': 'Bass', 'chain': []}}, author: 'kim', clientSeq: 2, baseSeq: 0));
    expect(t.children(rootId, 'tracks'), ['l00000001']);
    expect(() => t.apply(InsertOp(parent: 'l00000001', list: 'tracks', node: 'l00000002', key: 'V', kind: 'track', author: 'kim', clientSeq: 3, baseSeq: 0)), rejected(OpRejected.schema));
    expect(coarseProjectSchema.hash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(coarseProjectSchema.hash, Schema(version: 1, rootKind: 'project', kinds: [...coarseProjectSchema.kinds.values]).hash);
    expect(coarseProjectSchema.hash, isNot(Schema(version: 2, rootKind: 'project', kinds: [...coarseProjectSchema.kinds.values]).hash));
    expect(coarseProjectSchema.hash, isNot(folders.hash));
  });

  test('the schema checks kinds, lists and known fields, and keeps unknown fields', () {
    final t = CollabTree(folders);
    t.apply(ins(rootId, id(1), fields: {'name': 'Drums', 'future': {'x': 1}}));
    expect(t.node(id(1))!.fields['future'], {'x': 1});
    expect(() => t.apply(ins(rootId, id(2), kind: 'track')), rejected(OpRejected.schema));
    expect(() => t.apply(ins(rootId, id(2), list: 'tracks')), rejected(OpRejected.schema));
    expect(() => t.apply(ins(id(1), id(2), kind: 'leaf', fields: {'on': 'yes'})), rejected(OpRejected.schema));
    expect(() => t.apply(set(id(1), 'gain', 3)), rejected(OpRejected.schema));
    expect(() => t.apply(set(id(1), 'name', 7)), rejected(OpRejected.schema));
    t.apply(set(id(1), 'gain', 1.5));
    t.apply(set(id(1), 'another', [1, 2]));
    expect(t.node(id(1))!.fields, {'name': 'Drums', 'future': {'x': 1}, 'gain': 1.5, 'another': [1, 2]});
    t.apply(set(id(1), 'another', null));
    expect(t.node(id(1))!.fields.containsKey('another'), isFalse);
    expect(() => t.apply(TextOp(node: id(1), field: 'name', value: 'x', lockEpoch: 0, author: 'kim', clientSeq: 1, baseSeq: 0)), rejected(OpRejected.schema));
    expect(() => t.apply(ins(rootId, id(1))), rejected(OpRejected.duplicateNode));
    expect(() => t.apply(set(id(9), 'name', 'x')), rejected(OpRejected.unknownNode));
    expect(() => t.apply(ins(rootId, 'not an id')), rejected(OpRejected.invalid));
  });

  test('a text field is written only by text ops; a set may only clear it', () {
    final t = CollabTree(folders);
    t.apply(ins(rootId, id(1), fields: {'source': 'note c4'}));
    expect(() => t.apply(set(id(1), 'source', 'note d4')), rejected(OpRejected.schema));
    expect(t.node(id(1))!.fields['source'], 'note c4');
    t.apply(TextOp(node: id(1), field: 'source', value: 'note e4', lockEpoch: 3, author: 'kim', clientSeq: 1, baseSeq: 0));
    expect(t.node(id(1))!.fields['source'], 'note e4');
    t.apply(set(id(1), 'source', null));
    expect(t.node(id(1))!.fields.containsKey('source'), isFalse);
  });

  test('nodes handed out are read-only', () {
    final t = CollabTree(folders);
    t.apply(ins(rootId, id(1), fields: {'name': 'Bass'}));
    final n = t.node(id(1))!;
    expect(() => n.fields['name'] = 'x', throwsUnsupportedError);
    expect(() => n.fields.remove('name'), throwsUnsupportedError);
    expect(() => n.fields.clear(), throwsUnsupportedError);
    // parent, list, key and deleted are getters only; this would not compile:  n.parent = id(1);
    expect(() => (n as dynamic).parent = id(1), throwsNoSuchMethodError);
    expect(() => (n as dynamic).deleted = true, throwsNoSuchMethodError);
    expect(t.node(id(1))!.fields, {'name': 'Bass'});
    expect(t.node(id(1))!.parent, rootId);
    checkInvariants(t, [id(1)]);
  });

  test('stored values are frozen copies', () {
    final t = CollabTree(folders);
    final v = <String, Object?>{'a': [1]};
    t.apply(ins(rootId, id(1)));
    t.apply(set(id(1), 'x', v));
    (v['a'] as List).add(2);
    expect(t.node(id(1))!.fields['x'], {'a': [1]});
    expect(() => (t.node(id(1))!.fields['x'] as Map)['b'] = 1, throwsUnsupportedError);
  });

  test('a delete tombstones the subtree; ops on it are refused; a revive restores it as it was', () {
    final t = CollabTree(folders);
    t.apply(ins(rootId, id(1), fields: {'name': 'Bass'}));
    t.apply(ins(id(1), id(2), fields: {'name': 'Inner'}));
    t.apply(ins(id(2), id(3), kind: 'leaf'));
    t.apply(ins(id(2), id(4), kind: 'leaf', key: 'W'));
    t.apply(ins(rootId, id(5), key: 'W'));
    t.apply(del(id(4)));
    final before = t.visibleView();
    t.apply(del(id(1)));
    expect(t.children(rootId, 'items'), [id(5)]);
    expect(t.children(rootId, 'items', includeDeleted: true), [id(1), id(5)]);
    for (final i in [1, 2, 3, 4]) {
      expect(t.isVisible(id(i)), isFalse);
      expect(t.node(id(i)), isNotNull, reason: 'kept until compaction');
    }
    expect(() => t.apply(set(id(3), 'on', true)), rejected(OpRejected.targetDeleted));
    expect(() => t.apply(ins(id(2), id(6))), rejected(OpRejected.targetDeleted));
    expect(() => t.apply(mv(id(5), id(2))), rejected(OpRejected.targetDeleted));
    expect(() => t.apply(mv(id(3), rootId)), rejected(OpRejected.targetDeleted));
    expect(() => t.apply(del(id(1))), rejected(OpRejected.targetDeleted));
    expect(() => t.apply(rev(id(2))), rejected(OpRejected.notDeleted));
    expect(() => t.apply(rev(id(4))), rejected(OpRejected.targetDeleted), reason: 'its ancestor is still deleted');
    expect(() => t.apply(ins(rootId, id(3))), rejected(OpRejected.duplicateNode), reason: 'a tombstoned id stays taken');
    t.apply(rev(id(1)));
    expect(t.visibleView(), before);
    expect(t.isVisible(id(4)), isFalse, reason: 'a node deleted on its own stays deleted');
    expect(() => t.apply(del(rootId)), rejected(OpRejected.root));
    expect(() => t.apply(mv(rootId, id(1))), rejected(OpRejected.root));
  });

  test('a move into its own subtree is refused', () {
    final t = CollabTree(folders);
    t.apply(ins(rootId, id(1)));
    t.apply(ins(id(1), id(2)));
    t.apply(ins(id(2), id(3)));
    expect(() => t.apply(mv(id(1), id(1))), rejected(OpRejected.cycle));
    expect(() => t.apply(mv(id(1), id(3))), rejected(OpRejected.cycle));
    t.apply(mv(id(3), rootId));
    t.apply(mv(id(1), id(3)));
    expect(t.children(id(3), 'items'), [id(1)]);
    checkInvariants(t, [id(1), id(2), id(3)]);
  });

  test('random op storms never make a cycle, break the index or pass the limits', () {
    const limits = TreeLimits(maxNodes: 40, maxDepth: 6);
    for (var seed = 0; seed < 40; seed++) {
      final r = Random(seed);
      final t = CollabTree(folders, limits: limits);
      for (var i = 0; i < 1500; i++) {
        tryApply(t, randomOp(r, 60));
      }
      expect(t.nodeCount, lessThanOrEqualTo(40));
      checkInvariants(t, [for (var i = 0; i < 60; i++) id(i)]);
    }
  });

  test('depth and node limits refuse inserts and moves', () {
    final t = CollabTree(folders, limits: const TreeLimits(maxNodes: 6, maxDepth: 3));
    t.apply(ins(rootId, id(1)));
    t.apply(ins(id(1), id(2)));
    t.apply(ins(id(2), id(3)));
    expect(() => t.apply(ins(id(3), id(4))), rejected(OpRejected.limit));
    t.apply(ins(rootId, id(4), key: 'W'));
    t.apply(ins(id(4), id(5)));
    expect(() => t.apply(mv(id(4), id(2))), rejected(OpRejected.limit), reason: 'its child would sit at depth 4');
    expect(() => t.apply(ins(rootId, id(6), key: 'X')), rejected(OpRejected.limit), reason: 'the root and 5 nodes fill 6');
  });

  test('applying an inverse undoes the op', () {
    final r = Random(9);
    var checked = 0;
    for (var seed = 0; seed < 20; seed++) {
      final t = CollabTree(folders);
      for (var i = 0; i < 400; i++) {
        final op = randomOp(r, 30);
        final snap = t.snapshot(), view = t.visibleView();
        Op? inverse;
        try {
          inverse = t.apply(op);
        } on OpRejected {
          expect(t.snapshot(), snap, reason: 'a refused op changes nothing');
          continue;
        }
        if (inverse == null || r.nextBool()) continue;
        t.apply(inverse);
        if (op is InsertOp) {
          expect(t.visibleView(), view, reason: 'an undone insert is a tombstone');
        } else {
          expect(t.snapshot(), snap, reason: '$op');
        }
        checked++;
      }
    }
    expect(checked, greaterThan(500));
  });

  test('replicas applying the same host order hold the same tree', () {
    for (var seed = 0; seed < 20; seed++) {
      final r = Random(100 + seed);
      final ops = [for (var i = 0; i < 800; i++) randomOp(r, 40)];
      final a = CollabTree(folders), b = CollabTree(folders);
      for (final op in ops) {
        expect(tryApply(a, op), tryApply(b, decodeOpBinary(encodeOpBinary(op))));
      }
      expect(a.snapshot(), b.snapshot());
    }
  });

  test('independent ops (different nodes or fields, distinct inserts) converge in any order', () {
    final r = Random(12);
    for (var round = 0; round < 50; round++) {
      final base = <Op>[for (var i = 0; i < 6; i++) ins(rootId, id(i), key: FractionalKeys.digits[1 + i])];
      final concurrent = <Op>[
        set(id(0), 'name', 'Kim', author: 'kim'),
        set(id(0), 'gain', 0.5, author: 'sam'),
        set(id(1), 'name', 'Sam', author: 'sam'),
        ins(id(2), id(10), key: 'V', author: 'kim'),
        ins(id(2), id(11), key: 'V', author: 'sam'), // the same key: both kept
        ins(id(2), id(12), key: 'W', author: 'ana'),
        mv(id(3), id(4), author: 'ana'),
        del(id(5)),
        TextOp(node: id(1), field: 'source', value: 'note c4', lockEpoch: 1, author: 'ana', clientSeq: 1, baseSeq: 0),
      ];
      Map<String, Object?>? first;
      for (var p = 0; p < 6; p++) {
        final t = CollabTree(folders);
        base.forEach(t.apply);
        for (final op in [...concurrent]..shuffle(r)) {
          t.apply(op);
        }
        expect(t.children(id(2), 'items'), [id(10), id(11), id(12)]);
        first ??= t.snapshot();
        expect(t.snapshot(), first);
      }
    }
  });

  test('a delete and a concurrent edit of the deleted subtree converge on what readers see', () {
    for (final deleteFirst in [true, false]) {
      final t = CollabTree(folders);
      t.apply(ins(rootId, id(1)));
      t.apply(ins(id(1), id(2), kind: 'leaf'));
      t.apply(ins(rootId, id(3), key: 'W'));
      final edits = [set(id(2), 'on', true), ins(id(1), id(4), kind: 'leaf'), mv(id(3), id(1))];
      if (deleteFirst) t.apply(del(id(1)));
      for (final e in edits) {
        tryApply(t, e);
      }
      if (!deleteFirst) t.apply(del(id(1)));
      // Readers see the same: the deleted folder is gone; the moved folder went with it only if it got there first.
      expect(t.children(rootId, 'items'), deleteFirst ? [id(3)] : <String>[]);
      expect(t.isVisible(id(2)), isFalse);
    }
  });

  test('crossing moves (A into B, B into A) never make a cycle, in either order', () {
    for (final aFirst in [true, false]) {
      final t = CollabTree(folders);
      t.apply(ins(rootId, id(1)));
      t.apply(ins(rootId, id(2), key: 'W'));
      final a = mv(id(1), id(2), author: 'kim'), b = mv(id(2), id(1), author: 'sam');
      final first = aFirst ? a : b, second = aFirst ? b : a;
      t.apply(first);
      expect(() => t.apply(second), rejected(OpRejected.cycle));
      checkInvariants(t, [id(1), id(2)]);
      expect(t.children(rootId, 'items'), [aFirst ? id(2) : id(1)]);
    }
  });

  test('the same field set concurrently: the later op in host order wins on every replica', () {
    final ops = [ins(rootId, id(1)), set(id(1), 'name', 'Kim', author: 'kim'), set(id(1), 'name', 'Sam', author: 'sam')];
    final a = CollabTree(folders), b = CollabTree(folders);
    ops.forEach(a.apply);
    ops.forEach(b.apply);
    expect(a.node(id(1))!.fields['name'], 'Sam');
    expect(a.snapshot(), b.snapshot());
  });

  test('the host tie-break makes concurrent keys unique', () {
    final t = CollabTree(folders);
    t.apply(ins(rootId, id(1), key: 'V'));
    expect(t.resolveKey(rootId, 'items', 'W', 'sam'), 'W');
    final k = t.resolveKey(rootId, 'items', 'V', 'sam');
    expect(k, 'Vsam');
    t.apply(ins(rootId, id(2), key: k, author: 'sam'));
    expect(t.children(rootId, 'items'), [id(1), id(2)]);
    final k2 = t.resolveKey(rootId, 'items', 'V', 'sam');
    expect(k2, 'Vsamsam');
    expect(FractionalKeys.isValid(k2), isTrue);
  });

  test('blobs are immutable by hash', () {
    const h = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
    BlobOp blob(int size) => BlobOp(hash: h, size: size, format: 'wav', channels: 2, rate: 48000, frames: 10, author: 'kim', clientSeq: 1, baseSeq: 0);
    final t = CollabTree(folders);
    expect(t.apply(blob(100)), isNull);
    t.apply(blob(100));
    expect(() => t.apply(blob(101)), rejected(OpRejected.blobConflict));
    expect(t.blobs.keys, [h]);
  });
}
