// Metadata embedded in audio files, read with hard limits (the files are untrusted): WAV INFO, acid, smpl, bext, ID3v2, FLAC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'music_key.dart';
import 'sample_names.dart';

/// Where the parsers read from: a file opened for reading, or bytes (tests).
abstract class ByteSource {
  int get length;

  /// Up to [n] bytes from [offset] (fewer at the end; empty past it).
  Uint8List read(int offset, int n);
}

class BytesSource implements ByteSource {
  BytesSource(this.bytes);
  final Uint8List bytes;
  @override
  int get length => bytes.length;
  @override
  Uint8List read(int offset, int n) {
    if (offset < 0 || offset >= bytes.length || n <= 0) return Uint8List(0);
    return Uint8List.sublistView(bytes, offset, offset + n > bytes.length ? bytes.length : offset + n);
  }
}

/// A file read synchronously (the indexer runs on a background isolate).
class FileSource implements ByteSource {
  FileSource(this._file) : length = _file.lengthSync();
  final RandomAccessFile _file;
  @override
  final int length;
  @override
  Uint8List read(int offset, int n) {
    if (offset < 0 || offset >= length || n <= 0) return Uint8List(0);
    _file.setPositionSync(offset);
    return _file.readSync(n);
  }
}

/// Hard limits on what one file may make the parsers do.
class MetaLimits {
  static const chunks = 256;               // RIFF chunks walked
  static const listBytes = 64 * 1024;      // a LIST chunk read
  static const smplLoops = 16;             // loops read from smpl
  static const text = 256;                 // characters kept of any text
  static const id3Bytes = 256 * 1024;      // of an ID3v2 tag read
  static const id3Frames = 512;
  static const flacBlocks = 128;
  static const vorbisBytes = 256 * 1024;   // a VORBIS_COMMENT block read
  static const vorbisComments = 512;
  static const vorbisField = 4096;
}

/// What a file's own metadata says. Null: not given.
class SampleMeta {
  String? title, genre, comment, artist;
  double? bpm;
  MusicalKey? key;
  SampleKind? kind;

  /// The acid chunk's beats (a loop's length in beats).
  int? beats;

  /// The root note (smpl's unity note, acid's root), MIDI number.
  int? rootNote;
  int loops = 0;
  double? seconds;

  /// True when [seconds] is an estimate (an MP3's from its first frame's bit rate).
  bool secondsApprox = false;
  int? sampleRate, channels;
  final List<String> keywords = [];

  /// The format the bytes are: wav, flac, mp3, or null (not one of them).
  String? format;

  bool get isEmpty => title == null && genre == null && bpm == null && key == null && kind == null && rootNote == null;
}

String _clean(String s) {
  final t = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return t.length > MetaLimits.text ? t.substring(0, MetaLimits.text) : t;
}

String _latin1(Uint8List b) {
  var end = b.indexOf(0);
  if (end < 0) end = b.length;
  return _clean(latin1.decode(Uint8List.sublistView(b, 0, end)));
}

double? _bpmText(String? s) {
  if (s == null) return null;
  final v = double.tryParse(s.trim().replaceAll(',', '.'));
  return v != null && v.isFinite && v >= 20 && v <= 999 ? v : null;
}

int _u32le(Uint8List b, int o) => o + 4 <= b.length ? ByteData.sublistView(b).getUint32(o, Endian.little) : 0;
int _u16le(Uint8List b, int o) => o + 2 <= b.length ? ByteData.sublistView(b).getUint16(o, Endian.little) : 0;

bool _tag(Uint8List b, int o, String id) {
  if (o + id.length > b.length) return false;
  for (var i = 0; i < id.length; i++) {
    if (b[o + i] != id.codeUnitAt(i)) return false;
  }
  return true;
}

/// Reads whatever metadata [src] carries. Never throws on malformed input: what can't be read is left out.
SampleMeta readSampleMeta(ByteSource src) {
  final meta = SampleMeta();
  try {
    final head = src.read(0, 12);
    if (_tag(head, 0, 'RIFF') && _tag(head, 8, 'WAVE')) {
      meta.format = 'wav';
      _readWav(src, meta);
    } else if (_tag(head, 0, 'fLaC')) {
      meta.format = 'flac';
      _readFlac(src, 4, meta);
    } else if (_tag(head, 0, 'ID3')) {
      final end = _readId3(src, meta);
      // A FLAC may start with an ID3 tag too (rare); MP3 otherwise.
      if (_tag(src.read(end, 4), 0, 'fLaC')) {
        meta.format = 'flac';
        _readFlac(src, end + 4, meta);
      } else {
        meta.format = 'mp3';
        _mp3Length(src, end, meta);
      }
    } else if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
      meta.format = 'mp3';
      _mp3Length(src, 0, meta);
    }
  } catch (_) {
    // A read failed part-way (a file that shrank): keep what was found.
  }
  return meta;
}

// ---------- WAV ----------

void _readWav(ByteSource src, SampleMeta meta) {
  var at = 12;
  int? dataBytes;
  var blockAlign = 0;
  for (var n = 0; n < MetaLimits.chunks && at + 8 <= src.length; n++) {
    final h = src.read(at, 8);
    if (h.length < 8) break;
    final id = latin1.decode(Uint8List.sublistView(h, 0, 4));
    final size = _u32le(h, 4);
    final body = at + 8;
    if (size > src.length - body && id != 'data') break;  // a chunk past the end: stop, keep what was read
    switch (id) {
      case 'fmt ':
        final f = src.read(body, size < 40 ? size : 40);
        meta.channels = _u16le(f, 2);
        meta.sampleRate = _u32le(f, 4);
        blockAlign = _u16le(f, 12);
      case 'data':
        dataBytes = size > src.length - body ? src.length - body : size;
      case 'LIST':
        final b = src.read(body, size < MetaLimits.listBytes ? size : MetaLimits.listBytes);
        if (_tag(b, 0, 'INFO')) _readInfo(b, meta);
      case 'acid':
        final b = src.read(body, 24);
        if (b.length >= 24) {
          final d = ByteData.sublistView(b);
          final flags = d.getUint32(0, Endian.little);
          meta.kind = (flags & 1) != 0 ? SampleKind.oneShot : SampleKind.loop;
          if ((flags & 2) != 0) {
            final root = d.getUint16(4, Endian.little);
            if (root < 128) meta.rootNote = root;
          }
          final beats = d.getUint32(12, Endian.little);
          if (beats > 0 && beats <= 4096) meta.beats = beats;
          final tempo = d.getFloat32(20, Endian.little);
          if (tempo.isFinite && tempo >= 20 && tempo <= 999) meta.bpm = tempo.toDouble();
        }
      case 'smpl':
        final b = src.read(body, 36 + MetaLimits.smplLoops * 24);
        if (b.length >= 36) {
          final unity = _u32le(b, 12);
          if (unity < 128 && meta.rootNote == null) meta.rootNote = unity;
          final loops = _u32le(b, 28);
          meta.loops = loops > MetaLimits.smplLoops ? MetaLimits.smplLoops : loops;
        }
      case 'bext':
        // EBU Tech 3285: Description (256 bytes), Originator (32), OriginatorReference (32), ...
        final b = src.read(body, 288);
        if (b.length >= 256) {
          final d = _latin1(Uint8List.sublistView(b, 0, 256));
          if (d.isNotEmpty) meta.comment ??= d;
        }
        if (b.length >= 288) {
          final o = _latin1(Uint8List.sublistView(b, 256, 288));
          if (o.isNotEmpty) meta.artist ??= o;
        }
      case 'id3 ' || 'ID3 ':
        final sub = _SliceSource(src, body, size);
        _readId3(sub, meta);
    }
    at = body + size + (size & 1);
  }
  final rate = meta.sampleRate ?? 0;
  if (dataBytes != null && rate > 0 && blockAlign > 0) meta.seconds = dataBytes / blockAlign / rate;
}

void _readInfo(Uint8List b, SampleMeta meta) {
  var at = 4;
  for (var n = 0; n < MetaLimits.chunks && at + 8 <= b.length; n++) {
    final id = latin1.decode(Uint8List.sublistView(b, at, at + 4));
    final size = _u32le(b, at + 4);
    final start = at + 8;
    if (size > b.length - start) break;
    final text = _latin1(Uint8List.sublistView(b, start, start + size));
    if (text.isNotEmpty) {
      switch (id) {
        case 'INAM': meta.title ??= text;
        case 'IGNR': meta.genre ??= text;
        case 'ICMT': meta.comment ??= text;
        case 'IART': meta.artist ??= text;
        case 'IKEY':
          for (final k in text.split(RegExp(r'[;,]'))) {
            final t = k.trim();
            if (t.isNotEmpty && meta.keywords.length < 32) meta.keywords.add(t);
          }
      }
    }
    at = start + size + (size & 1);
  }
}

class _SliceSource implements ByteSource {
  _SliceSource(this._src, this._at, int size) : length = size < 0 ? 0 : size;
  final ByteSource _src;
  final int _at;
  @override
  final int length;
  @override
  Uint8List read(int offset, int n) {
    if (offset < 0 || offset >= length || n <= 0) return Uint8List(0);
    return _src.read(_at + offset, offset + n > length ? length - offset : n);
  }
}

// ---------- ID3v2 ----------

int _syncsafe(Uint8List b, int o) => ((b[o] & 0x7f) << 21) | ((b[o + 1] & 0x7f) << 14) | ((b[o + 2] & 0x7f) << 7) | (b[o + 3] & 0x7f);

String _id3Text(Uint8List b) {
  if (b.isEmpty) return '';
  final enc = b[0];
  final body = Uint8List.sublistView(b, 1);
  String s;
  switch (enc) {
    case 1 || 2:
      // UTF-16 with a BOM (1) or big-endian (2); the first string only.
      var big = enc == 2;
      var o = 0;
      if (enc == 1 && body.length >= 2) {
        if (body[0] == 0xFE && body[1] == 0xFF) {
          big = true;
          o = 2;
        } else if (body[0] == 0xFF && body[1] == 0xFE) {
          o = 2;
        }
      }
      final units = <int>[];
      for (; o + 1 < body.length && units.length < MetaLimits.text; o += 2) {
        final u = big ? (body[o] << 8) | body[o + 1] : body[o] | (body[o + 1] << 8);
        if (u == 0) break;
        units.add(u);
      }
      s = String.fromCharCodes(units);
    case 3:
      var end = body.indexOf(0);
      if (end < 0) end = body.length;
      s = utf8.decode(Uint8List.sublistView(body, 0, end), allowMalformed: true);
    default:
      var end = body.indexOf(0);
      if (end < 0) end = body.length;
      s = latin1.decode(Uint8List.sublistView(body, 0, end));
  }
  return _clean(s);
}

/// Reads an ID3v2 tag at the start of [src] (v2.2, 2.3 or 2.4); returns where the audio after it starts.
int _readId3(ByteSource src, SampleMeta meta) {
  final h = src.read(0, 10);
  if (h.length < 10 || !_tag(h, 0, 'ID3')) return 0;
  final version = h[3];
  final flags = h[5];
  final size = _syncsafe(h, 6);
  final end = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
  if (version < 2 || version > 4) return end;
  // Unsynchronisation over the whole tag (v2.2/2.3) is rare in samples: such a tag is skipped, not misread.
  if ((flags & 0x80) != 0 && version < 4) return end;
  final tag = src.read(10, size < MetaLimits.id3Bytes ? size : MetaLimits.id3Bytes);
  var at = 0;
  if ((flags & 0x40) != 0 && version >= 3 && tag.length >= 4) {
    // Extended header: its size counts itself in 2.4 (syncsafe), not in 2.3.
    final ext = version == 4 ? _syncsafe(tag, 0) : ByteData.sublistView(tag).getUint32(0) + 4;
    at = ext;
  }
  final idLen = version == 2 ? 3 : 4, headLen = version == 2 ? 6 : 10;
  for (var n = 0; n < MetaLimits.id3Frames && at + headLen <= tag.length; n++) {
    if (tag[at] == 0) break;  // padding
    final id = latin1.decode(Uint8List.sublistView(tag, at, at + idLen));
    final int frameSize;
    if (version == 2) {
      frameSize = (tag[at + 3] << 16) | (tag[at + 4] << 8) | tag[at + 5];
    } else if (version == 4) {
      frameSize = _syncsafe(tag, at + 4);
    } else {
      frameSize = ByteData.sublistView(tag).getUint32(at + 4);
    }
    final start = at + headLen;
    if (frameSize <= 0 || frameSize > tag.length - start) break;
    final frameFlags = version == 2 ? 0 : (tag[at + 8] << 8) | tag[at + 9];
    // Compressed, encrypted or unsynchronised frames are skipped (v2.3: 0x00C0; v2.4: 0x000E with the data
    // length indicator 0x0001 handled below).
    final skip = version == 3 ? (frameFlags & 0x00C0) != 0 : version == 4 && (frameFlags & 0x000E) != 0;
    if (!skip && id.startsWith('T') && frameSize <= 64 * 1024) {
      var body = Uint8List.sublistView(tag, start, start + frameSize);
      if (version == 4 && (frameFlags & 0x0001) != 0 && body.length >= 4) body = Uint8List.sublistView(body, 4);
      final text = _id3Text(body);
      if (text.isNotEmpty) {
        switch (id) {
          case 'TBPM' || 'TBP':
            meta.bpm ??= _bpmText(text);
          case 'TKEY' || 'TKE':
            meta.key ??= MusicalKey.parse(text);
          case 'TIT2' || 'TT2':
            meta.title ??= text;
          case 'TCON' || 'TCO':
            // "(17)Rock" or "Rock": the words are kept, an ID3v1 genre number is not looked up.
            final g = text.replaceAll(RegExp(r'^\(\d+\)'), '').trim();
            if (g.isNotEmpty && int.tryParse(g) == null) meta.genre ??= g;
          case 'TPE1' || 'TP1':
            meta.artist ??= text;
        }
      }
    }
    at = start + frameSize;
  }
  return end;
}

// MPEG audio: bit rates (kbit/s) by version and index, Layer III; rates by version. An estimate from the first
// frame (a constant bit rate is assumed; a VBR file's length comes from the engine once it is played).
const _l3BitratesV1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const _l3BitratesV2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
const _ratesV1 = [44100, 48000, 32000, 0];

void _mp3Length(ByteSource src, int from, SampleMeta meta) {
  final b = src.read(from, 4096);
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
    final version = (b[i + 1] >> 3) & 3;  // 3: MPEG 1, 2: MPEG 2, 0: MPEG 2.5
    final layer = (b[i + 1] >> 1) & 3;    // 1: Layer III
    if (version == 1 || layer != 1) continue;
    final brIndex = b[i + 2] >> 4, srIndex = (b[i + 2] >> 2) & 3;
    final kbps = version == 3 ? _l3BitratesV1[brIndex] : _l3BitratesV2[brIndex];
    final base = _ratesV1[srIndex];
    if (kbps == 0 || base == 0) continue;
    final rate = version == 3 ? base : version == 2 ? base ~/ 2 : base ~/ 4;
    meta.sampleRate = rate;
    meta.channels = (b[i + 3] >> 6) == 3 ? 1 : 2;
    final audioBytes = src.length - from - i;
    meta.seconds = audioBytes * 8 / (kbps * 1000);
    meta.secondsApprox = true;
    return;
  }
}

// ---------- FLAC (RFC 9639) ----------

void _readFlac(ByteSource src, int at, SampleMeta meta) {
  for (var n = 0; n < MetaLimits.flacBlocks && at + 4 <= src.length; n++) {
    final h = src.read(at, 4);
    if (h.length < 4) break;
    final last = (h[0] & 0x80) != 0;
    final type = h[0] & 0x7f;
    final size = (h[1] << 16) | (h[2] << 8) | h[3];
    final body = at + 4;
    if (type == 127 || size > src.length - body) break;
    if (type == 0 && size >= 18) {
      final s = src.read(body, 18);
      // Sample rate: 20 bits from bit 80; channels - 1: 3 bits; bits - 1: 5; total samples: 36 bits.
      final rate = (s[10] << 12) | (s[11] << 4) | (s[12] >> 4);
      final channels = ((s[12] >> 1) & 7) + 1;
      final total = ((s[13] & 0x0f) * 4294967296) + ((s[14] << 24) | (s[15] << 16) | (s[16] << 8) | s[17]);
      if (rate > 0) {
        meta.sampleRate = rate;
        meta.channels = channels;
        if (total > 0) meta.seconds = total / rate;
      }
    } else if (type == 4) {
      _readVorbis(src.read(body, size < MetaLimits.vorbisBytes ? size : MetaLimits.vorbisBytes), meta);
    }
    if (last) break;
    at = body + size;
  }
}

void _readVorbis(Uint8List b, SampleMeta meta) {
  final vendor = _u32le(b, 0);
  var at = 4 + vendor;
  if (vendor > b.length || at + 4 > b.length) return;
  final count = _u32le(b, at);
  at += 4;
  for (var i = 0; i < count && i < MetaLimits.vorbisComments && at + 4 <= b.length; i++) {
    final len = _u32le(b, at);
    at += 4;
    if (len > b.length - at) return;
    if (len <= MetaLimits.vorbisField) {
      final field = utf8.decode(Uint8List.sublistView(b, at, at + len), allowMalformed: true);
      final eq = field.indexOf('=');
      if (eq > 0) {
        final name = field.substring(0, eq).toUpperCase();
        final value = _clean(field.substring(eq + 1));
        if (value.isNotEmpty) {
          switch (name) {
            case 'BPM' || 'TEMPO' || 'TBPM':
              meta.bpm ??= _bpmText(value);
            case 'KEY' || 'INITIALKEY' || 'TKEY':
              meta.key ??= MusicalKey.parse(value);
            case 'TITLE':
              meta.title ??= value;
            case 'GENRE':
              meta.genre ??= value;
            case 'ARTIST':
              meta.artist ??= value;
            case 'COMMENT' || 'DESCRIPTION':
              meta.comment ??= value;
          }
        }
      }
    }
    at += len;
  }
}

/// Reads the metadata of the file at [path] (a background isolate: synchronous I/O). Null when it can't be opened.
SampleMeta? readSampleMetaFile(String path) {
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    return readSampleMeta(FileSource(f));
  } catch (_) {
    return null;
  } finally {
    try {
      f?.closeSync();
    } catch (_) {}
  }
}
