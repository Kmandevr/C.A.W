// The transport-agnostic session host: admission (versions, lobby password, invites, member cap), the op
// pipeline (dedupe, size, rate, structure, permission, schema and cycle checks, seq, WAL, fsync before ack,
// broadcast), catch-up and resume, snapshots, epochs and fencing for host migration, and the session cache.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../codec.dart';
import '../ids.dart';
import '../limits.dart';
import '../ops.dart';
import '../schema.dart';
import '../tree.dart';
import 'messages.dart';
import 'password.dart';
import 'permissions.dart';
import 'session.dart';
import 'settings.dart';
import 'storage.dart';
import 'versions.dart';

/// Where the host sends messages: one implementation per transport.
abstract interface class HostOutbox {
  void send(String connection, HostMessage message);

  /// Ends [connection] after the messages already sent.
  void close(String connection, String reason);
}

/// The points of the op pipeline (and of a snapshot) where a test can inject a crash.
enum PipelineStep { received, validated, appended, synced, acked, broadcast, snapshotWritten, walReset }

/// What a fault hook throws to stop the host where it stands, as a crash would.
class SimulatedCrash implements Exception {
  const SimulatedCrash(this.step);
  final PipelineStep step;
  @override
  String toString() => 'SimulatedCrash at ${step.name}';
}

/// Checks a password against its hash; the default runs the slow hash on another isolate so the host keeps
/// ordering ops meanwhile.
typedef PasswordCheck = Future<bool> Function(PasswordHash hash, String password);

Future<bool> isolatePasswordCheck(PasswordHash hash, String password) => Isolate.run(() => hash.verify(password));

/// The host's lifecycle.
enum HostState {
  running,

  /// Another host holds a newer epoch: this one accepts nothing, for good.
  fenced,

  /// The session ended; its cache waits out the resume window.
  ended,

  /// Storage failed or a crash was simulated: throw this object away and [HostCore.recover].
  failed,

  /// The cache is deleted.
  purged,
}

/// Op reject reasons the host adds to the tree's ([OpRejected]).
abstract final class HostReject {
  static const permission = 'permission';
  static const rateLimited = 'rate_limited';
  static const staleEpoch = 'stale_epoch';
  static const duplicate = 'duplicate';
  static const wrongAuthor = 'wrong_author';
  static const unsupported = 'unsupported';
  static const limit = 'limit';
}

const _recOp = 1, _recMeta = 2;

// The key a resent op's ack names when the outcome is rebuilt from a confirmed op: the key it was confirmed with.
String? _keyOf(Op op) => switch (op) {
      InsertOp() => op.key,
      MoveOp() => op.key,
      _ => null,
    };
const _snapshotFormat = 1;

class _Outcome {
  const _Outcome.ack(this.seq, this.key) : reason = null, message = null;
  const _Outcome.reject(this.reason, this.message) : seq = null, key = null;
  final int? seq;
  final String? key;
  final String? reason, message;

  Map<String, Object?> toJson() => seq != null ? {'seq': seq, if (key != null) 'key': key} : {'reason': reason, 'message': message};

  static _Outcome fromJson(Map m) =>
      m['seq'] is int ? _Outcome.ack(m['seq'] as int, m['key'] as String?) : _Outcome.reject(m['reason'] as String, m['message'] as String);
}

// One member's recent (clientSeq -> outcome), oldest first; every clientSeq at or below floor is long handled.
class _Seen {
  int floor = 0;
  final recent = <int, _Outcome>{};

  void record(int cs, _Outcome o, int memory) {
    recent[cs] = o;
    while (recent.length > memory) {
      final first = recent.keys.first;
      recent.remove(first);
      if (first > floor) floor = first;
    }
  }
}

class _Conn {
  _Conn(this.address);
  final String address;
  String? member;
  bool pending = false;
}

class _Bucket {
  _Bucket(this.tokens, this.at);
  double tokens;
  int at;
}

/// One session's host. It is driven entirely by calls ([connect], [receive], [disconnect], [tick]) and answers
/// through its [HostOutbox], so any transport can carry it; it does nothing on its own.
///
/// Durability: an op is acked only after its log record is synced; a snapshot replaces the log every
/// [HostSettings.snapshotEveryOps] ops or [HostSettings.snapshotEveryMs]. In memory the tree runs ahead of the
/// disk while a batch is being written; any storage failure moves the host to [HostState.failed] and the caller
/// recovers a new one from storage, so nothing unsynced is ever acked or broadcast.
class HostCore {
  HostCore._({
    required this.config,
    required this.schema,
    required this.storage,
    required this.outbox,
    required this.settings,
    required this.policy,
    required this.clock,
    required this.passwordCheck,
    this.faults,
  }) : tree = CollabTree(schema, opLimits: settings.limits);

  final SessionConfig config;
  final Schema schema;
  final HostStorage storage;
  final HostOutbox outbox;
  final HostSettings settings;
  final PermissionPolicy policy;
  final PasswordCheck passwordCheck;

  /// Called at each [PipelineStep]; throw [SimulatedCrash] to stop the host there.
  final void Function(PipelineStep step)? faults;

  /// Milliseconds since the epoch.
  final int Function() clock;

  /// The host's tree: every confirmed op applied, in seq order.
  CollabTree tree;
  final permissions = Permissions();

  HostState _state = HostState.running;
  int _epoch = 1, _epochStartSeq = 0, _seq = 0, _lsn = 0;
  int _snapshotSeq = 0, _snapshotLsn = 0, _lastSnapshotAt = 0, _lastActive = 0;
  int? _endedAt;
  Map<String, Object?> _snapshotTree = const {};
  final _tail = <Op>[];
  final _seen = <String, _Seen>{};
  final _conns = <String, _Conn>{};
  final _scores = <String, double>{};
  final _buckets = <String, _Bucket>{};
  final _tries = <String, List<int>>{};

  HostState get state => _state;
  int get epoch => _epoch;
  int get seq => _seq;

  /// The seq of the latest snapshot; ops after it are in [tail].
  int get snapshotSeq => _snapshotSeq;
  List<Op> get tail => List.unmodifiable(_tail);

  /// The members connected now.
  Set<String> get connectedMembers => {for (final c in _conns.values) if (c.member != null) c.member!};

  VersionInfo get version => hostVersion(config, schema.hash);

  // -------------------------------------------------------------------------------------------------------------
  // Starting

  /// Starts a new session over empty [storage], from [initial] (the owner's project at the start; an empty tree
  /// when null). The owner gets the owner role.
  static HostCore create({
    required SessionConfig config,
    required Schema schema,
    required HostStorage storage,
    required HostOutbox outbox,
    CollabTree? initial,
    HostSettings settings = const HostSettings(),
    PermissionPolicy policy = PermissionPolicy.standard,
    int Function()? clock,
    PasswordCheck passwordCheck = isolatePasswordCheck,
    void Function(PipelineStep)? faults,
  }) {
    if (!storage.isEmpty) throw StateError('storage already holds a session: recover it or purge it');
    final h = HostCore._(
        config: config, schema: schema, storage: storage, outbox: outbox, settings: settings, policy: policy,
        clock: clock ?? _wallClock, passwordCheck: passwordCheck, faults: faults);
    if (initial != null) {
      if (initial.schema.hash != schema.hash) throw ArgumentError('the initial tree has another schema');
      h.tree = CollabTree.fromSnapshot(schema, jsonDecode(jsonEncode(initial.snapshot())), opLimits: settings.limits);
    }
    h.permissions.set(config.owner, Role.owner.grants);
    h._lastActive = h._now;
    h._writeSnapshot();
    return h;
  }

  /// Continues a session as its next host, from this device's replica: [replica] is its tree at [seq], its last
  /// confirmed seq, and [state] is what the previous host sent it as a successor. The new host starts epoch
  /// `state.epoch + 1`, so the previous host's ops are fenced off. [recentOps] (confirmed ops this replica holds)
  /// let it answer resends of ops it already has.
  static HostCore continueSession({
    required SessionState state,
    required Schema schema,
    required CollabTree replica,
    required int seq,
    required HostStorage storage,
    required HostOutbox outbox,
    required String hostApp,
    String? hostMember,
    List<Op> recentOps = const [],
    HostSettings settings = const HostSettings(),
    PermissionPolicy policy = PermissionPolicy.standard,
    int Function()? clock,
    PasswordCheck passwordCheck = isolatePasswordCheck,
    void Function(PipelineStep)? faults,
  }) {
    if (!storage.isEmpty) throw StateError('storage already holds a session');
    if (replica.schema.hash != schema.hash) throw ArgumentError('the replica has another schema');
    final config = SessionConfig.fromJson(state.config.toJson(), hostApp: hostApp, hostMember: hostMember, keepHostMember: false);
    final h = HostCore._(
        config: config, schema: schema, storage: storage, outbox: outbox, settings: settings, policy: policy,
        clock: clock ?? _wallClock, passwordCheck: passwordCheck, faults: faults);
    h.tree = CollabTree.fromSnapshot(schema, jsonDecode(jsonEncode(replica.snapshot())), opLimits: settings.limits);
    for (final e in state.grants.entries) {
      h.permissions.set(e.key, e.value);
    }
    if (!h.permissions.isKnown(config.owner)) h.permissions.set(config.owner, Role.owner.grants);
    h._epoch = state.epoch + 1;
    h._seq = seq;
    h._epochStartSeq = seq;
    for (final op in recentOps) {
      if (op.seq != null && op.seq! <= seq) h._seenOf(op.author).record(op.clientSeq, _Outcome.ack(op.seq!, _keyOf(op)), settings.dedupeMemory);
    }
    h._lastActive = h._now;
    h._writeSnapshot();
    return h;
  }

  /// Rebuilds a host from [storage] after a crash or a restart: the latest snapshot, then every log record after
  /// it (a torn tail is cut).
  static HostCore recover({
    required Schema schema,
    required HostStorage storage,
    required HostOutbox outbox,
    HostSettings settings = const HostSettings(),
    PermissionPolicy policy = PermissionPolicy.standard,
    String? hostApp,
    int Function()? clock,
    PasswordCheck passwordCheck = isolatePasswordCheck,
    void Function(PipelineStep)? faults,
  }) {
    final bytes = storage.snapshots.read();
    if (bytes == null) throw StateError('no session snapshot is stored');
    final Map s;
    try {
      final v = parseJsonLimited(utf8.decode(bytes), maxChars: 1 << 30, maxDepth: settings.limits.maxDepth + 8);
      if (v is! Map || v['v'] != _snapshotFormat) throw const FormatException('not a host snapshot');
      s = v;
    } on Object catch (e) {
      throw StateError('the stored snapshot is unreadable: $e');
    }
    final h = HostCore._(
        config: SessionConfig.fromJson(s['config'], hostApp: hostApp), schema: schema, storage: storage, outbox: outbox,
        settings: settings, policy: policy, clock: clock ?? _wallClock, passwordCheck: passwordCheck, faults: faults);
    h._loadSnapshot(s);
    for (final r in storage.wal.recover()) {
      h._replay(r);
    }
    h._lastActive = h._now;
    return h;
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;
  int get _now => clock();

  // -------------------------------------------------------------------------------------------------------------
  // Connections

  /// A transport opened [connection] from [address] (the peer's network address, for the password rate limit).
  void connect(String connection, {required String address}) {
    _conns[connection] = _Conn(address);
    _lastActive = _now;
  }

  /// The transport lost [connection].
  void disconnect(String connection) {
    final c = _conns.remove(connection);
    _lastActive = _now;
    if (c?.member != null && _state == HostState.running) _sendSessionUpdates();
  }

  /// A message arrived as text: decoded with the limits; a malformed one ends the connection.
  Future<void> receiveText(String connection, String text) async {
    final ClientMessage m;
    try {
      m = decodeClientMessage(text, settings.limits);
    } on CollabDecodeError catch (e) {
      _refuse(connection, Refused.invalid, 'Unreadable message: ${e.message}');
      return;
    }
    await receive(connection, m);
  }

  /// A message arrived. Only a hello can wait (on the password check); everything else is handled at once.
  Future<void> receive(String connection, ClientMessage message) async {
    final c = _conns[connection];
    if (c == null) return;
    _lastActive = _now;
    if (_state == HostState.failed) throw StateError('the host failed: recover it from storage');
    if (message.epoch > _epoch && (_state == HostState.running || _state == HostState.ended)) _fence(message.epoch);
    if (_state != HostState.running) {
      if (_conns.containsKey(connection)) _refuse(connection, _closedReason, _closedMessage);
      return;
    }
    switch (message) {
      case Hello():
        await _hello(connection, c, message);
      case Submit():
        if (c.member == null) return _refuse(connection, Refused.notJoined, 'Join the session first.');
        _submit(connection, c.member!, message);
      case Resume():
        if (c.member == null) return _refuse(connection, Refused.notJoined, 'Join the session first.');
        _catchup(connection, message.fromSeq, message.epoch);
      case CreateInvite():
        if (c.member == null) return _refuse(connection, Refused.notJoined, 'Join the session first.');
        _invite(c.member!, message);
      case Bye():
        _conns.remove(connection);
        outbox.close(connection, 'bye');
        if (c.member != null) _sendSessionUpdates();
    }
  }

  String get _closedReason => switch (_state) {
        HostState.fenced => Refused.staleHost,
        HostState.ended => Refused.sessionEnded,
        _ => Refused.noSession,
      };

  String get _closedMessage => switch (_state) {
        HostState.fenced => 'This host was replaced by a newer one: reconnect to the session\'s current host.',
        HostState.ended => 'The session has ended.',
        _ => 'There is no such session here.',
      };

  void _refuse(String connection, String reason, String message) {
    outbox.send(connection, Refused(epoch: _epoch, reason: reason, message: message));
    outbox.close(connection, reason);
    final c = _conns.remove(connection);
    if (c?.member != null && _state == HostState.running) _sendSessionUpdates();
  }

  // -------------------------------------------------------------------------------------------------------------
  // Admission

  Future<void> _hello(String connection, _Conn c, Hello h) async {
    // A repeated hello (a duplicate on the wire) changes nothing; another member on the same connection is refused.
    if (c.member == h.member || c.pending) return;
    if (c.member != null) return _refuse(connection, Refused.invalid, 'Another member already joined on this connection.');
    final v = versionRefusal(version, h.version);
    if (v != null) return _refuse(connection, v.reason, v.message);
    final m = h.member;
    if (permissions.isKnown(m) && !permissions.canView(m)) {
      return _refuse(connection, Refused.removed, 'You were removed from this session.');
    }
    final others = connectedMembers..remove(m);
    if (others.length >= settings.maxMembers && m != config.owner) {
      return _refuse(connection, Refused.sessionFull, 'The session is full (${settings.maxMembers} members).');
    }
    Role? role;
    final invite = h.invite;
    if (invite != null) role = config.invites[inviteSecretHash(invite)];
    if (role == null && config.lobby == Lobby.private) {
      final pw = h.password, hash = config.password;
      if (pw == null || hash == null) {
        return _refuse(connection, Refused.wrongPassword, 'This session is private: it needs its password or an invite.');
      }
      final now = _now;
      final tries = (_tries[c.address] ??= [])..removeWhere((t) => now - t >= 60000);
      if (tries.length >= settings.passwordTriesPerMinute) {
        return _refuse(connection, Refused.rateLimited, 'Too many password tries: wait a minute and try again.');
      }
      tries.add(now);
      c.pending = true;
      final ok = await passwordCheck(hash, pw);
      c.pending = false;
      if (!identical(_conns[connection], c) || _state != HostState.running) return;
      if (!ok) return _refuse(connection, Refused.wrongPassword, 'Wrong password.');
    }
    _admit(connection, c, h, role ?? settings.defaultRole);
  }

  void _admit(String connection, _Conn c, Hello h, Role role) {
    final m = h.member;
    if (!permissions.isKnown(m)) {
      final grants = m == config.owner ? Role.owner.grants : role.grants;
      permissions.set(m, grants);
      _appendMeta({'k': 'member', 'member': m, 'grants': [for (final g in grants) g.toJson()]});
      _sync();
    }
    for (final e in _conns.entries.toList()) {
      if (e.key != connection && e.value.member == m) {
        outbox.send(e.key, Refused(epoch: _epoch, reason: Refused.replaced, message: 'You joined from another connection.'));
        outbox.close(e.key, Refused.replaced);
        _conns.remove(e.key);
      }
    }
    c.member = m;
    _scores[m] = h.score.clamp(0, 1e12).toDouble();
    outbox.send(connection, Welcome(epoch: _epoch, sessionId: config.sessionId, seq: _seq, grants: permissions.grantsOf(m), owner: config.owner));
    _catchup(connection, h.lastSeq, h.epoch);
    _sendSessionUpdates();
  }

  void _invite(String member, CreateInvite m) {
    if (!permissions.allows(tree, member, Capability.invite, rootId) || !permissions.covers(member, m.role.grants)) return;
    config.invites[m.secretHash] = m.role;
    _appendMeta({'k': 'invite', 'hash': m.secretHash, 'role': m.role.wire});
    _sync();
  }

  // -------------------------------------------------------------------------------------------------------------
  // Catch-up

  /// Sends [connection] what follows [fromSeq]: the tail when the latest snapshot covers it, otherwise the
  /// snapshot and the tail. A member from an older epoch that is past where this epoch began gets the snapshot
  /// too, since its later ops may not be this host's.
  void _catchup(String connection, int? fromSeq, int memberEpoch) {
    final crossed = memberEpoch < _epoch && fromSeq != null && fromSeq > _epochStartSeq;
    if (fromSeq != null && !crossed && fromSeq >= _snapshotSeq && fromSeq <= _seq) {
      if (fromSeq == _seq) return;
      outbox.send(connection, Catchup(epoch: _epoch, ops: [for (final o in _tail) if (o.seq! > fromSeq) o]));
      return;
    }
    outbox.send(connection, Catchup(epoch: _epoch, snapshotSeq: _snapshotSeq, snapshot: _snapshotTree, ops: List.of(_tail)));
  }

  // -------------------------------------------------------------------------------------------------------------
  // The op pipeline

  _Seen _seenOf(String member) => _seen[member] ??= _Seen();

  bool _takeToken(String member) {
    final now = _now;
    final b = _buckets[member] ??= _Bucket(settings.opBurst.toDouble(), now);
    b.tokens = min(settings.opBurst.toDouble(), b.tokens + (now - b.at) * settings.opsPerSecond / 1000);
    b.at = now;
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }

  void _step(PipelineStep s) {
    final f = faults;
    if (f == null) return;
    try {
      f(s);
    } on SimulatedCrash {
      _state = HostState.failed;
      rethrow;
    }
  }

  void _submit(String connection, String member, Submit msg) {
    _step(PipelineStep.received);
    final replies = <HostMessage>[];
    void reject(int cs, String reason, String message, {bool record = true}) {
      replies.add(Reject(epoch: _epoch, clientSeq: cs, reason: reason, message: message));
      if (record) _seenOf(member).record(cs, _Outcome.reject(reason, message), settings.dedupeMemory);
    }

    if (msg.epoch < _epoch) {
      for (final op in msg.ops) {
        reject(op.clientSeq, HostReject.staleEpoch, 'Sent to an older host (epoch ${msg.epoch}); this is epoch $_epoch.', record: false);
      }
      for (final r in replies) {
        outbox.send(connection, r);
      }
      return;
    }
    if (msg.ops.length > settings.limits.maxBatchOps) {
      for (final op in msg.ops) {
        reject(op.clientSeq, HostReject.limit, 'Over ${settings.limits.maxBatchOps} ops in one batch.', record: false);
      }
      for (final r in replies) {
        outbox.send(connection, r);
      }
      return;
    }
    final accepted = <Op>[];
    final kicked = <String>{};
    var sessionChanged = false;
    for (final op in msg.ops) {
      if (op.author != member) {
        reject(op.clientSeq, HostReject.wrongAuthor, 'An op must carry its sender as author.', record: false);
        continue;
      }
      final seen = _seenOf(member);
      final had = seen.recent[op.clientSeq];
      if (had != null) {
        replies.add(had.seq != null
            ? Ack(epoch: _epoch, clientSeq: op.clientSeq, seq: had.seq!, key: had.key)
            : Reject(epoch: _epoch, clientSeq: op.clientSeq, reason: had.reason!, message: had.message!));
        continue;
      }
      if (op.clientSeq <= seen.floor) {
        reject(op.clientSeq, HostReject.duplicate, 'Already handled long ago.', record: false);
        continue;
      }
      final size = encodeOpBinary(op).length;
      if (size > settings.limits.maxOpBytes) {
        reject(op.clientSeq, HostReject.limit, 'Over ${settings.limits.maxOpBytes} bytes.');
        continue;
      }
      if (!_takeToken(member)) {
        reject(op.clientSeq, HostReject.rateLimited, 'Too many changes at once: resend shortly.', record: false);
        continue;
      }
      final problem = opProblem(op, settings.limits);
      if (problem != null) {
        reject(op.clientSeq, OpRejected.invalid, problem);
        continue;
      }
      final denied = _permissionProblem(member, op);
      if (denied != null) {
        reject(op.clientSeq, HostReject.permission, denied);
        continue;
      }
      if (op is RestoreOp) {
        reject(op.clientSeq, HostReject.unsupported, 'Restore is not available in sessions yet.');
        continue;
      }
      var stamped = op.withHeader(seq: _seq + 1, time: _now);
      String? newKey;
      if (stamped is InsertOp) {
        final k = tree.resolveKey(stamped.parent, stamped.list, stamped.key, member);
        if (k != stamped.key) stamped = stamped.withKey(newKey = k);
      } else if (stamped is MoveOp) {
        final n = tree.node(stamped.node);
        final same = n != null && n.parent == stamped.parent && n.list == stamped.list && n.key == stamped.key;
        final k = same ? stamped.key : tree.resolveKey(stamped.parent, stamped.list, stamped.key, member);
        if (k != stamped.key) {
          stamped = MoveOp(
              node: stamped.node, parent: stamped.parent, list: stamped.list, key: newKey = k, author: stamped.author,
              clientSeq: stamped.clientSeq, baseSeq: stamped.baseSeq, seq: stamped.seq, time: stamped.time);
        }
      }
      try {
        tree.apply(stamped);
      } on OpRejected catch (e) {
        reject(op.clientSeq, e.reason, e.message);
        continue;
      }
      _seq++;
      if (stamped is AccessOp) {
        permissions.set(stamped.member, stamped.grants);
        if (!permissions.canView(stamped.member)) kicked.add(stamped.member);
        sessionChanged = true;
      }
      _tail.add(stamped);
      seen.record(op.clientSeq, _Outcome.ack(_seq, newKey), settings.dedupeMemory);
      replies.add(Ack(epoch: _epoch, clientSeq: op.clientSeq, seq: _seq, key: newKey));
      accepted.add(stamped);
    }
    _step(PipelineStep.validated);
    if (accepted.isNotEmpty) {
      for (final op in accepted) {
        _append(_recOp, encodeOpBinary(op));
      }
      _step(PipelineStep.appended);
      _sync();
      _step(PipelineStep.synced);
    }
    for (final r in replies) {
      outbox.send(connection, r);
    }
    _step(PipelineStep.acked);
    if (accepted.isNotEmpty) {
      for (final e in _conns.entries) {
        if (e.key != connection && e.value.member != null) outbox.send(e.key, Ops(epoch: _epoch, ops: accepted));
      }
      _step(PipelineStep.broadcast);
    }
    for (final e in _conns.entries.toList()) {
      if (kicked.contains(e.value.member)) {
        outbox.send(e.key, Refused(epoch: _epoch, reason: Refused.removed, message: 'You were removed from this session.'));
        outbox.close(e.key, Refused.removed);
        _conns.remove(e.key);
      }
    }
    if (sessionChanged || kicked.isNotEmpty) _sendSessionUpdates();
    if (_seq - _snapshotSeq >= settings.snapshotEveryOps) _writeSnapshot();
  }

  /// Why [member] may not make [op], or null when it may.
  String? _permissionProblem(String member, Op op) {
    for (final (cap, node) in policy.required(op, tree)) {
      if (!permissions.allows(tree, member, cap, node)) {
        return node == null ? 'You need ${cap.wire} here.' : 'You need ${cap.wire} on ${node == rootId ? 'the project' : node}.';
      }
    }
    if (op is AccessOp && op.member == config.owner && member != config.owner) {
      return 'Only the owner can change the owner\'s access.';
    }
    return null;
  }

  // -------------------------------------------------------------------------------------------------------------
  // Blobs

  /// Stores a declared blob a member uploaded: null when stored, or why not. The blob must be declared by a
  /// confirmed `blob` op with the same size.
  String? putBlob(String connection, String hash, Uint8List bytes) {
    final m = _conns[connection]?.member;
    if (m == null || _state != HostState.running) return Refused.notJoined;
    if (!permissions.holdsAnywhere(m, Capability.editContent)) return HostReject.permission;
    final declared = tree.blobs[hash];
    if (declared == null) return 'undeclared';
    if (declared.size != bytes.length) return BlobRefused.hashMismatch;
    if (bytes.length > settings.maxBlobBytes) return BlobRefused.tooLarge;
    try {
      storage.blobs.put(hash, bytes);
    } on BlobRefused catch (e) {
      return e.reason;
    }
    return null;
  }

  /// A stored blob for a member who can see the project, or null.
  Uint8List? getBlob(String connection, String hash) {
    final m = _conns[connection]?.member;
    if (m == null || !permissions.canView(m)) return null;
    return storage.blobs.get(hash);
  }

  // -------------------------------------------------------------------------------------------------------------
  // Successors, epochs and fencing

  bool _eligible(String member) => switch (settings.whoMayHost) {
        HostEligibility.anyone => permissions.canView(member),
        HostEligibility.editors => permissions.holds(member, Capability.editContent, rootId),
        HostEligibility.managers => permissions.holds(member, Capability.manageAccess, rootId),
      };

  /// The ranked successors: connected, eligible members other than the hosting device, by capability score
  /// (highest first), then by key id; empty when migration is off.
  List<Successor> get successors {
    if (!settings.migration) return const [];
    final out = [
      for (final m in connectedMembers)
        if (m != config.hostMember && _eligible(m)) Successor(m, _scores[m] ?? 0),
    ];
    out.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.member.compareTo(b.member);
    });
    return out;
  }

  /// What a successor continues from.
  SessionState get sessionState => SessionState(config: config, grants: permissions.all, epoch: _epoch, seq: _seq);

  void _sendSessionUpdates() {
    final list = successors;
    final names = {for (final s in list) s.member};
    final st = names.isEmpty ? null : sessionState;
    for (final e in _conns.entries) {
      final m = e.value.member;
      if (m == null) continue;
      outbox.send(e.key, SessionUpdate(epoch: _epoch, successors: list, state: names.contains(m) ? st : null));
    }
  }

  void _fence(int newer) {
    if (_state == HostState.fenced) return;
    _state = HostState.fenced;
    try {
      _appendMeta({'k': 'fenced', 'epoch': newer});
      _sync();
    } on Object {
      // A failed log leaves the host failed; it accepts nothing either way.
    }
    for (final id in _conns.keys.toList()) {
      outbox.send(id, Refused(epoch: _epoch, reason: Refused.staleHost, message: _closedMessage));
      outbox.close(id, Refused.staleHost);
    }
    _conns.clear();
  }

  // -------------------------------------------------------------------------------------------------------------
  // Time, the session's end and the cache

  /// Housekeeping, called now and then: a snapshot after [HostSettings.snapshotEveryMs] with ops since the last
  /// one, and the purge of a cache left idle or ended past the resume window. Returns whether it purged.
  bool tick() {
    final now = _now;
    if (_state == HostState.running && _seq > _snapshotSeq && now - _lastSnapshotAt >= settings.snapshotEveryMs) {
      _writeSnapshot();
    }
    if (expired) {
      purge();
      return true;
    }
    return false;
  }

  /// Whether the cache has outlived the resume window: ended, or with nobody connected, for that long.
  bool get expired {
    if (_state == HostState.purged || _state == HostState.failed) return false;
    final since = _state == HostState.ended ? (_endedAt ?? _lastActive) : _lastActive;
    return (_state == HostState.ended || _conns.isEmpty) && _now - since >= settings.resumeWindowMs;
  }

  /// Ends the session: a final snapshot, everyone disconnected, the cache kept for the resume window.
  void end() {
    if (_state != HostState.running) return;
    _endedAt = _now;
    _appendMeta({'k': 'ended', 'at': _endedAt});
    _sync();
    _state = HostState.ended;
    _writeSnapshot();
    for (final id in _conns.keys.toList()) {
      outbox.send(id, Refused(epoch: _epoch, reason: Refused.sessionEnded, message: 'The session has ended.'));
      outbox.close(id, Refused.sessionEnded);
    }
    _conns.clear();
  }

  /// Opens an ended session again within its resume window.
  void reopen() {
    if (_state != HostState.ended) throw StateError('the session has not ended');
    _endedAt = null;
    _state = HostState.running;
    _appendMeta({'k': 'reopened'});
    _sync();
    _lastActive = _now;
  }

  /// Deletes the session's cache (its snapshot, log and blobs) and closes every connection.
  void purge() {
    for (final id in _conns.keys.toList()) {
      outbox.send(id, Refused(epoch: _epoch, reason: Refused.noSession, message: 'The session is over.'));
      outbox.close(id, Refused.noSession);
    }
    _conns.clear();
    storage.purge();
    _state = HostState.purged;
  }

  // -------------------------------------------------------------------------------------------------------------
  // Storage

  void _append(int type, List<int> body) {
    _lsn++;
    final rec = Uint8List(9 + body.length);
    rec[0] = type;
    ByteData.sublistView(rec).setUint64(1, _lsn, Endian.little);
    rec.setRange(9, rec.length, body);
    try {
      storage.wal.append(rec);
    } on Object {
      _state = HostState.failed;
      rethrow;
    }
  }

  void _appendMeta(Map<String, Object?> meta) => _append(_recMeta, utf8.encode(jsonEncode(meta)));

  void _sync() {
    try {
      storage.wal.sync();
    } on Object {
      _state = HostState.failed;
      rethrow;
    }
  }

  void _writeSnapshot() {
    final treeSnap = jsonDecode(jsonEncode(tree.snapshot())) as Map<String, Object?>;
    final snap = {
      'v': _snapshotFormat,
      'config': config.toJson(),
      'epoch': _epoch,
      'epochStartSeq': _epochStartSeq,
      'seq': _seq,
      'lsn': _lsn,
      'state': _state.name,
      if (_endedAt != null) 'endedAt': _endedAt,
      'grants': {for (final e in permissions.all.entries) e.key: [for (final g in e.value) g.toJson()]},
      'seen': {
        for (final e in _seen.entries)
          e.key: {'floor': e.value.floor, 'recent': {for (final r in e.value.recent.entries) '${r.key}': r.value.toJson()}},
      },
      'tree': treeSnap,
    };
    try {
      storage.snapshots.write(Uint8List.fromList(utf8.encode(jsonEncode(snap))));
    } on Object {
      _state = HostState.failed;
      rethrow;
    }
    _step(PipelineStep.snapshotWritten);
    _snapshotSeq = _seq;
    _snapshotLsn = _lsn;
    _snapshotTree = treeSnap;
    _tail.clear();
    _lastSnapshotAt = _now;
    try {
      storage.wal.reset();
    } on Object {
      _state = HostState.failed;
      rethrow;
    }
    _step(PipelineStep.walReset);
  }

  void _loadSnapshot(Map s) {
    try {
      final treeSnap = s['tree'];
      tree = CollabTree.fromSnapshot(schema, treeSnap, opLimits: settings.limits);
      _snapshotTree = jsonDecode(jsonEncode(treeSnap)) as Map<String, Object?>;
      _epoch = s['epoch'] as int;
      _epochStartSeq = s['epochStartSeq'] as int;
      _seq = _snapshotSeq = s['seq'] as int;
      _lsn = _snapshotLsn = s['lsn'] as int;
      _state = HostState.values.byName(s['state'] as String);
      _endedAt = s['endedAt'] as int?;
      for (final e in grantsFromJson(s['grants'] as Map).entries) {
        permissions.set(e.key, e.value);
      }
      for (final e in (s['seen'] as Map).entries) {
        final v = e.value as Map;
        final seen = _seenOf(e.key as String)..floor = v['floor'] as int;
        for (final r in (v['recent'] as Map).entries) {
          seen.recent[int.parse(r.key as String)] = _Outcome.fromJson(r.value as Map);
        }
      }
    } on Object catch (e) {
      throw StateError('the stored snapshot is malformed: $e');
    }
    _lastSnapshotAt = _now;
  }

  void _replay(Uint8List r) {
    if (r.length < 9) throw StateError('a log record is too short');
    final lsn = ByteData.sublistView(r).getUint64(1, Endian.little);
    if (lsn <= _snapshotLsn) return;
    _lsn = lsn;
    final body = Uint8List.sublistView(r, 9);
    switch (r[0]) {
      case _recOp:
        final op = decodeOpBinary(body, settings.limits);
        if (op.seq != _seq + 1) throw StateError('the log skips from seq $_seq to ${op.seq}');
        tree.apply(op);
        _seq = op.seq!;
        if (op is AccessOp) permissions.set(op.member, op.grants);
        _tail.add(op);
        _seenOf(op.author).record(op.clientSeq, _Outcome.ack(op.seq!, _keyOf(op)), settings.dedupeMemory);
      case _recMeta:
        final m = jsonDecode(utf8.decode(body)) as Map;
        switch (m['k']) {
          case 'member':
            permissions.set(m['member'] as String, [for (final g in m['grants'] as List) grantFromJson(g)]);
          case 'invite':
            config.invites[m['hash'] as String] = Role.byWire(m['role'] as String)!;
          case 'fenced':
            _state = HostState.fenced;
          case 'ended':
            _state = HostState.ended;
            _endedAt = m['at'] as int;
          case 'reopened':
            _state = HostState.running;
            _endedAt = null;
        }
      default:
        throw StateError('an unknown log record ${r[0]}');
    }
  }
}
