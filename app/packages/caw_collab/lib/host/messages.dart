// The session messages between members and the host, each carrying the sender's epoch, and their JSON codec
// (decoders treat their input as untrusted and throw nothing but CollabDecodeError).
import 'dart:convert';

import '../codec.dart';
import '../ids.dart';
import '../limits.dart';
import '../ops.dart';
import 'permissions.dart';
import 'session.dart';
import 'versions.dart';

// ---------------------------------------------------------------------------------------------------------------
// Member to host

/// A message from a member. [epoch] is the host epoch the member last knew (0 before it knew any).
sealed class ClientMessage {
  const ClientMessage(this.epoch);
  final int epoch;
  String get type;
  Map<String, Object?> body();
  Map<String, Object?> toJson() => {'t': type, 'epoch': epoch, ...body()};
}

/// The join handshake. [token] is the member's token: proposed at its first hello (at least 32 random
/// characters), or issued by the host in that first welcome, and required on every later hello. [lastSeq] asks to resume after that seq (null: send everything). [score] is the member's
/// self-reported capability score for the successor ranking (the host clamps it and ranks by role first).
final class Hello extends ClientMessage {
  const Hello({
    required int epoch,
    required this.member,
    required this.version,
    this.password,
    this.invite,
    this.token,
    this.lastSeq,
    this.score = 0,
  }) : super(epoch);
  final String member;
  final VersionInfo version;
  final String? password;
  final String? invite;
  final String? token;
  final int? lastSeq;
  final double score;

  @override
  String get type => 'hello';
  @override
  Map<String, Object?> body() => {
        'member': member,
        'app': version.appVersion,
        'format': version.format.toJson(),
        'protocol': version.protocol.toString(),
        if (password != null) 'password': password,
        if (invite != null) 'invite': invite,
        if (token != null) 'token': token,
        if (lastSeq != null) 'lastSeq': lastSeq,
        'score': score,
      };
}

/// Ops for the host to order.
final class Submit extends ClientMessage {
  const Submit({required int epoch, required this.ops}) : super(epoch);
  final List<Op> ops;
  @override
  String get type => 'submit';
  @override
  Map<String, Object?> body() => {'ops': [for (final o in ops) o.toJson()]};
}

/// Send what came after [fromSeq] again.
final class Resume extends ClientMessage {
  const Resume({required int epoch, required this.fromSeq}) : super(epoch);
  final int fromSeq;
  @override
  String get type => 'resume';
  @override
  Map<String, Object?> body() => {'fromSeq': fromSeq};
}

/// Register an invite: the hash of its secret ([inviteSecretHash]), the role it gives (at most the sender's),
/// how many joins it admits (one by default) and how long it lasts (null: the host's default).
final class CreateInvite extends ClientMessage {
  const CreateInvite({required int epoch, required this.secretHash, required this.role, this.maxUses = 1, this.ttlMs}) : super(epoch);
  final String secretHash;
  final Role role;
  final int maxUses;
  final int? ttlMs;
  @override
  String get type => 'invite';
  @override
  Map<String, Object?> body() => {'secretHash': secretHash, 'role': role.wire, 'maxUses': maxUses, if (ttlMs != null) 'ttlMs': ttlMs};
}

/// Proof that a newer host took over: its [epoch] and [proof] ([fenceProof]), as the new host's welcome carried
/// them. A host that checks it stops accepting anything, for good.
final class FenceNotice extends ClientMessage {
  const FenceNotice({required int epoch, required this.proof}) : super(epoch);
  final String proof;
  @override
  String get type => 'fence';
  @override
  Map<String, Object?> body() => {'proof': proof};
}

/// Leaving.
final class Bye extends ClientMessage {
  const Bye({required int epoch}) : super(epoch);
  @override
  String get type => 'bye';
  @override
  Map<String, Object?> body() => const {};
}

// ---------------------------------------------------------------------------------------------------------------
// Host to member

/// A message from the host, carrying its epoch.
sealed class HostMessage {
  const HostMessage(this.epoch);
  final int epoch;
  String get type;
  Map<String, Object?> body();
  Map<String, Object?> toJson() => {'t': type, 'epoch': epoch, ...body()};
}

/// The join is accepted: the session, the member's grants and the host's position. [token] is issued once, at
/// a member's first admission when it proposed none: the member keeps it and sends it on every later hello. [fence] is this host's
/// proof of its epoch ([fenceProof]) when it is a successor, for members to show an older host.
final class Welcome extends HostMessage {
  const Welcome({required int epoch, required this.sessionId, required this.seq, required this.grants, required this.owner, this.token, this.fence}) : super(epoch);
  final String sessionId;
  final int seq;
  final List<Grant> grants;
  final String owner;
  final String? token;
  final String? fence;
  @override
  String get type => 'welcome';
  @override
  Map<String, Object?> body() => {
        'sessionId': sessionId,
        'seq': seq,
        'grants': [for (final g in grants) g.toJson()],
        'owner': owner,
        if (token != null) 'token': token,
        if (fence != null) 'fence': fence,
      };
}

/// Catching up: with a [snapshot] (the tree at [snapshotSeq], which replaces the member's state), then [ops] in
/// seq order.
final class Catchup extends HostMessage {
  const Catchup({required int epoch, this.snapshotSeq, this.snapshot, required this.ops}) : super(epoch);
  final int? snapshotSeq;
  final Object? snapshot;
  final List<Op> ops;
  @override
  String get type => 'catchup';
  @override
  Map<String, Object?> body() => {
        if (snapshot != null) 'snapshotSeq': snapshotSeq,
        if (snapshot != null) 'snapshot': snapshot,
        'ops': [for (final o in ops) o.toJson()],
      };
}

/// The member's op [clientSeq] is confirmed as [seq]. [key] is set when the host changed an insert's or move's
/// key (the tie-break).
final class Ack extends HostMessage {
  const Ack({required int epoch, required this.clientSeq, required this.seq, this.key}) : super(epoch);
  final int clientSeq;
  final int seq;
  final String? key;
  @override
  String get type => 'ack';
  @override
  Map<String, Object?> body() => {'clientSeq': clientSeq, 'seq': seq, if (key != null) 'key': key};
}

/// The member's op [clientSeq] was refused, with a stable [reason].
final class Reject extends HostMessage {
  const Reject({required int epoch, required this.clientSeq, required this.reason, required this.message}) : super(epoch);
  final int clientSeq;
  final String reason;
  final String message;
  @override
  String get type => 'reject';
  @override
  Map<String, Object?> body() => {'clientSeq': clientSeq, 'reason': reason, 'message': message};
}

/// Others' confirmed ops, in seq order.
final class Ops extends HostMessage {
  const Ops({required int epoch, required this.ops}) : super(epoch);
  final List<Op> ops;
  @override
  String get type => 'ops';
  @override
  Map<String, Object?> body() => {'ops': [for (final o in ops) o.toJson()]};
}

/// One ranked successor.
class Successor {
  const Successor(this.member, this.score);
  final String member;
  final double score;
  Map<String, Object?> toJson() => {'member': member, 'score': score};
}

/// Who would host next, in order; [state] goes only to the members on the list.
final class SessionUpdate extends HostMessage {
  const SessionUpdate({required int epoch, required this.successors, this.state}) : super(epoch);
  final List<Successor> successors;
  final SessionState? state;
  @override
  String get type => 'session';
  @override
  Map<String, Object?> body() => {'successors': [for (final s in successors) s.toJson()], if (state != null) 'state': state!.toJson()};
}

/// The host refuses the join or ends the connection, with a stable [reason] and a [message] for the person.
final class Refused extends HostMessage {
  const Refused({required int epoch, required this.reason, required this.message}) : super(epoch);
  final String reason;
  final String message;

  static const invalid = 'invalid';
  static const notJoined = 'not_joined';
  static const wrongPassword = 'wrong_password';
  static const rateLimited = 'rate_limited';
  static const sessionFull = 'session_full';
  static const removed = 'removed';
  static const replaced = 'replaced';
  static const staleHost = 'stale_host';
  static const sessionEnded = 'session_ended';
  static const noSession = 'no_session';
  static const unauthorized = 'unauthorized';
  static const epochAhead = 'epoch_ahead';
  static const busy = 'busy';
  static const locked = 'locked';

  @override
  String get type => 'refused';
  @override
  Map<String, Object?> body() => {'reason': reason, 'message': message};
}

// ---------------------------------------------------------------------------------------------------------------
// Codec

/// A message as JSON text.
String encodeMessage(Object message) => switch (message) {
      ClientMessage m => jsonEncode(m.toJson()),
      HostMessage m => jsonEncode(m.toJson()),
      _ => throw ArgumentError('not a session message'),
    };

// A message, its ops list and an op's map add 3 levels; a snapshot adds snapshot, nodes, node and fields.
int _depth(CollabLimits l, {bool snapshot = false}) => l.maxDepth + 3 + 3 + (snapshot ? 4 : 0);

/// Decodes a member's message from untrusted [text]: at most one batch's worth of characters plus 64 KiB.
ClientMessage decodeClientMessage(String text, [CollabLimits limits = CollabLimits.standard]) {
  final v = parseJsonLimited(text, maxChars: limits.maxOpBytes + 65536, maxDepth: _depth(limits));
  return _wrap(() => _client(v, limits));
}

/// Decodes a host's message from untrusted [text] of at most [maxChars] (a catch-up holds a whole snapshot).
HostMessage decodeHostMessage(String text, {CollabLimits limits = CollabLimits.standard, int maxChars = 64 * 1024 * 1024}) {
  final v = parseJsonLimited(text, maxChars: maxChars, maxDepth: _depth(limits, snapshot: true));
  return _wrap(() => _host(v, limits));
}

T _wrap<T>(T Function() f) {
  try {
    return f();
  } on FormatException catch (e) {
    throw CollabDecodeError(e.message);
  }
}

Never _bad(String why) => throw CollabDecodeError(why);

T _f<T>(Map m, String k) {
  final v = m[k];
  if (v is! T) _bad('$k is missing or malformed');
  return v;
}

T? _opt<T>(Map m, String k) {
  final v = m[k];
  if (v == null) return null;
  if (v is! T) _bad('$k is malformed');
  return v;
}

int _seqField(Map m, String k) {
  final v = _f<int>(m, k);
  if (v < 0) _bad('$k is negative');
  return v;
}

List<Op> _ops(Map m, CollabLimits limits) {
  final l = _f<List>(m, 'ops');
  if (l.length > limits.maxBatchOps) _bad('over ${limits.maxBatchOps} ops');
  return [for (final o in l) opFromJson(o, limits)];
}

ClientMessage _client(Object? v, CollabLimits limits) {
  if (v is! Map) _bad('a message is not an object');
  final epoch = _seqField(v, 'epoch');
  switch (_f<String>(v, 't')) {
    case 'hello':
      final member = _f<String>(v, 'member');
      if (!AuthorIds.isValid(member)) _bad('member is not an author id');
      final format = _f<Map>(v, 'format');
      final protocol = ProtocolVersion.parse(_f<String>(v, 'protocol'));
      if (protocol == null) _bad('protocol is not major.minor');
      final score = _f<num>(v, 'score').toDouble();
      final app = _f<String>(v, 'app');
      final password = _opt<String>(v, 'password');
      final invite = _opt<String>(v, 'invite');
      final token = _opt<String>(v, 'token');
      if (app.length > 64 || (password?.length ?? 0) > 1024 || (invite?.length ?? 0) > 256 || (token?.length ?? 0) > 256) {
        _bad('a hello field is too long');
      }
      final lastSeq = _opt<int>(v, 'lastSeq');
      if ((lastSeq ?? 0) < 0) _bad('lastSeq is negative');
      return Hello(
        epoch: epoch,
        member: member,
        version: VersionInfo(
            appVersion: app,
            format: ProjectFormat(fileVersion: _seqField(format, 'fileVersion'), schemaHash: _f<String>(format, 'schemaHash')),
            protocol: protocol),
        password: password,
        invite: invite,
        token: token,
        lastSeq: lastSeq,
        score: score.isFinite ? score : 0,
      );
    case 'submit':
      return Submit(epoch: epoch, ops: _ops(v, limits));
    case 'resume':
      return Resume(epoch: epoch, fromSeq: _seqField(v, 'fromSeq'));
    case 'invite':
      final h = _f<String>(v, 'secretHash');
      final r = Role.byWire(_f<String>(v, 'role'));
      final uses = _opt<int>(v, 'maxUses') ?? 1;
      final ttl = _opt<int>(v, 'ttlMs');
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(h) || r == null || uses < 1 || (ttl ?? 1) < 1) _bad('an invite is malformed');
      return CreateInvite(epoch: epoch, secretHash: h, role: r, maxUses: uses, ttlMs: ttl);
    case 'fence':
      final proof = _f<String>(v, 'proof');
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(proof)) _bad('a fence proof is malformed');
      return FenceNotice(epoch: epoch, proof: proof);
    case 'bye':
      return Bye(epoch: epoch);
    default:
      _bad('unknown message ${v['t']}');
  }
}

HostMessage _host(Object? v, CollabLimits limits) {
  if (v is! Map) _bad('a message is not an object');
  final epoch = _seqField(v, 'epoch');
  switch (_f<String>(v, 't')) {
    case 'welcome':
      return Welcome(
          epoch: epoch,
          sessionId: _f<String>(v, 'sessionId'),
          seq: _seqField(v, 'seq'),
          grants: [for (final g in _f<List>(v, 'grants')) grantFromJson(g)],
          owner: _f<String>(v, 'owner'),
          token: _opt<String>(v, 'token'),
          fence: _opt<String>(v, 'fence'));
    case 'catchup':
      final hasSnap = v.containsKey('snapshot');
      return Catchup(
          epoch: epoch, snapshotSeq: hasSnap ? _seqField(v, 'snapshotSeq') : null, snapshot: hasSnap ? v['snapshot'] : null, ops: _ops(v, limits));
    case 'ack':
      return Ack(epoch: epoch, clientSeq: _seqField(v, 'clientSeq'), seq: _seqField(v, 'seq'), key: _opt<String>(v, 'key'));
    case 'reject':
      return Reject(epoch: epoch, clientSeq: _seqField(v, 'clientSeq'), reason: _f<String>(v, 'reason'), message: _f<String>(v, 'message'));
    case 'ops':
      return Ops(epoch: epoch, ops: _ops(v, limits));
    case 'session':
      final s = v['state'];
      return SessionUpdate(epoch: epoch, successors: [
        for (final x in _f<List>(v, 'successors'))
          if (x is Map && x['member'] is String && x['score'] is num)
            Successor(x['member'] as String, (x['score'] as num).toDouble())
          else
            _bad('a successor is malformed'),
      ], state: s == null ? null : SessionState.fromJson(s));
    case 'refused':
      return Refused(epoch: epoch, reason: _f<String>(v, 'reason'), message: _f<String>(v, 'message'));
    default:
      _bad('unknown message ${v['t']}');
  }
}
