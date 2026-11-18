// The Benchmark: its plans, safety stops, memory skips, the app set aside, telemetry, H2 `stress`, the screen at 360 dp.
import 'dart:async';
import 'dart:io';

import 'package:caw/engine/execution.dart';
import 'package:caw/engine/stress.dart';
import 'package:caw/model/stress_result.dart';
import 'package:caw/model/stress_runner.dart';
import 'package:caw_services/telemetry/report_schema.dart';
import 'package:caw/ui/benchmark/benchmark_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _scenarios = [
  StressScenarioInfo(id: 'first_loop', name: 'First loop (6 tracks)', tier: 'normal', memoryMiB: 32),
  StressScenarioInfo(id: 'song8', name: 'Typical song (8 tracks)', tier: 'normal', memoryMiB: 64),
  StressScenarioInfo(id: 'song16', name: 'Song, 16 tracks', tier: 'heavy', memoryMiB: 128),
  StressScenarioInfo(id: 'song32_heavy', name: 'Song, 32 tracks + heavy FX', tier: 'extreme', memoryMiB: 256),
  StressScenarioInfo(id: 'tail_floor', name: 'Tail project, no notes', tier: 'idle', memoryMiB: 64),
];

/// A fake engine: each plain scenario takes [pct] of the budget; ramps hold up to [limits].
class FakeStress implements StressBackend {
  FakeStress({this.onStart, this.extra = const {}});
  final void Function(StressRequest r)? onStart;
  final Map<String, Object?> extra;
  final List<StressRequest> started = [];
  final pct = {'first_loop': 20.0, 'song8': 40.0, 'song16': 85.0, 'song32_heavy': 160.0, 'tail_floor': 2.0};
  final limits = {StressKind.rampTracks: 23, StressKind.rampVoices: 41, StressKind.rampEffects: 64};

  @override
  List<StressScenarioInfo> scenarios() => _scenarios;

  @override
  StressJob start(StressRequest r) {
    started.add(r);
    onStart?.call(r);
    return _FakeJob(_json(r));
  }

  Map<String, dynamic> _json(StressRequest r) {
    final p = pct[r.scenario] ?? 0;
    final base = {
      'ok': true, 'stop_reason': 'done', 'error': '', 'scenario': r.scenario,
      'mode': r.mode == StressMode.live ? 'live' : 'dsp', 'budget_us': 5333.3, 'frames': 256,
      'mean_us': 53.33 * p * 0.8, 'p99_us': 53.33 * p, 'worst_us': 53.33 * p * 1.3,
      'mean_pct': p * 0.8, 'p99_pct': p, 'worst_pct': p * 1.3, 'callbacks': 280,
      'over_budget': p > 100 ? 30 : 0, 'dropouts': p > 100 ? 30 : 0, 'xruns': r.mode == StressMode.live ? 0 : -1,
      'limit': -1, 'first_failed': -1, 'costs': <Object>[], 'mean_first_us': 2000.0, 'mean_last_us': 2300.0, 'seconds': r.seconds,
      ...extra,
    };
    if (limits.containsKey(r.kind)) {
      final l = limits[r.kind]!;
      return {...base, 'scenario': '', 'limit': l, 'first_failed': l == 64 ? -1 : l + 1, 'stop_reason': l == 64 ? 'done' : 'over_budget'};
    }
    if (r.kind == StressKind.profile) {
      return {
        ...base,
        'costs': [
          {'id': 'org.caw.synth.flagship', 'pct': 41.4, 'ran_pct': 90.0, 'instances': 6},
          {'id': 'host', 'pct': 12.2, 'ran_pct': 100.0, 'instances': 1},
          {'id': 'org.caw.reverb.pro', 'pct': 18.6, 'ran_pct': 100.0, 'instances': 2},
          {'id': 'com.example.mine', 'pct': 3.0, 'ran_pct': 100.0, 'instances': 1},
        ],
        'parts': extra.containsKey('parts') ? extra['parts'] : fakeParts(r.scenario),
      };
    }
    return base;
  }
}

/// A profiled scenario's engine parts (API 30): song8's add up to 100%, others lean on sends or devices.
List<Map<String, Object>> fakeParts(String scenario) {
  final sends = scenario == 'song16' ? 31.0 : 8.0;
  final devices = scenario == 'song16' ? 34.0 : 57.0;
  final rows = {
    'devices': devices, 'mix': 12.0, 'sends': sends, 'routing': 5.0, 'automation': 4.0, 'voices': 3.5, 'samples': 3.0,
    'metering': 2.5, 'mix_pool': 2.0, 'master': 1.5, 'device_io': 0.0, 'other': 1.0,
  };
  return [
    for (final e in rows.entries) {'id': e.key, 'pct': e.value, 'mean_us': 21.3 * e.value, 'p99_us': 30.1 * e.value},
  ];
}

class _FakeJob implements StressJob {
  _FakeJob(Map<String, dynamic> json) : result = Future.value(json);
  @override
  final Future<Map<String, dynamic>> result;
  @override
  StressProgress progress() => const StressProgress(fraction: 0.5, load: 0.4);
  @override
  List<double> takeHistory() => const [0.3, 0.4];
  @override
  void cancel() {}
}

/// [FakeStress]'s numbers, but each job runs until it ends 10 ms later or is cancelled (then 'cancelled').
class _HidingStress extends FakeStress {
  _HidingStress({this.onJob});
  final void Function(StressRequest r, _SlowJob job)? onJob;
  int cancelled = 0;

  @override
  StressJob start(StressRequest r) {
    started.add(r);
    final job = _SlowJob(_json(r), () => cancelled++);
    onJob?.call(r, job);
    return job;
  }
}

class _SlowJob implements StressJob {
  _SlowJob(Map<String, dynamic> json, this._onCancel) {
    _timer = Timer(const Duration(milliseconds: 10), () {
      if (!_done.isCompleted) _done.complete(json);
    });
  }
  final void Function() _onCancel;
  final _done = Completer<Map<String, dynamic>>();
  late final Timer _timer;
  @override
  Future<Map<String, dynamic>> get result => _done.future;
  @override
  StressProgress progress() => const StressProgress(fraction: 0.5, load: 0.4);
  @override
  List<double> takeHistory() => const [];
  @override
  void cancel() {
    if (_done.isCompleted) return;
    _timer.cancel();
    _onCancel();
    _done.complete({'ok': true, 'stop_reason': 'cancelled', 'error': ''});
  }
}

class FakeHost implements StressHost {
  int suspended = 0, resumed = 0;
  @override
  void suspendForStress() => suspended++;
  @override
  void resumeAfterStress() => resumed++;
}

void main() {
  test('a Quick run plays every scenario, the three ramps, a profile and a live check, then sends H2 stress', () async {
    final fake = FakeStress();
    final host = FakeHost();
    final sent = <Map<String, Object?>>[];
    final runner = StressRunner(backend: fake, host: host, sendTelemetry: (s) async => sent.add(s));
    final res = await runner.run(StressPlanKind.quick);
    expect(host.suspended, 1);
    expect(host.resumed, 1);
    // An untimed second first (its result dropped), then every scenario.
    expect(fake.started.first.seconds, 1);
    expect(fake.started.where((r) => r.kind == StressKind.plain && r.mode == StressMode.dsp).length, _scenarios.length + 1);
    expect(res.scenarios.where((s) => !s.live).length, _scenarios.length);
    // Live: at the playing buffer (Auto while not recording: 1024 frames), then at Low latency (0: the burst).
    final live = fake.started.where((r) => r.mode == StressMode.live).toList();
    expect([for (final r in live) r.frames], [StressBuffer.playingFrames, 0]);
    expect([for (final s in res.scenarios.where((s) => s.live)) s.buffer], [StressBuffer.playing, StressBuffer.lowLatency]);
    expect(res.scenarios.where((s) => s.live).map((s) => s.key).toSet(), hasLength(2));
    expect(fake.started.any((r) => r.kind == StressKind.sustained), isFalse); // Full only
    expect(res.tier('normal'), StressTier.comfortable);
    expect(res.tier('heavy'), StressTier.tight);
    expect(res.tier('extreme'), StressTier.over);
    expect(res.limitsText, 'Holds 23 tracks / 41 voices / all 64 effects');
    expect(res.holdingBack.first.id, 'org.caw.synth.flagship');
    expect(sent, hasLength(1));
    final s = sent.single;
    expect(s['version'], 1);
    expect(s['tiers'], {'normal': 'comfortable', 'heavy': 'tight', 'extreme': 'over'});
    expect(s['limits'], {'tracks': 23, 'voices': 41, 'effects': 64});
    final rows = s['scenarios'] as Map<String, Object?>;
    expect(rows.keys.toSet(), {'first_loop', 'song8', 'song16', 'song32_heavy', 'tail_floor'});
    for (final r in rows.values) {
      for (final v in (r as Map<String, Object?>).values) {
        expect(v, isA<int>()); // whole numbers
      }
    }
    expect((rows['song8'] as Map)['dropouts'], 0); // the live run's
    final costs = s['topCosts'] as List;
    expect(costs.length, lessThanOrEqualTo(10));
    expect([for (final c in costs) (c as Map)['component']], ['org.caw.synth.flagship', 'org.caw.reverb.pro']); // built-ins only
    // It passes the relay contract's allow-list unchanged.
    final allow = TelemetryAllowList(isBuiltin: (id) => id.startsWith('org.caw.'));
    expect(allow.stress(s), s);
  });

  test('a Full run adds the sustained run and more profiles', () async {
    final fake = FakeStress();
    final res = await StressRunner(backend: fake).run(StressPlanKind.full);
    expect(fake.started.where((r) => r.kind == StressKind.profile).length, 3);
    expect(fake.started.where((r) => r.kind == StressKind.sustained).single.seconds, 120);
    expect(res.sustained!.driftPct, closeTo(15, 0.01)); // no trend in the result: the last tenth against the first
    // Costs are each profiled scenario's own, not averaged across them; the headline is the typical song's.
    expect(res.costsByScenario.keys.toSet(), {'song8', 'song16', 'flagship_heavy16'});
    expect(res.costsScenario, 'song8');
    expect(res.costs.firstWhere((c) => c.id == 'org.caw.synth.flagship').instances, 6); // the project's, not profiles
    expect((res.toJson()['costs_by_scenario'] as Map).keys, hasLength(3));
  });

  test('the sustained run is live at the playing buffer: its trend, core clock and thermal state', () async {
    final fake = FakeStress(extra: {'slope_pct_per_min': 3.0, 'core_khz_start': 2995200, 'core_khz_end': 2400000});
    final thermal = [
      {'status': 0, 'headroom': 0.42},
      {'status': 2, 'headroom': 0.91},
    ];
    var reads = 0;
    final res = await StressRunner(backend: fake, readThermal: () async => thermal[reads++]).run(StressPlanKind.full);
    final r = fake.started.singleWhere((r) => r.kind == StressKind.sustained);
    expect(r.mode, StressMode.live);
    expect(r.frames, StressBuffer.playingFrames);
    final s = res.sustained!;
    expect(reads, 2);
    expect(s.thermalStart['headroom'], 0.42);
    expect(s.thermalEnd['status'], 2);
    expect(s.coreKhzEnd, 2400000);
    // 3% of the budget a minute for two minutes, against a start at 37.5%: 16% slower.
    expect(s.driftPct, closeTo(100 * 3.0 * 2 / (100 * 2000 / 5333.3), 0.01));
    final j = s.toJson();
    expect(j['thermal_end'], {'status': 2, 'headroom': 0.91});
    expect(j['slope_pct_per_min'], 3.0);
  });

  test('a playing-buffer run that took the device\'s own sizes says so (Android 11 and older)', () async {
    final res = await StressRunner(backend: FakeStress(extra: {'device_sizes': true})).run(StressPlanKind.quick);
    final live = res.scenarios.firstWhere((s) => s.live && s.buffer == StressBuffer.playing);
    expect(live.deviceSizes, isTrue);
    expect(live.modeLabel, contains('own sizes'));
    expect(live.toJson()['device_sizes'], isTrue);
    expect(res.scenarios.firstWhere((s) => !s.live).deviceSizes, isFalse); // DSP never
    expect(res.summary(), contains('(live, device\'s own sizes)'));
  });

  test('a run keeps its local numbers in the JSON export and out of H2', () async {
    final fake = FakeStress(extra: {
      'first_callback_us': 812.0, 'worst_at_s': 1.93, 'callback_core': 7, 'core_khz_start': 2995200, 'mix_workers': 3,
      'warmup_s': 1.7,
    });
    final sent = <Map<String, Object?>>[];
    final res = await StressRunner(backend: fake, sendTelemetry: (s) async => sent.add(s)).run(StressPlanKind.quick);
    final row = res.scenarios.firstWhere((s) => s.id == 'song8' && !s.live);
    expect(row.firstCallbackUs, 812.0);
    expect(row.worstAtS, 1.93);
    expect(row.mixWorkers, 3);
    final live = res.scenarios.firstWhere((s) => s.live && s.buffer == StressBuffer.playing);
    expect(live.callbackCore, 7);
    final j = live.toJson();
    expect(j['first_callback_us'], 812.0);
    expect(j['worst_at_s'], 1.93);
    expect(j['budget_basis'], 'callback_length');
    expect(j['device_sizes'], isFalse);
    final allow = TelemetryAllowList(isBuiltin: (id) => id.startsWith('org.caw.'));
    expect(allow.stress(sent.single), sent.single); // H2 unchanged: no new field
    expect('${sent.single}', isNot(contains('first_callback')));
  });

  test('unknowns are null: a run stopped before the ramps sends no limits', () async {
    final pressure = StreamController<EnginePressure>();
    late StressRunner runner;
    var song8 = 0;
    final fake = FakeStress(onStart: (r) {
      if (r.scenario == 'song8' && ++song8 == 2) pressure.add(EnginePressure.thermalHot); // after the warm-up
    });
    final sent = <Map<String, Object?>>[];
    runner = StressRunner(backend: fake, pressure: pressure.stream, sendTelemetry: (s) async => sent.add(s));
    final res = await runner.run(StressPlanKind.quick);
    expect(res.stoppedBecause, contains('too hot'));
    expect(fake.started.any((r) => r.kind == StressKind.rampTracks), isFalse);
    expect((sent.single['limits'] as Map).values, everyElement(isNull));
    expect(sent.single['tiers'], containsPair('heavy', null));
    await pressure.close();
  });

  test('closing the screen mid-run cancels it, and the run still ends and is sent', () async {
    final sent = <Map<String, Object?>>[];
    late StressRunner runner;
    var song8 = 0;
    runner = StressRunner(
        backend: FakeStress(onStart: (r) {
          if (r.scenario == 'song8' && ++song8 == 2) runner.dispose(); // after the warm-up
        }),
        sendTelemetry: (s) async => sent.add(s));
    final res = await runner.run(StressPlanKind.quick);
    expect(res.stoppedBecause, 'You stopped it');
    expect(sent, hasLength(1));
  });

  group('the app leaving the foreground (#234)', () {
    test('a step it leaves during is thrown away and run again once it is back, flagged in the JSON', () async {
      final front = StreamController<bool>();
      var song8 = 0;
      final fake = _HidingStress(onJob: (r, job) {
        // song8's timed run (after the warm-up), once: the app goes behind, then comes back.
        if (r.scenario == 'song8' && r.mode == StressMode.dsp && r.kind == StressKind.plain && ++song8 == 2) {
          front.add(false);
          Future<void>.delayed(const Duration(milliseconds: 20), () => front.add(true));
        }
      });
      final sent = <Map<String, Object?>>[];
      final res = await StressRunner(backend: fake, foreground: front.stream, sendTelemetry: (s) async => sent.add(s))
          .run(StressPlanKind.quick);
      expect(res.stoppedBecause, isNull);
      expect(res.backgroundedSteps, 1);
      final rows = res.scenarios.where((s) => s.id == 'song8' && !s.live).toList();
      expect(rows, hasLength(1)); // the cut-short run left nothing behind
      expect(rows.single.ran, isTrue);
      expect(rows.single.backgrounded, isTrue);
      expect(rows.single.toJson()['backgrounded'], isTrue);
      expect(res.toJson()['backgrounded_steps'], 1);
      expect(fake.cancelled, 1);
      expect(fake.started.where((r) => r.scenario == 'song8' && r.mode == StressMode.dsp && r.kind == StressKind.plain),
          hasLength(3)); // the warm-up, the run it left, the run again
      expect(res.scenarios.where((s) => s.id == 'first_loop').single.toJson()['backgrounded'], isFalse); // per scenario
      expect(TelemetryAllowList(isBuiltin: (id) => id.startsWith('org.caw.')).stress(sent.single), sent.single); // H2 unchanged
      await front.close();
    });

    test('a step it keeps leaving is skipped, never measured in the background', () async {
      final front = StreamController<bool>();
      final fake = _HidingStress(onJob: (r, job) {
        if (r.scenario == 'song16' && r.mode == StressMode.dsp && r.kind == StressKind.plain) {
          front.add(false);
          Future<void>.delayed(const Duration(milliseconds: 5), () => front.add(true));
        }
      });
      final res = await StressRunner(backend: fake, foreground: front.stream).run(StressPlanKind.quick);
      final row = res.scenarios.where((s) => s.id == 'song16' && !s.live).single;
      expect(row.ran, isFalse);
      expect(row.backgrounded, isTrue);
      expect(row.skipped, contains('foreground'));
      expect(res.backgroundedSteps, StressRunner.maxBackgroundRedos + 1);
      expect(res.stoppedBecause, isNull);
      await front.close();
    });

    test('the sustained run left for another app runs again in front and says so', () async {
      final front = StreamController<bool>();
      var once = false;
      final fake = _HidingStress(onJob: (r, job) {
        if (r.kind == StressKind.sustained && !once) {
          once = true;
          front.add(false);
          Future<void>.delayed(const Duration(milliseconds: 20), () => front.add(true));
        }
      });
      final res = await StressRunner(backend: fake, foreground: front.stream).run(StressPlanKind.full);
      expect(res.sustained, isNotNull);
      expect(res.sustained!.backgrounded, isTrue);
      expect(res.sustained!.toJson()['backgrounded'], isTrue);
      expect(fake.started.where((r) => r.kind == StressKind.sustained), hasLength(2));
      expect(res.backgroundedSteps, 1);
      await front.close();
    });

    test('a capped ramp (the engine refused the next count) keeps its limit and why', () async {
      final fake = FakeStress(extra: {'capped_by': 'the project uses 355 native components; at most 256 can run'});
      final res = await StressRunner(backend: fake).run(StressPlanKind.quick);
      final effects = res.ramps['effects']!; // the fake's effects ramp holds to its end
      expect(effects.capped, isTrue);
      expect(effects.toJson()['capped_by'], contains('at most 256'));
      expect(res.ramps['tracks']!.cappedBy, isNull); // over budget: not capped
    });

    test('behind at the start, it waits; Stop while it waits ends the run', () async {
      final fake = _HidingStress();
      late StressRunner runner;
      runner = StressRunner(backend: fake, foreground: const Stream<bool>.empty(), inForeground: () => false);
      final done = runner.run(StressPlanKind.quick);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.started, isEmpty);
      expect(runner.phase, contains('background'));
      runner.cancel();
      final res = await done;
      expect(res.stoppedBecause, 'You stopped it');
      expect(res.scenarios, isEmpty);
    });
  });

  test('a live row keeps the engine\'s audio threads and says its parts are unprofiled (#234)', () async {
    final fake = FakeStress(extra: {
      'parts_basis': 'unprofiled',
      'audio_threads': {'hint': false, 'hint_state': 'failed', 'callback_policy': 0, 'core_kind': 'little'},
    });
    final res = await StressRunner(backend: fake).run(StressPlanKind.quick);
    final live = res.scenarios.firstWhere((s) => s.live).toJson();
    expect(live['parts_basis'], 'unprofiled');
    expect((live['audio_threads'] as Map)['hint_state'], 'failed');
  });

  test('battery saver at the start: nothing runs, and it says why', () async {
    final fake = FakeStress();
    final host = FakeHost();
    final res = await StressRunner(backend: fake, host: host, readPressure: () async => EnginePressure.batterySaver)
        .run(StressPlanKind.quick);
    expect(fake.started, isEmpty);
    expect(host.suspended, 0);
    expect(res.stoppedBecause, contains('Battery saver'));
  });

  test('Extreme scenarios needing more than the work budget are skipped', () async {
    final fake = FakeStress();
    final res = await StressRunner(backend: fake, memoryBudgetMiB: 200).run(StressPlanKind.quick);
    expect(fake.started.any((r) => r.scenario == 'song32_heavy' && r.kind == StressKind.plain), isFalse);
    final row = res.scenarios.firstWhere((s) => s.id == 'song32_heavy');
    expect(row.skipped, contains('256 MiB'));
    expect(res.tier('extreme'), isNull);
    expect((res.toTelemetryStress()['scenarios'] as Map).containsKey('song32_heavy'), isFalse);
  });

  testWidgets('the screen at 360 dp: Quick run, then tiers, limits, costs, rows, Share and Save', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? saved, shared;
    final runner = StressRunner(backend: FakeStress());
    await tester.pumpWidget(MaterialApp(
        home: BenchmarkScreen(
            runner: runner,
            saveJson: (j) async {
              saved = j;
              return true;
            },
            share: (t) async {
              shared = t;
              return true;
            })));
    expect(find.byKey(const ValueKey('bench-quick')), findsOneWidget);
    expect(find.byKey(const ValueKey('bench-full')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bench-quick')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('bench-verdict')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('bench-raw-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bench-raw-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Comfortable'), findsOneWidget);
    expect(find.text('Over budget'), findsOneWidget);
    expect(find.byKey(const ValueKey('bench-limits')), findsOneWidget);
    expect(find.text('What\'s holding it back'), findsOneWidget);
    expect(find.text('Flagship'), findsOneWidget);
    final row = find.byKey(const ValueKey('bench-row-song8-false'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.textContaining('99% of callbacks within 40%'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('bench-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bench-save')));
    await tester.pumpAndSettle();
    expect(saved, contains('"tool": "caw_benchmark"'));
    await tester.tap(find.byKey(const ValueKey('bench-share')));
    await tester.pumpAndSettle();
    expect(shared, startsWith('C.A.W Benchmark (Quick run)'));
  });

  test('with the engine: a short run through the worker pool (needs CAW_LIB)', () async {
    final scenarios = const EngineStress().scenarios();
    // API 30: the ten telemetry knows first, then the feature scenarios (#197).
    expect([for (final s in scenarios.take(10)) s.id], telemetryScenarioIds.toList());
    expect(scenarios.length, 30);
    expect(scenarios.map((s) => s.id), containsAll(['empty', 'folders_deep', 'sends_many', 'worst_all']));
    final job = const EngineStress().start(const StressRequest(scenario: 'three_tracks', seconds: 0.5));
    final r = await job.result;
    expect(r['ok'], isTrue);
    expect(r['callbacks'], 93);
    final ramp = await const EngineStress()
        .start(const StressRequest(kind: StressKind.rampVoices, seconds: 0.05, frames: 8192))
        .result;
    expect(ramp['limit'], 64);
    final dir = await Directory.systemTemp.createTemp('caw-bench-test');
    final extras = await const EngineStress()
        .start(StressRequest(scenario: 'song8_extras', kind: StressKind.profile, seconds: 0.3, workDir: dir.path))
        .result;
    await dir.delete(recursive: true);
    expect(extras['ok'], isTrue);
    expect((extras['costs'] as List).any((c) => (c as Map)['id'] == 'host'), isTrue);
    final cancelled = const EngineStress().start(const StressRequest(scenario: 'song16', seconds: 600));
    // The timed span starts after the untimed warm-up (1.7 s of audio with the mix pool on Auto).
    for (var i = 0; i < 100 && cancelled.progress().callbacks == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(cancelled.progress().callbacks, greaterThan(0));
    cancelled.cancel();
    expect((await cancelled.result)['stop_reason'], 'cancelled');
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true ? 'set CAW_LIB to the built engine library' : null);
}
