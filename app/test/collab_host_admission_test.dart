// caw_collab's host admission: the version matrix (project format and protocol major decide, nothing else), public
// and private lobbies, the password's per-address rate limit, invites that skip the password and set a role,
// the member cap, removed members, and invites made by members.
import 'dart:async';
import 'dart:convert';

import 'package:caw_collab/caw_collab.dart';
import 'package:flutter_test/flutter_test.dart';

import 'collab_host_fixture.dart';

void main() {
  useTestFloor();
  group('the version matrix', () {
    final host = goodVersion();
    final cases = <(String, VersionInfo, String?)>[
      ('same everything', goodVersion(), null),
      ('another app version', goodVersion(app: '1.1.9-alpha.3'), null),
      ('a newer protocol minor', goodVersion(protocol: const ProtocolVersion(1, 7)), null),
      ('an older protocol minor', goodVersion(protocol: const ProtocolVersion(1, 0)), null),
      ('an older protocol major', goodVersion(protocol: const ProtocolVersion(0, 9)), VersionRefusal.protocolMismatch),
      ('a newer protocol major', goodVersion(protocol: const ProtocolVersion(2, 0)), VersionRefusal.protocolMismatch),
      ('an older file version', goodVersion(fileVersion: 6), VersionRefusal.formatMismatch),
      ('a newer file version', goodVersion(fileVersion: 8), VersionRefusal.formatMismatch),
      ('another schema', goodVersion(schemaHash: coarseProjectSchema.hash), VersionRefusal.formatMismatch),
    ];
    for (final (name, joiner, want) in cases) {
      test(name, () => expect(versionRefusal(host, joiner)?.reason, want));
    }

    test('a refusal names who must update and to what', () {
      final behind = versionRefusal(host, goodVersion(fileVersion: 6, app: '1.1.2'))!;
      expect(behind.message, contains('update C.A.W to $appVersion'));
      final ahead = versionRefusal(host, goodVersion(fileVersion: 8, app: '1.3.0'))!;
      expect(ahead.message, contains('the host must update C.A.W to 1.3.0'));
      final proto = versionRefusal(host, goodVersion(protocol: const ProtocolVersion(0, 4)))!;
      expect(proto.message, contains('protocol 1.x'));
      expect(ProtocolVersion.parse('3.12'), const ProtocolVersion(3, 12));
      expect(ProtocolVersion.parse('3'), isNull);
    });

    test('the host refuses an unfit joiner with the reason and admits a fit one', () async {
      final rig = HostRig();
      final a = TestMember(rig.net, 'kim')..join(version: goodVersion(fileVersion: 6));
      final b = TestMember(rig.net, 'sam')..join(version: goodVersion(app: '0.0.1', protocol: const ProtocolVersion(1, 3)));
      await rig.net.settle();
      expect(a.refusals, [VersionRefusal.formatMismatch]);
      expect(a.joined, isFalse);
      expect(b.joined, isTrue);
    });
  });

  group('lobbies', () {
    test('a public session admits anyone with the default role; the owner gets the owner role', () async {
      final rig = HostRig();
      final o = TestMember(rig.net, owner)..join();
      final k = TestMember(rig.net, 'kim')..join();
      await rig.net.settle();
      expect(o.joined && k.joined, isTrue);
      expect(o.grants.map((g) => g.capability), containsAll(Capability.values));
      expect(k.grants.map((g) => g.capability).toSet(), Role.collaborator.capabilities);
    });

    test('a private session needs the password; the wrong one is refused', () async {
      final rig = HostRig(cfg: config(lobby: Lobby.private, password: 'tide pool'));
      final none = TestMember(rig.net, 'ana')..join();
      final wrong = TestMember(rig.net, 'sam', password: 'tidepool')..join();
      final right = TestMember(rig.net, 'kim', password: 'tide pool')..join();
      await rig.net.settle();
      expect(none.refusals, [Refused.wrongPassword]);
      expect(wrong.refusals, [Refused.wrongPassword]);
      expect(right.joined, isTrue);
      expect(utf8.decode(rig.storage.snapshots.read()!), isNot(contains('tide pool')));
      expect(utf8.decode(rig.storage.snapshots.read()!), contains('pbkdf2-sha256'));
    });

    test('password tries are limited per address per minute', () async {
      final rig = HostRig(cfg: config(lobby: Lobby.private, password: 'pw'), settings: const HostSettings(passwordTriesPerMinute: 3));
      Future<TestMember> attempt(String pw, String address) async {
        final m = TestMember(rig.net, 'kim', password: pw, address: address)..join();
        await rig.net.settle();
        return m;
      }

      for (var i = 0; i < 3; i++) {
        expect((await attempt('nope', '10.0.0.9')).refusals, [Refused.wrongPassword]);
      }
      expect((await attempt('pw', '10.0.0.9')).refusals, [Refused.rateLimited], reason: 'even the right one waits');
      expect((await attempt('pw', '10.0.0.10')).joined, isTrue, reason: 'another address has its own tries');
      rig.clock.now += 60000;
      expect((await attempt('pw', '10.0.0.9')).joined, isTrue, reason: 'a minute later');
    });

    test('an invite skips the password and gives its role; an unknown invite does not', () async {
      final secret = 'Qx9v2Lr8Tz0aYb3c';
      final rig = HostRig(cfg: config(lobby: Lobby.private, password: 'pw', invites: {inviteSecretHash(secret): Role.viewer}));
      final v = TestMember(rig.net, 'vic', invite: secret)..join();
      final bad = TestMember(rig.net, 'bob', invite: 'not-it')..join();
      await rig.net.settle();
      expect(v.joined, isTrue);
      expect(v.grants.map((g) => g.capability).toSet(), {Capability.view});
      expect(bad.refusals, [Refused.wrongPassword]);
    });

    test('the member cap refuses one more, but never the owner', () async {
      final rig = HostRig(settings: const HostSettings(maxMembers: 2));
      final ms = [for (final n in ['kim', 'sam', 'ana']) TestMember(rig.net, n)..join()];
      await rig.net.settle();
      expect(ms.map((m) => m.joined), [true, true, false]);
      expect(ms[2].refusals, [Refused.sessionFull]);
      final o = TestMember(rig.net, owner)..join();
      await rig.net.settle();
      expect(o.joined, isTrue);
    });

    test('a member removed by an access change is disconnected and refused from then on', () async {
      final rig = HostRig();
      final o = TestMember(rig.net, owner)..join();
      final k = TestMember(rig.net, 'kim')..join();
      await rig.net.settle();
      o.submit([AccessOp(member: 'kim', grants: const [], author: owner, clientSeq: o.nextCs(), baseSeq: 0)]);
      await rig.net.settle();
      expect(k.refusals, [Refused.removed]);
      expect(k.closes, [Refused.removed]);
      final again = TestMember(rig.net, 'kim')..join();
      await rig.net.settle();
      expect(again.refusals, [Refused.removed]);
    });

    test('a member can make an invite up to its own level only', () async {
      final rig = HostRig();
      final k = TestMember(rig.net, 'kim')..join();
      await rig.net.settle();
      rig.net.post(k.conn!, CreateInvite(epoch: k.epoch, secretHash: inviteSecretHash('s-viewer'), role: Role.viewer));
      rig.net.post(k.conn!, CreateInvite(epoch: k.epoch, secretHash: inviteSecretHash('s-owner'), role: Role.owner));
      await rig.net.settle();
      expect(rig.host.config.invites.values.map((i) => i.role), [Role.viewer]);
      // The invite survives a restart (it is in the log).
      rig.recover();
      expect(rig.host.config.invites.values.map((i) => i.role), [Role.viewer]);
    });

    test('a private session must have a password or an invite', () {
      expect(() => HostCore.create(config: config(lobby: Lobby.private), schema: hostSchema, storage: MemoryHostStorage(), outbox: RecordingOutbox(), ownerToken: ownerToken),
          throwsArgumentError);
    });

    test('a slow password check does not stop the host ordering ops', () async {
      final check = Completer<bool>();
      final out = RecordingOutbox();
      final secret = 'owner-secret-0123';
      final h = HostCore.create(
          config: config(lobby: Lobby.private, password: 'pw', invites: {inviteSecretHash(secret): Role.viewer}), schema: hostSchema,
          storage: MemoryHostStorage(), outbox: out, ownerToken: ownerToken, passwordCheck: (_, _) => check.future);
      h.connect('a', address: '1');
      h.connect('b', address: '2');
      final joining = h.receive('a', Hello(epoch: 0, member: 'kim', version: goodVersion(), password: 'pw'));
      await h.receive('b', Hello(epoch: 0, member: owner, version: goodVersion(), token: ownerToken));
      await h.receive('b', Submit(epoch: 1, ops: [
        InsertOp(parent: rootId, list: 'tracks', node: nid(1), key: 'V', kind: 'track', author: owner, clientSeq: 1, baseSeq: 0),
      ]));
      expect(out.of('b').whereType<Ack>().single.seq, 1);
      expect(out.of('a'), isEmpty, reason: 'still checking the password');
      check.complete(true);
      await joining;
      expect(out.of('a').first, isA<Welcome>());
      expect(out.of('a').whereType<Catchup>().single.ops.single.seq, 1);
    });
  });
}
