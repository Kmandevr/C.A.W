// The C++ Builder's widgets: the key row and cursor key, the Problems list jump, and BuildSection's tabs.
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_diagnostics.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/cpp/build_section.dart';
import 'package:caw/ui/cpp/cpp_editor.dart';
import 'package:caw/ui/cpp/key_row.dart';
import 'package:caw/ui/cpp/panels.dart';
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
      expect(find.textContaining('My effect · effect.cpp'), findsOneWidget);
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

    testWidgets('without a SectionScope (tests, a screen alone) it keeps its own tabs', (tester) async {
      await tester.pumpWidget(host(BuildSection(state: state)));
      await tester.tap(find.byKey(const ValueKey('new effect')));
      await tester.pump();
      expect(find.byType(CppEditor), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
