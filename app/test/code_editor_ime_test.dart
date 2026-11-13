// Issue #20: the C++ editor (re_editor) edited the way an Android on-screen keyboard edits it: text deltas from the
// IME, not key events. Backspace inside a line and at a line's start, replacing a selection, and a composed word.
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/cpp/build_section.dart';
import 'package:caw/ui/cpp/cpp_editor.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// The zero-width prefix re_editor puts before the line it hands an Android or iOS keyboard, so a Backspace at the
/// line's start still has a character to delete.
const prefix = '​';

void main() {
  late Directory dir;
  late AppState state;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('caw-ime');
    state = AppState(settings: Settings());
    state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Opens the editor on a two-line file and focuses it, as a tap does; returns the editor's state.
  Future<CppEditorState> open(WidgetTester tester) async {
    final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
    state.project.cppComponents.add(doc);
    final sections = SectionController()..openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SectionScope(controller: sections, child: BuildSection(state: state)))));
    await tester.pump();
    final editor = tester.state<CppEditorState>(find.byType(CppEditor));
    editor.view.controller.text = 'int gain = 1;\nfloat drive;';
    await tester.pump();
    await tester.tap(find.byType(CodeEditor));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    return editor;
  }

  Future<void> close(WidgetTester tester) async {
    // re_editor shows the cursor 100 ms after each blink starts on Android (an unguarded delay): let it run while the
    // editor is still there, then stop the blink before it goes.
    await tester.pump(const Duration(milliseconds: 150));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  /// The id the IME's connection has (the last setClient).
  int clientId(WidgetTester tester) =>
      (tester.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient').arguments as List)[0] as int;

  /// Sends one delta as the platform does (`TextInputClient.updateEditingStateWithDeltas`).
  Future<void> sendDelta(WidgetTester tester, TextEditingDelta d) async {
    final json = {
      'oldText': d.oldText,
      'deltaText': switch (d) {
        TextEditingDeltaInsertion i => i.textInserted,
        TextEditingDeltaReplacement r => r.replacementText,
        _ => '',
      },
      'deltaStart': switch (d) {
        TextEditingDeltaInsertion i => i.insertionOffset,
        TextEditingDeltaDeletion del => del.deletedRange.start,
        TextEditingDeltaReplacement r => r.replacedRange.start,
        _ => -1,
      },
      'deltaEnd': switch (d) {
        TextEditingDeltaInsertion i => i.insertionOffset,
        TextEditingDeltaDeletion del => del.deletedRange.end,
        TextEditingDeltaReplacement r => r.replacedRange.end,
        _ => -1,
      },
      'selectionBase': d.selection.baseOffset,
      'selectionExtent': d.selection.extentOffset,
      'selectionAffinity': d.selection.affinity.toString(),
      'selectionIsDirectional': false,
      'composingBase': d.composing.start,
      'composingExtent': d.composing.end,
    };
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        clientId(tester),
        {'deltas': [json]},
      ])),
      (_) {},
    );
    await tester.pump();
  }

  CodeLineEditingController ctl(CppEditorState e) => e.view.controller;

  testWidgets('Backspace inside a line deletes the character before the cursor', (tester) async {
    final e = await open(tester);
    ctl(e).selection = const CodeLineSelection.collapsed(index: 0, offset: 8); // after "int gain"
    await tester.pump();
    final old = '${prefix}int gain = 1;';
    await sendDelta(
        tester,
        TextEditingDeltaDeletion(
            oldText: old,
            deletedRange: const TextRange(start: 8, end: 9),
            selection: const TextSelection.collapsed(offset: 8),
            composing: TextRange.empty));
    expect(ctl(e).codeLines[0].text, 'int gai = 1;');
    expect(ctl(e).selection.extentOffset, 7);
    // And again: the keyboard's next delete is against the line the editor sent back.
    await sendDelta(
        tester,
        TextEditingDeltaDeletion(
            oldText: '${prefix}int gai = 1;',
            deletedRange: const TextRange(start: 7, end: 8),
            selection: const TextSelection.collapsed(offset: 7),
            composing: TextRange.empty));
    expect(ctl(e).codeLines[0].text, 'int ga = 1;');
    await close(tester);
  });

  testWidgets("Backspace at a line's start joins it to the line above", (tester) async {
    final e = await open(tester);
    ctl(e).selection = const CodeLineSelection.collapsed(index: 1, offset: 0);
    await tester.pump();
    await sendDelta(
        tester,
        TextEditingDeltaDeletion(
            oldText: '${prefix}float drive;',
            deletedRange: const TextRange(start: 0, end: 1),
            selection: const TextSelection.collapsed(offset: 0),
            composing: TextRange.empty));
    expect(ctl(e).codeLines.length, 1);
    expect(ctl(e).codeLines[0].text, 'int gain = 1;float drive;');
    await close(tester);
  });

  testWidgets('typing over a selection replaces it', (tester) async {
    final e = await open(tester);
    ctl(e).selection = const CodeLineSelection(baseIndex: 0, baseOffset: 4, extentIndex: 0, extentOffset: 8); // "gain"
    await tester.pump();
    await sendDelta(
        tester,
        TextEditingDeltaReplacement(
            oldText: '${prefix}int gain = 1;',
            replacementText: 'x',
            replacedRange: const TextRange(start: 5, end: 9),
            selection: const TextSelection.collapsed(offset: 6),
            composing: TextRange.empty));
    expect(ctl(e).codeLines[0].text, 'int x = 1;');
    expect(ctl(e).selection.isCollapsed, isTrue);
    expect(ctl(e).selection.extentOffset, 5);
    await close(tester);
  });

  testWidgets('a word composed by the keyboard goes in, and a Backspace while composing shortens it', (tester) async {
    final e = await open(tester);
    ctl(e).selection = const CodeLineSelection.collapsed(index: 1, offset: 12); // the end of "float drive;"
    await tester.pump();
    await sendDelta(
        tester,
        TextEditingDeltaInsertion(
            oldText: '${prefix}float drive;',
            textInserted: 'mix',
            insertionOffset: 13,
            selection: const TextSelection.collapsed(offset: 16),
            composing: const TextRange(start: 13, end: 16)));
    expect(ctl(e).codeLines[1].text, 'float drive;mix');
    await sendDelta(
        tester,
        TextEditingDeltaDeletion(
            oldText: '${prefix}float drive;mix',
            deletedRange: const TextRange(start: 15, end: 16),
            selection: const TextSelection.collapsed(offset: 15),
            composing: const TextRange(start: 13, end: 15)));
    expect(ctl(e).codeLines[1].text, 'float drive;mi');
    await close(tester);
  });
}
