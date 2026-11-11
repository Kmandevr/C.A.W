// The piano roll's tools from WP-K2: closing an empty pattern writes nothing; the quantize sheet; step input; the
// connect and tremolo generators (needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppState> _state(String source, {String id = 'line'}) async {
  final s = AppState();
  s.engine = Engine.create();
  s.templates = Engine.templates();
  s.project = s.starterProject();
  s.project.modules.add(ModuleDoc(id: id, name: id, source: source));
  s.ready = true;
  s.starting = false;
  return s;
}

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  testWidgets('closing a truly empty pattern writes nothing and trips no assertion (#169)', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = await _state('');
    final m = s.project.module('line')!;
    final show = ValueNotifier(true);
    // The app rebuilds on every AppState change, as the Build tabs do.
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: Listenable.merge([s, show]),
                builder: (_, __) => show.value ? PatternEditor(state: s, module: m) : const SizedBox()))));
    show.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(m.source, '', reason: 'an unedited empty pattern stays empty');
    s.dispose();
  }, skip: skip != null);

  testWidgets('an edit still pending when the roll closes is written after the frame, without an assertion', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = await _state('');
    final m = s.project.module('line')!;
    final show = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: Listenable.merge([s, show]),
                builder: (_, __) => show.value ? PatternEditor(state: s, module: m) : const SizedBox()))));
    await tester.tapAt(const Offset(120, 200)); // draws a note; the write waits 150 ms
    show.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(m.source.split('---').last.trim(), isNotEmpty, reason: m.source);
    s.dispose();
  }, skip: skip != null);
}
