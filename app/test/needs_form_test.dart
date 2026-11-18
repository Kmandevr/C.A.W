// The Needs form on the plug-in page: add from the picker, write a reason (and Internet's sites), validation on one line, remove, and caw-component.json as written.
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/capabilities.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/cpp/needs_form.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var motion = MotionLevel.full;
  late Directory dir;
  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
    dir = Directory.systemTemp.createTempSync('caw-needs');
  });
  tearDown(() {
    Motion.setting = motion;
    dir.deleteSync(recursive: true);
  });

  CppWorkbench workbench() {
    final state = AppState(settings: Settings());
    state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
    state.project.cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Space Delay'));
    return CppWorkbench(state, 'cpp1', saveDelay: const Duration(hours: 1), checkDelay: const Duration(hours: 1));
  }

  Future<void> pump(WidgetTester tester, CppWorkbench w) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: [NeedsForm(workbench: w)])),
    ));
  }

  Future<void> add(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(const ValueKey('needs-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('needs-pick-$id')));
    await tester.pumpAndSettle();
  }

  // The pending autosave and check go with the session (its save runs for real).
  Future<void> close(WidgetTester tester, CppWorkbench w) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      w.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  }

  List<CapabilityDeclaration> written(CppWorkbench w) => Capabilities.ofManifest(w.texts['caw-component.json']!);

  testWidgets('add, edit, validate and remove; each change writes the manifest once', (tester) async {
    final w = workbench();
    await pump(tester, w);
    expect(find.byKey(const ValueKey('needs-empty')), findsOneWidget);

    // Internet: a reason and its sites.
    await add(tester, 'internet');
    expect(find.byKey(const ValueKey('needs-row-internet')), findsOneWidget);
    expect(find.byKey(const ValueKey('needs-sites')), findsOneWidget);
    // Done with no reason: it says why on one line and writes nothing.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('needs-error-internet')), findsOneWidget);
    expect(written(w), isEmpty);

    final revision = w.revision;
    await tester.enterText(find.byKey(const ValueKey('needs-reason-internet')), 'downloads the factory presets');
    await tester.enterText(find.byKey(const ValueKey('needs-sites')), 'presets.example.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('needs-error-internet')), findsNothing);
    expect(written(w), const [CapabilityDeclaration('internet', 'downloads the factory presets', ['presets.example.com'])]);
    expect(w.revision, revision + 1); // one undoable replace in the editor

    // A bad site isn't written; the manifest keeps what it had.
    await tester.enterText(find.byKey(const ValueKey('needs-sites')), 'Not a host!');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('is not a host name'), findsOneWidget);
    expect(written(w).single.sites, ['presets.example.com']);
    await tester.enterText(find.byKey(const ValueKey('needs-sites')), 'presets.example.com cdn.example.org');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(written(w).single.sites, ['presets.example.com', 'cdn.example.org']);

    // Write files: the picker no longer offers Internet.
    await tester.tap(find.byKey(const ValueKey('needs-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('needs-pick-internet')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('needs-pick-write_files')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('needs-reason-write_files')), 'saves recorded loops');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(written(w).map((d) => d.id), ['internet', 'write_files']);
    expect(find.text('Write files'), findsOneWidget);
    expect(find.byKey(const ValueKey('needs-sites')), findsOneWidget); // only Internet has sites

    // A reason over 200 characters can't be typed; the field stops at 200.
    await tester.enterText(find.byKey(const ValueKey('needs-reason-write_files')), 'x' * 250);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('needs-reason-write_files'))).controller!.text.length, 200);

    // Remove.
    await tester.tap(find.byKey(const ValueKey('needs-remove-internet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('needs-row-internet')), findsNothing);
    expect(written(w).map((d) => d.id), ['write_files']);
    expect(written(w).single.reason, 'x' * 200);
    await tester.tap(find.byKey(const ValueKey('needs-remove-write_files')));
    await tester.pumpAndSettle();
    expect(w.texts['caw-component.json'], isNot(contains('capabilities')));
    expect(find.byKey(const ValueKey('needs-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, w);
  });

  testWidgets('the rows follow the manifest when it changes in the code, and an invalid list says why', (tester) async {
    final w = workbench();
    await pump(tester, w);
    w.edit('caw-component.json', Capabilities.writeToManifest(w.texts['caw-component.json']!,
        const [CapabilityDeclaration('background_threads', 'loads long samples')]));
    w.notifyListeners(); // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('needs-row-background_threads')), findsOneWidget);
    expect(find.text('loads long samples'), findsOneWidget);

    w.edit('caw-component.json', w.texts['caw-component.json']!.replaceFirst('background_threads', 'network'));
    w.notifyListeners(); // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('needs-problem')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('needs-add'))).onPressed, isNull);
    await close(tester, w);
  });
}
