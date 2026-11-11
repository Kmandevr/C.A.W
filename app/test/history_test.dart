// Tests project undo and redo: the history's steps (one per burst of edits, a limit, redo cleared by a new edit) and
// AppState undoing and redoing real edits, including a parameter drag that saves without notifying, and the code editor
// showing the undone code.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/history.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/ui/pattern_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _head = '---\nkind: pattern\nname: tone\n---\n';

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

    /// Waits, however busy the machine is, until the state's own pause timer has closed the burst of edits (it fires
    /// 600 ms after the last edit; nothing here closes it by hand).
    Future<void> settled(AppState s) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (s.history.open && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(s.history.open, isFalse, reason: 'the burst settles by itself after a pause');
    }

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
      expect(s.history.open, isTrue, reason: 'the two volume moves are one open burst');
      await settled(s);
      s.editProject((p) => p.bpm = 150);
      await settled(s);

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
  testWidgets('undoing typed pattern text shows the old text in the editor, and the next keystroke keeps the undo', (tester) async {
    final s = AppState();
    s.starting = false;
    s.project = ProjectDoc(id: 'p', name: 'Song', modules: [ModuleDoc(id: 'm', name: 'tone', source: '${_head}0 C3 1')]);
    s.selectedModuleId = 'm';
    s.history.reset(jsonEncode(s.project.toJson()));
    // The shell rebuilds the workspace when the state notifies.
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => PatternScreen(state: s)))));
    await tester.tap(find.text('Text'));
    await tester.pump();
    final code = find.byWidgetPredicate((w) => w is EditableText && w.maxLines == null);
    String shown() => tester.widget<EditableText>(code).controller.text;
    expect(shown(), '0 C3 1');

    await tester.enterText(code, '0 C3 2');
    await tester.pump(const Duration(milliseconds: 700));
    expect(s.project.module('m')!.source, '${_head}0 C3 2');
    expect(s.undo(), isTrue);
    await tester.pump();
    expect(shown(), '0 C3 1');
    await tester.enterText(code, '0 C3 13');
    expect(s.project.module('m')!.source, '${_head}0 C3 13');
    expect(s.undo(), isTrue);
    await tester.pump();
    expect(shown(), '0 C3 1');
    expect(s.redo(), isTrue);
    await tester.pump();
    expect(shown(), '0 C3 13');
    await tester.pump(const Duration(seconds: 2));
    s.dispose();
  });
  test('the undo steps keep at most maxChars of text, always the newest', () {
    final h = ProjectHistory(maxChars: 10)..reset('aaaa');
    for (final next in ['bbbb', 'cccc', 'dddd', 'eeeeeeeeeeeeeeee', 'f']) {
      h.begin();
      h.settle(next);
    }
    expect(h.undo('f'), 'eeeeeeeeeeeeeeee'); // over the cap alone, but the newest step stays
    expect(h.undo('eeeeeeeeeeeeeeee'), isNull);
    expect(h.redo('eeeeeeeeeeeeeeee'), 'f');
  });
}
