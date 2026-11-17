// Embedded metadata (#229): WAV INFO, acid, smpl and bext, ID3v2.3/2.4, FLAC Vorbis comments, and malformed or hostile files that must never throw or run away.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/model/music_key.dart';
import 'package:caw/model/sample_meta.dart';
import 'package:caw/model/sample_names.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

Uint8List _chunk(String id, List<int> body) {
  final b = BytesBuilder()
    ..add(ascii.encode(id))
    ..add(_u32(body.length))
    ..add(body);
  if (body.length.isOdd) b.addByte(0);
  return b.toBytes();
}

Uint8List _wav(List<Uint8List> chunks, {int dataBytes = 4800 * 4}) {
  final fmt = BytesBuilder()
    ..add(_u16(1))
    ..add(_u16(2))
    ..add(_u32(48000))
    ..add(_u32(48000 * 4))
    ..add(_u16(4))
    ..add(_u16(16));
  final body = BytesBuilder()
    ..add(ascii.encode('WAVE'))
    ..add(_chunk('fmt ', fmt.toBytes()))
    ..add(_chunk('data', Uint8List(dataBytes)));
  for (final c in chunks) {
    body.add(c);
  }
  final b = body.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('RIFF'))
        ..add(_u32(b.length))
        ..add(b))
      .toBytes();
}

Uint8List _acid({required bool oneShot, int root = 60, int beats = 8, double tempo = 124}) {
  final d = ByteData(24)
    ..setUint32(0, (oneShot ? 1 : 0) | 2, Endian.little)
    ..setUint16(4, root, Endian.little)
    ..setUint32(12, beats, Endian.little)
    ..setUint16(16, 4, Endian.little)
    ..setUint16(18, 4, Endian.little)
    ..setFloat32(20, tempo, Endian.little);
  return _chunk('acid', d.buffer.asUint8List());
}

Uint8List _info(Map<String, String> tags) {
  final b = BytesBuilder()..add(ascii.encode('INFO'));
  tags.forEach((id, text) => b.add(_chunk(id, [...latin1.encode(text), 0])));
  return _chunk('LIST', b.toBytes());
}

Uint8List _syncsafe(int v) => Uint8List.fromList([(v >> 21) & 0x7f, (v >> 14) & 0x7f, (v >> 7) & 0x7f, v & 0x7f]);

Uint8List _id3(int version, Map<String, String> frames, {int encoding = 3}) {
  final body = BytesBuilder();
  frames.forEach((id, text) {
    final data = <int>[encoding, ...(encoding == 3 ? utf8.encode(text) : latin1.encode(text))];
    body
      ..add(ascii.encode(id))
      ..add(version == 4 ? _syncsafe(data.length) : (Uint8List(4)..buffer.asByteData().setUint32(0, data.length)))
      ..add([0, 0])
      ..add(data);
  });
  body.add(Uint8List(16));  // padding
  final b = body.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([version, 0, 0])
        ..add(_syncsafe(b.length))
        ..add(b))
      .toBytes();
}

/// An MPEG-1 Layer III frame header at 128 kbit/s, 44.1 kHz, stereo, then zeros.
Uint8List _mp3Frames(int bytes) => Uint8List(bytes)
  ..[0] = 0xFF
  ..[1] = 0xFB
  ..[2] = 0x90
  ..[3] = 0x00;

Uint8List _flac({required Map<String, String> comments, int rate = 44100, int samples = 88200}) {
  final si = Uint8List(34);
  // Sample rate (20 bits) from bit 80, channels - 1 (3 bits), bits - 1 (5 bits), total samples (36 bits).
  si[10] = (rate >> 12) & 0xff;
  si[11] = (rate >> 4) & 0xff;
  si[12] = ((rate & 0x0f) << 4) | (1 << 1) | 0;  // 2 channels, bits-1 high bit 0
  si[13] = (15 << 4) | ((samples >> 32) & 0x0f);  // 16 bits per sample
  si[14] = (samples >> 24) & 0xff;
  si[15] = (samples >> 16) & 0xff;
  si[16] = (samples >> 8) & 0xff;
  si[17] = samples & 0xff;
  final vendor = utf8.encode('test');
  final vc = BytesBuilder()
    ..add(_u32(vendor.length))
    ..add(vendor)
    ..add(_u32(comments.length));
  comments.forEach((k, v) {
    final f = utf8.encode('$k=$v');
    vc
      ..add(_u32(f.length))
      ..add(f);
  });
  final c = vc.toBytes();
  Uint8List head(bool last, int type, int len) =>
      Uint8List.fromList([(last ? 0x80 : 0) | type, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff]);
  return (BytesBuilder()
        ..add(ascii.encode('fLaC'))
        ..add(head(false, 0, 34))
        ..add(si)
        ..add(head(true, 4, c.length))
        ..add(c)
        ..add(Uint8List(64)))
      .toBytes();
}

SampleMeta _read(Uint8List b) => readSampleMeta(BytesSource(b));

void main() {
  group('WAV', () {
    test('INFO, acid, smpl and bext', () {
      final smpl = ByteData(36 + 24)
        ..setUint32(12, 57, Endian.little)
        ..setUint32(28, 1, Endian.little);
      final bext = Uint8List(602);
      bext.setAll(0, ascii.encode('Warm pad, take 2'));
      bext.setAll(256, ascii.encode('Studio A'));
      final m = _read(_wav([
        _info({'INAM': 'Night Pad', 'IGNR': 'Ambient', 'IKEY': 'pad; warm, dark'}),
        _acid(oneShot: false, root: 57, beats: 8, tempo: 92.5),
        _chunk('smpl', smpl.buffer.asUint8List()),
        _chunk('bext', bext),
      ]));
      expect(m.format, 'wav');
      expect(m.title, 'Night Pad');
      expect(m.genre, 'Ambient');
      expect(m.keywords, ['pad', 'warm', 'dark']);
      expect(m.bpm, closeTo(92.5, 1e-4));
      expect(m.kind, SampleKind.loop);
      expect(m.beats, 8);
      expect(m.rootNote, 57);
      expect(m.loops, 1);
      expect(m.comment, 'Warm pad, take 2');
      expect(m.artist, 'Studio A');
      expect(m.sampleRate, 48000);
      expect(m.channels, 2);
      expect(m.seconds, closeTo(0.1, 1e-9));
    });
    test('an acid one-shot', () {
      final m = _read(_wav([_acid(oneShot: true, tempo: 0)]));
      expect(m.kind, SampleKind.oneShot);
      expect(m.bpm, isNull);  // 0 is not a tempo
    });
    test('an ID3 chunk inside a WAV', () {
      final m = _read(_wav([_chunk('id3 ', _id3(3, {'TBPM': '128', 'TKEY': 'Am'}, encoding: 0))]));
      expect(m.bpm, 128);
      expect(m.key, const MusicalKey(9, minor: true));
    });
  });

  group('ID3v2 and MP3', () {
    test('v2.3 and v2.4 frames', () {
      for (final v in [3, 4]) {
        final b = BytesBuilder()
          ..add(_id3(v, {'TBPM': '140', 'TKEY': 'F#m', 'TIT2': 'Hook', 'TCON': '(13)Pop', 'TPE1': 'Someone'}))
          ..add(_mp3Frames(16000));
        final m = _read(b.toBytes());
        expect(m.format, 'mp3');
        expect(m.bpm, 140);
        expect(m.key, const MusicalKey(6, minor: true));
        expect(m.title, 'Hook');
        expect(m.genre, 'Pop');
        expect(m.artist, 'Someone');
        expect(m.secondsApprox, isTrue);
        expect(m.seconds, closeTo(16000 * 8 / 128000, 1e-9));
        expect(m.sampleRate, 44100);
      }
    });
    test('UTF-16 text', () {
      final text = [0xFF, 0xFE, ...[for (final c in '125'.codeUnits) ...[c, 0]], 0, 0];
      final frame = BytesBuilder()
        ..add(ascii.encode('TBPM'))
        ..add(Uint8List(4)..buffer.asByteData().setUint32(0, text.length + 1))
        ..add([0, 0, 1])
        ..add(text);
      final f = frame.toBytes();
      final tag = (BytesBuilder()
            ..add(ascii.encode('ID3'))
            ..add([3, 0, 0])
            ..add(_syncsafe(f.length))
            ..add(f))
          .toBytes();
      expect(_read(tag).bpm, 125);
    });
  });

  group('FLAC', () {
    test('STREAMINFO and Vorbis comments', () {
      final m = _read(_flac(comments: {'BPM': '174', 'KEY': 'Dm', 'TITLE': 'Roller', 'GENRE': 'DnB'}));
      expect(m.format, 'flac');
      expect(m.bpm, 174);
      expect(m.key, const MusicalKey(2, minor: true));
      expect(m.title, 'Roller');
      expect(m.genre, 'DnB');
      expect(m.sampleRate, 44100);
      expect(m.channels, 2);
      expect(m.seconds, closeTo(2.0, 1e-9));
    });
  });

  group('malformed and hostile input', () {
    test('sizes past the end, zero and huge counts', () {
      // A chunk claiming 4 GB, a LIST claiming more than it holds, an acid chunk cut short.
      final bad = BytesBuilder()
        ..add(ascii.encode('RIFF'))
        ..add(_u32(100))
        ..add(ascii.encode('WAVE'))
        ..add(ascii.encode('LIST'))
        ..add(_u32(0xFFFFFFF0))
        ..add(ascii.encode('INFO'));
      expect(_read(bad.toBytes()).format, 'wav');
      expect(_read(_wav([_chunk('acid', [1, 2, 3])])).kind, isNull);
      // A FLAC Vorbis block with a comment count of four billion and a vendor length past the block.
      final flac = _flac(comments: {'BPM': '120'});
      final i = flac.indexOf(0x84);  // the last block's header (type 4)
      final evil = Uint8List.fromList(flac);
      evil.buffer.asByteData().setUint32(i + 4, 0xFFFFFFFF, Endian.little);
      expect(_read(evil).bpm, isNull);
      // An ID3 tag whose frame claims more than the tag; one with a 2^28 size.
      final id3 = _id3(4, {'TBPM': '99'});
      final cut = Uint8List.sublistView(id3, 0, 18);
      expect(_read(cut).bpm, isNull);
      final huge = Uint8List.fromList([...ascii.encode('ID3'), 4, 0, 0, 0x7f, 0x7f, 0x7f, 0x7f, ...ascii.encode('TBPM')]);
      expect(() => _read(huge), returnsNormally);
      // Text bounded, control characters cleaned.
      final long = _read(_wav([_info({'INAM': 'x\u0001${'y' * 5000}'})]));
      expect(long.title!.length, MetaLimits.text);
      expect(long.title!.contains('\u0001'), isFalse);
      // Empty, tiny and unknown files.
      expect(_read(Uint8List(0)).format, isNull);
      expect(_read(Uint8List.fromList([0x52, 0x49])).format, isNull);
      expect(_read(Uint8List.fromList(utf8.encode('not audio at all'))).isEmpty, isTrue);
      // Out-of-range values are dropped, not clamped into something plausible.
      expect(_read(_id3(3, {'TBPM': '12000', 'TKEY': 'Zm'}, encoding: 0)).bpm, isNull);
      expect(_read(_id3(3, {'TBPM': 'NaN'}, encoding: 0)).bpm, isNull);
    });
    test('fuzz: random bytes after valid headers never throw', () {
      final rnd = math.Random(229);
      final seeds = [_wav([_info({'INAM': 'a'}), _acid(oneShot: false)]), _id3(3, {'TBPM': '120'}), _id3(4, {'TKEY': 'C'}),
        _flac(comments: {'BPM': '90'})];
      var cases = 0;
      for (final seed in seeds) {
        for (var n = 0; n < 400; n++) {
          final b = Uint8List.fromList(seed);
          // Flip some bytes, truncate sometimes.
          for (var k = 0; k < 1 + rnd.nextInt(8); k++) {
            b[4 + rnd.nextInt(b.length - 4)] = rnd.nextInt(256);
          }
          final len = rnd.nextBool() ? b.length : 4 + rnd.nextInt(b.length - 4);
          final m = readSampleMeta(BytesSource(Uint8List.sublistView(b, 0, len)));
          if (m.bpm != null) expect(m.bpm, inInclusiveRange(20, 999));
          if (m.title != null) expect(m.title!.length, lessThanOrEqualTo(MetaLimits.text));
          expect(m.keywords.length, lessThanOrEqualTo(32));
          cases++;
        }
      }
      // Pure noise too.
      for (var n = 0; n < 400; n++) {
        final b = Uint8List.fromList([for (var i = 0; i < 64 + rnd.nextInt(512); i++) rnd.nextInt(256)]);
        if (n.isEven) b.setAll(0, ascii.encode('RIFF'));
        if (n % 4 == 0) b.setAll(8, ascii.encode('WAVE'));
        expect(() => readSampleMeta(BytesSource(b)), returnsNormally);
        cases++;
      }
      expect(cases, 2000);
    });
  });
}
