// Shared pieces for the collab host tests: a small schema, a fake clock, a host rig over the in-memory network
// and storage, and a simple member that applies confirmed ops in seq order and resends what isn't acked.
import 'package:caw_collab/caw_collab.dart';

/// Tracks hold clips; a track has a name, a gain and a code text.
final hostSchema = Schema(version: 1, rootKind: 'project', kinds: const [
  KindSpec('project', fields: {'json': FieldSpec(FieldType.json)}, lists: {'tracks': {'track'}}),
  KindSpec('track',
      fields: {'name': FieldSpec(FieldType.string), 'gain': FieldSpec(FieldType.number, min: 0, max: 2), 'source': FieldSpec(FieldType.text)},
      lists: {'items': {'clip', 'track'}}),
  KindSpec('clip', fields: {'json': FieldSpec(FieldType.json)}),
]);

const owner = 'owner1';

/// The owner's member token, given when the session is created.
const ownerToken = 'owner-token-0123456789';
const appVersion = '1.1.6';

VersionInfo goodVersion({int fileVersion = 7, String? schemaHash, ProtocolVersion protocol = collabProtocol, String app = appVersion}) =>
    VersionInfo(appVersion: app, format: ProjectFormat(fileVersion: fileVersion, schemaHash: schemaHash ?? hostSchema.hash), protocol: protocol);

class FakeClock {
  int now = 1000000;
  int call() => now;
}

/// A password check that runs inline (tests use few iterations).
Future<bool> inlineCheck(PasswordHash h, String p) async => h.verify(p);

/// Lets tests hash passwords with few iterations.
void useTestFloor() => PasswordHash.floor = 1;

SessionConfig config({Lobby lobby = Lobby.public, String? password, Map<String, Role> invites = const {}, String? hostMember}) {
  useTestFloor();
  return SessionConfig(
      sessionId: 'sess1',
      owner: owner,
      hostApp: appVersion,
      fileVersion: 7,
      lobby: lobby,
      password: password == null ? null : PasswordHash.create(password, iterations: 50),
      invites: {for (final e in invites.entries) e.key: Invite(role: e.value, usesLeft: 5)},
      hostMember: hostMember,
    );
}

/// A host, its storage, its network and its clock; [crash] throws the host away and [recover] rebuilds it.
class HostRig {
  HostRig({SessionConfig? cfg, this.settings = const HostSettings(), int seed = 1, NetworkFaults faults = NetworkFaults.none, this.faultHook})
      : net = MemoryNetwork(seed: seed, faults: faults) {
    host = HostCore.create(
        config: cfg ?? config(), schema: hostSchema, storage: storage, outbox: net, settings: settings, clock: clock.call,
        ownerToken: ownerToken, passwordCheck: inlineCheck, faults: _hook);
    net.attach(host);
    net.onCrash = (_) => crashed = true;
  }

  final storage = MemoryHostStorage();
  final clock = FakeClock();
  final MemoryNetwork net;
  final HostSettings settings;
  late HostCore host;
  bool crashed = false;
  void Function(PipelineStep step)? faultHook;

  void _hook(PipelineStep s) => faultHook?.call(s);

  /// Rebuilds the host from storage after a power cut that keeps [tornBytes] of the unsynced log.
  void recover({int tornBytes = 0}) {
    storage.crash(tornBytes: tornBytes);
    net.dropAll('host restarted');
    host = HostCore.recover(schema: hostSchema, storage: storage, outbox: net, settings: settings, clock: clock.call, passwordCheck: inlineCheck, faults: _hook);
    net.attach(host);
    crashed = false;
  }
}

/// A member: it applies confirmed ops in seq order (its own when acked, others' when broadcast or caught up),
/// keeps what it sent until it is acked or rejected, and on [resync] rejoins or asks to resume and resends.
class TestMember implements MemoryEndpoint {
  TestMember(this.net, this.id, {this.password, this.invite, this.score = 0, this.address = '10.0.0.1', String? token})
      : token = token ?? (id == owner ? ownerToken : 'token-of-$id-${'x' * 32}');
  MemoryNetwork net;
  final String id;
  String? password, invite;

  /// The member token: the owner's from the start, anyone else's from its first welcome.
  String? token;

  /// The newest host's proof of its epoch, from its welcome.
  String? fence;
  double score;
  String address;

  String? conn;
  bool joined = false;
  int epoch = 0;
  int applied = 0;
  CollabTree tree = CollabTree(hostSchema);
  int _cs = 0;
  final pending = <int, Op>{};
  final acked = <int, int>{};
  final rejected = <int, String>{};
  final _buffer = <int, Op>{};
  final refusals = <String>[];
  final refusalMessages = <String>[];
  final closes = <String>[];
  List<Successor> successors = const [];
  SessionState? state;
  List<Grant> grants = const [];
  bool hasState = false;

  void join({VersionInfo? version}) {
    conn = net.open(this, address: address);
    net.post(conn!, Hello(
        epoch: epoch, member: id, version: version ?? goodVersion(), password: password, invite: invite, token: token,
        lastSeq: hasState ? applied : null, score: score));
  }

  int nextCs() => ++_cs;

  /// Sends [ops] (made with [nextCs] clientSeqs) and keeps them until answered.
  void submit(List<Op> ops) {
    for (final o in ops) {
      pending[o.clientSeq] = o;
    }
    if (conn != null && net.isOpen(conn!)) net.post(conn!, Submit(epoch: epoch, ops: ops));
  }

  /// Reconnects when closed; otherwise asks for what it may have missed and resends what is unanswered.
  void resync() {
    if (conn == null || !net.isOpen(conn!) || !joined) {
      if (conn != null) net.hangUp(conn!);
      joined = false;
      join();
      return;
    }
    net.post(conn!, Resume(epoch: epoch, fromSeq: applied));
    if (pending.isNotEmpty) net.post(conn!, Submit(epoch: epoch, ops: (pending.values.toList()..sort((a, b) => a.clientSeq.compareTo(b.clientSeq)))));
  }

  @override
  void onMessage(HostMessage m) {
    if (m is Refused) {
      refusals.add(m.reason);
      refusalMessages.add(m.message);
      return;
    }
    if (m.epoch < epoch) return;
    epoch = m.epoch;
    switch (m) {
      case Welcome():
        joined = true;
        if (m.token != null) token = m.token;
        if (m.fence != null) fence = m.fence;
        grants = m.grants;
        if (pending.isNotEmpty) {
          net.post(conn!, Submit(epoch: epoch, ops: (pending.values.toList()..sort((a, b) => a.clientSeq.compareTo(b.clientSeq)))));
        }
      case Catchup():
        if (m.snapshot != null) {
          tree = CollabTree.fromSnapshot(hostSchema, m.snapshot);
          applied = m.snapshotSeq!;
          confirmed.clear();
          _buffer.removeWhere((s, _) => s <= applied);
        }
        hasState = true;
        for (final o in m.ops) {
          _buffer[o.seq!] = o;
        }
        _drain();
      case Ops():
        for (final o in m.ops) {
          _buffer[o.seq!] = o;
        }
        _drain();
      case Ack():
        final op = pending.remove(m.clientSeq);
        acked[m.clientSeq] = m.seq;
        if (op != null) {
          var o = op.withHeader(seq: m.seq);
          final k = m.key;
          if (k != null && o is InsertOp) o = o.withKey(k);
          if (k != null && o is MoveOp) {
            o = MoveOp(node: o.node, parent: o.parent, list: o.list, key: k, author: o.author, clientSeq: o.clientSeq, baseSeq: o.baseSeq, seq: o.seq);
          }
          _buffer[m.seq] = o;
          _drain();
        }
      case Reject():
        if (m.reason == HostReject.staleEpoch || m.reason == HostReject.rateLimited) return;
        pending.remove(m.clientSeq);
        rejected[m.clientSeq] = m.reason;
      case SessionUpdate():
        successors = m.successors;
        if (m.state != null) state = m.state;
      case Refused():
    }
  }

  /// The confirmed ops applied since the last snapshot this member took (a successor's recent log).
  final confirmed = <Op>[];

  void _drain() {
    while (_buffer.containsKey(applied + 1)) {
      final o = _buffer.remove(applied + 1)!;
      tree.apply(o);
      confirmed.add(o);
      applied++;
    }
    _buffer.removeWhere((s, _) => s <= applied);
  }

  @override
  void onClose(String reason) {
    closes.add(reason);
    joined = false;
  }

  String get snapshotText => canonicalJson(tree.snapshot());
}

String hostText(HostCore h) => canonicalJson(h.tree.snapshot());

/// A node id for test number [i].
String nid(int i, [String prefix = 't']) => '$prefix${i.toString().padLeft(8, '0')}';

/// An outbox that only records, for tests that drive a host directly.
class RecordingOutbox implements HostOutbox {
  final sent = <(String, HostMessage)>[];
  final closed = <(String, String)>[];

  @override
  void send(String connection, HostMessage message) => sent.add((connection, message));
  @override
  void close(String connection, String reason) => closed.add((connection, reason));

  List<HostMessage> of(String connection) => [for (final (c, m) in sent) if (c == connection) m];
}
