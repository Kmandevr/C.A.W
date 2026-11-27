// caw_collab's host storage and crypto: CRC-32 and the log's framing, torn-tail recovery in memory and on disk,
// atomic snapshots, content-addressed blob stores with limits, the cache purge, PBKDF2 and HMAC vectors, and the
// checks on untrusted snapshots and session messages.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:caw_collab/caw_collab.dart';
import 'package:caw_services/sha256.dart';
import 'package:flutter_test/flutter_test.dart';

import 'collab_host_fixture.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List rec(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  test('CRC-32 matches the standard check value', () {
    expect(crc32('123456789'.codeUnits), 0xcbf43926);
    expect(crc32(const []), 0);
  });

  test('frames read back whole, and reading stops at the first torn or corrupt frame', () {
    final a = frameRecord(rec('one')), b = frameRecord(rec('two')), c = frameRecord(rec('three'));
    final all = Uint8List.fromList([...a, ...b, ...c]);
    final (r, n) = readFrames(all);
    expect(r.map(utf8.decode), ['one', 'two', 'three']);
    expect(n, all.length);
    for (var cut = 0; cut < all.length; cut++) {
      final (r2, n2) = readFrames(Uint8List.sublistView(all, 0, cut));
      expect(n2, lessThanOrEqualTo(cut));
      expect(r2.length, cut >= a.length + b.length ? 2 : (cut >= a.length ? 1 : 0));
    }
    final bad = Uint8List.fromList(all)..[a.length + 9] ^= 0xff;
    expect(readFrames(bad).$1.map(utf8.decode), ['one']);
    final huge = Uint8List.fromList([0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0]);
    expect(readFrames(huge).$1, isEmpty);
  });

  test('a memory log keeps only synced records through a crash, and cuts a torn tail for good', () {
    final w = MemoryWal();
    w.append(rec('a'));
    w.append(rec('b'));
    w.sync();
    w.append(rec('c'));
    w.crash(tornBytes: 5);
    expect(w.recover().map(utf8.decode), ['a', 'b']);
    // The torn bytes are gone: a new record after them reads back.
    w.append(rec('d'));
    w.sync();
    expect(w.recover().map(utf8.decode), ['a', 'b', 'd']);
    w.reset();
    expect(w.recover(), isEmpty);
  });

  test('a file log survives reopening, cuts a torn tail and resets', () {
    final dir = Directory.systemTemp.createTempSync('caw_wal');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/wal.log');
    var w = FileWal(f);
    for (final s in ['x', 'y', 'z']) {
      w.append(rec(s));
    }
    w.sync();
    w.close();
    // A torn frame: a header claiming 100 bytes with only 3 behind it.
    f.writeAsBytesSync([...f.readAsBytesSync(), 100, 0, 0, 0, 1, 2, 3, 4, 9, 9, 9], flush: true);
    w = FileWal(f);
    expect(w.recover().map(utf8.decode), ['x', 'y', 'z']);
    final cutLength = f.lengthSync();
    expect(cutLength, 3 * 9);
    w.append(rec('w'));
    w.sync();
    expect(FileWal(f).recover().map(utf8.decode), ['x', 'y', 'z', 'w']);
    w.reset();
    w.append(rec('v'));
    w.sync();
    w.close();
    expect(FileWal(f).recover().map(utf8.decode), ['v']);
  });

  test('snapshot stores replace whole and refuse a damaged snapshot', () {
    final dir = Directory.systemTemp.createTempSync('caw_snap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = FileSnapshotStore(File('${dir.path}/snapshot.bin'));
    final mem = MemorySnapshotStore();
    for (final SnapshotStore s in [file, mem]) {
      expect(s.read(), isNull);
      s.write(rec('first'));
      s.write(rec('second'));
      expect(utf8.decode(s.read()!), 'second');
    }
    mem.framed = Uint8List.fromList(mem.framed!)..[10] ^= 1;
    expect(mem.read(), isNull);
    expect(File('${dir.path}/snapshot.bin.tmp').existsSync(), isFalse);
  });

  test('blob stores check the hash, the size limit and the quota, in memory and on disk', () {
    final dir = Directory.systemTemp.createTempSync('caw_blobs');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final BlobStore s in [MemoryBlobStore(maxBlobBytes: 10, quotaBytes: 16), FileBlobStore(Directory('${dir.path}/b'), maxBlobBytes: 10, quotaBytes: 16)]) {
      final a = Uint8List.fromList(List.filled(8, 1)), b = Uint8List.fromList(List.filled(9, 2));
      s.put(sha256Hex(a), a);
      s.put(sha256Hex(a), a);
      expect(s.has(sha256Hex(a)), isTrue);
      expect(s.get(sha256Hex(a)), a);
      expect(s.totalBytes, 8);
      expect(() => s.put(sha256Hex(b), a), throwsA(isA<BlobRefused>().having((e) => e.reason, 'reason', BlobRefused.hashMismatch)));
      final big = Uint8List(11);
      expect(() => s.put(sha256Hex(big), big), throwsA(isA<BlobRefused>().having((e) => e.reason, 'reason', BlobRefused.tooLarge)));
      expect(() => s.put(sha256Hex(b), b), throwsA(isA<BlobRefused>().having((e) => e.reason, 'reason', BlobRefused.quota)));
      s.delete(sha256Hex(a));
      s.put(sha256Hex(b), b);
      expect(s.hashes, [sha256Hex(b)]);
    }
  });

  test('file storage purges itself, and a host start purges sessions past the resume window', () {
    final root = Directory.systemTemp.createTempSync('caw_cache');
    addTearDown(() => root.deleteSync(recursive: true));
    final old = FileHostStorage(Directory('${root.path}/old')), fresh = FileHostStorage(Directory('${root.path}/fresh'));
    for (final s in [old, fresh]) {
      expect(s.isEmpty, isTrue);
      s.snapshots.write(rec('snap'));
      s.wal.append(rec('r'));
      s.wal.sync();
      s.wal.close();
      expect(s.isEmpty, isFalse);
    }
    final long = DateTime.now().subtract(const Duration(days: 2));
    old.snapshots.file.setLastModifiedSync(long);
    old.wal.file.setLastModifiedSync(long);
    final gone = FileHostStorage.purgeExpired(root, 24 * 3600 * 1000, DateTime.now());
    expect(gone, ['old']);
    expect(Directory('${root.path}/old').existsSync(), isFalse);
    expect(Directory('${root.path}/fresh').existsSync(), isTrue);
    fresh.purge();
    expect(Directory('${root.path}/fresh').existsSync(), isFalse);
  });

  group('password hashing', () {
    test('HMAC-SHA256 matches RFC 4231 test case 2', () {
      expect(hex(hmacSha256(utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?'))),
          '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
    });

    test('PBKDF2-HMAC-SHA256 matches RFC 7914 section 11', () {
      expect(hex(pbkdf2HmacSha256(utf8.encode('passwd'), utf8.encode('salt'), 1, 64)),
          '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783');
      expect(hex(pbkdf2HmacSha256(utf8.encode('Password'), utf8.encode('NaCl'), 80000, 64)),
          '4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d');
    });

    test('the fast iteration path equals chained plain HMACs', () {
      final r = Random(7);
      for (var t = 0; t < 20; t++) {
        final pw = List.generate(r.nextInt(100), (_) => r.nextInt(256)), salt = List.generate(r.nextInt(20), (_) => r.nextInt(256));
        final c = 1 + r.nextInt(6);
        var u = hmacSha256(pw, [...salt, 0, 0, 0, 1]);
        final acc = Uint8List.fromList(u);
        for (var i = 1; i < c; i++) {
          u = hmacSha256(pw, u);
          for (var j = 0; j < 32; j++) {
            acc[j] ^= u[j];
          }
        }
        expect(hex(pbkdf2HmacSha256(pw, salt, c, 32)), hex(acc));
      }
    });

    test('a stored hash verifies its password only, parses back, and refuses malformed text', () {
      final h = PasswordHash.create('correct horse', iterations: 100, random: Random(3));
      expect(h.encoded, startsWith(r'pbkdf2-sha256$100$'));
      expect(h.encoded.contains('correct'), isFalse);
      expect(h.verify('correct horse'), isTrue);
      expect(h.verify('correct horsE'), isFalse);
      final back = PasswordHash.parse(h.encoded)!;
      expect(back.verify('correct horse'), isTrue);
      for (final bad in ['', r'md5$1$a$b', r'pbkdf2-sha256$0$AAAAAAAAAAA$AAAA', r'pbkdf2-sha256$99999999999$AAAAAAAAAAA$AAAA', r'pbkdf2-sha256$5$!!$!!']) {
        expect(PasswordHash.parse(bad), isNull, reason: bad);
      }
      expect(PasswordHash.create('x', iterations: 100).encoded, isNot(PasswordHash.create('x', iterations: 100).encoded));
      expect(PasswordHash.defaultIterations, 600000);
    });
  });

  group('untrusted input', () {
    test('a tree snapshot round-trips through JSON and a damaged one is refused', () {
      final t = CollabTree(hostSchema);
      t.apply(InsertOp(parent: rootId, list: 'tracks', node: nid(1), key: 'V', kind: 'track', fields: {'name': 'a'}, author: 'kim', clientSeq: 1, baseSeq: 0));
      t.apply(InsertOp(parent: nid(1), list: 'items', node: nid(2), key: 'V', kind: 'track', author: 'kim', clientSeq: 2, baseSeq: 0));
      t.apply(DeleteOp(node: nid(2), author: 'kim', clientSeq: 3, baseSeq: 0));
      t.apply(BlobOp(hash: 'a' * 64, size: 3, format: 'wav', author: 'kim', clientSeq: 4, baseSeq: 0));
      final snap = jsonDecode(jsonEncode(t.snapshot())) as Map<String, dynamic>;
      expect(canonicalJson(CollabTree.fromSnapshot(hostSchema, snap).snapshot()), canonicalJson(t.snapshot()));
      Map<String, dynamic> copy() => jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
      final cycle = copy();
      (cycle['nodes'] as Map)[nid(1)]['parent'] = nid(2);
      (cycle['nodes'] as Map)[nid(1)]['list'] = 'items';
      final orphan = copy();
      (orphan['nodes'] as Map)[nid(2)]['parent'] = nid(7);
      final kind = copy();
      (kind['nodes'] as Map)[nid(2)]['kind'] = 'bogus';
      final range = copy();
      (range['nodes'] as Map)[nid(1)]['fields'] = {'gain': 9};
      final schema = copy()..['schema'] = coarseProjectSchema.hash;
      final blob = copy();
      (blob['blobs'] as Map)['a' * 64]['size'] = -1;
      for (final bad in [cycle, orphan, kind, range, schema, blob, 'x', {}]) {
        expect(() => CollabTree.fromSnapshot(hostSchema, bad), throwsA(isA<CollabDecodeError>()), reason: '$bad');
      }
    });

    test('session messages round-trip and malformed ones are refused', () {
      final hello = Hello(epoch: 2, member: 'kim', version: goodVersion(), password: 'pw', lastSeq: 4, score: 3.5);
      final back = decodeClientMessage(encodeMessage(hello)) as Hello;
      expect([back.member, back.password, back.lastSeq, back.score, back.version.protocol, back.version.format], ['kim', 'pw', 4, 3.5, collabProtocol, goodVersion().format]);
      final sub = Submit(epoch: 1, ops: [SetOp(node: rootId, field: 'json', value: [1, 2], author: 'kim', clientSeq: 1, baseSeq: 0)]);
      expect((decodeClientMessage(encodeMessage(sub)) as Submit).ops.single, sub.ops.single);
      final up = SessionUpdate(epoch: 3, successors: const [Successor('sam', 9)], state: SessionState(config: config(), grants: {'kim': Role.viewer.grants}, epoch: 3, seq: 8));
      final upBack = decodeHostMessage(encodeMessage(up)) as SessionUpdate;
      expect(upBack.state!.grants['kim']!.single.capability, Capability.view);
      expect(upBack.successors.single.member, 'sam');
      for (final bad in [
        '{}',
        '{"t":"hello","epoch":-1}',
        '{"t":"nope","epoch":0}',
        '{"t":"submit","epoch":0,"ops":[{"op":"set"}]}',
        '{"t":"resume","epoch":0,"fromSeq":"1"}',
        '{"t":"invite","epoch":0,"secretHash":"x","role":"owner"}',
        '[' * 500,
        'x' * (CollabLimits.standard.maxOpBytes + 70000),
      ]) {
        expect(() => decodeClientMessage(bad), throwsA(isA<CollabDecodeError>()), reason: bad.length > 60 ? bad.substring(0, 60) : bad);
      }
    });

    test('a host refuses an unreadable message and ends the connection', () async {
      final out = RecordingOutbox();
      final h = HostCore.create(config: config(), schema: hostSchema, storage: MemoryHostStorage(), outbox: out, passwordCheck: inlineCheck);
      h.connect('a', address: '1');
      await h.receiveText('a', '{"t":"submit"');
      expect((out.of('a').single as Refused).reason, Refused.invalid);
      expect(out.closed.single.$1, 'a');
      await h.receive('a', Bye(epoch: 0));
      expect(out.of('a').length, 1, reason: 'the connection is gone');
    });
  });
}
