// The host's storage on disk: one folder per session holding the write-ahead log, the latest snapshot (replaced
// atomically) and the blobs by hash, plus removal of session folders past the resume window.
import 'dart:io';
import 'dart:typed_data';

import 'storage.dart';

/// A log file: frames appended in order, fsynced by [sync], with a torn tail cut at [recover].
class FileWal implements WriteAheadLog {
  FileWal(this.file);
  final File file;
  RandomAccessFile? _raf;

  RandomAccessFile get _open => _raf ??= file.openSync(mode: FileMode.append);

  @override
  void append(Uint8List record) => _open.writeFromSync(frameRecord(record));

  @override
  void sync() => _open.flushSync();

  @override
  List<Uint8List> recover() {
    close();
    if (!file.existsSync()) return const [];
    final all = file.readAsBytesSync();
    final (records, valid) = readFrames(all);
    if (valid != all.length) {
      final raf = file.openSync(mode: FileMode.append);
      try {
        raf.truncateSync(valid);
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
    }
    return [for (final r in records) Uint8List.fromList(r)];
  }

  @override
  void reset() {
    final raf = _open;
    raf.truncateSync(0);
    raf.setPositionSync(0);
    raf.flushSync();
  }

  @override
  void close() {
    _raf?.closeSync();
    _raf = null;
  }
}

/// The latest snapshot in one file, framed with its CRC-32, replaced by writing a temporary file, fsyncing it and
/// renaming it over the old one.
///
/// Assumption: `dart:io` has no directory fsync, so the rename is durable once the file system commits it; a power
/// cut right after it can leave the old snapshot, which recovery handles because the log is reset only after a
/// snapshot write returns, and a log older than the snapshot is skipped by record number.
class FileSnapshotStore implements SnapshotStore {
  FileSnapshotStore(this.file);
  final File file;

  @override
  Uint8List? read() {
    if (!file.existsSync()) return null;
    final f = file.readAsBytesSync();
    final (records, valid) = readFrames(f, maxBytes: maxSnapshotBytes);
    return records.length == 1 && valid == f.length ? Uint8List.fromList(records.single) : null;
  }

  @override
  void write(Uint8List snapshot) {
    final tmp = File('${file.path}.tmp');
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeFromSync(frameRecord(snapshot, maxBytes: maxSnapshotBytes));
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(file.path);
  }
}

/// Blobs as files named by their SHA-256, each written to a temporary file, fsynced and renamed into place.
class FileBlobStore extends BlobStore {
  FileBlobStore(this.dir, {super.maxBlobBytes = 1 << 30, super.quotaBytes = 4 << 30});
  final Directory dir;

  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  File _file(String hash) {
    if (!_hash.hasMatch(hash)) throw ArgumentError.value(hash, 'hash', 'not a SHA-256 in lowercase hex');
    return File('${dir.path}${Platform.pathSeparator}$hash');
  }

  @override
  bool has(String hash) => _file(hash).existsSync();

  @override
  Uint8List? get(String hash) {
    final f = _file(hash);
    return f.existsSync() ? f.readAsBytesSync() : null;
  }

  @override
  Iterable<String> get hashes => dir.existsSync()
      ? [for (final e in dir.listSync()) if (e is File && _hash.hasMatch(e.uri.pathSegments.last)) e.uri.pathSegments.last]
      : const [];

  @override
  int get totalBytes => hashes.fold(0, (a, h) => a + _file(h).lengthSync());

  @override
  void delete(String hash) {
    final f = _file(hash);
    if (f.existsSync()) f.deleteSync();
  }

  @override
  void writeBlob(String hash, Uint8List bytes) {
    dir.createSync(recursive: true);
    final tmp = File('${_file(hash).path}.tmp');
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeFromSync(bytes);
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(_file(hash).path);
  }
}

/// One session's folder: `wal.log`, `snapshot.bin` and `blobs/`. The folder is a cache of the session, kept in
/// app-private storage, and holds nothing that is the owner's project file.
class FileHostStorage implements HostStorage {
  FileHostStorage(this.dir, {int maxBlobBytes = 1 << 30, int quotaBytes = 4 << 30})
      : wal = FileWal(File('${dir.path}${Platform.pathSeparator}wal.log')),
        snapshots = FileSnapshotStore(File('${dir.path}${Platform.pathSeparator}snapshot.bin')),
        blobs = FileBlobStore(Directory('${dir.path}${Platform.pathSeparator}blobs'), maxBlobBytes: maxBlobBytes, quotaBytes: quotaBytes) {
    dir.createSync(recursive: true);
  }

  final Directory dir;
  @override
  final FileWal wal;
  @override
  final FileSnapshotStore snapshots;
  @override
  final FileBlobStore blobs;

  @override
  bool get isEmpty => !snapshots.file.existsSync() && (!wal.file.existsSync() || wal.file.lengthSync() == 0) && blobs.hashes.isEmpty;

  @override
  void purge() {
    wal.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// When this session last wrote anything (its last activity), or null when nothing is stored.
  DateTime? get lastWrite {
    DateTime? last;
    for (final f in [wal.file, snapshots.file]) {
      if (f.existsSync()) {
        final m = f.lastModifiedSync();
        if (last == null || m.isAfter(last)) last = m;
      }
    }
    return last;
  }

  /// Deletes every session folder under [root] that has written nothing for [resumeWindowMs], and returns their
  /// names. Meant for a host starting up, before it opens any session.
  static List<String> purgeExpired(Directory root, int resumeWindowMs, DateTime now) {
    final out = <String>[];
    if (!root.existsSync()) return out;
    for (final e in root.listSync()) {
      if (e is! Directory) continue;
      final s = FileHostStorage(e);
      final last = s.lastWrite;
      if (last != null && now.difference(last).inMilliseconds >= resumeWindowMs) {
        s.purge();
        out.add(e.uri.pathSegments.where((p) => p.isNotEmpty).last);
      }
    }
    return out;
  }
}
