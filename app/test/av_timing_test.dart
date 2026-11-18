// The playhead's timing pieces from #241: a frame drawn for its vsync (FrameTime), the latency sheet's visual beat
// (the song's metronome phase, the stopped click loop and its WAV), and the system latency figure taken as the median
// of the timestamps less half a callback, with offsets set over an estimate keeping their total.
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/av_sync.dart';
import 'package:caw/model/latency_beat.dart';
import 'package:caw/model/latency_comp.dart';
import 'package:caw/model/tempo_map.dart';
import 'package:caw/platform/audio_route.dart';
import 'package:flutter_test/flutter_test.dart';

import 'latency_comp_test.dart' show FakeRoute, buds, mic, speaker;

DeviceLatency _out(double ms, {String source = 'timestamp', bool running = true}) => DeviceLatency(
    running: running, sampleRate: 48000,
    output: SideLatency(running: running, frames: (ms * 48).round(), ms: ms, source: source));

void main() {
  group('FrameTime', () {
    test('every frame is drawn for its vsync, however late its build starts', () {
      final f = FrameTime();
      // The vsync clock runs 5 s behind the app's; builds start 1 to 6 ms after their vsync.
      const late = [1000, 6000, 2000, 4500, 1200, 3000];
      final drawn = <int>[];
      for (var i = 0; i < late.length; i++) {
        final vsync = i * 8333;
        drawn.add(f.at(nowUs: vsync + 5000000 + late[i], vsyncUs: vsync));
      }
      final steps = [for (var i = 1; i < drawn.length; i++) drawn[i] - drawn[i - 1]];
      // After the first frame the offset is the smallest gap seen, plus at most the creep: even steps.
      for (final d in steps.skip(1)) {
        expect(d, closeTo(8333, FrameTime.creepUs * 2), reason: '$steps');
      }
      expect(f.at(nowUs: 123, vsyncUs: null), 123, reason: 'outside a frame: now');
      // Every call in one frame gets the same time.
      final again = f.at(nowUs: 5 * 8333 + 5000000 + 9000, vsyncUs: 5 * 8333);
      expect(again, drawn.last);
    });

    test('a stale vsync is not used', () {
      final f = FrameTime();
      f.at(nowUs: 1000, vsyncUs: 0);
      expect(f.at(nowUs: 1000 + 200000, vsyncUs: 10), 201000);
    });
  });

  group('the visual beat', () {
    test('the song\'s phase is 0 on each tick of the signature', () {
      const sigs = [TimeSignature(0, 0, 4, 4), TimeSignature(2, 8, 6, 8)];
      expect(songBeatPhase(0, sigs), 0);
      expect(songBeatPhase(2, sigs), 0.5);
      expect(songBeatPhase(4, sigs), 0);
      // From beat 8 (step 32), 6/8: a tick every eighth note (2 steps).
      expect(songBeatPhase(33, sigs), closeTo(0.5, 1e-9));
      expect(songBeatPhase(34, sigs), closeTo(0, 1e-9));
    });

    test('the click loop is one beat: a click at its start, silence after', () {
      final wav = clickLoopWav(sampleRate: 48000, seconds: 0.5);
      final d = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(d.getUint32(40, Endian.little), 24000 * 2);
      expect(d.getInt16(44 + 40 * 2, Endian.little).abs(), greaterThan(1000), reason: 'the click');
      expect(d.getInt16(44 + 20000 * 2, Endian.little), 0, reason: 'then silence');
    });

    test('stopped, the loop\'s beat is drawn as the playhead is: the lead on, the output latency back', () {
      final b = LoopBeat();
      var now = 1000000;
      // The preview voice plays 0.6 s of file a beat; reads every 33 ms.
      b.read(seconds: 0, length: 0.6, atUs: now, playing: true);
      now += 33000;
      b.read(seconds: 0.033, length: 0.6, atUs: now, playing: true);
      expect(b.running, isTrue);
      // At the read, rendered at 0.033 s: heard 100 ms later, drawn 21.7 ms ahead.
      final p = b.phase(nowUs: now, leadUs: 21700, outputLatencyUs: 100000);
      expect(p, closeTo((0.033 + 0.0217 - 0.1 + 0.6) / 0.6, 1e-6));
      // A click is seen when the heard moment crosses the loop's start: rendered 0.1 s - 0.0217 s.
      final at = b.phase(nowUs: now + ((0.1 - 0.0217 - 0.033) * 1e6).round(), leadUs: 21700, outputLatencyUs: 100000);
      expect(at < 0.001 || at > 0.999, isTrue, reason: '$at');
    });
  });

  group('the system figure', () {
    test('the median of the timestamps, less half a callback', () async {
      final figures = [58.0, 70.0, 52.0, 66.0, 61.0];
      var i = 0;
      final l = LatencyComp(route: FakeRoute(const AudioRouteInfo(output: speaker, input: mic)))
        ..readDevice = (() => _out(figures[i]))
        ..callbackFrames = () => 1024;
      addTearDown(l.dispose);
      for (i = 0; i < figures.length; i++) {
        await l.refresh();
      }
      // Median 61 ms, less 512 frames at 48 kHz (10.67 ms).
      expect(l.platformOutputMs, closeTo(61 - 512 / 48, 1e-9));
      expect(l.outputMs, closeTo(61 - 512 / 48, 1e-9), reason: 'the built-in speaker has no preset on top');
    });

    test('an offset set over the buffers\' estimate keeps its total once timestamps come (300 ms before #241)', () async {
      // Bluetooth buds: right after the device opens the engine has only its queued buffers (21 ms); the user slides
      // to 200 ms where the click looks right; then AAudio's timestamps say 121 ms.
      var dev = _out(21.3, source: 'buffers');
      final l = LatencyComp(route: FakeRoute(const AudioRouteInfo(output: buds, input: mic)))
        ..readDevice = () => dev;
      addTearDown(l.dispose);
      await l.refresh();
      l.setOutputTotalMs(200, source: OffsetSource.slider);
      expect(l.outputMs, 200);
      dev = _out(121);
      await l.refresh();
      expect(l.outputMs, 200, reason: 'was 121 + 178.7 = 299.7: the delay counted twice');
      expect(l.outputOffset.extraMs, closeTo(79, 1e-9));
      expect(l.outputNeedsCheck, isFalse);
      // Set over a settled timestamp it rides on a later settled figure (a new codec), and asks for a check.
      for (var i = 0; i < LatencyComp.settleRuns; i++) {
        await l.refresh();
      }
      l.setOutputTotalMs(200, source: OffsetSource.slider);
      dev = _out(160);
      for (var i = 0; i < 5; i++) {
        await l.refresh(); // the median follows once most reads say so
      }
      expect(l.outputMs, closeTo(239, 1e-9));
      expect(l.outputNeedsCheck, isTrue);
    });

    test('a wired output with the playing buffer counts the system figure once', () async {
      // A wired headset, the 1024-frame playing buffer: AAudio's timestamps hold the buffer already.
      final l = LatencyComp(route: FakeRoute(const AudioRouteInfo(
          output: AudioEndpoint(id: 9, name: 'Headset', kind: AudioDeviceKind.wired), input: mic)))
        ..readDevice = (() => _out(64))
        ..callbackFrames = () => 1024;
      addTearDown(l.dispose);
      await l.refresh();
      expect(l.outputOffset.extraMs, 0, reason: 'no preset on a wired output');
      expect(l.outputMs, closeTo(64 - 512 / 48, 1e-9));
    });
  });
}
