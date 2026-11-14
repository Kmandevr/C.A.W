// Tempo detection and slices through the real engine (API 32, #208; needs CAW_LIB): a click track's tempo and its
// transients come back over dart:ffi from a worker isolate.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/engine/audio_engine.dart';
import 'package:caw/engine/bindings.dart';
import 'package:caw/engine/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 16-bit mono WAV of [seconds] with a 2 ms, 2 kHz click every 60 / [bpm] seconds.
File clickWav(String path, {required double bpm, double seconds = 12, int rate = 48000}) {
  final frames = (seconds * rate).round();
  final period = rate * 60 / bpm;
  final pcm = Int16List(frames);
  for (var k = 0; k * period < frames; k++) {
    final at = (k * period).round();
    for (var i = 0; i < 96 && at + i < frames; i++) {
      pcm[at + i] = (0.8 * 32767 * math.sin(2 * math.pi * 2000 * i / rate)).round();
    }
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('caw-analysis'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the bindings carry API 32', () => expect(cawApiVersion, 32));

  test('a click track at 128 BPM is detected, and its clicks are the slices', () async {
    final e = Engine.create();
    final io = EngineAudioIo(() => e);
    try {
      final wav = clickWav('${tmp.path}/c.wav', bpm: 128);
      final t = await io.detectTempo(wav.path);
      expect(t.ok, isTrue, reason: t.error);
      expect(t.bpm, closeTo(128, 0.5));
      expect(t.confidence, greaterThan(0.2));
      expect(t.candidates, isNotEmpty);

      final s = await io.slices(wav.path, startSeconds: 0, endSeconds: 4, minGapSeconds: 0.2);
      expect(s.ok, isTrue, reason: s.error);
      expect(s.seconds, closeTo(4, 1e-6));
      final period = 60 / 128;
      expect(s.slices.length, (4 / period).ceil());
      for (var k = 0; k < s.slices.length; k++) {
        expect(s.slices[k].seconds, closeTo(k * period, 0.002));
        expect(s.slices[k].frame, closeTo(s.slices[k].seconds * 48000, 1));
      }

      final bad = await io.slices(wav.path, sensitivity: 2);
      expect(bad.ok, isFalse);
      expect(bad.error, contains('sensitivity'));
      expect((await io.detectTempo('${tmp.path}/missing.wav')).ok, isFalse);
    } finally {
      e.dispose();
    }
  }, skip: skip);
}
