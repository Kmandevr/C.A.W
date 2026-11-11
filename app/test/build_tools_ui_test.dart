// The Build tools' screens with a fake engine: the testing suite's request and result cards, the sample-pack maker's request, progress and cancel, and the plug-in export; goldens at phone and desktop size.
import 'dart:async';

import 'package:caw/engine/build_tools.dart';
import 'package:caw/engine/engine.dart' show NativeComponentTrust;
import 'package:caw/model/app_state.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/cpp/test_suite_screen.dart';
import 'package:caw/ui/cpp/tool_kit.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

/// A pack run the test finishes by hand.
class FakeRun implements PackRun {
  @override
  double progress = 0;
  bool cancelled = false;
  final done = Completer<Map<String, dynamic>>();
  @override
  void cancel() {
    cancelled = true;
    done.complete({'ok': false, 'error': 'cancelled'});
  }

  @override
  Future<Map<String, dynamic>> get result => done.future;
}

class FakeTools implements BuildToolsBackend {
  final tests = <Map<String, dynamic>>[];
  final packs = <Map<String, dynamic>>[];
  NativeComponentTrust? trust;
  FakeRun? run;
  Map<String, dynamic> testResult = sampleResult;

  @override
  Future<Map<String, dynamic>> test(Map<String, dynamic> request, {required NativeComponentTrust trust, String? outputDir}) async {
    tests.add(request);
    this.trust = trust;
    return testResult;
  }

  @override
  PackRun pack(Map<String, dynamic> request, {required NativeComponentTrust trust}) {
    packs.add(request);
    this.trust = trust;
    return run = FakeRun();
  }
}

/// A result shaped like docs/engine.md "Component testing" says.
final Map<String, dynamic> sampleResult = {
  'ok': true,
  'error': '',
  'output': {
    'channels': [
      {'peak_db': -3.2, 'rms_db': -9.1, 'gain_db': 2.5},
      {'peak_db': -3.4, 'rms_db': -9.3, 'gain_db': 2.3},
    ],
    'stereo': {'correlation': 0.98, 'width': 0.04},
    'thd': {'left': {'thd_percent': 4.21, 'thd_n_percent': 4.3}},
    'latency': {'declared': 0, 'measured': null, 'matches': null},
    'tail': {'declared': 0, 'measured': 12, 'measured_ms': 0.25, 'truncated': false, 'within_declared': true},
    'spectrum': {'bands': [for (var i = 0; i < 60; i++) [20.0 * (1 << (i ~/ 6)) * (1 + (i % 6) / 6), i == 30 ? -6.0 : -70.0 + (i % 7) * 4]]},
  },
  'cpu': {'blocks': 800, 'median_us': 6, 'worst_us': 40, 'median_percent': 0.45, 'worst_percent': 3.0},
  'bypass': {'exact': false, 'depth_db': -4.8, 'difference_peak_db': -7.0},
  'warnings': ['clipping'],
};

void main() {
  var motion = MotionLevel.full;
  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
  });
  tearDown(() => Motion.setting = motion);

  CppWorkbench workbench({bool built = true}) {
    final state = AppState(settings: Settings());
    state.project.cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
    final w = CppWorkbench(state, 'cpp1');
    if (built) w.debugArtifactPath = '/builds/fuzz.so';
    return w;
  }

  group('Test suite', () {
    test('reads a result into cards with verdicts', () {
      final r = TestSuiteResult.fromJson(sampleResult);
      expect(r.ok, isTrue);
      final byTitle = {for (final c in r.cards) c.title: c.status};
      expect(byTitle['Levels'], ToolStatus.warn); // clipping
      expect(byTitle['CPU'], ToolStatus.pass);
      expect(byTitle['Null test · against bypass'], ToolStatus.info);
      expect(r.overall, ToolStatus.warn);
      expect(r.spectrum, hasLength(60));
      expect(TestSuiteResult.fromJson({'ok': false, 'error': 'no such id'}).error, 'no such id');
      expect(TestSuiteResult.fromJson({...sampleResult, 'warnings': ['non_finite']}).overall, ToolStatus.fail);
    });

    testWidgets('sends the built library as trusted, with the chosen signal and comparisons', (tester) async {
      final fake = FakeTools();
      final w = workbench();
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: TestSuiteScreen(workbench: w, backend: fake)));
      await tester.tap(find.byKey(const ValueKey('signal-TestSignal.impulse')));
      await tester.tap(find.text('CPU per block'));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('tool-action')));
        for (var i = 0; i < 20 && fake.tests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final req = fake.tests.single;
      expect(req['component'], {'id': w.componentId, 'library': '/builds/fuzz.so', 'params': <String, double>{}});
      expect(req['signal'], {'type': 'impulse'});
      expect(req['cpu'], isFalse);
      expect(req['bypass'], isTrue);
      expect(req['align'], 'measured');
      expect(req.containsKey('trust'), isFalse);
      expect(fake.trust, NativeComponentTrust.trusted);
      expect(find.byKey(const ValueKey('test-summary')), findsOneWidget);
      expect(find.text('Passes, with things to check'), findsOneWidget);
    });

    testWidgets('before a build, Run is off and says why', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: TestSuiteScreen(workbench: workbench(built: false), backend: FakeTools())));
      expect(find.text('Build it first'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('tool-action'))).onPressed, isNull);
    });

    for (final name in const ['phone', 'desktop']) {
      testWidgets('golden: results at $name size', (tester) async {
        final fake = FakeTools();
        final w = workbench();
        await pumpGolden(tester, TestSuiteScreen(workbench: w, backend: fake), goldenSizes[name]!);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('tool-action')));
          for (var i = 0; i < 20 && fake.tests.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        await expectLater(goldenScreen, matchesGoldenFile('goldens/build_test_suite_$name.png'));
      });
    }
  });
}
