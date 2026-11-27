// The edit operations on the shared tree (set, insert, move, delete, revive, text, blob, access, checkpoint,
// restore), their common header and the structural checks a decoded op must pass.
import 'fractional_key.dart';
import 'ids.dart';
import 'limits.dart';
import 'values.dart';

/// The op kinds, with their names in JSON and their numbers in the binary codec (never reused).
enum OpType {
  set('set', 1),
  insert('insert', 2),
  move('move', 3),
  delete('delete', 4),
  revive('revive', 5),
  text('text', 6),
  blob('blob', 7),
  access('access', 8),
  checkpoint('checkpoint', 9),
  restore('restore', 10);

  const OpType(this.wire, this.code);
  final String wire;
  final int code;

  static OpType? byWire(String wire) {
    for (final t in values) {
      if (t.wire == wire) return t;
    }
    return null;
  }

  static OpType? byCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// The capabilities an `access` op grants, with their wire names.
///
/// Assumption: the design's capability table is the list; its conflict table also names `project_settings` for
/// tempo edits, which the capability table calls `routing_settings`, so only `routing_settings` is here.
enum Capability {
  view('view'),
  editContent('edit_content'),
  addRemoveTracks('add_remove_tracks'),
  routingSettings('routing_settings'),
  editCode('edit_code'),
  renderExport('render_export'),
  publish('publish'),
  invite('invite'),
  manageAccess('manage_access'),
  reviewProposals('review_proposals');

  const Capability(this.wire);
  final String wire;

  static Capability? byWire(String wire) {
    for (final c in values) {
      if (c.wire == wire) return c;
    }
    return null;
  }
}

/// One capability on one scope: a node id, [rootId] for the whole project.
class Grant {
  const Grant(this.capability, this.scope);
  final Capability capability;
  final String scope;

  Map<String, Object?> toJson() => {'capability': capability.wire, 'scope': scope};
}

/// The most bytes a blob may declare: the project package's 1 GiB cap per audio file.
const int maxBlobBytes = 1 << 30;

/// One operation. Every op carries its [author] (the device key id), the author's [clientSeq] and the host
/// sequence it was made against ([baseSeq]); the host adds [seq] and [time] (milliseconds since the epoch).
///
/// Assumption: the design's header is `{op, node, …, author, clientSeq, baseSeq}` with `seq` and the time added
/// by the host; ops that name no node (blob, access, checkpoint, restore) carry none, and the time is an integer
/// count of milliseconds. Undo and restore tags (`undoOf`, `restoreOf`) arrive with the steps that use them.
sealed class Op {
  const Op({required this.author, required this.clientSeq, required this.baseSeq, this.seq, this.time});

  final String author;
  final int clientSeq;
  final int baseSeq;
  final int? seq;
  final int? time;

  OpType get type;

  /// The op's own fields, without the header.
  Map<String, Object?> bodyJson();

  /// The same op with another header (the host stamps [seq] and [time]; an inverse takes a new [clientSeq]).
  Op withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time});

  /// The op as a JSON map: `op`, the header, then the body.
  Map<String, Object?> toJson() => {
        'op': type.wire,
        'author': author,
        'clientSeq': clientSeq,
        'baseSeq': baseSeq,
        if (seq != null) 'seq': seq,
        if (time != null) 'time': time,
        ...bodyJson(),
      };

  @override
  bool operator ==(Object other) => other is Op && canonicalJson(other.toJson()) == canonicalJson(toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;

  @override
  String toString() => canonicalJson(toJson());
}

/// Replace one field; a coarse node has one field, `json`. A null value clears the field.
final class SetOp extends Op {
  const SetOp({required this.node, required this.field, required this.value, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String node;
  final String field;
  final Object? value;

  @override
  OpType get type => OpType.set;
  @override
  Map<String, Object?> bodyJson() => {'node': node, 'field': field, 'value': value};
  @override
  SetOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => SetOp(
      node: node, field: field, value: value, author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq,
      baseSeq: baseSeq ?? this.baseSeq, seq: seq ?? this.seq, time: time ?? this.time);
}

/// A new node of [kind] in [parent]'s [list] at fractional [key], with its initial [fields].
final class InsertOp extends Op {
  const InsertOp({required this.parent, required this.list, required this.node, required this.key, required this.kind, this.fields = const {}, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String parent;
  final String list;
  final String node;
  final String key;
  final String kind;
  final Map<String, Object?> fields;

  @override
  OpType get type => OpType.insert;
  @override
  Map<String, Object?> bodyJson() => {'parent': parent, 'list': list, 'node': node, 'key': key, 'kind': kind, 'fields': fields};
  @override
  InsertOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => InsertOp(
      parent: parent, list: list, node: node, key: key, kind: kind, fields: fields, author: author ?? this.author,
      clientSeq: clientSeq ?? this.clientSeq, baseSeq: baseSeq ?? this.baseSeq, seq: seq ?? this.seq, time: time ?? this.time);

  /// This insert at another key (the host's tie-break).
  InsertOp withKey(String key) => InsertOp(
      parent: parent, list: list, node: node, key: key, kind: kind, fields: fields, author: author,
      clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
}

/// Parent, list and position as one property.
final class MoveOp extends Op {
  const MoveOp({required this.node, required this.parent, required this.list, required this.key, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String node;
  final String parent;
  final String list;
  final String key;

  @override
  OpType get type => OpType.move;
  @override
  Map<String, Object?> bodyJson() => {'node': node, 'parent': parent, 'list': list, 'key': key};
  @override
  MoveOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => MoveOp(
      node: node, parent: parent, list: list, key: key, author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq,
      baseSeq: baseSeq ?? this.baseSeq, seq: seq ?? this.seq, time: time ?? this.time);
}

/// A tombstone: the node and its subtree are hidden, kept until compaction.
final class DeleteOp extends Op {
  const DeleteOp({required this.node, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String node;

  @override
  OpType get type => OpType.delete;
  @override
  Map<String, Object?> bodyJson() => {'node': node};
  @override
  DeleteOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => DeleteOp(
      node: node, author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq, baseSeq: baseSeq ?? this.baseSeq,
      seq: seq ?? this.seq, time: time ?? this.time);
}

/// Clear a tombstone: the subtree comes back as it was.
final class ReviveOp extends Op {
  const ReviveOp({required this.node, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String node;

  @override
  OpType get type => OpType.revive;
  @override
  Map<String, Object?> bodyJson() => {'node': node};
  @override
  ReviveOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => ReviveOp(
      node: node, author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq, baseSeq: baseSeq ?? this.baseSeq,
      seq: seq ?? this.seq, time: time ?? this.time);
}

/// A whole text (a pattern's source, a C++ file), last writer wins, under soft lock [lockEpoch].
///
/// Assumption: the tree stores only the text; checking [lockEpoch] against the current lease is the host's job,
/// which comes with the session steps.
final class TextOp extends Op {
  const TextOp({required this.node, required this.field, required this.value, required this.lockEpoch, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String node;
  final String field;
  final String value;
  final int lockEpoch;

  @override
  OpType get type => OpType.text;
  @override
  Map<String, Object?> bodyJson() => {'node': node, 'field': field, 'value': value, 'lockEpoch': lockEpoch};
  @override
  TextOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => TextOp(
      node: node, field: field, value: value, lockEpoch: lockEpoch, author: author ?? this.author,
      clientSeq: clientSeq ?? this.clientSeq, baseSeq: baseSeq ?? this.baseSeq, seq: seq ?? this.seq, time: time ?? this.time);
}

/// Declare an asset by content: its SHA-256 and metadata.
///
/// Assumption: [format] is a short name (such as `wav`), and the audio fields are absent for a file that isn't
/// audio; the design lists "sha256, size, format, channels, rate, frames" without types.
final class BlobOp extends Op {
  const BlobOp({required this.hash, required this.size, required this.format, this.channels, this.rate, this.frames, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String hash;
  final int size;
  final String format;
  final int? channels;
  final int? rate;
  final int? frames;

  @override
  OpType get type => OpType.blob;
  @override
  Map<String, Object?> bodyJson() => {
        'hash': hash,
        'size': size,
        'format': format,
        if (channels != null) 'channels': channels,
        if (rate != null) 'rate': rate,
        if (frames != null) 'frames': frames,
      };
  @override
  BlobOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => BlobOp(
      hash: hash, size: size, format: format, channels: channels, rate: rate, frames: frames,
      author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq, baseSeq: baseSeq ?? this.baseSeq,
      seq: seq ?? this.seq, time: time ?? this.time);
}

/// Replace [member]'s capabilities with [grants].
final class AccessOp extends Op {
  const AccessOp({required this.member, required this.grants, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String member;
  final List<Grant> grants;

  @override
  OpType get type => OpType.access;
  @override
  Map<String, Object?> bodyJson() => {'member': member, 'grants': [for (final g in grants) g.toJson()]};
  @override
  AccessOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => AccessOp(
      member: member, grants: grants, author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq,
      baseSeq: baseSeq ?? this.baseSeq, seq: seq ?? this.seq, time: time ?? this.time);
}

/// Mark a named revision (a restore point).
final class CheckpointOp extends Op {
  const CheckpointOp({required this.label, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final String label;

  @override
  OpType get type => OpType.checkpoint;
  @override
  Map<String, Object?> bodyJson() => {'label': label};
  @override
  CheckpointOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => CheckpointOp(
      label: label, author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq, baseSeq: baseSeq ?? this.baseSeq,
      seq: seq ?? this.seq, time: time ?? this.time);
}

/// Go back to the state at [checkpointSeq]; the host expands it into ordinary ops.
final class RestoreOp extends Op {
  const RestoreOp({required this.checkpointSeq, required super.author, required super.clientSeq, required super.baseSeq, super.seq, super.time});
  final int checkpointSeq;

  @override
  OpType get type => OpType.restore;
  @override
  Map<String, Object?> bodyJson() => {'checkpointSeq': checkpointSeq};
  @override
  RestoreOp withHeader({String? author, int? clientSeq, int? baseSeq, int? seq, int? time}) => RestoreOp(
      checkpointSeq: checkpointSeq, author: author ?? this.author, clientSeq: clientSeq ?? this.clientSeq,
      baseSeq: baseSeq ?? this.baseSeq, seq: seq ?? this.seq, time: time ?? this.time);
}

final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// The longest checkpoint label and blob format, in UTF-8 bytes.
///
/// Assumption: the design sets no lengths; a label is a short name and a format a file-type word.
const int maxLabelBytes = 256;
const int maxFormatBytes = 32;

/// Why [op] is malformed or over [limits], or null when it is well-formed. This is structure only: whether the
/// op fits the tree and the schema is the tree's check.
String? opProblem(Op op, [CollabLimits limits = CollabLimits.standard]) {
  if (!AuthorIds.isValid(op.author)) return 'author is not an author id';
  if (op.clientSeq < 0 || op.baseSeq < 0) return 'a negative sequence number';
  if ((op.seq ?? 0) < 0 || (op.time ?? 0) < 0) return 'a negative seq or time';
  String? node(String id, String what) => NodeIds.isValid(id) ? null : '$what is not a node id';
  String? name(String n, String what) => isValidName(n) ? null : '$what is not a name';
  String? key(String k) => FractionalKeys.isValid(k, maxLength: limits.maxKeyLength) ? null : 'key is not a fractional key';
  switch (op) {
    case SetOp():
      return node(op.node, 'node') ?? name(op.field, 'field') ?? valueProblem(op.value, limits);
    case InsertOp():
      if (op.node == rootId) return 'the root cannot be inserted';
      if (op.fields.length > limits.maxFields) return 'over ${limits.maxFields} fields';
      for (final e in op.fields.entries) {
        final p = name(e.key, 'a field') ?? valueProblem(e.value, limits);
        if (p != null) return p;
      }
      return node(op.parent, 'parent') ?? name(op.list, 'list') ?? node(op.node, 'node') ?? key(op.key) ?? name(op.kind, 'kind');
    case MoveOp():
      return node(op.node, 'node') ?? node(op.parent, 'parent') ?? name(op.list, 'list') ?? key(op.key);
    case DeleteOp():
      return node(op.node, 'node');
    case ReviveOp():
      return node(op.node, 'node');
    case TextOp():
      if (op.lockEpoch < 0) return 'a negative lock epoch';
      return node(op.node, 'node') ?? name(op.field, 'field') ?? valueProblem(op.value, limits);
    case BlobOp():
      if (!_sha256Hex.hasMatch(op.hash)) return 'hash is not a SHA-256 in lowercase hex';
      if (op.size < 0 || op.size > maxBlobBytes) return 'size is outside 0..$maxBlobBytes';
      if (op.format.isEmpty) return 'format is empty';
      final f = stringProblem(op.format, maxFormatBytes);
      if (f != null) return 'format: $f';
      if ((op.channels ?? 1) < 1 || (op.rate ?? 1) < 1 || (op.frames ?? 0) < 0) return 'audio metadata out of range';
      return null;
    case AccessOp():
      if (!AuthorIds.isValid(op.member)) return 'member is not an author id';
      if (op.grants.length > limits.maxEntries) return 'over ${limits.maxEntries} grants';
      for (final g in op.grants) {
        final p = node(g.scope, 'a grant scope');
        if (p != null) return p;
      }
      return null;
    case CheckpointOp():
      final l = stringProblem(op.label, maxLabelBytes);
      return l == null ? null : 'label: $l';
    case RestoreOp():
      return op.checkpointSeq < 0 ? 'a negative checkpoint seq' : null;
  }
}
