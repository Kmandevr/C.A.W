// caw_collab's host pipeline: ack and broadcast, dedupe by (device, clientSeq), the size, rate, schema, cycle and
// permission checks, the key tie-break, snapshots, resume by replay or snapshot plus tail, a crash at each step
// with recovery from the log, a torn log tail, blobs, epochs and fencing for host migration, and the cache purge.
import 'dart:typed_data';

import 'package:caw_collab/caw_collab.dart';
import 'package:caw_services/sha256.dart';
import 'package:flutter_test/flutter_test.dart';

import 'collab_host_fixture.dart';

InsertOp track(TestMember m, int i, {String key = 'V', String parent = rootId, String list = 'tracks'}) =>
    InsertOp(parent: parent, list: list, node: nid(i), key: key, kind: 'track', fields: {'name': 'T$i'}, author: m.id, clientSeq: m.nextCs(), baseSeq: m.applied);
InsertOp clip(TestMember m, int i, String parent) =>
    InsertOp(parent: parent, list: 'items', node: nid(i, 'c'), key: 'V', kind: 'clip', fields: {'json': {'n': i}}, author: m.id, clientSeq: m.nextCs(), baseSeq: m.applied);
SetOp setOp(TestMember m, String node, String field, Object? v) =>
    SetOp(node: node, field: field, value: v, author: m.id, clientSeq: m.nextCs(), baseSeq: m.applied);

Future<(HostRig, TestMember, TestMember)> twoMembers({HostSettings settings = const HostSettings(), SessionConfig? cfg}) async {
  final rig = HostRig(settings: settings, cfg: cfg);
  final o = TestMember(rig.net, owner)..join();
  final k = TestMember(rig.net, 'kim')..join();
  await rig.net.settle();
  return (rig, o, k);
}

Future<void> heal(HostRig rig, List<TestMember> ms) async {
  for (var round = 0; round < 6; round++) {
    rig.clock.now += 15000;
    for (final m in ms) {
      m.resync();
    }
    await rig.net.settle();
  }
}

void main() {
  useTestFloor();
  test('an op is acked to its author with a seq and broadcast to the others, who converge', () async {
    final (rig, o, k) = await twoMembers();
    o.submit([track(o, 1), setOp(o, nid(1), 'gain', 1.5)]);
    await rig.net.settle();
    expect(o.acked.values, [1, 2]);
    expect(rig.host.seq, 2);
    expect(rig.host.tail.map((x) => x.time), everyElement(rig.clock.now));
    expect(k.applied, 2);
    expect(o.snapshotText, hostText(rig.host));
    expect(k.snapshotText, hostText(rig.host));
    expect(rig.storage.wal.syncs, greaterThan(0));
  });

  test('a resend with the same clientSeq gets the same answer and changes nothing', () async {
    final (rig, o, _) = await twoMembers();
    final op = track(o, 1);
    final bad = setOp(o, nid(9), 'name', 'x');
    o.submit([op, bad]);
    await rig.net.settle();
    final seqBefore = rig.host.seq;
    final out = RecordingOutbox();
    final h = rig.host;
    // Answer through a recording outbox to see the replies exactly.
    final rig2 = HostCore.recover(schema: hostSchema, storage: rig.storage, outbox: out, clock: rig.clock.call, passwordCheck: inlineCheck);
    rig2.connect('x', address: 'a');
    await rig2.receive('x', Hello(epoch: 1, member: owner, version: goodVersion(), token: ownerToken, lastSeq: seqBefore));
    await rig2.receive('x', Submit(epoch: 1, ops: [op, op]));
    expect(out.of('x').whereType<Ack>().map((a) => a.seq), [1, 1]);
    expect(rig2.seq, seqBefore);
    expect(h.seq, seqBefore);
    // Out of order within the memory window: both are new, both are taken.
    final a = track(o, 2), b = track(o, 3);
    await rig2.receive('x', Submit(epoch: 1, ops: [b, a]));
    expect(out.of('x').whereType<Ack>().map((x) => x.clientSeq).skip(2), [b.clientSeq, a.clientSeq]);
    expect(rig2.seq, seqBefore + 2);
  });

  test('a rejected op answers the same rejection on a resend; another author\'s op is refused', () async {
    final (rig, o, k) = await twoMembers();
    final bad = setOp(o, nid(9), 'name', 'x');
    o.submit([bad]);
    await rig.net.settle();
    expect(o.rejected[bad.clientSeq], OpRejected.unknownNode);
    o.pending[bad.clientSeq] = bad;
    o.resync();
    await rig.net.settle();
    expect(o.rejected[bad.clientSeq], OpRejected.unknownNode);
    final forged = SetOp(node: rootId, field: 'json', value: 1, author: owner, clientSeq: 99, baseSeq: 0);
    k.submit([forged]);
    await rig.net.settle();
    expect(k.rejected[99], HostReject.wrongAuthor);
  });

  group('permissions', () {
    test('a viewer can change nothing; a worker edits only inside its assigned scope', () async {
      final secret = 'viewer-secret-0001';
      final (rig, o, k) = await twoMembers(cfg: config(invites: {inviteSecretHash(secret): Role.viewer}));
      final v = TestMember(rig.net, 'vic', invite: secret)..join();
      await rig.net.settle();
      o.submit([track(o, 1), track(o, 2, key: 'W')]);
      await rig.net.settle();
      final vs = setOp(v, nid(1), 'name', 'mine');
      v.submit([vs]);
      // Make kim a worker assigned to track 1.
      o.submit([AccessOp(member: 'kim', grants: [...Role.worker.grants, Grant(Capability.editContent, nid(1)), Grant(Capability.editCode, nid(1))], author: owner, clientSeq: o.nextCs(), baseSeq: 0)]);
      await rig.net.settle();
      expect(v.rejected[vs.clientSeq], HostReject.permission);
      final inScope = setOp(k, nid(1), 'name', 'Bass');
      final clipIn = clip(k, 1, nid(1));
      final outScope = setOp(k, nid(2), 'name', 'Drums');
      final newTrack = track(k, 3);
      final code = TextOp(node: nid(2), field: 'source', value: 'x', lockEpoch: 0, author: 'kim', clientSeq: k.nextCs(), baseSeq: 0);
      final settings = setOp(k, rootId, 'json', {'tempo': 90});
      final grant = AccessOp(member: 'kim', grants: Role.owner.grants, author: 'kim', clientSeq: k.nextCs(), baseSeq: 0);
      k.submit([inScope, clipIn, outScope, newTrack, code, settings, grant]);
      await rig.net.settle();
      // The clip's own scope has no grant: the walk finds track 1's.
      final c2 = setOp(k, nid(1, 'c'), 'json', {'n': 2});
      k.submit([c2]);
      await rig.net.settle();
      expect(k.acked.keys, containsAll([inScope.clientSeq, clipIn.clientSeq, c2.clientSeq]));
      for (final x in [outScope, newTrack, code, settings, grant]) {
        expect(k.rejected[x.clientSeq], HostReject.permission, reason: x.toString());
      }
      expect(rig.host.tree.node(nid(1))!.fields['name'], 'Bass');
    });

    test('a move needs the capability at both ends; only the owner changes the owner\'s access', () async {
      final (rig, o, k) = await twoMembers();
      o.submit([track(o, 1), track(o, 2, key: 'W'), clip(o, 5, nid(1))]);
      o.submit([AccessOp(member: 'kim', grants: [...Role.worker.grants, Grant(Capability.editContent, nid(1)), Grant(Capability.manageAccess, rootId)], author: owner, clientSeq: o.nextCs(), baseSeq: 0)]);
      await rig.net.settle();
      final mv = MoveOp(node: nid(5, 'c'), parent: nid(2), list: 'items', key: 'V', author: 'kim', clientSeq: k.nextCs(), baseSeq: 0);
      final demote = AccessOp(member: owner, grants: Role.viewer.grants, author: 'kim', clientSeq: k.nextCs(), baseSeq: 0);
      final other = AccessOp(member: 'sam', grants: Role.viewer.grants, author: 'kim', clientSeq: k.nextCs(), baseSeq: 0);
      k.submit([mv, demote, other]);
      await rig.net.settle();
      expect(k.rejected[mv.clientSeq], HostReject.permission);
      expect(k.rejected[demote.clientSeq], HostReject.permission);
      expect(k.acked.keys, contains(other.clientSeq));
      expect(rig.host.permissions.grantsOf('sam').map((g) => g.capability), [Capability.view]);
    });
  });

  test('size, rate, schema, cycle, deleted-target and unsupported ops are refused with their reasons', () async {
    final (rig, o, _) = await twoMembers(settings: const HostSettings(opBurst: 7, opsPerSecond: 1, limits: CollabLimits(maxOpBytes: 200)));
    o.submit([track(o, 1), track(o, 2, parent: nid(1), list: 'items')]);
    await rig.net.settle();
    final big = setOp(o, nid(1), 'name', 'x' * 300);
    final range = setOp(o, nid(1), 'gain', 5);
    final cycle = MoveOp(node: nid(1), parent: nid(2), list: 'items', key: 'V', author: owner, clientSeq: o.nextCs(), baseSeq: 0);
    final del = DeleteOp(node: nid(2), author: owner, clientSeq: o.nextCs(), baseSeq: 0);
    final onDeleted = setOp(o, nid(2), 'name', 'gone');
    final restore = RestoreOp(checkpointSeq: 1, author: owner, clientSeq: o.nextCs(), baseSeq: 0);
    o.submit([big, range, cycle, del, onDeleted, restore]);
    await rig.net.settle();
    expect(o.rejected[big.clientSeq], HostReject.limit);
    expect(o.rejected[range.clientSeq], OpRejected.schema);
    expect(o.rejected[cycle.clientSeq], OpRejected.cycle);
    expect(o.acked.keys, contains(del.clientSeq));
    expect(o.rejected[onDeleted.clientSeq], OpRejected.targetDeleted);
    expect(o.rejected[restore.clientSeq], HostReject.unsupported);
    // 7 tokens are spent (2 + 5: the oversized op is refused before the bucket); the next waits for the bucket to refill.
    final late = setOp(o, nid(1), 'name', 'later');
    final h = rig.host;
    o.submit([late]);
    await rig.net.settle();
    expect(o.pending.keys, contains(late.clientSeq), reason: 'rate-limited ops stay pending');
    rig.clock.now += 2000;
    o.resync();
    await rig.net.settle();
    expect(o.acked.keys, contains(late.clientSeq));
    expect(h.tree.node(nid(1))!.fields['name'], 'later');
  });

  test('two inserts at one key keep both, the second with the author\'s suffix', () async {
    final (rig, o, k) = await twoMembers();
    final a = track(o, 1), b = InsertOp(parent: rootId, list: 'tracks', node: nid(2), key: 'V', kind: 'track', author: 'kim', clientSeq: k.nextCs(), baseSeq: 0);
    o.submit([a]);
    k.submit([b]);
    await rig.net.settle();
    expect(rig.host.tree.node(nid(2))!.key, 'V${AuthorIds.short('kim')}');
    expect(k.snapshotText, hostText(rig.host));
    expect(o.snapshotText, hostText(rig.host));
  });

  test('snapshots come every N ops and after a quiet interval, and replace the log', () async {
    final (rig, o, _) = await twoMembers(settings: const HostSettings(snapshotEveryOps: 5, snapshotEveryMs: 60000));
    for (var i = 0; i < 12; i++) {
      o.submit([track(o, i, key: FractionalKeys.digits[10 + i])]);
    }
    await rig.net.settle();
    expect(rig.host.snapshotSeq, 10);
    expect(rig.host.tail.map((x) => x.seq), [11, 12]);
    expect(rig.storage.wal.recover().length, 2);
    rig.clock.now += 30000;
    rig.host.tick();
    expect(rig.host.snapshotSeq, 10);
    rig.clock.now += 30000;
    rig.host.tick();
    expect(rig.host.snapshotSeq, 12);
    expect(rig.storage.wal.recover(), isEmpty);
    rig.recover();
    expect(hostText(rig.host), o.snapshotText);
  });

  test('resume replays the tail when the snapshot covers the gap, and sends snapshot plus tail when not', () async {
    final (rig, o, k) = await twoMembers(settings: const HostSettings(snapshotEveryOps: 4));
    o.submit([track(o, 1)]);
    await rig.net.settle();
    rig.net.hangUp(k.conn!);
    o.submit([track(o, 2, key: 'W')]);
    await rig.net.settle();
    final out = RecordingOutbox();
    // A near resume: kim is at 1, the snapshot is at 0, so the tail alone covers it.
    final h = HostCore.recover(schema: hostSchema, storage: rig.storage, outbox: out, clock: rig.clock.call, passwordCheck: inlineCheck);
    h.connect('k', address: 'a');
    await h.receive('k', Hello(epoch: 1, member: 'kim', version: goodVersion(), token: k.token, lastSeq: 1));
    final near = out.of('k').whereType<Catchup>().single;
    expect(near.snapshot, isNull);
    expect(near.ops.map((x) => x.seq), [2]);
    // Four more ops make a snapshot at 4; a resume from 1 now needs it.
    o.net = rig.net;
    for (var i = 3; i < 7; i++) {
      o.submit([track(o, i, key: 'X$i')]);
    }
    await rig.net.settle();
    expect(rig.host.snapshotSeq, 4);
    k.join();
    await rig.net.settle();
    expect(k.applied, 6);
    expect(k.snapshotText, hostText(rig.host));
    final h2 = HostCore.recover(schema: hostSchema, storage: rig.storage, outbox: out, clock: rig.clock.call, passwordCheck: inlineCheck);
    h2.connect('k2', address: 'a');
    await h2.receive('k2', Hello(epoch: 1, member: 'kim', version: goodVersion(), token: k.token, lastSeq: 1));
    final far = out.of('k2').whereType<Catchup>().single;
    expect(far.snapshotSeq, 4);
    expect(far.ops.map((x) => x.seq), [5, 6]);
  });

  group('a crash at each step recovers from the log', () {
    for (final step in PipelineStep.values) {
      test(step.name, () async {
        final rig = HostRig(settings: const HostSettings(snapshotEveryOps: 3));
        final o = TestMember(rig.net, owner)..join();
        final k = TestMember(rig.net, 'kim')..join();
        await rig.net.settle();
        o.submit([track(o, 1), track(o, 2, key: 'W')]);
        await rig.net.settle();
        var armed = true;
        rig.faultHook = (s) {
          if (armed && s == step) {
            armed = false;
            throw SimulatedCrash(s);
          }
        };
        final batch = [track(o, 3, key: 'X'), setOp(o, nid(1), 'gain', 0.5)];
        o.submit(batch);
        await rig.net.settle();
        expect(rig.crashed, isTrue, reason: 'the hook fired');
        rig.faultHook = null;
        rig.recover(tornBytes: 7);
        await heal(rig, [o, k]);
        expect(o.pending, isEmpty);
        // Each op is confirmed exactly once, at one seq, whatever the step.
        final seqs = [for (final b in batch) o.acked[b.clientSeq]];
        expect(seqs.toSet().length, 2);
        expect(rig.host.seq, 4);
        expect(o.snapshotText, hostText(rig.host));
        expect(k.snapshotText, hostText(rig.host));
        expect(rig.host.tree.node(nid(1))!.fields['gain'], 0.5);
      });
    }
  });

  test('a torn log tail is cut at recovery, and the unacked ops are taken again on resend', () async {
    final (rig, o, _) = await twoMembers();
    o.submit([track(o, 1)]);
    await rig.net.settle();
    rig.faultHook = (s) {
      if (s == PipelineStep.appended) throw SimulatedCrash(s);
    };
    o.submit([track(o, 2, key: 'W'), track(o, 3, key: 'X')]);
    await rig.net.settle();
    expect(rig.storage.wal.pendingBytes, greaterThan(20));
    rig.faultHook = null;
    rig.recover(tornBytes: 20);
    expect(rig.host.seq, 1);
    await heal(rig, [o]);
    expect(rig.host.seq, 3);
    expect(o.snapshotText, hostText(rig.host));
  });

  test('blobs must be declared, match their size and hash, and are served to members', () async {
    final (rig, o, k) = await twoMembers(settings: const HostSettings(maxBlobBytes: 64));
    final bytes = Uint8List.fromList(List.generate(40, (i) => i));
    final hash = sha256Hex(bytes);
    expect(rig.host.putBlob(o.conn!, hash, bytes), 'undeclared');
    o.submit([BlobOp(hash: hash, size: 40, format: 'wav', author: owner, clientSeq: o.nextCs(), baseSeq: 0)]);
    await rig.net.settle();
    expect(rig.host.putBlob(o.conn!, hash, Uint8List(40)), BlobRefused.hashMismatch);
    expect(rig.host.putBlob(o.conn!, hash, Uint8List(39)), BlobRefused.hashMismatch);
    expect(rig.host.putBlob(o.conn!, hash, bytes), isNull);
    expect(rig.host.getBlob(k.conn!, hash), bytes);
    expect(rig.host.getBlob('nobody', hash), isNull);
  });

  group('epochs and migration', () {
    test('successors are ranked by score, and only they get the session state', () async {
      final rig = HostRig(cfg: config(hostMember: owner));
      final o = TestMember(rig.net, owner, score: 100)..join();
      final k = TestMember(rig.net, 'kim', score: 5)..join();
      final s = TestMember(rig.net, 'sam', score: 9)..join();
      final a = TestMember(rig.net, 'ana', score: 5)..join();
      await rig.net.settle();
      expect(s.successors.map((x) => x.member), ['sam', 'ana', 'kim'], reason: 'the hosting device is not its own successor');
      expect(s.state, isNotNull);
      expect(o.state, isNull);
      expect(a.state!.grants.keys, containsAll([owner, 'kim', 'sam', 'ana']));
      expect(k.state!.epoch, 1);
    });

    test('migration off lists nobody; managers-only lists only managers', () async {
      for (final (settings, want) in [
        (const HostSettings(migration: false), <String>[]),
        (const HostSettings(whoMayHost: HostEligibility.managers), [owner]),
        (const HostSettings(whoMayHost: HostEligibility.editors), ['kim', owner]),
      ]) {
        final rig = HostRig(settings: settings);
        final o = TestMember(rig.net, owner)..join();
        TestMember(rig.net, 'kim').join();
        await rig.net.settle();
        expect(o.successors.map((x) => x.member).toList()..sort(), want);
      }
    });

    test('a successor continues from its replica in the next epoch; the old host is fenced off', () async {
      final rig = HostRig();
      final o = TestMember(rig.net, owner)..join();
      final k = TestMember(rig.net, 'kim', score: 1)..join();
      final s = TestMember(rig.net, 'sam', score: 9)..join();
      await rig.net.settle();
      o.submit([track(o, 1), track(o, 2, key: 'W')]);
      await rig.net.settle();
      expect(s.successors.map((x) => x.member), [owner, 'sam', 'kim'], reason: 'the owner ranks first, then by score');
      // The host drops. Sam continues from its replica at its last confirmed seq.
      rig.net.dropAll('host gone');
      final net2 = MemoryNetwork(seed: 2);
      final store2 = MemoryHostStorage();
      final clock = FakeClock();
      final h2 = HostCore.continueSession(
          state: s.state!, schema: hostSchema, replica: s.tree, seq: s.applied, storage: store2, outbox: net2,
          hostApp: '1.1.7', hostMember: 'sam', clock: clock.call, passwordCheck: inlineCheck);
      net2.attach(h2);
      expect(h2.epoch, 2);
      expect(h2.seq, 2);
      for (final m in [o, k]) {
        m.net = net2;
        m.join();
      }
      await net2.settle();
      expect(o.epoch, 2);
      expect(k.snapshotText, hostText(h2));
      // A message from the old epoch is refused at the new host.
      final stale = setOp(k, nid(1), 'name', 'old');
      net2.post(k.conn!, Submit(epoch: 1, ops: [stale]));
      await net2.settle();
      expect(h2.tree.node(nid(1))!.fields['name'], 'T1');
      // New-epoch edits are taken.
      k.submit([setOp(k, nid(1), 'name', 'new')]);
      await net2.settle();
      expect(h2.tree.node(nid(1))!.fields['name'], 'new');
      // The old host is still running. A claim of epoch 2 alone only ends that connection.
      expect(rig.host.state, HostState.running);
      final late = TestMember(rig.net, 'kim', token: k.token)..epoch = 2;
      late.join();
      await rig.net.settle();
      expect(late.refusals, [Refused.epochAhead]);
      expect(rig.host.state, HostState.running);
      // A forged proof is refused; the new host's proof, which members got in its welcome, fences the old host.
      expect(o.fence, isNotNull);
      for (final (proof, want) in [('0' * 64, HostState.running), (o.fence!, HostState.fenced)]) {
        final c = rig.net.open(late);
        rig.net.post(c, FenceNotice(epoch: 2, proof: proof));
        await rig.net.settle();
        expect(rig.host.state, want);
      }
      expect(late.refusals, [Refused.epochAhead, Refused.invalid, Refused.staleHost]);
      final old = TestMember(rig.net, 'ana')..join();
      await rig.net.settle();
      expect(old.refusals, [Refused.staleHost]);
      rig.recover();
      expect(rig.host.state, HostState.fenced);
    });

    test('a member past where the new epoch began gets a fresh snapshot, and resends of ops the successor holds are deduped', () async {
      final rig = HostRig();
      final o = TestMember(rig.net, owner)..join();
      final s = TestMember(rig.net, 'sam', score: 9)..join();
      await rig.net.settle();
      final first = track(o, 1);
      o.submit([first]);
      await rig.net.settle();
      final state = s.state!;
      final replica = CollabTree.fromSnapshot(hostSchema, s.tree.snapshot());
      final at = s.applied;
      // One more op reaches the owner but not sam before the host drops.
      o.submit([track(o, 2, key: 'W')]);
      await rig.net.deliver();
      await rig.net.deliver();
      expect(o.applied, 2);
      rig.net.dropAll('gone');
      final net2 = MemoryNetwork(seed: 3);
      final h2 = HostCore.continueSession(
          state: state, schema: hostSchema, replica: replica, seq: at, storage: MemoryHostStorage(), outbox: net2,
          hostApp: appVersion, recentOps: s.confirmed, passwordCheck: inlineCheck);
      net2.attach(h2);
      o.net = net2;
      o.join();
      await net2.settle();
      expect(o.applied, 1, reason: 'reset to the new host\'s snapshot');
      expect(o.snapshotText, hostText(h2));
      // The owner's first op, resent, is answered from the successor's own log, not ordered again.
      final out = RecordingOutbox();
      final h3 = HostCore.continueSession(
          state: state, schema: hostSchema, replica: replica, seq: at, storage: MemoryHostStorage(), outbox: out,
          hostApp: appVersion, recentOps: s.confirmed, passwordCheck: inlineCheck);
      h3.connect('o', address: 'a');
      await h3.receive('o', Hello(epoch: 1, member: owner, version: goodVersion(), token: ownerToken, lastSeq: 1));
      await h3.receive('o', Submit(epoch: 2, ops: [first]));
      expect(out.of('o').whereType<Ack>().single.seq, 1);
      expect(h3.seq, 1);
    });
  });

  group('the session cache', () {
    test('an ended session refuses joins, reopens within the window and is purged after it', () async {
      final (rig, o, k) = await twoMembers(settings: const HostSettings(resumeWindowMs: 1000));
      o.submit([track(o, 1)]);
      await rig.net.settle();
      rig.host.end();
      await rig.net.settle();
      expect(k.closes, [Refused.sessionEnded]);
      final late = TestMember(rig.net, 'ana')..join();
      await rig.net.settle();
      expect(late.refusals, [Refused.sessionEnded]);
      rig.recover();
      expect(rig.host.state, HostState.ended);
      rig.host.reopen();
      k.join();
      await rig.net.settle();
      expect(k.joined, isTrue);
      rig.host.end();
      rig.clock.now += 999;
      expect(rig.host.tick(), isFalse);
      rig.clock.now += 1;
      expect(rig.host.tick(), isTrue);
      expect(rig.host.state, HostState.purged);
      expect(rig.storage.isEmpty, isTrue);
    });

    test('an idle cache with nobody connected is purged after the window, not before; purge works any time', () async {
      final (rig, o, k) = await twoMembers(settings: const HostSettings(resumeWindowMs: 5000));
      rig.clock.now += 10000;
      expect(rig.host.tick(), isFalse, reason: 'members are connected');
      rig.net.hangUp(o.conn!);
      rig.net.hangUp(k.conn!);
      rig.clock.now += 4999;
      expect(rig.host.tick(), isFalse);
      rig.clock.now += 1;
      expect(rig.host.tick(), isTrue);
      final rig2 = HostRig();
      final m = TestMember(rig2.net, 'kim')..join();
      await rig2.net.settle();
      rig2.host.purge();
      await rig2.net.settle();
      expect(m.refusals, [Refused.noSession]);
      expect(rig2.storage.purged, isTrue);
      expect(() => HostCore.recover(schema: hostSchema, storage: rig2.storage, outbox: rig2.net), throwsStateError);
    });
  });

  test('recovery restores grants, dedupe and the log, so a resend after a restart is answered exactly', () async {
    final (rig, o, k) = await twoMembers();
    final ins = track(o, 1);
    o.submit([ins, AccessOp(member: 'kim', grants: Role.viewer.grants, author: owner, clientSeq: o.nextCs(), baseSeq: 0)]);
    await rig.net.settle();
    rig.recover();
    expect(rig.host.permissions.grantsOf('kim').map((g) => g.capability), [Capability.view]);
    o.pending[ins.clientSeq] = ins;
    o.acked.clear();
    await heal(rig, [o, k]);
    expect(o.acked[ins.clientSeq], 1);
    expect(rig.host.seq, 2);
    final ks = setOp(k, nid(1), 'name', 'no');
    k.submit([ks]);
    await rig.net.settle();
    expect(k.rejected[ks.clientSeq], HostReject.permission);
  });
}
