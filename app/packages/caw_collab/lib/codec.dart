// The ops' two encodings, binary for the wire and logs and JSON for reading: encoders, and decoders that treat
// their input as untrusted and throw nothing but CollabDecodeError.
import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart';
import 'ops.dart';

// ---------------------------------------------------------------------------------------------------------------
// JSON

/// One op as JSON text.
String encodeOpJson(Op op) => jsonEncode(op.toJson());

/// A batch of ops as a JSON array.
String encodeBatchJson(List<Op> ops) => jsonEncode([for (final op in ops) op.toJson()]);

/// Decodes one op from untrusted JSON [text].
Op decodeOpJson(String text, [CollabLimits limits = CollabLimits.standard]) =>
    opFromJson(_parseJson(text, limits, 0), limits);

/// Decodes a batch from untrusted JSON [text].
List<Op> decodeBatchJson(String text, [CollabLimits limits = CollabLimits.standard]) {
  final v = _parseJson(text, limits, 1);
  if (v is! List) throw const CollabDecodeError('a batch is not a JSON array');
  if (v.length > limits.maxBatchOps) throw CollabDecodeError('a batch over ${limits.maxBatchOps} ops');
  return [for (final e in v) opFromJson(e, limits)];
}

// The op map, its fields map and a grant add up to 3 levels above a value's own nesting; a batch adds one more.
Object? _parseJson(String text, CollabLimits limits, int extraDepth) {
  if (text.length > limits.maxOpBytes) throw CollabDecodeError('over ${limits.maxOpBytes} characters');
  // Bound the nesting before the parser sees it, so a deep input can't exhaust the stack.
  final most = limits.maxDepth + 3 + extraDepth;
  var depth = 0;
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (c == 0x5c) {
        i++;
      } else if (c == 0x22) {
        inString = false;
      }
    } else if (c == 0x22) {
      inString = true;
    } else if (c == 0x5b || c == 0x7b) {
      if (++depth > most) throw CollabDecodeError('nesting deeper than ${limits.maxDepth}');
    } else if (c == 0x5d || c == 0x7d) {
      depth--;
    }
  }
  try {
    return jsonDecode(text);
  } on FormatException catch (e) {
    throw CollabDecodeError('not JSON: ${e.message}');
  }
}

/// Reads one op from an already-decoded, untrusted JSON value. Unknown keys are refused.
///
/// Assumption: ops are strict (the tree keeps unknown node fields, but an op's own keys are a fixed set).
Op opFromJson(Object? json, [CollabLimits limits = CollabLimits.standard]) {
  if (json is! Map) throw const CollabDecodeError('an op is not a JSON object');
  final m = json;
  final type = OpType.byWire(_str(m, 'op'));
  if (type == null) throw CollabDecodeError('unknown op ${m['op']}');
  final known = <String>{'op', 'author', 'clientSeq', 'baseSeq', 'seq', 'time', ..._bodyKeys[type]!};
  for (final k in m.keys) {
    if (!known.contains(k)) throw CollabDecodeError('unknown key $k in a ${type.wire} op');
  }
  final author = _str(m, 'author');
  final clientSeq = _int(m, 'clientSeq');
  final baseSeq = _int(m, 'baseSeq');
  final seq = _optInt(m, 'seq');
  final time = _optInt(m, 'time');
  final Op op;
  switch (type) {
    case OpType.set:
      if (!m.containsKey('value')) throw const CollabDecodeError('set has no value');
      op = SetOp(node: _str(m, 'node'), field: _str(m, 'field'), value: m['value'], author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.insert:
      final f = m['fields'];
      if (f is! Map) throw const CollabDecodeError('insert fields is not an object');
      final fields = <String, Object?>{};
      for (final e in f.entries) {
        final k = e.key;
        if (k is! String) throw const CollabDecodeError('an insert field name is not a string');
        fields[k] = e.value;
      }
      op = InsertOp(
          parent: _str(m, 'parent'), list: _str(m, 'list'), node: _str(m, 'node'), key: _str(m, 'key'), kind: _str(m, 'kind'),
          fields: fields, author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.move:
      op = MoveOp(node: _str(m, 'node'), parent: _str(m, 'parent'), list: _str(m, 'list'), key: _str(m, 'key'), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.delete:
      op = DeleteOp(node: _str(m, 'node'), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.revive:
      op = ReviveOp(node: _str(m, 'node'), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.text:
      op = TextOp(node: _str(m, 'node'), field: _str(m, 'field'), value: _str(m, 'value'), lockEpoch: _int(m, 'lockEpoch'), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.blob:
      op = BlobOp(
          hash: _str(m, 'hash'), size: _int(m, 'size'), format: _str(m, 'format'), channels: _optInt(m, 'channels'),
          rate: _optInt(m, 'rate'), frames: _optInt(m, 'frames'), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.access:
      final g = m['grants'];
      if (g is! List) throw const CollabDecodeError('access grants is not an array');
      if (g.length > limits.maxEntries) throw CollabDecodeError('over ${limits.maxEntries} grants');
      final grants = <Grant>[];
      for (final e in g) {
        if (e is! Map || e.length != 2) throw const CollabDecodeError('a grant is not {capability, scope}');
        final c = Capability.byWire(_str(e, 'capability'));
        if (c == null) throw CollabDecodeError('unknown capability ${e['capability']}');
        grants.add(Grant(c, _str(e, 'scope')));
      }
      op = AccessOp(member: _str(m, 'member'), grants: grants, author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.checkpoint:
      op = CheckpointOp(label: _str(m, 'label'), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.restore:
      op = RestoreOp(checkpointSeq: _int(m, 'checkpointSeq'), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
  }
  return _checked(op, limits);
}

const _bodyKeys = <OpType, List<String>>{
  OpType.set: ['node', 'field', 'value'],
  OpType.insert: ['parent', 'list', 'node', 'key', 'kind', 'fields'],
  OpType.move: ['node', 'parent', 'list', 'key'],
  OpType.delete: ['node'],
  OpType.revive: ['node'],
  OpType.text: ['node', 'field', 'value', 'lockEpoch'],
  OpType.blob: ['hash', 'size', 'format', 'channels', 'rate', 'frames'],
  OpType.access: ['member', 'grants'],
  OpType.checkpoint: ['label'],
  OpType.restore: ['checkpointSeq'],
};

String _str(Map m, String k) {
  final v = m[k];
  if (v is! String) throw CollabDecodeError('$k is not a string');
  return v;
}

int _int(Map m, String k) {
  final v = m[k];
  if (v is! int) throw CollabDecodeError('$k is not an integer');
  return v;
}

int? _optInt(Map m, String k) => m.containsKey(k) ? _int(m, k) : null;

Op _checked(Op op, CollabLimits limits) {
  final p = opProblem(op, limits);
  if (p != null) throw CollabDecodeError('${op.type.wire}: $p');
  return op;
}

// ---------------------------------------------------------------------------------------------------------------
// Binary
//
// Assumption: the design asks for a binary codec without a layout; this one is the simplest that is compact and
// self-delimiting. All integers are unsigned LEB128 varints of at most 9 bytes (63 bits).
//
//   op     := 0x01 body                          batch := 0x02 count body*
//   body   := type:u8 author:str clientSeq baseSeq flags:u8 [seq] [time] fields-of-type
//             (flags bit 0: seq present, bit 1: time present)
//   str    := length utf8-bytes
//   value  := 0 null | 1 false | 2 true | 3 n (int n >= 0) | 4 n (int -(n+1)) | 5 float64-LE
//           | 6 str | 7 count value* | 8 count (str value)*
//   insert fields := count (str value)*;  blob := hash size format flags:u8 [channels] [rate] [frames]
//   access := member count (capability:str scope:str)*

const int _opMagic = 0x01;
const int _batchMagic = 0x02;

/// One op in the binary encoding.
Uint8List encodeOpBinary(Op op) {
  final w = _Writer()..byte(_opMagic);
  _writeOp(w, op);
  return w.take();
}

/// A batch of ops in the binary encoding.
Uint8List encodeBatchBinary(List<Op> ops) {
  final w = _Writer()
    ..byte(_batchMagic)
    ..uint(ops.length);
  for (final op in ops) {
    _writeOp(w, op);
  }
  return w.take();
}

/// Decodes one op from untrusted [bytes].
Op decodeOpBinary(Uint8List bytes, [CollabLimits limits = CollabLimits.standard]) {
  final r = _Reader(bytes, limits);
  if (r.byte() != _opMagic) throw const CollabDecodeError('not a binary op');
  final op = _readOp(r);
  r.end();
  return op;
}

/// Decodes a batch from untrusted [bytes].
List<Op> decodeBatchBinary(Uint8List bytes, [CollabLimits limits = CollabLimits.standard]) {
  final r = _Reader(bytes, limits);
  if (r.byte() != _batchMagic) throw const CollabDecodeError('not a binary batch');
  final n = r.count(limits.maxBatchOps, 'a batch');
  final ops = [for (var i = 0; i < n; i++) _readOp(r)];
  r.end();
  return ops;
}

void _writeOp(_Writer w, Op op) {
  w
    ..byte(op.type.code)
    ..str(op.author)
    ..uint(op.clientSeq)
    ..uint(op.baseSeq)
    ..byte((op.seq != null ? 1 : 0) | (op.time != null ? 2 : 0));
  if (op.seq != null) w.uint(op.seq!);
  if (op.time != null) w.uint(op.time!);
  switch (op) {
    case SetOp():
      w
        ..str(op.node)
        ..str(op.field)
        ..value(op.value);
    case InsertOp():
      w
        ..str(op.parent)
        ..str(op.list)
        ..str(op.node)
        ..str(op.key)
        ..str(op.kind)
        ..uint(op.fields.length);
      for (final e in op.fields.entries) {
        w
          ..str(e.key)
          ..value(e.value);
      }
    case MoveOp():
      w
        ..str(op.node)
        ..str(op.parent)
        ..str(op.list)
        ..str(op.key);
    case DeleteOp():
      w.str(op.node);
    case ReviveOp():
      w.str(op.node);
    case TextOp():
      w
        ..str(op.node)
        ..str(op.field)
        ..str(op.value)
        ..uint(op.lockEpoch);
    case BlobOp():
      w
        ..str(op.hash)
        ..uint(op.size)
        ..str(op.format)
        ..byte((op.channels != null ? 1 : 0) | (op.rate != null ? 2 : 0) | (op.frames != null ? 4 : 0));
      if (op.channels != null) w.uint(op.channels!);
      if (op.rate != null) w.uint(op.rate!);
      if (op.frames != null) w.uint(op.frames!);
    case AccessOp():
      w
        ..str(op.member)
        ..uint(op.grants.length);
      for (final g in op.grants) {
        w
          ..str(g.capability.wire)
          ..str(g.scope);
      }
    case CheckpointOp():
      w.str(op.label);
    case RestoreOp():
      w.uint(op.checkpointSeq);
  }
}

Op _readOp(_Reader r) {
  final type = OpType.byCode(r.byte());
  if (type == null) throw const CollabDecodeError('unknown op type');
  final author = r.str();
  final clientSeq = r.uint();
  final baseSeq = r.uint();
  final flags = r.byte();
  if (flags & ~3 != 0) throw const CollabDecodeError('unknown header flags');
  final seq = flags & 1 != 0 ? r.uint() : null;
  final time = flags & 2 != 0 ? r.uint() : null;
  final Op op;
  switch (type) {
    case OpType.set:
      op = SetOp(node: r.str(), field: r.str(), value: r.value(0), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.insert:
      final parent = r.str(), list = r.str(), node = r.str(), key = r.str(), kind = r.str();
      final n = r.count(r.limits.maxFields, 'insert fields');
      final fields = <String, Object?>{};
      for (var i = 0; i < n; i++) {
        final k = r.str();
        if (fields.containsKey(k)) throw CollabDecodeError('field $k twice');
        fields[k] = r.value(0);
      }
      op = InsertOp(parent: parent, list: list, node: node, key: key, kind: kind, fields: fields, author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.move:
      op = MoveOp(node: r.str(), parent: r.str(), list: r.str(), key: r.str(), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.delete:
      op = DeleteOp(node: r.str(), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.revive:
      op = ReviveOp(node: r.str(), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.text:
      op = TextOp(node: r.str(), field: r.str(), value: r.str(), lockEpoch: r.uint(), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.blob:
      final hash = r.str(), size = r.uint(), format = r.str();
      final f = r.byte();
      if (f & ~7 != 0) throw const CollabDecodeError('unknown blob flags');
      op = BlobOp(
          hash: hash, size: size, format: format, channels: f & 1 != 0 ? r.uint() : null, rate: f & 2 != 0 ? r.uint() : null,
          frames: f & 4 != 0 ? r.uint() : null, author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.access:
      final member = r.str();
      final n = r.count(r.limits.maxEntries, 'grants');
      final grants = <Grant>[];
      for (var i = 0; i < n; i++) {
        final c = Capability.byWire(r.str());
        if (c == null) throw const CollabDecodeError('unknown capability');
        grants.add(Grant(c, r.str()));
      }
      op = AccessOp(member: member, grants: grants, author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.checkpoint:
      op = CheckpointOp(label: r.str(), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
    case OpType.restore:
      op = RestoreOp(checkpointSeq: r.uint(), author: author, clientSeq: clientSeq, baseSeq: baseSeq, seq: seq, time: time);
  }
  return _checked(op, r.limits);
}

class _Writer {
  final _b = BytesBuilder(copy: false);
  final _f64 = ByteData(8);

  void byte(int b) => _b.addByte(b);

  void uint(int n) {
    if (n < 0) throw ArgumentError.value(n, 'n', 'negative');
    while (n >= 0x80) {
      _b.addByte((n & 0x7f) | 0x80);
      n >>= 7;
    }
    _b.addByte(n);
  }

  void str(String s) {
    final bytes = utf8.encode(s);
    uint(bytes.length);
    _b.add(bytes);
  }

  void value(Object? v) {
    switch (v) {
      case null:
        byte(0);
      case false:
        byte(1);
      case true:
        byte(2);
      case int n when n >= 0:
        byte(3);
        uint(n);
      case int n:
        byte(4);
        uint(-(n + 1));
      case double d:
        byte(5);
        _f64.setFloat64(0, d, Endian.little);
        _b.add(_f64.buffer.asUint8List(0, 8).toList());
      case String s:
        byte(6);
        str(s);
      case List l:
        byte(7);
        uint(l.length);
        for (final e in l) {
          value(e);
        }
      case Map m:
        byte(8);
        uint(m.length);
        for (final e in m.entries) {
          str(e.key as String);
          value(e.value);
        }
      default:
        throw ArgumentError.value(v, 'value', 'not a JSON value');
    }
  }

  Uint8List take() => _b.takeBytes();
}

class _Reader {
  _Reader(this.bytes, this.limits) {
    if (bytes.length > limits.maxOpBytes) throw CollabDecodeError('over ${limits.maxOpBytes} bytes');
  }

  final Uint8List bytes;
  final CollabLimits limits;
  int _pos = 0;

  int byte() {
    if (_pos >= bytes.length) throw const CollabDecodeError('unexpected end');
    return bytes[_pos++];
  }

  int uint() {
    var n = 0;
    for (var i = 0; i < 9; i++) {
      final b = byte();
      n |= (b & 0x7f) << (7 * i);
      if (b & 0x80 == 0) {
        if (i > 0 && b == 0) throw const CollabDecodeError('a varint with a needless byte');
        return n;
      }
    }
    throw const CollabDecodeError('a varint over 63 bits');
  }

  // A count, bounded by [most] and by the bytes left (every entry takes at least one).
  int count(int most, String what) {
    final n = uint();
    if (n > most) throw CollabDecodeError('$what over $most entries');
    if (n > bytes.length - _pos) throw CollabDecodeError('$what longer than the input');
    return n;
  }

  String str() {
    final n = uint();
    if (n > limits.maxStringBytes) throw CollabDecodeError('a string over ${limits.maxStringBytes} bytes');
    if (n > bytes.length - _pos) throw const CollabDecodeError('a string past the end');
    final start = _pos;
    _pos += n;
    try {
      return utf8.decode(Uint8List.sublistView(bytes, start, _pos));
    } on FormatException {
      throw const CollabDecodeError('a string that is not UTF-8');
    }
  }

  Object? value(int depth) {
    switch (byte()) {
      case 0:
        return null;
      case 1:
        return false;
      case 2:
        return true;
      case 3:
        return uint();
      case 4:
        return -uint() - 1;
      case 5:
        if (bytes.length - _pos < 8) throw const CollabDecodeError('a number past the end');
        final d = ByteData.sublistView(bytes, _pos, _pos + 8).getFloat64(0, Endian.little);
        _pos += 8;
        if (!d.isFinite) throw const CollabDecodeError('a number that is not finite');
        return d;
      case 6:
        return str();
      case 7:
        if (depth + 1 > limits.maxDepth) throw CollabDecodeError('nesting deeper than ${limits.maxDepth}');
        final n = count(limits.maxEntries, 'a list');
        return [for (var i = 0; i < n; i++) value(depth + 1)];
      case 8:
        if (depth + 1 > limits.maxDepth) throw CollabDecodeError('nesting deeper than ${limits.maxDepth}');
        final n = count(limits.maxEntries, 'a map');
        final m = <String, Object?>{};
        for (var i = 0; i < n; i++) {
          final k = str();
          if (m.containsKey(k)) throw CollabDecodeError('map key $k twice');
          m[k] = value(depth + 1);
        }
        return m;
      default:
        throw const CollabDecodeError('unknown value tag');
    }
  }

  void end() {
    if (_pos != bytes.length) throw const CollabDecodeError('bytes after the end');
  }
}
