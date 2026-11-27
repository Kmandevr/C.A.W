// caw_collab's host under seeded random storms: members send random ops (valid or not) over a network that drops,
// duplicates and reorders messages, members drop and rejoin, and the host crashes at random pipeline steps with a
// torn log; afterwards every member's tree equals the host's and every seq was confirmed to exactly one op.
import 'dart:io';
import 'dart:math';

import 'package:caw_collab/caw_collab.dart';
import 'package:flutter_test/flutter_test.dart';

import 'collab_host_fixture.dart';

Op randomOp(Random r, TestMember m) {
  String t() => nid(r.nextInt(12));
  String c() => nid(r.nextInt(12), 'c');
  final key = FractionalKeys.digits[1 + r.nextInt(61)];
  final cs = m.nextCs(), base = m.applied;
  return switch (r.nextInt(9)) {
    0 || 1 => InsertOp(parent: r.nextInt(3) == 0 ? t() : rootId, list: r.nextBool() ? 'tracks' : 'items', node: t(), key: key, kind: 'track', fields: {'name': 'n${r.nextInt(9)}'}, author: m.id, clientSeq: cs, baseSeq: base),
    2 => InsertOp(parent: t(), list: 'items', node: c(), key: key, kind: 'clip', fields: {'json': {'v': r.nextInt(9)}}, author: m.id, clientSeq: cs, baseSeq: base),
    3 => SetOp(node: t(), field: ['name', 'gain', 'extra'][r.nextInt(3)], value: r.nextBool() ? r.nextInt(3) : 'v${r.nextInt(5)}', author: m.id, clientSeq: cs, baseSeq: base),
    4 => MoveOp(node: r.nextBool() ? t() : c(), parent: r.nextInt(3) == 0 ? rootId : t(), list: r.nextBool() ? 'tracks' : 'items', key: key, author: m.id, clientSeq: cs, baseSeq: base),
    5 => DeleteOp(node: r.nextBool() ? t() : c(), author: m.id, clientSeq: cs, baseSeq: base),
    6 => ReviveOp(node: r.nextBool() ? t() : c(), author: m.id, clientSeq: cs, baseSeq: base),
    7 => TextOp(node: t(), field: 'source', value: 'x${r.nextInt(9)}', lockEpoch: 0, author: m.id, clientSeq: cs, baseSeq: base),
    _ => SetOp(node: rootId, field: 'json', value: {'tempo': 60 + r.nextInt(100)}, author: m.id, clientSeq: cs, baseSeq: base),
  };
}

Future<void> storm(int seed, {required bool crashes, int steps = 400}) async {
  final r = Random(seed);
  var crashCount = 0;
  final rig = HostRig(
      seed: seed,
      faults: const NetworkFaults(drop: 0.08, duplicate: 0.08, reorder: 0.2),
      settings: HostSettings(snapshotEveryOps: 5 + r.nextInt(20), opBurst: 1000));
  final ms = [for (final n in [owner, 'kim', 'sam', 'ana']) TestMember(rig.net, n, score: r.nextInt(10).toDouble())];
  for (final m in ms) {
    m.join();
  }
  for (var step = 0; step < steps; step++) {
    if (rig.crashed) rig.recover(tornBytes: r.nextInt(40));
    final roll = r.nextInt(100);
    if (roll < 35) {
      final m = ms[r.nextInt(ms.length)];
      if (m.joined) m.submit([for (var i = 0; i < 1 + r.nextInt(3); i++) randomOp(r, m)]);
    } else if (roll < 80) {
      for (var i = r.nextInt(6); i >= 0; i--) {
        await rig.net.deliver();
        if (rig.crashed) break;
      }
    } else if (roll < 88) {
      final m = ms[r.nextInt(ms.length)];
      if (m.conn != null) rig.net.hangUp(m.conn!);
    } else if (roll < 97) {
      ms[r.nextInt(ms.length)].resync();
    }
    if (crashes && (roll >= 97 || step == steps ~/ 2)) {
      final at = PipelineStep.values[r.nextInt(PipelineStep.values.length)];
      rig.faultHook = (s) {
        if (s == at) {
          rig.faultHook = null;
          crashCount++;
          throw SimulatedCrash(s);
        }
      };
    }
  }
  rig.faultHook = null;
  if (rig.crashed) rig.recover(tornBytes: r.nextInt(40));
  rig.net.faults = NetworkFaults.none;
  for (var round = 0; round < 12; round++) {
    for (final m in ms) {
      m.resync();
    }
    await rig.net.settle();
    if (ms.every((m) => m.pending.isEmpty && m.joined && m.applied == rig.host.seq)) break;
  }
  final h = rig.host;
  for (final m in ms) {
    expect(m.pending, isEmpty, reason: 'seed $seed: ${m.id} has unanswered ops');
    expect(m.applied, h.seq, reason: 'seed $seed: ${m.id} is behind');
    expect(m.snapshotText, hostText(h), reason: 'seed $seed: ${m.id} diverged');
  }
  // Every seq went to exactly one (member, clientSeq).
  final bySeq = <int, String>{};
  for (final m in ms) {
    for (final e in m.acked.entries) {
      final who = '${m.id}#${e.key}';
      expect(bySeq.putIfAbsent(e.value, () => who), who, reason: 'seed $seed: seq ${e.value} acked twice');
    }
  }
  expect(bySeq.keys.toSet(), {for (var i = 1; i <= h.seq; i++) i}, reason: 'seed $seed: every seq is acked once');
  expect(h.seq, greaterThan(0), reason: 'seed $seed: the storm confirmed something');
  if (crashes) expect(crashCount, greaterThan(0), reason: 'seed $seed: the host crashed');
  // The stored session rebuilds to the same tree.
  final again = HostCore.recover(schema: hostSchema, storage: rig.storage, outbox: RecordingOutbox(), passwordCheck: inlineCheck);
  expect(hostText(again), hostText(h));
}

void main() {
  for (var seed = 1; seed <= 20; seed++) {
    test('a storm of drops, duplicates and reordering converges (seed $seed)', () => storm(seed, crashes: false));
  }
  for (var seed = 101; seed <= 120; seed++) {
    test('a storm with host crashes and torn logs converges (seed $seed)', () => storm(seed, crashes: true));
  }

  test('a session on disk recovers after a torn write and keeps its order', () async {
    final dir = Directory.systemTemp.createTempSync('caw_host');
    addTearDown(() => dir.deleteSync(recursive: true));
    final net = MemoryNetwork();
    final clock = FakeClock();
    var h = HostCore.create(
        config: config(), schema: hostSchema, storage: FileHostStorage(dir), outbox: net, clock: clock.call,
        settings: const HostSettings(snapshotEveryOps: 4), passwordCheck: inlineCheck);
    net.attach(h);
    final o = TestMember(net, owner)..join();
    await net.settle();
    for (var i = 0; i < 6; i++) {
      o.submit([InsertOp(parent: rootId, list: 'tracks', node: nid(i), key: 'V${i + 1}', kind: 'track', author: owner, clientSeq: o.nextCs(), baseSeq: 0)]);
    }
    await net.settle();
    expect(h.snapshotSeq, 4);
    final wal = File('${dir.path}/wal.log');
    wal.writeAsBytesSync([...wal.readAsBytesSync(), 50, 0, 0, 0, 7, 7], flush: true);
    net.dropAll('restart');
    h = HostCore.recover(schema: hostSchema, storage: FileHostStorage(dir), outbox: net, clock: clock.call, passwordCheck: inlineCheck);
    net.attach(h);
    expect(h.seq, 6);
    expect(hostText(h), o.snapshotText);
    o.join();
    o.submit([InsertOp(parent: rootId, list: 'tracks', node: nid(7), key: 'W', kind: 'track', author: owner, clientSeq: o.nextCs(), baseSeq: 6)]);
    await net.settle();
    expect(h.seq, 7);
    expect(hostText(h), o.snapshotText);
  });
}
