// The C++ Builder's widgets: the key row and cursor key, the Problems list jump, and BuildSection's tabs.
import 'dart:io';

import 'package:caw/model/pattern_templates.dart' show PatternTemplate;
import 'package:caw/model/app_state.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_diagnostics.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/cpp/build_section.dart';
import 'package:caw/ui/cpp/build_start.dart' show starterExamples;
import 'package:caw/ui/cpp/cpp_editor.dart';
import 'package:caw/ui/cpp/cpp_library.dart';
import 'package:caw/ui/cpp/key_row.dart';
import 'package:caw/ui/cpp/panels.dart';
import 'package:caw/ui/cpp/quick_open.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A one-line text with a cursor, standing in for the editor.
class FakeTarget implements CodeKeyTarget {
  String text = '';
  int cursor = 0, line = 0, selectionStart = -1;
  int undos = 0;

  @override
  void insert(String t) {
    text = text.substring(0, cursor) + t + text.substring(cursor);
    cursor += t.length;
  }

  @override
  void indent() => insert('    ');

  @override
  void moveCursor({int columns = 0, int lines = 0, bool select = false}) {
    if (select && selectionStart < 0) selectionStart = cursor;
    cursor = (cursor + columns).clamp(0, text.length);
    line = (line + lines).clamp(0, 100);
  }

  @override
  void undo() => undos++;
  @override
  void redo() {}
  @override
  bool get canUndo => true;
  @override
  bool get canRedo => false;
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('the key row types symbols, variants on hold, a second page, and undo', (tester) async {
    final t = FakeTarget();
    await tester.pumpWidget(host(Align(alignment: Alignment.bottomCenter, child: CodeKeyRow(target: t))));
    await tester.tap(find.byKey(const ValueKey('key {')));
    await tester.tap(find.byKey(const ValueKey('key ;')));
    await tester.tap(find.byKey(const ValueKey('key tab')));
    expect(t.text, '{;    ');
    await tester.longPress(find.byKey(const ValueKey('key =')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('variant ==')));
    await tester.pumpAndSettle();
    expect(t.text, '{;    ==');
    await tester.longPress(find.byKey(const ValueKey('key <')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('variant ->')));
    await tester.pumpAndSettle();
    expect(t.text, endsWith('->'));
    // Swipe for the second page.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1500);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('key ::')));
    expect(t.text, endsWith('->::'));
    await tester.tap(find.byKey(const ValueKey('key undo')));
    expect(t.undos, 1);
  });

  testWidgets('the key row explains its hidden moves on its first showings, then stays quiet', (tester) async {
    CodeKeyRow.hintsShown = 0;
    double opacity() => tester
        .widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const ValueKey('key row hint')), matching: find.byType(AnimatedOpacity)))
        .opacity;
    for (var i = 0; i < CodeKeyRow.hintTimes; i++) {
      await tester.pumpWidget(host(Align(alignment: Alignment.bottomCenter, child: CodeKeyRow(key: ValueKey(i), target: FakeTarget()))));
      expect(opacity(), 1);
      await tester.pump(const Duration(seconds: 6));
      expect(opacity(), 0);
    }
    await tester.pumpWidget(host(Align(alignment: Alignment.bottomCenter, child: CodeKeyRow(key: const ValueKey('again'), target: FakeTarget()))));
    expect(opacity(), 0);
  });

  testWidgets('the cursor key moves the cursor like a trackpad; held, it selects', (tester) async {
    final t = FakeTarget()..text = 'abcdefghijklmnopqrstuvwxyz';
    await tester.pumpWidget(host(Align(alignment: Alignment.bottomCenter, child: CodeKeyRow(target: t))));
    final key = find.byKey(const ValueKey('cursor key'));
    final gesture = await tester.startGesture(tester.getCenter(key));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(9, 0));
      await tester.pump();
    }
    await gesture.moveBy(const Offset(0, 33));
    await tester.pump();
    await gesture.up();
    // Drag recognition takes the first few dp: most of the 72 dp across becomes columns, 33 dp down two lines.
    expect(t.cursor, inInclusiveRange(5, 8));
    expect(t.line, 2);
    expect(t.selectionStart, -1);
    // Hold, then drag: a selection.
    final hold = await tester.startGesture(tester.getCenter(key));
    await tester.pump(const Duration(milliseconds: 600));
    await hold.moveBy(const Offset(-27, 0));
    await tester.pump();
    await hold.up();
    expect(t.selectionStart, isNot(-1));
    expect(t.cursor, lessThan(t.selectionStart));
  });

  testWidgets('tapping a problem jumps to it; warnings are listed under their file', (tester) async {
    final state = AppState(settings: Settings());
    state.project.cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
    final w = CppWorkbench(state, 'cpp1');
    w.diagnostics = const [
      CppDiagnostic(file: 'src/effect.cpp', line: 12, column: 3, severity: CppSeverity.error, message: 'expected ;'),
      CppDiagnostic(file: 'src/effect.cpp', line: 4, column: 1, severity: CppSeverity.warning, message: 'unused variable'),
    ];
    CppDiagnostic? jumped;
    await tester.pumpWidget(host(ProblemsList(workbench: w, onJump: (d) => jumped = d)));
    expect(find.text('SRC/EFFECT.CPP'), findsOneWidget);
    expect(find.text('unused variable'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('problem src/effect.cpp:12:3')));
    expect(jumped!.line, 12);
    w.dispose();
  });

  testWidgets('the Library finds an SDK type with its members, built-ins and the pattern format, and inserts', (tester) async {
    final inserted = <String>[];
    await tester.pumpWidget(host(CppLibraryView(onInsert: inserted.add)));
    expect(find.text('DESCRIBE'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('library search')), 'caw::lib::Adsr');
    await tester.pump();
    // One match opens; its members are listed and a tap types `.gateOn`.
    expect(find.textContaining('.gateOn: ', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('insert caw::lib::Adsr')));
    expect(inserted.single, 'caw::lib::Adsr env_;');
    await tester.enterText(find.byKey(const ValueKey('library search')), 'org.caw.drum.kit');
    await tester.pump();
    expect(find.text('BUILT-IN INSTRUMENTS'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('library search')), 'ratchet');
    await tester.pump();
    expect(find.text('TEXT FORMATS'), findsOneWidget);
  });

  group('BuildSection', () {
    late Directory dir;
    late AppState state;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('caw-build-section');
      state = AppState(settings: Settings());
      state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('shows the start view without tabs; New effect adds one and opens it', (tester) async {
      final sections = SectionController();
      await tester.pumpWidget(host(SectionScope(controller: sections, child: BuildSection(state: state))));
      expect(find.byKey(const ValueKey('new effect')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('new effect')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.project.cppComponents, hasLength(1));
      final doc = state.project.cppComponents.single;
      expect(sections.buildTabs, [BuildTab(BuildTabKind.cpp, doc.componentId)]);
      expect(find.byType(CppEditor), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('breadcrumb')), matching: find.textContaining('My effect › src › effect.cpp')), findsOneWidget);
      // No errors: no error count (owner: show only what matters).
      expect(find.byKey(const ValueKey('error count')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets("opens the controller's active C++ tab in the editor; a tab whose effect is gone shows the start view", (tester) async {
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      final sections = SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
      await tester.pumpWidget(host(SectionScope(controller: sections, child: BuildSection(state: state))));
      await tester.pump();
      expect(find.byType(CppEditor), findsOneWidget);
      expect(find.textContaining('Fuzz'), findsWidgets);
      // A tab whose component is gone falls back to the start view.
      sections.closeBuild(sections.buildTabs.single);
      sections.openBuild(const BuildTab(BuildTabKind.cpp, 'gone'));
      await tester.pump();
      expect(find.byType(CppEditor), findsNothing);
      expect(find.byKey(const ValueKey('new effect')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('completion opens after :: near the cursor and inserts the chosen name', (tester) async {
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      final sections = SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
      await tester.pumpWidget(host(SectionScope(controller: sections, child: BuildSection(state: state))));
      await tester.pump();
      final editor = tester.state<CppEditorState>(find.byType(CppEditor));
      editor.insert('caw::lib::dr');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // a short pause opens it mid-word
      expect(find.byKey(const ValueKey('completion drive')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('completion drive')));
      await tester.pump();
      expect(editor.view.controller.codeLines[0].text, startsWith('caw::lib::drive//'));
      expect(find.byKey(const ValueKey('completion drive')), findsNothing);
      // Typing went into the session (autosave and the check follow after a pause).
      expect(state.cppWorkbench('cpp1').texts['src/effect.cpp'], startsWith('caw::lib::drive'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('+ New offers pattern, instrument, effect and a text file in the open component', (tester) async {
      final sections = SectionController();
      await tester.pumpWidget(host(SectionScope(controller: sections, child: BuildSection(state: state))));
      await tester.tap(find.byKey(const ValueKey('new menu')));
      await tester.pumpAndSettle();
      expect(find.text('Pattern'), findsOneWidget);
      expect(find.text('Instrument'), findsOneWidget);
      // No C++ component open: no text file yet.
      expect(tester.widget<PopupMenuItem<String>>(find.byKey(const ValueKey('new text'))).enabled, isFalse);
      await tester.tap(find.text('Effect'));
      await tester.pumpAndSettle();
      final doc = state.project.cppComponents.single;
      expect(sections.buildTabs.single, BuildTab(BuildTabKind.cpp, doc.componentId));
      await tester.tap(find.byKey(const ValueKey('new menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('new file name')), 'notes.txt');
      await tester.tap(find.byKey(const ValueKey('create file')));
      await tester.pumpAndSettle();
      final w = state.cppWorkbench(doc.id);
      expect(w.currentFile, 'notes.txt');
      expect(find.descendant(of: find.byKey(const ValueKey('breadcrumb')), matching: find.textContaining('My effect › notes.txt')), findsOneWidget);
      // A pattern opens as a .caw tab next to it.
      await tester.tap(find.byKey(const ValueKey('new menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pattern'));
      await tester.pumpAndSettle();
      expect(sections.buildTabs, hasLength(2));
      expect(state.isPattern(sections.activeBuildTab!.id), isTrue);
      expect(find.byKey(const ValueKey('pattern name')), findsOneWidget);
      // × closes a tab.
      await tester.tap(find.byKey(ValueKey('close ${sections.activeBuildTab!.id}')));
      await tester.pumpAndSettle();
      expect(sections.buildTabs, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets("the explorer (a drawer on a phone) is the Files browser: a tap opens a component's file", (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      final sections = SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
      await tester.pumpWidget(host(SectionScope(controller: sections, child: BuildSection(state: state))));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('explorer')));
      await tester.pumpAndSettle();
      // It opens on the component's own folder.
      expect(find.text('caw-component.json'), findsOneWidget);
      await tester.tap(find.text('caw-component.json'));
      await tester.pumpAndSettle();
      expect(state.cppWorkbench('cpp1').currentFile, 'caw-component.json');
      expect(find.descendant(of: find.byKey(const ValueKey('breadcrumb')), matching: find.textContaining('caw-component.json')), findsOneWidget);
      // Folders jumps anywhere in the tree.
      await tester.tap(find.byKey(const ValueKey('explorer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Patterns').last);
      await tester.pumpAndSettle();
      expect(find.text('No patterns yet. Tap + for a new one.'), findsOneWidget);
      // The group chips jump between kinds of code in one tap.
      await tester.tap(find.byKey(const ValueKey('explorer group cpp')));
      await tester.pumpAndSettle();
      expect(find.text('Fuzz'), findsWidgets);
      expect(find.text('No patterns yet. Tap + for a new one.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('on a wide screen the explorer is a sidebar that hides and drags wider', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      final sections = SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
      await tester.pumpWidget(host(SectionScope(controller: sections, child: BuildSection(state: state))));
      await tester.pump();
      final explorer = find.byKey(const ValueKey('build explorer'));
      expect(explorer, findsOneWidget);
      final before = tester.getSize(explorer).width;
      await tester.drag(find.byKey(const ValueKey('explorer sash')), const Offset(60, 0));
      await tester.pump();
      expect(tester.getSize(explorer).width, greaterThan(before + 50));
      await tester.tap(find.byKey(const ValueKey('explorer')));
      await tester.pump();
      expect(explorer, findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('without a SectionScope (tests, a screen alone) it keeps its own tabs', (tester) async {
      await tester.pumpWidget(host(BuildSection(state: state)));
      await tester.tap(find.byKey(const ValueKey('new effect')));
      await tester.pump();
      expect(find.byType(CppEditor), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('Build: start page and navigation', () {
    late Directory dir;
    late AppState state;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('caw-build-nav');
      state = AppState(settings: Settings());
      state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<SectionController> pump(WidgetTester tester, {SectionController? sections}) async {
      final c = sections ?? SectionController();
      await tester.pumpWidget(host(SectionScope(controller: c, child: BuildSection(state: state))));
      await tester.pump();
      return c;
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('the start page says what Build is for and starts an instrument, an effect or a pattern', (tester) async {
      final sections = await pump(tester);
      expect(find.text('The C++ workspace: write instruments and effects in code, then hear them on your tracks. Patterns and other text files open here too.'), findsOneWidget);
      for (final id in ['new instrument', 'new effect', 'new pattern']) {
        expect(find.byKey(ValueKey(id)), findsOneWidget);
      }
      expect(find.textContaining('InstrumentProcessor'), findsOneWidget); // the tiny code preview
      expect(find.byKey(const ValueKey('start library')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('new instrument')));
      await tester.pump();
      final doc = state.project.cppComponents.single;
      expect(sections.activeBuildTab, BuildTab(BuildTabKind.cpp, doc.componentId));
      expect(state.cppWorkbench(doc.id).isInstrument, isTrue);
      expect(find.byKey(const ValueKey('cpp badge')), findsOneWidget);
      expect(find.text('Not built yet'), findsOneWidget);
      // + New › Start page brings the start page back; the tab stays open.
      await tester.tap(find.byKey(const ValueKey('new menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start page'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('build start')), findsOneWidget);
      expect(sections.buildTabs, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('new pattern')));
      await tester.pumpAndSettle();
      expect(state.isPattern(sections.activeBuildTab!.id), isTrue);
      await done(tester);
    });

    testWidgets('Open an example lists the C++ starters and pattern templates by kind and opens a copy', (tester) async {
      state.patternExamples = const [
        PatternTemplate('fold.caw', '---\ncaw: 1\nkind: effect\nname: Fold\nsummary: Wavefolder\n---\nout = in;\n'),
        PatternTemplate('chords.caw', '---\ncaw: 1\nkind: pattern\nname: Chords\nsummary: Four bars\n---\n'),
      ];
      final sections = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('open example')));
      await tester.pumpAndSettle();
      expect(find.text('INSTRUMENTS'), findsOneWidget);
      // The .caw sound modules are replaced by the C++ starters; patterns stay.
      final listed = starterExamples(state.patternExamples);
      expect({for (final e in listed) e.group}, {'Instruments', 'Effects', 'Patterns'});
      expect(listed.map((e) => e.key), containsAll(['cpp/bass', 'cpp/glitch-fx', 'chords.caw']));
      expect(listed.map((e) => e.key), isNot(contains('fold.caw')));
      await tester.tap(find.byKey(const ValueKey('example cpp/bass')));
      await tester.pumpAndSettle();
      final c = state.project.cppComponents.single;
      expect(c.name, 'Bass');
      expect(c.componentId, 'local.bass.${c.id}');
      expect(sections.activeBuildTab, BuildTab(BuildTabKind.cpp, c.componentId));
      await done(tester);
    });

    testWidgets('the quick switcher finds a file and a symbol', (tester) async {
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      await pump(tester, sections: SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId)));
      await tester.tap(find.byKey(const ValueKey('quick open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick open field')), 'compjson');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quick file cpp1/caw-component.json')));
      await tester.pumpAndSettle();
      expect(state.cppWorkbench('cpp1').currentFile, 'caw-component.json');
      // A symbol of the open file: the cursor goes to its line.
      state.cppWorkbench('cpp1').selectFile('src/effect.cpp');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick open field')), 'process');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final editor = tester.state<CppEditorState>(find.byType(CppEditor));
      final line = editor.view.controller.selection.extentIndex;
      expect(editor.view.controller.codeLines[line].text, contains('process('));
      await done(tester);
    });

    test('quick matching ranks contiguous and word-start matches first, and drops non-matches', () {
      expect(quickScore('fx', 'effect.cpp'), isNull);
      expect(quickScore('eff', 'effect.cpp')!, greaterThan(quickScore('ect', 'effect.cpp')!));
      expect(quickScore('cjs', 'caw-component.json'), isNotNull);
      final outline = cppOutline('class Fuzz final : public X {\n  void process(int b) {\n  }\n  if (x) {\n};');
      expect([for (final o in outline) o.name], ['Fuzz', 'process']);
    });

    testWidgets('the status chip counts errors; next and previous go between them', (tester) async {
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      final w = state.cppWorkbench('cpp1');
      w.diagnostics = const [
        CppDiagnostic(file: 'src/effect.cpp', line: 4, column: 1, severity: CppSeverity.error, message: 'one'),
        CppDiagnostic(file: 'src/effect.cpp', line: 9, column: 5, severity: CppSeverity.error, message: 'two'),
      ];
      await pump(tester, sections: SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId)));
      expect(find.text('2 errors'), findsOneWidget);
      final editor = tester.state<CppEditorState>(find.byType(CppEditor));
      int line() => editor.view.controller.selection.extentIndex + 1;
      await tester.tap(find.byKey(const ValueKey('build status'))); // go to the next error
      await tester.pump();
      expect(line(), 4);
      await tester.tap(find.byKey(const ValueKey('next error')));
      await tester.pump();
      expect(line(), 9);
      await tester.tap(find.byKey(const ValueKey('next error'))); // wraps
      await tester.pump();
      expect(line(), 4);
      await tester.tap(find.byKey(const ValueKey('previous error'))); // wraps back
      await tester.pump();
      expect(line(), 9);
      await done(tester);
    });

    testWidgets('after a build, "Try it on a track" puts an effect on the picked track and an instrument on a new one',
        (tester) async {
      state.addLayer();
      final kick = state.project.layers.single..name = 'Kick';
      state.selectLayer(kick);
      final fx = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      final synth = CppComponentDoc.blankInstrument(id: 'cpp2', name: 'Synth');
      state.project.cppComponents.addAll([fx, synth]);
      state.cppWorkbench('cpp1').phase = CppBuildPhase.built;
      state.cppWorkbench('cpp2').phase = CppBuildPhase.built;
      final sections = await pump(tester, sections: SectionController()..openBuild(BuildTab(BuildTabKind.cpp, fx.componentId)));
      expect(find.text('Built'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('try on track')));
      await tester.pumpAndSettle();
      expect(find.text('selected'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('try ${kick.id}')));
      await tester.pumpAndSettle();
      expect(kick.components.map((c) => c.id), [fx.componentId]);
      expect(find.text('Fuzz is on Kick'), findsOneWidget);
      // Now the chip says where it plays; tapping it shows that track in Arrange.
      expect(find.text('Built · on Kick'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('build status')));
      await tester.pump();
      expect(sections.focusedLayer, kick.id);
      // An instrument on a new track named after it.
      sections.openBuild(BuildTab(BuildTabKind.cpp, synth.componentId));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('try on track')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('try new track')));
      await tester.pumpAndSettle();
      final added = state.project.layers.last;
      expect(added.name, 'Synth');
      expect(added.instrument?.id, synth.componentId);
      expect(state.selectedLayerId, added.id);
      await done(tester);
    });
  });
}
