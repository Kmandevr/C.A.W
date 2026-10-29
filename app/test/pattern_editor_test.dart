// The piano roll: tapping draws a note and the pattern's text gets it; keys move it; it works inside a scrolling page; the menu runs generators; the Curve tool shapes velocity; a double tap deletes a note (needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  testWidgets('tap draws a note, D moves it, Delete removes it', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await tester.tapAt(const Offset(120, 200));
    await tester.pump(const Duration(milliseconds: 200));
    final body = m.source.split('---').last.trim();
    expect(body.split('\n').length, 1, reason: m.source);
    expect(body, isNotEmpty);
    final first = body;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump(const Duration(milliseconds: 200));
    expect(m.source.split('---').last.trim(), isNot(first));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump(const Duration(milliseconds: 200));
    expect(m.source.split('---').last.trim(), isEmpty);
    s.dispose();
  }, skip: skip != null);

  testWidgets('inside a scrolling page a tap still draws, and a drag on empty grid scrolls instead', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    final list = ScrollController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(controller: list, children: [
      const SizedBox(height: 100),
      SizedBox(height: 440, child: PatternEditor(state: s, module: m)),
      const SizedBox(height: 900),
    ]))));
    await tester.dragFrom(const Offset(200, 380), const Offset(-80, -120));
    await tester.pump(const Duration(milliseconds: 200));
    expect(list.offset, 0, reason: 'the page must not take the roll\'s drag');
    expect(m.source.split('---').last.trim(), isEmpty, reason: 'a drag on empty grid scrolls, it does not draw');
    await tester.tapAt(const Offset(200, 380));
    await tester.pump(const Duration(milliseconds: 200));
    expect(m.source.split('---').last.trim().split('\n').length, 1, reason: m.source);
    s.dispose();
  }, skip: skip != null);

  testWidgets('the menu runs a generator: Euclid writes 3 hits in 8 steps', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    expect(find.byTooltip('Draw tool'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate: Euclid'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(m.source.split('---').last.trim().split('\n').length, 3, reason: m.source);
    s.dispose();
  }, skip: skip != null);

  testWidgets('the Curve tool: two taps in the velocity lane ramp the notes between them', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n1 C3 1\n5 C3 1\n9 C3 1\n13 C3 1\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await tester.tap(find.byTooltip('Curve tool'));
    await tester.pump();
    // The velocity lane is the bottom 56 px; x = 44 px of keys + 28 px per step.
    await tester.tapAt(const Offset(44 + 0.5 * 28, 787)); // value 0.2
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(44 + 14 * 28, 749)); // value 0.96
    await tester.pump(const Duration(milliseconds: 200));
    final vels = PatternDoc.parse(m.source).doc!.notes.map((n) => n.vel).toList();
    expect(vels.first, lessThan(0.4), reason: m.source);
    expect(vels.last, greaterThan(0.8), reason: m.source);
    for (var i = 1; i < vels.length; i++) {
      expect(vels[i], greaterThan(vels[i - 1]), reason: m.source);
    }
    s.dispose();
  }, skip: skip != null);

  testWidgets('touch: a double tap on a note deletes it, a single tap keeps it', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    String body() => m.source.split('---').last.trim();
    // The double tap is timed by the wall clock, so the test waits real time where the taps must be apart.
    Future<void> wait() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await tester.tapAt(const Offset(120, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(body(), isNotEmpty);
    await wait();
    await tester.tapAt(const Offset(125, 200));
    await tester.pump(const Duration(milliseconds: 500));
    await wait();
    expect(body(), isNotEmpty, reason: 'one tap keeps the note');
    await tester.tapAt(const Offset(125, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(body(), isNotEmpty, reason: 'taps far apart are two single taps');
    await wait();
    await tester.tapAt(const Offset(125, 200));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(125, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(body(), isEmpty, reason: m.source);
    s.dispose();
  }, skip: skip != null);
}
