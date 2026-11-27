// caw_collab's host against hostile peers: fencing only on a successor's proof, member ids bound to tokens,
// invites that are used up, expire and are revoked, successors ranked by role and given the lobby's secrets only
// when they manage access, a byte cap on the tree, rate limits on every message kind, bounded password checks,
// a cap on admitted members, access changes limited to what the sender holds, and the password iteration floor.
import 'dart:async';
import 'dart:convert';

import 'package:caw_collab/caw_collab.dart';
import 'package:flutter_test/flutter_test.dart';

import 'collab_host_fixture.dart';

Hello hello(String member, {String? token, String? password, String? invite, int epoch = 0, double score = 0}) =>
    Hello(epoch: epoch, member: member, version: goodVersion(), token: token, password: password, invite: invite, score: score);

String tok(String id) => 'token-of-$id-${'x' * 32}';

InsertOp trackOp(String author, int cs, int i, {Map<String, Object?> fields = const {}}) =>
    InsertOp(parent: rootId, list: 'tracks', node: nid(i), key: 'V${i}V', kind: 'track', fields: fields, author: author, clientSeq: cs, baseSeq: 0);

/// A host driven directly, with a recording outbox.
class Direct {
  Direct({SessionConfig? cfg, HostSettings settings = const HostSettings(), PasswordCheck? check})
      : storage = MemoryHostStorage() {
    host = HostCore.create(
        config: cfg ?? config(), schema: hostSchema, storage: storage, outbox: out, ownerToken: ownerToken, settings: settings,
        clock: clock.call, passwordCheck: check ?? inlineCheck);
  }
  final out = RecordingOutbox();
  final clock = FakeClock();
  final MemoryHostStorage storage;
  late HostCore host;
  int _n = 0;

  /// Opens a connection and sends [h]; returns the connection id.
  Future<String> join(Hello h, {String address = '10.0.0.1', String? identity}) async {
    final c = 'c${_n++}';
    host.connect(c, address: address, identity: identity);
    await host.receive(c, h);
    return c;
  }

  List<HostMessage> of(String c) => out.of(c);
  String? refusal(String c) => of(c).whereType<Refused>().map((r) => r.reason).firstOrNull;
  bool welcomed(String c) => of(c).any((m) => m is Welcome);

  HostCore recover() => host = HostCore.recover(schema: hostSchema, storage: storage, outbox: out, settings: host.settings, clock: clock.call, passwordCheck: inlineCheck);
}

void main() {
  useTestFloor();

  group('1. fencing needs a successor\'s proof', () {
    test('a claimed epoch, before or after joining, only ends that connection', () async {
      final d = Direct();
      final pre = await d.join(hello('mal', epoch: 1 << 53));
      expect(d.refusal(pre), Refused.epochAhead);
      final k = await d.join(hello('kim', token: tok('kim')));
      await d.host.receive(k, Submit(epoch: 1 << 40, ops: [trackOp('kim', 1, 1)]));
      expect(d.refusal(k), Refused.epochAhead);
      expect(d.host.state, HostState.running);
      expect(d.recover().state, HostState.running);
      expect(d.welcomed(await d.join(hello('kim', token: tok('kim')))), isTrue);
    });

    test('a forged proof is refused and the host keeps running; the true one fences it, durably', () async {
      final d = Direct();
      final c = await d.join(hello('mal'));
      await d.host.receive(c, FenceNotice(epoch: 2, proof: 'ab' * 32));
      expect(d.refusal(c), Refused.invalid);
      expect(d.host.state, HostState.running);
      final c2 = 'proof';
      d.host.connect(c2, address: '1');
      await d.host.receive(c2, FenceNotice(epoch: 2, proof: fenceProof(d.host.config.migrationSecret, 'sess1', 2)));
      expect(d.host.state, HostState.fenced);
      expect(d.recover().state, HostState.fenced);
    });

    test('removing a member changes the migration secret, so its old proofs stop working', () async {
      final d = Direct();
      final o = await d.join(hello(owner, token: ownerToken));
      await d.join(hello('kim', token: tok('kim')));
      final before = d.host.config.migrationSecret;
      await d.host.receive(o, Submit(epoch: 1, ops: [AccessOp(member: 'kim', grants: const [], author: owner, clientSeq: 1, baseSeq: 0)]));
      expect(d.host.config.migrationSecret, isNot(before));
      final c = await d.join(hello('x'));
      await d.host.receive(c, FenceNotice(epoch: 2, proof: fenceProof(before, 'sess1', 2)));
      expect(d.host.state, HostState.running);
      expect(d.recover().config.migrationSecret, isNot(before), reason: 'the new secret is in the log');
    });
  });

  group('2. member ids are bound to tokens', () {
    test('the owner id without the owner token is refused, and the owner role never comes from the wire', () async {
      final d = Direct();
      final fake = await d.join(hello(owner, token: tok('mal')));
      expect(d.refusal(fake), Refused.unauthorized);
      final none = await d.join(hello(owner));
      expect(d.refusal(none), Refused.unauthorized);
      expect(d.welcomed(await d.join(hello(owner, token: ownerToken))), isTrue);
    });

    test('a known id can\'t be taken over: the real member stays; with its token it may move connections', () async {
      final d = Direct();
      final real = await d.join(hello('kim', token: tok('kim')));
      final thief = await d.join(hello('kim', token: tok('mal')));
      expect(d.refusal(thief), Refused.unauthorized);
      expect(d.refusal(real), isNull, reason: 'not kicked');
      final again = await d.join(hello('kim', token: tok('kim')));
      expect(d.welcomed(again), isTrue);
      expect(d.refusal(real), Refused.replaced);
    });

    test('the host issues a token when none (or a short one) is proposed, and requires it after', () async {
      final d = Direct();
      final c = await d.join(hello('kim', token: 'short'));
      final issued = d.of(c).whereType<Welcome>().single.token;
      expect(issued, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(d.refusal(await d.join(hello('kim', token: 'short'))), Refused.unauthorized);
      expect(d.welcomed(await d.join(hello('kim', token: issued))), isTrue);
      final p = await d.join(hello('sam', token: tok('sam')));
      expect(d.of(p).whereType<Welcome>().single.token, isNull, reason: 'its own token binds it');
      expect(utf8.decode(d.storage.snapshots.read()!), isNot(contains(tok('sam'))), reason: 'kept as a hash');
    });

    test('a removed member is refused with or without its token, and tokens survive recovery', () async {
      final d = Direct();
      final o = await d.join(hello(owner, token: ownerToken));
      await d.join(hello('kim', token: tok('kim')));
      await d.host.receive(o, Submit(epoch: 1, ops: [AccessOp(member: 'kim', grants: const [], author: owner, clientSeq: 1, baseSeq: 0)]));
      d.recover();
      expect(d.refusal(await d.join(hello('kim', token: tok('kim')))), Refused.removed);
      await d.join(hello('sam', token: tok('sam')));
      d.recover();
      expect(d.refusal(await d.join(hello('sam', token: tok('mal')))), Refused.unauthorized);
    });
  });

  group('3. invites', () {
    test('one use by default; expiry; multi-use up to its count; all logged', () async {
      final d = Direct(cfg: config(lobby: Lobby.private, password: 'pw'), settings: const HostSettings(inviteTtlMs: 1000));
      final o = await d.join(hello(owner, token: ownerToken));
      await d.host.receive(o, CreateInvite(epoch: 1, secretHash: inviteSecretHash('once'), role: Role.viewer));
      await d.host.receive(o, CreateInvite(epoch: 1, secretHash: inviteSecretHash('twice'), role: Role.viewer, maxUses: 2));
      await d.host.receive(o, CreateInvite(epoch: 1, secretHash: inviteSecretHash('late'), role: Role.viewer));
      expect(d.welcomed(await d.join(hello('a1', invite: 'once'))), isTrue);
      d.recover();
      expect(d.refusal(await d.join(hello('a2', invite: 'once'))), Refused.wrongPassword, reason: 'used up, even after a restart');
      expect(d.welcomed(await d.join(hello('b1', invite: 'twice'))), isTrue);
      expect(d.welcomed(await d.join(hello('b2', invite: 'twice'))), isTrue);
      expect(d.refusal(await d.join(hello('b3', invite: 'twice'))), Refused.wrongPassword);
      d.clock.now += 1000;
      expect(d.refusal(await d.join(hello('c1', invite: 'late'))), Refused.wrongPassword, reason: 'expired');
    });

    test('a removed member\'s invites are revoked, and the number of live invites is capped', () async {
      final d = Direct(settings: const HostSettings(maxInvites: 3, invitesPerMinute: 100));
      final o = await d.join(hello(owner, token: ownerToken));
      final k = await d.join(hello('kim', token: tok('kim')));
      await d.host.receive(k, CreateInvite(epoch: 1, secretHash: inviteSecretHash('kims'), role: Role.viewer));
      expect(d.host.config.invites, hasLength(1));
      await d.host.receive(o, Submit(epoch: 1, ops: [AccessOp(member: 'kim', grants: const [], author: owner, clientSeq: 1, baseSeq: 0)]));
      expect(d.host.config.invites, isEmpty);
      expect(d.recover().config.invites, isEmpty, reason: 'revocation replays from the log');
      final o2 = await d.join(hello(owner, token: ownerToken));
      for (var i = 0; i < 6; i++) {
        await d.host.receive(o2, CreateInvite(epoch: 1, secretHash: inviteSecretHash('s$i'), role: Role.viewer));
      }
      expect(d.host.config.invites, hasLength(3));
    });
  });

  group('4. successors', () {
    test('viewers are never successors; role ranks before a self-reported score, which is clamped', () async {
      final secret = 'viewer-invite-0001';
      final d = Direct(cfg: config(invites: {inviteSecretHash(secret): Role.viewer}));
      await d.join(hello('vic', invite: secret, score: 1e9));
      await d.join(hello('kim', token: tok('kim'), score: 1e9));
      await d.join(hello(owner, token: ownerToken, score: 1));
      final list = d.host.successors;
      expect(list.map((s) => s.member), [owner, 'kim']);
      expect(list[1].score, const HostSettings().maxScore);
    });

    test('the lobby\'s secrets go only to a successor who manages access', () async {
      final d = Direct(cfg: config(lobby: Lobby.private, password: 'pw', invites: {inviteSecretHash('inv-0000000000'): Role.viewer}));
      final o = await d.join(hello(owner, token: ownerToken));
      await d.join(hello('kim', token: tok('kim'), password: 'pw'));
      await d.join(hello('ana', token: tok('ana'), password: 'pw'));
      await d.host.receive(o, Submit(epoch: 1, ops: [AccessOp(member: 'ana', grants: Role.owner.grants.where((g) => g.capability != Capability.publish).toList(), author: owner, clientSeq: 1, baseSeq: 0)]));
      final kimState = d.host.stateFor('kim'), anaState = d.host.stateFor('ana');
      expect(kimState.config.password, isNull);
      expect(kimState.config.invites, isEmpty);
      expect(anaState.config.password, isNotNull);
      expect(anaState.config.invites, hasLength(1));
      // What kim actually received carries no hash either.
      final sent = [for (final (_, m) in d.out.sent) if (m is SessionUpdate && m.state != null) m.state!];
      expect(sent.where((s) => s.config.password == null), isNotEmpty);
      // Kim continues as host: the session stays private, admitting known members and nobody new.
      final out = RecordingOutbox();
      final h2 = HostCore.continueSession(
          state: kimState, schema: hostSchema, replica: d.host.tree, seq: d.host.seq, storage: MemoryHostStorage(), outbox: out,
          hostApp: appVersion, passwordCheck: inlineCheck);
      h2.connect('n', address: '1');
      await h2.receive('n', hello('new', password: 'pw'));
      expect(out.of('n').whereType<Refused>().single.reason, Refused.locked);
      h2.connect('o', address: '1');
      await h2.receive('o', hello(owner, token: ownerToken, epoch: 1));
      expect(out.of('o').first, isA<Welcome>());
    });
  });

  group('5. bounded storage', () {
    test('an op that would pass the tree\'s byte cap is refused, and snapshots and recovery keep working', () async {
      final d = Direct(settings: const HostSettings(maxTreeBytes: 6000, snapshotEveryOps: 3));
      final o = await d.join(hello(owner, token: ownerToken));
      for (var i = 1; i <= 12; i++) {
        await d.host.receive(o, Submit(epoch: 1, ops: [trackOp(owner, i, i, fields: {'name': 'n' * 900})]));
      }
      final rejects = d.of(o).whereType<Reject>().toList();
      expect(rejects, isNotEmpty);
      expect(rejects.map((r) => r.reason).toSet(), {HostReject.limit});
      expect(d.host.treeBytes, lessThanOrEqualTo(6000));
      expect(d.host.state, HostState.running);
      final seq = d.host.seq;
      expect(d.recover().seq, seq);
      expect(d.host.treeBytes, lessThanOrEqualTo(6000));
    });

    test('settings whose worst snapshot passes the frame limit are refused; grants per member are capped', () async {
      expect(() => Direct(settings: const HostSettings(maxTreeBytes: maxSnapshotBytes)), throwsArgumentError);
      final d = Direct(settings: const HostSettings(maxGrantsPerMember: 4));
      final o = await d.join(hello(owner, token: ownerToken));
      await d.host.receive(o, Submit(epoch: 1, ops: [AccessOp(member: 'kim', grants: [for (var i = 0; i < 5; i++) Grant(Capability.view, nid(i))], author: owner, clientSeq: 1, baseSeq: 0)]));
      expect(d.of(o).whereType<Reject>().single.reason, HostReject.permission);
    });
  });

  group('6. every message kind is rate-limited', () {
    test('resumes and invites beyond their per-minute counts are ignored; a flood ends the connection', () async {
      final d = Direct(settings: const HostSettings(resumesPerMinute: 2, invitesPerMinute: 2, messageBurst: 30, messagesPerSecond: 1));
      final o = await d.join(hello(owner, token: ownerToken));
      await d.host.receive(o, Submit(epoch: 1, ops: [trackOp(owner, 1, 1)]));
      final before = d.of(o).whereType<Catchup>().length;
      for (var i = 0; i < 5; i++) {
        await d.host.receive(o, Resume(epoch: 1, fromSeq: 0));
      }
      expect(d.of(o).whereType<Catchup>().length - before, 2);
      final writes = d.storage.wal.syncs;
      for (var i = 0; i < 5; i++) {
        await d.host.receive(o, CreateInvite(epoch: 1, secretHash: inviteSecretHash('f$i'), role: Role.viewer));
      }
      expect(d.host.config.invites, hasLength(2));
      expect(d.storage.wal.syncs - writes, 2);
      for (var i = 0; i < 40; i++) {
        await d.host.receive(o, Resume(epoch: 1, fromSeq: 1));
      }
      expect(d.refusal(o), Refused.rateLimited);
    });
  });

  group('7. password checks', () {
    test('run one at a time with a bounded queue, and the rest are refused as busy', () async {
      var running = 0, most = 0;
      final gates = <Completer<bool>>[];
      final d = Direct(
          cfg: config(lobby: Lobby.private, password: 'pw'),
          settings: const HostSettings(passwordChecksAtOnce: 1, passwordQueue: 1, passwordTriesPerMinute: 100),
          check: (h, p) {
            running++;
            if (running > most) most = running;
            final g = Completer<bool>();
            gates.add(g);
            return g.future.whenComplete(() => running--);
          });
      final joins = <Future<String>>[for (var i = 0; i < 3; i++) d.join(hello('m$i', password: 'pw'), address: '10.0.0.$i')];
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(1), reason: 'one runs, one waits, one is refused');
      gates.single.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(2));
      gates[1].complete(true);
      final cs = await Future.wait(joins);
      expect(most, 1);
      expect([for (final c in cs) d.welcomed(c)], [true, true, false]);
      expect(d.refusal(cs[2]), Refused.busy);
    });

    test('tries count per transport identity when given, with a global cap, and old windows are pruned', () async {
      final d = Direct(cfg: config(lobby: Lobby.private, password: 'pw'), settings: const HostSettings(passwordTriesPerMinute: 2, passwordTriesPerMinuteGlobal: 5));
      Future<String?> attempt(String id, String? identity, String pw) async =>
          d.refusal(await d.join(hello(id, password: pw), address: '10.9.9.9', identity: identity));
      expect(await attempt('a', 'peer-a', 'no'), Refused.wrongPassword);
      expect(await attempt('a', 'peer-a', 'no'), Refused.wrongPassword);
      expect(await attempt('a', 'peer-a', 'pw'), Refused.rateLimited);
      expect(await attempt('b', 'peer-b', 'pw'), isNull, reason: 'behind the same relay address, another peer still joins');
      expect(await attempt('c', 'peer-c', 'no'), Refused.wrongPassword);
      expect(await attempt('d', 'peer-d', 'no'), Refused.wrongPassword);
      expect(await attempt('e', 'peer-e', 'pw'), Refused.rateLimited, reason: 'the global cap');
      expect(d.host.windowCount, greaterThan(0));
      d.clock.now += 60000;
      d.host.tick();
      expect(d.host.windowCount, 0);
    });
  });

  group('8. admissions are capped', () {
    test('at most maxKnownMembers ids, and a few first joins per address a minute', () async {
      final d = Direct(settings: const HostSettings(maxKnownMembers: 3, maxMembers: 3, joinsPerMinute: 10));
      for (final m in ['a', 'b']) {
        await d.join(hello(m, token: tok(m)), address: '10.0.0.${m.codeUnitAt(0)}');
      }
      expect(d.refusal(await d.join(hello('c', token: tok('c')), address: '10.0.1.1')), Refused.sessionFull, reason: 'the owner counts');
      final e = Direct(settings: const HostSettings(joinsPerMinute: 2));
      expect(e.welcomed(await e.join(hello('a1'), address: '5.5.5.5')), isTrue);
      expect(e.welcomed(await e.join(hello('a2'), address: '5.5.5.5')), isTrue);
      expect(e.refusal(await e.join(hello('a3'), address: '5.5.5.5')), Refused.rateLimited);
      expect(e.welcomed(await e.join(hello('a4'), address: '6.6.6.6')), isTrue);
      expect(e.welcomed(await e.join(hello('a1', token: e.of('c0').whereType<Welcome>().single.token), address: '5.5.5.5')), isTrue,
          reason: 'known members rejoin freely');
    });
  });

  group('9. access changes', () {
    test('a sender gives only what it holds, where it holds it', () async {
      final d = Direct();
      final o = await d.join(hello(owner, token: ownerToken));
      await d.host.receive(o, Submit(epoch: 1, ops: [
        trackOp(owner, 1, 1),
        AccessOp(member: 'kim', grants: [Grant(Capability.view, rootId), Grant(Capability.manageAccess, rootId), Grant(Capability.editContent, nid(1))], author: owner, clientSeq: 2, baseSeq: 0),
      ]));
      final k = await d.join(hello('kim', token: tok('kim')));
      Future<String?> give(int cs, List<Grant> grants) async {
        await d.host.receive(k, Submit(epoch: 1, ops: [AccessOp(member: 'sam', grants: grants, author: 'kim', clientSeq: cs, baseSeq: 0)]));
        final r = d.of(k).whereType<Reject>().where((r) => r.clientSeq == cs);
        return r.isEmpty ? null : r.single.reason;
      }

      expect(await give(1, [Grant(Capability.publish, rootId)]), HostReject.permission);
      expect(await give(2, [Grant(Capability.editContent, rootId)]), HostReject.permission);
      expect(await give(3, [Grant(Capability.view, rootId), Grant(Capability.editContent, nid(1))]), isNull);
    });
  });

  group('10. the password iteration floor', () {
    test('new and stored hashes under 100,000 iterations are refused outside tests', () {
      final weak = PasswordHash.create('pw', iterations: 50).encoded;
      final cfg = config().toJson();
      PasswordHash.floor = PasswordHash.minIterations;
      try {
        expect(PasswordHash.minIterations, 100000);
        expect(() => PasswordHash.create('pw', iterations: 50), throwsArgumentError);
        expect(PasswordHash.parse(weak), isNull);
        expect(PasswordHash.parse(r'pbkdf2-sha256$1$AAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'), isNull);
        expect(() => SessionConfig.fromJson({...cfg, 'password': weak}), throwsFormatException);
      } finally {
        useTestFloor();
      }
    });
  });
}
