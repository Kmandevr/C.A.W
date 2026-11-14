// Tempo detection and slices through the real engine (API 32, #208; needs CAW_LIB): a click track's tempo and its
// transients come back over dart:ffi from a worker isolate.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/engine/bindings.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_analysis.dart';
import 'package:caw/model/sample_edit.dart';
import 'package:caw/model/settings.dart';
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
    try {
      final wav = clickWav('${tmp.path}/c.wav', bpm: 128);
      final t = (await e.assetTempo(wav.path))!;
      expect(t['ok'], isTrue, reason: '${t['error']}');
      expect(t['bpm'], closeTo(128, 0.5));
      expect(t['confidence'], greaterThan(0.2));
      expect(t['candidates'], isNotEmpty);
      expect(tempoFromJson(t)!.bpm, closeTo(128, 0.5));

      final s = (await e.assetSlices(wav.path, startSeconds: 0, endSeconds: 4, minGapSeconds: 0.2))!;
      expect(s['ok'], isTrue, reason: '${s['error']}');
      expect(s['seconds'], closeTo(4, 1e-6));
      final period = 60 / 128;
      final slices = s['slices'] as List;
      expect(slices.length, (4 / period).ceil() - 1, reason: 'the click at 0 is the range start, not a slice');
      for (var k = 0; k < slices.length; k++) {
        final sl = slices[k] as Map;
        expect(sl['seconds'], closeTo((k + 1) * period, 0.002));
        expect(sl['frame'], closeTo((sl['seconds'] as num) * 48000, 1));
      }
      // The app's adapter reads the same answer as its cut points.
      expect(slicesFromJson(s, start: 0, end: 4)!.length, slices.length);

      final bad = (await e.assetSlices(wav.path, sensitivity: 2))!;
      expect(bad['ok'], isFalse);
      expect(bad['error'], contains('sensitivity'));
      expect((await e.assetTempo('${tmp.path}/missing.wav'))!['ok'], isFalse);
    } finally {
      e.dispose();
    }
  }, skip: skip);

  test('the sample editor asks the running engine (and the waveform peaks without one)', () async {
    final e = Engine.create();
    final s = AppState(settings: Settings())..engine = e;
    try {
      final wav = clickWav('${tmp.path}/c.wav', bpm: 140, seconds: 8);
      final t = await s.audioAnalysis.detectTempo(wav.path, seconds: 8);
      expect(t!.bpm, closeTo(140, 0.5));
      final cuts = await s.audioAnalysis.slicePoints(wav.path, start: 0, end: 2, sensitivity: 0.5);
      expect(cuts!.length, (2 * 140 / 60).ceil() - 1);
      expect(cuts.first, closeTo(60 / 140, 0.002));
      expect(await s.audioAnalysis.peak(wav.path, start: 0, end: 2), closeTo(0.8, 0.01));
    } finally {
      s.engine = null;
      s.dispose();
      e.dispose();
    }
  }, skip: skip);
}
