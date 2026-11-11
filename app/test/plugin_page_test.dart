// The plug-in page (Write → Build → Test → Export): each step's status and one-line result, out of date after an edit, the next button, errors that jump to the code, the export warning and targets, the editor's button and the track card's menu leading here; goldens at phone and desktop size.
import 'dart:io';

import 'package:caw/engine/build_tools.dart';
import 'package:caw/engine/engine.dart' show NativeComponentTrust;
import 'package:caw/model/app_state.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_diagnostics.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/cpp/build_section.dart';
import 'package:caw/ui/cpp/plugin_export_screen.dart';
import 'package:caw/ui/cpp/plugin_screen.dart';
import 'package:caw/ui/cpp/sample_pack_screen.dart';
import 'package:caw/ui/cpp/test_suite_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/page_closer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

class _Tools implements BuildToolsBackend {
  Map<String, dynamic> result = {
    'ok': true,
    'output': {
      'channels': [
        {'peak_db': -3.0, 'rms_db': -12.0},
        {'peak_db': -3.1, 'rms_db': -12.2},
      ],
      'tail': {'declared': 0, 'measured_ms': 0.2, 'truncated': false, 'within_declared': true},
    },
    'checks': [
      {'path': 'output.channels.0.peak_db', 'value': -3.0, 'pass': true},
      {'path': 'output.channels.1.peak_db', 'value': -3.1, 'pass': true},
    ],
    'passed': true,
    'warnings': <String>[],
  };

  @override
  Future<Map<String, dynamic>> test(Map<String, dynamic> request, {required NativeComponentTrust trust, String? outputDir}) async =>
      result;

  @override
  PackRun pack(Map<String, dynamic> request, {required NativeComponentTrust trust}) => throw UnimplementedError();
}

void main() {
  var motion = MotionLevel.full;
  late Directory dir;
  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
    dir = Directory.systemTemp.createTempSync('caw-plugin-page');
  });
  tearDown(() {
    Motion.setting = motion;
    dir.deleteSync(recursive: true);
  });

  CppWorkbench workbench({bool built = false, bool instrument = false}) {
    final state = AppState(settings: Settings());
    state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
    state.project.cppComponents.add(instrument
        ? CppComponentDoc.blankInstrument(id: 'cpp1', name: 'Lead')
        : CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
    final w = CppWorkbench(state, 'cpp1', saveDelay: const Duration(milliseconds: 10), checkDelay: const Duration(milliseconds: 10));
    if (built) {
      w.debugArtifactPath = '/builds/fuzz.so';
      w.debugMarkBuilt();
    }
    return w;
  }

  Widget app(Widget home) => MaterialApp(theme: ThemeData.dark(), home: home);

  String summary(WidgetTester t, String step) => t.widget<Text>(find.byKey(ValueKey('plugin-summary-$step'))).data!;
  String state(WidgetTester t, String step) =>
      t.widget<Text>(find.descendant(of: find.byKey(ValueKey('plugin-state-$step')), matching: find.byType(Text))).data!;
  String next(WidgetTester t) =>
      t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('tool-action')), matching: find.byType(Text))).data!;

  testWidgets('a new effect: nothing built, every later step not run, and Build is next', (tester) async {
    await tester.pumpWidget(app(PluginScreen(workbench: workbench())));
    expect(find.text('Plug-in'), findsOneWidget);
    expect(find.text('Fuzz · effect'), findsOneWidget);
    expect(state(tester, 'write'), 'DONE');
    expect(summary(tester, 'write'), contains('no problems found'));
    expect(state(tester, 'build'), 'NOT RUN');
    expect(summary(tester, 'build'), 'Not built yet');
    expect(state(tester, 'test'), 'NOT RUN');
    expect(summary(tester, 'test'), 'Needs a build first');
    expect(state(tester, 'export'), 'NOT RUN');
    expect(summary(tester, 'export'), 'CLAP or VST3');
    expect(next(tester), 'Build');
    // An effect exports as CLAP or VST3; a sample pack is an instrument's.
    expect(find.byKey(const ValueKey('plugin-target-clap')), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-target-vst3')), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-target-pack')), findsNothing);
    expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('plugin-open-tests'))).onPressed, isNull);
  });

  testWidgets('built: Test is next; the test suite records its verdict and thresholds on the Test step', (tester) async {
    final w = workbench(built: true);
    final tools = _Tools();
    await tester.pumpWidget(app(PluginScreen(workbench: w, backend: tools)));
    expect(state(tester, 'build'), 'DONE');
    expect(next(tester), 'Run the test suite');
    expect(find.byKey(const ValueKey('plugin-export-warning')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tool-action')));
    await tester.pumpAndSettle();
    expect(find.byType(TestSuiteScreen), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('tool-action')));
      for (var i = 0; i < 40 && w.lastTest == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-summary')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(state(tester, 'test'), 'DONE');
    expect(summary(tester, 'test'), 'All checks pass · 2 of 2 thresholds pass');
    expect(find.byKey(const ValueKey('plugin-export-warning')), findsNothing);
    expect(next(tester), 'Export…');
  });

  testWidgets('a failed test is next to review; export still opens, with a warning', (tester) async {
    final w = workbench(built: true)..recordTest(PluginCheck.fail, 'Something failed · 1 of 2 thresholds pass');
    await tester.pumpWidget(app(PluginScreen(workbench: w)));
    expect(state(tester, 'test'), 'FAILED');
    expect(next(tester), 'Review the failed tests');
    expect(find.text('This build failed its tests. You can still export.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('plugin-target-vst3')));
    await tester.tap(find.byKey(const ValueKey('plugin-target-vst3')));
    await tester.pumpAndSettle();
    expect(find.byType(PluginExportScreen), findsOneWidget);
    expect(find.text('Name (the file: fuzz.vst3)'), findsOneWidget);
  });

  testWidgets('an edit makes the build, the test and the export out of date, and Build next again', (tester) async {
    final w = workbench(built: true)
      ..recordTest(PluginCheck.pass, 'All checks pass')
      ..recordExport('CLAP', 'fuzz-plugin.zip');
    await tester.pumpWidget(app(PluginScreen(workbench: w)));
    expect(state(tester, 'export'), 'DONE');
    expect(summary(tester, 'export'), 'Saved CLAP · fuzz-plugin.zip');
    expect(next(tester), 'Export…');
    w.edit(w.currentFile, '${w.texts[w.currentFile]}\n// louder');
    w.notifyListeners();
    await tester.pump();
    expect(state(tester, 'build'), 'OUT OF DATE');
    expect(state(tester, 'test'), 'OUT OF DATE');
    expect(state(tester, 'export'), 'OUT OF DATE');
    expect(summary(tester, 'test'), contains('tested an older build'));
    expect(next(tester), 'Build again');
    expect(find.text("The latest code isn't built: the export uses the code as it is now, untested."), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50)); // the autosave and the check
  });

  testWidgets("a failed build lists its errors; one tap closes the page and shows the code at that line", (tester) async {
    final w = workbench();
    const error = CppDiagnostic(file: 'src/effect.cpp', line: 12, column: 3, severity: CppSeverity.error, message: "expected ';'");
    w.diagnostics = const [error];
    w.phase = CppBuildPhase.failed;
    w.buildMessage = 'Build failed: 1 error.';
    CppDiagnostic? shown;
    var opened = false;
    await tester.pumpWidget(app(Builder(builder: (c) => TextButton(
        onPressed: () => openPluginPage(c, w, onOpenCode: (d) {
          opened = true;
          shown = d;
        }),
        child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(state(tester, 'write'), 'FAILED');
    expect(state(tester, 'build'), 'FAILED');
    expect(summary(tester, 'build'), 'Build failed: 1 error.');
    expect(next(tester), 'Fix the error');
    expect(find.text("effect.cpp:12  expected ';'"), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-error-0')));
    await tester.pumpAndSettle();
    expect(find.byType(PluginScreen), findsNothing);
    expect(opened, isTrue);
    expect(shown, same(error));
  });

  testWidgets('an instrument offers a sample pack next to CLAP and VST3, and records the rendered pack', (tester) async {
    final w = workbench(built: true, instrument: true);
    await tester.pumpWidget(app(PluginScreen(workbench: w)));
    expect(find.text('Lead · instrument'), findsOneWidget);
    expect(summary(tester, 'export'), 'CLAP, VST3 or a sample pack');
    await tester.ensureVisible(find.byKey(const ValueKey('plugin-target-pack')));
    await tester.tap(find.byKey(const ValueKey('plugin-target-pack')));
    await tester.pumpAndSettle();
    final pack = tester.widget<SamplePackScreen>(find.byType(SamplePackScreen));
    expect(pack.instrumentId, w.componentId);
    pack.onRendered!('Lead');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(summary(tester, 'export'), 'Saved Sample pack · Lead');
  });

  testWidgets('keys: Ctrl+T opens the tests, Ctrl+E the export, Esc closes', (tester) async {
    final observer = PageCloserObserver();
    final w = workbench(built: true);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      navigatorObservers: [observer],
      builder: (c, child) => PageCloser(observer: observer, child: child!),
      home: Builder(builder: (c) => TextButton(onPressed: () => openPluginPage(c, w), child: const Text('open'))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(TestSuiteScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TestSuiteScreen), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(PluginExportScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PluginScreen), findsNothing);
  });

  testWidgets("the C++ tab's Plug-in button beside Build opens the page", (tester) async {
    final state = AppState(settings: Settings());
    state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
    final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
    state.project.cppComponents.add(doc);
    final sections = SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
    await tester.pumpWidget(app(Scaffold(body: SectionScope(controller: sections, child: BuildSection(state: state)))));
    await tester.pump();
    expect(find.byKey(const ValueKey('plugin-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-page')));
    await tester.pumpAndSettle();
    expect(find.byType(PluginScreen), findsOneWidget);
    expect(find.text('Fuzz · effect'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  for (final name in const ['phone', 'desktop']) {
    testWidgets('golden: the plug-in page at $name size', (tester) async {
      final w = workbench(built: true, instrument: true)..recordTest(PluginCheck.warn, 'Passes, with things to check · 2 of 2 thresholds pass');
      await pumpGolden(tester, PluginScreen(workbench: w), goldenSizes[name]!);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/build_plugin_page_$name.png'));
    });
  }
}
