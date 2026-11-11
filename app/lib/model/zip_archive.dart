// A small zip reader and writer for .caw project packages (no dependency): stored or deflated entries through
// dart:io's raw deflate, no zip64, no encryption. The reader treats the file as untrusted: every name, size and
// offset is checked before a byte is written, and an entry inflates only up to the size it declared.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What an archive may hold. A package that passes them still has each entry checked against its own limit.
class ZipLimits {
  const ZipLimits({
    this.maxEntries = 20000,
    this.maxEntryBytes = 1 << 30,
    this.maxTotalBytes = 4 << 30,
    this.maxDirectoryBytes = 16 << 20,
  });

  final int maxEntries, maxEntryBytes, maxTotalBytes, maxDirectoryBytes;
}

/// The archive is not one this reader opens (damaged, unsafe, too large or a kind it doesn't read).
class ZipException implements Exception {
  const ZipException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One file in an archive, as its central directory describes it.
class ZipEntry {
  const ZipEntry(this.name, this.method, this.crc, this.compressedSize, this.size, this.localOffset);
  final String name;
  final int method, crc, compressedSize, size, localOffset;
}

/// A path inside an archive this app writes or reads: relative, `/`-separated, each part plain (letters, digits,
/// space and `. _ - ( ) + #`), never `.`, `..`, empty, a drive (`:`), a backslash or a control character.
bool isSafeArchivePath(String name) {
  if (name.isEmpty || name.length > 240 || name.startsWith('/') || name.contains('\\') || name.contains(':')) {
    return false;
  }
  final parts = name.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..' || !_safePart.hasMatch(part) || part.startsWith('.')) return false;
  }
  return true;
}

final _safePart = RegExp(r'^[A-Za-z0-9 ._()+#-]{1,128}$');

// ---------- CRC-32 (ISO-HDLC, as zip uses) ----------

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// Adds [data] to a running CRC-32 (start from 0).
int crc32(List<int> data, [int crc = 0]) {
  var c = crc ^ 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

// ---------- writing ----------

/// Writes a zip file entry by entry (synchronous: run it off the UI isolate). Entries are stored, or deflated when
/// that makes them smaller; sizes stay under 4 GB each (no zip64).
class ZipWriter {
  ZipWriter._(this._out);

  static ZipWriter create(String path) => ZipWriter._(File(path).openSync(mode: FileMode.write));

  final RandomAccessFile _out;
  final List<(ZipEntry, Uint8List)> _central = [];
  final Set<String> _names = {};

  static const _limit = 0xFFFFFFFF;

  void _check(String name, int size) {
    if (!isSafeArchivePath(name)) throw ZipException('Unsafe name in the archive: $name');
    if (!_names.add(name.toLowerCase())) throw ZipException('Two files named $name');
    if (size >= _limit) throw ZipException('$name is over 4 GB');
    if (_central.length >= 65535) throw const ZipException('Too many files for one archive');
  }

  /// Adds [bytes] as [name], deflated when [deflate] and smaller.
  void addBytes(String name, List<int> bytes, {bool deflate = true}) {
    _check(name, bytes.length);
    final crc = crc32(bytes);
    var data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    var method = 0;
    if (deflate && bytes.isNotEmpty) {
      final packed = ZLibEncoder(raw: true, level: 6).convert(bytes);
      if (packed.length < bytes.length) {
        data = Uint8List.fromList(packed);
        method = 8;
      }
    }
    final nameBytes = utf8.encode(name);
    final offset = _out.positionSync();
    _out.writeFromSync(_localHeader(nameBytes, method, crc, data.length, bytes.length));
    _out.writeFromSync(data);
    _central.add((ZipEntry(name, method, crc, data.length, bytes.length, offset), nameBytes));
  }

  /// Adds the file at [path] as [name], stored (audio and libraries don't deflate much), a chunk at a time.
  void addFile(String name, String path) {
    final src = File(path).openSync();
    try {
      final size = src.lengthSync();
      _check(name, size);
      final buffer = Uint8List(1 << 16);
      var crc = 0;
      for (var n = src.readIntoSync(buffer); n > 0; n = src.readIntoSync(buffer)) {
        crc = crc32(Uint8List.sublistView(buffer, 0, n), crc);
      }
      final nameBytes = utf8.encode(name);
      final offset = _out.positionSync();
      _out.writeFromSync(_localHeader(nameBytes, 0, crc, size, size));
      src.setPositionSync(0);
      var copied = 0;
      for (var n = src.readIntoSync(buffer); n > 0; n = src.readIntoSync(buffer)) {
        _out.writeFromSync(buffer, 0, n);
        copied += n;
      }
      if (copied != size) throw ZipException('$path changed while it was packaged');
      _central.add((ZipEntry(name, 0, crc, size, size, offset), nameBytes));
    } finally {
      src.closeSync();
    }
  }

  /// Writes the central directory and closes the file.
  void close() {
    try {
      final start = _out.positionSync();
      for (final (e, nameBytes) in _central) {
        final h = ByteData(46);
        h.setUint32(0, 0x02014b50, Endian.little);
        h.setUint16(4, 20, Endian.little); // made by: MS-DOS / zip 2.0
        h.setUint16(6, 20, Endian.little);
        h.setUint16(8, 0x0800, Endian.little); // UTF-8 names
        h.setUint16(10, e.method, Endian.little);
        h.setUint16(12, 0, Endian.little);
        h.setUint16(14, 0x21, Endian.little); // 1980-01-01
        h.setUint32(16, e.crc, Endian.little);
        h.setUint32(20, e.compressedSize, Endian.little);
        h.setUint32(24, e.size, Endian.little);
        h.setUint16(28, nameBytes.length, Endian.little);
        h.setUint32(42, e.localOffset, Endian.little);
        _out.writeFromSync(h.buffer.asUint8List());
        _out.writeFromSync(nameBytes);
      }
      final end = _out.positionSync();
      if (end >= _limit) throw const ZipException('The archive is over 4 GB');
      final eocd = ByteData(22);
      eocd.setUint32(0, 0x06054b50, Endian.little);
      eocd.setUint16(8, _central.length, Endian.little);
      eocd.setUint16(10, _central.length, Endian.little);
      eocd.setUint32(12, end - start, Endian.little);
      eocd.setUint32(16, start, Endian.little);
      _out.writeFromSync(eocd.buffer.asUint8List());
    } finally {
      _out.closeSync();
    }
  }

  /// Closes without finishing (a failed export); the caller deletes the file.
  void abandon() {
    try {
      _out.closeSync();
    } catch (_) {}
  }

  static Uint8List _localHeader(Uint8List name, int method, int crc, int compressed, int size) {
    final h = ByteData(30 + name.length);
    h.setUint32(0, 0x04034b50, Endian.little);
    h.setUint16(4, 20, Endian.little);
    h.setUint16(6, 0x0800, Endian.little);
    h.setUint16(8, method, Endian.little);
    h.setUint16(12, 0x21, Endian.little);
    h.setUint32(14, crc, Endian.little);
    h.setUint32(18, compressed, Endian.little);
    h.setUint32(22, size, Endian.little);
    h.setUint16(26, name.length, Endian.little);
    final out = h.buffer.asUint8List();
    out.setRange(30, 30 + name.length, name);
    return out;
  }
}

// ---------- reading ----------

/// Reads a zip file someone else made (synchronous: run it off the UI isolate). [open] checks the whole central
/// directory first; [readBytes] and [extract] check each entry's local header, size and CRC as they read it.
class ZipReader {
  ZipReader._(this._file, this._length, this._directoryStart, this.entries);

  final RandomAccessFile _file;
  final int _length, _directoryStart;

  /// The files, in archive order (folders left out).
  final List<ZipEntry> entries;

  ZipEntry? operator [](String name) => entries.where((e) => e.name == name).firstOrNull;

  /// Whether [bytes] start like a zip file.
  static bool looksLikeZip(List<int> bytes) =>
      bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] == 0x03 && bytes[3] == 0x04;

  static ZipReader open(String path, {ZipLimits limits = const ZipLimits()}) {
    final file = File(path).openSync();
    try {
      return _open(file, limits);
    } catch (_) {
      file.closeSync();
      rethrow;
    }
  }

  static ZipReader _open(RandomAccessFile file, ZipLimits limits) {
    final length = file.lengthSync();
    if (length < 22) throw const ZipException('Not a zip archive (too short)');
    final tailLength = length < 22 + 65535 ? length : 22 + 65535;
    file.setPositionSync(length - tailLength);
    final tail = file.readSync(tailLength);
    var at = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
        at = i;
        break;
      }
    }
    if (at < 0) throw const ZipException('Not a zip archive (no directory)');
    final eocd = ByteData.sublistView(tail, at);
    final disk = eocd.getUint16(4, Endian.little), cdDisk = eocd.getUint16(6, Endian.little);
    final onDisk = eocd.getUint16(8, Endian.little), count = eocd.getUint16(10, Endian.little);
    final cdSize = eocd.getUint32(12, Endian.little), cdOffset = eocd.getUint32(16, Endian.little);
    final eocdPosition = length - tailLength + at;
    if (disk != 0 || cdDisk != 0 || onDisk != count) throw const ZipException('Split archives are not read');
    if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      throw const ZipException('Zip64 archives are not read');
    }
    if (count > limits.maxEntries) throw ZipException('Too many files in the archive ($count)');
    if (cdSize > limits.maxDirectoryBytes || cdOffset + cdSize > eocdPosition) {
      throw const ZipException('The archive\'s directory is damaged');
    }
    file.setPositionSync(cdOffset);
    final cd = file.readSync(cdSize);
    if (cd.length != cdSize) throw const ZipException('The archive is cut short');
    final view = ByteData.sublistView(cd);
    final entries = <ZipEntry>[];
    final seen = <String>{};
    var total = 0, p = 0;
    for (var i = 0; i < count; i++) {
      if (p + 46 > cd.length || view.getUint32(p, Endian.little) != 0x02014b50) {
        throw const ZipException('The archive\'s directory is damaged');
      }
      final flags = view.getUint16(p + 8, Endian.little), method = view.getUint16(p + 10, Endian.little);
      final crc = view.getUint32(p + 16, Endian.little);
      final csize = view.getUint32(p + 20, Endian.little), usize = view.getUint32(p + 24, Endian.little);
      final nameLength = view.getUint16(p + 28, Endian.little), extra = view.getUint16(p + 30, Endian.little);
      final comment = view.getUint16(p + 32, Endian.little);
      final external = view.getUint32(p + 38, Endian.little), offset = view.getUint32(p + 42, Endian.little);
      if (p + 46 + nameLength + extra + comment > cd.length) throw const ZipException('The archive\'s directory is damaged');
      final String name;
      try {
        name = utf8.decode(Uint8List.sublistView(cd, p + 46, p + 46 + nameLength));
      } on FormatException {
        throw const ZipException('A name in the archive is not readable');
      }
      p += 46 + nameLength + extra + comment;
      final folder = name.endsWith('/');
      final bare = folder ? name.substring(0, name.length - 1) : name;
      if (!isSafeArchivePath(bare)) throw ZipException('Unsafe path in the archive: $name');
      if ((external >> 16) & 0xF000 == 0xA000) throw ZipException('Links are not allowed in the archive: $name');
      if (folder) continue;
      if ((flags & 0x1) != 0) throw ZipException('Encrypted files are not read: $name');
      if (method != 0 && method != 8) throw ZipException('$name uses a compression this app doesn\'t read');
      if (csize == 0xFFFFFFFF || usize == 0xFFFFFFFF) throw const ZipException('Zip64 archives are not read');
      if (method == 0 && csize != usize) throw ZipException('$name is damaged');
      if (!seen.add(name.toLowerCase())) throw ZipException('Two files named $name in the archive');
      if (usize > limits.maxEntryBytes) throw ZipException('$name is too large');
      total += usize;
      if (total > limits.maxTotalBytes) throw const ZipException('The archive unpacks to more than this app takes');
      if (offset + 30 + csize > cdOffset) throw ZipException('$name is damaged');
      entries.add(ZipEntry(name, method, crc, csize, usize, offset));
    }
    return ZipReader._(file, length, cdOffset, entries);
  }

  /// Where [e]'s data starts, after its local header (which must name the same file).
  int _dataStart(ZipEntry e) {
    _file.setPositionSync(e.localOffset);
    final h = _file.readSync(30);
    final v = ByteData.sublistView(h);
    if (h.length != 30 || v.getUint32(0, Endian.little) != 0x04034b50) throw ZipException('${e.name} is damaged');
    final n = v.getUint16(26, Endian.little), extra = v.getUint16(28, Endian.little);
    final name = _file.readSync(n);
    if (utf8.decode(name, allowMalformed: true) != e.name) throw ZipException('${e.name} is damaged');
    final start = e.localOffset + 30 + n + extra;
    if (start + e.compressedSize > _directoryStart || start + e.compressedSize > _length) {
      throw ZipException('${e.name} is damaged');
    }
    return start;
  }

  /// Streams [e]'s bytes to [sink], at most its declared size, then checks its size and CRC.
  void _read(ZipEntry e, void Function(Uint8List chunk) sink) {
    _file.setPositionSync(_dataStart(e));
    final buffer = Uint8List(1 << 16);
    var left = e.compressedSize, produced = 0, crc = 0;
    void emit(List<int> out) {
      if (out.isEmpty) return;
      produced += out.length;
      if (produced > e.size) throw ZipException('${e.name} unpacks to more than it says');
      final chunk = out is Uint8List ? out : Uint8List.fromList(out);
      crc = crc32(chunk, crc);
      sink(chunk);
    }

    final inflate = e.method == 8 ? RawZLibFilter.inflateFilter(raw: true) : null;
    while (left > 0) {
      final n = _file.readIntoSync(buffer, 0, left < buffer.length ? left : buffer.length);
      if (n <= 0) throw ZipException('${e.name} is cut short');
      left -= n;
      final piece = Uint8List.sublistView(buffer, 0, n);
      if (inflate == null) {
        emit(Uint8List.fromList(piece));
      } else {
        inflate.process(piece, 0, n);
        for (List<int>? out = inflate.processed(flush: false); out != null; out = inflate.processed(flush: false)) {
          emit(out);
        }
      }
    }
    if (inflate != null) {
      try {
        for (List<int>? out = inflate.processed(end: true); out != null; out = inflate.processed(end: true)) {
          emit(out);
        }
      } on FileSystemException {
        throw ZipException('${e.name} is damaged');
      }
    }
    if (produced != e.size || crc != e.crc) throw ZipException('${e.name} is damaged (size or checksum)');
  }

  /// [e]'s bytes; refused over [maxBytes].
  Uint8List readBytes(ZipEntry e, {int maxBytes = 64 << 20}) {
    if (e.size > maxBytes) throw ZipException('${e.name} is too large');
    final out = BytesBuilder(copy: false);
    _read(e, out.add);
    return out.takeBytes();
  }

  /// Writes [e] to a new file at [path] (it must not exist yet), refused over [maxBytes]. A failure deletes it.
  void extract(ZipEntry e, String path, {int? maxBytes}) {
    if (maxBytes != null && e.size > maxBytes) throw ZipException('${e.name} is too large');
    final f = File(path);
    final out = f.openSync(mode: FileMode.writeOnly);
    try {
      _read(e, (chunk) => out.writeFromSync(chunk));
      out.closeSync();
    } catch (_) {
      out.closeSync();
      if (f.existsSync()) f.deleteSync();
      rethrow;
    }
  }

  void close() => _file.closeSync();
}
