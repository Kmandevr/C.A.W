// Applies a CAWPATCH v1 file (written by scripts/update-delta.js): streamed, bounded, every rebuilt file hashed as it
// is written and refused unless it matches. Synchronous file work: call it off the UI isolate.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../sha256.dart';

/// A patch that is malformed, out of range or rebuilds something else than it promised.
class PatchError implements Exception {
  const PatchError(this.message);
  final String message;
  @override
  String toString() => 'Patch refused: $message';
}

/// Limits for untrusted patches.
abstract final class PatchLimits {
  static const maxFiles = 10000;
  static const maxPath = 1024;

  /// The largest file a patch may build (the APK is about 55 MB now).
  static const maxFileBytes = 512 * 1024 * 1024;

  /// The largest base range a bsdiff block reads into memory (the Dart code library is about 16 MB).
  static const maxBsdiffBase = 128 * 1024 * 1024;
}

/// One file a patch builds, as its header says.
class PatchEntry {
  const PatchEntry(this.path, this.size, this.sha256, this.baseSha256);
  final String path;
  final int size;
  final String sha256;

  /// The file the ops read from, or null when the file is built from the patch's data alone.
  final String? baseSha256;
}

const _magic = 'CAWPATCH';
const _opEnd = 0, _opCopy = 1, _opData = 2, _opBsdiff = 3;

String _hex(Uint8List b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

/// Reads a patch file: the header, then each file's ops through an inflater, a chunk at a time.
class PatchReader {
  PatchReader(String path) : _file = File(path).openSync() {
    final head = _file.readSync(9);
    if (head.length != 9 || ascii.decode(head.sublist(0, 8), allowInvalid: true) != _magic || head[8] != 1) {
      _file.closeSync();
      throw const PatchError('not a CAWPATCH v1 file');
    }
  }

  final RandomAccessFile _file;
  final RawZLibFilter _z = RawZLibFilter.inflateFilter(raw: true);
  Uint8List _buf = Uint8List(0);
  int _pos = 0;
  bool _inputDone = false, _drained = false;

  void close() => _file.closeSync();

  void _fill() {
    while (_pos >= _buf.length) {
      final out = _drained ? null : _z.processed(flush: false, end: _inputDone);
      if (out != null && out.isNotEmpty) {
        _buf = out is Uint8List ? out : Uint8List.fromList(out);
        _pos = 0;
        return;
      }
      if (_inputDone) {
        _drained = true;
        throw const PatchError('truncated');
      }
      final chunk = _file.readSync(1 << 16);
      if (chunk.isEmpty) {
        _inputDone = true;
      } else {
        _z.process(chunk, 0, chunk.length);
      }
    }
  }

  int byte() {
    _fill();
    return _buf[_pos++];
  }

  int varint() {
    var n = 0, scale = 1;
    for (var i = 0; i < 8; i++) {
      final b = byte();
      n += (b & 0x7f) * scale;
      if (b & 0x80 == 0) return n;
      scale *= 128;
    }
    throw const PatchError('a number is too long');
  }

  int svarint() {
    final n = varint();
    return n.isEven ? n ~/ 2 : -((n + 1) ~/ 2);
  }

  /// The next [n] bytes (small reads only: headers, hashes, paths).
  Uint8List take(int n) {
    final out = Uint8List(n);
    var at = 0;
    while (at < n) {
      _fill();
      final k = (_buf.length - _pos) < (n - at) ? _buf.length - _pos : n - at;
      out.setRange(at, at + k, _buf, _pos);
      _pos += k;
      at += k;
    }
    return out;
  }

  /// Passes the next [n] bytes to [sink] in the pieces they arrive in.
  void stream(int n, void Function(Uint8List piece) sink) {
    var left = n;
    while (left > 0) {
      _fill();
      final k = (_buf.length - _pos) < left ? _buf.length - _pos : left;
      sink(Uint8List.sublistView(_buf, _pos, _pos + k));
      _pos += k;
      left -= k;
    }
  }

  /// The number of files, read once before the first [entry].
  int count() {
    final n = varint();
    if (n > PatchLimits.maxFiles) throw const PatchError('too many files');
    return n;
  }

  PatchEntry entry() {
    final pathLength = varint();
    if (pathLength == 0 || pathLength > PatchLimits.maxPath) throw const PatchError('bad path');
    final String path;
    try {
      path = utf8.decode(take(pathLength));
    } on FormatException {
      throw const PatchError('bad path');
    }
    final size = varint();
    if (size > PatchLimits.maxFileBytes) throw const PatchError('a file is too large');
    final sha = _hex(take(32));
    final hasBase = byte();
    if (hasBase > 1) throw const PatchError('bad header');
    return PatchEntry(path, size, sha, hasBase == 1 ? _hex(take(32)) : null);
  }

  /// Writes [e]'s file to [out] from its ops, reading [base] (null when [e] has none), and returns its SHA-256.
  /// Throws [PatchError] for anything out of range or a file that does not hash to [PatchEntry.sha256].
  String build(PatchEntry e, RandomAccessFile? base, RandomAccessFile out) {
    if ((e.baseSha256 == null) != (base == null)) throw const PatchError('base file mismatch');
    final baseSize = base?.lengthSync() ?? 0;
    final hash = Sha256();
    var at = 0;
    void write(Uint8List piece) {
      out.writeFromSync(piece);
      hash.add(piece);
      at += piece.length;
    }

    final chunk = Uint8List(1 << 16);
    for (;;) {
      final op = byte();
      if (op == _opEnd) break;
      switch (op) {
        case _opCopy:
          final off = varint(), len = varint();
          if (base == null || off + len > baseSize || at + len > e.size) throw const PatchError('copy out of range');
          base.setPositionSync(off);
          for (var left = len; left > 0;) {
            final n = base.readIntoSync(chunk, 0, left < chunk.length ? left : chunk.length);
            if (n <= 0) throw const PatchError('the base file ended early');
            write(Uint8List.sublistView(chunk, 0, n));
            left -= n;
          }
        case _opData:
          final len = varint();
          if (at + len > e.size) throw const PatchError('data out of range');
          stream(len, write);
        case _opBsdiff:
          final bo = varint(), bl = varint(), nl = varint();
          if (base == null || bo + bl > baseSize || at + nl > e.size || bl > PatchLimits.maxBsdiffBase) {
            throw const PatchError('bsdiff out of range');
          }
          base.setPositionSync(bo);
          final old = Uint8List(bl);
          if (base.readIntoSync(old) != bl) throw const PatchError('the base file ended early');
          final end = at + nl;
          var pos = 0;
          while (at < end) {
            final x = varint(), y = varint(), z = svarint();
            if (at + x + y > end) throw const PatchError('bsdiff block out of range');
            stream(x, (piece) {
              final made = Uint8List(piece.length);
              for (var i = 0; i < piece.length; i++) {
                final o = pos + i;
                made[i] = (piece[i] + (o >= 0 && o < bl ? old[o] : 0)) & 0xff;
              }
              pos += piece.length;
              write(made);
            });
            stream(y, write);
            pos += z;
          }
        default:
          throw PatchError('unknown op $op');
      }
    }
    if (at != e.size) throw const PatchError('a rebuilt file has the wrong size');
    final got = hash.hex();
    if (got != e.sha256) throw const PatchError('a rebuilt file does not match its checksum');
    return got;
  }
}

/// Windows' reserved device names, which open a device instead of a file whatever the extension (`nul.txt`).
final _deviceName = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$', caseSensitive: false);

/// A relative path from a patch or manifest that is safe to write under the app's folder: '/'-separated, no `..`,
/// `.`, empty parts, drive letters, backslashes, control characters or Windows device names (`CON`, `NUL`, `AUX`,
/// `PRN`, `COM1`–`9`, `LPT1`–`9`, with or without an extension), and nothing inside the update's own `.caw-update/`.
bool safeRelativePath(String p) {
  if (p.isEmpty || p.length > PatchLimits.maxPath || p.startsWith('/') || p.contains('\\') || p.contains(':')) {
    return false;
  }
  if (p.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return false;
  final parts = p.split('/');
  if (parts.first.toLowerCase() == '.caw-update') return false;
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..' || part.endsWith('.') || part.endsWith(' ')) return false;
    if (_deviceName.hasMatch(part.split('.').first.trimRight())) return false;
  }
  return true;
}

/// Rebuilds one file (an APK) from [patchPath] and the [basePath] it was made against into [outPath]. The patch must
/// hold exactly one file whose base hashes to [baseSha256] and whose result is [wantSha256]. Returns the result's
/// SHA-256; on any problem the output is deleted and [PatchError] (or a file error) is thrown.
String rebuildSingleFile(
    {required String patchPath,
    required String basePath,
    required String baseSha256,
    required String outPath,
    required String wantSha256}) {
  final r = PatchReader(patchPath);
  final out = File(outPath);
  try {
    if (r.count() != 1) throw const PatchError('expected one file');
    final e = r.entry();
    if (e.baseSha256 != baseSha256) throw const PatchError('made for another build');
    if (e.sha256 != wantSha256) throw const PatchError('builds another file than the release publishes');
    final base = File(basePath).openSync();
    final sink = out.openSync(mode: FileMode.write);
    try {
      return r.build(e, base, sink);
    } finally {
      sink.closeSync();
      base.closeSync();
    }
  } catch (_) {
    try {
      if (out.existsSync()) out.deleteSync();
    } catch (_) {}
    rethrow;
  } finally {
    r.close();
  }
}

/// Builds every file of a files patch (the Windows app) under [stageDir], each read against the file of the same
/// path under [installDir] when it has a base. [expected] is the manifest's path → SHA-256 for the new build: every
/// file must be in it with that checksum. Returns the files staged (path → SHA-256). On any problem nothing is left
/// half-written: the caller clears [stageDir].
Map<String, String> stageFiles(
    {required String patchPath, required String installDir, required String stageDir, required Map<String, String> expected}) {
  final r = PatchReader(patchPath);
  final staged = <String, String>{};
  final seen = <String>{};
  try {
    final n = r.count();
    for (var i = 0; i < n; i++) {
      final e = r.entry();
      if (!safeRelativePath(e.path)) throw PatchError('unsafe path ${e.path}');
      if (expected[e.path] != e.sha256) throw PatchError('${e.path} is not this build\'s');
      // Windows' file names ignore case: data/App.so and data/app.so are one file.
      if (!seen.add(e.path.toLowerCase())) throw PatchError('${e.path} twice');
      RandomAccessFile? base;
      if (e.baseSha256 != null) {
        final local = '$installDir${Platform.pathSeparator}${e.path.replaceAll('/', Platform.pathSeparator)}';
        if (!File(local).existsSync() || sha256OfFileSync(local) != e.baseSha256) {
          throw PatchError('${e.path} here is not the build this patch starts from');
        }
        base = File(local).openSync();
      }
      final to = File('$stageDir${Platform.pathSeparator}${e.path.replaceAll('/', Platform.pathSeparator)}');
      to.parent.createSync(recursive: true);
      final sink = to.openSync(mode: FileMode.write);
      try {
        staged[e.path] = r.build(e, base, sink);
      } finally {
        sink.closeSync();
        base?.closeSync();
      }
    }
    return staged;
  } finally {
    r.close();
  }
}
