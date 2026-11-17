// The sample browser's engine calls through the real engine (API 33, #229; needs CAW_LIB): the preview plays, seeks and stops, and the key estimate finds A minor.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/engine/sample_preview_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 16-bit mono WAV of an A minor triad (A3, C4, E4) for [seconds].
File chordWav(String path, {double seconds = 3, int rate = 44100}) {
  final frames = (seconds * rate).round();
  final pcm = Int16List(frames);
  for (var i = 0; i < frames; i++) {
    var v = 0.0;
    for (final f in [220.0, 261.63, 329.63]) {
      v += math.sin(2 * math.pi * f * i / rate);
    }
    pcm[i] = (0.2 * 32767 * v / 1.5).round().clamp(-32768, 32767);
  }
  final b = BytesBuilder();
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  b.add('RIFF'.codeUnits);
  u32(36 + frames * 2);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(rate);
  u32(rate * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(frames * 2);
  b.add(pcm.buffer.asUint8List());
  return File(path)..writeAsBytesSync(b.toBytes());
}

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('caw-preview'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('preview, seek, stop and the key estimate over dart:ffi', () async {
    final e = Engine.create();
    try {
      final io = EngineSamplePreviewIo(() => e);
      final wav = chordWav('${tmp.path}/am.wav');
      final key = await io.key(wav.path);
      expect(key['ok'], isTrue, reason: '${key['error']}');
      expect(key['tonic'], 9);
      expect(key['mode'], 'minor');
      final r = await io.play(wav.path, ratio: 1.5, loop: true, volume: 0.5);
      expect(r['ok'], isTrue, reason: '${r['error']}');
      expect(r['seconds'], closeTo(3, 1e-6));
      expect(r['stretch_ratio'], 1.5);
      expect(r['seq'], 1);
      // Through a track's effects: an id the engine doesn't know plays straight, and says so.
      final through = await io.play(wav.path, layer: 'no-such-track');
      expect(through['ok'], isTrue, reason: '${through['error']}');
      expect(through['layer'], isFalse);
      io.seek(1);
      io.setVolume(0.3);
      io.stop();
      final bad = await io.play('${tmp.path}/missing.wav');
      expect(bad['ok'], isFalse);
      expect(io.state().playing, isFalse);  // no audio device ran a callback
    } finally {
      e.dispose();
    }
  }, skip: skip);
}
