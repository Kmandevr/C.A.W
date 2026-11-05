// Tests project undo and redo: the history's steps (one per burst of edits, a limit, redo cleared by a new edit) and
// AppState undoing and redoing real edits, including a parameter drag that saves without notifying, and the code editor
// showing the undone code.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/history.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/ui/builder_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProjectHistory', () {
    test('a burst of edits is one step; undo and redo walk the steps', () {
      final h = ProjectHistory()..reset('a');
      expect(h.canUndo, isFalse);
      h.begin();
      h.begin(); // the same burst
      h.settle('b');
      h.begin();
      h.settle('c');
      expect(h.undo('c'), 'b');
      expect(h.undo('b'), 'a');
      expect(h.undo('a'), isNull);
      expect(h.redo('a'), 'b');
      expect(h.redo('b'), 'c');
      expect(h.redo('c'), isNull);
    });

    test('a new edit clears redo', () {
      final h = ProjectHistory()..reset('a');
      h.begin();
      h.settle('b');
      expect(h.undo('b'), 'a');
      expect(h.canRedo, isTrue);
      h.begin();
      h.settle('x');
      expect(h.canRedo, isFalse);
      expect(h.undo('x'), 'a');
    });

    test('a burst that changed nothing adds no step and keeps redo', () {
      final h = ProjectHistory()..reset('a');
      h.begin();
      h.settle('b');
      expect(h.undo('b'), 'a');
      h.begin(); // a save with no edit, such as Run on unedited code
      h.settle('a');
      expect(h.canRedo, isTrue);
      expect(h.redo('a'), 'b');
      expect(h.undo('b'), 'a');
      expect(h.undo('a'), isNull);
    });

    test('undo in the middle of a burst ends it first, so nothing is lost', () {
      final h = ProjectHistory()..reset('a');
      h.begin(); // still open: the project now stands at b
      expect(h.undo('b'), 'a');
      expect(h.redo('a'), 'b');
    });

    test('only the newest steps are kept', () {
      final h = ProjectHistory(limit: 2)..reset('0');
      for (var i = 1; i <= 4; i++) {
        h.begin();
        h.settle('$i');
      }
      expect(h.undo('4'), '3');
      expect(h.undo('3'), '2');
      expect(h.undo('2'), isNull);
    });
  });

  group('AppState undo and redo', () {
    late Directory root;
    setUp(() async => root = await Directory.systemTemp.createTemp('caw-history-'));
    tearDown(() => root.delete(recursive: true));

    Future<void> pause() => Future<void>.delayed(const Duration(milliseconds: 700));

    test('undo and redo go back and forth over project edits, one step per burst', () async {
      final storage = ProjectStorage(root);
      await storage.save(ProjectDoc(id: 'p', name: 'Song', bpm: 120, layers: [LayerDoc(id: 'l', name: 'Lead', color: 0)]));
      await storage.setLastOpened('p');
      final s = AppState();
      addTearDown(s.dispose);
      await s.openStorage(storage);
      expect(s.canUndo, isFalse, reason: 'a project just opened has no history');

      var notified = 0;
      s.addListener(() => notified++);
      s.mixLayer(s.project.layers.first, volume: 0.3); // a drag: saves without a full notification
      s.mixLayer(s.project.layers.first, volume: 0.2);
      expect(s.canUndo, isTrue);
      expect(notified, greaterThan(0), reason: 'the transport sees undo become available');
      await pause();
      s.editProject((p) => p.bpm = 150);
      await pause();

      expect(s.undo(), isTrue);
      expect(s.project.bpm, 120);
      expect(s.project.layers.first.volume, closeTo(0.2, 1e-9));
      expect(s.undo(), isTrue, reason: 'the two volume moves were one burst');
      expect(s.project.layers.first.volume, isNot(closeTo(0.2, 1e-9)));
      expect(s.undo(), isFalse);
      expect(s.redo(), isTrue);
      expect(s.redo(), isTrue);
      expect(s.project.bpm, 150);
      expect(s.redo(), isFalse);
    });
  });
  testWidgets('undoing typed code shows the old code in the editor, and the next keystroke keeps the undo', (tester) async {
    final s = AppState();
    s.starting = false;
    s.project = ProjectDoc(id: 'p', name: 'Song', modules: [ModuleDoc(id: 'm', name: 'tone', source: 'out 1')]);
    s.selectedModuleId = 'm';
    s.history.reset(jsonEncode(s.project.toJson()));
    // The shell rebuilds the workspace when the state notifies.
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => BuilderScreen(state: s)))));
    String shown() => tester.widget<EditableText>(find.byType(EditableText).first).controller.text;
    expect(shown(), 'out 1');

    await tester.enterText(find.byType(EditableText).first, 'out 2');
    await tester.pump(const Duration(milliseconds: 700));
    expect(s.project.module('m')!.source, 'out 2');
    expect(s.undo(), isTrue);
    await tester.pump();
    expect(shown(), 'out 1');
    await tester.enterText(find.byType(EditableText).first, 'out 13');
    expect(s.project.module('m')!.source, 'out 13');
    expect(s.undo(), isTrue);
    await tester.pump();
    expect(shown(), 'out 1');
    expect(s.redo(), isTrue);
    await tester.pump();
    expect(shown(), 'out 13');
    await tester.pump(const Duration(seconds: 2));
    s.dispose();
  });
}
