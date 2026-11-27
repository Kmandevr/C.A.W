// caw_collab's op codec: every op type round-trips through binary and JSON, and random, corrupted, deep and
// oversized input never throws anything but CollabDecodeError.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:caw_collab/caw_collab.dart';
import 'package:flutter_test/flutter_test.dart';

const _hash = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

/// A random JSON value up to [depth] levels of nesting.
Object? randomValue(Random r, int depth) {
  switch (r.nextInt(depth > 0 ? 9 : 7)) {
    case 0:
      return null;
    case 1:
      return r.nextBool();
    case 2:
      return r.nextInt(1 << 32) - (1 << 31);
    case 3:
      return [0, -1, 1 << 62, -(1 << 62), 9223372036854775807, -9223372036854775807 - 1][r.nextInt(6)];
    case 4:
      return (r.nextDouble() - 0.5) * pow(10, r.nextInt(40) - 20);
    case 5:
      return String.fromCharCodes(List.generate(r.nextInt(12), (_) => [0x41 + r.nextInt(26), 0xe9, 0x4e2d, 0x22, 0x5c, 0x0a][r.nextInt(6)]));
    case 6:
      return '🎵 ${r.nextInt(100)}';
    case 7:
      return [for (var i = 0; i < r.nextInt(4); i++) randomValue(r, depth - 1)];
    default:
      return {for (var i = 0; i < r.nextInt(4); i++) 'k$i': randomValue(r, depth - 1)};
  }
}

String randomId(Random r) => NodeIds.create(['d', 'l', 'cpp', 'al'][r.nextInt(4)], r);

/// A random well-formed op of every type in turn.
Op randomOp(Random r, int i) {
  final author = 'dev${r.nextInt(1000)}';
  final cs = r.nextInt(1 << 20), bs = r.nextInt(1 << 20);
  final seq = r.nextBool() ? r.nextInt(1 << 30) : null;
  final time = r.nextBool() ? 1764000000000 + r.nextInt(1 << 30) : null;
  final key = FractionalKeys.between(null, null) + (r.nextBool() ? 'k' : '');
  switch (OpType.values[i % OpType.values.length]) {
    case OpType.set:
      return SetOp(node: randomId(r), field: 'json', value: randomValue(r, 4), author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.insert:
      return InsertOp(
          parent: rootId, list: 'tracks', node: randomId(r), key: key, kind: 'track',
          fields: {'json': randomValue(r, 3), 'extra': randomValue(r, 2)}, author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.move:
      return MoveOp(node: randomId(r), parent: randomId(r), list: 'tracks', key: key, author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.delete:
      return DeleteOp(node: randomId(r), author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.revive:
      return ReviveOp(node: randomId(r), author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.text:
      return TextOp(node: randomId(r), field: 'source', value: 'note c4 ${r.nextInt(9)}\n"x"', lockEpoch: r.nextInt(50), author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.blob:
      return BlobOp(
          hash: _hash, size: r.nextInt(1 << 30), format: 'wav', channels: r.nextBool() ? 2 : null, rate: r.nextBool() ? 48000 : null,
          frames: r.nextBool() ? r.nextInt(1 << 24) : null, author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.access:
      return AccessOp(
          member: 'kim${r.nextInt(9)}',
          grants: [for (var j = 0; j < r.nextInt(4); j++) Grant(Capability.values[r.nextInt(Capability.values.length)], r.nextBool() ? rootId : randomId(r))],
          author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.checkpoint:
      return CheckpointOp(label: 'Before the bridge ${r.nextInt(9)}', author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
    case OpType.restore:
      return RestoreOp(checkpointSeq: r.nextInt(1 << 20), author: author, clientSeq: cs, baseSeq: bs, seq: seq, time: time);
  }
}

/// Decodes [decode] and fails the test on anything thrown but [CollabDecodeError]. A success must be well-formed.
void survives(Object? Function() decode) {
  try {
    final v = decode();
    for (final op in v is List<Op> ? v : [v as Op]) {
      expect(opProblem(op), isNull);
      expect(decodeOpBinary(encodeOpBinary(op)), op);
    }
  } on CollabDecodeError {
    // The one allowed failure.
  } catch (e, s) {
    fail('threw ${e.runtimeType}: $e\n$s');
  }
}

void main() {
  test('every op type round-trips through binary and JSON, and across them', () {
    final r = Random(1);
    for (var i = 0; i < 2000; i++) {
      final op = randomOp(r, i);
      expect(opProblem(op), isNull, reason: '$op');
      final bin = encodeOpBinary(op);
      final fromBin = decodeOpBinary(bin);
      expect(fromBin, op);
      expect(encodeOpBinary(fromBin), bin, reason: 'binary is canonical');
      final json = encodeOpJson(op);
      final fromJson = decodeOpJson(json);
      expect(fromJson, op);
      expect(encodeOpBinary(fromJson), bin, reason: 'JSON and binary agree');
      expect(fromBin.type, op.type);
    }
  });

  test('ints and doubles stay apart, and edge values survive', () {
    for (final v in [1, 1.0, -0.0, 0, 9223372036854775807, -9223372036854775807 - 1, 1e300, -1e-300, '', 'a\u0000b', <Object?>[], <String, Object?>{}]) {
      final op = SetOp(node: 'd12345678', field: 'json', value: v, author: 'a', clientSeq: 0, baseSeq: 0);
      final b = decodeOpBinary(encodeOpBinary(op)) as SetOp;
      final j = decodeOpJson(encodeOpJson(op)) as SetOp;
      expect(valueEquals(b.value, v), isTrue, reason: '$v binary');
      expect(valueEquals(j.value, v), isTrue, reason: '$v JSON');
      expect(b.value.runtimeType, v.runtimeType);
    }
  });

  test('batches round-trip and respect the batch cap', () {
    final r = Random(2);
    final ops = [for (var i = 0; i < 50; i++) randomOp(r, i)];
    expect(decodeBatchBinary(encodeBatchBinary(ops)), ops);
    expect(decodeBatchJson(encodeBatchJson(ops)), ops);
    const small = CollabLimits(maxBatchOps: 10);
    expect(() => decodeBatchBinary(encodeBatchBinary(ops), small), throwsA(isA<CollabDecodeError>()));
    expect(() => decodeBatchJson(encodeBatchJson(ops), small), throwsA(isA<CollabDecodeError>()));
  });

  test('random bytes never throw anything but CollabDecodeError', () {
    final r = Random(3);
    for (var i = 0; i < 20000; i++) {
      final b = Uint8List.fromList(List.generate(r.nextInt(64), (_) => r.nextInt(256)));
      if (b.isNotEmpty && r.nextBool()) b[0] = 1 + r.nextInt(2);
      if (b.length > 1 && r.nextBool()) b[1] = 1 + r.nextInt(10);
      survives(() => decodeOpBinary(b));
      survives(() => decodeBatchBinary(b));
    }
  });

  test('corrupted encodings (flipped, cut, inserted and swapped bytes) never throw anything else', () {
    final r = Random(4);
    for (var i = 0; i < 6000; i++) {
      final good = r.nextInt(4) == 0 ? encodeBatchBinary([randomOp(r, i), randomOp(r, i + 1)]) : encodeOpBinary(randomOp(r, i));
      final b = Uint8List.fromList(good);
      switch (r.nextInt(4)) {
        case 0:
          for (var k = 0; k < 1 + r.nextInt(3); k++) {
            b[r.nextInt(b.length)] ^= 1 << r.nextInt(8);
          }
          survives(() => decodeOpBinary(b));
          survives(() => decodeBatchBinary(b));
        case 1:
          final cut = Uint8List.sublistView(b, 0, r.nextInt(b.length));
          expect(() => decodeOpBinary(cut), throwsA(isA<CollabDecodeError>()));
          survives(() => decodeBatchBinary(cut));
        case 2:
          final at = r.nextInt(b.length + 1);
          final grown = Uint8List.fromList([...b.sublist(0, at), r.nextInt(256), ...b.sublist(at)]);
          survives(() => decodeOpBinary(grown));
          survives(() => decodeBatchBinary(grown));
        default:
          b[r.nextInt(b.length)] = [0x00, 0x7f, 0x80, 0xff][r.nextInt(4)];
          survives(() => decodeOpBinary(b));
          survives(() => decodeBatchBinary(b));
      }
    }
  });

  test('random and corrupted JSON never throws anything but CollabDecodeError', () {
    final r = Random(5);
    const alphabet = '{}[]":,0123456789.-eE truefalsnul\\abcop';
    for (var i = 0; i < 10000; i++) {
      final s = String.fromCharCodes(List.generate(r.nextInt(40), (_) => alphabet.codeUnitAt(r.nextInt(alphabet.length))));
      survives(() => decodeOpJson(s));
      survives(() => decodeBatchJson(s));
      final good = encodeOpJson(randomOp(r, i));
      final at = r.nextInt(good.length);
      final bad = switch (r.nextInt(3)) {
        0 => good.substring(0, at),
        1 => good.replaceRange(at, at + 1, alphabet[r.nextInt(alphabet.length)]),
        _ => good.replaceRange(at, at, alphabet[r.nextInt(alphabet.length)]),
      };
      survives(() => decodeOpJson(bad));
    }
    // Well-formed JSON of the wrong shape.
    for (final s in [
      'null', '[]', '{}', '"set"', '{"op":"set"}', '{"op":"nope","author":"a","clientSeq":0,"baseSeq":0}',
      '{"op":"delete","author":"a","clientSeq":0.0,"baseSeq":0,"node":"d12345678"}',
      '{"op":"delete","author":"a","clientSeq":-1,"baseSeq":0,"node":"d12345678"}',
      '{"op":"delete","author":"a","clientSeq":0,"baseSeq":0,"node":"d12345678","extra":1}',
      '{"op":"delete","author":"a","clientSeq":0,"baseSeq":0,"node":"D12345678"}',
      '{"op":"set","author":"a","clientSeq":0,"baseSeq":0,"node":"d12345678","field":"json","value":1e999}',
      '{"op":"set","author":"a","clientSeq":0,"baseSeq":0,"node":"d12345678","field":"json","value":"\\ud800"}',
      '{"op":"insert","author":"a","clientSeq":0,"baseSeq":0,"parent":"root","list":"tracks","node":"l12345678","key":"V0","kind":"track","fields":{}}',
      '{"op":"access","author":"a","clientSeq":0,"baseSeq":0,"member":"b","grants":[{"capability":"root","scope":"root"}]}',
      '{"op":"blob","author":"a","clientSeq":0,"baseSeq":0,"hash":"00","size":1,"format":"wav"}',
    ]) {
      expect(() => decodeOpJson(s), throwsA(isA<CollabDecodeError>()), reason: s);
    }
  });

  test('nesting past the depth limit is refused before it can exhaust the stack', () {
    SetOp nested(int depth) {
      Object? v = 1;
      for (var i = 0; i < depth; i++) {
        v = i.isEven ? [v] : {'a': v};
      }
      return SetOp(node: 'd12345678', field: 'json', value: v, author: 'a', clientSeq: 0, baseSeq: 0);
    }

    expect(decodeOpBinary(encodeOpBinary(nested(64))), nested(64));
    expect(decodeOpJson(encodeOpJson(nested(64))), nested(64));
    expect(() => decodeOpBinary(encodeOpBinary(nested(65))), throwsA(isA<CollabDecodeError>()));
    expect(() => decodeOpJson(encodeOpJson(nested(65))), throwsA(isA<CollabDecodeError>()));
    // Hostile nesting: a hundred thousand open lists, in both codecs.
    final deepBin = Uint8List.fromList([1, 1, 1, 0x61, 0, 0, 0, 9, ...utf8.encode('d12345678'), 4, ...utf8.encode('json'), ...List.filled(100000, 7)]);
    expect(() => decodeOpBinary(deepBin), throwsA(isA<CollabDecodeError>()));
    final deepJson = '{"op":"set","author":"a","clientSeq":0,"baseSeq":0,"node":"d12345678","field":"json","value":${'[' * 100000}${']' * 100000}}';
    expect(() => decodeOpJson(deepJson), throwsA(isA<CollabDecodeError>()));
  });

  test('size and count limits hold in both codecs', () {
    const limits = CollabLimits(maxOpBytes: 4096, maxEntries: 100, maxStringBytes: 1000, maxFields: 4, maxKeyLength: 16);
    SetOp setOf(Object? v) => SetOp(node: 'd12345678', field: 'json', value: v, author: 'a', clientSeq: 0, baseSeq: 0);
    for (final op in [
      setOf('x' * 1001),
      setOf(List.filled(101, 0)),
      setOf({for (var i = 0; i < 101; i++) 'k$i': 0}),
      setOf('x' * 5000),
      InsertOp(parent: rootId, list: 'tracks', node: 'l12345678', key: 'V', kind: 'track', fields: {for (var i = 0; i < 5; i++) 'f$i': 0}, author: 'a', clientSeq: 0, baseSeq: 0),
      MoveOp(node: 'l12345678', parent: rootId, list: 'tracks', key: 'V' * 17, author: 'a', clientSeq: 0, baseSeq: 0),
    ]) {
      expect(() => decodeOpBinary(encodeOpBinary(op), limits), throwsA(isA<CollabDecodeError>()), reason: '$op'.substring(0, 60));
      expect(() => decodeOpJson(encodeOpJson(op), limits), throwsA(isA<CollabDecodeError>()), reason: '$op'.substring(0, 60));
    }
    // A count that claims more entries than there are bytes is refused without allocating them.
    final lying = Uint8List.fromList([2, 0xff, 0xff, 0xff, 0x7f]);
    expect(() => decodeBatchBinary(lying), throwsA(isA<CollabDecodeError>()));
    // Non-canonical and oversized varints.
    expect(() => decodeOpBinary(Uint8List.fromList([1, 4, 1, 0x61, 0x80, 0x00, 0, 0, 1, 0x30])), throwsA(isA<CollabDecodeError>()));
    expect(() => decodeOpBinary(Uint8List.fromList([1, 4, 1, 0x61, ...List.filled(10, 0xff), 1])), throwsA(isA<CollabDecodeError>()));
  });
}
