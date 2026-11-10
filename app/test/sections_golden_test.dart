// Goldens of the three sections at phone size: Build with a C++ effect open, Files, and Arrange's focus view on the
// FX tab with a built-in effect (they need CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  Future<AppState> startState(WidgetTester tester, {bool distortion = false}) async {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    if (distortion) s.project.layers.first.components.add(ComponentUseDoc('org.caw.distortion'));
    s.selectedModuleId = s.project.modules.first.id;
    s.ready = true;
    s.starting = false;
    await tester.runAsync(() async => s.info = await s.engine!.setProject(s.project.toEngineJson()));
    return s;
  }

  SectionController sections(WidgetTester tester) =>
      SectionController.of(tester.element(find.byType(Scaffold).first));

  testWidgets('Build with a C++ effect open, at phone size', (tester) async {
    final s = await startState(tester);
    final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
    s.project.cppComponents.add(doc);
    await pumpGolden(tester, Shell(state: s), goldenSizes['phone']!);
    sections(tester).openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/section_build_phone.png'));
    s.dispose();
  }, skip: skip);

  testWidgets('Files at phone size', (tester) async {
    final s = await startState(tester);
    await pumpGolden(tester, Shell(state: s), goldenSizes['phone']!);
    sections(tester).show(Section.files);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/section_files_phone.png'));
    s.dispose();
  }, skip: skip);

  testWidgets('Arrange focus view on the FX tab, at phone size', (tester) async {
    final s = await startState(tester, distortion: true);
    final layer = s.project.layers.first;
    // The knobs come from the engine's descriptors, read off the UI thread (real time, outside the test's clock).
    await tester.runAsync(() async => s.componentCatalog.set(await s.engine!.nativeComponents()));
    await pumpGolden(tester, Shell(state: s), goldenSizes['phone']!);
    sections(tester).focusLayer(layer.id);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/section_focus_phone.png'));
    s.dispose();
  }, skip: skip);
}
