// Benchmark 2 (batch 1.0.2): engine parts and features parsed with limits, the verdict, the summary and drill-down screens, the plug-in benchmark's result and screen, the Builder's Benchmark button, and goldens.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/stress.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/component_bench.dart';
import 'package:caw/model/component_bench_result.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/native_components.dart';
import 'package:caw/model/native_trust.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/stress_result.dart';
import 'package:caw/model/stress_runner.dart';
import 'package:caw/ui/benchmark/benchmark_screen.dart';
import 'package:caw/ui/benchmark/part_detail_page.dart';
import 'package:caw/ui/benchmark/plugin_bench_screen.dart';
import 'package:caw/ui/cpp/build_section.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_test.dart' show FakeStress;
import 'component_bench_fake.dart';
import 'golden_util.dart';

Future<StressResult> quickRun() =>
    StressRunner(backend: FakeStress(), readDeviceName: () async => 'Samsung SM-S906B').run(StressPlanKind.quick);

Finder mark(String m) => find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == m);

Widget app(Widget home) => MaterialApp(theme: ThemeData.dark(), home: home);

const _target = ComponentBenchTarget(name: 'Lead', componentId: 'com.me.lead', libraryPath: '/b/lead.so', instrument: true);
const _effect = ComponentBenchTarget(name: 'Fuzz', componentId: 'com.me.fuzz', libraryPath: '/b/fuzz.so', instrument: false);

void main() {
  late MotionLevel motion;
  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.reduced;
  });
  tearDown(() => Motion.setting = motion);

  group('engine parts and features', () {
    test('parts are read with limits: bad entries skipped, values clamped, ids once and short, at most 24', () {
      expect(EnginePart.parseList(null), isEmpty);
      expect(EnginePart.parseList('mix'), isEmpty);
      final parts = EnginePart.parseList([
        'junk',
        {'pct': 4},
        {'id': '', 'pct': 4},
        {'id': 'mix', 'pct': 14.2, 'mean_us': 12.1, 'p99_us': 20.3},
        {'id': 'mix', 'pct': 99},
        {'id': 'sends', 'pct': 'lots', 'mean_us': -3},
        {'id': 'devices', 'pct': 250, 'mean_us': double.nan, 'p99_us': double.infinity},
        {'id': 'x' * 80, 'pct': 1},
      ]);
      expect([for (final p in parts) p.id], ['mix', 'sends', 'devices', 'x' * 32]);
      expect(parts[0].meanUs, 12.1);
      expect(parts[1].pct, 0);
      expect(parts[1].meanUs, 0);
      expect(parts[2].pct, 100);
      expect(parts[2].meanUs, 0);
      expect(parts[2].p99Us, 0);
      expect(EnginePart.parseList([for (var i = 0; i < 40; i++) {'id': 'p$i', 'pct': 1}]), hasLength(EnginePart.maxParts));
    });

    test('every part has a plain name; an unknown one is still shown', () {
      for (final id in EnginePart.info.keys) {
        expect(EnginePart(id: id, pct: 1).name, isNot(id));
      }
      expect(const EnginePart(id: 'gpu_offload', pct: 1).name, 'Gpu offload');
    });

    test('a scenario takes the engine\'s feature, else the contract\'s for its id', () {
      ScenarioResult row(Map<String, dynamic> j) => ScenarioResult.fromEngine({'callbacks': 1, 'ok': true, ...j}, name: 'n', tier: 'normal');
      expect(row({'scenario': 'sends_many', 'feature': 'sends'}).feature, 'sends');
      expect(row({'scenario': 'song8', 'feature': 'nonsense'}).feature, 'all');
      expect(row({'scenario': 'flagship_heavy16'}).feature, 'instrument');
      expect(row({'scenario': 'drums_kit'}).feature, 'instrument');
      expect(row({'scenario': 'tail_floor'}).feature, 'baseline');
      expect(row({'scenario': 'song8', 'parts': [{'id': 'mix', 'pct': 3}]}).parts.single.id, 'mix');
      for (final f in ['empty', 'single_audio', 'resample', 'metering_heavy', 'worst_all', 'modulation_dense']) {
        expect(stressFeatures.containsKey(scenarioFeature(f)), isTrue);
      }
    });

    test('a run keeps each profile\'s parts; the headline is song8\'s, costliest first; the verdict reads them', () async {
      final r = await quickRun();
      expect(r.partsByScenario.keys, ['song8']);
      expect(r.parts.first.id, 'devices');
      expect(r.overall, StressTier.tight); // normal comfortable, heavy (song16 at 85%) tight
      expect(r.verdictText, 'Normal projects: comfortable; heavy projects: tight.');
      expect(r.limitsShort, '~23 tracks · ~41 voices · 64 effects');
      expect(r.biggestCost, 'Biggest cost: instruments and effects (57%), mostly Flagship');
      expect(r.device['name'], 'Samsung SM-S906B');
      final json = jsonDecode(r.toJsonText()) as Map<String, dynamic>;
      expect(json['parts_scenario'], 'song8');
      expect((json['parts'] as List).first, {'id': 'devices', 'pct': 57.0, 'mean_us': 1214.1, 'p99_us': 1715.7});
      expect((json['scenarios'] as List).first['feature'], 'all');
      // H2 is unchanged: no parts, no features.
      final h2 = jsonEncode(r.toTelemetryStress());
      expect(h2, isNot(contains('parts')));
      expect(h2, isNot(contains('feature')));
    });

    test('a Full run also profiles one scenario per feature the engine lists; Quick adds worst_all', () {
      const s = [
        StressScenarioInfo(id: 'song8', name: 'a', tier: 'normal', memoryMiB: 1),
        StressScenarioInfo(id: 'sends_many', name: 'b', tier: 'heavy', memoryMiB: 1),
        StressScenarioInfo(id: 'worst_all', name: 'c', tier: 'extreme', memoryMiB: 1),
      ];
      List<String> profiled(StressPlanKind k) =>
          [for (final st in stressPlan(k, s)) if (st.request.kind == StressKind.profile) st.request.scenario];
      expect(profiled(StressPlanKind.quick), ['song8', 'worst_all']);
      expect(profiled(StressPlanKind.full), ['song8', 'song16', 'flagship_heavy16', 'sends_many', 'worst_all']);
    });

    test('tips are plain and name the share', () {
      expect(partTips('sends', 31.4).single, 'Sends cost 31%; fewer sends, or folder tracks instead, cost less.');
      expect(partTips('devices', 50), hasLength(2));
      expect(partTips('mix', 2).single, contains('small'));
    });

    test('no verdict before anything ran', () {
      final r = StressResult(plan: 'quick', startedAt: DateTime(2026));
      expect(r.overall, isNull);
      expect(r.biggestCost, isNull);
      expect(r.limitsShort, '');
    });
  });

  group('plug-in benchmark result', () {
    test('an instrument: header numbers, fails then warnings then passes, sections slowest first, three curves', () {
      final r = ComponentBenchResult.parse(benchFixture('instrument'));
      expect(r.ok, isTrue);
      expect(r.isInstrument, isTrue);
      expect(r.name, 'Lead');
      expect(r.costPct, 12.4);
      expect([for (final c in r.checks) c.status], [
        BenchCheckStatus.fail, BenchCheckStatus.warn, BenchCheckStatus.warn,
        BenchCheckStatus.pass, BenchCheckStatus.pass, BenchCheckStatus.pass, BenchCheckStatus.pass,
      ]);
      expect(r.checks.first.id, 'sample_rate_scaling');
      expect([for (final s in r.sections) s.name], ['resonance', 'oscillators', 'envelope']);
      expect([for (final c in r.curves) c.id], ['voices', 'block_frames', 'sample_rate']);
    });

    test('an allocation check the app could not measure is said plainly, not as a warning', () {
      final json = benchFixture('effect');
      (json['checks'] as List)[0] = {'id': 'allocations', 'status': 'warn', 'value': -1, 'detail': 'x', 'measured': false};
      final r = ComponentBenchResult.parse(json);
      final a = r.checks.firstWhere((c) => c.id == 'allocations');
      expect(a.status, BenchCheckStatus.notMeasured);
      expect(a.detail, 'Not measured in the app (run the test build)');
      expect(r.checks.last.id, 'allocations');  // after the passes
    });

    test('an effect: no cost per voice, no sections, no voices curve', () {
      final r = ComponentBenchResult.parse(benchFixture('effect'));
      expect(r.isInstrument, isFalse);
      expect(r.checks.any((c) => c.id == 'cost_per_voice'), isFalse);
      expect(r.sections, isEmpty);
      expect([for (final c in r.curves) c.id], ['block_frames', 'sample_rate']);
    });

    test('malformed input is a result with an error, never a throw', () {
      expect(ComponentBenchResult.parseText('{not json').error, isNotNull);
      expect(ComponentBenchResult.parseText('[1,2]').error, isNotNull);
      expect(ComponentBenchResult.parseText(' ' * (ComponentBenchResult.maxBytes + 1)).error, contains('too large'));
      expect(ComponentBenchResult.parse({'tool': 'caw_benchmark'}).error, isNotNull);
      expect(ComponentBenchResult.parse({'ok': false, 'error': 'the pool did not take it'}).error, 'the pool did not take it');
      expect(ComponentBenchResult.parse({'ok': false}).error, 'The benchmark failed');
    });

    test('bounded: at most 16 checks and 32 sections, bad rows skipped, names cleaned and cut, curves checked', () {
      final r = ComponentBenchResult.parse({
        'tool': 'caw_component_bench',
        'component': {'id': 7, 'name': 'N\u0000ame${'e' * 200}', 'kind': 'weird'},
        'cost_pct': -4,
        'checks': [
          {'id': 'a', 'status': 'maybe'},
          {'status': 'pass'},
          for (var i = 0; i < 30; i++) {'id': 'c$i', 'status': 'pass', 'value': 'x', 'detail': 3},
        ],
        'sections': [
          {'pct': 3},
          for (var i = 0; i < 50; i++) {'name': 's$i', 'pct': i.toDouble(), 'calls': -2},
        ],
        'curves': {
          'voices': [[1, 2], 'x', [3], ['a', 1], [-1, 1], [2, 5000], for (var i = 0; i < 100; i++) [i + 10, 1]],
          'sample_rate': [[48000, 1]],
          'block_frames': 'no',
        },
      });
      expect(r.ok, isTrue);
      expect(r.componentId, '');
      expect(r.kind, 'effect');
      expect(r.name.length, lessThanOrEqualTo(64));
      expect(r.name, startsWith('N ame'));
      expect(r.costPct, 0);
      expect(r.checks, hasLength(ComponentBenchResult.maxChecks));
      expect(r.checks.first.value, isNull);
      expect(r.checks.first.detail, '');
      expect(r.sections, hasLength(ComponentBenchResult.maxSections));
      expect(r.sections.first.calls, 0);
      expect(r.curves.single.id, 'voices'); // one point isn't a curve
      expect(r.curves.single.points, hasLength(ComponentBenchResult.maxPoints));
      expect(r.curves.single.points[1], (2.0, 1000.0));
    });
  });

  group('summary screens', () {
    Future<void> pumpResults(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(BenchmarkScreen(
          runner: StressRunner(backend: FakeStress(), readDeviceName: () async => 'Samsung SM-S906B'),
          saveJson: (_) async => true,
          share: (_) async => true)));
      await tester.tap(find.byKey(const ValueKey('bench-quick')));
      await tester.pumpAndSettle();
    }

    testWidgets('the verdict card: device, overall tier, limits, biggest cost', (tester) async {
      await pumpResults(tester);
      expect(find.text('Samsung SM-S906B'), findsOneWidget);
      expect(find.byKey(const ValueKey('bench-overall-tight')), findsOneWidget);
      expect(find.text('~23 tracks · ~41 voices · 64 effects'), findsOneWidget);
      expect(find.textContaining('Biggest cost: instruments and effects'), findsOneWidget);
    });

    testWidgets('a bar for each part, costliest first; each opens its drill-down', (tester) async {
      await pumpResults(tester);
      final ids = [for (final p in fakeIds) p];
      final ys = <double>[];
      for (final id in ids) {
        final bar = find.byKey(ValueKey('bench-part-$id'));
        expect(bar, findsOneWidget, reason: id);
        ys.add(tester.getTopLeft(bar).dy);
      }
      expect([...ys]..sort(), ys);
      for (final id in ids) {
        final bar = find.byKey(ValueKey('bench-part-$id'));
        await tester.ensureVisible(bar);
        await tester.pumpAndSettle();
        await tester.tap(bar);
        await tester.pumpAndSettle();
        expect(find.byType(PartDetailPage), findsOneWidget, reason: id);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('part-table')), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('the sends drill-down: its numbers, where it mattered, a plain tip', (tester) async {
      await pumpResults(tester);
      await tester.tap(find.byKey(const ValueKey('bench-part-sends')));
      await tester.pumpAndSettle();
      expect(find.text('Sends'), findsOneWidget);
      expect(find.text('Sends cost 8%; fewer sends, or folder tracks instead, cost less.'), findsOneWidget);
      expect(find.byKey(const ValueKey('part-most-song8')), findsOneWidget);
      expect(find.text('170.4 µs'), findsOneWidget); // mean
      expect(find.text('240.8 µs'), findsOneWidget); // p99
      expect(find.byKey(const ValueKey('part-device-song8-org.caw.synth.flagship')), findsNothing);
    });

    testWidgets('the devices drill-down lists each device\'s cost', (tester) async {
      await pumpResults(tester);
      await tester.tap(find.byKey(const ValueKey('bench-part-devices')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('part-device-song8-org.caw.synth.flagship')), 200);
      expect(find.byKey(const ValueKey('part-device-song8-org.caw.reverb.pro')), findsOneWidget);
      expect(find.byKey(const ValueKey('part-device-song8-host')), findsNothing);
      expect(find.text('6 of it'), findsOneWidget);
    });

    testWidgets('scenarios grouped by feature, best first, each with its tier; tap for full numbers', (tester) async {
      await pumpResults(tester);
      expect(find.byKey(const ValueKey('bench-group-baseline')), findsOneWidget);
      expect(find.byKey(const ValueKey('bench-group-all')), findsOneWidget);
      // Baseline (2%) comes before whole songs (worst 160%).
      expect(tester.getTopLeft(find.byKey(const ValueKey('bench-group-baseline'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('bench-group-all'))).dy));
      final y = [
        for (final id in ['first_loop', 'song8', 'song16', 'song32_heavy'])
          tester.getTopLeft(find.byKey(ValueKey('bench-scn-$id-false'))).dy,
      ];
      expect([...y]..sort(), y);
      final row = find.byKey(const ValueKey('bench-scn-song16-false'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.textContaining('Tight. Average 68%'), findsOneWidget);
    });

    testWidgets('an engine without parts: the components\' costs, no drill-down', (tester) async {
      final r = StressRunner(backend: FakeStress(extra: {'parts': null}));
      await tester.pumpWidget(app(BenchmarkScreen(runner: r, saveJson: (_) async => true, share: (_) async => true)));
      await tester.tap(find.byKey(const ValueKey('bench-quick')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bench-part-devices')), findsNothing);
      expect(find.byKey(const ValueKey('bench-partcost-org.caw.synth.flagship')), findsOneWidget);
    });
  });

  group('plug-in benchmark screen', () {
    Future<FakeComponentBench> open(WidgetTester tester, ComponentBenchTarget t, {Map<String, dynamic>? json, bool hold = false}) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = FakeComponentBench(json: json, hold: hold);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(PluginBenchScreen(target: t, runner: ComponentBenchRunner(backend: fake))));
      await tester.pump();
      hold ? await tester.pump(const Duration(milliseconds: 300)) : await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('an instrument: its cost, checks with ✗ and ⚠ first, sections, curves on a tap', (tester) async {
      final fake = await open(tester, _target);
      expect(fake.started.single.libraryPath, '/b/lead.so');
      expect(fake.started.single.instrument, isTrue);
      expect(find.text('Lead · instrument'), findsOneWidget);
      expect(find.text('12% of a block'), findsOneWidget);
      final ys = [
        for (final id in ['sample_rate_scaling', 'denormals', 'silence_cost', 'allocations', 'cost_per_voice'])
          tester.getTopLeft(find.byKey(ValueKey('pbench-check-$id'))).dy,
      ];
      expect([...ys]..sort(), ys);
      expect(mark('✗'), findsOneWidget);
      expect(mark('⚠'), findsNWidgets(2));
      expect(mark('✓'), findsNWidgets(4));
      expect(find.text('38% slower at silence'), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const ValueKey('pbench-section-resonance'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('pbench-section-oscillators'))).dy));
      expect(find.byKey(const ValueKey('pbench-curves')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('pbench-curves-toggle')));
      await tester.tap(find.byKey(const ValueKey('pbench-curves-toggle')));
      await tester.pumpAndSettle();
      for (final id in ['voices', 'block_frames', 'sample_rate']) {
        expect(find.byKey(ValueKey('pbench-curve-$id')), findsOneWidget);
      }
      expect(find.text('These numbers stay on this device; they are never sent.'), findsOneWidget);
    });

    testWidgets('an effect without sections: the CAW_PROFILE_SCOPE hint, no voices curve', (tester) async {
      await open(tester, _effect);
      expect(find.text('Fuzz · effect'), findsOneWidget);
      expect(find.byKey(const ValueKey('pbench-no-sections')), findsOneWidget);
      expect(find.textContaining('CAW_PROFILE_SCOPE'), findsOneWidget);
      expect(find.byKey(const ValueKey('pbench-check-cost_per_voice')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('pbench-curves-toggle')));
      await tester.tap(find.byKey(const ValueKey('pbench-curves-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pbench-curve-voices')), findsNothing);
      expect(find.byKey(const ValueKey('pbench-curve-sample_rate')), findsOneWidget);
    });

    testWidgets('an engine without it says so, and Stop ends a run', (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(PluginBenchScreen(target: _effect, runner: ComponentBenchRunner(backend: const NoComponentBench()))));
      await tester.pumpAndSettle();
      expect(find.text('This engine has no plug-in benchmark yet'), findsOneWidget);
      await open(tester, _effect, hold: true);
      expect(find.byKey(const ValueKey('pbench-running')), findsOneWidget);
      expect(find.byKey(const ValueKey('pbench-in-process')), findsOneWidget);  // says it runs in the app's process
      await tester.tap(find.byKey(const ValueKey('pbench-stop')));
      await tester.pumpAndSettle();
      expect(find.text('You stopped it'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pbench-again')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('pbench-running')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Settings › Performance › Benchmark lists built plug-ins, each with Benchmark', (tester) async {
      final fake = FakeComponentBench();
      await tester.pumpWidget(app(BenchmarkScreen(
          runner: StressRunner(backend: FakeStress()), plugins: const [_target, _effect], pluginBackend: fake)));
      expect(find.text('Lead · instrument'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bench-plugin-com.me.fuzz')));
      await tester.pumpAndSettle();
      expect(find.byType(PluginBenchScreen), findsOneWidget);
      expect(fake.started.single.componentId, 'com.me.fuzz');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(BenchmarkScreen(runner: StressRunner(backend: FakeStress()), plugins: const [])));
      expect(find.byKey(const ValueKey('bench-plugins-none')), findsOneWidget);
    });
  });

  group('the Builder\'s Benchmark button', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw-bench-btn'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('disabled with a reason until built, then it times the build', (tester) async {
      final fake = FakeComponentBench();
      ComponentBenchBackend.current = fake;
      addTearDown(() => ComponentBenchBackend.current = const NoComponentBench());
      final state = AppState(settings: Settings());
      state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      // The user's own code: Trusted (only trusted code is listed or run).
      final trust = NativeTrustStore(File('${dir.path}/trust.json'))..markAuthored(doc);
      state.nativeComponents = NativeComponentManager(
          trust: trust,
          cacheFile: File('${dir.path}/builds.json'),
          build: (_, _) => throw UnimplementedError(),
          load: ({required artifactPath, required expectedComponentId, required trust, bool reload = false}) =>
              throw UnimplementedError());
      final sections = SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
      await tester.pumpWidget(app(Scaffold(body: SectionScope(controller: sections, child: BuildSection(state: state)))));
      await tester.pump();
      final button = find.byKey(const ValueKey('bench-plugin'));
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(button).onPressed, isNull); // an icon under 1000 dp
      expect(find.byTooltip('Build it first: there is nothing to benchmark yet'), findsOneWidget);
      expect(componentBenchTargets(state), isEmpty);
      final w = state.openCppWorkbench('cpp1')!;
      w.debugArtifactPath = '${dir.path}/fuzz.so';
      w.debugMarkBuilt();
      await tester.pump();
      expect(componentBenchTargets(state).single.libraryPath, '${dir.path}/fuzz.so');
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(PluginBenchScreen), findsOneWidget);
      expect(fake.started.single.libraryPath, '${dir.path}/fuzz.so');
      expect(fake.started.single.instrument, isFalse);
      expect(fake.started.single.trusted, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      state.dispose(); // the run woke its poller
    });
  });

  group('goldens', () {
    testWidgets('golden: the Benchmark summary at phone size', (tester) async {
      await pumpGolden(
          tester,
          BenchmarkScreen(
              runner: StressRunner(backend: FakeStress(), readDeviceName: () async => 'Samsung SM-S906B'),
              saveJson: (_) async => true,
              share: (_) async => true),
          goldenSizes['phone']!);
      await tester.tap(find.byKey(const ValueKey('bench-quick')));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -110));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/bench_summary_phone.png'));
    });

    testWidgets('golden: the plug-in benchmark result at phone size', (tester) async {
      await pumpGolden(tester, PluginBenchScreen(target: _target, runner: ComponentBenchRunner(backend: FakeComponentBench())),
          goldenSizes['phone']!);
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/bench_plugin_phone.png'));
    });
  });
}

/// The fake profile's parts, costliest first (benchmark_test.dart's fakeParts for song8).
const fakeIds = ['devices', 'mix', 'sends', 'routing', 'automation', 'voices', 'samples', 'metering', 'mix_pool', 'master', 'other', 'device_io'];
