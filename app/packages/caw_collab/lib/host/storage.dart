// The host's storage interfaces (a write-ahead log, a snapshot store, a content-addressed blob store, and the
// bundle a session keeps them in), their length-and-CRC32 framing, and in-memory implementations.
import 'dart:typed_data';

import 'package:caw_services/sha256.dart';

import 'crc32.dart';

/// The most bytes one framed record may hold: one op batch at its cap plus room for its header.
///
/// Assumption: a log record is at most one batch of the collab limits (8 MiB) plus 1 MiB.
const int maxRecordBytes = 9 * 1024 * 1024;

/// One frame: the payload's length (u32, little-endian), its CRC-32 (u32, little-endian), then the payload.
Uint8List frameRecord(List<int> payload) {
  if (payload.length > maxRecordBytes) throw ArgumentError('a record over $maxRecordBytes bytes');
  final out = Uint8List(8 + payload.length);
  final v = ByteData.sublistView(out);
  v.setUint32(0, payload.length, Endian.little);
  v.setUint32(4, crc32(payload), Endian.little);
  out.setRange(8, out.length, payload);
  return out;
}

/// The whole frames at the start of [bytes], and how many bytes they take. Reading stops at the first frame that
/// is short, too long or fails its CRC: that frame and everything after it are a torn tail.
(List<Uint8List>, int) readFrames(Uint8List bytes) {
  final out = <Uint8List>[];
  final v = ByteData.sublistView(bytes);
  var at = 0;
  while (at + 8 <= bytes.length) {
    final n = v.getUint32(at, Endian.little);
    if (n > maxRecordBytes || at + 8 + n > bytes.length) break;
    final crc = v.getUint32(at + 4, Endian.little);
    if (crc32(bytes, at + 8, at + 8 + n) != crc) break;
    out.add(Uint8List.sublistView(bytes, at + 8, at + 8 + n));
    at += 8 + n;
  }
  return (out, at);
}

/// An append-only log of framed records.
abstract interface class WriteAheadLog {
  /// Appends one record; it is durable only after [sync].
  void append(Uint8List record);

  /// Makes every appended record durable (fsync). The host calls this before it acks.
  void sync();

  /// The durable records in order. A torn or corrupt tail is cut off the log for good.
  List<Uint8List> recover();

  /// Drops every record, durably (a snapshot now covers them).
  void reset();

  void close();
}

/// The latest snapshot, replaced atomically and durably.
abstract interface class SnapshotStore {
  /// The stored snapshot, or null when there is none or it fails its check.
  Uint8List? read();

  /// Replaces the snapshot; durable when it returns, and never half-written.
  void write(Uint8List snapshot);
}

/// Why a blob was refused: a stable [reason] code.
class BlobRefused implements Exception {
  const BlobRefused(this.reason, this.message);
  final String reason;
  final String message;

  static const hashMismatch = 'hash_mismatch';
  static const tooLarge = 'too_large';
  static const quota = 'quota';

  @override
  String toString() => 'BlobRefused($reason): $message';
}

/// Files by content: each blob is stored under its SHA-256, checked on the way in, within a per-blob size limit
/// and a total quota.
abstract class BlobStore {
  BlobStore({required this.maxBlobBytes, required this.quotaBytes});
  final int maxBlobBytes;
  final int quotaBytes;

  bool has(String hash);
  Uint8List? get(String hash);
  Iterable<String> get hashes;
  int get totalBytes;
  void delete(String hash);

  /// Stores [bytes] under its own hash after checking it is [hash] and within the limits. Storing a blob again
  /// changes nothing.
  void put(String hash, Uint8List bytes) {
    if (bytes.length > maxBlobBytes) throw BlobRefused(BlobRefused.tooLarge, 'over $maxBlobBytes bytes');
    final actual = sha256Hex(bytes);
    if (actual != hash) throw const BlobRefused(BlobRefused.hashMismatch, 'the bytes do not have the declared hash');
    if (has(hash)) return;
    if (totalBytes + bytes.length > quotaBytes) throw BlobRefused(BlobRefused.quota, 'over the session quota of $quotaBytes bytes');
    writeBlob(hash, bytes);
  }

  /// Writes a checked blob (the implementation's part).
  void writeBlob(String hash, Uint8List bytes);
}

/// Everything one session's host keeps: a cache of the session, never the owner's project (hosting is not
/// owning, owner 2026-11-27).
abstract interface class HostStorage {
  WriteAheadLog get wal;
  SnapshotStore get snapshots;
  BlobStore get blobs;

  /// Whether anything is stored yet.
  bool get isEmpty;

  /// Deletes everything this session stored.
  void purge();
}

/// A log in memory that models a disk: appended bytes are lost on [crash] unless [sync] ran, except for an
/// optional torn prefix.
class MemoryWal implements WriteAheadLog {
  final _durable = BytesBuilder(copy: false);
  final _pending = BytesBuilder(copy: false);
  int syncs = 0;

  @override
  void append(Uint8List record) => _pending.add(frameRecord(record));

  @override
  void sync() {
    _durable.add(_pending.takeBytes());
    syncs++;
  }

  /// What a power cut leaves: the durable bytes plus the first [tornBytes] of those not yet synced.
  void crash({int tornBytes = 0}) {
    final p = _pending.takeBytes();
    if (tornBytes > 0) _durable.add(Uint8List.sublistView(p, 0, tornBytes.clamp(0, p.length)));
  }

  /// The durable bytes, for tests that damage them.
  Uint8List get bytes => _durable.toBytes();
  set bytes(Uint8List b) {
    _durable.clear();
    _durable.add(b);
  }

  int get pendingBytes => _pending.length;

  @override
  List<Uint8List> recover() {
    _pending.clear();
    final all = _durable.toBytes();
    final (records, valid) = readFrames(all);
    if (valid != all.length) bytes = Uint8List.fromList(Uint8List.sublistView(all, 0, valid));
    return [for (final r in records) Uint8List.fromList(r)];
  }

  @override
  void reset() {
    _durable.clear();
    _pending.clear();
  }

  @override
  void close() {}
}

/// A snapshot store in memory; a write replaces the snapshot whole.
class MemorySnapshotStore implements SnapshotStore {
  /// The stored bytes, framed (tests damage them).
  Uint8List? framed;
  int writes = 0;

  @override
  Uint8List? read() {
    final f = framed;
    if (f == null) return null;
    final (records, valid) = readFrames(f);
    return records.length == 1 && valid == f.length ? Uint8List.fromList(records.single) : null;
  }

  @override
  void write(Uint8List snapshot) {
    framed = frameRecord(snapshot);
    writes++;
  }
}

/// A blob store in memory.
class MemoryBlobStore extends BlobStore {
  MemoryBlobStore({super.maxBlobBytes = 1 << 30, super.quotaBytes = 4 << 30});
  final _blobs = <String, Uint8List>{};

  @override
  bool has(String hash) => _blobs.containsKey(hash);
  @override
  Uint8List? get(String hash) => _blobs[hash];
  @override
  Iterable<String> get hashes => _blobs.keys;
  @override
  int get totalBytes => _blobs.values.fold(0, (a, b) => a + b.length);
  @override
  void delete(String hash) => _blobs.remove(hash);
  @override
  void writeBlob(String hash, Uint8List bytes) => _blobs[hash] = Uint8List.fromList(bytes);
}

/// A session's storage in memory: it survives a [HostCore] being thrown away, as a disk would.
class MemoryHostStorage implements HostStorage {
  MemoryHostStorage({int maxBlobBytes = 1 << 30, int quotaBytes = 4 << 30})
      : blobs = MemoryBlobStore(maxBlobBytes: maxBlobBytes, quotaBytes: quotaBytes);

  @override
  final MemoryWal wal = MemoryWal();
  @override
  final MemorySnapshotStore snapshots = MemorySnapshotStore();
  @override
  final MemoryBlobStore blobs;

  bool purged = false;

  @override
  bool get isEmpty => snapshots.framed == null && wal.bytes.isEmpty && blobs.hashes.isEmpty;

  /// A power cut: unsynced log bytes are lost, apart from [tornBytes] of them.
  void crash({int tornBytes = 0}) => wal.crash(tornBytes: tornBytes);

  @override
  void purge() {
    wal.reset();
    snapshots.framed = null;
    for (final h in blobs.hashes.toList()) {
      blobs.delete(h);
    }
    purged = true;
  }
}
