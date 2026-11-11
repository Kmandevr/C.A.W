// The Build tools' screens with a fake engine: the testing suite's request (an effect's signal, an instrument's notes, the thresholds) and result cards, the sample-pack maker's request, progress, cancel and zip, and the plug-in export (CLAP and VST3); goldens at phone and desktop size.
import 'dart:async';

import 'package:caw/ui/frame/sections.dart' show AssetKind;
import 'package:caw/engine/build_tools.dart';
import 'package:caw/engine/engine.dart' show NativeComponentTrust;
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/sample_packs.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/cpp/plugin_export_screen.dart';
import 'package:caw/ui/cpp/sample_pack_screen.dart';
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

  /// Presses Run and waits, in real time, until the run has finished: the screen records its verdict only after the
  /// fake's answer and its own file checks, so a busy machine can't leave the progress bar spinning into
  /// pumpAndSettle.
  Future<void> runSuite(WidgetTester tester, CppWorkbench w) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('tool-action')));
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (w.lastTest == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(w.lastTest, isNotNull, reason: 'the run did not finish');
  }

  CppWorkbench workbench({bool built = true, bool instrument = false}) {
    final state = AppState(settings: Settings());
    state.project.cppComponents.add(instrument
        ? CppComponentDoc.blankInstrument(id: 'cpp1', name: 'Lead')
        : CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
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
      await runSuite(tester, w);
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

    test('reads the thresholds into a pass/fail card that sets the verdict', () {
      final failed = TestSuiteResult.fromJson({...sampleResult, 'warnings': <String>[], 'passed': false, 'checks': [
        {'path': 'output.channels.0.peak_db', 'value': -3.2, 'max': -0.3, 'pass': true},
        {'path': 'cpu.median_percent', 'value': null, 'max': 50, 'pass': false},
      ]});
      final card = failed.cards.firstWhere((c) => c.title == 'Thresholds');
      expect(card.status, ToolStatus.fail);
      expect(card.lines, [('✓ Peak L ≤ −0.3 dB', '-3.2'), ('✗ Median block < 50 %', 'missing')]);
      expect(failed.overall, ToolStatus.fail);
      final passed = TestSuiteResult.fromJson({...sampleResult, 'warnings': <String>[], 'passed': true, 'checks': [
        {'path': 'output.channels.1.rms_db', 'value': -9.3, 'min': -70, 'pass': true},
      ]});
      expect(passed.cards.firstWhere((c) => c.title == 'Thresholds').status, ToolStatus.pass);
      expect(passed.overall, ToolStatus.pass);
      expect(TestSuiteResult.fromJson(sampleResult).cards.where((c) => c.title == 'Thresholds'), isEmpty);
    });

    testWidgets('an instrument is played the chosen notes, with the thresholds as checks and no bypass', (tester) async {
      final fake = FakeTools()
        ..testResult = {
          'ok': true, 'error': '', 'warnings': <String>[], 'passed': true,
          'settings': {'signal': 'notes', 'notes': 3},
          'output': {
            'channels': [{'peak_db': -4.0, 'rms_db': -14.0, 'gain_db': null}, {'peak_db': -4.1, 'rms_db': -14.2, 'gain_db': null}],
            'latency': null, 'thd': null,
            'tail': {'declared': 4800, 'measured': 2400, 'measured_ms': 50.0, 'truncated': false, 'within_declared': true},
          },
          'checks': [{'path': 'output.channels.0.peak_db', 'value': -4.0, 'max': -0.3, 'pass': true}],
        };
      final w = workbench(instrument: true);
      expect(w.isInstrument, isTrue);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: TestSuiteScreen(workbench: w, backend: fake)));
      expect(find.text('A/B against bypass'), findsNothing);
      expect(find.byKey(const ValueKey('signal-TestSignal.sine')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('notes-TestNotes.chord')));
      await tester.ensureVisible(find.byKey(const ValueKey('test-threshold-realtime')));
      await tester.tap(find.byKey(const ValueKey('test-threshold-realtime')));
      await tester.pump();
      await runSuite(tester, w);
      await tester.pumpAndSettle();
      final req = fake.tests.single;
      expect(req['notes'], [for (final p in const [60, 64, 67]) {'pitch': p, 'velocity': 100, 'start': 0, 'length': 1}]);
      expect(req.containsKey('signal'), isFalse);
      expect(req.containsKey('bypass'), isFalse);
      expect(req['align'], 'declared');
      expect([for (final c in req['checks'] as List) (c as Map)['path']], [
        'output.channels.0.peak_db', 'output.channels.1.peak_db', 'output.channels.0.rms_db', 'output.channels.1.rms_db',
        'cpu.median_percent',
      ]);
      expect(fake.trust, NativeComponentTrust.trusted);
      expect(find.text('All checks pass'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-card-Thresholds')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-card-Latency')), findsNothing, reason: 'an instrument has no input to measure it against');
      expect(find.text('Chord played on Lead, default knobs.'), findsOneWidget);
    });

    testWidgets('with CPU timing off, the real-time threshold is not sent', (tester) async {
      final fake = FakeTools();
      final w = workbench();
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: TestSuiteScreen(workbench: w, backend: fake)));
      await tester.tap(find.text('CPU per block'));
      await tester.ensureVisible(find.byKey(const ValueKey('test-threshold-realtime')));
      await tester.tap(find.byKey(const ValueKey('test-threshold-realtime')));
      await tester.tap(find.byKey(const ValueKey('test-threshold-headroom'))); // off
      await tester.pump();
      expect(find.text('${TestThreshold.realtime.detail} (needs CPU per block)'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-summary')), findsNothing);
      await runSuite(tester, w);
      await tester.pumpAndSettle();
      expect([for (final c in fake.tests.single['checks'] as List) (c as Map)['path']],
          ['output.channels.0.rms_db', 'output.channels.1.rms_db']);
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
        await runSuite(tester, w);
        await tester.pumpAndSettle();
        await expectLater(goldenScreen, matchesGoldenFile('goldens/build_test_suite_$name.png'));
      });
    }
  });

  group('Sample-pack maker', () {
    const flagship = NativeComponentInfo(id: 'org.caw.synth.flagship', name: 'Flagship', builtin: true, ports: [
      ComponentPortInfo(id: 'notes', type: 'event', input: true, layout: 'none', channels: 0),
      ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
    ]);
    late Directory root;
    late AppState state;
    setUp(() {
      root = Directory.systemTemp.createTempSync('caw-packs');
      state = AppState(settings: Settings());
      state.samplePacksRoot = root;
      state.componentCatalog.set([flagship]);
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<void> render(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('tool-action')));
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
    }

    testWidgets('sends the grid, shows progress, and Cancel stops it', (tester) async {
      final fake = FakeTools();
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
          home: SamplePackScreen(state: state, instrumentId: flagship.id, backend: fake)));
      expect(find.text('Render 5 files'), findsOneWidget); // C2..C6 in octaves
      await tester.tap(find.byKey(const ValueKey('pack-layers-2')));
      await tester.ensureVisible(find.text('Loop points'));
      await tester.tap(find.text('Loop points'));
      await tester.pump();
      expect(find.text('Render 10 files'), findsOneWidget);
      await render(tester);
      final req = fake.packs.single;
      expect(req['instrument'], {'id': flagship.id});
      expect(req['notes'], [36, 48, 60, 72, 84]);
      expect(req['velocities'], [64, 127]);
      expect(req['output_dir'], '${root.path}${Platform.pathSeparator}Flagship');
      expect(req['name'], 'Flagship');
      expect(req['loop'], {'enabled': true, 'min_seconds': 0.05, 'max_seconds': 0.5});
      expect(req['sfz'], isTrue);
      expect(req['max_files'], 10);
      expect(req.containsKey('trust'), isFalse);
      expect(fake.trust, NativeComponentTrust.blocked); // a built-in names no library
      fake.run!.progress = 0.4;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250))); // the screen polls on a real timer
      await tester.pump();
      expect(find.text('Rendering offline… 40%'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('tool-cancel')));
      });
      for (var i = 0; i < 100 && find.byKey(const ValueKey('pack-error')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(fake.run!.cancelled, isTrue);
      expect(find.byKey(const ValueKey('pack-error')), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('a finished pack saves as one zip through the picker', (tester) async {
      final fake = FakeTools();
      final saved = <String, List<String>>{};
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: SamplePackScreen(state: state,
          instrumentId: flagship.id, backend: fake, saveZip: (zip, name) async {
            final unzip = await Process.run('unzip', ['-Z1', zip.path]);
            saved[name] = '${unzip.stdout}'.trim().split('\n');
            return true;
          })));
      await render(tester);
      final dir = Directory('${root.path}/Flagship')..createSync();
      await tester.runAsync(() async {
        for (final n in ['C2', 'C3']) {
          File('${dir.path}/Flagship_${n}_100.wav').writeAsBytesSync(List.filled(64, 1));
        }
        File('${dir.path}/Flagship.sfz').writeAsStringSync('<region> sample=Flagship_C2_100.wav');
        File('${dir.path}/Flagship.json').writeAsStringSync('{"files": []}');
        File('${dir.path}/Flagship_C4_100.wav.part').writeAsBytesSync([0]); // a half-written file stays out
        fake.run!.done.complete({'ok': true, 'error': '', 'warnings': <String>[], 'sfz': ['Flagship.sfz'],
          'files': [for (final n in ['C2', 'C3']) {'file': 'Flagship_${n}_100.wav', 'seconds': 1.0, 'loop': null}]});
      });
      for (var i = 0; i < 100 && find.byKey(const ValueKey('pack-result')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const ValueKey('pack-save-zip')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('pack-save-zip')));
        for (var i = 0; i < 200 && saved.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(saved.keys.single, 'Flagship.zip');
      expect(saved.values.single, ['Flagship/Flagship.json', 'Flagship/Flagship.sfz', 'Flagship/Flagship_C2_100.wav',
        'Flagship/Flagship_C3_100.wav']);
      expect(find.text('Saved Flagship.zip (4 files).'), findsOneWidget);
    });

    testWidgets('a project instrument that is not built says so', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
          home: SamplePackScreen(state: state, instrumentId: 'local.my-synth', backend: FakeTools())));
      expect(find.textContaining('Build this C++ instrument first'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('tool-action'))).onPressed, isNull);
    });

    test('Files lists a rendered pack from its manifest, and deleting the last WAV removes the pack', () async {
      final dir = Directory('${root.path}/Lead')..createSync();
      File('${dir.path}/Lead_C4_100.wav').writeAsBytesSync([0]);
      File('${dir.path}/Lead.json').writeAsStringSync(jsonEncode({
        'instrument': {'id': 'org.caw.synth.flagship'},
        'files': [{'file': 'Lead_C4_100.wav', 'note_name': 'C4', 'velocity': 100, 'seconds': 1.5, 'loop': null}],
        'sfz': ['Lead.sfz'],
      }));
      await state.refreshSamplePacks();
      expect(state.samplePacks.single.name, 'Lead');
      final folder = state.folderAt('audio/samples/Lead')!;
      expect(folder.kind, FilesFolderKind.samplePack);
      final wav = state.folderAssets(folder).single;
      expect(wav.type, FileAssetType.sampleFile);
      expect(wav.sample!.noteName, 'C4');
      // A pack's WAV drags as audio (a clip where it lands, or a sampler zone).
      expect(wav.drag!.kind, AssetKind.audioFile);
      expect(wav.drag!.id, wav.sample!.path);
      state.deleteAsset(wav);
      for (var i = 0; i < 50 && state.samplePacks.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(dir.existsSync(), isFalse);
      expect(state.samplePacks, isEmpty);
    });

    for (final name in const ['phone', 'desktop']) {
      testWidgets('golden: a finished pack at $name size', (tester) async {
        final fake = FakeTools();
        await pumpGolden(tester, SamplePackScreen(state: state, instrumentId: flagship.id, backend: fake), goldenSizes[name]!);
        await render(tester);
        await tester.runAsync(() async {
          fake.run!.done.complete({
            'ok': true, 'error': '', 'warnings': <String>[], 'sfz': ['Flagship.sfz'],
            'files': [for (final n in ['C2', 'C3', 'C4', 'C5', 'C6']) {'file': 'Flagship_${n}_100.wav', 'seconds': 1.42, 'loop': null}],
          });
        });
        // The screen re-reads the packs from disk (real I/O) before it shows the result.
        for (var i = 0; i < 100 && find.byKey(const ValueKey('pack-result')).evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('pack-result')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('pack-result')));
        await tester.pumpAndSettle();
        await expectLater(goldenScreen, matchesGoldenFile('goldens/build_sample_pack_$name.png'));
      });
    }
  });

  group('Export as plug-in', () {
    testWidgets('needs a vendor, offers CLAP and VST3, keeps macOS off, and saves the package zip', (tester) async {
      final saved = <String, List<int>>{};
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: PluginExportScreen(workbench: workbench(),
          save: (bytes, name) async {
            saved[name] = bytes;
            return true;
          })));
      expect(find.text('• Give a vendor (your name or label).'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('tool-action'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('plugin-format-PluginFormat.vst3')));
      await tester.pump();
      expect(find.textContaining('wrapper'), findsNothing);
      expect(find.text('Name (the file: fuzz.vst3)'), findsOneWidget);
      expect(find.text(r'C:\Program Files\Common Files\VST3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('plugin-format-PluginFormat.clap')));
      await tester.pump();
      expect(find.text(r'C:\Program Files\Common Files\CLAP'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('plugin-format-PluginFormat.vst3')));
      await tester.enterText(find.byKey(const ValueKey('plugin-vendor')), 'Me');
      await tester.pump();
      expect(tester.widget<Switch>(find.descendant(of: find.byKey(const ValueKey('plugin-target-macos')),
          matching: find.byType(Switch))).onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('tool-action')));
      await tester.pumpAndSettle();
      expect(saved.keys.single, 'fuzz-plugin.zip');
      expect(find.byKey(const ValueKey('plugin-saved')), findsOneWidget);
    });

    for (final name in const ['phone', 'desktop']) {
      testWidgets('golden: the export page at $name size', (tester) async {
        await pumpGolden(tester, PluginExportScreen(workbench: workbench(), save: (_, _) async => true), goldenSizes[name]!);
        await tester.enterText(find.byKey(const ValueKey('plugin-vendor')), 'Me');
        FocusManager.instance.primaryFocus?.unfocus(); // no blinking cursor in the golden
        await tester.pumpAndSettle();
        await expectLater(goldenScreen, matchesGoldenFile('goldens/build_plugin_export_$name.png'));
      });
    }
  });
}
