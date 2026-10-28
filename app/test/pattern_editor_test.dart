// The piano roll: tapping draws a note and the pattern's text gets it; keys move it; touch drags scroll and a double tap deletes (needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
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

  testWidgets('touch: a drag on empty space scrolls, and a double tap on a note deletes it', (tester) async {
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
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await tester.dragFrom(const Offset(400, 300), const Offset(-200, -60));
    await tester.pump(const Duration(milliseconds: 500));
    expect(body(), isEmpty, reason: 'a drag scrolls, it draws nothing');
    await tester.tapAt(const Offset(120, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(body(), isNotEmpty);
    await tester.tapAt(const Offset(125, 200));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(125, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(body(), isEmpty, reason: m.source);
    s.dispose();
  }, skip: skip != null);
}
