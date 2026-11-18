// #236: the lean-early alignment maths, the ping series, learning from takes (suggested, never applied by itself),
// per-device offsets with a re-check, the slider sheet (while listening, ±1 ms, Bluetooth's card), Record's menu
// entry and on-screen keys reaching the engine on the finger's down.
import 'dart:io';

import 'package:caw/engine/audio_engine.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/av_sync.dart';
import 'package:caw/model/latency_comp.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/audio_route.dart';
import 'package:caw/ui/frame/live_keys.dart';
import 'package:caw/ui/frame/record_tools.dart';
import 'package:caw/ui/settings/latency_settings.dart';
import 'package:caw/ui/settings/latency_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'latency_comp_test.dart' show FakeRoute, buds, device, mic, speaker;

/// Pings that answer from a script, one result per run.
class ScriptedPings extends FakeAudioIo {
  ScriptedPings(this.script);
  final List<double?> script;
  int run = 0;

  @override
  PingResult pingResult() {
    final ms = script[run++ % script.length];
    final r = ms == null
        ? const PingResult(state: 'done', ok: false)
        : PingResult(state: 'done', ok: true, frames: (ms * 48).round(), ms: ms, confidence: 20);
    if (r.ok) measured = r.frames;
    return r;
  }
}

class FakeBluetoothSettings implements BluetoothSettings {
  int opened = 0, developer = 0;
  DeveloperOptions answer = DeveloperOptions.opened;
  @override
  bool get canOpen => true;
  @override
  Future<bool> open() async {
    opened++;
    return true;
  }

  @override
  Future<DeveloperOptions> openDeveloperOptions() async {
    developer++;
    return answer;
  }
}

/// Keys go to the engine through previewOn; here they are counted.
class KeysState extends AppState {
  KeysState() : super(settings: Settings());
  final on = <double>[];
  @override
  void previewOn(String layerId, int id, double pitch, double velocity) => on.add(pitch);
  @override
  void previewOff(int id) {}
}

void main() {
  group('lean early', () {
    test('the lead is two refreshes plus the 5 ms early bias, 60 Hz when the rate is unknown', () {
      expect(earlyBiasUs, inInclusiveRange(0, 10000));
      expect(displayLatencyUs(120), 16667);
      expect(displayLatencyUs(60), 33333);
      expect(displayLatencyUs(0), 33333);
      expect(displayLatencyUs(double.nan), 33333);
      expect(visualLeadUs(120), 21667);
      expect(AvSync(refreshHz: () => 90).leadUs, 22222 + 5000);
    });

    test('a meter shows the read whose span holds the heard moment; held drawing is half a read on', () {
      expect(meterRenderUs(nowUs: 1000000, leadUs: 20000, outputLatencyUs: 200000), 820000);
      expect(heldDrawUs(nowUs: 1000000, leadUs: 20000, readIntervalUs: 33000), 1036500);
      final t = MeterTimeline();
      MeterReading r(int us) => MeterReading(us, const EngineMeters(), const []);
      expect(t.covering(5), isNull);
      final a = r(100000), b = r(133000), c = r(166000);
      t
        ..push(a)
        ..push(b)
        ..push(c);
      expect(t.covering(100001), same(b), reason: 'rendered after a: b stands for it');
      expect(t.covering(133000), same(b));
      expect(t.covering(140000), same(c));
      expect(t.covering(999999), same(c));
      expect(t.covering(90000), same(a), reason: 'inside the first read\'s span');
      expect(t.covering(60000), isNull, reason: 'before anything kept was rendered');
    });
  });

  group('the ping series', () {
    test('agreeing runs give their median; one far off, or too few heard, is unreliable', () {
      var p = judgePings([20.1, 20.0, 19.9, 20.3, 20.0]);
      expect(p.reliable, isTrue);
      expect(p.ms, 20.0);
      expect(p.heard, 5);
      p = judgePings([20.0, 20.0, 31.0, 20.0, 20.0]);
      expect(p.reliable, isFalse);
      expect(p.spreadMs, 11);
      expect(pingSeriesProblem(p), contains('disagreed'));
      p = judgePings([20.0, null, null, 20.0, 20.0]);
      expect(p.reliable, isFalse, reason: '3 of 5 heard');
      expect(pingSeriesProblem(p), contains('3 of 5'));
      // Bluetooth: 3 % of 300 ms allows 9 ms.
      expect(judgePings([300, 306, 296, 301, 304]).reliable, isTrue);
      expect(judgePings([]).ms, isNull);
    });

    Future<(AppState, AudioRecorder, ScriptedPings)> recorder(List<double?> script) async {
      final s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: speaker, input: mic)));
      final io = ScriptedPings(script);
      s.audioIo = io;
      s.latency.readDevice = () => device(outMs: 10, inMs: 10);
      final rec = AudioRecorder(s, prefs: AudioInputPrefs());
      await s.latency.refresh();
      addTearDown(() {
        rec.dispose();
        s.dispose();
      });
      return (s, rec, io);
    }

    test('a reliable series is split from its median and places takes', () async {
      final (s, rec, io) = await recorder([30.2, 29.8, 30.0, 30.1, 29.9]);
      final done = <int>[];
      final p = await rec.ping(poll: Duration.zero, progress: (d, _) => done.add(d));
      expect(done, [1, 2, 3, 4, 5]);
      expect(p!.reliable, isTrue);
      expect(io.run, pingRuns);
      expect(s.latency.inputOffset.source, OffsetSource.loopback);
      expect(s.latency.roundTripMs, closeTo(30, 1e-9));
      expect(io.latencyOverride, 30 * 48, reason: 'the median, not the last run');
    });

    test('an unreliable series is reported and not saved', () async {
      final (s, rec, _) = await recorder([30, 30, 52, 30, 30]);
      final before = s.latency.inputOffset;
      final p = await rec.ping(poll: Duration.zero);
      expect(p!.reliable, isFalse);
      expect(s.latency.inputOffset.source, before.source);
      expect(s.latency.store.inputs, isEmpty);
      expect(s.latency.pingOutputKey, isNull, reason: 'no ping stands for this output');
    });
  });

  group('learning from takes', () {
    test('beat deviations: within the window of a beat, in ms at the tempo', () {
      // 120 BPM: a step is 125 ms. 4.16 is 20 ms late on beat 2; 7.9 is 12.5 ms early on beat 3; 2 is off-beat.
      final d = beatDeviationsMs([4.16, 7.9, 2.0, 0.0], bpmAt: (_) => 120);
      expect(d.length, 3);
      expect(d[0], closeTo(20, 1e-9));
      expect(d[1], closeTo(-12.5, 1e-9));
      expect(d[2], 0);
    });

    test('a suggestion needs enough takes, notes, shift and agreement', () {
      TimingEvidence ev(int takes, List<double> ms) {
        final e = TimingEvidence();
        for (var i = 0; i < takes; i++) {
          e.add(ms);
        }
        return e;
      }

      final late20 = List.filled(10, 20.0);
      expect(suggestFrom(ev(2, late20), 200), isNull, reason: 'two takes');
      expect(suggestFrom(ev(3, List.filled(5, 20.0)), 200), isNull, reason: '15 notes');
      expect(suggestFrom(ev(3, List.filled(10, 4.0)), 200), isNull, reason: 'a 4 ms shift is playing style');
      expect(suggestFrom(ev(3, [for (var i = 0; i < 10; i++) i.isEven ? 30.0 : -25.0]), 200), isNull,
          reason: 'no agreement');
      final s = suggestFrom(ev(3, late20), 200)!;
      expect(s.shiftMs, 20);
      expect(s.totalMs, 220);
      expect(s.onsets, 30);
    });

    test('takes played late suggest more output latency; nothing changes until it is applied', () async {
      final s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: buds, input: mic)));
      addTearDown(s.dispose);
      s.project = ProjectDoc(id: 'p', name: 'P', bpm: 120, loopBars: 4)
        ..layers.add(LayerDoc(id: 'L1', name: 'Keys', color: 0));
      s.latency.readDevice = () => device(outMs: 0);
      await s.latency.refresh();
      final live = LiveMidi(s, null);
      addTearDown(live.dispose);
      final before = s.latency.outputMs;
      for (var take = 0; take < 3; take++) {
        s.pausedStep = 0;
        live.toggleRecord('L1');
        for (var beat = 0; beat < 8; beat++) {
          s.pausedStep = beat * 4 + 0.16; // 20 ms late at 120 BPM
          live.keyDown(60, 0.8);
          s.pausedStep = beat * 4 + 1.0;
          live.keyUp(60);
        }
        live.toggleRecord();
      }
      expect(s.latency.outputMs, before, reason: 'never applied by itself');
      final sug = s.latency.outputSuggestion!;
      expect(sug.shiftMs, 20);
      expect(sug.takes, 3);
      s.latency.acceptSuggestion();
      expect(s.latency.outputMs, closeTo(before + 20, 1e-9));
      expect(s.latency.outputOffset.source, OffsetSource.learned);
      expect(s.latency.outputSuggestion, isNull, reason: 'the evidence starts again');
    });
  });

  group('per device', () {
    test('offsets, negative ones, the platform figure and the evidence round trip through the file', () async {
      final dir = await Directory.systemTemp.createTemp('lat');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/latency.json');
      final route = FakeRoute(const AudioRouteInfo(output: speaker, input: mic));
      final a = LatencyComp(store: LatencyStore(file), route: route)..readDevice = () => device(outMs: 30);
      await a.refresh();
      a.setOutputTotalMs(20, source: OffsetSource.slider); // the platform reports too much
      expect(a.outputOffset.extraMs, -10);
      expect(a.outputMs, 20);
      a.learnFromTake([12, 14]);
      await a.saveNow();
      a.dispose();
      final b = LatencyComp(store: LatencyStore(file), route: route)..readDevice = () => device(outMs: 30);
      await b.load();
      await b.refresh();
      expect(b.outputMs, 20);
      expect(b.outputOffset.source, OffsetSource.slider);
      expect(b.outputOffset.platformMs, 30);
      expect(b.store.evidence[speaker.key]!.ms, [12, 14]);
      b.dispose();
    });

    test('a slider drag saves when it ends; a nudge is one ms and saves', () async {
      final dir = await Directory.systemTemp.createTemp('lat');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/latency.json');
      final l = LatencyComp(store: LatencyStore(file), route: FakeRoute(const AudioRouteInfo(output: buds)))
        ..readDevice = () => device(outMs: 40);
      addTearDown(l.dispose);
      await l.refresh();
      l.setOutputTotalMs(180, source: OffsetSource.slider, save: false);
      await pumpEventQueue();
      expect(file.existsSync(), isFalse);
      l.nudgeOutput(1);
      l.nudgeOutput(1);
      l.nudgeOutput(-1);
      expect(l.outputMs, 181);
      await l.saveNow();
      expect(file.readAsStringSync(), contains('"source":"slider"'));
    });

    test('a device change is read again after it settles; a moved platform figure asks for a check', () async {
      var outMs = 40.0;
      final route = FakeRoute(const AudioRouteInfo(output: speaker, input: mic));
      final l = LatencyComp(route: route, recheckDelay: const Duration(milliseconds: 1))
        ..readDevice = () => device(outMs: outMs);
      addTearDown(l.dispose);
      await l.refresh();
      final asked = route.asked;
      route.move(const AudioRouteInfo(output: buds, input: mic));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(route.asked, asked + 2, reason: 'read on the change, and again after the link settles');
      expect(l.previousOutput?.key, speaker.key);
      l.setOutputTotalMs(220);
      expect(l.outputNeedsCheck, isFalse);
      outMs = 90; // a new codec, say
      await l.refresh();
      expect(l.outputNeedsCheck, isTrue);
      expect(l.outputMs, 270, reason: 'the offset rides on the new figure until checked');
    });
  });

  group('the sheet', () {
    late AppState s;
    late FakeBluetoothSettings bt;
    setUp(() {
      bt = FakeBluetoothSettings();
      BluetoothSettings.current = bt;
    });
    tearDown(() => BluetoothSettings.current = const NoBluetoothSettings());

    Future<void> pump(WidgetTester tester, {AudioEndpoint output = buds}) async {
      s = AppState(settings: Settings(), audioRoute: FakeRoute(AudioRouteInfo(output: output, input: mic)));
      s.latency.readDevice = () => device(outMs: 20);
      await tester.runAsync(() => s.latency.refresh());
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Center(
        child: TextButton(onPressed: () => openLatencySheet(context, s), child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the slider and the nudges set this output\'s total at once; Bluetooth says what it adds',
        (tester) async {
      await pump(tester);
      expect(s.latency.outputMs, 200);
      expect(find.text('200 ms'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('latency-nudge-up')));
      await tester.pump();
      expect(s.latency.outputMs, 201);
      await tester.tap(find.byKey(const ValueKey('latency-nudge-down')));
      await tester.tap(find.byKey(const ValueKey('latency-nudge-down')));
      await tester.pump();
      expect(s.latency.outputMs, 199);
      expect(s.latency.outputOffset.source, OffsetSource.slider);
      // A drag along the slider: the value follows the finger.
      final slider = find.byKey(const ValueKey('latency-slider'));
      final before = s.latency.outputMs;
      await tester.drag(slider, const Offset(-60, 0));
      await tester.pump();
      expect(s.latency.outputMs, lessThan(before));
      expect(s.latency.outputMs, s.latency.outputMs.roundToDouble(), reason: 'whole ms');
      // Bluetooth: said plainly, with the way to the system's settings.
      expect(find.byKey(const ValueKey('latency-bluetooth')), findsOneWidget);
      expect(find.textContaining('no app can remove'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('latency-bluetooth-settings')));
      await tester.tap(find.byKey(const ValueKey('latency-bluetooth-settings')));
      await tester.pump();
      expect(bt.opened, 1);
      s.dispose();
    });

    testWidgets('Bluetooth\'s best quality: the user\'s own switches, Developer options or how to turn them on',
        (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('latency-beat')), findsOneWidget, reason: 'the visual beat (#241)');
      expect(find.byKey(const ValueKey('latency-breakdown')), findsOneWidget);
      expect(find.textContaining('system 20 ms (timestamps, buffer included)'), findsOneWidget);
      expect(find.textContaining('offset +180 ms (preset)'), findsOneWidget);
      expect(find.byKey(const ValueKey('latency-bluetooth-quality')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('latency-bluetooth-quality-toggle')));
      await tester.tap(find.byKey(const ValueKey('latency-bluetooth-quality-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Get the best Bluetooth quality'), findsOneWidget);
      expect(find.textContaining('No app can change it'), findsOneWidget, reason: 'never claims to change the codec');
      await tester.ensureVisible(find.byKey(const ValueKey('latency-bluetooth-developer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('latency-bluetooth-developer')));
      await tester.pump();
      expect((bt.developer, bt.opened), (1, 0), reason: 'opened: nothing else');
      bt.answer = DeveloperOptions.off;
      await tester.tap(find.byKey(const ValueKey('latency-bluetooth-developer')));
      await tester.pump();
      expect((bt.developer, bt.opened), (2, 1), reason: 'off: the Bluetooth settings instead');
      expect(find.textContaining('tap Build number seven times'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      s.dispose();
    });

    testWidgets('no Bluetooth card on the speaker; a learned suggestion is offered and applied', (tester) async {
      await pump(tester, output: speaker);
      expect(find.byKey(const ValueKey('latency-bluetooth')), findsNothing);
      for (var i = 0; i < 3; i++) {
        s.latency.learnFromTake(List.filled(10, -12.0));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('latency-suggestion')), findsOneWidget);
      expect(find.textContaining('12 ms early'), findsOneWidget);
      final from = s.latency.outputMs;
      await tester.ensureVisible(find.byKey(const ValueKey('latency-suggestion-apply')));
      await tester.tap(find.byKey(const ValueKey('latency-suggestion-apply')));
      await tester.pumpAndSettle();
      expect(s.latency.outputMs, closeTo(from - 12, 1e-9));
      expect(find.byKey(const ValueKey('latency-suggestion')), findsNothing);
      s.dispose();
    });

    testWidgets('the Latency page has the same cards and opens the sheet', (tester) async {
      final st = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: buds, input: mic)));
      st.latency.readDevice = () => device();
      await tester.runAsync(() => st.latency.refresh());
      await tester.pumpWidget(MaterialApp(home: LatencyPage(state: st)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('latency-bluetooth')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('setting-audio.latencyListen')));
      await tester.pumpAndSettle();
      expect(find.byType(LatencySheet), findsOneWidget);
      st.dispose();
    });
  });

  testWidgets('Record\'s long-press opens the latency sheet', (tester) async {
    final s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: buds, input: mic)));
    s.latency.readDevice = () => device();
    await tester.runAsync(() => s.latency.refresh());
    final live = LiveMidi(s, null);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Center(
      child: TextButton(onPressed: () => showRecordOptions(context, s, live, const Offset(200, 300)),
          child: const Text('hold')))))));
    await tester.tap(find.text('hold'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Latency:'));
    await tester.pumpAndSettle();
    expect(find.byType(LatencySheet), findsOneWidget);
    live.dispose();
    s.dispose();
  });

  testWidgets('a key and a pad reach the engine as the finger lands, before it lifts', (tester) async {
    tester.view.physicalSize = const Size(412, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = KeysState()
      ..project = (ProjectDoc(id: 'p', name: 'P')..layers.add(LayerDoc(id: 'L1', name: 'Keys', color: 0)))
      ..selectedLayerId = 'L1';
    final live = LiveMidi(s, null)..keysOpen = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter,
        child: LiveKeysPanel(midi: live, state: s)))));
    await tester.pumpAndSettle();
    final r = tester.getRect(find.byKey(const ValueKey('live-piano')));
    final g = await tester.startGesture(Offset(r.left + 15, r.bottom - 6));
    expect(s.on, [48.0], reason: 'on the down, not after a tap is recognised');
    await g.up();
    await tester.tap(find.byKey(const ValueKey('live-keys-pads')));
    await tester.pumpAndSettle();
    final pads = tester.getRect(find.byKey(const ValueKey('live-pads')));
    final p = await tester.startGesture(Offset(pads.left + 10, pads.bottom - 10));
    expect(s.on.length, 2);
    await p.up();
    live.dispose();
    s.dispose();
  });
}
