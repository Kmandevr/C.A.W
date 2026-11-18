// Every way of setting a latency (tap-along, the loopback ping series, typing a total) keeps the total it set when
// the system's own figure gets better or comes back after a reopen: 1.0.5-alpha.2 fixed this for the slider only,
// and the owner found tap-along still counting the system's latency twice (#241, 1.0.5-alpha.3).
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/latency_comp.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/audio_route.dart';
import 'package:caw/ui/settings/latency_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'latency_comp_test.dart' show FakeRoute, buds, mic;
import 'latency_sync_test.dart' show ScriptedPings;

/// The device as the engine reports it: each side's figure and where it came from.
DeviceLatency _dev(double outMs, {String out = 'timestamp', double inMs = 10, String inSource = 'buffers'}) =>
    DeviceLatency(running: true, sampleRate: 48000,
        output: SideLatency(running: true, frames: (outMs * 48).round(), ms: outMs, source: out),
        input: SideLatency(running: true, frames: (inMs * 48).round(), ms: inMs, source: inSource));

/// Eight taps, each [leadMs] after its beat at 120 BPM (a step is 125 ms), as the tap-along dialog collects them.
List<double> _taps(double leadMs) => [for (var b = 1; b <= 8; b++) b * 4 + leadMs / 125];

void main() {
  late DeviceLatency dev;
  LatencyComp comp() {
    final l = LatencyComp(route: FakeRoute(const AudioRouteInfo(output: buds, input: mic)))..readDevice = () => dev;
    addTearDown(l.dispose);
    return l;
  }

  Future<void> reads(LatencyComp l, int n) async {
    for (var i = 0; i < n; i++) {
      await l.refresh();
    }
  }

  group('tap-along', () {
    test('tapped over a Bluetooth link\'s first timestamp, the total stands once they settle (was 340 ms)', () async {
      // The tap ends just after the first timestamp read (the 3 s refresh): AAudio says 40 ms while the link
      // settles, then 180.
      dev = _dev(40);
      final l = comp();
      await l.refresh();
      final ms = tapAlongMs(_taps(200), bpm: 120)!;
      expect(ms, closeTo(200, 1e-9));
      l.setOutputTotalMs(ms, source: OffsetSource.tapped); // what the Latency page's Tap does with the result
      expect(l.outputMs, closeTo(200, 1e-9));
      dev = _dev(180);
      await reads(l, LatencyComp.settleRuns + 2);
      expect(l.outputMs, closeTo(200, 1e-9), reason: 'was 180 + (200 - 40) = 340: the system part counted twice');
      expect(l.outputOffset.extraMs, closeTo(20, 1e-9));
      expect(l.outputOffset.source, OffsetSource.tapped);
      expect(l.outputNeedsCheck, isFalse, reason: 'set over a figure that had not settled');
    });

    test('tapped over the buffers\' estimate, with the timestamps arriving after the tap', () async {
      dev = _dev(21.3, out: 'buffers');
      final l = comp();
      await l.refresh();
      l.setOutputTotalMs(tapAlongMs(_taps(200), bpm: 120)!, source: OffsetSource.tapped);
      expect(l.outputMs, closeTo(200, 1e-9));
      dev = _dev(121);
      for (var i = 0; i < LatencyComp.settleRuns + 2; i++) {
        await l.refresh();
        expect(l.outputMs, closeTo(200, 1e-9), reason: 'read ${i + 1}');
      }
    });

    test('tapped over settled timestamps: a reopen\'s estimate keeps the total, a real change rides', () async {
      dev = _dev(110);
      final l = comp();
      await reads(l, LatencyComp.settleRuns);
      l.setOutputTotalMs(tapAlongMs(_taps(200), bpm: 120)!, source: OffsetSource.tapped);
      // Stopped a while, the device closed; Play opens it again and the first reads are its buffers.
      dev = _dev(21.3, out: 'buffers');
      await l.refresh();
      expect(l.outputMs, closeTo(200, 1e-9), reason: 'was 21.3 + 90 = 111.3');
      dev = _dev(110);
      await reads(l, LatencyComp.settleRuns);
      expect(l.outputMs, closeTo(200, 1e-9));
      // A smaller buffer: the settled figure moves for real, the total rides on it and asks for a check.
      dev = _dev(60);
      await reads(l, LatencyComp.settleRuns);
      expect(l.outputMs, closeTo(150, 1e-9));
      expect(l.outputNeedsCheck, isTrue);
    });
  });

  group('the loopback ping series', () {
    test('the split takes the output\'s total, not the estimate it reads while the input opens (it counted the output\'s system part twice)', () async {
      dev = _dev(121);
      final s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: buds, input: mic)));
      final io = ScriptedPings([300, 300, 301, 299, 300]);
      s.audioIo = io;
      s.latency.readDevice = () => dev;
      final rec = AudioRecorder(s, prefs: AudioInputPrefs());
      addTearDown(() {
        rec.dispose();
        s.dispose();
      });
      await reads(s.latency, LatencyComp.settleRuns);
      s.latency.setOutputTotalMs(200, source: OffsetSource.tapped);
      // The input opening for the ping reopens the stream: the output reads its buffers, the input its own.
      dev = _dev(21.3, out: 'buffers', inMs: 10);
      await s.latency.refresh();
      final p = await rec.ping(poll: Duration.zero);
      expect(p!.reliable, isTrue);
      expect(s.latency.inputMs, closeTo(100, 1e-9), reason: 'was 300 - (21.3 + 79) = 199.7');
      expect(s.latency.roundTripMs, closeTo(300, 1e-9));
      // The timestamps come back, the input's too: the round trip is still the one measured.
      dev = _dev(121, inMs: 40, inSource: 'timestamp');
      await reads(s.latency, LatencyComp.settleRuns);
      expect(s.latency.outputMs, closeTo(200, 1e-9));
      expect(s.latency.inputMs, closeTo(100, 1e-9), reason: 'was 40 + 90 = 130');
      expect(s.latency.roundTripMs, closeTo(300, 1e-9), reason: 'was 200 + 199.7 + 30: 430');
      expect(s.latency.inputOffset.source, OffsetSource.loopback);
    });
  });

  group('typing a total', () {
    test('a typed output and input total stand once the system\'s figures get better', () async {
      dev = _dev(40);
      final l = comp();
      await l.refresh();
      l.setOutputTotalMs(150);
      l.setInputTotalMs(35);
      dev = _dev(120, inMs: 30, inSource: 'timestamp');
      await reads(l, LatencyComp.settleRuns);
      expect(l.outputMs, closeTo(150, 1e-9), reason: 'was 120 + 110 = 230');
      expect(l.inputMs, closeTo(35, 1e-9), reason: 'was 30 + 25 = 55');
      expect(l.store.inputs[mic.key]!.platformSource, 'buffers', reason: 'the input records its source too');
    });

    testWidgets('the Latency page: a typed input total is the one shown after the input\'s timestamps come',
        (tester) async {
      dev = _dev(121, inMs: 10);
      final s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: buds, input: mic)));
      s.latency.readDevice = () => dev;
      await tester.runAsync(() => s.latency.refresh());
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: LatencyPage(state: s))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('setting-audio.latencyInputOffset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setting-audio.latencyInputOffset')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '45');
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();
      expect(s.latency.inputMs, closeTo(45, 1e-9));
      dev = _dev(121, inMs: 30, inSource: 'timestamp');
      await tester.runAsync(() => s.latency.refresh());
      await tester.pump();
      expect(s.latency.inputMs, closeTo(45, 1e-9), reason: 'was 30 + 35 = 65');
      s.dispose();
    });
  });
}
