// Latency compensation (owner, 2026-11-11): presets by device kind and per-device offsets that persist, the
// tap-along median, a route change moving the offset, the audible playhead and meters (a reading appears exactly one
// output latency later), recordings placed by output + input latency, the Android route pick, and the Latency page.
import 'dart:async';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/latency_comp.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/audio_route.dart';
import 'package:caw/ui/settings/latency_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

class FakeRoute implements AudioRoute {
  FakeRoute(this.info);
  AudioRouteInfo info;
  final _changes = StreamController<void>.broadcast();
  int asked = 0;

  void move(AudioRouteInfo to) {
    info = to;
    _changes.add(null);
  }

  @override
  Future<AudioRouteInfo> current(AudioRouteHint hint) async {
    asked++;
    return info;
  }

  @override
  Stream<void> get changes => _changes.stream;
}

const speaker = AudioEndpoint(id: 2, name: 'Phone', kind: AudioDeviceKind.builtIn);
const buds = AudioEndpoint(id: 41, name: 'Buds', kind: AudioDeviceKind.bluetooth);
const mic = AudioEndpoint(id: 3, name: 'Phone', kind: AudioDeviceKind.builtIn);

DeviceLatency device({double outMs = 20, double inMs = 10, bool input = true}) => DeviceLatency(
    running: true, sampleRate: 48000,
    output: SideLatency(running: true, frames: (outMs * 48).round(), ms: outMs, source: 'timestamp'),
    input: SideLatency(running: input, frames: (inMs * 48).round(), ms: inMs, source: 'buffers'));

void main() {
  group('offsets', () {
    test('a Bluetooth output starts at its preset; a built-in one at what the system reports', () async {
      final route = FakeRoute(const AudioRouteInfo(output: buds, input: mic));
      final l = LatencyComp(route: route)..readDevice = () => device();
      await l.refresh();
      expect(l.outputOffset.source, OffsetSource.preset);
      expect(l.outputMs, closeTo(presetOutputMs(AudioDeviceKind.bluetooth), 1e-9));
      expect(l.outputIsLate, isTrue);
      expect(l.inputMs, 10);
      route.info = const AudioRouteInfo(output: speaker, input: mic);
      await l.refresh();
      expect(l.outputMs, 20);
      expect(l.outputIsLate, isFalse);
      l.enabled = false;
      expect(l.outputMs, 0);
      expect(l.roundTripMs, 0);
      l.dispose();
    });

    test('a system figure larger than the preset is kept (the platform already counts the link)', () async {
      final l = LatencyComp(route: FakeRoute(const AudioRouteInfo(output: buds)))..readDevice = () => device(outMs: 260);
      await l.refresh();
      expect(l.outputOffset.extraMs, 0);
      expect(l.outputMs, 260);
      l.dispose();
    });

    test('saves started together land in order: the file always holds the newest offsets', () async {
      final dir = await Directory.systemTemp.createTemp('lat');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/latency.json');
      final store = LatencyStore(file);
      for (var round = 0; round < 20; ++round) {
        final saves = <Future<void>>[];
        for (var i = 0; i < 8; ++i) {
          store.enabled = i.isEven;
          // Files of different lengths, so overlapping writes would leave a broken file.
          store.outputs.clear();
          for (var k = 0; k < (i * 37 + round) % 50; ++k) {
            store.outputs['device $k'] = DeviceOffset(k.toDouble(), OffsetSource.typed);
          }
          saves.add(store.save());
        }
        await Future.wait(saves);
        final back = LatencyStore(file);
        await back.load();
        expect(back.enabled, false, reason: 'round $round: the last save (disabled) must win and the file must parse');
        store.enabled = true;
        await store.save();
      }
    });

    test('offsets are saved per device and read back', () async {
      final dir = await Directory.systemTemp.createTemp('lat');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/latency.json');
      final route = FakeRoute(const AudioRouteInfo(output: buds, input: mic));
      final a = LatencyComp(store: LatencyStore(file), route: route)..readDevice = () => device();
      await a.refresh();
      a.setOutputTotalMs(240, source: OffsetSource.tapped);
      a.setInputTotalMs(35);
      await a.store.save();
      a.dispose();

      final b = LatencyComp(store: LatencyStore(file), route: route)..readDevice = () => device();
      await b.load();
      await b.refresh();
      expect(b.outputMs, closeTo(240, 1e-9));
      expect(b.outputOffset.source, OffsetSource.tapped);
      expect(b.inputMs, closeTo(35, 1e-9));
      // Another device keeps its own (here its preset).
      route.info = const AudioRouteInfo(output: AudioEndpoint(name: 'Other buds', kind: AudioDeviceKind.bluetooth));
      await b.refresh();
      expect(b.outputOffset.source, OffsetSource.preset);
      b.resetInput();
      b.dispose();
    });

    test('a route change reads the route again and moves the offset', () async {
      final route = FakeRoute(const AudioRouteInfo(output: speaker, input: mic));
      final l = LatencyComp(route: route)..readDevice = () => device();
      await l.refresh();
      var notified = 0;
      l.addListener(() => notified++);
      expect(l.outputMs, 20);
      route.move(const AudioRouteInfo(output: buds, input: mic));
      await pumpEventQueue();
      expect(l.routeInfo.output.key, buds.key);
      expect(l.outputMs, 200);
      expect(notified, greaterThan(0));
      l.dispose();
    });

    test('a loopback ping gives the input what the output does not explain', () async {
      final l = LatencyComp(route: FakeRoute(const AudioRouteInfo(output: buds, input: mic)))..readDevice = () => device();
      await l.refresh();
      l.splitPing(260);
      expect(l.inputOffset.source, OffsetSource.loopback);
      expect(l.inputMs, closeTo(60, 1e-9));
      expect(l.roundTripMs, closeTo(260, 1e-9));
      expect(l.pingOutputKey, buds.key);
      l.dispose();
    });
  });

  group('calibration', () {
    test('median of an odd and an even count', () {
      expect(median([]), isNull);
      expect(median([5, 1, 3]), 3);
      expect(median([4, 1, 3, 2]), 2.5);
    });

    test('tap-along: the lead past each beat, early taps counted for the next beat, one wild tap ignored', () {
      // 120 bpm: a step is 125 ms; beats every 4 steps. Taps 200 ms (1.6 steps) late, one 3.9 (early for the next).
      final taps = [1.6, 5.6, 9.62, 13.58, 17.6, 21.6, 25.6, 3.9];
      final ms = tapAlongMs(taps, bpm: 120)!;
      expect(ms, closeTo(200, 2));
      expect(tapAlongMs([1.6, 5.6], bpm: 120), isNull, reason: 'too few taps');
    });
  });

  group('audible time', () {
    late AppState s;
    late int clock;
    setUp(() async {
      clock = 1000000;
      s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: buds)), clockUs: () => clock);
      s.project = ProjectDoc(id: 'p', name: 'P', bpm: 120, loopBars: 4);
      s.latency.readDevice = () => device(outMs: 0);
      await s.latency.refresh();
      s.latency.setOutputTotalMs(250); // 2 steps at 120 bpm
    });
    tearDown(() => s.dispose());

    test('the playhead is the render position less the output latency, wrapped over the loop', () {
      final loopSteps = s.project.engineLoopSteps;
      s.meters = EngineMeters(playing: true, position: 10 * 1000, loopLength: loopSteps * 1000);
      expect(s.renderStep, 10);
      expect(s.outputLatencySteps, closeTo(2, 1e-9));
      expect(s.playheadStep, closeTo(8, 1e-9));
      // Just past the wrap the ear is still at the end of the song.
      s.meters = EngineMeters(playing: true, position: 500, loopLength: loopSteps * 1000);
      expect(s.playheadStep, closeTo(loopSteps - 1.5, 1e-9));
      s.latency.enabled = false;
      expect(s.playheadStep, closeTo(0.5, 1e-9));
    });

    test('a meter reading appears exactly one output latency later', () {
      final rendered = MeterReading(clock, const EngineMeters(peakL: 0.8, peakR: 0.6, playing: true), const [
        LayerMeterValue(peak: 0.7),
      ]);
      s.meterTimeline.push(MeterReading(clock - 1000, const EngineMeters(playing: true), const [LayerMeterValue()]));
      s.meterTimeline.push(rendered);
      s.layerMeters = const [LayerMeterValue(peak: 0.7)];
      expect(s.outputLatencyUs, 250000);
      clock += 249999;
      expect(s.audibleMeters.peakL, 0, reason: 'not heard yet');
      expect(s.audibleLayerMeters.single.peak, 0);
      clock += 1;
      expect(s.audibleMeters.peakL, 0.8);
      expect(s.audibleMeters.peakR, 0.6);
      expect(s.audibleLayerMeters.single.peak, 0.7);
      expect(s.meterAt(clock - 250000), same(rendered));
    });

    test('the badge tip shows while the output adds more than 50 ms', () {
      expect(s.latencyTip, contains('feel late'));
      s.latency.setOutputTotalMs(40);
      expect(s.latencyTip, isNull);
    });
  });

  group('recording placement', () {
    late AppState s;
    late FakeAudioIo io;
    late AudioRecorder rec;
    late FakeRoute route;
    setUp(() async {
      route = FakeRoute(const AudioRouteInfo(output: speaker, input: mic));
      s = AppState(settings: Settings(), audioRoute: route);
      io = FakeAudioIo();
      s.audioIo = io;
      s.latency.readDevice = () => device(outMs: 10, inMs: 10);
      rec = AudioRecorder(s, prefs: AudioInputPrefs());
      await s.latency.refresh();
    });
    tearDown(() {
      rec.dispose();
      s.dispose();
    });

    test('takes are placed by output + input latency: Bluetooth output adds its delay to the round trip', () async {
      expect(io.latencyOverride, -1, reason: 'the engine\'s own 20 ms estimate covers the built-in route');
      route.move(const AudioRouteInfo(output: buds, input: mic));
      await pumpEventQueue();
      expect(s.latency.roundTripMs, closeTo(210, 1e-9));
      expect(io.latencyOverride, 210 * 48);
      expect(rec.latency.source, 'compensated');
      // A typed offset stands over it.
      rec.setLatencyMs(12.5);
      expect(io.latencyOverride, 600);
      rec.setLatencyMs(null);
      expect(io.latencyOverride, 210 * 48);
      // A ping through this output heard the whole trip: the engine uses it, and the input gets the rest.
      final r = await rec.ping(poll: Duration.zero);
      expect(r!.ok, isTrue);
      expect(io.latencyOverride, -1);
      expect(rec.latency.source, 'measured');
      // Back on the speaker the ping (made through the buds) no longer holds.
      route.move(const AudioRouteInfo(output: speaker, input: mic));
      await pumpEventQueue();
      expect(io.latencyOverride, greaterThan(0));
    });
  });

  group('Android route', () {
    test('device types map to kinds', () {
      expect(androidDeviceKind(8), AudioDeviceKind.bluetooth);
      expect(androidDeviceKind(26), AudioDeviceKind.bluetoothLe);
      expect(androidDeviceKind(22), AudioDeviceKind.usb);
      expect(androidDeviceKind(9), AudioDeviceKind.hdmi);
      expect(androidDeviceKind(2), AudioDeviceKind.builtIn);
      expect(androidDeviceKind(99), AudioDeviceKind.unknown);
    });

    test('the engine\'s device id wins, then Android 13\'s routed device, then the usual priority', () {
      final snap = <Object?, Object?>{
        'outputs': [
          {'id': 2, 'type': 2, 'name': 'Phone'},
          {'id': 41, 'type': 8, 'name': 'Buds'},
          {'id': 50, 'type': 7, 'name': 'Buds'},
        ],
        'inputs': [
          {'id': 3, 'type': 15, 'name': 'Phone'},
          {'id': 51, 'type': 7, 'name': 'Buds'},
        ],
        'routed': <Object?>[],
      };
      var r = pickAndroidRoute(snap, const AudioRouteHint());
      expect(r.output.kind, AudioDeviceKind.bluetooth);
      expect(r.output.id, 41, reason: 'A2DP, not the call (SCO) device');
      expect(r.input.kind, AudioDeviceKind.builtIn, reason: 'media capture stays on the phone\'s microphone');
      r = pickAndroidRoute(snap, const AudioRouteHint(outputId: 2, inputId: 51));
      expect(r.output.kind, AudioDeviceKind.builtIn);
      expect(r.input.kind, AudioDeviceKind.bluetooth);
      r = pickAndroidRoute({...snap, 'routed': [{'id': 2, 'type': 2, 'name': 'Phone'}]}, const AudioRouteHint());
      expect(r.output.kind, AudioDeviceKind.builtIn);
      expect(kindFromName('Headphones (WH-1000XM4 Stereo) Bluetooth'), AudioDeviceKind.bluetooth);
      expect(kindFromName('Speakers (USB Audio Device)'), AudioDeviceKind.usb);
      expect(kindFromName('LG TV (NVIDIA High Definition Audio)'), AudioDeviceKind.hdmi);
    });

    test('Windows: the kind WASAPI reported wins over the name; unknown falls back to the name', () async {
      const route = NamedAudioRoute();
      var r = await route.current(const AudioRouteHint(outputName: 'Headphones (Jabra Elite)', outputKind: 'bluetooth',
          inputName: 'Microphone (USB Audio Device)'));
      expect(r.output.kind, AudioDeviceKind.bluetooth, reason: 'the name says nothing; the bus does');
      expect(r.input.kind, AudioDeviceKind.usb, reason: 'no kind from the engine: the name');
      r = await route.current(const AudioRouteHint(outputName: 'Speakers (Realtek(R) Audio)', outputKind: 'hdmi'));
      expect(r.output.kind, AudioDeviceKind.hdmi);
      expect(hintedKind('nonsense', 'Bluetooth speaker'), AudioDeviceKind.bluetooth);
      expect(androidDeviceKind(33), AudioDeviceKind.bluetoothLe);
    });
  });

  testWidgets('the Latency page shows both sides and types an output offset; the badge appears', (tester) async {
    final s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: buds, input: mic)));
    s.latency.readDevice = () => device();
    await tester.runAsync(() => s.latency.refresh());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      LatencyBadge(state: s),
      Expanded(child: LatencyPage(state: s)),
    ]))));
    await tester.pumpAndSettle();
    expect(find.text('OUTPUT'), findsOneWidget);
    expect(find.text('INPUT'), findsOneWidget);
    expect(find.byKey(const ValueKey('latency-badge')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('setting-audio.latencyOutputOffset')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '30');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(s.latency.outputMs, closeTo(30, 1e-9));
    expect(find.byKey(const ValueKey('latency-badge')), findsNothing);
    s.dispose();
  });
}
